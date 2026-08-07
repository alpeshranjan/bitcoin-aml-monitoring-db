# Project Report — Overview

Everything below was run live against `elliptic_aml` on PostgreSQL 18.4, loaded from the
authentic Elliptic Data Set (203,769 transactions / 234,355 edges), on 2026-08-07. Nothing
here is a projection from the Unit 8 numbers — each result was produced by a command run on
the actual database and captured as it happened.

## Scope and status

| # | Item | Status |
|---|---|---|
| 1 | Fit and evaluate | **Done** — see `02_model_evaluation.md` |
| 2 | Partition by period | **Done** — see `03_partitioning_and_refresh.md` |
| 3 | Incremental refresh strategy | **Done** — see `03_partitioning_and_refresh.md` |
| 4 | Access control | **Done** — see `04_access_control.md` |
| 5 | Actor layer | **Blocked** — requires Elliptic++'s address-level files (`wallets_features.csv`, `AddrTx_edgelist.csv`, etc.), a separate download this project does not have |

A fifth document, `05_case_study_alert_triage.md`, works one flagged transaction end to end — detection
through investigation — because the four items above report on the system's behaviour in
aggregate and none of them shows what the database actually hands an investigator.

## Headline results

**Fit and evaluate.** A logistic regression over the graph-derived predictors in
`analytics.vw_analysis_matrix` beats the existing `illicit_neighbour_ratio` heuristic on
overall ranking quality (PR-AUC 0.287 vs 0.211) and at wider review budgets (10%: 35.9% recall
vs 30.0%), but not at the tightest budget (top 1%, where the heuristic is already competitive).
The honest finding: a fitted model earns its complexity once investigators can review 5%+ of
transactions; below that, the heuristic already shipped in Unit 8 is not leaving much on the
table. This model was not benchmarked against the published results on this dataset and was
not given the 165 supplied features, so it evidences that the analysis matrix is usable — not
that the model is competitive.

**Partition by period.** `core.transaction` and `core.tx_feature` are now range-partitioned on
`time_step`, 49 partitions each. `EXPLAIN (ANALYZE, BUFFERS)` on a period-scoped query touches
exactly one partition — proof of partition pruning, not just a claim of it. The migration cost
one real trade-off, made explicit rather than hidden: `tx_flow`'s foreign keys to
`transaction` were dropped, since PostgreSQL cannot enforce global uniqueness on `tx_id` alone
across a table partitioned by `time_step`. Referential integrity there is now enforced at load
time by the `edgelist_endpoints_resolve` rule, which was already the mechanism doing the real
work.

**Incremental refresh.** `mv_tx_degree` and `mv_illicit_exposure` went from materialized views
(one refresh primitive: recompute everything) to partitioned tables maintained by a stored
procedure that refreshes exactly one period. This is correct, not just convenient, because no
edge in this dataset crosses a period boundary — a fact already noted in `sql/04_analysis.sql`
before this item existed. Measured: a full 49-period rebuild takes 4,284 ms; a single period,
109 ms — roughly 1/39th of the cost for 1/49th of the data.

**Access control.** Two roles enforce, at the database level, boundaries this project had
previously only stated in prose: `staging` denied to the analyst (the README already claimed
"nothing downstream reads it"), the DQ audit trail granted (a passing rule is only stronger
evidence than a slide if the analyst can query it), and `governance.rejected_row` restricted by
row-level security rather than a blanket revoke — proven live by inserting a row as the loader
and confirming the analyst still saw zero.

## What's in this submission

```
sql/05_partition_by_period.sql       core.transaction / core.tx_feature -> partitioned
sql/06_incremental_refresh.sql       mv_tx_degree / mv_illicit_exposure -> incrementally refreshed
sql/03_analytics_views_only.sql      unchanged downstream views, reapplied after 06
sql/07_access_control.sql            roles, grants, row-level security
etl/fit_and_evaluate.py              model fit/evaluation against vw_analysis_matrix

02_model_evaluation.md           item 1 write-up
03_partitioning_and_refresh.md      items 2 & 3 write-up
04_access_control.md             item 4 write-up
01_overview.md                    this file
```

## Conclusion

Unit 8 asked whether Bitcoin transaction data could be structured in an RDBMS to support AML
monitoring, and answered it with a database that was validated but not yet exercised under any
of the four pressures a real deployment puts on a schema: a model consuming it, a query
pattern dominant enough to demand partitioning, a monitoring layer that needs to stay current
without a full rebuild, and more than one class of user needing different access. The later work put
the database under each of those four pressures in turn, live, and it held: the analysis
matrix was usable enough to fit and honestly evaluate a model against a real baseline; the
partitioning migration completed and measurably pruned; the incremental refresh was correct
because of a property of the data the project had already documented, not a new assumption;
and the access boundaries enforced, in the database itself, distinctions the project had so
far only asserted in README prose. The one item not attempted -- the Elliptic++ actor layer --
remains out of scope for the same reason it always was: it requires a dataset this project
does not have, not a decision to skip it.
