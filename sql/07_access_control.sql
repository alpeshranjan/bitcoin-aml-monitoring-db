-- ============================================================================
-- ANLC-752 Course Project -- Unit 10, Item 4: Access control
--
-- Two roles, matching the two real jobs done against this database:
--
--   anlc752_analyst      -- read-only. Runs the monitoring queries in
--                            sql/03_analytics.sql / sql/04_analysis.sql and
--                            nothing else.
--   anlc752_etl_loader   -- the identity etl_load.py actually runs as.
--                            Read/write on staging, core, governance.
--
-- Every boundary below enforces a decision this project already made in
-- words, not a new one invented for this item:
--
--   - staging is denied to the analyst entirely. README already says
--     "Untyped landing zone ... Nothing downstream reads it." That sentence
--     was previously just true by convention; it is now true because the
--     grant does not exist.
--   - governance.etl_load_audit and governance.dq_check_result are granted
--     to the analyst. The project's standing argument is that a passing
--     named rule is stronger evidence than an assertion in a slide -- that
--     argument is worthless if the analyst who needs to check it can't.
--   - governance.rejected_row is different: it holds the raw, quarantined
--     payload of whatever failed a data quality rule, with no guarantee of
--     its shape or contents. The analyst's job is triage over conformed
--     data, not forensics over rejected raw rows, so this table gets a row-
--     level security policy that grants the loader role every row and
--     leaves the analyst with none -- table-level SELECT is granted (so the
--     denial is visibly a policy decision, not a missing permission) but
--     row-level security reduces the visible rows to zero.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Roles (idempotent -- safe to rerun)
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'anlc752_analyst') THEN
        CREATE ROLE anlc752_analyst LOGIN PASSWORD 'anlc752_analyst_demo';
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'anlc752_etl_loader') THEN
        CREATE ROLE anlc752_etl_loader LOGIN PASSWORD 'anlc752_etl_loader_demo';
    END IF;
END $$;

COMMENT ON ROLE anlc752_analyst IS
    'Read-only. core + analytics in full; governance limited to audit/DQ '
    'results, not rejected_row (see row-level security policy). No staging.';
COMMENT ON ROLE anlc752_etl_loader IS
    'The identity etl_load.py runs as. Read/write on staging, core, '
    'governance; owns rebuilding the analytics/analysis layers each run.';

-- ---------------------------------------------------------------------------
-- 2. Analyst -- read-only
-- ---------------------------------------------------------------------------
GRANT USAGE ON SCHEMA core, analytics, governance TO anlc752_analyst;

GRANT SELECT ON ALL TABLES IN SCHEMA core TO anlc752_analyst;
GRANT SELECT ON ALL TABLES IN SCHEMA analytics TO anlc752_analyst;
ALTER DEFAULT PRIVILEGES IN SCHEMA core      GRANT SELECT ON TABLES TO anlc752_analyst;
ALTER DEFAULT PRIVILEGES IN SCHEMA analytics GRANT SELECT ON TABLES TO anlc752_analyst;

GRANT SELECT ON governance.etl_load_audit, governance.dq_check_result TO anlc752_analyst;
GRANT SELECT ON governance.rejected_row TO anlc752_analyst;   -- see RLS below

-- No grants at all on staging -- default-deny, not an oversight.

-- ---------------------------------------------------------------------------
-- 3. ETL loader -- read/write on the pipeline's own schemas
-- ---------------------------------------------------------------------------
GRANT USAGE, CREATE ON SCHEMA staging, core, governance, analytics TO anlc752_etl_loader;

GRANT ALL ON ALL TABLES IN SCHEMA staging    TO anlc752_etl_loader;
GRANT ALL ON ALL TABLES IN SCHEMA core       TO anlc752_etl_loader;
GRANT ALL ON ALL TABLES IN SCHEMA governance TO anlc752_etl_loader;
GRANT ALL ON ALL TABLES IN SCHEMA analytics  TO anlc752_etl_loader;
GRANT ALL ON ALL SEQUENCES IN SCHEMA governance TO anlc752_etl_loader;

ALTER DEFAULT PRIVILEGES IN SCHEMA staging   GRANT ALL ON TABLES TO anlc752_etl_loader;
ALTER DEFAULT PRIVILEGES IN SCHEMA core      GRANT ALL ON TABLES TO anlc752_etl_loader;
ALTER DEFAULT PRIVILEGES IN SCHEMA governance GRANT ALL ON TABLES TO anlc752_etl_loader;
ALTER DEFAULT PRIVILEGES IN SCHEMA governance GRANT ALL ON SEQUENCES TO anlc752_etl_loader;

-- ---------------------------------------------------------------------------
-- 4. Row-level security on governance.rejected_row
-- ---------------------------------------------------------------------------
ALTER TABLE governance.rejected_row ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS loader_full_access ON governance.rejected_row;
CREATE POLICY loader_full_access ON governance.rejected_row
    FOR ALL TO anlc752_etl_loader
    USING (true) WITH CHECK (true);

-- No policy is defined for anlc752_analyst. With row-level security enabled
-- and no matching policy, PostgreSQL's default is deny: the analyst has
-- table-level SELECT (granted above) but every row is filtered out. This is
-- deliberately visible as a policy decision -- SELECT does not fail, it
-- returns zero rows -- rather than an opaque permission error.

COMMENT ON TABLE governance.rejected_row IS
    'Quarantine for rows failing transformation or integrity rules. Rejects are '
    'retained rather than dropped so that data loss is visible and auditable. '
    'Row-level security restricts visibility to anlc752_etl_loader; '
    'anlc752_analyst holds table-level SELECT but sees zero rows by policy, '
    'since a rejected raw payload carries no guarantee of its shape or content.';
