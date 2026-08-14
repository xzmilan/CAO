#!/usr/bin/env python3
"""
check_column_contracts.py — CAO column-contract gate (read-only).

Two rules, both hard-fail:

  NO-STAR-REF       No SELECT * (or alias.*) in any model whose FROM/JOIN
                    chain contains a ref(). Explicit column lists are what
                    make downstream impact verifiable — this is CAO doctrine,
                    now machine-enforced.

  COLUMN-CONTRACT   Every field a model consumes from an upstream model
                    (Alias.Object:Field colon access, or plain Alias.Column)
                    must exist in the upstream model's published contract.
                    A model's contract is:
                      (a) field names inside its ::OBJECT(Field TYPE, ...) casts
                      (b) its final-SELECT output aliases (AS Foo)
                    Diff-scoped: only contracts of models CHANGED in this PR
                    are re-validated against their consumers. Consumers of
                    unchanged models are assumed valid (they passed their
                    own PR gate when they merged).

Unresolvable constructs (jinja-generated column lists, dynamic SQL) are
WARN, never fail. This gate's value is precision — a check that cries
wolf gets disabled within a month.

Exit codes: 0 = clean (warnings allowed), 1 = violations found.
Never writes files. Never commits. Safe to run any number of times.

Usage:
    python3 tools/check_column_contracts.py --domain CustomerJourney
    python3 tools/check_column_contracts.py --domain CustomerJourney --all
    python3 tools/check_column_contracts.py --domain CustomerJourney --base-ref origin/main
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

# tools/ dir = this file's parent; CAO root = parent of tools/.
TOOLS_DIR = Path(__file__).resolve().parent
CAO_ROOT = TOOLS_DIR.parent
sys.path.insert(0, str(TOOLS_DIR))

from sql_formatter_snowflake import _extract_object_casts, _protect_jinja  # noqa: E402

# ── Regexes ──────────────────────────────────────────────────────────────────
# ref('Name') or ref("Name") — capture the model name
_REF_RE = re.compile(r"\{\{\s*ref\(\s*['\"]([\w]+)['\"]\s*\)\s*\}\}")

# FROM/JOIN ref('X') AS Alias — capture model name and alias
_FROM_JOIN_REF_RE = re.compile(
    r"(?:FROM|JOIN)\s+\{\{\s*ref\(\s*['\"]([\w]+)['\"]\s*\)\s*\}\}"
    r"(?:\s+AS\s+)?\s*([A-Za-z_][A-Za-z0-9_]*)",
    re.IGNORECASE,
)

# SELECT * or alias.* — star-ref detection
_STAR_REF_RE = re.compile(
    r"\bSELECT\s+\*|([A-Za-z_][A-Za-z0-9_]*)\.\s*\*",
    re.IGNORECASE,
)

# Colon field access: Alias.Object:Field (reuse the same pattern as the formatter)
_COLON_FIELD_RE = re.compile(r"(?<=[\w)])\s*(:\s*)([A-Za-z_][A-Za-z0-9_]*)")

# Plain column ref: Alias.Column (NOT followed by colon — colon refs handled separately)
# Built dynamically per model from alias_map keys.

# Field name inside OBJECT cast: FieldName TYPE
_OBJECT_FIELD_RE = re.compile(
    r"([A-Za-z_][A-Za-z0-9_]*)\s+(?:VARCHAR|NUMBER|FLOAT|BOOLEAN|DATE|TIMESTAMP[A-Z_]*|VARIANT|OBJECT|ARRAY)\b",
    re.IGNORECASE,
)

# Nested OBJECT(Field TYPE, ...) inside a cast token
_NESTED_OBJECT_RE = re.compile(
    r"\bOBJECT\s*\(\s*([^)]*(?:\([^)]*\)[^)]*)*)\s*\)",
    re.IGNORECASE,
)

# ARRAY(OBJECT(...)) inside a cast token
_ARRAY_OBJECT_RE = re.compile(
    r"\bARRAY\s*\(\s*OBJECT\s*\(\s*([^)]*(?:\([^)]*\)[^)]*)*)\s*\)\s*\)",
    re.IGNORECASE,
)

# AS alias after a cast placeholder or expression
_AS_ALIAS_RE = re.compile(r"\bAS\s+([A-Za-z_][A-Za-z0-9_]*)", re.IGNORECASE)

# SQL type keywords that should never be treated as column aliases
_SQL_TYPES = frozenset({
    "VARCHAR", "NUMBER", "FLOAT", "BOOLEAN", "DATE", "INTEGER",
    "TIMESTAMP", "TIMESTAMP_NTZ", "TIMESTAMP_LTZ", "TIMESTAMP_TZ",
    "VARIANT", "OBJECT", "ARRAY", "TEXT", "STRING", "BIGINT", "INT",
    "DOUBLE", "DECIMAL", "NUMERIC", "CHAR", "BINARY", "TIME",
})

# Comment line detection
_COMMENT_LINE_RE = re.compile(r"^\s*--")

# dbt config block — strip before parsing
_CONFIG_BLOCK_RE = re.compile(r"^\s*\{\{\s*config\s*\(.*?\)\s*\}\}", re.DOTALL)


# ── Data structures ──────────────────────────────────────────────────────────

class Violation:
    """A single contract violation."""
    def __init__(self, file: str, line: int, message: str, rule: str):
        self.file = file
        self.line = line
        self.message = message
        self.rule = rule


class Contract:
    """A model's published column contract."""
    def __init__(self):
        # objects: {object_alias: {field_name, ...}}
        self.objects: dict[str, set[str]] = defaultdict(set)
        # columns: {column_name, ...} — plain output columns (non-OBJECT)
        self.columns: set[str] = set()
        # nested objects: {object_alias: {nested_object_alias: {field_name, ...}}}
        self.nested_objects: dict[str, dict[str, set[str]]] = defaultdict(
            lambda: defaultdict(set)
        )
        # warnings about unresolvable constructs
        self.warnings: list[str] = []


# ── Step 1: Model discovery ──────────────────────────────────────────────────

def discover_models(domain: str) -> dict[str, Path]:
    """Walk models/ and return {model_name: file_path}."""
    domain_dir = CAO_ROOT / "domains" / domain
    models_dir = domain_dir / "models"
    if not models_dir.is_dir():
        print(f"ERROR: models directory not found: {models_dir}", file=sys.stderr)
        sys.exit(1)

    models: dict[str, Path] = {}
    for f in sorted(models_dir.rglob("*.sql")):
        model_name = f.stem  # filename without .sql
        models[model_name] = f
    return models


# ── Step 2: Ref graph ────────────────────────────────────────────────────────

def build_ref_graph(models: dict[str, Path]) -> tuple[dict[str, set[str]], dict[str, set[str]]]:
    """
    Build the model-level dependency graph.
    Returns (upstream_of, consumers_of):
      upstream_of[model] = {models it ref()s}
      consumers_of[model] = {models that ref() it}
    """
    upstream_of: dict[str, set[str]] = defaultdict(set)
    consumers_of: dict[str, set[str]] = defaultdict(set)

    for model_name, file_path in models.items():
        sql = file_path.read_text()
        # Strip config block
        sql = _CONFIG_BLOCK_RE.sub("", sql)
        refs = set(_REF_RE.findall(sql))
        upstream_of[model_name] = refs
        for ref_name in refs:
            consumers_of[ref_name].add(model_name)

    return upstream_of, consumers_of


def all_consumers(changed: set[str], consumers_of: dict[str, set[str]]) -> set[str]:
    """Transitive closure: all models that consume any of `changed`, directly or indirectly."""
    result: set[str] = set()
    worklist = list(changed)
    while worklist:
        model = worklist.pop()
        for consumer in consumers_of.get(model, set()):
            if consumer not in result:
                result.add(consumer)
                worklist.append(consumer)
    return result


# ── Step 3: Diff scope ───────────────────────────────────────────────────────

def changed_models(base_ref: str, domain: str) -> set[str]:
    """Return set of model names changed in this PR vs base_ref."""
    try:
        result = subprocess.run(
            ["git", "diff", "--name-only", f"{base_ref}...HEAD", "--",
             f"domains/{domain}/models"],
            capture_output=True, text=True, cwd=str(CAO_ROOT),
        )
        if result.returncode != 0:
            print(f"WARN: git diff failed ({result.stderr.strip()}) — falling back to --all",
                  file=sys.stderr)
            return set()
        changed_files = [line.strip() for line in result.stdout.splitlines() if line.strip()]
        changed = set()
        for f in changed_files:
            if f.endswith(".sql"):
                changed.add(Path(f).stem)
        return changed
    except FileNotFoundError:
        print("WARN: git not found — falling back to --all", file=sys.stderr)
        return set()


# ── Step 4: Published contracts ──────────────────────────────────────────────

def _extract_fields_from_cast_token(cast_token: str) -> dict[str, set[str]]:
    """
    Extract field names from a single ::OBJECT(...) cast token.
    Handles nested OBJECT(...) and ARRAY(OBJECT(...)).
    Returns {object_alias: {field_name, ...}} — top-level fields go under '' key.
    """
    fields: dict[str, set[str]] = defaultdict(set)

    # Remove the leading ::OBJECT( and trailing )
    inner = cast_token.strip()
    # Strip leading ::OBJECT( and trailing )
    inner = re.sub(r"^::\s*OBJECT\s*\(\s*", "", inner, flags=re.IGNORECASE)
    inner = re.sub(r"\s*\)\s*$", "", inner)

    nested_objects: dict[str, set[str]] = {}

    # Extract nested ARRAY(OBJECT(...)) first — remove them, extract their fields
    for m in _ARRAY_OBJECT_RE.finditer(inner):
        nested_inner = m.group(1)
        nested_fields: set[str] = set()
        for fm in _OBJECT_FIELD_RE.finditer(nested_inner):
            nested_fields.add(fm.group(1))
        # Find the field name before this ARRAY(OBJECT(
        before = inner[:m.start()].strip()
        before_parts = before.rstrip(",").strip().split()
        if before_parts:
            array_name = before_parts[-1].strip("'\"")
            nested_objects[array_name] = nested_fields
        inner = inner[:m.start()] + inner[m.end():]

    # Extract nested OBJECT(...) blocks
    for m in _NESTED_OBJECT_RE.finditer(inner):
        nested_inner = m.group(1)
        nested_fields: set[str] = set()
        for fm in _OBJECT_FIELD_RE.finditer(nested_inner):
            nested_fields.add(fm.group(1))
        # Find the field name before this OBJECT(
        before = inner[:m.start()].strip()
        # The field name is the last word before OBJECT(
        before_parts = before.rstrip(",").strip().split()
        if before_parts:
            obj_name = before_parts[-1].strip("'\"")
            nested_objects[obj_name] = nested_fields
        inner = inner[:m.start()] + inner[m.end():]

    # Extract top-level fields
    for fm in _OBJECT_FIELD_RE.finditer(inner):
        field_name = fm.group(1)
        # Skip if it's OBJECT or ARRAY keyword
        if field_name.upper() in ("OBJECT", "ARRAY"):
            continue
        fields[""].add(field_name)

    # Merge nested objects
    for obj_name, obj_fields in nested_objects.items():
        fields[obj_name] = obj_fields

    return dict(fields)


def published_contract(sql: str, model_name: str) -> Contract:
    """
    Extract a model's published column contract from its SQL.
    Uses the existing _extract_object_casts and _protect_jinja helpers.
    """
    contract = Contract()

    # Strip config block
    sql = _CONFIG_BLOCK_RE.sub("", sql)

    # Protect jinja
    sql_no_jinja, _ = _protect_jinja(sql)

    # Extract OBJECT casts
    sql_no_casts, cast_tokens = _extract_object_casts(sql_no_jinja)

    # 4a — OBJECT-cast fields: for each cast token, extract fields
    # and determine which output alias owns the cast
    for idx, token in enumerate(cast_tokens):
        cast_fields = _extract_fields_from_cast_token(token)

        # Find the AS alias that follows this cast placeholder
        placeholder = f"::VARIANT /*SF_OBJECTCAST__{idx}__*/"
        placeholder_pos = sql_no_casts.find(placeholder)
        if placeholder_pos < 0:
            contract.warnings.append(
                f"{model_name}: cast placeholder {idx} not found in protected SQL"
            )
            continue

        # Look for AS <Alias> after the placeholder
        after = sql_no_casts[placeholder_pos + len(placeholder):]
        as_match = _AS_ALIAS_RE.search(after)
        if as_match:
            alias = as_match.group(1)
            # Top-level fields go under the alias itself
            if "" in cast_fields:
                contract.objects[alias].update(cast_fields[""])
            # Nested objects go under alias.nested_name
            for nested_name, nested_fields in cast_fields.items():
                if nested_name and nested_name != "":
                    contract.nested_objects[alias][nested_name].update(nested_fields)
        else:
            contract.warnings.append(
                f"{model_name}: cast {idx} has no AS alias — unresolvable ownership"
            )

    # 4b — Fallback: bare OBJECT_CONSTRUCT_KEEP_NULL(...) AS Alias
    # (no ::OBJECT cast). Use a balanced-paren scanner to find the call,
    # then extract field-name strings from the inner content.
    _BARE_OBJECT_START = re.compile(r"OBJECT_CONSTRUCT_KEEP_NULL\s*\(", re.IGNORECASE)
    for m in _BARE_OBJECT_START.finditer(sql_no_casts):
        start = m.end()  # just past the opening '('
        depth = 1
        j = start
        while j < len(sql_no_casts) and depth > 0:
            ch = sql_no_casts[j]
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
            j += 1
        inner = sql_no_casts[start:j - 1]  # content between outer parens
        # Look for AS <Alias> after the closing paren
        after = sql_no_casts[j:]
        as_match = _AS_ALIAS_RE.search(after)
        if as_match:
            alias = as_match.group(1)
            # Extract field names: 'FieldName' strings followed by commas
            field_names = re.findall(r"'([A-Za-z_][A-Za-z0-9_]*)'\s*,", inner)
            if alias not in contract.objects or not contract.objects[alias]:
                contract.objects[alias].update(field_names)

    # 4c — plain output aliases from the final SELECT
    # Find the last top-level SELECT block (simple heuristic: last SELECT at depth 0)
    lines = sql_no_casts.split("\n")
    in_select = False
    select_start = -1
    depth = 0
    last_select_start = -1

    for i, line in enumerate(lines):
        stripped = line.lstrip()
        if stripped.upper().startswith("SELECT") and depth == 0:
            last_select_start = i
            in_select = True
        # Track paren depth
        depth += line.count("(") - line.count(")")

    if last_select_start >= 0:
        # From the last SELECT to end of file (or next top-level statement)
        select_sql = "\n".join(lines[last_select_start:])
        # Find AS aliases that are NOT inside OBJECT_CONSTRUCT_KEEP_NULL
        # Simple approach: find all AS <Alias> at the top level of the SELECT
        for m in _AS_ALIAS_RE.finditer(select_sql):
            alias = m.group(1)
            # Skip SQL type keywords (CAST(x AS NUMBER) is not a column alias)
            if alias.upper() in _SQL_TYPES:
                continue
            # Skip if this alias appears inside an OBJECT_CONSTRUCT_KEEP_NULL call
            # (those are cast-owned, already handled above)
            before = select_sql[:m.start()]
            if "OBJECT_CONSTRUCT_KEEP_NULL" in before.split("\n")[-1]:
                continue

            # Detect object passthrough: Alias.ObjectName AS ObjectName
            # e.g. "Survey.Survey AS Survey" or "Policy.Policy AS Policy"
            # The expression before AS is a dotted ref ending in the alias name.
            before_expr = before.rstrip().rsplit(",", 1)[-1].strip()
            dotted_match = re.search(
                rf"([A-Za-z_][A-Za-z0-9_]*)\.{re.escape(alias)}\s*$",
                before_expr,
            )
            if dotted_match:
                # This is an object passthrough — mark it as an object
                # (fields will be resolved from the upstream model at check time)
                contract.objects[alias] = set()  # empty = passthrough, resolve transitively
                continue

            # Skip if the alias is a known OBJECT alias
            if alias not in contract.objects:
                contract.columns.add(alias)

        # Also capture implicit aliases: SELECT expressions without AS
        # e.g. "Policy.ID" implicitly publishes "ID"
        # Parse the SELECT clause: split on commas at depth 0, extract last identifier
        select_body = select_sql
        # Strip leading SELECT
        select_body = re.sub(r"^\s*SELECT\s+", "", select_body, flags=re.IGNORECASE)
        # Find FROM at depth 0 to bound the SELECT clause
        from_match = re.search(r"\bFROM\b", select_body, re.IGNORECASE)
        if from_match:
            select_body = select_body[:from_match.start()]

        # Split on commas at depth 0
        parts = []
        depth = 0
        current = ""
        for ch in select_body:
            if ch == "," and depth == 0:
                parts.append(current.strip())
                current = ""
            else:
                if ch == "(":
                    depth += 1
                elif ch == ")":
                    depth -= 1
                current += ch
        if current.strip():
            parts.append(current.strip())

        for part in parts:
            # If this part has an explicit AS, skip — already handled above
            if _AS_ALIAS_RE.search(part):
                continue
            # Extract the last dotted identifier as the implicit alias
            implicit_match = re.search(r"([A-Za-z_][A-Za-z0-9_]*)\s*$", part)
            if implicit_match:
                implicit_alias = implicit_match.group(1)
                if implicit_alias.upper() not in _SQL_TYPES:
                    if implicit_alias not in contract.objects:
                        contract.columns.add(implicit_alias)

    return contract


# ── Step 5: Consumed references ──────────────────────────────────────────────

def _build_alias_map(sql: str) -> dict[str, str]:
    """Build {alias: model_name} from FROM/JOIN ref() clauses."""
    alias_map: dict[str, str] = {}
    for m in _FROM_JOIN_REF_RE.finditer(sql):
        model_name = m.group(1)
        alias = m.group(2)
        alias_map[alias] = model_name
    return alias_map


def consumed_refs(sql: str, alias_map: dict[str, str]) -> list[tuple[str, str, str, int]]:
    """
    Extract all consumed references from a model's SQL.
    Returns list of (upstream_model, object_path, field, line_number).
    object_path is empty for plain column refs.
    """
    refs: list[tuple[str, str, str, int]] = []

    # Protect jinja and casts so their internals don't produce false tokens
    sql_no_jinja, _ = _protect_jinja(sql)
    sql_clean, _ = _extract_object_casts(sql_no_jinja)

    lines = sql_clean.split("\n")

    # Build the plain-column-ref regex from alias_map keys (longest-first)
    aliases = sorted(alias_map.keys(), key=len, reverse=True)
    if aliases:
        alias_pattern = "|".join(re.escape(a) for a in aliases)
        _PLAIN_COL_RE = re.compile(
            rf"\b({alias_pattern})\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)\b(?!\s*:)",
            re.IGNORECASE,
        )

    for line_num, line in enumerate(lines, 1):
        # Skip comment lines
        if _COMMENT_LINE_RE.match(line):
            continue

        # 5a — Colon refs: Alias.Object:Field
        for cm in _COLON_FIELD_RE.finditer(line):
            field_name = cm.group(2)
            # Walk left from the match to capture the dotted chain
            before = line[:cm.start()]
            # Find the object path: everything from the last non-word char before the colon
            # back to the alias
            path_match = re.search(r"([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)\s*$", before)
            if path_match:
                object_path = path_match.group(1)
                # Resolve leftmost segment through alias_map
                parts = object_path.split(".")
                leftmost = parts[0]
                if leftmost in alias_map:
                    upstream = alias_map[leftmost]
                    refs.append((upstream, object_path, field_name, line_num))

        # 5b — Plain column refs: Alias.Column (not followed by colon)
        if aliases:
            for pm in _PLAIN_COL_RE.finditer(line):
                alias = pm.group(1)
                col = pm.group(2)
                if alias in alias_map:
                    upstream = alias_map[alias]
                    refs.append((upstream, "", col, line_num))

    return refs


def check_star_refs(sql: str, alias_map: dict[str, str], file_path: str) -> list[Violation]:
    """Check for SELECT * or alias.* over ref()s."""
    violations: list[Violation] = []

    # Protect jinja and casts
    sql_no_jinja, _ = _protect_jinja(sql)
    sql_clean, _ = _extract_object_casts(sql_no_jinja)

    lines = sql_clean.split("\n")
    for line_num, line in enumerate(lines, 1):
        if _COMMENT_LINE_RE.match(line):
            continue

        for sm in _STAR_REF_RE.finditer(line):
            alias = sm.group(1)
            if alias:
                # alias.* — check if alias maps to a ref
                if alias in alias_map:
                    violations.append(Violation(
                        file=file_path,
                        line=line_num,
                        message=f"{alias}.* over ref('{alias_map[alias]}') is banned "
                                f"(CAO doctrine: explicit column lists make downstream "
                                f"impact verifiable). List the columns.",
                        rule="NO-STAR-REF",
                    ))
            else:
                # SELECT * — check if this model has ANY ref()
                if alias_map:
                    violations.append(Violation(
                        file=file_path,
                        line=line_num,
                        message="SELECT * in a model with ref()s is banned "
                                "(CAO doctrine: explicit column lists make downstream "
                                "impact verifiable). List the columns.",
                        rule="NO-STAR-REF",
                    ))

    return violations


# ── Step 6: The gate ─────────────────────────────────────────────────────────

def _resolve_colon_ref(
    object_path: str, field: str, contract: Contract, model_name: str
) -> tuple[bool, str]:
    """
    Resolve a colon reference against a contract.
    Returns (valid, reason_if_invalid).

    object_path is the dotted chain BEFORE the colon, e.g.:
      "Policy"              → alias-only, field is a top-level column
      "Policy.Policy"       → alias.ObjectName, field is inside that object
      "Policy.Policy:SystemIds" → alias.ObjectName.NestedObject, field inside nested
    """
    parts = object_path.split(".")
    alias = parts[0]

    if len(parts) == 1:
        # Single-segment: Alias:Field — check if field is a top-level column
        if field in contract.columns:
            return True, ""
        # Or if alias itself is an object name and field is inside it
        if alias in contract.objects and field in contract.objects[alias]:
            return True, ""
        available = sorted(set(contract.columns) | set(contract.objects.keys()))
        return False, f"field '{field}' not found in contract (available: {available})"

    # Multi-segment: Alias.ObjName or Alias.ObjName.NestedObj
    # parts[1] is the OBJECT name in the contract
    obj_name = parts[1]
    nested_chain = parts[2:]  # any deeper nesting

    if obj_name not in contract.objects:
        # Check if it's a nested object inside a top-level object
        for top_obj, nested in contract.nested_objects.items():
            if obj_name in nested:
                # Found it as a nested object — check field inside it
                if field in nested[obj_name]:
                    return True, ""
                return False, (
                    f"field '{field}' not found in nested object '{obj_name}' "
                    f"(available: {sorted(nested[obj_name])})"
                )
        available = sorted(contract.objects.keys())
        return False, f"object '{obj_name}' not found in {model_name} contract (available: {available})"

    # Walk nested chain
    current_fields = contract.objects[obj_name]
    for nested_obj in nested_chain:
        if obj_name in contract.nested_objects and nested_obj in contract.nested_objects[obj_name]:
            current_fields = contract.nested_objects[obj_name][nested_obj]
            continue
        return False, (
            f"nested object '{nested_obj}' not found in '{obj_name}' "
            f"(available fields: {sorted(current_fields)})"
        )

    if field not in current_fields:
        # Check if field is a nested object name (e.g. Policy:SystemIds)
        if obj_name in contract.nested_objects and field in contract.nested_objects[obj_name]:
            return True, ""
        return False, (
            f"field '{field}' not found in '{obj_name}"
            + ("." + ".".join(nested_chain) if nested_chain else "")
            + f"' (available: {sorted(current_fields)})"
        )

    return True, ""


def validate(
    changed: set[str],
    models: dict[str, Path],
    upstream_of: dict[str, set[str]],
    consumers_of: dict[str, set[str]],
    domain: str,
) -> tuple[list[Violation], list[str]]:
    """
    Validate column contracts for changed models against their consumers.
    Returns (violations, warnings).
    """
    violations: list[Violation] = []
    all_warnings: list[str] = []

    # Compute published contracts for changed models
    contracts: dict[str, Contract] = {}
    for model_name in changed:
        if model_name not in models:
            continue
        sql = models[model_name].read_text()
        contract = published_contract(sql, model_name)
        contracts[model_name] = contract
        all_warnings.extend(contract.warnings)

    # Find all consumers of changed models (transitive)
    consumers = all_consumers(changed, consumers_of)

    # Resolve transitive passthrough objects: when a model does
    # "Upstream.ObjectName AS ObjectName" (empty object = passthrough),
    # resolve its fields from the upstream model's contract.
    for model_name, contract in list(contracts.items()):
        for obj_name, obj_fields in list(contract.objects.items()):
            if obj_fields:  # already has fields — not a passthrough
                continue
            # Empty set = passthrough. Find which upstream model it comes from.
            if model_name not in models:
                continue
            sql = models[model_name].read_text()
            sql = _CONFIG_BLOCK_RE.sub("", sql)
            alias_map = _build_alias_map(sql)
            # Look for "Alias.ObjectName AS ObjectName" pattern
            for alias, upstream_name in alias_map.items():
                if upstream_name in contracts:
                    upstream_contract = contracts[upstream_name]
                    if obj_name in upstream_contract.objects:
                        # Copy fields from upstream
                        contract.objects[obj_name] = set(upstream_contract.objects[obj_name])
                        # Also copy nested objects
                        if obj_name in upstream_contract.nested_objects:
                            contract.nested_objects[obj_name] = dict(
                                upstream_contract.nested_objects[obj_name]
                            )
                        break

    # For each consumer, check its references against changed upstream contracts
    for consumer_name in consumers:
        if consumer_name not in models:
            continue
        sql = models[consumer_name].read_text()
        sql = _CONFIG_BLOCK_RE.sub("", sql)
        alias_map = _build_alias_map(sql)

        # NO-STAR-REF check
        rel_path = str(models[consumer_name].relative_to(CAO_ROOT))
        star_violations = check_star_refs(sql, alias_map, rel_path)
        violations.extend(star_violations)

        # COLUMN-CONTRACT check
        refs = consumed_refs(sql, alias_map)
        for upstream, object_path, field, line_num in refs:
            if upstream not in contracts:
                continue  # upstream wasn't changed — skip

            contract = contracts[upstream]
            rel_path = str(models[consumer_name].relative_to(CAO_ROOT))

            if object_path:
                # Colon ref
                valid, reason = _resolve_colon_ref(object_path, field, contract, upstream)
                if not valid:
                    violations.append(Violation(
                        file=rel_path,
                        line=line_num,
                        message=f"{object_path}:{field} — {upstream} {reason}",
                        rule="COLUMN-CONTRACT",
                    ))
            else:
                # Plain column ref
                if field not in contract.columns and field not in contract.objects:
                    available = sorted(set(contract.columns) | set(contract.objects.keys()))
                    violations.append(Violation(
                        file=rel_path,
                        line=line_num,
                        message=f"{field} — {upstream} no longer publishes column '{field}' "
                                f"(available: {available})",
                        rule="COLUMN-CONTRACT",
                    ))

    return violations, all_warnings


# ── Main ─────────────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(
        description="CAO column-contract gate — validates downstream field references."
    )
    parser.add_argument(
        "--domain", default="CustomerJourney",
        help="Domain folder under domains/ to check (default: CustomerJourney).",
    )
    parser.add_argument(
        "--base-ref", default="origin/main",
        help="Git ref to diff against (default: origin/main).",
    )
    parser.add_argument(
        "--all", action="store_true",
        help="Check ALL models (skip diff-scoping).",
    )
    args = parser.parse_args()

    domain_dir = CAO_ROOT / "domains" / args.domain
    if not domain_dir.is_dir():
        print(f"ERROR: domain not found: {domain_dir}", file=sys.stderr)
        return 1

    # Step 1: Discover models
    models = discover_models(args.domain)
    print(f"Found {len(models)} model files in domains/{args.domain}/models")

    # Step 2: Build ref graph
    upstream_of, consumers_of = build_ref_graph(models)

    # Step 3: Determine changed models
    if args.all:
        changed = set(models.keys())
        print("Checking ALL models (--all flag)")
    else:
        changed = changed_models(args.base_ref, args.domain)
        if not changed:
            print("No model changes detected — nothing to check.")
            return 0
        print(f"Changed models: {sorted(changed)}")

    # Step 6: Validate
    violations, warnings = validate(
        changed, models, upstream_of, consumers_of, args.domain,
    )

    # Print warnings
    if warnings:
        print(f"\nWARN ({len(warnings)} unresolvable — human eyeball needed):")
        for w in warnings:
            print(f"  {w}")

    # Print violations
    if violations:
        # Group by file
        by_file: dict[str, list[Violation]] = defaultdict(list)
        for v in violations:
            by_file[v.file].append(v)

        print(f"\nVIOLATIONS ({len(violations)} total):\n")
        for file_path in sorted(by_file):
            file_violations = by_file[file_path]
            print(f"  {file_path} ({len(file_violations)} violations):")
            for v in file_violations:
                print(f"    L{v.line:04d}  [{v.rule}] {v.message}")
            print()

        print(f"SUMMARY: {len(violations)} violations, {len(warnings)} warnings")
        return 1

    print(f"\nAll column contracts valid. ({len(warnings)} warnings)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())