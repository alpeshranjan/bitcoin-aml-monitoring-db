#!/usr/bin/env python3
"""
Generate SCHEMA-FAITHFUL TEST FIXTURES for the edgelist and feature files.

    !!  THIS IS NOT PROJECT DATA.  !!

These fixtures exist only to exercise the ETL pipeline end to end -- COPY paths,
data quality rules, casts, constraints, index builds and the analytics layer --
without a network round trip to Kaggle. Every feature value is drawn from a
random distribution and carries no information about Bitcoin.

Analysis, statistics and findings must be produced from the real files. Run:

    python3 etl/etl_load.py --data-dir ./data --dsn ...

against the genuine download. This script writes to a separate directory
(default ./fixtures) so a fixture can never be mistaken for the real thing.

The real elliptic_txs_classes.csv IS used here, purely as the source of the
authentic tx_id universe, so that reconciliation and referential rules are
tested against realistic identifier values.
"""
from __future__ import annotations

import argparse
import csv
from pathlib import Path

import numpy as np

N_LOCAL, N_AGG = 93, 72
N_FEATURES = N_LOCAL + N_AGG
N_TIME_STEPS = 49


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--classes", type=Path, default=Path("data/elliptic_txs_classes.csv"),
                    help="Real classes file -- used only for its tx_id universe.")
    ap.add_argument("--out", type=Path, default=Path("fixtures"))
    ap.add_argument("--sample", type=int, default=0,
                    help="Use only the first N transactions (0 = all).")
    ap.add_argument("--seed", type=int, default=752)
    args = ap.parse_args()

    rng = np.random.default_rng(args.seed)
    args.out.mkdir(parents=True, exist_ok=True)

    # -- real tx_id universe -------------------------------------------------
    with args.classes.open() as fh:
        rdr = csv.reader(fh)
        next(rdr)
        rows = [(int(r[0]), r[1]) for r in rdr]
    if args.sample:
        rows = rows[: args.sample]
    tx_ids = np.array([r[0] for r in rows], dtype=np.int64)
    n = len(tx_ids)
    print(f"tx universe: {n:,} ids from {args.classes.name}")

    # -- classes subset (only needed when sampling) --------------------------
    if args.sample:
        with (args.out / "elliptic_txs_classes.csv").open("w", newline="") as fh:
            w = csv.writer(fh)
            w.writerow(["txId", "class"])
            w.writerows(rows)

    # -- time steps ----------------------------------------------------------
    # Real time steps are unequal in size; a Dirichlet split reproduces that
    # shape so the partial index and extended statistics are exercised against
    # a skewed distribution rather than a uniform one.
    weights = rng.dirichlet(np.full(N_TIME_STEPS, 6.0))
    steps = rng.choice(np.arange(1, N_TIME_STEPS + 1), size=n, p=weights)

    # -- edges ---------------------------------------------------------------
    # Constrained to within-time-step pairs, matching the real dataset: each
    # time step is its own connected component. Preferential attachment gives a
    # heavy-tailed degree distribution so the dispersal view has something to
    # find.
    edges: list[tuple[int, int]] = []
    target_ratio = 234355 / 203769           # real edge:node ratio
    for ts in range(1, N_TIME_STEPS + 1):
        idx = np.nonzero(steps == ts)[0]
        if len(idx) < 2:
            continue
        ids = tx_ids[idx]
        m = int(len(ids) * target_ratio)
        src_w = rng.pareto(1.6, len(ids)) + 1
        src_w /= src_w.sum()
        src = rng.choice(ids, size=m, p=src_w)
        dst = rng.choice(ids, size=m)
        keep = src != dst
        edges.extend(zip(src[keep].tolist(), dst[keep].tolist()))
    edges = sorted(set(edges))
    print(f"edges: {len(edges):,}")

    with (args.out / "elliptic_txs_edgelist.csv").open("w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["txId1", "txId2"])
        w.writerows(edges)

    # -- features ------------------------------------------------------------
    # No header, matching the Kaggle release, so has_header() is exercised.
    print(f"features: {n:,} x {N_FEATURES} ...", end="", flush=True)
    path = args.out / "elliptic_txs_features.csv"
    CHUNK = 20_000
    with path.open("w", newline="") as fh:
        for lo in range(0, n, CHUNK):
            hi = min(lo + CHUNK, n)
            block = rng.standard_normal((hi - lo, N_FEATURES)).astype(np.float32)
            head = np.column_stack([tx_ids[lo:hi], steps[lo:hi]])
            lines = [
                f"{a},{b}," + ",".join(f"{v:.6f}" for v in row)
                for (a, b), row in zip(head, block)
            ]
            fh.write("\n".join(lines) + "\n")
    mb = path.stat().st_size / 1e6
    print(f" {mb:,.0f} MB")

    print(f"\nFixtures written to {args.out}/  -- NOT project data.")


if __name__ == "__main__":
    main()
