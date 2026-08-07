# Data Dictionary

Generated from the live PostgreSQL catalog by `etl/gen_data_dictionary.py` after a
successful load. Do not edit by hand — regenerate.

## `analytics.mv_feature_separation`  *(materialized view)*

Per-feature class separation for the 165 obfuscated features, measured as Cohen's d over the
labelled subset. Materialised because the long-form projection costs roughly six seconds and every
screening query reuses it.

| Column | Type | Null | Notes |
|---|---|---|---|
| `column_name` | text |  |  |
| `feature_group` | character varying(16) |  |  |
| `n_illicit` | bigint |  |  |
| `n_licit` | bigint |  |  |
| `mean_illicit` | numeric |  |  |
| `mean_licit` | numeric |  |  |
| `pooled_sd` | numeric |  |  |
| `cohens_d` | numeric |  |  |

## `analytics.mv_illicit_exposure`  *(partitioned table, 203,769 rows)*

One-hop counterparty exposure. Partitioned table maintained by analytics.refresh_period(), not a
MATERIALIZED VIEW.

| Column | Type | Null | Notes |
|---|---|---|---|
| `tx_id` | bigint | NOT NULL |  |
| `time_step` | smallint | NOT NULL |  |
| `class_id` | smallint | NOT NULL |  |
| `illicit_neighbours` | bigint | NOT NULL |  |
| `licit_neighbours` | bigint | NOT NULL |  |
| `unknown_neighbours` | bigint | NOT NULL |  |
| `total_neighbours` | bigint | NOT NULL |  |
| `illicit_neighbour_ratio` | numeric |  |  |

## `analytics.mv_tx_degree`  *(partitioned table, 203,769 rows)*

Per-transaction fan-in and fan-out. Partitioned table maintained by analytics.refresh_period(),
not a MATERIALIZED VIEW -- see header of sql/06_incremental_refresh.sql for why a per-period
refresh is correct for this dataset.

| Column | Type | Null | Notes |
|---|---|---|---|
| `tx_id` | bigint | NOT NULL |  |
| `time_step` | smallint | NOT NULL |  |
| `class_id` | smallint | NOT NULL |  |
| `out_degree` | bigint | NOT NULL |  |
| `in_degree` | bigint | NOT NULL |  |
| `total_degree` | bigint | NOT NULL |  |

## `analytics.vw_alert_queue`  *(view)*

Triage queue over unlabelled transactions with at least one known illicit counterparty. The
weights are a transparent heuristic, not a fitted model -- the project scope is the data structure
that makes such scoring queryable, not the scoring function itself.

| Column | Type | Null | Notes |
|---|---|---|---|
| `tx_id` | bigint |  |  |
| `time_step` | smallint |  |  |
| `in_degree` | bigint |  |  |
| `out_degree` | bigint |  |  |
| `illicit_neighbours` | bigint |  |  |
| `total_neighbours` | bigint |  |  |
| `illicit_neighbour_ratio` | numeric |  |  |
| `risk_score` | numeric |  |  |

## `analytics.vw_analysis_matrix`  *(view)*

Analysis-ready extract: labelled transactions only, binary target, graph predictors, and a
temporal train/test split. Unlabelled rows are excluded rather than treated as negative.

| Column | Type | Null | Notes |
|---|---|---|---|
| `tx_id` | bigint |  |  |
| `time_step` | smallint |  |  |
| `split` | text |  |  |
| `is_illicit` | integer |  |  |
| `in_degree` | bigint |  |  |
| `out_degree` | bigint |  |  |
| `total_degree` | bigint |  |  |
| `illicit_neighbours` | bigint |  |  |
| `licit_neighbours` | bigint |  |  |
| `unknown_neighbours` | bigint |  |  |
| `total_neighbours` | bigint |  |  |
| `illicit_neighbour_ratio` | numeric |  |  |

## `analytics.vw_discriminative_features`  *(view)*

Features ranked by univariate class separation. Column names are obfuscated by the publisher, so a
result here is stateable as "feature X separates the classes" and never as a claim about a real-
world transaction attribute.

| Column | Type | Null | Notes |
|---|---|---|---|
| `separation_rank` | bigint |  |  |
| `column_name` | text |  |  |
| `feature_group` | character varying(16) |  |  |
| `mean_illicit` | numeric |  |  |
| `mean_licit` | numeric |  |  |
| `cohens_d` | numeric |  |  |
| `effect_size` | text |  |  |

## `analytics.vw_dispersal_candidates`  *(view)*

Transactions in the top 0.1% of fan-out that disperse to more destinations than they received from
-- the placement/layering signature.

| Column | Type | Null | Notes |
|---|---|---|---|
| `tx_id` | bigint |  |  |
| `time_step` | smallint |  |  |
| `class_code` | character varying(16) |  |  |
| `in_degree` | bigint |  |  |
| `out_degree` | bigint |  |  |
| `illicit_neighbours` | bigint |  |  |
| `threshold_applied` | double precision |  |  |

## `analytics.vw_graph_predictor_strength`  *(view)*

Association between each graph-derived predictor and the illicit outcome. These predictors are
interpretable precisely because the database built them; the publisher's 165 columns are not.

| Column | Type | Null | Notes |
|---|---|---|---|
| `predictor` | text |  |  |
| `point_biserial_r` | numeric |  |  |
| `mean_illicit` | numeric |  |  |
| `mean_licit` | numeric |  |  |

## `analytics.vw_period_risk_profile`  *(view)*

Illicit rate per period, denominated on labelled transactions only. A step change in this series
is the database-level signal of a market-wide event such as a darknet marketplace takedown.

| Column | Type | Null | Notes |
|---|---|---|---|
| `time_step` | smallint |  |  |
| `total_transactions` | bigint |  |  |
| `illicit_count` | bigint |  |  |
| `licit_count` | bigint |  |  |
| `unlabelled_count` | bigint |  |  |
| `illicit_rate_of_labelled` | numeric |  |  |

## `analytics.vw_split_balance`  *(view)*

Class balance either side of the temporal split. Reported because the illicit rate collapses after
period 42, so train and test are not drawn from the same regime -- a fact a model must be
evaluated against, not one to be smoothed away by resampling.

| Column | Type | Null | Notes |
|---|---|---|---|
| `split` | text |  |  |
| `first_period` | smallint |  |  |
| `last_period` | smallint |  |  |
| `n_labelled` | bigint |  |  |
| `n_illicit` | bigint |  |  |
| `n_licit` | bigint |  |  |
| `pct_illicit` | numeric |  |  |

## `core.dim_class`  *(table, 3 rows)*

Ground-truth classification assigned by Elliptic Ltd. Class 3 (unknown) is an absence of label,
not a third outcome -- is_labelled makes that explicit so analysts cannot silently treat unknown
as licit.

| Column | Type | Null | Notes |
|---|---|---|---|
| `class_id` | smallint | NOT NULL |  |
| `class_code` | character varying(16) | NOT NULL |  |
| `class_label` | character varying(64) | NOT NULL |  |
| `is_labelled` | boolean | NOT NULL |  |
| `description` | text |  |  |

## `core.dim_feature`  *(table, 165 rows)*

Catalogue of the 165 anonymised node features. Carries the lineage and interpretability caveat:
is_obfuscated records that no feature can be mapped back to a real-world transaction attribute
such as value or fee.

| Column | Type | Null | Notes |
|---|---|---|---|
| `feature_id` | smallint | NOT NULL |  |
| `column_name` | character varying(64) | NOT NULL |  |
| `feature_group` | character varying(16) | NOT NULL |  |
| `ordinal_in_group` | smallint | NOT NULL |  |
| `is_obfuscated` | boolean | NOT NULL |  |
| `description` | text |  |  |

## `core.dim_time_step`  *(table, 49 rows)*

The 49 discrete time steps of the dataset. Each is a connected component of transactions appearing
on the blockchain within roughly a two-week window; steps are evenly spaced but carry no absolute
calendar date.

| Column | Type | Null | Notes |
|---|---|---|---|
| `time_step` | smallint | NOT NULL |  |
| `nominal_interval` | character varying(32) | NOT NULL |  |
| `description` | text |  |  |

## `core.transaction`  *(partitioned table, 203,769 rows)*

One row per Bitcoin transaction (graph node). tx_id is the Elliptic surrogate identifier, not a
Bitcoin transaction hash. Range-partitioned on time_step: 49 partitions, one per period, because
period-scoped filtering is the dominant access pattern in the monitoring workload.

| Column | Type | Null | Notes |
|---|---|---|---|
| `tx_id` | bigint | NOT NULL |  |
| `time_step` | smallint | NOT NULL |  |
| `class_id` | smallint | NOT NULL |  |
| `load_batch_id` | integer | NOT NULL |  |

## `core.tx_feature`  *(partitioned table, 203,769 rows)*

Wide 1:1 feature vector per transaction. Range-partitioned on time_step to match core.transaction;
time_step is carried here only because a partitioned table's key must include the partition
column, not because it is a new fact -- it is always equal to the owning transaction's time_step,
enforced by the composite foreign key.

| Column | Type | Null | Notes |
|---|---|---|---|
| `tx_id` | bigint | NOT NULL |  |
| `time_step` | smallint | NOT NULL |  |
| `local_feature_1` … `local_feature_93` | double precision | NOT NULL | 93 columns, identical shape. Obfuscated by the publisher; see `core.dim_feature`. |
| `aggregate_feature_1` … `aggregate_feature_72` | double precision | NOT NULL | 72 columns, identical shape. Obfuscated by the publisher; see `core.dim_feature`. |

## `core.tx_flow`  *(table, 234,355 rows)*

Directed money flow edge: bitcoin from src_tx_id was spent by dst_tx_id. Edges connect
transactions, NOT wallets or account holders -- the dataset carries no party or counterparty
entity. Foreign keys to core.transaction were dropped when core.transaction was partitioned by
time_step (PostgreSQL cannot enforce uniqueness on tx_id alone across that partitioning); endpoint
referential integrity is instead enforced at load time by the edgelist_endpoints_resolve rule in
governance.dq_check_result.

| Column | Type | Null | Notes |
|---|---|---|---|
| `src_tx_id` | bigint | NOT NULL |  |
| `dst_tx_id` | bigint | NOT NULL |  |
| `load_batch_id` | integer | NOT NULL |  |

## `governance.dq_check_result`  *(table, 9 rows)*

Outcome of each declarative data quality rule. Rules that fail with severity ERROR abort the load
before core tables are touched.

| Column | Type | Null | Notes |
|---|---|---|---|
| `check_result_id` | integer | NOT NULL |  |
| `load_batch_id` | integer |  |  |
| `check_name` | character varying(128) | NOT NULL |  |
| `check_type` | character varying(32) | NOT NULL |  |
| `severity` | character varying(16) | NOT NULL |  |
| `expected_value` | text |  |  |
| `actual_value` | text |  |  |
| `passed` | boolean | NOT NULL |  |
| `checked_at` | timestamp with time zone | NOT NULL |  |

## `governance.etl_load_audit`  *(table, 3 rows)*

One row per file-to-table load. source_sha256 pins the exact input artefact so a result can be
traced back to the file that produced it.

| Column | Type | Null | Notes |
|---|---|---|---|
| `load_batch_id` | integer | NOT NULL |  |
| `source_file` | character varying(128) | NOT NULL |  |
| `source_bytes` | bigint |  |  |
| `source_sha256` | character(64) |  |  |
| `target_table` | character varying(128) | NOT NULL |  |
| `rows_extracted` | bigint |  |  |
| `rows_rejected` | bigint |  |  |
| `rows_loaded` | bigint |  |  |
| `started_at` | timestamp with time zone | NOT NULL |  |
| `finished_at` | timestamp with time zone |  |  |
| `status` | character varying(16) | NOT NULL |  |
| `notes` | text |  |  |

## `governance.rejected_row`  *(table, 0 rows)*

**Row-level security is enabled on this table.** Visible rows depend on the querying role; see `sql/07_access_control.sql`.

Quarantine for rows failing transformation or integrity rules. Rejects are retained rather than
dropped so that data loss is visible and auditable. Row-level security restricts visibility to
anlc752_etl_loader; anlc752_analyst holds table-level SELECT but sees zero rows by policy, since a
rejected raw payload carries no guarantee of its shape or content.

| Column | Type | Null | Notes |
|---|---|---|---|
| `rejected_row_id` | bigint | NOT NULL |  |
| `load_batch_id` | integer |  |  |
| `source_file` | character varying(128) |  |  |
| `source_line_no` | bigint |  |  |
| `reject_reason` | character varying(256) | NOT NULL |  |
| `raw_payload` | text |  |  |

## Functions and procedures

### `analytics.refresh_all()`

Procedure — invoked with `CALL`, returns no value.

Full rebuild, expressed as 49 calls to refresh_period(). Exists to prove the incremental path and
the full-rebuild path are the same code -- a full rebuild is not a special case, it is 49 ordinary
incremental refreshes.

### `analytics.refresh_period(IN p_time_step smallint)`

Procedure — invoked with `CALL`, returns no value.

Incremental refresh: recomputes mv_tx_degree and mv_illicit_exposure for exactly one period.
Correct because no edge in core.tx_flow crosses a time_step boundary, so a period's degree and
exposure figures cannot be affected by data outside that period. Cost is O(period size), not
O(graph size) -- see the timing comparison run after this script.

### `analytics.trace_illicit_provenance(p_tx_id bigint, p_max_depth integer DEFAULT 4)`

Returns `TABLE(depth integer, ancestor_tx_id bigint, ancestor_class character varying, path bigint[])`.

Bounded recursive upstream trace. Depth is a required parameter because an unbounded walk on a
234k-edge graph is not a safe interactive query.
