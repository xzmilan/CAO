#!/usr/bin/env python3
"""
generate_wide_layer.py — Auto-discovery / auto-assembly for CustomerJourney wide tables
==========================================================================================
Scans models/metric_layer/ for the entities discovered by the sibling
generator (tools/generate_metrics_combiner.py) and regenerates the matching
models/wide_layer/<Entity>Wide.sql as a TWO-JOIN, flat-column wide table:

    SELECT
        OBJECT_CONSTRUCT(Policy.*) AS Policy
        , OBJECT_CONSTRUCT(PolicyMetrics.*) AS PolicyMetrics
    FROM {{ ref('PolicyRaw') }} AS Policy
    JOIN {{ ref('policy_metrics') }} AS PolicyMetrics
        ON Policy.ID = PolicyMetrics.ID

This is Snowflake's qualified-wildcard OBJECT_CONSTRUCT pattern — packing a
joined relation's columns into one named OBJECT without an explicit column
list. See generate_metrics_combiner.py for why the per-metric joins live in
a combiner model instead of directly in this file.

WHY THIS EXISTS
----------------
Snowflake's server-side dbt runtime (CREATE/EXECUTE DBT PROJECT) can't see
the project's file list at compile time — it gets an EMPTY graph. So
"discover every metric file and regenerate the assembly" is IMPOSSIBLE to run
inside Snowflake itself.

This script is the fix: it runs OUTSIDE Snowflake (locally, or as a GitHub
Action — see .github/workflows/customer_journey_ci.yml and
customer_journey_deploy.yml) where the real file list is visible, and writes
the wide-layer .sql files that get committed/deployed. Run this AFTER
tools/generate_metrics_combiner.py — the wide layer now depends on the
combiner model existing, not on the individual metric files directly.

WHAT COUNTS AS AN "ENTITY"
---------------------------
Every subfolder of models/metric_layer/ named "<Entity>_Metrics" (e.g.
"Policy_Metrics", "ChangeEvent_Metrics") is one entity. Its raw model is
"<Entity>Raw". Its combiner model (built by generate_metrics_combiner.py)
is "<entity_snake>_metrics" (e.g. "policy_metrics"). Its wide model gets
written to models/wide_layer/<Entity>Wide.sql.

JOIN TYPE (INNER vs LEFT)
--------------------------
This is now the ONLY join in the wide table (raw ↔ combiner, both already
1:1 with every ID by construction — the combiner LEFT JOINs every metric
onto the full set of raw IDs, so it's already a complete superset).
PolicyWide INNER JOINs (zero-fill contract preserved — every policy has a
combiner row). ChangeEventWide LEFT JOINs, matching the pre-existing
_wide.yml doctrine. Configurable per-entity via JOIN_TYPE_BY_ENTITY below.
Unset entities default to LEFT JOIN (the safer default).

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


def _to_snake(name: str) -> str:
    """PascalCase -> snake_case (e.g. "ChangeEvent" -> "change_event")."""
    return re.sub(r"(?<!^)(?=[A-Z])", "_", name).lower()


class Entity:
    def __init__(self, metrics_dir: Path):
        self.metrics_dir = metrics_dir
        # "Policy_Metrics" -> "Policy" ; "ChangeEvent_Metrics" -> "ChangeEvent"
        self.name = re.sub(r"_Metrics$", "", metrics_dir.name)
        self.snake = _to_snake(self.name)
        self.raw_model = f"{self.name}Raw"
        self.combiner_model = f"{self.snake}_metrics"
        self.wide_model = f"{self.name}Wide"
        self.metric_count = len(self._discover_metrics())

    def _discover_metrics(self) -> list[Path]:
        found = []
        for sql_path in sorted(self.metrics_dir.glob("*.sql")):
            if sql_path.stem.startswith("_"):
                continue
            found.append(sql_path)
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
    entity_var = entity.name  # e.g. "Policy" — raw-relation alias
    metrics_var = f"{entity.name}Metrics"  # e.g. "PolicyMetrics" — combiner alias

    header = (
        f"-- WIDE LAYER: {entity.name} Wide Table (AUTO-GENERATED)\n"
        f"-- AUTO-GENERATED by tools/generate_wide_layer.py — DO NOT EDIT BY HAND.\n"
        f"-- Snowflake OBJECT_CONSTRUCT(alias.*) — qualified wildcard, auto-expanding.\n"
        f"-- No explicit column list, no logic, zero maintenance.\n"
        f"-- Regenerate after adding/removing a file in models/metric_layer/{entity.metrics_dir.name}/:\n"
        f"--   python3 tools/generate_metrics_combiner.py --entity {entity.name}\n"
        f"--   python3 tools/generate_wide_layer.py --entity {entity.name}\n"
        f"-- (run the combiner generator FIRST — the wide layer joins against\n"
        f"-- its output, {entity.combiner_model}, not the individual metric files.)\n"
        f"-- Owner: CI/CD (mechanically generated, do not edit by hand)\n"
        f"--\n"
        f"-- HOW IT WORKS (Snowflake):\n"
        f"--   OBJECT_CONSTRUCT({entity_var}.*) packs the entire row from the {entity_var} alias into a named OBJECT.\n"
        f"--   OBJECT_CONSTRUCT({metrics_var}.*) does the same for the combined metrics alias.\n"
        f"--   The qualified wildcard (alias.*) ensures each OBJECT only contains columns from its own source.\n"
        f"--   Adding a column upstream (a new metric file + combiner regen) expands the OBJECT automatically —\n"
        f"--   nothing downstream breaks.\n"
        f"--\n"
        f"--   NOTE: bare OBJECT_CONSTRUCT(*) after a JOIN is WRONG — it packs ALL joined columns into BOTH objects.\n"
        f"--   Always qualify with the alias: OBJECT_CONSTRUCT({entity_var}.*), OBJECT_CONSTRUCT({metrics_var}.*).\n"
        f"-- Consumer access: {entity.wide_model}.{entity_var}:<Field> / {entity.wide_model}.{metrics_var}:<MetricName> / ...\n"
    )

    body = (
        f"SELECT\n"
        f"    OBJECT_CONSTRUCT({entity_var}.*) AS {entity_var}\n"
        f"    , OBJECT_CONSTRUCT({metrics_var}.*) AS {metrics_var}\n"
        f"FROM {{{{ ref('{entity.raw_model}') }}}} AS {entity_var}\n"
        f"{entity.join_type} JOIN {{{{ ref('{entity.combiner_model}') }}}} AS {metrics_var}\n"
        f"    ON {entity_var}.ID = {metrics_var}.ID\n"
    )

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
        print(f"  {entity.name:15s} -> {entity.metric_count} metrics -> {entity.combiner_model}.sql -> {entity.wide_model}.sql "
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
