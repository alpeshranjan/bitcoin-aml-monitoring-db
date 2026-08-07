#!/usr/bin/env python3
"""
Emits docs/data_dictionary.md from the live PostgreSQL catalog.

    python3 etl/gen_data_dictionary.py --dsn "postgresql://user@host/db"

The dictionary is a description of what was actually built, so it is read back
out of the catalog rather than maintained alongside it. Table comments, column
comments and row counts all come from the database; nothing here restates the
schema from memory, which is what lets the file stay correct when the schema
changes.
"""
from __future__ import annotations

import argparse
import textwrap
from pathlib import Path

import psycopg2

SCHEMAS = ("core", "analytics", "governance")

RELATIONS = """
SELECT n.nspname                       AS schema_name,
       c.relname                       AS rel_name,
       CASE c.relkind WHEN 'r' THEN 'table'
                      WHEN 'p' THEN 'partitioned table'
                      WHEN 'v' THEN 'view'
                      WHEN 'm' THEN 'materialized view' END AS rel_kind,
       obj_description(c.oid, 'pg_class')                   AS rel_comment,
       c.relrowsecurity                                     AS rls_enabled
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = ANY(%s)
  AND c.relkind IN ('r', 'p', 'v', 'm')
  AND NOT c.relispartition        -- individual partitions are an implementation
                                  -- detail of their parent, not separate objects
ORDER BY n.nspname, c.relname
"""

COLUMNS = """
SELECT a.attname                                        AS column_name,
       format_type(a.atttypid, a.atttypmod)             AS data_type,
       a.attnotnull                                     AS not_null,
       col_description(a.attrelid, a.attnum)            AS column_comment
FROM pg_attribute a
WHERE a.attrelid = %s::regclass AND a.attnum > 0 AND NOT a.attisdropped
ORDER BY a.attnum
"""

FUNCTIONS = """
SELECT n.nspname                                   AS schema_name,
       p.proname                                   AS func_name,
       pg_get_function_arguments(p.oid)            AS args,
       pg_get_function_result(p.oid)               AS returns,
       obj_description(p.oid, 'pg_proc')           AS func_comment,
       p.prokind                                   AS kind
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = ANY(%s) AND p.prokind IN ('f', 'p')
ORDER BY n.nspname, p.proname
"""

# The feature table is 165 columns of identical shape. Listing all of them adds
# 165 lines that say the same thing; the pattern is stated instead.
COLLAPSE = {"core.tx_feature": ("local_feature_", "aggregate_feature_")}


def wrap(text: str | None, width: int = 98) -> str:
    if not text:
        return "_No description recorded in the catalog._"
    return "\n".join(textwrap.wrap(" ".join(text.split()), width=width))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn", required=True)
    ap.add_argument("--out", type=Path,
                    default=Path(__file__).resolve().parents[1] / "docs" / "data_dictionary.md")
    args = ap.parse_args()

    out: list[str] = [
        "# Data Dictionary",
        "",
        "Generated from the live PostgreSQL catalog by `etl/gen_data_dictionary.py` after a",
        "successful load. Do not edit by hand — regenerate.",
        "",
    ]

    with psycopg2.connect(args.dsn) as conn, conn.cursor() as cur:
        cur.execute(RELATIONS, (list(SCHEMAS),))
        relations = cur.fetchall()

        for schema, name, kind, comment, rls in relations:
            qualified = f"{schema}.{name}"
            heading = f"## `{qualified}`  *({kind}"
            if kind in ("table", "partitioned table"):
                cur.execute(f'SELECT COUNT(*) FROM "{schema}"."{name}"')
                heading += f", {cur.fetchone()[0]:,} rows"
            out += [heading + ")*", ""]
            if rls:
                out += ["**Row-level security is enabled on this table.** Visible rows depend "
                        "on the querying role; see `sql/07_access_control.sql`.", ""]
            out += [wrap(comment), ""]

            cur.execute(COLUMNS, (qualified,))
            cols = cur.fetchall()

            prefixes = COLLAPSE.get(qualified, ())
            shown, collapsed = [], {p: 0 for p in prefixes}
            for col in cols:
                hit = next((p for p in prefixes if col[0].startswith(p)), None)
                if hit:
                    collapsed[hit] += 1
                else:
                    shown.append(col)

            out += ["| Column | Type | Null | Notes |", "|---|---|---|---|"]
            for col_name, data_type, not_null, col_comment in shown:
                out.append(
                    f"| `{col_name}` | {data_type} | {'NOT NULL' if not_null else ''} "
                    f"| {' '.join((col_comment or '').split())} |"
                )
            for prefix, n in collapsed.items():
                if n:
                    out.append(
                        f"| `{prefix}1` … `{prefix}{n}` | double precision | NOT NULL "
                        f"| {n} columns, identical shape. Obfuscated by the publisher; see "
                        f"`core.dim_feature`. |"
                    )
            out.append("")

        cur.execute(FUNCTIONS, (list(SCHEMAS),))
        funcs = cur.fetchall()
        if funcs:
            out += ["## Functions and procedures", ""]
            for schema, fname, fargs, freturns, fcomment, kind in funcs:
                out += [f"### `{schema}.{fname}({fargs})`", ""]
                if kind == "p":
                    out += ["Procedure — invoked with `CALL`, returns no value.", ""]
                else:
                    out += [f"Returns `{freturns}`.", ""]
                out += [wrap(fcomment), ""]

    args.out.write_text("\n".join(out))
    print(f"wrote {args.out} "
          f"({len(relations)} relations, {len(funcs)} functions)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
