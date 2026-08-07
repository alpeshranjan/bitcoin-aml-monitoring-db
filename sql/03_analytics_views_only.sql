-- ============================================================================
-- ANLC-752 Course Project -- Analytics layer, views-only pass
--
-- Run AFTER sql/06_incremental_refresh.sql. That script already created and
-- populated analytics.mv_tx_degree and analytics.mv_illicit_exposure as
-- partitioned tables. This file re-applies everything else from
-- sql/03_analytics.sql UNCHANGED -- these views SELECT FROM the two objects
-- above by name and do not care whether the object behind that name is a
-- MATERIALIZED VIEW or a partitioned TABLE.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Period risk profile -- typology: temporal concentration
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
-- Dispersal candidates -- typology: structuring / smurfing
-- ---------------------------------------------------------------------------

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
-- Fund provenance tracing -- typology: layering
-- ---------------------------------------------------------------------------

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
-- Composite alert queue
-- ---------------------------------------------------------------------------

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
          2.0 * LEAST(e.illicit_neighbours, 5)
        + 3.0 * COALESCE(e.illicit_neighbour_ratio, 0)
        + 1.0 * LEAST(d.out_degree / 25.0, 2.0)
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
