# ETL Validation Run Log — Second Run

**ANLC-752 Course Project**
**PostgreSQL 18.4** (Postgres.app) on aarch64-apple-darwin23.6.0

## Provenance

A second, independent execution of the pipeline against the authentic Elliptic Data Set
(`elliptic_txs_classes.csv`, `elliptic_txs_edgelist.csv`, `elliptic_txs_features.csv`), on a
different machine and a different PostgreSQL major version from the original Unit 8 run
recorded in `validation_run_log.txt`. That earlier file has been left exactly as generated;
this one records what was observed on this machine and nothing else.

Everything below was transcribed from the terminal session in which it ran. Where a figure was
not re-measured on this run, it is omitted rather than carried over from the earlier log.

## ETL run

```
ETL run  data-dir=/Users/alpesh/Downloads/elliptic_bitcoin_dataset

  Extracting to staging
    extracted   203,769 rows  elliptic_txs_classes.csv    -> staging.txs_classes   (0.1s)
    extracted   234,355 rows  elliptic_txs_edgelist.csv   -> staging.txs_edgelist  (0.1s)
    extracted   203,769 rows  elliptic_txs_features.csv   -> staging.txs_features  (4.2s)

  Data quality rules
    [PASS] classes_row_count_nonzero         expected > 0                             got 203769
    [PASS] classes_tx_id_unique              expected 0 duplicate tx_id               got 0
    [PASS] classes_code_in_domain            expected 0 out-of-domain class codes     got 0
    [PASS] features_tx_id_unique             expected 0 duplicate tx_id               got 0
    [PASS] features_time_step_in_range       expected all time steps in 1..49         got 0
    [PASS] classes_features_tx_id_reconcile  expected 0 symmetric difference          got 0
    [PASS] edgelist_endpoints_resolve        expected 0 unresolved endpoints          got 0
    [PASS] edgelist_no_self_loops            expected 0 self-loops                    got 0
    [PASS] features_no_null_values           expected 0 nulls across all 165 feature columns  got 0

  Loading core
    dim_time_step               49
    dim_feature                165
    core.transaction       203,769
    core.tx_feature        203,769
    core.tx_flow           234,355

  Building indexes and analytics layer
    applied 02_indexes.sql
    applied 03_analytics.sql
    applied 04_analysis.sql
    staging truncated

Committed in 17.3s
```

All nine rules passed. Row counts are identical to the Unit 8 run in every table, which is the
reconciliation that matters: the same three input files produced the same conformed model on a
different server and a different major version.

## Post-load verification

The three findings the Unit 8 deck rests on, re-measured on this load.

### 1. Counterparty adjacency (deck slide 13)

```
 illicit_pct | licit_pct
-------------+-----------
        30.0 |       2.4
```

30.0% of illicit transactions have at least one illicit counterparty, against 2.4% of licit
ones — the 12× separation claimed in the deck, reproduced.

### 2. Periods 43–46 collapse (deck slide 12)

```
 time_step | illicit_rate_of_labelled
-----------+--------------------------
        42 |                   0.1110
        43 |                   0.0175
        44 |                   0.0151
        45 |                   0.0041
        46 |                   0.0028
```

11.10% at period 42 falling to 0.28% at period 46 — the ~40-fold collapse, reproduced.
Recovery to 11.8% by period 49 is visible in the full series.

### 3. Temporal split balance (deck slide 16)

```
 split | n_labelled | n_illicit | pct_illicit
-------+------------+-----------+-------------
 train |      29894 |      3462 |       11.58
 test  |      16670 |      1083 |        6.50
```

### 4. Alert queue size

```
 count
-------
  4027
```

4,027 unlabelled transactions with at least one known illicit counterparty.

## Schema migrations

### Partition pruning — after `sql/05_partition_by_period.sql`

```
EXPLAIN (ANALYZE, BUFFERS)
SELECT tx_id FROM core.transaction WHERE time_step = 32 AND class_id = 1;

 Bitmap Heap Scan on transaction_p32 transaction
   (cost=7.79..37.92 rows=342 width=8) (actual time=0.273..0.448 rows=342.00 loops=1)
   Recheck Cond: ((time_step = 32) AND (class_id = 1))
   Heap Blocks: exact=25
   Buffers: shared read=27
   ->  Bitmap Index Scan on transaction_p32_time_step_class_id_idx
         (actual time=0.235..0.235 rows=342.00 loops=1)
         Buffers: shared read=2
 Planning Time: 3.417 ms
 Execution Time: 0.671 ms
```

Only `transaction_p32` appears; the other 48 partitions were pruned. `vw_alert_queue` (4,027)
and `vw_split_balance` were re-checked after the migration and were unchanged, so no rows were
lost or altered.

### Incremental refresh — after `sql/06_incremental_refresh.sql`

```
CALL analytics.refresh_all();                Time: 4284.365 ms (00:04.284)
CALL analytics.refresh_period(32::smallint);  Time:  108.961 ms
```

Full 49-period rebuild against one period: ≈39×, versus a theoretical 49× for perfectly linear
per-period cost. The shortfall is fixed per-call overhead.

### Storage after partitioning

Summed over partitions via `pg_inherits`; `pg_total_relation_size()` on a partitioned parent
reports 0 bytes.

| Object | Size | Partitions |
|---|---|---|
| whole database | 471 MB | — |
| `core.tx_feature` | 329 MB | 49 |
| `analytics.mv_tx_degree` | 29 MB | 49 |
| `analytics.mv_illicit_exposure` | 28 MB | 49 |
| `core.transaction` | 22 MB | 49 |

### Access control — after `sql/07_access_control.sql`

```
as anlc752_analyst:
  core.transaction                203769 rows visible
  governance.dq_check_result           9 rows visible
  governance.rejected_row              0 rows visible
  staging.txs_classes             ERROR: permission denied for schema staging

as anlc752_etl_loader:
  INSERT INTO governance.rejected_row ...   INSERT 0 1
  governance.rejected_row              1 row visible

back as anlc752_analyst, same table, after that insert:
  governance.rejected_row              0 rows visible
```

The row exists and the loader can see it; the analyst cannot. Row-level security is doing the
filtering, not an empty table.

### Data dictionary regenerated from the live catalog

```
wrote docs/data_dictionary.md (19 relations, 3 functions)
```

## Not re-measured on this run

Source file SHA-256 values, per-file load audit rows and the class distribution table were
produced by the Unit 8 run and are recorded in `validation_run_log.txt`. They were not
re-queried here, so they are not restated above.

The injected-defect negative test (duplicate `txId`, `time_step = 99`, edge to a missing
transaction) was performed during Unit 8 and is documented in `validation_run_log.txt` and the
deck. It was not repeated on this run.
