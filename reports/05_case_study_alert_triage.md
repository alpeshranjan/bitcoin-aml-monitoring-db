# Case Study: One Flagged Transaction, End to End

Everything in this project up to this point argues, in the abstract, that the schema
"supports identification and monitoring." This is what that claim produces on a specific,
real, un-cherry-picked row of the live database.

**In plain terms:** the database was asked "which transaction should someone look at right
now, and why?" It answered with a specific transaction ID, a period, and — instead of a bare
probability — an actual traceable list of the confirmed-illicit transactions that fed money
into it directly. That is what "monitoring" means as a query result rather than a slide claim.

## On what basis a transaction is flagged

Two things decide this, both defined in `analytics.vw_alert_queue`
(`sql/03_analytics.sql`) and neither of them a model.

**Who enters the queue.** Only transactions that are (a) still unlabelled —
`class_id = 3`, meaning Elliptic could not attribute them — and (b) adjacent to at least one
transaction Elliptic *did* confirm illicit (`illicit_neighbours > 0`). Labelled transactions
are excluded because they need no triage; the whole point of the queue is to rank the
*unknown*. That filter reduces 157,205 unlabelled transactions to **4,027**.

**How they are ranked.** Three weighted terms, maximum possible score 15:

```sql
risk_score = 2.0 * LEAST(illicit_neighbours, 5)      -- direct exposure  (max 10)
           + 3.0 * illicit_neighbour_ratio           -- concentration    (max  3)
           + 1.0 * LEAST(out_degree / 25.0, 2.0)     -- dispersal shape  (max  2)
```

The weights are a stated heuristic, not fitted coefficients — the view's own comment says so.
The project's claim is that the schema makes such scoring *queryable*, not that these are the
right weights.

## Detection

```sql
SELECT tx_id, time_step, illicit_neighbours, illicit_neighbour_ratio, risk_score
FROM analytics.vw_alert_queue
ORDER BY risk_score DESC
LIMIT 10;
```

| tx_id | time_step | illicit_neighbours | illicit_neighbour_ratio | risk_score |
|---|---|---|---|---|
| 283172570 | 25 | 10 | 1.0000 | 13.000 |
| 277013200 | 25 | 6 | 1.0000 | 13.000 |
| 275521193 | 25 | 9 | 1.0000 | 13.000 |
| 275521195 | 25 | 5 | 1.0000 | 13.000 |
| 29778647  | 14 | 11 | 1.0000 | 13.000 |
| 275521191 | 25 | 7 | 1.0000 | 13.000 |
| 283546985 | 25 | 6 | 1.0000 | 13.000 |
| 101721963 | 18 | 15 | 1.0000 | 13.000 |
| **139273997** | **28** | **59** | **1.0000** | **13.000** |
| 275155448 | 25 | 9 | 1.0000 | 13.000 |

All ten are transactions Elliptic never labelled — `class = unknown` — that nonetheless have
a 100% illicit-neighbour ratio: every counterparty they touch is a transaction Elliptic *did*
confirm as illicit.

Decomposing the score shows exactly why every one of them lands on 13.000:

| tx_id | illicit_nb | ratio | out_degree | exposure | concentration | dispersal | total |
|---|---|---|---|---|---|---|---|
| 283172570 | 10 | 1.0000 | 0 | 10.0 | 3.0 | 0.0 | 13.000 |
| 277013200 | 6 | 1.0000 | 0 | 10.0 | 3.0 | 0.0 | 13.000 |
| 101721963 | 15 | 1.0000 | 0 | 10.0 | 3.0 | 0.0 | 13.000 |
| 139273997 | 59 | 1.0000 | 0 | 10.0 | 3.0 | 0.0 | 13.000 |
| *(all ten identical)* | | | | | | | |

**Three limitations of the heuristic are visible in that table, and none of them is hidden by
it.**

*The exposure term saturates.* It caps at 5 illicit neighbours, so `139273997` with **59**
confirmed-illicit inputs scores exactly the same as `277013200` with **6**. The queue cannot
tell them apart, even though a analyst plainly would.

*The ranking is a tie, not an ordering.* All ten rows score 13.000, so `ORDER BY risk_score
DESC LIMIT 10` returns them in whatever order the planner produces. "Top of the queue" here
means "tied at the top," and the row printed first carries no more meaning than the row
printed last.

*The top of the queue is structurally biased toward sinks.* Every one of these ten has
`out_degree = 0`, yet only **203 of the 4,027** queued transactions (5.0%) are pure sinks.
That is not coincidence: reaching a ratio of 1.0000 requires *every* neighbour to be illicit,
and outgoing edges are additional neighbours that can dilute the ratio. Having no outgoing
edges removes that dilution risk entirely, so sinks reach the maximum concentration term far
more easily than transactions with outbound flow. The scoring formula intends its third term
to reward *dispersal* (high fan-out), but in practice the concentration term filters the top
of the queue down to transactions with no fan-out at all — the opposite shape.

`139273997` was chosen for the trace below on a stated basis rather than arbitrarily: among
the tied rows it has by far the most confirmed-illicit inputs (59), so it produces the
richest provenance trail. That choice is exactly the judgement the score itself failed to
make.

## Investigation

```sql
SELECT * FROM analytics.trace_illicit_provenance(139273997, 4);
```

At depth 1 — one hop upstream — every ancestor returned carries `ancestor_class = illicit`:

```
 depth | ancestor_tx_id | ancestor_class |          path
-------+----------------+----------------+-------------------------
     1 |      139273998 | illicit        | {139273997,139273998}
     1 |      139273999 | illicit        | {139273997,139273999}
     1 |      139274000 | illicit        | {139273997,139274000}
     1 |      139274001 | illicit        | {139273997,139274001}
     ...                                    (output continues)
```

Counting the trace by depth:

```sql
SELECT depth, count(*) AS ancestors
FROM analytics.trace_illicit_provenance(139273997, 4)
GROUP BY depth ORDER BY depth;
```

| depth | ancestors |
|---|---|
| 1 | 59 |
| 2 | 13 |
| 3 | 2 |

74 upstream transactions in total, and the chain terminates at three hops — nothing is
returned at depth 4 even though the walk was allowed to go that far.

**The shape of this transaction is itself the finding.** Checking its edges directly:

```sql
SELECT (SELECT count(*) FROM core.tx_flow WHERE dst_tx_id = 139273997) AS upstream_edges,
       (SELECT count(*) FROM core.tx_flow WHERE src_tx_id = 139273997) AS downstream_edges;
```

| upstream_edges | downstream_edges |
|---|---|
| 59 | 0 |

`139273997` receives from 59 transactions and sends to none. It is a pure sink — a terminal
collection point, which is the consolidation signature `mv_tx_degree`'s own comment describes
("high out-degree with low in-degree is the structural signature of dispersal; the inverse
indicates consolidation"). Every one of those 59 inbound counterparties is a transaction
Elliptic independently confirmed illicit.

This also explains why `vw_alert_queue`'s `illicit_neighbours = 59` happens to equal the
depth-1 ancestor count of 59, which is worth being precise about rather than presenting as
mutual confirmation. The two numbers measure different things: `mv_illicit_exposure` counts
*undirected* neighbours (it UNIONs both edge directions), while `trace_illicit_provenance`
walks *upstream only*. They coincide here specifically because this transaction has zero
outgoing edges, so its undirected neighbourhood and its set of direct ancestors are the same
set. On a transaction with outbound flow they would differ, and a reader should not take the
match as a general cross-validation of the two objects.

## What this proves that the aggregate statistics elsewhere in this project don't

Precision, recall, and AUC describe the system's behaviour averaged over 16,670 test
transactions. They don't answer the question a compliance officer actually asks, which is
about one transaction: *why this one?* This case study is that answer, produced end to end by
the database alone — no model, no manual lookup:

1. `vw_alert_queue` narrows 157,205 unlabelled transactions down to a ranked list of 4,027
   with at least one confirmed-illicit counterparty.
2. `trace_illicit_provenance` turns "flagged" into a specific, inspectable, re-runnable
   reason: 59 confirmed-illicit transactions feeding directly in, 74 across the full upstream
   chain, and a fan-in/fan-out shape (59 in, 0 out) that names the typology.

That is the concrete version of the claim the rest of this project makes abstractly: the
schema doesn't just store the data, it makes "which transaction, and why" a query, not a
research project.

## What this says about the scoring function

The three limitations above are the concrete version of the caveat
`vw_alert_queue`'s comment already carries — "the weights are a transparent heuristic, not a
fitted model." Seen against real data, the specific repairs it needs are now nameable rather
than hypothetical: uncap the exposure term (or make it logarithmic) so 59 outranks 6; add a
tiebreak so the ranking is a total order; and reconsider a concentration term that
systematically promotes zero-fan-out transactions while a separate term is trying to reward
fan-out.

That is a more useful finding than a queue that had simply looked correct. It is also the
argument for `02_model_evaluation.md`: fitted coefficients would not have produced the
saturation or the tie, because nothing in a fitted model caps a predictor at 5 by hand.

## Reproducing this

```bash
psql -d elliptic_aml -c "SELECT tx_id, time_step, illicit_neighbours, illicit_neighbour_ratio, risk_score FROM analytics.vw_alert_queue ORDER BY risk_score DESC LIMIT 10;"

# score decomposition and the sink observation
psql -d elliptic_aml -c "SELECT tx_id, illicit_neighbours, illicit_neighbour_ratio, out_degree, 2.0*LEAST(illicit_neighbours,5) AS term_exposure, 3.0*COALESCE(illicit_neighbour_ratio,0) AS term_concentration, 1.0*LEAST(out_degree/25.0,2.0) AS term_dispersal, risk_score FROM analytics.vw_alert_queue ORDER BY risk_score DESC LIMIT 10;"
psql -d elliptic_aml -c "SELECT count(*) AS queue_total, count(*) FILTER (WHERE out_degree=0) AS pure_sinks FROM analytics.vw_alert_queue;"

# provenance
psql -d elliptic_aml -c "SELECT * FROM analytics.trace_illicit_provenance(139273997, 4);"
psql -d elliptic_aml -c "SELECT depth, count(*) FROM analytics.trace_illicit_provenance(139273997,4) GROUP BY depth ORDER BY depth;"
```
