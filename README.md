# ANLC-752 Course Project — Bitcoin AML Monitoring Database

Relational database and ETL pipeline for the Elliptic Data Set, supporting identification and monitoring of Bitcoin transaction patterns associated with illicit activity.

**Platform:** PostgreSQL 14+ · Python 3.10+ · `psycopg2`

---

## Read this first

The pipeline has been **executed and validated end to end against the authentic
Elliptic Data Set** — all three files, full row count, no synthetic input. Every
figure in this repository and in `validation_run_log.txt` was measured on that run.

`etl/make_test_fixtures.py` remains in the tree as a testing utility. It is not
used by the load and produces no project data.

---

## Setup

**1. Obtain the data.**

```bash
mkdir -p data
# https://www.kaggle.com/datasets/ellipticco/elliptic-data-set
# Place all three CSVs in ./data/
```

Either naming convention works — the Kaggle `elliptic_txs_*.csv` files or the Elliptic++ `txs_*.csv` files.

**2. Create the database.**

```bash
createdb elliptic_aml
export DSN="postgresql://localhost/elliptic_aml"
psql "$DSN" -f sql/01_schema.sql
```

**3. Load.**

```bash
pip install psycopg2-binary numpy
python3 etl/etl_load.py --data-dir ./data --dsn "$DSN"
```

The run extracts to staging, evaluates every data quality rule, loads `core`, then
builds indexes, the analytics layer and the analysis layer. It is a single
transaction: if any ERROR-severity rule fails, nothing is committed.

The load is **idempotent**. Re-running it against an already-populated database
truncates and rebuilds rather than failing on a primary key violation, so a
repeat run produces the same database as a first run.

**4. Apply the schema migrations** (optional — the database is complete and
queryable without them; they add partitioning, incremental refresh and roles).

```bash
psql "$DSN" -f sql/05_partition_by_period.sql
psql "$DSN" -f sql/02_indexes.sql
psql "$DSN" -f sql/03_analytics.sql
psql "$DSN" -f sql/04_analysis.sql

psql "$DSN" -f sql/06_incremental_refresh.sql
psql "$DSN" -f sql/03_analytics_views_only.sql
psql "$DSN" -f sql/04_analysis.sql

psql "$DSN" -f sql/07_access_control.sql
python3 etl/gen_data_dictionary.py --dsn "$DSN"    # dictionary reflects the new shape
```

---

## Layout

```
sql/01_schema.sql       schemas, tables, constraints, comments  (generated)
sql/02_indexes.sql      indexes and extended statistics
sql/03_analytics.sql    AML monitoring views, matviews, provenance function
sql/04_analysis.sql     feature screening, predictor strength, analysis matrix
                        (04 depends on 03; apply them as a pair, in order)

                        -- schema migrations, applied after the load, in order --
sql/05_partition_by_period.sql   range-partitions core.transaction, core.tx_feature
sql/06_incremental_refresh.sql   the two analytics matviews become partitioned tables
                        maintained by analytics.refresh_period()
sql/03_analytics_views_only.sql  the unchanged 03 views, reapplied after 06
sql/07_access_control.sql        roles, grants, row-level security

etl/gen_schema.py       emits 01_schema.sql — edit this, not the SQL
etl/gen_data_dictionary.py  emits docs/data_dictionary.md from the live catalog
etl/etl_load.py         the pipeline
etl/fit_and_evaluate.py     fits/evaluates a model on vw_analysis_matrix
etl/make_test_fixtures.py   fixture generator (testing only)
docs/data_source_summary.md   dataset summary and citations
docs/data_dictionary.md       table and column reference
reports/                write-ups — start with reports/01_overview.md
```

`sql/01_schema.sql` and `docs/data_dictionary.md` are both generated — the schema from
`gen_schema.py`, the dictionary read back out of the catalog after a load, so neither can
drift from what was actually built. The feature table is 165 columns wide and those columns appear in the core table, the staging table and the COPY column list; deriving all three from one constant in `gen_schema.py` removes the possibility of drift. Edit the generator and re-run it.

---

## Schema

Four schemas, one responsibility each.

**`staging`** — text-typed landing zone, unlogged, truncated after each run. Nothing is cast on the way in, so a malformed value fails a named quality rule that can be reported rather than an implicit cast inside `COPY` that surfaces as an opaque error.

**`core`** — the conformed model.

| Table | Grain | Notes |
|---|---|---|
| `dim_class` | 1 row per class | `is_labelled` separates "unknown" from a real outcome |
| `dim_time_step` | 1 row per period | 49 rows, CHECK-constrained |
| `dim_feature` | 1 row per feature | Carries the obfuscation caveat as data |
| `transaction` | 1 row per transaction | 203,769 rows |
| `tx_flow` | 1 row per directed edge | Composite PK, no self-loops. FKs to `transaction` dropped when `transaction` was partitioned — see below |
| `tx_feature` | 1 row per transaction | Wide, 165 feature columns, 1:1 with `transaction`. Carries `time_step` since partitioning |

`tx_feature` is wide rather than entity-attribute-value. EAV was considered and rejected: 203,769 × 165 would produce ~33.6M rows and force a pivot on every analytical query, in exchange for flexibility a fixed, non-sparse feature set does not need.

**Since `sql/05_partition_by_period.sql`,** `transaction` and `tx_feature` are range-partitioned on `time_step` (49 partitions each). Two consequences are worth stating plainly rather than leaving to be discovered: a partitioned table's primary key must contain the partition key, so `transaction`'s PK is now `(tx_id, time_step)` and `tx_feature` carries `time_step` for that reason alone; and because PostgreSQL cannot enforce uniqueness on `tx_id` alone across that partitioning, `tx_flow`'s foreign keys to `transaction` were dropped. Endpoint referential integrity is still enforced — by the `edgelist_endpoints_resolve` rule at load time, recorded in `governance.dq_check_result`, which was already the mechanism actually checking it.

**`analytics`** — the derived monitoring layer, each object mapped to a laundering typology.

| Object | Typology |
|---|---|
| `mv_tx_degree` | fan-in / fan-out shape |
| `mv_illicit_exposure` | guilt by association (one-hop) |
| `refresh_period(p)` | rebuilds the two objects above for one period only |
| `vw_period_risk_profile` | temporal concentration |
| `vw_dispersal_candidates` | structuring / smurfing |
| `trace_illicit_provenance()` | layering (bounded recursive walk) |
| `vw_alert_queue` | composite investigator triage queue |

**Analysis layer** (`sql/04_analysis.sql`) — preparation for statistical modelling.

| Object | Purpose |
|---|---|
| `mv_feature_separation` | Cohen's d per feature across the labelled classes |
| `vw_discriminative_features` | features ranked by effect size |
| `vw_graph_predictor_strength` | point-biserial r for each graph-derived predictor |
| `vw_analysis_matrix` | analysis-ready extract with temporal train/test split |
| `vw_split_balance` | class balance either side of the split |

**`governance`** — `etl_load_audit` (one row per file-to-table load, with a SHA-256 of the source artefact), `dq_check_result`, and `rejected_row` for quarantined rows.

---

## Validation performed

Two separate runs are documented here, on different machines, and they are kept
distinct rather than merged into one set of numbers.

**Run 1 — the original Unit 8 load.** Recorded in `validation_run_log.txt`, which
states the exact server build it ran against. That file is the artefact of that
run and has been left as generated; its timings and storage figures describe that
machine, not this one.

Full terminal output of run 2 — the nine rule results, loaded row counts, the
three deck findings re-measured, and every migration check — is in
`validation_run_log_rerun.md`.

**Run 2 — the second run, verified live.** PostgreSQL 18.4 (Postgres.app) on
aarch64-apple-darwin23.6.0. 203,769 transactions, 234,355 edges, 165 feature
columns, 49 time steps — identical counts to run 1, and identical class
distribution and analysis-layer figures. Full run, extract through the analysis
layer, committed in 17.3 s.

Storage, measured after the partitioning migration:

| Object | Size |
|---|---|
| Whole database | 471 MB |
| `core.tx_feature` (49 partitions) | 329 MB |
| `analytics.mv_tx_degree` (49 partitions) | 29 MB |
| `analytics.mv_illicit_exposure` (49 partitions) | 28 MB |
| `core.transaction` (49 partitions) | 22 MB |

`core.tx_feature` is larger than the pre-partitioning figure reported in run 1.
Partitioning is not free: 49 separate relations carry per-partition overhead, the
table gained a `time_step` column, and its primary key became composite. The two
runs were measured on different machines and server versions, so this should be
read as "partitioning costs storage," not as a precise measurement of how much.

One practical note: `pg_total_relation_size()` on a partitioned parent returns
only the parent's own (empty) storage. The figures above sum the partitions via
`pg_inherits`; querying the parent directly reports 0 bytes.

**Quality rules.** All nine passed on clean input. The null check covers all 165
feature columns, not a sample. Negative test: three defects were injected into a copy of the input (a duplicate `txId`, a `time_step` of 99, and an edge referencing a non-existent transaction). All three were caught by their respective rules, the run aborted, and `core.transaction` was confirmed still empty — while the failures persisted to `governance.dq_check_result` on a separate connection, so the abort is auditable rather than silent.

**Index usage.** Confirmed with `EXPLAIN (ANALYZE, BUFFERS)`:

Before partitioning (run 1), the period-scoped query used the partial index
`ix_transaction_labelled` and returned in 0.39 ms; backward edge traversal used
`ix_tx_flow_dst` in under 1 ms. After partitioning, the same period query prunes
to a single partition first:

```
SELECT tx_id FROM core.transaction WHERE time_step = 32 AND class_id = 1;

Bitmap Heap Scan on transaction_p32 transaction  (actual time=0.273..0.448 rows=342 loops=1)
  ->  Bitmap Index Scan on transaction_p32_time_step_class_id_idx
        Buffers: shared read=2
  Buffers: shared read=27
Execution Time: 0.671 ms
```

Only `transaction_p32` appears in the plan; the other 48 partitions are pruned
before execution. Indexes declared in `02_indexes.sql` propagate to each
partition, which is why the plan names a per-partition child index rather than
the name declared in that file. The partial index on labelled rows only is still
roughly a quarter the size of the equivalent full index, since 77% of rows are
class 3.

**Incremental refresh.** `analytics.refresh_all()` (49 periods) runs in 4,284 ms;
`analytics.refresh_period(32)` in 109 ms.

---

## Course deliverable mapping

The repository is organised as an engineering project rather than by course unit. For
assessment, the required items map as follows.

| Required item | Where it lives |
|---|---|
| Data source evaluation | `docs/data_source_summary.md` |
| Schema, ETL, governance, monitoring layer | `sql/01`–`04`, `etl/etl_load.py`, `validation_run_log.txt` |
| Milestone presentation | `deck/` |
| Fit and evaluate a model | `reports/02_model_evaluation.md`, `etl/fit_and_evaluate.py` |
| Partition by period | `reports/03_partitioning_and_refresh.md`, `sql/05_partition_by_period.sql` |
| Incremental refresh strategy | `reports/03_partitioning_and_refresh.md`, `sql/06_incremental_refresh.sql` |
| Access control | `reports/04_access_control.md`, `sql/07_access_control.sql` |
| Actor layer | not attempted — see scope boundaries below |

---

## Known scope boundaries

- Edges connect **transactions, not wallets**. No customer or counterparty dimension can be derived from this data. Extending to Elliptic++'s 822k-address actor layer remains future scope: it requires the Elliptic++ address-level files (`wallets_features.csv`, `AddrTx_edgelist.csv` and companions), which are a separate release from the three files this project loads and were not available here.
- Labels are binary. Money laundering is not separable from other illicit categories.
- `vw_alert_queue` weights are a transparent heuristic, not a fitted model. The project scope is the structure that makes such scoring queryable.
- `sql/04_analysis.sql` prepares and screens; it does not fit a model. Fitting is
  done separately in `etl/fit_and_evaluate.py` rather than in SQL, and
  is reported in `reports/02_model_evaluation.md`. The headline result is that
  a fitted logistic regression beats the existing `illicit_neighbour_ratio`
  heuristic at review budgets of 5% and above, but not at the top 1%.
- The model in `fit_and_evaluate.py` is a logistic regression over eight
  graph-derived predictors. It is **not** benchmarked against the published
  results on this dataset (Weber et al. use gradient-boosted and graph
  convolutional models over all 165 features), so it should be read as evidence
  that the analysis matrix is usable, not as a competitive result.
