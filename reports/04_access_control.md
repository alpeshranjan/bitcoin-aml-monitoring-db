# Access Control

Run live against `elliptic_aml` on PostgreSQL 18.4, on 2026-08-07.

## Design

Two roles, matching the two real jobs done against this database — an analyst running the
monitoring queries in `sql/03_analytics.sql`/`sql/04_analysis.sql`, and the ETL process itself
(`etl/etl_load.py`).

| Schema | `anlc752_analyst` | `anlc752_etl_loader` |
|---|---|---|
| `staging` | no access | full DML |
| `core` | read-only | full DML |
| `analytics` | read-only | full DML (rebuilds it each run) |
| `governance.etl_load_audit`, `dq_check_result` | read-only | full DML |
| `governance.rejected_row` | **0 rows via RLS** | full DML |

Every boundary enforces a decision this project already stated in words:

- **`staging` denied entirely.** The README already says "Untyped landing zone ... Nothing
  downstream reads it." That was previously true by convention; it is now true because the
  grant does not exist.
- **`etl_load_audit`/`dq_check_result` granted.** The project's standing argument — a passing
  named rule is stronger evidence than an assertion in a slide — is worthless if the person
  who needs to check it can't query the table.
- **`rejected_row` restricted by row-level security, not a plain `REVOKE`.** This table holds
  the raw, quarantined payload of whatever failed a data quality rule, with no guarantee of
  its shape or contents. Table-level `SELECT` is granted to the analyst deliberately, so the
  restriction is visibly a policy decision (query succeeds, returns zero rows) rather than an
  opaque permission error.

## Live proof

```
--- as anlc752_analyst ---
core_transaction_visible   203769
dq_results_visible              9
rejected_rows_visible           0

attempting staging (should be denied):
ERROR:  permission denied for schema staging

--- as anlc752_etl_loader: insert a test rejected row ---
INSERT 0 1
rejected_rows_visible_to_loader   1

--- back as anlc752_analyst: same table, after the insert ---
rejected_rows_visible_to_analyst   0
```

The last two lines are the actual test: the loader inserted a row and could see it; the
analyst, querying the identical table seconds later, still saw zero. That rules out "the table
happened to be empty" as an explanation — the row exists, and row-level security is what's
hiding it.

## Reproducing this run

```bash
psql -d elliptic_aml -f sql/07_access_control.sql

psql -d elliptic_aml << 'EOF'
SET ROLE anlc752_analyst;
SELECT count(*) FROM core.transaction;
SELECT count(*) FROM governance.dq_check_result;
SELECT count(*) FROM governance.rejected_row;
SELECT count(*) FROM staging.txs_classes;   -- expect: permission denied
RESET ROLE;
EOF
```

## What this item does not cover

Both roles are granted `CREATE` on `analytics` so `anlc752_etl_loader` can rebuild the
analytics/analysis layers, matching what `etl_load.py` does today. In a larger deployment that
DDL step would likely be its own migration identity, separate from the DML-only loader that
runs each incremental load — a further separation of duties this project's scale doesn't
currently require but would be the next cut if the pipeline grew a human-reviewed migration
step.
