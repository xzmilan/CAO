"""
sql_formatter_snowflake.py — Originally created by Steven Passanante (contractor 08/07/2026) modified for free use for Farmers Insurance Group
==============================
CAO / Snowflake dialect copy of the MESA SQL Normalizer
(mesa-governance-api/api/services/sql_formatter.py — ANSI/dbt original).

WHY THIS IS A SEPARATE FILE (not just a dialect switch)
------------------------------------------------------
The ANSI/dbt formatter can't be reused as-is for Snowflake because of two
kinds of syntax the Snowflake grammar handles differently:

  1. OBJECT-field access via COLON:  `Policy.Policy:PolicyInceptionDate`
     and the wide-table cast `...::OBJECT(Field TYPE, ...)`.
     sqlfluff's Snowflake dialect can't parse the multi-field OBJECT cast
     (PRS "unparsable section") and flags colon field-access oddly. We
     PROTECT these before linting and restore them after — same technique
     as _protect_jinja.

  2. Identifier capitalisation doctrine (CAO-specific, not a sqlfluff rule):
       - The entity primary key column is ALWAYS all-caps:  ID
       - Metric / alias names are ALWAYS PascalCase:  TenureDays, InceptionMonth
     sqlfluff's CP02 ('consistent') would force ONE case per file and rename
     ID→Id or TenureDays→TENUREDAYS — a SEMANTIC change, not cosmetic. So CP02
     is EXCLUDED from the sqlfluff pass (same as MESA) and enforced by a
     dedicated Python check (check_identifier_doctrine) instead.

SAME TWO-TIER CONTRACT AS MESA
-------------------------------
  Tier 1 — Cosmetic pass (safe, automatic; never changes semantics).
  Tier 2 — Semantic suggestions (returned, NEVER auto-applied).

Public API:
  format_snowflake_sql(sql, object_name) -> (formatted, suggestions)
  lint_snowflake_sql(sql)                -> list[lint findings]  (CI gate helper)
  check_identifier_doctrine(sql)         -> list[doctrine violations]

For other dialects (redshift, bigquery, duckdb): copy this file, change
_DIALECT and the _protect_* helpers for that dialect's unusual syntax.
"""

from __future__ import annotations

import re
import textwrap
from pathlib import Path


# ── Dialect constant ─────────────────────────────────────────────────────────
_DIALECT = "snowflake"

# A leading dbt {{ config(...) }} block is not valid standalone SQL — strip it
# before parsing (it is Jinja, not SQL), keep the rest of the body.
_CONFIG_BLOCK_RE = re.compile(r"^\s*\{\{\s*config\s*\(.*?\)\s*\}\}", re.DOTALL)


# ── Jinja protection (identical technique to MESA) ───────────────────────────
_JINJA_RE = re.compile(r"\{\{.*?\}\}", re.DOTALL)
_JINJA_PLACEHOLDER = "JINJA_PLACEHOLDER__{idx}__"
_JINJA_PLACEHOLDER_RE = re.compile(r"JINJA_PLACEHOLDER__(\d+)__")


def _protect_jinja(sql: str) -> tuple[str, list[str]]:
    tokens: list[str] = []

    def replacer(m: re.Match) -> str:
        tokens.append(m.group(0))
        return _JINJA_PLACEHOLDER.format(idx=len(tokens) - 1)

    return _JINJA_RE.sub(replacer, sql), tokens


def _restore_jinja(sql: str, tokens: list[str]) -> str:
    return _JINJA_PLACEHOLDER_RE.sub(lambda m: tokens[int(m.group(1))], sql)


# ── Dialect auto-detection ───────────────────────────────────────────────────
# Each dialect has a set of (regex, weight) patterns. The dialect with the
# highest cumulative weight wins. Weights are tuned so that a single strong
# signal (e.g. ::OBJECT for Snowflake) outweighs multiple weak signals.

_DIALECT_SIGNALS: list[tuple[str, str, int]] = [
    # (dialect, regex_pattern, weight)
    # ── Snowflake ──
    ("snowflake", r"::\s*OBJECT\s*\(", 10),          # ::OBJECT( cast
    ("snowflake", r"::\s*VARIANT\b", 8),             # ::VARIANT cast
    ("snowflake", r"::\s*ARRAY\b", 5),               # ::ARRAY cast (Snowflake-only :: syntax)
    ("snowflake", r"\w+\.\w+:\w+", 8),               # colon field access Object:Field
    ("snowflake", r"\bTRY_CAST\s*\(", 6),            # TRY_CAST()
    ("snowflake", r"\bQUALIFY\b", 5),                # QUALIFY clause
    ("snowflake", r"\bILIKE\b", 3),                  # ILIKE
    ("snowflake", r"\bFLATTEN\s*\(", 5),             # FLATTEN()
    ("snowflake", r"\bLATERAL\s+FLATTEN\b", 6),      # LATERAL FLATTEN
    ("snowflake", r"\bTIMESTAMP_NTZ\b", 4),          # Snowflake timestamp types
    ("snowflake", r"\bTIMESTAMP_TZ\b", 4),
    ("snowflake", r"\bTIMESTAMP_LTZ\b", 4),
    ("snowflake", r"\bARRAY_CONSTRUCT\b", 3),        # Snowflake array constructor
    ("snowflake", r"\bOBJECT_CONSTRUCT\b", 3),       # Snowflake object constructor
    ("snowflake", r"\bARRAY_AGG\s*\(", 2),           # ARRAY_AGG (shared, low weight — also BQ/DuckDB)
    ("snowflake", r"\bTO_VARCHAR\b", 2),             # Snowflake conversion functions
    ("snowflake", r"\bTO_NUMBER\b", 2),
    ("snowflake", r"\bTO_DATE\b", 2),
    ("snowflake", r"\bTO_TIMESTAMP\b", 2),
    ("snowflake", r"\bZEROIFNULL\b", 2),
    ("snowflake", r"\bIFF\s*\(", 3),                 # Snowflake IFF()
    ("snowflake", r"\bREGEXP_LIKE\b", 2),
    ("snowflake", r"\bDATEADD\s*\(", 2),             # Snowflake DATEADD (not DATE_ADD)
    ("snowflake", r"\bDATEDIFF\s*\(", 2),            # Snowflake DATEDIFF (not DATE_DIFF)
    # ── BigQuery ──
    ("bigquery", r"`[^`]+`", 6),                     # backtick identifiers
    ("bigquery", r"\bSAFE_CAST\s*\(", 8),            # SAFE_CAST()
    ("bigquery", r"\bSTRUCT\s*<", 8),                # STRUCT<...>
    ("bigquery", r"\bARRAY\s*<", 8),                 # ARRAY<...> typed array (BigQuery-specific)
    ("bigquery", r"\bARRAY_AGG\s*\(", 2),            # ARRAY_AGG (shared, low weight — also SF/DuckDB)
    ("bigquery", r"\bARRAY_LENGTH\b", 3),            # ARRAY_LENGTH (BigQuery)
    ("bigquery", r"\bARRAY_TO_STRING\b", 3),         # ARRAY_TO_STRING (BigQuery)
    ("bigquery", r"\bGENERATE_ARRAY\b", 3),          # GENERATE_ARRAY (BigQuery)
    ("bigquery", r"\bOFFSET\s*\(", 3),               # OFFSET() array accessor (BigQuery)
    ("bigquery", r"\bSAFE_OFFSET\b", 3),             # SAFE_OFFSET (BigQuery)
    ("bigquery", r"\bUNNEST\s*\(", 5),               # UNNEST()
    ("bigquery", r"\bEXCEPT\s+DISTINCT\b", 5),       # EXCEPT DISTINCT
    ("bigquery", r"\bSTRING_AGG\b", 3),              # STRING_AGG
    ("bigquery", r"\bDATE_SUB\b", 2),                # BigQuery date functions
    ("bigquery", r"\bDATE_TRUNC\b", 2),
    ("bigquery", r"\bPARSE_DATE\b", 2),
    ("bigquery", r"\bPARSE_TIMESTAMP\b", 2),
    ("bigquery", r"\bFORMAT_TIMESTAMP\b", 2),
    ("bigquery", r"\bGENERATE_DATE_ARRAY\b", 2),
    ("bigquery", r"\bNET\.", 2),                     # NET. functions
    # ── DuckDB ──
    ("duckdb", r"\bread_csv_auto\s*\(", 10),         # DuckDB-specific read functions
    ("duckdb", r"\bread_parquet\s*\(", 10),
    ("duckdb", r"\bread_json\s*\(", 8),
    ("duckdb", r"\bSUMMARIZE\b", 6),                 # SUMMARIZE
    ("duckdb", r"\bCOLUMNS\s*\(", 6),                # COLUMNS() regex
    ("duckdb", r"\bEXCLUDE\s*\(", 5),                # EXCLUDE()
    ("duckdb", r"\bREPLACE\s*\(", 5),                # REPLACE() in SELECT
    ("duckdb", r"\bLIST\s*\(", 3),                   # DuckDB list type
    ("duckdb", r"\bMAP\s*\(", 3),                    # DuckDB map type
    ("duckdb", r"\bARRAY\[", 5),                     # ARRAY[...] constructor (DuckDB)
    ("duckdb", r"\bARRAY_AGG\s*\(", 2),              # ARRAY_AGG (shared, low weight)
    ("duckdb", r"\bLIST_AGG\b", 3),                  # LIST_AGG (DuckDB)
    ("duckdb", r"\bLIST_FILTER\b", 3),               # LIST_FILTER (DuckDB)
    ("duckdb", r"\bLIST_TRANSFORM\b", 3),            # LIST_TRANSFORM (DuckDB)
    ("duckdb", r"\bLIST_SORT\b", 2),                 # LIST_SORT (DuckDB)
    ("duckdb", r"\bLIST_DISTINCT\b", 2),             # LIST_DISTINCT (DuckDB)
    ("duckdb", r"\bUNION\s+ALL\s+BY\s+NAME\b", 4),   # UNION ALL BY NAME
    ("duckdb", r"\bSTRFTIME\b", 2),
    ("duckdb", r"\bEPOCH\s*\(", 2),
    # ── Redshift (partial; many patterns overlap with ANSI) ──
    ("redshift", r"\bGETDATE\s*\(", 4),              # GETDATE() vs CURRENT_TIMESTAMP
    ("redshift", r"\bNVL\s*\(", 3),                  # NVL() vs COALESCE
    ("redshift", r"\bDATEADD\s*\(", 2),              # Redshift DATEADD
    ("redshift", r"\bDATEDIFF\s*\(", 2),             # Redshift DATEDIFF
    ("redshift", r"\bLISTAGG\s*\(", 3),              # Redshift LISTAGG
    ("redshift", r"\bSYSDATE\b", 2),                 # SYSDATE
    ("redshift", r"\bENCODE\s+\w+\b", 3),            # column ENCODE
    ("redshift", r"\bDISTKEY\b", 4),                 # DISTKEY
    ("redshift", r"\bSORTKEY\b", 4),                 # SORTKEY
    ("redshift", r"\bCOMPOUND\s+SORTKEY\b", 5),      # COMPOUND SORTKEY
    ("redshift", r"\bINTERLEAVED\s+SORTKEY\b", 5),   # INTERLEAVED SORTKEY
]

# Compile all patterns once at import time
_DIALECT_SIGNALS_COMPILED: list[tuple[str, re.Pattern, int]] = [
    (dialect, re.compile(pattern, re.IGNORECASE), weight)
    for dialect, pattern, weight in _DIALECT_SIGNALS
]


def _auto_detect_dialect(sql: str) -> str:
    """
    Inspect SQL for dialect-specific syntax patterns and return the best-match
    sqlfluff dialect name.

    Scoring: each matching pattern adds its weight to that dialect's score.
    The dialect with the highest score wins. Ties break toward 'ansi' (safest).

    Returns one of: 'snowflake', 'bigquery', 'duckdb', 'redshift', 'ansi'.
    """
    scores: dict[str, int] = {"ansi": 0, "snowflake": 0, "bigquery": 0, "duckdb": 0, "redshift": 0}

    for dialect, pattern, weight in _DIALECT_SIGNALS_COMPILED:
        if pattern.search(sql):
            scores[dialect] += weight

    # Find the dialect with the highest score
    best = max(scores, key=lambda d: scores[d])
    if scores[best] == 0:
        return "ansi"
    return best


# ── Snowflake OBJECT / colon-access protection ───────────────────────────────
# Protect the multi-field OBJECT cast  ::OBJECT(Field TYPE, Field TYPE, ...)
# and OBJECT field access  Alias.Object:Field  so sqlfluff's incomplete
# Snowflake grammar doesn't throw PRS on them. Restored verbatim afterward.
# The OBJECT-cast placeholder must itself PARSE as valid SQL (it sits where a
# cast belongs, before AS <alias>) — a simple "::VARIANT" cast is valid and
# unique enough to restore reliably.
#
# NOTE: the field list can contain NESTED parens — a field whose TYPE is itself
# OBJECT(ID VARCHAR) or OBJECT(LoadYearMonth NUMBER, ...). A regex `[^)]*`
# stops at the first inner ')' and breaks. So OBJECT casts are extracted with a
# balanced-paren scanner (_extract_object_casts), not a single regex.
_OBJECT_CAST_PLACEHOLDER = "::VARIANT /*SF_OBJECTCAST__{idx}__*/"
_OBJECT_CAST_PLACEHOLDER_RE = re.compile(r"::VARIANT\s*/\*SF_OBJECTCAST__(\d+)__\*/")
_OBJECT_CAST_START_RE = re.compile(r"::\s*OBJECT\s*\(", re.IGNORECASE)


def _extract_object_casts(sql: str) -> tuple[str, list[str]]:
    """
    Replace every balanced  ::OBJECT( ... )  cast (including nested parens in
    field TYPEs) with a parseable placeholder. Returns (cleaned_sql, tokens).
    """
    tokens: list[str] = []
    out: list[str] = []
    i = 0
    n = len(sql)
    while i < n:
        m = _OBJECT_CAST_START_RE.search(sql, i)
        if not m:
            out.append(sql[i:])
            break
        # Emit text before the cast
        out.append(sql[i:m.start()])
        # m.end() is just past the opening '(' of OBJECT(
        depth = 1
        j = m.end()
        while j < n and depth > 0:
            ch = sql[j]
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
            j += 1
        # sql[m.start():j] is the full balanced ::OBJECT(...)
        tokens.append(sql[m.start():j])
        out.append(_OBJECT_CAST_PLACEHOLDER.format(idx=len(tokens) - 1))
        i = j
    return "".join(out), tokens

# Colon field-access:  Something.Something:Field  (e.g. Policy.Policy:PolicyInceptionDate)
# We protect ONLY the `:Field` segment, leaving the dotted prefix intact so the
# rest of the expression still parses. A lone identifier after a colon is valid.
# REQUIRES the colon to immediately follow a word char or ')' (a real object),
# NOT whitespace — so comment text like "-- METRIC: TenureDays" is NOT matched.
_COLON_FIELD_RE = re.compile(r'(?<=[\w)])\s*(:\s*)([A-Za-z_][A-Za-z0-9_]*)')
_COLON_PLACEHOLDER = "__SF_COLON__{idx}__"
_COLON_PLACEHOLDER_RE = re.compile(r"__SF_COLON__(\d+)__")


def _protect_snowflake_constructs(sql: str) -> tuple[str, list[str], list[str]]:
    """
    Hide Snowflake-only syntax from sqlfluff. Returns
    (cleaned_sql, object_cast_tokens, colon_field_tokens).

    OBJECT casts are protected on the WHOLE block (they span multiple lines).
    Colon field-access is protected LINE-BY-LINE so comment lines are skipped
    (a colon in "-- METRIC: TenureDays" must not be treated as field access).
    """
    cast_tokens: list[str] = []
    colon_tokens: list[str] = []

    # Multi-line / nested OBJECT casts: protect across the whole SQL body using
    # the balanced-paren extractor (regex can't handle nested OBJECT(...) TYPEs).
    cleaned, cast_tokens = _extract_object_casts(sql)

    def colon_replacer(m: re.Match) -> str:
        # m.group(1) is the colon+spaces, group(2) the field name.
        colon_tokens.append(m.group(2))
        return _COLON_PLACEHOLDER.format(idx=len(colon_tokens) - 1)

    # Colon access: line-by-line, skipping comment lines.
    out_lines: list[str] = []
    for line in cleaned.split("\n"):
        if line.lstrip().startswith("--"):
            out_lines.append(line)
            continue
        out_lines.append(_COLON_FIELD_RE.sub(colon_replacer, line))

    return "\n".join(out_lines), cast_tokens, colon_tokens


def _restore_snowflake_constructs(
    sql: str, cast_tokens: list[str], colon_tokens: list[str]
) -> str:
    sql = _OBJECT_CAST_PLACEHOLDER_RE.sub(lambda m: cast_tokens[int(m.group(1))], sql)

    def colon_restore(m: re.Match) -> str:
        return ":" + colon_tokens[int(m.group(1))]

    return _COLON_PLACEHOLDER_RE.sub(colon_restore, sql)


# ── sqlfluff runner (Snowflake) ──────────────────────────────────────────────
def _run_sqlfluff_fix(
    sql: str,
    config_path: str | None = None,
    dialect: str | None = None,
) -> str:
    """
    Run sqlfluff fix on a SQL string.

    CP02 (capitalisation.identifiers) is ALWAYS excluded — see module docstring:
    sqlfluff's 'consistent' policy would semantically rename PascalCase aliases
    or the all-caps ID column. Identifier case is enforced separately by
    check_identifier_doctrine(), not by sqlfluff.

    When dialect is None or "snowflake", Snowflake-specific syntax protections
    (OBJECT casts, colon field access) are applied before/after sqlfluff.
    When dialect is a non-Snowflake value (e.g. "bigquery", "ansi"), those
    protections are skipped — the SQL is assumed to not contain Snowflake syntax.

    Never crashes: returns the original SQL if sqlfluff fails.
    """
    try:
        from sqlfluff.core import Linter, FluffConfig

        resolved_dialect = dialect if dialect else _DIALECT
        is_snowflake = resolved_dialect == "snowflake"

        overrides = {
            "dialect": resolved_dialect,
            "exclude_rules": "capitalisation.identifiers",
        }
        if config_path and Path(config_path).is_file():
            config = FluffConfig.from_root(extra_config_path=config_path, overrides=overrides)
        else:
            config = FluffConfig.from_root(overrides=overrides)

        linter = Linter(config=config)

        # Preserve the {{ config(...) }} block: strip it for parsing, then
        # re-prepend it verbatim to the fixed output. Jinja-protect would
        # otherwise turn it into a placeholder that survives, but stripping it
        # entirely loses it from the result. Capture it first.
        config_match = _CONFIG_BLOCK_RE.search(sql)
        config_block = config_match.group(0) if config_match else ""
        body = _CONFIG_BLOCK_RE.sub("", sql)  # drop {{ config }} BEFORE jinja-protect
        protected, jinja_tokens = _protect_jinja(body)

        cast_tokens: list[str] = []
        colon_tokens: list[str] = []
        if is_snowflake:
            protected, cast_tokens, colon_tokens = _protect_snowflake_constructs(protected)

        if not protected.endswith("\n"):
            protected += "\n"

        parsed = linter.parse_string(protected)
        fixed_tree, _ = linter.fix(parsed.tree, parsed.config)
        fixed = fixed_tree.raw

        if is_snowflake:
            fixed = _restore_snowflake_constructs(fixed, cast_tokens, colon_tokens)
        fixed = _restore_jinja(fixed, jinja_tokens)
        fixed = fixed.rstrip() + "\n"
        # Re-prepend the preserved config block (with a blank line after it).
        if config_block:
            fixed = config_block + "\n\n" + fixed.lstrip("\n")
        return fixed
    except Exception:
        return sql


# ── CAO identifier doctrine (the CP02 replacement) ───────────────────────────
# Enforced as a Python check because sqlfluff has no rule for "this specific
# column is all-caps AND these aliases are PascalCase simultaneously."

# All-caps identifiers that are INTENTIONAL:
#   - ID: the entity primary-key column (universal doctrine).
#   - Raw source column names (PLCY_CNTRCT_NUM, EFF_DT, ...) — raw-layer doctrine
#     keeps source columns unformatted / values as-is, so they stay ALL-CAPS.
#   - SQL type keywords used in CASTs (VARCHAR, NUMBER, DATE, ...) — not aliases.
_SQL_TYPES = {
    "VARCHAR", "NUMBER", "DATE", "TIMESTAMP", "TIMESTAMP_NTZ", "TIMESTAMP_LTZ",
    "TIMESTAMP_TZ", "FLOAT", "INTEGER", "INT", "BOOLEAN", "VARIANT", "OBJECT",
    "ARRAY", "STRING", "TEXT", "CHAR", "DECIMAL", "NUMERIC", "TIME", "DATETIME",
}

# A genuine column alias:  <expr> AS Name   where Name is the alias.
# We capture the two chars before AS to detect CAST(... AS TYPE) and CTE "name AS (".
_ALIAS_RE = re.compile(r"\bAS\s+([A-Za-z_][A-Za-z0-9_]*)\b", re.IGNORECASE)

# Raw source columns are ALL-CAPS_WITH_UNDERSCORES by design (raw layer doctrine).
# A PascalCase alias has NO underscores and starts uppercase.
_SNAKE_OR_RAW_RE = re.compile(r"^[A-Z][A-Z0-9]*(_[A-Z0-9]+)+$")  # e.g. PLCY_CNTRCT_NUM


def _is_allowed_upper(name: str) -> bool:
    """All-caps is allowed for: ID, SQL types, and raw source columns (UPPER_SNAKE)."""
    if name == "ID":
        return True
    if name in _SQL_TYPES:
        return True
    if _SNAKE_OR_RAW_RE.match(name):
        return True  # raw source column, e.g. PLCY_CNTRCT_NUM — kept as-is by doctrine
    return False


def _is_pascal_case(name: str) -> bool:
    """PascalCase: starts uppercase, no underscores. All-caps handled separately."""
    if _is_allowed_upper(name):
        return True
    if "_" in name:
        return False
    if name.isupper():
        return False  # all-caps but not whitelisted (e.g. a stray acronym alias)
    return name[0].isupper()


def check_identifier_doctrine(sql: str) -> list[dict]:
    """
    Enforce the CAO identifier doctrine that sqlfluff CP02 cannot express:
      - `ID` (and whitelisted raw columns) may be ALL-CAPS.
      - Every other column alias must be PascalCase.

    Returns a list of violation dicts {rule, name, message}. Empty = compliant.
    This is the CAO-specific enforcement the user requires INSTEAD OF sqlfluff
    forcing a single case per file.
    """
    violations: list[dict] = []
    in_block_comment = False
    for line in sql.split("\n"):
        stripped = line.lstrip()
        # Track /* ... */ block comments (possibly spanning lines).
        if in_block_comment:
            if "*/" in line:
                in_block_comment = False
            continue
        if stripped.startswith("/*"):
            if "*/" not in line:
                in_block_comment = True
            continue
        # Skip -- line comments — 'as of today' inside a comment is not an alias.
        if stripped.startswith("--"):
            continue
        for m in _ALIAS_RE.finditer(line):
            name = m.group(1)
            # Skip Jinja placeholders and protected tokens
            if name.startswith(("JINJA_PLACEHOLDER", "SF_OBJECTCAST", "__SF_COLON__")):
                continue
            # Skip CAST(... AS TYPE) — the "alias" is a type keyword.
            before = line[: m.start()]
            if re.search(r"CAST\s*\([^)]*$", before, re.IGNORECASE):
                continue
            # Skip CTE definitions:  Name AS (   — the name precedes AS, "(" follows.
            after = line[m.end():]
            if after.lstrip().startswith("("):
                continue
            if not _is_pascal_case(name):
                violations.append({
                    "rule": "CAO-IDENTIFIER-CASE",
                    "name": name,
                    "message": (
                        f"Alias '{name}' violates CAO identifier doctrine: use PascalCase "
                        f"(e.g. TenureDays) for metric/alias names. ALL-CAPS is reserved for "
                        f"the entity key 'ID' and raw source columns (UPPER_SNAKE)."
                    ),
                })
    return violations


# ── Header comment ───────────────────────────────────────────────────────────
_HEADER_RE = re.compile(r"^\s*--\s*(MESA|CAO|METRIC|RAW ENTITY|WIDE LAYER)", re.MULTILINE | re.IGNORECASE)


def _add_header_comment(sql: str, object_name: str = "") -> str:
    if _HEADER_RE.search(sql):
        return sql
    name_line = f"-- {object_name}" if object_name else ""
    header = textwrap.dedent(f"""\
        -- CAO Governed Definition (Snowflake)
        {name_line}
        -- Format: keyword/function UPPER | PascalCase aliases | ID all-caps | explicit AS
    """).strip()
    return header + "\n" + sql


# ── Semantic suggestions (Snowflake-tuned) ───────────────────────────────────
_RAW_PATH_RE = re.compile(r"\b(\w+\.\w+\.\w+)\b")
_CAST_RE = re.compile(r"\bCAST\s*\(", re.IGNORECASE)


def _detect_semantic_suggestions(sql: str) -> list[dict]:
    suggestions: list[dict] = []
    for i, line in enumerate(sql.split("\n")):
        lineno = i + 1
        if line.lstrip().startswith("--"):
            continue
        for m in _RAW_PATH_RE.finditer(line):
            suggestions.append({
                "type": "SUGGEST-001",
                "description": f"Raw three-part path '{m.group(1)}' — prefer {{{{ ref() }}}} / {{{{ source() }}}} for entity isolation.",
                "location": f"{lineno}:{m.start() + 1}",
                "before": m.group(1),
                "after": f"{{{{ ref('{m.group(1).split('.')[-1]}') }}}}",
            })
        for m in _CAST_RE.finditer(line):
            suggestions.append({
                "type": "SUGGEST-002",
                "description": "CAST() — consider TRY_CAST() in Snowflake to avoid errors on invalid input.",
                "location": f"{lineno}:{m.start() + 1}",
                "before": "CAST(",
                "after": "TRY_CAST(",
            })
    return suggestions


# ── Public API ───────────────────────────────────────────────────────────────
def format_snowflake_sql(
    sql: str,
    object_name: str = "",
    config_path: str | None = None,
    dialect: str = "auto",
) -> tuple[str, list[dict]]:
    """
    Cosmetically normalize SQL and return semantic suggestions.

    Tier 1 (applied):  sqlfluff fix (CP01/CP03/AL/LT — NOT CP02), header comment.
    Tier 2 (returned): semantic suggestions — NEVER auto-applied.

    Identifier case doctrine is enforced separately via check_identifier_doctrine().

    Args:
        sql:         Raw SQL to format.
        object_name: Optional name for the header comment.
        config_path: Optional path to .sqlfluff config file.
        dialect:     SQL dialect hint (snowflake|bigquery|duckdb|redshift|ansi|auto).
                     Use "auto" (default) to auto-detect from SQL syntax patterns.
    """
    if not sql or not sql.strip():
        return sql, []

    # Auto-detect dialect from SQL syntax patterns when dialect="auto"
    resolved_dialect = dialect.lower()
    if resolved_dialect == "auto":
        resolved_dialect = _auto_detect_dialect(sql)

    try:
        formatted = _run_sqlfluff_fix(sql, config_path, dialect=resolved_dialect)
    except Exception:
        formatted = sql

    try:
        formatted = _add_header_comment(formatted, object_name)
    except Exception:
        pass

    try:
        suggestions = _detect_semantic_suggestions(sql)
    except Exception:
        suggestions = []

    return formatted, suggestions


def lint_snowflake_sql(
    sql: str,
    config_path: str | None = None,
    dialect: str = "auto",
    file_path: str | None = None,
) -> list[dict]:
    """
    CI-gate helper: return combined lint findings = sqlfluff violations
    (colons/OBJECT protected when Snowflake, CP02 excluded) + CAO
    identifier-doctrine violations.

    An empty list means the file passes the CAO gate.

    Args:
        sql:         Raw SQL to lint.
        config_path: Optional path to .sqlfluff config file.
        dialect:     SQL dialect hint (snowflake|bigquery|duckdb|redshift|ansi|auto).
                     Use "auto" (default) to auto-detect from SQL syntax patterns.
        file_path:   Optional source path. Used for per-path rule exemptions —
                     auto-generated models/wide_layer/* files are exempt from
                     LT05 (line length) because their long OBJECT_CONSTRUCT_
                     KEEP_NULL(...)... AS <MetricName> lines are machine-built
                     and intentional (see .sqlfluff [sqlfluff:path:models/wide_layer]).
    """
    findings: list[dict] = []

    # Per-path exemption: wide_layer is auto-generated; LT05 is noise there.
    is_generated_wide = bool(file_path) and "wide_layer" in file_path.replace("\\", "/")

    # Auto-detect dialect from SQL syntax patterns when dialect="auto"
    resolved_dialect = dialect.lower()
    if resolved_dialect == "auto":
        resolved_dialect = _auto_detect_dialect(sql)
    is_snowflake = resolved_dialect == "snowflake"

    # 1. CAO identifier doctrine (the CP02 replacement)
    findings.extend(check_identifier_doctrine(sql))

    # 2. sqlfluff lint (not fix) with protections
    try:
        from sqlfluff.core import Linter, FluffConfig

        overrides = {"dialect": resolved_dialect, "exclude_rules": "capitalisation.identifiers"}
        if config_path and Path(config_path).is_file():
            config = FluffConfig.from_root(extra_config_path=config_path, overrides=overrides)
        else:
            config = FluffConfig.from_root(overrides=overrides)
        linter = Linter(config=config)

        body = _CONFIG_BLOCK_RE.sub("", sql)  # drop {{ config }} BEFORE jinja-protect
        protected, _j = _protect_jinja(body)
        if is_snowflake:
            protected, _c, _col = _protect_snowflake_constructs(protected)
        # lint_string() runs the RULE engine (CP01/CP03/AL/LT...), unlike
        # parse_string() which only surfaces PRS parse errors. fix=False so we
        # report violations without mutating the SQL.
        result = linter.lint_string(protected, fix=False)
        for v in result.violations:
            code = v.rule_code() if hasattr(v, "rule_code") else "???"
            # Skip LT05 (line length) for auto-generated wide_layer files.
            if is_generated_wide and code == "LT05":
                continue
            # AL05 false-positive: sqlfluff's Snowflake dialect does not
            # recognize a LATERAL FLATTEN alias as "used" when its fields
            # are accessed via colon notation (alias.value:Field). The
            # alias is genuinely referenced, but sqlfluff still flags it
            # unused, and its only available autofix is to DELETE the alias
            # — which would break every downstream reference to it. This is
            # a dialect gap, not dead code. Only skip AL05 when the flagged
            # alias is declared immediately after a LATERAL FLATTEN(...) in
            # this same statement; a genuinely unused, non-FLATTEN alias
            # must still fail the gate.
            if code == "AL05":
                alias_match = re.search(r"Alias '(\w+)' is never used", str(v))
                if alias_match:
                    flatten_alias_re = re.compile(
                        rf"LATERAL\s+FLATTEN\([^)]*\)\s+AS\s+{re.escape(alias_match.group(1))}\b",
                        re.IGNORECASE,
                    )
                    if flatten_alias_re.search(sql):
                        continue
            findings.append({
                "rule": code,
                "message": str(v),
            })
    except Exception as e:
        findings.append({"rule": "FORMATTER-ERROR", "message": f"sqlfluff pass failed: {e}"})

    return findings
