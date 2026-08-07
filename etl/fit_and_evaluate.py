#!/usr/bin/env python3
"""
ANLC-752 -- Unit 10, Item 1: Fit and evaluate.

Fits a classifier on analytics.vw_analysis_matrix (the analysis-ready table
built entirely in SQL for Unit 8) and reports precision/recall at a fixed
review budget -- the metric a triage queue is actually judged on, not
accuracy, which is meaningless at a 2.2% base rate.

Two models are fit so the comparison is honest:
  - illicit_neighbour_ratio alone (the existing heuristic already driving
    analytics.vw_alert_queue) -- the baseline.
  - A logistic regression over all graph-derived predictors in the matrix --
    interpretable, coefficients are signed and explainable to a compliance
    officer, consistent with the argument made in the Unit 8 deck (slide 15)
    that graph-derived features are the ones worth defending.

The train/test split is NOT re-derived here. It is read from the `split`
column of vw_analysis_matrix, which is defined once in the database
(sql/04_analysis.sql) so this script -- and any other analysis -- inherits
the same temporal split rather than each re-implementing it.

Usage:
    python3 fit_and_evaluate.py --dsn "postgresql://localhost/elliptic_aml"
"""
from __future__ import annotations

import argparse

import numpy as np
import pandas as pd
import psycopg2
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import average_precision_score, roc_auc_score

FEATURES = [
    "in_degree",
    "out_degree",
    "total_degree",
    "illicit_neighbours",
    "licit_neighbours",
    "unknown_neighbours",
    "total_neighbours",
    "illicit_neighbour_ratio",
]

REVIEW_BUDGETS = [0.01, 0.02, 0.05, 0.10]


def precision_recall_at_budget(y_true: np.ndarray, score: np.ndarray, budget: float):
    n = len(y_true)
    k = max(1, int(round(budget * n)))
    order = np.argsort(-score)
    top_k = order[:k]
    tp = y_true[top_k].sum()
    total_positive = y_true.sum()
    precision = tp / k
    recall = tp / total_positive if total_positive > 0 else float("nan")
    return k, int(tp), precision, recall


def report(name: str, y_true: np.ndarray, score: np.ndarray) -> None:
    print(f"\n  {name}")
    print(f"  {'-' * len(name)}")
    print(f"  ROC-AUC        {roc_auc_score(y_true, score):.4f}")
    print(f"  PR-AUC         {average_precision_score(y_true, score):.4f}"
          f"   (base rate {y_true.mean():.4f}, so this is the number that matters)")
    print(f"\n  {'budget':>8}  {'n reviewed':>10}  {'caught':>7}  {'precision':>9}  {'recall':>7}")
    for b in REVIEW_BUDGETS:
        k, tp, p, r = precision_recall_at_budget(y_true, score, b)
        print(f"  {b:>7.0%}  {k:>10,}  {tp:>7,}  {p:>9.3f}  {r:>7.3f}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn", required=True)
    args = ap.parse_args()

    print(f"Connecting to {args.dsn} ...")
    conn = psycopg2.connect(args.dsn)
    df = pd.read_sql(
        "SELECT * FROM analytics.vw_analysis_matrix",
        conn,
    )
    conn.close()
    print(f"Loaded {len(df):,} labelled rows from analytics.vw_analysis_matrix "
          f"(train={len(df[df.split=='train']):,}, test={len(df[df.split=='test']):,})")

    train = df[df.split == "train"]
    test = df[df.split == "test"]

    X_train, y_train = train[FEATURES].to_numpy(dtype=float), train["is_illicit"].to_numpy()
    X_test, y_test = test[FEATURES].to_numpy(dtype=float), test["is_illicit"].to_numpy()

    # ---- Baseline: the heuristic already in production (vw_alert_queue) ----
    baseline_score = test["illicit_neighbour_ratio"].to_numpy(dtype=float)
    report("Baseline -- illicit_neighbour_ratio alone (existing heuristic)",
           y_test, baseline_score)

    # ---- Fitted model: logistic regression over all graph-derived features ----
    clf = LogisticRegression(max_iter=2000, class_weight="balanced")
    clf.fit(X_train, y_train)
    model_score = clf.predict_proba(X_test)[:, 1]
    report("Fitted -- logistic regression over all graph-derived predictors",
           y_test, model_score)

    print("\n  Coefficients (standardised scale would be more comparable; raw shown here)")
    for feat, coef in sorted(zip(FEATURES, clf.coef_[0]), key=lambda t: -abs(t[1])):
        print(f"    {feat:<24} {coef:+.4f}")

    print(
        "\n  Read: at a 5% review budget, compare the baseline's precision/recall to the "
        "fitted model's. If the fitted model doesn't clear the baseline by a real margin, "
        "the heuristic already in analytics.vw_alert_queue is doing the job and the added "
        "complexity of a fitted model is not earning its keep -- that is itself a valid "
        "finding, not a failure of the exercise."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
