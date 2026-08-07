# Model Fit and Evaluation

Run live against `elliptic_aml` on PostgreSQL 18.4, loaded from the real Elliptic Data Set
(203,769 transactions / 234,355 edges), on 2026-08-07.

## Method

`analytics.vw_analysis_matrix` — the analysis-ready extract built entirely in SQL for the
Unit 8 milestone — was read directly into pandas via `psycopg2`. The `split` column already
defined in that view (`time_step <= 34` train / `>= 35` test) was used as-is rather than
re-derived, so this analysis inherits the same temporal split as everything else in the
project rather than risking a second, inconsistent one.

Two scores were compared on the 16,670-row test set:

1. **Baseline** — `illicit_neighbour_ratio` alone, the heuristic already driving
   `analytics.vw_alert_queue` in production.
2. **Fitted** — a logistic regression (`class_weight="balanced"`) over all eight
   graph-derived predictors in the matrix: `in_degree`, `out_degree`, `total_degree`,
   `illicit_neighbours`, `licit_neighbours`, `unknown_neighbours`, `total_neighbours`,
   `illicit_neighbour_ratio`.

Evaluation used precision and recall at four fixed review budgets (1%, 2%, 5%, 10% of the
test set, ranked by score) rather than accuracy, which is meaningless at a 6.5% test-set
illicit rate. ROC-AUC and PR-AUC are reported as summary statistics; PR-AUC is the one that
matters at this base rate.

## Results

**Baseline — `illicit_neighbour_ratio` alone**
ROC-AUC 0.6077 · PR-AUC 0.2105

| Budget | Reviewed | Caught | Precision | Recall |
|---|---|---|---|---|
| 1% | 167 | 119 | 0.713 | 0.110 |
| 2% | 333 | 225 | 0.676 | 0.208 |
| 5% | 834 | 277 | 0.332 | 0.256 |
| 10% | 1,667 | 325 | 0.195 | 0.300 |

**Fitted — logistic regression, all graph-derived predictors**
ROC-AUC 0.8149 · PR-AUC 0.2866

| Budget | Reviewed | Caught | Precision | Recall |
|---|---|---|---|---|
| 1% | 167 | 118 | 0.707 | 0.109 |
| 2% | 333 | 192 | 0.577 | 0.177 |
| 5% | 834 | 274 | 0.329 | 0.253 |
| 10% | 1,667 | 389 | 0.233 | 0.359 |

**Coefficients** (raw scale, not standardised — relative magnitude only):

| Predictor | Coefficient |
|---|---|
| illicit_neighbour_ratio | +3.8582 |
| licit_neighbours | −0.9605 |
| unknown_neighbours | +0.4352 |
| illicit_neighbours | +0.3440 |
| out_degree | −0.2555 |
| total_degree | −0.1812 |
| total_neighbours | −0.1812 |
| in_degree | +0.0742 |

## Interpretation

The fitted model wins decisively on the summary statistics — ROC-AUC 0.815 vs 0.608,
PR-AUC 0.287 vs 0.211 — and at wider review budgets (5–10%) it materially outperforms the
baseline: at a 10% budget it catches 389 illicit transactions against the baseline's 325
(recall 0.359 vs 0.300), at higher precision (0.233 vs 0.195).

At the tightest budgets, the result is less flattering to the model. At 1% and 2%, the plain
heuristic matches or slightly beats the fitted model on precision (0.713 vs 0.707 at 1%;
0.676 vs 0.577 at 2%). The coefficient table explains why: `illicit_neighbour_ratio` (+3.86)
dominates the fit by an order of magnitude over every other term, so the model is close to a
recalibrated version of the same signal rather than a genuinely new one. Adding
`licit_neighbours` (−0.96) as a correction term improves the model's ranking in the middle of
the distribution but does not improve on the ratio's own ranking of its highest-confidence
cases.

**Finding:** if an investigator team can review a wider slice of transactions per period
(5% or more), fitting a model is worth the added complexity — it recovers materially more
illicit transactions at comparable or better precision. If the review budget is very tight
(top 1%), the heuristic already shipped in Unit 8's `vw_alert_queue` is not leaving much on
the table, and the added complexity of a fitted model does not clearly earn its keep at that
operating point. This is reported as the finding rather than smoothed into a single
"the model wins" claim, consistent with the project's standing rule that every claim traces
to a query that can be re-run.

## Limitations of this result

Two, both of which bound how far the finding above can be pushed:

- **This is not a competitive benchmark.** The model is a logistic regression over eight
  graph-derived predictors. The published work on this dataset (Weber et al., 2019) fits
  random forests and graph convolutional networks over all 165 supplied features plus graph
  features, and reports materially better illicit-class F1 than anything here. No comparison
  against those results was run. What this exercise establishes is that
  `vw_analysis_matrix` is directly usable as a modelling input and that the graph-derived
  predictors carry real signal — not that this model is a good one.
- **The 165 supplied features were not given to the model at all.** Only the graph-derived
  columns were used, so the comparison is "graph structure alone versus one graph column
  alone," not "graph structure versus the publisher's features." `mv_feature_separation`
  already shows one supplied feature (`local_feature_53`, Cohen's d −0.913) separating the
  classes more strongly than any other single column, so a model given both would likely beat
  both arms reported here.

## Reproducing this run

```bash
psql -d elliptic_aml -c "SELECT count(*) FROM analytics.vw_analysis_matrix;"   -- 46,564
python3 etl/fit_and_evaluate.py --dsn "$DSN"
```
