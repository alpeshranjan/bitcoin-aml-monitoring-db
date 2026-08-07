-- ============================================================================
-- ANLC-752 Course Project -- Indexes
--
-- Created AFTER bulk load, not before: building a B-tree incrementally during a
-- 200k/234k row COPY is materially slower than building it once at the end.
--
-- Each index below is justified by a specific access path in the monitoring
-- workload. Indexes with no named consumer were not created.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- core.transaction
-- ---------------------------------------------------------------------------

-- Access path: "show illicit activity in period N" -- the primary alerting
-- filter. Leading column is time_step because every monitoring query is bounded
-- by period first, then narrowed by class.
CREATE INDEX IF NOT EXISTS ix_transaction_timestep_class
    ON core.transaction (time_step, class_id);

-- Access path: labelled-only extracts. Partial index -- roughly 23% of rows
-- carry a label, so excluding class 3 keeps the index about a quarter the size
-- of the equivalent full index.
CREATE INDEX IF NOT EXISTS ix_transaction_labelled
    ON core.transaction (class_id, time_step)
    WHERE class_id IN (1, 2);


-- ---------------------------------------------------------------------------
-- core.tx_flow
-- ---------------------------------------------------------------------------

-- The primary key (src_tx_id, dst_tx_id) already serves forward traversal
-- ("what did this transaction fund?"). Backward traversal ("what funded this
-- transaction?") has no usable prefix in that key, so it needs its own index.
-- Without it, tracing fund provenance degrades to a sequential scan of the
-- entire edge table on every hop.
CREATE INDEX IF NOT EXISTS ix_tx_flow_dst
    ON core.tx_flow (dst_tx_id, src_tx_id);


-- ---------------------------------------------------------------------------
-- Statistics
-- ---------------------------------------------------------------------------

-- time_step and class_id are strongly correlated (illicit share varies sharply
-- across periods, and one period is dominated by a single market shutdown).
-- The planner assumes independence by default and badly underestimates the
-- selectivity of the combined predicate. Extended statistics correct this.
DROP STATISTICS IF EXISTS st_transaction_timestep_class;
CREATE STATISTICS st_transaction_timestep_class (dependencies, ndistinct)
    ON time_step, class_id
    FROM core.transaction;

ANALYZE core.transaction;
ANALYZE core.tx_flow;
ANALYZE core.tx_feature;
