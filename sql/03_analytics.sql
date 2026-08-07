-- ============================================================================
-- ANLC-752 Course Project -- Analytics layer
--
-- These objects are the answer to the research question: they are the structures
-- through which the relational model actually supports AML pattern monitoring.
-- Each maps to a recognised laundering typology, noted in its comment.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Graph degree metrics
-- ---------------------------------------------------------------------------
-- Materialised because in/out degree is recomputed by nearly every downstream
-- object, and the underlying edge table is append-only between loads.

-- Re-runnable: dropped before creation so a repeat load rebuilds the layer
-- rather than failing on objects that already exist.
--
-- COUPLING: sql/04_analysis.sql builds on mv_tx_degree and mv_illicit_exposure.
-- Dropping them here cascades to those dependants, so 03 and 04 are applied as a
-- pair and in that order. The pipeline does this automatically; applying this
-- file by hand requires re-applying 04 afterwards. The DO block below says so at
-- runtime rather than leaving the operator to notice objects missing later.
DROP VIEW IF EXISTS analytics.vw_alert_queue;
DROP VIEW IF EXISTS analytics.vw_dispersal_candidates;
DROP VIEW IF EXISTS analytics.vw_period_risk_profile;
DROP FUNCTION IF EXISTS analytics.trace_illicit_provenance(BIGINT, INTEGER);
DROP MATERIALIZED VIEW IF EXISTS analytics.mv_illicit_exposure CASCADE;
DROP MATERIALIZED VIEW IF EXISTS analytics.mv_tx_degree CASCADE;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_class
                WHERE relnamespace = 'analytics'::regnamespace
                  AND relname = 'vw_analysis_matrix') THEN
        RAISE NOTICE 'Analysis layer dropped by cascade -- re-apply sql/04_analysis.sql.';
    END IF;
END $$;

CREATE MATERIALIZED VIEW analytics.mv_tx_degree AS
SELECT
    t.tx_id,
    t.time_step,
    t.class_id,
    COALESCE(o.out_degree, 0) AS out_degree,
    COALESCE(i.in_degree,  0) AS in_degree,
    COALESCE(o.out_degree, 0) + COALESCE(i.in_degree, 0) AS total_degree
FROM core.transaction t
LEFT JOIN (
    SELECT src_tx_id AS tx_id, COUNT(*) AS out_degree
    FROM core.tx_flow GROUP BY src_tx_id
) o ON o.tx_id = t.tx_id
LEFT JOIN (
    SELECT dst_tx_id AS tx_id, COUNT(*) AS in_degree
    FROM core.tx_flow GROUP BY dst_tx_id
) i ON i.tx_id = t.tx_id;

CREATE UNIQUE INDEX ix_mv_tx_degree_pk ON analytics.mv_tx_degree (tx_id);
CREATE INDEX ix_mv_tx_degree_out ON analytics.mv_tx_degree (out_degree DESC);
CREATE INDEX ix_mv_tx_degree_in  ON analytics.mv_tx_degree (in_degree  DESC);

COMMENT ON MATERIALIZED VIEW analytics.mv_tx_degree IS
    'Per-transaction fan-in and fan-out. High out-degree with low in-degree is the '
    'structural signature of dispersal (smurfing); the inverse indicates consolidation.';


-- ---------------------------------------------------------------------------
-- 2. Illicit exposure -- typology: guilt by association
-- ---------------------------------------------------------------------------
-- One-hop exposure of every transaction to KNOWN illicit counterparties.
-- Deliberately counts only class_id = 1: unknown neighbours are reported
-- separately rather than folded into the risk count, so that absence of a label
-- is never silently treated as evidence of innocence.

CREATE MATERIALIZED VIEW analytics.mv_illicit_exposure AS
WITH undirected AS (
    SELECT src_tx_id AS tx_id, dst_tx_id AS neighbour_id FROM core.tx_flow
    UNION ALL
    SELECT dst_tx_id AS tx_id, src_tx_id AS neighbour_id FROM core.tx_flow
)
SELECT
    t.tx_id,
    t.time_step,
    t.class_id,
    COUNT(*) FILTER (WHERE n.class_id = 1) AS illicit_neighbours,
    COUNT(*) FILTER (WHERE n.class_id = 2) AS licit_neighbours,
    COUNT(*) FILTER (WHERE n.class_id = 3) AS unknown_neighbours,
    COUNT(u.neighbour_id)                  AS total_neighbours,
    ROUND(
        COUNT(*) FILTER (WHERE n.class_id = 1)::NUMERIC
        / NULLIF(COUNT(u.neighbour_id), 0), 4
    ) AS illicit_neighbour_ratio
FROM core.transaction t
LEFT JOIN undirected       u ON u.tx_id = t.tx_id
LEFT JOIN core.transaction n ON n.tx_id = u.neighbour_id
GROUP BY t.tx_id, t.time_step, t.class_id;

CREATE UNIQUE INDEX ix_mv_illicit_exposure_pk ON analytics.mv_illicit_exposure (tx_id);
CREATE INDEX ix_mv_illicit_exposure_ratio
    ON analytics.mv_illicit_exposure (illicit_neighbour_ratio DESC)
    WHERE illicit_neighbours > 0;

COMMENT ON MATERIALIZED VIEW analytics.mv_illicit_exposure IS
    'One-hop counterparty exposure. Unknown neighbours are counted in their own '
    'column and never merged into the illicit count.';


-- ---------------------------------------------------------------------------
-- 3. Period risk profile -- typology: temporal concentration
-- ---------------------------------------------------------------------------

CREATE VIEW analytics.vw_period_risk_profile AS
SELECT
    ts.time_step,
    COUNT(t.tx_id)                                   AS total_transactions,
    COUNT(*) FILTER (WHERE t.class_id = 1)           AS illicit_count,
    COUNT(*) FILTER (WHERE t.class_id = 2)           AS licit_count,
    COUNT(*) FILTER (WHERE t.class_id = 3)           AS unlabelled_count,
    ROUND(
        COUNT(*) FILTER (WHERE t.class_id = 1)::NUMERIC
        / NULLIF(COUNT(*) FILTER (WHERE t.class_id IN (1, 2)), 0), 4
    ) AS illicit_rate_of_labelled
FROM core.dim_time_step ts
LEFT JOIN core.transaction t ON t.time_step = ts.time_step
GROUP BY ts.time_step
ORDER BY ts.time_step;

COMMENT ON VIEW analytics.vw_period_risk_profile IS
    'Illicit rate per period, denominated on labelled transactions only. A step '
    'change in this series is the database-level signal of a market-wide event '
    'such as a darknet marketplace takedown.';


-- ---------------------------------------------------------------------------
-- 4. Dispersal candidates -- typology: structuring / smurfing
-- ---------------------------------------------------------------------------
-- Thresholds are expressed against the distribution rather than hard-coded, so
-- the rule does not silently stop firing if a future load changes scale.

CREATE VIEW analytics.vw_dispersal_candidates AS
WITH bounds AS (
    SELECT PERCENTILE_CONT(0.999) WITHIN GROUP (ORDER BY out_degree) AS out_p999
    FROM analytics.mv_tx_degree
)
SELECT
    d.tx_id,
    d.time_step,
    c.class_code,
    d.in_degree,
    d.out_degree,
    e.illicit_neighbours,
    b.out_p999 AS threshold_applied
FROM analytics.mv_tx_degree d
CROSS JOIN bounds b
JOIN core.dim_class c            ON c.class_id = d.class_id
LEFT JOIN analytics.mv_illicit_exposure e ON e.tx_id = d.tx_id
WHERE d.out_degree >= b.out_p999
  AND d.out_degree > d.in_degree
ORDER BY d.out_degree DESC;

COMMENT ON VIEW analytics.vw_dispersal_candidates IS
    'Transactions in the top 0.1% of fan-out that disperse to more destinations '
    'than they received from -- the placement/layering signature.';


-- ---------------------------------------------------------------------------
-- 5. Fund provenance tracing -- typology: layering
-- ---------------------------------------------------------------------------
-- Recursive backward walk from a transaction of interest to any illicit
-- ancestor within a bounded depth. Cycle protection is via the path array:
-- Bitcoin transaction graphs are acyclic in principle, but the constraint is
-- enforced rather than assumed.

CREATE OR REPLACE FUNCTION analytics.trace_illicit_provenance(
    p_tx_id     BIGINT,
    p_max_depth INTEGER DEFAULT 4
)
RETURNS TABLE (
    depth            INTEGER,
    ancestor_tx_id   BIGINT,
    ancestor_class   VARCHAR(16),
    path             BIGINT[]
)
LANGUAGE SQL STABLE AS $$
    WITH RECURSIVE walk AS (
        SELECT 0 AS depth,
               p_tx_id AS ancestor_tx_id,
               ARRAY[p_tx_id] AS path
        UNION ALL
        SELECT w.depth + 1,
               f.src_tx_id,
               w.path || f.src_tx_id
        FROM walk w
        JOIN core.tx_flow f ON f.dst_tx_id = w.ancestor_tx_id
        WHERE w.depth < p_max_depth
          AND NOT f.src_tx_id = ANY(w.path)
    )
    SELECT w.depth,
           w.ancestor_tx_id,
           c.class_code,
           w.path
    FROM walk w
    JOIN core.transaction t ON t.tx_id = w.ancestor_tx_id
    JOIN core.dim_class   c ON c.class_id = t.class_id
    WHERE w.depth > 0
    ORDER BY w.depth, w.ancestor_tx_id;
$$;

COMMENT ON FUNCTION analytics.trace_illicit_provenance IS
    'Bounded recursive upstream trace. Depth is a required parameter because an '
    'unbounded walk on a 234k-edge graph is not a safe interactive query.';


-- ---------------------------------------------------------------------------
-- 6. Composite alert queue
-- ---------------------------------------------------------------------------
-- The operational surface an investigator would actually work from. Ranks
-- unlabelled transactions only: labelled ones need no triage.

CREATE VIEW analytics.vw_alert_queue AS
SELECT
    e.tx_id,
    e.time_step,
    d.in_degree,
    d.out_degree,
    e.illicit_neighbours,
    e.total_neighbours,
    e.illicit_neighbour_ratio,
    ROUND(
          2.0 * LEAST(e.illicit_neighbours, 5)                     -- direct exposure
        + 3.0 * COALESCE(e.illicit_neighbour_ratio, 0)             -- exposure concentration
        + 1.0 * LEAST(d.out_degree / 25.0, 2.0)                    -- dispersal shape
    , 3) AS risk_score
FROM analytics.mv_illicit_exposure e
JOIN analytics.mv_tx_degree d ON d.tx_id = e.tx_id
WHERE e.class_id = 3
  AND e.illicit_neighbours > 0
ORDER BY risk_score DESC;

COMMENT ON VIEW analytics.vw_alert_queue IS
    'Triage queue over unlabelled transactions with at least one known illicit '
    'counterparty. The weights are a transparent heuristic, not a fitted model -- '
    'the project scope is the data structure that makes such scoring queryable, '
    'not the scoring function itself.';
