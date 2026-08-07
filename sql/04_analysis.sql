-- ============================================================================
-- ANLC-752 Course Project -- Analysis preparation layer
--
-- Everything above this file structures the data. This file uses that structure
-- to (a) screen which of the 165 obfuscated features separate the two labelled
-- classes, (b) measure the graph-derived predictors the database itself created,
-- and (c) emit the analysis-ready matrix a regression would be fitted on.
--
-- Every object here is built from SELECT / WHERE / JOIN / GROUP BY and standard
-- aggregate functions. No procedural code, no external statistics package.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. Feature screening -- which obfuscated features separate the classes
-- ---------------------------------------------------------------------------
-- core.tx_feature is stored wide (165 columns) because that is the right shape
-- for retrieval. Statistical screening wants the opposite shape: one row per
-- (transaction, feature). Rather than reverse the storage decision, this view
-- projects the wide table to long form ONLY for the 46,564 labelled rows --
-- 7.68M projected rows, versus the 33.6M an EAV core table would have imposed
-- permanently. The storage decision on slide 8 stands; this is a derived
-- projection with a bounded, stated cost.
--
-- Separation is measured as Cohen's d, the difference in class means expressed
-- in pooled standard deviations. d is used rather than a raw mean difference
-- because the features carry no units and no comparable scale, and rather than
-- a t-statistic because t grows with n and would rank all 165 as "significant"
-- at n = 46,564 while saying nothing about magnitude.

-- Re-runnable: dropped before creation so a repeat load rebuilds the layer
-- rather than failing on objects that already exist.
DROP VIEW IF EXISTS analytics.vw_split_balance;
DROP VIEW IF EXISTS analytics.vw_analysis_matrix;
DROP VIEW IF EXISTS analytics.vw_graph_predictor_strength;
DROP VIEW IF EXISTS analytics.vw_discriminative_features;
DROP MATERIALIZED VIEW IF EXISTS analytics.mv_feature_separation CASCADE;

CREATE MATERIALIZED VIEW analytics.mv_feature_separation AS
WITH labelled_long AS (
    SELECT
        t.class_id,
        kv.key                            AS column_name,
        kv.value::DOUBLE PRECISION        AS value
    FROM core.tx_feature f
    JOIN core.transaction t ON t.tx_id = f.tx_id
    CROSS JOIN LATERAL jsonb_each_text(to_jsonb(f) - 'tx_id') AS kv
    WHERE t.class_id IN (1, 2)
),
class_stats AS (
    SELECT
        column_name,
        COUNT(*)          FILTER (WHERE class_id = 1) AS n_illicit,
        COUNT(*)          FILTER (WHERE class_id = 2) AS n_licit,
        AVG(value)        FILTER (WHERE class_id = 1) AS mean_illicit,
        AVG(value)        FILTER (WHERE class_id = 2) AS mean_licit,
        STDDEV_SAMP(value) FILTER (WHERE class_id = 1) AS sd_illicit,
        STDDEV_SAMP(value) FILTER (WHERE class_id = 2) AS sd_licit
    FROM labelled_long
    GROUP BY column_name
)
SELECT
    s.column_name,
    d.feature_group,
    s.n_illicit,
    s.n_licit,
    ROUND(s.mean_illicit::NUMERIC, 4) AS mean_illicit,
    ROUND(s.mean_licit::NUMERIC,   4) AS mean_licit,
    ROUND(
        SQRT(
            ((s.n_illicit - 1) * POWER(s.sd_illicit, 2)
           + (s.n_licit   - 1) * POWER(s.sd_licit,   2))
            / NULLIF(s.n_illicit + s.n_licit - 2, 0)
        )::NUMERIC, 4
    ) AS pooled_sd,
    ROUND(
        (
            (s.mean_illicit - s.mean_licit)
            / NULLIF(
                SQRT(
                    ((s.n_illicit - 1) * POWER(s.sd_illicit, 2)
                   + (s.n_licit   - 1) * POWER(s.sd_licit,   2))
                    / NULLIF(s.n_illicit + s.n_licit - 2, 0)
                ), 0)
        )::NUMERIC, 4
    ) AS cohens_d
FROM class_stats s
JOIN core.dim_feature d ON d.column_name = s.column_name;

CREATE UNIQUE INDEX ix_mv_feature_separation_pk
    ON analytics.mv_feature_separation (column_name);

COMMENT ON MATERIALIZED VIEW analytics.mv_feature_separation IS
    'Per-feature class separation for the 165 obfuscated features, measured as '
    'Cohen''s d over the labelled subset. Materialised because the long-form '
    'projection costs roughly six seconds and every screening query reuses it.';


-- ---------------------------------------------------------------------------
-- 2. Screening result -- the features a model should be given
-- ---------------------------------------------------------------------------
-- Conventional reading of |d|: 0.2 small, 0.5 medium, 0.8 large. The threshold
-- here is 0.5 -- features below it are retained in core but carry little
-- univariate signal and are not the ones to defend in a write-up.

CREATE VIEW analytics.vw_discriminative_features AS
SELECT
    RANK() OVER (ORDER BY ABS(cohens_d) DESC) AS separation_rank,
    column_name,
    feature_group,
    mean_illicit,
    mean_licit,
    cohens_d,
    CASE
        WHEN ABS(cohens_d) >= 0.8 THEN 'large'
        WHEN ABS(cohens_d) >= 0.5 THEN 'medium'
        WHEN ABS(cohens_d) >= 0.2 THEN 'small'
        ELSE 'negligible'
    END AS effect_size
FROM analytics.mv_feature_separation
ORDER BY ABS(cohens_d) DESC;

COMMENT ON VIEW analytics.vw_discriminative_features IS
    'Features ranked by univariate class separation. Column names are obfuscated '
    'by the publisher, so a result here is stateable as "feature X separates the '
    'classes" and never as a claim about a real-world transaction attribute.';


-- ---------------------------------------------------------------------------
-- 3. Graph-derived predictors -- the interpretable ones
-- ---------------------------------------------------------------------------
-- These four predictors did not come with the dataset. They are produced by the
-- edge table and the analytics layer, which means -- unlike the 165 obfuscated
-- columns -- their meaning is known and a coefficient fitted on them is
-- interpretable. Association with the outcome is measured with corr(), the
-- point-biserial correlation when one variable is a 0/1 indicator.

CREATE VIEW analytics.vw_graph_predictor_strength AS
WITH labelled AS (
    SELECT
        (t.class_id = 1)::INT::DOUBLE PRECISION AS is_illicit,
        d.in_degree::DOUBLE PRECISION           AS in_degree,
        d.out_degree::DOUBLE PRECISION          AS out_degree,
        e.illicit_neighbours::DOUBLE PRECISION  AS illicit_neighbours,
        COALESCE(e.illicit_neighbour_ratio, 0)::DOUBLE PRECISION
                                                AS illicit_neighbour_ratio
    FROM core.transaction t
    JOIN analytics.mv_tx_degree        d ON d.tx_id = t.tx_id
    JOIN analytics.mv_illicit_exposure e ON e.tx_id = t.tx_id
    WHERE t.class_id IN (1, 2)
),
per_predictor AS (
    SELECT 'in_degree' AS predictor,
           CORR(is_illicit, in_degree)                          AS r,
           AVG(in_degree) FILTER (WHERE is_illicit = 1)         AS m_illicit,
           AVG(in_degree) FILTER (WHERE is_illicit = 0)         AS m_licit
    FROM labelled
    UNION ALL
    SELECT 'out_degree',
           CORR(is_illicit, out_degree),
           AVG(out_degree) FILTER (WHERE is_illicit = 1),
           AVG(out_degree) FILTER (WHERE is_illicit = 0)
    FROM labelled
    UNION ALL
    SELECT 'illicit_neighbours',
           CORR(is_illicit, illicit_neighbours),
           AVG(illicit_neighbours) FILTER (WHERE is_illicit = 1),
           AVG(illicit_neighbours) FILTER (WHERE is_illicit = 0)
    FROM labelled
    UNION ALL
    SELECT 'illicit_neighbour_ratio',
           CORR(is_illicit, illicit_neighbour_ratio),
           AVG(illicit_neighbour_ratio) FILTER (WHERE is_illicit = 1),
           AVG(illicit_neighbour_ratio) FILTER (WHERE is_illicit = 0)
    FROM labelled
)
SELECT
    predictor,
    ROUND(r::NUMERIC,         4) AS point_biserial_r,
    ROUND(m_illicit::NUMERIC, 3) AS mean_illicit,
    ROUND(m_licit::NUMERIC,   3) AS mean_licit
FROM per_predictor
ORDER BY ABS(r) DESC;


COMMENT ON VIEW analytics.vw_graph_predictor_strength IS
    'Association between each graph-derived predictor and the illicit outcome. '
    'These predictors are interpretable precisely because the database built '
    'them; the publisher''s 165 columns are not.';


-- ---------------------------------------------------------------------------
-- 4. Analysis-ready matrix
-- ---------------------------------------------------------------------------
-- The single table a regression is fitted on. Three things are settled here
-- rather than left to whoever runs the model:
--
--   target      class 3 is an absence of label, not a negative outcome, so it is
--               excluded rather than coerced to 0.
--   split       partitioned by time, not at random. The 49 steps are sequential
--               and edges never cross them; a random split would let a model
--               see the future of the same connected component it is scoring.
--               t <= 34 / t >= 35 is the split used in the published literature
--               on this dataset, which keeps results comparable.
--   predictors  graph-derived columns are named inline; the 165 obfuscated
--               columns join from core.tx_feature on tx_id when a model wants
--               them, so the matrix stays legible.

CREATE VIEW analytics.vw_analysis_matrix AS
SELECT
    t.tx_id,
    t.time_step,
    CASE WHEN t.time_step <= 34 THEN 'train' ELSE 'test' END AS split,
    (t.class_id = 1)::INT                        AS is_illicit,
    d.in_degree,
    d.out_degree,
    d.total_degree,
    e.illicit_neighbours,
    e.licit_neighbours,
    e.unknown_neighbours,
    e.total_neighbours,
    COALESCE(e.illicit_neighbour_ratio, 0)       AS illicit_neighbour_ratio
FROM core.transaction t
JOIN analytics.mv_tx_degree        d ON d.tx_id = t.tx_id
JOIN analytics.mv_illicit_exposure e ON e.tx_id = t.tx_id
WHERE t.class_id IN (1, 2);

COMMENT ON VIEW analytics.vw_analysis_matrix IS
    'Analysis-ready extract: labelled transactions only, binary target, graph '
    'predictors, and a temporal train/test split. Unlabelled rows are excluded '
    'rather than treated as negative.';


-- ---------------------------------------------------------------------------
-- 5. Split diagnostics
-- ---------------------------------------------------------------------------
-- A temporal split is only defensible if both sides are reported. The illicit
-- rate is not stable across the series, so the split is stated with its
-- imbalance visible rather than assumed benign.

CREATE VIEW analytics.vw_split_balance AS
SELECT
    split,
    MIN(time_step)                                   AS first_period,
    MAX(time_step)                                   AS last_period,
    COUNT(*)                                         AS n_labelled,
    SUM(is_illicit)                                  AS n_illicit,
    COUNT(*) - SUM(is_illicit)                       AS n_licit,
    ROUND(100.0 * SUM(is_illicit) / COUNT(*), 2)     AS pct_illicit
FROM analytics.vw_analysis_matrix
GROUP BY split
ORDER BY first_period;

COMMENT ON VIEW analytics.vw_split_balance IS
    'Class balance either side of the temporal split. Reported because the '
    'illicit rate collapses after period 42, so train and test are not drawn '
    'from the same regime -- a fact a model must be evaluated against, not one '
    'to be smoothed away by resampling.';
