#!/usr/bin/env python3
"""
ANLC-752 Course Project -- ETL pipeline for the Elliptic Data Set.

    python3 etl/etl_load.py --data-dir ./data --dsn "postgresql://user@host/db"

Design:

  Extract    stream each CSV to a text-typed staging table via COPY. No parsing,
             no casting -- a malformed value must fail a named data quality rule
             where it can be reported, not an implicit cast inside COPY where it
             surfaces as an opaque error on an unknown line.

  Validate   run declarative rules against staging. Rules are data, not code
             (see QualityRule below), so adding a rule does not mean editing the
             pipeline. ERROR-severity failures abort before core is touched.

  Transform  cast, map class codes to surrogate keys, quarantine rejects.

  Load       insert into core inside a single transaction per target table.

The whole run is one database transaction. A partial load is never visible.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import io
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

import psycopg2
from psycopg2 import sql as psql

N_LOCAL, N_AGG = 93, 72
FEATURE_COLS = (
    [f"local_feature_{i}" for i in range(1, N_LOCAL + 1)]
    + [f"aggregate_feature_{i}" for i in range(1, N_AGG + 1)]
)

# The Kaggle release ships elliptic_txs_*.csv; the Elliptic++ release ships
# txs_*.csv with the same content. Accept either rather than making the analyst
# rename files.
FILE_ALIASES = {
    "classes":  ["elliptic_txs_classes.csv",  "txs_classes.csv"],
    "edgelist": ["elliptic_txs_edgelist.csv", "txs_edgelist.csv"],
    "features": ["elliptic_txs_features.csv", "txs_features.csv"],
}

CLASS_CODE_MAP = {"1": 1, "2": 2, "unknown": 3, "3": 3}


# ---------------------------------------------------------------------------
# Data quality rules
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class QualityRule:
    name: str
    check_type: str          # completeness | uniqueness | referential | domain | reconciliation
    severity: str            # INFO | WARN | ERROR
    query: str               # must return exactly one row: (actual, passed)
    expected: str


STAGING_RULES: list[QualityRule] = [
    QualityRule(
        "classes_row_count_nonzero", "completeness", "ERROR",
        "SELECT COUNT(*)::TEXT, COUNT(*) > 0 FROM staging.txs_classes",
        "> 0",
    ),
    QualityRule(
        "classes_tx_id_unique", "uniqueness", "ERROR",
        """SELECT COUNT(*)::TEXT, COUNT(*) = 0 FROM (
               SELECT tx_id FROM staging.txs_classes
               GROUP BY tx_id HAVING COUNT(*) > 1) d""",
        "0 duplicate tx_id",
    ),
    QualityRule(
        "classes_code_in_domain", "domain", "ERROR",
        """SELECT COUNT(*)::TEXT, COUNT(*) = 0 FROM staging.txs_classes
           WHERE class_code NOT IN ('1','2','3','unknown')""",
        "0 out-of-domain class codes",
    ),
    QualityRule(
        "features_tx_id_unique", "uniqueness", "ERROR",
        """SELECT COUNT(*)::TEXT, COUNT(*) = 0 FROM (
               SELECT tx_id FROM staging.txs_features
               GROUP BY tx_id HAVING COUNT(*) > 1) d""",
        "0 duplicate tx_id",
    ),
    QualityRule(
        "features_time_step_in_range", "domain", "ERROR",
        """SELECT COUNT(*)::TEXT, COUNT(*) = 0 FROM staging.txs_features
           WHERE time_step !~ '^[0-9]+$' OR time_step::INT NOT BETWEEN 1 AND 49""",
        "all time steps in 1..49",
    ),
    QualityRule(
        # The two files are independent extracts. If their tx_id sets diverge,
        # core.transaction cannot be built without silently dropping rows.
        "classes_features_tx_id_reconcile", "reconciliation", "ERROR",
        """WITH a AS (SELECT tx_id FROM staging.txs_classes),
                b AS (SELECT tx_id FROM staging.txs_features)
           SELECT ((SELECT COUNT(*) FROM (SELECT tx_id FROM a EXCEPT SELECT tx_id FROM b) x)
                 + (SELECT COUNT(*) FROM (SELECT tx_id FROM b EXCEPT SELECT tx_id FROM a) y))::TEXT,
                  ((SELECT COUNT(*) FROM (SELECT tx_id FROM a EXCEPT SELECT tx_id FROM b) x)
                 + (SELECT COUNT(*) FROM (SELECT tx_id FROM b EXCEPT SELECT tx_id FROM a) y)) = 0""",
        "0 symmetric difference",
    ),
    QualityRule(
        # Edges referencing an unknown node would violate the FK on load. Catch
        # it here so the report names the count instead of the FK naming one row.
        "edgelist_endpoints_resolve", "referential", "ERROR",
        """SELECT COUNT(*)::TEXT, COUNT(*) = 0 FROM (
               SELECT src_tx_id AS t FROM staging.txs_edgelist
               UNION SELECT dst_tx_id FROM staging.txs_edgelist
           ) e WHERE NOT EXISTS (
               SELECT 1 FROM staging.txs_classes c WHERE c.tx_id = e.t)""",
        "0 unresolved endpoints",
    ),
    QualityRule(
        "edgelist_no_self_loops", "domain", "WARN",
        """SELECT COUNT(*)::TEXT, COUNT(*) = 0 FROM staging.txs_edgelist
           WHERE src_tx_id = dst_tx_id""",
        "0 self-loops",
    ),
    QualityRule(
        # All 165 columns, not a sample. The predicate is long but it is
        # generated from FEATURE_COLS, so it cannot drift from the schema, and
        # PostgreSQL short-circuits the OR chain on the first non-null column.
        "features_no_null_values", "completeness", "ERROR",
        f"""SELECT COUNT(*)::TEXT, COUNT(*) = 0 FROM staging.txs_features
            WHERE {' OR '.join(f'{c} IS NULL' for c in FEATURE_COLS)}""",
        "0 nulls across all 165 feature columns",
    ),
]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

@dataclass
class RunReport:
    batches: list[dict] = field(default_factory=list)
    rules: list[dict] = field(default_factory=list)


def resolve(data_dir: Path, key: str) -> Path:
    for name in FILE_ALIASES[key]:
        p = data_dir / name
        if p.exists():
            return p
    raise FileNotFoundError(
        f"none of {FILE_ALIASES[key]} found in {data_dir}. "
        "Download the Elliptic Data Set first -- see docs/data_source_summary.md."
    )


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def has_header(path: Path, expect_numeric_first: bool = True) -> bool:
    """The Kaggle feature file has no header; the Elliptic++ one does."""
    with path.open("r", newline="") as fh:
        first = next(csv.reader(fh))
    if not first:
        return False
    try:
        float(first[0])
        return False
    except ValueError:
        return True


def open_audit(cur, source: Path, target: str, rows: int | None = None) -> int:
    cur.execute(
        """INSERT INTO governance.etl_load_audit
               (source_file, source_bytes, source_sha256, target_table, rows_extracted)
           VALUES (%s, %s, %s, %s, %s) RETURNING load_batch_id""",
        (source.name, source.stat().st_size, sha256(source), target, rows),
    )
    return cur.fetchone()[0]


def close_audit(cur, batch_id: int, loaded: int, rejected: int = 0,
                status: str = "SUCCESS", notes: str | None = None) -> None:
    cur.execute(
        """UPDATE governance.etl_load_audit
              SET rows_loaded = %s, rows_rejected = %s, status = %s,
                  finished_at = now(), notes = %s
            WHERE load_batch_id = %s""",
        (loaded, rejected, status, notes, batch_id),
    )


# ---------------------------------------------------------------------------
# Extract
# ---------------------------------------------------------------------------

def copy_csv(cur, path: Path, table: str, columns: list[str],
             skip_header: bool) -> int:
    """Stream a CSV into a staging table. Never materialises the file in memory."""
    cols = psql.SQL(", ").join(psql.Identifier(c) for c in columns)
    stmt = psql.SQL("COPY {}.{} ({}) FROM STDIN WITH (FORMAT csv, HEADER {})").format(
        psql.Identifier(table.split(".")[0]),
        psql.Identifier(table.split(".")[1]),
        cols,
        psql.SQL("true" if skip_header else "false"),
    )
    with path.open("r", newline="") as fh:
        cur.copy_expert(stmt, fh)
    cur.execute(psql.SQL("SELECT COUNT(*) FROM {}.{}").format(
        psql.Identifier(table.split(".")[0]), psql.Identifier(table.split(".")[1])))
    return cur.fetchone()[0]


def extract(cur, data_dir: Path, report: RunReport) -> dict[str, int]:
    batches: dict[str, int] = {}
    spec = [
        ("classes",  "staging.txs_classes",  ["tx_id", "class_code"]),
        ("edgelist", "staging.txs_edgelist", ["src_tx_id", "dst_tx_id"]),
        ("features", "staging.txs_features", ["tx_id", "time_step"] + FEATURE_COLS),
    ]
    for key, table, cols in spec:
        path = resolve(data_dir, key)
        t0 = time.time()
        batch_id = open_audit(cur, path, table)
        n = copy_csv(cur, path, table, cols, skip_header=has_header(path))
        cur.execute(
            "UPDATE governance.etl_load_audit SET rows_extracted=%s WHERE load_batch_id=%s",
            (n, batch_id))
        batches[key] = batch_id
        report.batches.append({
            "file": path.name, "target": table, "rows": n,
            "seconds": round(time.time() - t0, 2),
        })
        print(f"  extracted {n:>9,} rows  {path.name:<32} -> {table} "
              f"({time.time()-t0:.1f}s)")
    return batches


# ---------------------------------------------------------------------------
# Validate
# ---------------------------------------------------------------------------

def validate(cur, batches: dict[str, int], report: RunReport) -> bool:
    ok = True
    print("\n  Data quality rules")
    for rule in STAGING_RULES:
        cur.execute(rule.query)
        actual, passed = cur.fetchone()
        cur.execute(
            """INSERT INTO governance.dq_check_result
                   (load_batch_id, check_name, check_type, severity,
                    expected_value, actual_value, passed)
               VALUES (%s,%s,%s,%s,%s,%s,%s)""",
            (batches.get("classes"), rule.name, rule.check_type, rule.severity,
             rule.expected, str(actual), bool(passed)),
        )
        report.rules.append({
            "name": rule.name, "severity": rule.severity,
            "expected": rule.expected, "actual": str(actual), "passed": bool(passed),
        })
        mark = "PASS" if passed else ("FAIL" if rule.severity == "ERROR" else "WARN")
        print(f"    [{mark:<4}] {rule.name:<38} expected {rule.expected:<32} got {actual}")
        if not passed and rule.severity == "ERROR":
            ok = False
    return ok


# ---------------------------------------------------------------------------
# Transform + Load
# ---------------------------------------------------------------------------

def load_core(cur, batches: dict[str, int], report: RunReport) -> None:
    print("\n  Loading core")

    # Idempotency. A re-run against an already-populated database must produce
    # the same result as a run against an empty one, not a primary key
    # violation. All five tables are named in one statement so PostgreSQL
    # resolves the foreign keys among them; this is inside the run's single
    # transaction, so a later failure restores the previous contents.
    cur.execute("""TRUNCATE core.tx_flow, core.tx_feature, core.transaction,
                            core.dim_feature, core.dim_time_step""")

    # -- dimensions ---------------------------------------------------------
    cur.execute("""
        INSERT INTO core.dim_time_step (time_step, description)
        SELECT DISTINCT time_step::SMALLINT,
               'Connected component of transactions within an approx. two-week window'
        FROM staging.txs_features
        ORDER BY 1
    """)
    print(f"    dim_time_step        {cur.rowcount:>9,}")

    cur.executemany(
        """INSERT INTO core.dim_feature
               (feature_id, column_name, feature_group, ordinal_in_group,
                is_obfuscated, description)
           VALUES (%s,%s,%s,%s,TRUE,%s)""",
        [
            (i + 1, c, ("local" if c.startswith("local") else "aggregate"),
             int(c.rsplit("_", 1)[1]),
             "Anonymised local transaction attribute; not mappable to a real-world field."
             if c.startswith("local") else
             "Anonymised aggregate of one-hop neighbour statistics.")
            for i, c in enumerate(FEATURE_COLS)
        ],
    )
    print(f"    dim_feature          {len(FEATURE_COLS):>9,}")

    # -- core.transaction ---------------------------------------------------
    # Inner join is intentional: a tx_id present in only one file has already
    # failed the reconciliation rule, so reaching here means the sets match.
    # The class mapping is declared once in CLASS_CODE_MAP and rendered into the
    # CASE here, so the domain rule and the transform cannot drift apart. The map
    # holds only literal constants defined in this module -- no external input
    # reaches this string.
    class_case = " ".join(f"WHEN '{code}' THEN {cid}"
                          for code, cid in CLASS_CODE_MAP.items())
    cur.execute(
        """INSERT INTO core.transaction (tx_id, time_step, class_id, load_batch_id)
           SELECT f.tx_id::BIGINT,
                  f.time_step::SMALLINT,
                  CASE c.class_code {class_case} ELSE 3 END,
                  %s
             FROM staging.txs_features f
             JOIN staging.txs_classes  c ON c.tx_id = f.tx_id""".format(class_case=class_case),
        (batches["classes"],),
    )
    n_tx = cur.rowcount
    # The audit row's target_table is staging.txs_classes, so rows_loaded is the
    # staging count. What the conformed model received is recorded in notes
    # rather than silently substituted for the staging figure.
    cur.execute("SELECT COUNT(*) FROM staging.txs_classes")
    close_audit(cur, batches["classes"], cur.fetchone()[0],
                notes=f"core.transaction received {n_tx} rows")
    print(f"    core.transaction     {n_tx:>9,}")

    # -- core.tx_feature ----------------------------------------------------
    cols = ", ".join(FEATURE_COLS)
    casts = ", ".join(f"{c}::DOUBLE PRECISION" for c in FEATURE_COLS)
    cur.execute(f"""
        INSERT INTO core.tx_feature (tx_id, {cols})
        SELECT tx_id::BIGINT, {casts} FROM staging.txs_features
    """)
    n_feat = cur.rowcount
    cur.execute("SELECT COUNT(*) FROM staging.txs_features")
    close_audit(cur, batches["features"], cur.fetchone()[0],
                notes=f"core.tx_feature received {n_feat} rows")
    print(f"    core.tx_feature      {n_feat:>9,}")

    # -- core.tx_flow -------------------------------------------------------
    # Self-loops are quarantined rather than dropped: the CHECK constraint would
    # reject them anyway, and a silent DELETE would hide a source data problem.
    cur.execute(
        """INSERT INTO governance.rejected_row
               (load_batch_id, source_file, reject_reason, raw_payload)
           SELECT %s, 'edgelist', 'self-loop violates ck_tx_flow_no_self_loop',
                  src_tx_id || ',' || dst_tx_id
             FROM staging.txs_edgelist WHERE src_tx_id = dst_tx_id""",
        (batches["edgelist"],),
    )
    n_rej = cur.rowcount

    cur.execute(
        """INSERT INTO core.tx_flow (src_tx_id, dst_tx_id, load_batch_id)
           SELECT DISTINCT src_tx_id::BIGINT, dst_tx_id::BIGINT, %s
             FROM staging.txs_edgelist
            WHERE src_tx_id <> dst_tx_id""",
        (batches["edgelist"],),
    )
    n_edge = cur.rowcount
    cur.execute("SELECT COUNT(*) FROM staging.txs_edgelist")
    close_audit(cur, batches["edgelist"], cur.fetchone()[0], rejected=n_rej,
                notes=f"core.tx_flow received {n_edge} rows")
    print(f"    core.tx_flow         {n_edge:>9,}"
          + (f"   ({n_rej:,} quarantined)" if n_rej else ""))

    report.batches.append({"summary": True, "transactions": n_tx,
                           "features": n_feat, "edges": n_edge, "rejected": n_rej})


def _sql_root() -> Path:
    """Locate the SQL directory whether the project is laid out as
    sql/ + etl/ or shipped as a single flat folder."""
    here = Path(__file__).resolve().parent
    for candidate in (here.parent / "sql", here / "sql", here):
        if (candidate / "02_indexes.sql").exists():
            return candidate
    raise FileNotFoundError(
        "02_indexes.sql not found next to etl_load.py or in ../sql/")


def post_load(cur) -> None:
    print("\n  Building indexes and analytics layer")
    root = _sql_root()
    for f in ("02_indexes.sql", "03_analytics.sql", "04_analysis.sql"):
        cur.execute((root / f).read_text())
        print(f"    applied {f}")
    cur.execute("TRUNCATE staging.txs_classes, staging.txs_edgelist, staging.txs_features")
    print("    staging truncated")


# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description="Load the Elliptic Data Set into PostgreSQL.")
    ap.add_argument("--data-dir", type=Path, default=Path("data"))
    ap.add_argument("--dsn", required=True)
    ap.add_argument("--skip-post", action="store_true",
                    help="Load core only; do not build indexes or analytics objects.")
    args = ap.parse_args()

    report = RunReport()
    t0 = time.time()
    print(f"ETL run  data-dir={args.data_dir}")

    conn = psycopg2.connect(args.dsn)
    try:
        with conn, conn.cursor() as cur:
            print("\n  Extracting to staging")
            batches = extract(cur, args.data_dir, report)

            if not validate(cur, batches, report):
                # The context manager rolls back on exception, so core is
                # untouched -- but the audit rows roll back too. Persist the
                # failure on a separate connection before aborting.
                raise SystemExit(_record_failure(args.dsn, report))

            load_core(cur, batches, report)
            if not args.skip_post:
                post_load(cur)

        print(f"\nCommitted in {time.time()-t0:.1f}s")
        return 0
    finally:
        conn.close()


def _record_failure(dsn: str, report: RunReport) -> str:
    with psycopg2.connect(dsn) as c2, c2.cursor() as k:
        for r in report.rules:
            if not r["passed"] and r["severity"] == "ERROR":
                k.execute(
                    """INSERT INTO governance.dq_check_result
                           (check_name, check_type, severity, expected_value,
                            actual_value, passed)
                       VALUES (%s,'reconciliation','ERROR',%s,%s,FALSE)""",
                    (r["name"] + " [aborted run]", r["expected"], r["actual"]),
                )
    failed = [r["name"] for r in report.rules if not r["passed"] and r["severity"] == "ERROR"]
    return f"ABORTED -- ERROR-severity rules failed: {', '.join(failed)}. Core not modified."


if __name__ == "__main__":
    sys.exit(main())
