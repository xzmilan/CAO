#!/usr/bin/env python3
"""
generate_wide_layer.py — Auto-discovery / auto-assembly for CustomerJourney wide tables
==========================================================================================
Scans models/metric_layer/<Entity>_Metrics/*.sql, discovers every metric file,
and regenerates the matching models/wide_layer/<Entity>Wide.sql.

So adding a metric is "drop a file in metric_layer/, run this script" — you
never need to hand-edit the wide model's OBJECT_CONSTRUCT_KEEP_NULL/JOIN lines.

WHY THIS EXISTS (read DEPLOY_HANDOFF.md §§4 and 9 first)
--------------------------------------------------------
Snowflake's server-side dbt runtime (CREATE/EXECUTE DBT PROJECT) can't see
the project's file list at compile time — it gets an EMPTY graph. So
"discover every metric file and regenerate the assembly" is IMPOSSIBLE to run
inside Snowflake today. This is a verified limitation — documented in
Snow_dbt_writeup_farmers.md §3/Step 3.

This script is the fix: it runs OUTSIDE Snowflake (locally, or as a GitHub
Action — see .github/workflows/customer_journey_ci.yml) where the real file
list is visible, and writes the wide-layer .sql files that get committed and
deployed.

Same generator pattern already proven in MESAProductDev:
  - mesa_redshift/generate_calc_views.py       (calc-file → assembled model)
  - model_zoo_bq/tools/mesa_migrate.py          (migration-time stub generator)
adapted here for CustomerJourney's specific wide-table shape: ONE
OBJECT_CONSTRUCT_KEEP_NULL(...)::OBJECT(...) column PER metric (not a
SELECT Base.*, Metrics.* pattern). This project's doctrine keeps every
metric's fields isolated in its own named OBJECT column — see
DEPLOY_HANDOFF.md §10 (OBJECT-only doctrine) and the PolicyWide/
ChangeEventWide files already in models/wide_layer/.

WHAT COUNTS AS AN "ENTITY"
---------------------------
Every subfolder of models/metric_layer/ named "<Entity>_Metrics" (e.g.
"Policy_Metrics", "ChangeEvent_Metrics") is one entity. Its raw model is
assumed to be "<Entity>Raw" (e.g. "PolicyRaw", "ChangeEventRaw") — this
matches the project's existing raw_layer/<Entity>/<Entity>Raw.sql convention.
Its wide model gets written to models/wide_layer/<Entity>Wide.sql.

HOW EACH METRIC FILE IS READ
-----------------------------
Every *.sql file directly inside an "<Entity>_Metrics/" folder is one metric
model. Filenames starting with "_" are skipped (the _policy_metrics.yml schema
files are already skipped by extension). The metric name = the filename stem
(e.g. "InForce90Flag.sql" → metric "InForce90Flag") — matching this project's
1-metric-per-file convention (see DEPLOY_HANDOFF.md §4).

Each metric's Snowflake column TYPE (needed for the ::OBJECT(<Metric> <TYPE>)
cast) is determined in this priority order:
  1. An explicit annotation comment in the file:
       -- WIDE_TYPE: NUMBER
     (case-insensitive, any Snowflake scalar type). If the heuristic below
     would guess wrong, add this comment — it's one line, reviewed in the
     same PR as the metric logic.
  2. A heuristic based on the metric's final SELECT expression. Regexes for
     common patterns: CASE...THEN 1/0 → NUMBER, TO_CHAR(...) → VARCHAR,
     AVG(...)/RATE/RATIO in the name → FLOAT, DATEDIFF/COUNT/SUM → NUMBER.
  3. Fallback: VARCHAR, with a printed WARNING telling you to add a
     WIDE_TYPE annotation. It NEVER silently guesses wrong without saying so.

JOIN TYPE (INNER vs LEFT)
--------------------------
PolicyWide INNER JOINs every metric (zero-fill contract — every policy has
every metric). ChangeEventWide LEFT JOINs (the doctrine in _wide.yml says
LEFT JOIN, even though today every event does have every flag).

Configurable per-entity via --join-type. Default reads from
JOIN_TYPE_BY_ENTITY below — extend that dict for new entities. Unset entities
default to LEFT JOIN (the safer default — never silently drops a row that
lacks one metric).

USAGE
-----
  # Regenerate all discovered entities' wide models:
  python3 tools/generate_wide_layer.py

  # Dry run — print what would be written, write nothing:
  python3 tools/generate_wide_layer.py --dry-run

  # Regenerate just one entity:
  python3 tools/generate_wide_layer.py --entity Policy

  # CI check mode — exit 1 if regenerating would CHANGE any committed file
  # (use this in GitHub Actions to fail a PR that added a metric file but
  # didn't run this script / commit the regenerated wide model):
  python3 tools/generate_wide_layer.py --check
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
MODELS_DIR = REPO_ROOT / "models"
METRIC_LAYER_DIR = MODELS_DIR / "metric_layer"
WIDE_LAYER_DIR = MODELS_DIR / "wide_layer"

# Per-entity JOIN type — extend when adding a new entity whose wide table
# should INNER JOIN (zero-fill contract) instead of the safer LEFT JOIN default.
JOIN_TYPE_BY_ENTITY: dict[str, str] = {
    "Policy": "INNER",
    "ChangeEvent": "LEFT",
}

#  Anchored to end-of-line ([^\n]+) rather than a whitespace-inclusive
# character class — the earlier version's char class included \s, which let
# it match across blank lines into the next SQL block (WITH/SELECT/...) for
# any metric file whose CTE body starts on the next non-blank line. Always
# keep this anchored to a single line.
WIDE_TYPE_ANNOTATION_RE = re.compile(r"--\s*WIDE_TYPE\s*:\s*([^\n]+)", re.IGNORECASE)

# Heuristic type-inference regexes, checked in order against the metric's
# raw SQL text. First match wins. This is intentionally conservative —
# ambiguous cases fall through to the VARCHAR-with-warning default rather
# than guessing confidently wrong.
TYPE_HEURISTICS: list[tuple[re.Pattern, str]] = [
    (re.compile(r"\bTO_CHAR\s*\(", re.IGNORECASE), "VARCHAR"),
    (re.compile(r"\bAVG\s*\(", re.IGNORECASE), "FLOAT"),
    (re.compile(r"RETENTION\s*RATE|RATIO", re.IGNORECASE), "FLOAT"),
    (re.compile(r"\bCASE\b.*?\bTHEN\s+1\b.*?\bELSE\s+0\b", re.IGNORECASE | re.DOTALL), "NUMBER"),
    # Snowflake IFF(condition, 1, 0) — same 0/1 flag pattern as CASE/WHEN, just
    # the more compact Snowflake-native form (see InForce90DaysAfterChangeFlag.sql).
    (re.compile(r"\bIFF\s*\(.*?,\s*1\s*,\s*0\s*\)", re.IGNORECASE | re.DOTALL), "NUMBER"),
    (re.compile(r"\bSUM\s*\(", re.IGNORECASE), "NUMBER"),
    (re.compile(r"\bCOUNT\s*\(", re.IGNORECASE), "NUMBER"),
    (re.compile(r"\bDATEDIFF\s*\(", re.IGNORECASE), "NUMBER"),
]


class MetricFile:
    def __init__(self, path: Path):
        self.path = path
        self.name = path.stem  # e.g. "InForce90Flag"
        self.raw_sql = path.read_text(encoding="utf-8")

    def resolve_wide_type(self) -> tuple[str, bool]:
        """Returns (snowflake_type, was_inferred). was_inferred=True means
        no explicit WIDE_TYPE annotation was found and a heuristic (or the
        VARCHAR fallback) was used — caller should warn in that case."""
        m = WIDE_TYPE_ANNOTATION_RE.search(self.raw_sql)
        if m:
            return m.group(1).strip().upper(), False

        for pattern, sf_type in TYPE_HEURISTICS:
            if pattern.search(self.raw_sql):
                return sf_type, True

        return "VARCHAR", True


class Entity:
    def __init__(self, metrics_dir: Path):
        self.metrics_dir = metrics_dir
        # "Policy_Metrics" -> "Policy" ; "ChangeEvent_Metrics" -> "ChangeEvent"
        self.name = re.sub(r"_Metrics$", "", metrics_dir.name)
        self.raw_model = f"{self.name}Raw"
        self.wide_model = f"{self.name}Wide"
        self.metrics = self._discover_metrics()

    def _discover_metrics(self) -> list[MetricFile]:
        found = []
        for sql_path in sorted(self.metrics_dir.glob("*.sql")):
            if sql_path.stem.startswith("_"):
                continue
            found.append(MetricFile(sql_path))
        return found

    @property
    def join_type(self) -> str:
        return JOIN_TYPE_BY_ENTITY.get(self.name, "LEFT")


def discover_entities(only_entity: str | None = None) -> list[Entity]:
    if not METRIC_LAYER_DIR.exists():
        print(f"ERROR: {METRIC_LAYER_DIR} does not exist.", file=sys.stderr)
        sys.exit(1)

    entities = []
    for child in sorted(METRIC_LAYER_DIR.iterdir()):
        if not child.is_dir() or not child.name.endswith("_Metrics"):
            continue
        entity = Entity(child)
        if only_entity and entity.name != only_entity:
            continue
        entities.append(entity)
    return entities


def build_wide_sql(entity: Entity) -> str:
    entity_var = entity.name  # e.g. "Policy" — used as the raw-relation alias/column name
    header = (
        f"-- WIDE LAYER: {entity.name} Wide Table\n"
        f"-- AUTO-GENERATED by tools/generate_wide_layer.py — DO NOT EDIT BY HAND.\n"
        f"-- Regenerate after adding/removing a file in models/metric_layer/{entity.metrics_dir.name}/:\n"
        f"--   python3 tools/generate_wide_layer.py --entity {entity.name}\n"
        f"-- Auto-assembly: one OBJECT per relation (raw + each metric model).\n"
        f"-- No combiner. No hand-maintained column list. Metric OBJECTs carry the\n"
        f"-- measure only — the join key ID is implicit (never selected from the\n"
        f"-- metric model directly, so it never needs stripping).\n"
        f"-- Consumer access: {entity.wide_model}.{entity_var}:<Field> / "
        f"{entity.wide_model}.<MetricName>:<MetricName> / ...\n"
    )

    raw_col_expr = f"{entity_var}.{entity_var}"
    # Single-space before AS (CAO Option-2 / MESA style — no column alignment).
    # LT01 enforces exactly one space; do not pad for alignment here or the
    # auto-generated file will fail the lint gate on every regeneration.
    select_lines = [f"    {raw_col_expr} AS {entity_var}"]
    for metric in entity.metrics:
        sf_type, inferred = metric.resolve_wide_type()
        if inferred:
            print(
                f"  WARNING: {metric.path.relative_to(REPO_ROOT)} has no '-- WIDE_TYPE: <TYPE>' "
                f"annotation — inferred {sf_type} via heuristic. Add the annotation if this is wrong.",
                file=sys.stderr,
            )
        select_lines.append(
            f"    , OBJECT_CONSTRUCT_KEEP_NULL('{metric.name}', {metric.name}.{metric.name})"
            f"::OBJECT({metric.name} {sf_type}) AS {metric.name}"
        )

    join_lines = [f"FROM {{{{ ref('{entity.raw_model}') }}}} AS {entity_var}"]
    for metric in entity.metrics:
        join_lines.append(
            f"{entity.join_type} JOIN {{{{ ref('{metric.name}') }}}} AS {metric.name}\n"
            f"    ON {entity_var}.ID = {metric.name}.ID"
        )

    body = "SELECT\n" + "\n".join(select_lines) + "\n" + "\n".join(join_lines) + "\n"
    return header + "\n" + body


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--entity", type=str, default=None, help="Regenerate only this entity (e.g. Policy).")
    parser.add_argument("--dry-run", action="store_true", help="Print generated SQL, write nothing.")
    parser.add_argument(
        "--check", action="store_true",
        help="CI mode: exit 1 if regeneration would change any committed wide-layer file.",
    )
    args = parser.parse_args(argv)

    entities = discover_entities(args.entity)
    if not entities:
        print(f"No entities found under {METRIC_LAYER_DIR} (looking for */Metrics folders).", file=sys.stderr)
        return 1

    print(f"Discovered {len(entities)} entit{'y' if len(entities) == 1 else 'ies'}:")
    for entity in entities:
        print(f"  {entity.name:15s} -> {len(entity.metrics)} metrics -> {entity.wide_model}.sql "
              f"({entity.join_type} JOIN)")

    drift_found = False
    for entity in entities:
        generated_sql = build_wide_sql(entity)
        out_path = WIDE_LAYER_DIR / f"{entity.wide_model}.sql"

        if args.check:
            existing = out_path.read_text(encoding="utf-8") if out_path.exists() else None
            if existing != generated_sql:
                drift_found = True
                print(f"\nDRIFT DETECTED: {out_path.relative_to(REPO_ROOT)} is out of date.")
                print("  Run 'python3 tools/generate_wide_layer.py' and commit the result.")
            continue

        if args.dry_run:
            print(f"\n{'-' * 70}\n-- {out_path.relative_to(REPO_ROOT)}\n{'-' * 70}")
            print(generated_sql)
        else:
            WIDE_LAYER_DIR.mkdir(parents=True, exist_ok=True)
            out_path.write_text(generated_sql, encoding="utf-8")
            print(f"  wrote {out_path.relative_to(REPO_ROOT)}")

    if args.check:
        return 1 if drift_found else 0

    if not args.dry_run:
        print("\nDone. Next step: dbt build (or re-deploy the dbt Project in Snowsight).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
