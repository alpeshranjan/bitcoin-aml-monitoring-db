# Partitioning by Period, and Incremental Refresh

Run live against `elliptic_aml` on PostgreSQL 18.4, on the real 203,769-transaction /
234,355-edge load, on 2026-08-07.

## Partitioning by period

`core.transaction` and `core.tx_feature` were converted to range-partitioned tables on
`time_step`, 49 partitions each (`sql/05_partition_by_period.sql`). Two real PostgreSQL
constraints were resolved rather than worked around:

- A partitioned table's primary key must include the partition key, so `core.transaction`'s
  PK became `(tx_id, time_step)`. Since each `tx_id` has exactly one `time_step`, this changes
  nothing about what is actually enforced.
- PostgreSQL cannot enforce a native unique constraint on `tx_id` alone across a table
  partitioned by `time_step`. `core.tx_flow`'s foreign keys to `core.transaction` were
  therefore dropped rather than migrated to a composite key that would have required
  denormalizing `time_step` onto the edge table for no monitoring benefit. Referential
  integrity across that edge remains enforced — just at load time, by the
  `edgelist_endpoints_resolve` rule already writing to `governance.dq_check_result`, not by a
  live constraint.

`analytics` (dropped and rebuilt entirely — a property the Unit 8 README already claimed for
that schema) and the whole load were unaffected: `vw_alert_queue` still returns 4,027 rows,
`vw_split_balance` still reports 29,894/16,670 at 11.58%/6.50% illicit, identical to before
the migration.

**Proof it worked**, `EXPLAIN (ANALYZE, BUFFERS)` on the period-scoped query from the Unit 8
deck:

```
SELECT tx_id FROM core.transaction WHERE time_step = 32 AND class_id = 1;

Bitmap Heap Scan on transaction_p32 transaction  (actual time=0.273..0.448 rows=342 loops=1)
  Buffers: shared read=27
Execution Time: 0.671 ms
```

Only `transaction_p32` appears in the plan — the other 48 partitions were pruned before
execution, not scanned and discarded.

## Incremental refresh strategy

`mv_tx_degree` and `mv_illicit_exposure` were PostgreSQL `MATERIALIZED VIEW`s, which have
exactly one refresh primitive: `REFRESH MATERIALIZED VIEW`, a full recompute. There is no
native per-partition refresh for a matview.

Both were converted to ordinary partitioned tables (`sql/06_incremental_refresh.sql`),
maintained by a stored procedure, `analytics.refresh_period(p)`, that truncates and
repopulates exactly one partition. This is correct — not merely convenient — because of a
property of the dataset already noted in `sql/04_analysis.sql`: no edge in `core.tx_flow`
connects two different periods (profiled as "cross-period edges: 0"). Degree and one-hop
illicit exposure for a transaction in period *p* therefore depend only on rows where
`time_step = p`; recomputing period *p* cannot need, and cannot change, any other period's
stored rows. A dataset without that property would need a different design.

A second procedure, `analytics.refresh_all()`, is defined as 49 sequential calls to
`refresh_period()` — the full rebuild and the incremental refresh are the same code path, not
two implementations to keep in sync.

**Measured live:**

| Operation | Time |
|---|---|
| `refresh_all()` — full rebuild, 49 periods | 4,284 ms |
| `refresh_period(32)` — one period | 109 ms |

Ratio ≈ 39×, against a theoretical ideal of 49× for perfectly linear per-period cost. The gap
is fixed per-call overhead (connection, planning) that doesn't shrink with partition size —
expected, and worth stating rather than rounding away.

**Practical reading:** in production, a new period's data becomes available roughly every two
weeks (the dataset's own period length). At 109 ms to refresh the new period, the incremental
strategy makes the monitoring layer's staleness bounded by "how often you choose to call
`refresh_period()`," not by a multi-second full rebuild — the difference matters more as the
dataset grows past this project's 49 periods, since `refresh_all()`'s cost scales with total
history while `refresh_period()`'s does not.

## Reproducing this run

```bash
psql -d elliptic_aml -f sql/05_partition_by_period.sql
psql -d elliptic_aml -f sql/02_indexes.sql
psql -d elliptic_aml -f sql/03_analytics.sql
psql -d elliptic_aml -f sql/04_analysis.sql

psql -d elliptic_aml -f sql/06_incremental_refresh.sql
psql -d elliptic_aml -f sql/03_analytics_views_only.sql
psql -d elliptic_aml -f sql/04_analysis.sql

psql -d elliptic_aml -c "\timing on" -c "CALL analytics.refresh_all();"
psql -d elliptic_aml -c "\timing on" -c "CALL analytics.refresh_period(32::smallint);"
```
