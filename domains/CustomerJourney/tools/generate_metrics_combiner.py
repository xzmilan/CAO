#!/usr/bin/env python3
"""
generate_metrics_combiner.py — Auto-discovery / auto-assembly for CustomerJourney metric combiners
=====================================================================================================
Scans models/metric_layer/<Entity>_Metrics/*.sql, discovers every metric
file, and regenerates a single flat combiner model
models/metric_layer/<entity_snake>_metrics.sql — one row per raw entity ID,
every metric as its own COALESCE-defaulted column.

WHY A COMBINER
---------------
The combiner collapses N metric-file joins into ONE joined, flat-columned
table per entity. That flat table is what lets the Wide Layer use
Snowflake's OBJECT_CONSTRUCT(alias.*) qualified-wildcard pattern (see
generate_wide_layer.py) instead of hand-building one ::OBJECT(...) cast per
metric. The combiner is the "ugly" file now — one LEFT JOIN per metric,
moved out of the Wide Layer so the Wide Layer stays a two-join pass-through.

WHAT COUNTS AS AN "ENTITY"
---------------------------
Same discovery rule as generate_wide_layer.py: every subfolder of
models/metric_layer/ named "<Entity>_Metrics" is one entity. Its raw model
is "<Entity>Raw". Its combiner is written to
models/metric_layer/<entity_snake>_metrics.sql — a singular combiner file
living at the metric_layer/ ROOT, not inside the entity's _Metrics/
subfolder.

JOIN SEMANTICS
--------------
Every metric file in this project already anchors on its own entity's raw
model with a LEFT JOIN (see each file's "Contract: 1 row per <entity> ID
= 1:1" comment) — so the combiner always LEFT JOINs each metric onto the
raw entity and COALESCEs a typed default. This preserves full row coverage
even if a future metric breaks the 1:1 contract — the row survives with a
COALESCE default instead of disappearing (the "defensive" BigQuery-style
behavior, not CAO's old "fail loud" INNER-JOIN-in-the-wide-layer behavior).
If you want fail-loud semantics back for a specific entity, that's a
Wide-Layer-level decision now, not a combiner-level one — the Wide Layer
still INNER/LEFT JOINs the raw entity to the combiner per
JOIN_TYPE_BY_ENTITY in generate_wide_layer.py.

COALESCE DEFAULT INFERENCE
----------------------------
Same priority order as the WIDE_TYPE annotation in generate_wide_layer.py,
but resolving a *default value* instead of a Snowflake column type:
  1. An explicit annotation comment in the metric file:
       -- COMBINER_DEFAULT: 0
     (case-insensitive; the raw literal is inserted verbatim into
     COALESCE(..., <literal>) — quote it yourself if it's a string).
  2. A heuristic based on the metric's final SELECT expression — same
     regex family as generate_wide_layer.py's TYPE_HEURISTICS, mapped to a
     representative default value per inferred type.
  3. Fallback: NULL is never COALESCEd (dbt_render.py's
     _coalesce_default() convention) — if no default can be inferred, the
     metric column passes through with a raw LEFT JOIN, no COALESCE. This
     matches metrics like AverageOrderValue-style scores where "no data"
     legitimately means NULL, not a zero-filled default.

USAGE
-----
  # Regenerate all discovered entities' combiners:
  python3 tools/generate_metrics_combiner.py

  # Dry run — print what would be written, write nothing:
  python3 tools/generate_metrics_combiner.py --dry-run

  # Regenerate just one entity:
  python3 tools/generate_metrics_combiner.py --entity Policy

  # CI check mode — exit 1 if regenerating would CHANGE any committed file:
  python3 tools/generate_metrics_combiner.py --check
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
MODELS_DIR = REPO_ROOT / "models"
METRIC_LAYER_DIR = MODELS_DIR / "metric_layer"

COMBINER_DEFAULT_ANNOTATION_RE = re.compile(r"--\s*COMBINER_DEFAULT\s*:\s*([^\n]+)", re.IGNORECASE)

# Heuristic default-value inference, checked in order against the metric's
# raw SQL text. First match wins. Conservative on purpose — an ambiguous
# metric falls through to "no COALESCE, pass NULL through" rather than
# guessing a default that could be silently wrong (e.g. defaulting an NPS
# score to 0 would look like a real, terrible score instead of "no data").
DEFAULT_HEURISTICS: list[tuple[re.Pattern, str]] = [
    (re.compile(r"\bCASE\b.*?\bTHEN\s+1\b.*?\bELSE\s+0\b", re.IGNORECASE | re.DOTALL), "0"),
    (re.compile(r"\bIFF\s*\(.*?,\s*1\s*,\s*0\s*\)", re.IGNORECASE | re.DOTALL), "0"),
    (re.compile(r"\bSUM\s*\(", re.IGNORECASE), "0"),
    (re.compile(r"\bCOUNT\s*\(", re.IGNORECASE), "0"),
]

# Metrics with survey/score-style averages (AVG(...) with no SUM/COUNT
# wrapper) are deliberately EXCLUDED from DEFAULT_HEURISTICS above — NULL
# ("no survey response") must stay NULL, never zero-filled, or a policy
# with no agent-change survey would look like it scored a 0 CSAT.


class MetricFile:
    def __init__(self, path: Path):
        self.path = path
        self.name = path.stem  # e.g. "InForce90Flag"
        self.raw_sql = path.read_text(encoding="utf-8")

    def resolve_combiner_default(self) -> str | None:
        """Returns the literal default expression to COALESCE with, or None
        if no default should be applied (metric passes through raw)."""
        m = COMBINER_DEFAULT_ANNOTATION_RE.search(self.raw_sql)
        if m:
            return m.group(1).strip()

        for pattern, default in DEFAULT_HEURISTICS:
            if pattern.search(self.raw_sql):
                return default

        return None


class Entity:
    def __init__(self, metrics_dir: Path):
        self.metrics_dir = metrics_dir
        # "Policy_Metrics" -> "Policy" ; "ChangeEvent_Metrics" -> "ChangeEvent"
        self.name = re.sub(r"_Metrics$", "", metrics_dir.name)
        self.snake = _to_snake(self.name)
        self.raw_model = f"{self.name}Raw"
        self.combiner_model = f"{self.snake}_metrics"
        self.metrics = self._discover_metrics()

    def _discover_metrics(self) -> list[MetricFile]:
        found = []
        for sql_path in sorted(self.metrics_dir.glob("*.sql")):
            if sql_path.stem.startswith("_"):
                continue
            found.append(MetricFile(sql_path))
        return found


def _to_snake(name: str) -> str:
    """PascalCase -> snake_case (e.g. "ChangeEvent" -> "change_event")."""
    return re.sub(r"(?<!^)(?=[A-Z])", "_", name).lower()


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


def build_combiner_sql(entity: Entity) -> str:
    header = (
        f"-- METRIC COMBINER: {entity.name} Metrics (AUTO-GENERATED)\n"
        f"-- AUTO-GENERATED by tools/generate_metrics_combiner.py — DO NOT EDIT BY HAND.\n"
        f"-- Regenerate after adding/removing a file in models/metric_layer/{entity.metrics_dir.name}/:\n"
        f"--   python3 tools/generate_metrics_combiner.py --entity {entity.name}\n"
        f"-- Assembled from every individual metric file in {entity.metrics_dir.name}/.\n"
        f"-- Contract: 1 row per {entity.raw_model} ID, every metric as a column.\n"
        f"-- LEFT JOIN per metric (defensive — a metric missing a row zero-fills\n"
        f"-- via COALESCE where a safe default exists; otherwise passes NULL\n"
        f"-- through, e.g. survey-average metrics where NULL means 'no response',\n"
        f"-- never a real zero score).\n"
    )

    if not entity.metrics:
        body = (
            f"SELECT\n"
            f"    {entity.name}.ID\n"
            f"FROM {{{{ ref('{entity.raw_model}') }}}} AS {entity.name}\n"
        )
        return header + "\n" + body

    cte_parts = []
    for metric in entity.metrics:
        cte_parts.append(
            f"{metric.name} AS (\n    SELECT * FROM {{{{ ref('{metric.name}') }}}}\n)"
        )
    cte_block = "WITH " + "\n, ".join(cte_parts)

    select_lines = [f"    {entity.name}.ID"]
    for metric in entity.metrics:
        default = metric.resolve_combiner_default()
        if default is None:
            select_lines.append(f"    , {metric.name}.{metric.name}")
        else:
            select_lines.append(
                f"    , COALESCE({metric.name}.{metric.name}, {default}) AS {metric.name}"
            )

    join_lines = [f"FROM {{{{ ref('{entity.raw_model}') }}}} AS {entity.name}"]
    for metric in entity.metrics:
        join_lines.append(
            f"LEFT JOIN {metric.name}\n"
            f"    ON {entity.name}.ID = {metric.name}.ID"
        )

    body = (
        cte_block + "\n\n"
        + "SELECT\n" + "\n".join(select_lines) + "\n"
        + "\n".join(join_lines) + "\n"
    )
    return header + "\n" + body


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--entity", type=str, default=None, help="Regenerate only this entity (e.g. Policy).")
    parser.add_argument("--dry-run", action="store_true", help="Print generated SQL, write nothing.")
    parser.add_argument(
        "--check", action="store_true",
        help="CI mode: exit 1 if regeneration would change any committed combiner file.",
    )
    args = parser.parse_args(argv)

    entities = discover_entities(args.entity)
    if not entities:
        print(f"No entities found under {METRIC_LAYER_DIR} (looking for */_Metrics folders).", file=sys.stderr)
        return 1

    print(f"Discovered {len(entities)} entit{'y' if len(entities) == 1 else 'ies'}:")
    for entity in entities:
        print(f"  {entity.name:15s} -> {len(entity.metrics)} metrics -> {entity.combiner_model}.sql")

    drift_found = False
    for entity in entities:
        generated_sql = build_combiner_sql(entity)
        out_path = METRIC_LAYER_DIR / f"{entity.combiner_model}.sql"

        if args.check:
            existing = out_path.read_text(encoding="utf-8") if out_path.exists() else None
            if existing != generated_sql:
                drift_found = True
                print(f"\nDRIFT DETECTED: {out_path.relative_to(REPO_ROOT)} is out of date.")
                print("  Run 'python3 tools/generate_metrics_combiner.py' and commit the result.")
            continue

        if args.dry_run:
            print(f"\n{'-' * 70}\n-- {out_path.relative_to(REPO_ROOT)}\n{'-' * 70}")
            print(generated_sql)
        else:
            METRIC_LAYER_DIR.mkdir(parents=True, exist_ok=True)
            out_path.write_text(generated_sql, encoding="utf-8")
            print(f"  wrote {out_path.relative_to(REPO_ROOT)}")

    if args.check:
        return 1 if drift_found else 0

    if not args.dry_run:
        print("\nDone. Next step: regenerate the Wide Layer (tools/generate_wide_layer.py), then dbt build.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
