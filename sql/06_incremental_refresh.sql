-- ============================================================================
-- ANLC-752 Course Project -- Unit 10, Item 3: Incremental refresh strategy
--
-- mv_tx_degree and mv_illicit_exposure were built as PostgreSQL MATERIALIZED
-- VIEWs. A MATERIALIZED VIEW has exactly one refresh primitive --
-- REFRESH MATERIALIZED VIEW -- which recomputes the entire query. There is no
-- native "refresh only period 32" for a matview, incremental or otherwise.
--
-- This migration replaces both with ordinary partitioned TABLEs (partitioned
-- on time_step, same partitioning already applied to core.transaction and
-- core.tx_feature in sql/05_partition_by_period.sql) plus a stored procedure,
-- analytics.refresh_period(p), that recomputes and swaps in exactly one
-- partition's worth of rows.
--
-- Why this is correct and not just convenient: the dataset's own structure
-- makes it correct. Every edge in core.tx_flow connects two transactions in
-- the SAME time_step -- confirmed at profiling (deck slide 5: "cross-period
-- edges 0") and relied on again in sql/04_analysis.sql's own comments
-- ("Edges never cross periods, and each period is its own connected
-- component"). Because of that, in-degree, out-degree, and one-hop illicit
-- exposure for a transaction in period p depend only on rows where
-- time_step = p. Recomputing period p never needs to touch, and can never
-- change, the stored rows for any other period. That is what makes a
-- per-partition refresh a correct incremental strategy here rather than an
-- approximation -- a dataset without this property (edges crossing periods)
-- would not support it without a bounded staleness window.
--
-- Downstream objects (vw_alert_queue, vw_dispersal_candidates,
-- vw_period_risk_profile, everything in sql/04_analysis.sql) are unchanged:
-- they SELECT FROM analytics.mv_tx_degree / analytics.mv_illicit_exposure by
-- name and have no idea whether the object behind that name is a
-- MATERIALIZED VIEW or a partitioned TABLE.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Drop and rebuild the whole derived layer, same rationale as the
--    partitioning migration: analytics is rebuildable by design.
-- ---------------------------------------------------------------------------
DROP SCHEMA IF EXISTS analytics CASCADE;
CREATE SCHEMA analytics;
COMMENT ON SCHEMA analytics IS 'Derived AML monitoring layer. Read-only to the analyst role.';

-- ---------------------------------------------------------------------------
-- 2. mv_tx_degree -- now a partitioned table, not a materialized view.
-- ---------------------------------------------------------------------------
CREATE TABLE analytics.mv_tx_degree (
    tx_id        BIGINT   NOT NULL,
    time_step    SMALLINT NOT NULL,
    class_id     SMALLINT NOT NULL,
    out_degree   BIGINT   NOT NULL,
    in_degree    BIGINT   NOT NULL,
    total_degree BIGINT   NOT NULL,
    CONSTRAINT pk_mv_tx_degree PRIMARY KEY (tx_id, time_step)
) PARTITION BY RANGE (time_step);

COMMENT ON TABLE analytics.mv_tx_degree IS
    'Per-transaction fan-in and fan-out. Partitioned table maintained by '
    'analytics.refresh_period(), not a MATERIALIZED VIEW -- see header of '
    'sql/06_incremental_refresh.sql for why a per-period refresh is correct '
    'for this dataset.';

DO $$
BEGIN
    FOR i IN 1..49 LOOP
        EXECUTE format(
            'CREATE TABLE analytics.mv_tx_degree_p%1$s PARTITION OF analytics.mv_tx_degree '
            'FOR VALUES FROM (%1$s) TO (%2$s)', i, i + 1);
    END LOOP;
END $$;

CREATE INDEX ix_mv_tx_degree_out ON analytics.mv_tx_degree (out_degree DESC);
CREATE INDEX ix_mv_tx_degree_in  ON analytics.mv_tx_degree (in_degree  DESC);

-- ---------------------------------------------------------------------------
-- 3. mv_illicit_exposure -- same treatment.
-- ---------------------------------------------------------------------------
CREATE TABLE analytics.mv_illicit_exposure (
    tx_id                    BIGINT   NOT NULL,
    time_step                SMALLINT NOT NULL,
    class_id                 SMALLINT NOT NULL,
    illicit_neighbours       BIGINT   NOT NULL,
    licit_neighbours         BIGINT   NOT NULL,
    unknown_neighbours       BIGINT   NOT NULL,
    total_neighbours         BIGINT   NOT NULL,
    illicit_neighbour_ratio  NUMERIC,
    CONSTRAINT pk_mv_illicit_exposure PRIMARY KEY (tx_id, time_step)
) PARTITION BY RANGE (time_step);

COMMENT ON TABLE analytics.mv_illicit_exposure IS
    'One-hop counterparty exposure. Partitioned table maintained by '
    'analytics.refresh_period(), not a MATERIALIZED VIEW.';

DO $$
BEGIN
    FOR i IN 1..49 LOOP
        EXECUTE format(
            'CREATE TABLE analytics.mv_illicit_exposure_p%1$s PARTITION OF analytics.mv_illicit_exposure '
            'FOR VALUES FROM (%1$s) TO (%2$s)', i, i + 1);
    END LOOP;
END $$;

CREATE INDEX ix_mv_illicit_exposure_ratio
    ON analytics.mv_illicit_exposure (illicit_neighbour_ratio DESC)
    WHERE illicit_neighbours > 0;

-- ---------------------------------------------------------------------------
-- 4. The incremental refresh procedure. This is the actual deliverable for
--    this item: everything above is just the table shape it needs to exist.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE analytics.refresh_period(p_time_step SMALLINT)
LANGUAGE plpgsql AS $$
BEGIN
    -- Degree. TRUNCATE the one partition rather than DELETE: no WAL-logged
    -- row-by-row delete, no need for a subsequent VACUUM, and it is safe
    -- specifically because it targets a single partition, not the whole
    -- table.
    EXECUTE format('TRUNCATE analytics.mv_tx_degree_p%s', p_time_step);

    INSERT INTO analytics.mv_tx_degree
        (tx_id, time_step, class_id, out_degree, in_degree, total_degree)
    SELECT
        t.tx_id, t.time_step, t.class_id,
        COALESCE(o.out_degree, 0),
        COALESCE(i.in_degree, 0),
        COALESCE(o.out_degree, 0) + COALESCE(i.in_degree, 0)
    FROM core.transaction t
    LEFT JOIN (
        SELECT f.src_tx_id AS tx_id, COUNT(*) AS out_degree
        FROM core.tx_flow f
        JOIN core.transaction s ON s.tx_id = f.src_tx_id
        WHERE s.time_step = p_time_step
        GROUP BY f.src_tx_id
    ) o ON o.tx_id = t.tx_id
    LEFT JOIN (
        SELECT f.dst_tx_id AS tx_id, COUNT(*) AS in_degree
        FROM core.tx_flow f
        JOIN core.transaction d ON d.tx_id = f.dst_tx_id
        WHERE d.time_step = p_time_step
        GROUP BY f.dst_tx_id
    ) i ON i.tx_id = t.tx_id
    WHERE t.time_step = p_time_step;

    -- Illicit exposure. Undirected one-hop neighbours, restricted to this
    -- period on both sides of the join -- correct because no edge in
    -- core.tx_flow connects two different periods.
    EXECUTE format('TRUNCATE analytics.mv_illicit_exposure_p%s', p_time_step);

    INSERT INTO analytics.mv_illicit_exposure
        (tx_id, time_step, class_id, illicit_neighbours, licit_neighbours,
         unknown_neighbours, total_neighbours, illicit_neighbour_ratio)
    WITH undirected AS (
        SELECT f.src_tx_id AS tx_id, f.dst_tx_id AS neighbour_id
        FROM core.tx_flow f
        JOIN core.transaction s ON s.tx_id = f.src_tx_id
        WHERE s.time_step = p_time_step
        UNION ALL
        SELECT f.dst_tx_id AS tx_id, f.src_tx_id AS neighbour_id
        FROM core.tx_flow f
        JOIN core.transaction d ON d.tx_id = f.dst_tx_id
        WHERE d.time_step = p_time_step
    )
    SELECT
        t.tx_id, t.time_step, t.class_id,
        COUNT(*) FILTER (WHERE n.class_id = 1),
        COUNT(*) FILTER (WHERE n.class_id = 2),
        COUNT(*) FILTER (WHERE n.class_id = 3),
        COUNT(u.neighbour_id),
        ROUND(
            COUNT(*) FILTER (WHERE n.class_id = 1)::NUMERIC
            / NULLIF(COUNT(u.neighbour_id), 0), 4
        )
    FROM core.transaction t
    LEFT JOIN undirected u ON u.tx_id = t.tx_id
    LEFT JOIN core.transaction n ON n.tx_id = u.neighbour_id
    WHERE t.time_step = p_time_step
    GROUP BY t.tx_id, t.time_step, t.class_id;
END;
$$;

COMMENT ON PROCEDURE analytics.refresh_period(SMALLINT) IS
    'Incremental refresh: recomputes mv_tx_degree and mv_illicit_exposure for '
    'exactly one period. Correct because no edge in core.tx_flow crosses a '
    'time_step boundary, so a period''s degree and exposure figures cannot be '
    'affected by data outside that period. Cost is O(period size), not '
    'O(graph size) -- see the timing comparison run after this script.';

CREATE OR REPLACE PROCEDURE analytics.refresh_all()
LANGUAGE plpgsql AS $$
BEGIN
    FOR i IN 1..49 LOOP
        CALL analytics.refresh_period(i::SMALLINT);
    END LOOP;
END;
$$;

COMMENT ON PROCEDURE analytics.refresh_all() IS
    'Full rebuild, expressed as 49 calls to refresh_period(). Exists to prove '
    'the incremental path and the full-rebuild path are the same code -- a '
    'full rebuild is not a special case, it is 49 ordinary incremental '
    'refreshes.';

-- ---------------------------------------------------------------------------
-- 5. Populate every period once (equivalent to the old REFRESH MATERIALIZED
--    VIEW, expressed as the same procedure that incremental callers use).
-- ---------------------------------------------------------------------------
CALL analytics.refresh_all();

COMMIT;

-- ---------------------------------------------------------------------------
-- Downstream views (vw_period_risk_profile, vw_dispersal_candidates,
-- trace_illicit_provenance, vw_alert_queue) and the whole analysis layer
-- (sql/04_analysis.sql) are unchanged and are re-applied after this script:
--
--   psql -d elliptic_aml -f sql/03_analytics_views_only.sql   (generated)
--   psql -d elliptic_aml -f sql/04_analysis.sql
-- ---------------------------------------------------------------------------
