#!/usr/bin/env python3
"""
rule_help.py — analyst-facing "what do I do about this" text for CAO CI gate
findings. Shared by lint_all.py and check_column_contracts.py so the same
rule prints the same guidance no matter which gate caught it.

Each entry is a short, human-readable block: which standard it enforces,
why the rule exists (the downstream consequence of ignoring it), what to
change, and where the full written standard lives. Findings only ever print
a code + one-line message from the underlying tool — this module is what
turns that into something an analyst can act on without pinging a reviewer.

Keep entries SHORT. This is printed once per distinct rule per run, not per
violation — long blocks defeat the purpose.
"""
from __future__ import annotations

# Path shown to analysts — adjust if SP_SQLStandards.md moves.
_STANDARDS_DOC = "FarmersContract/SP_SQLStandards.md"

RULE_HELP: dict[str, str] = {
    "NO-STAR-REF": (
        "Our standards don't allow \"SELECT *\" (or \"Alias.*\") when the model "
        "reads from a ref(). This breaks downstream dependency tracking — if an "
        "upstream field is ever renamed or removed, nothing can tell you which "
        "consumers broke, because \"*\" doesn't say which fields you actually rely "
        "on. List the exact columns you need instead.\n"
        f"    Read here for more: {_STANDARDS_DOC} — \"Field prefix\" / wide-layer "
        "\"pass through\" sections."
    ),
    "COLUMN-CONTRACT": (
        "An upstream field this model references no longer exists under that "
        "name — it was renamed, removed, or the case doesn't match. Snowflake's "
        "colon field access (Object:Field) is case-sensitive to how the field was "
        "declared in the OBJECT cast, so even a casing mismatch counts as a break. "
        "Fix it by either (a) updating this model to the field's current name/case, "
        "or (b) if you're the one who renamed the upstream field, updating every "
        "consumer this violation lists.\n"
        f"    Read here for more: {_STANDARDS_DOC} — \"System-Specific STRUCT\" "
        "and \"Link to Raw Layer Table\" sections."
    ),
    "CAO-IDENTIFIER-CASE": (
        "Table and field aliases must be PascalCase — this is the naming standard "
        "for every layer, not just a style preference. ALL-CAPS is reserved for "
        "the entity key 'ID' and raw source columns (UPPER_SNAKE) only.\n"
        f"    Read here for more: {_STANDARDS_DOC} — \"PascalCase\" row in the "
        "Coding Standards table."
    ),
    "CP01": (
        "Keywords (SELECT, FROM, WHERE, CASE, WHEN, END, JOIN, ON, AND, OR, etc.) "
        "must be upper case. sqlfluff fix (Job 0) usually corrects this "
        "automatically — if you're seeing it after auto-fix ran, check whether "
        "the keyword is inside a comment or string literal, which auto-fix "
        "intentionally leaves alone.\n"
        f"    Read here for more: {_STANDARDS_DOC} — \"Line spacing\" row."
    ),
    "LT01": (
        "Comma/whitespace spacing doesn't match the standard — commas go BEFORE "
        "the field, with a single space after. sqlfluff fix (Job 0) auto-corrects "
        "this; if it's still failing after auto-fix, look for a comma inside a "
        "multi-line expression the fixer couldn't safely reformat.\n"
        f"    Read here for more: {_STANDARDS_DOC} — \"Field commas\" row."
    ),
    "LT02": (
        "Indentation doesn't match the standard (CASE/WHEN indented under CASE, "
        "fields indented under SELECT, etc.). sqlfluff fix (Job 0) auto-corrects "
        "this in almost all cases.\n"
        f"    Read here for more: {_STANDARDS_DOC} — \"Indentation\" row."
    ),
    "NO-SUBQUERY-JOIN": (
        "Subqueries aren't allowed in JOIN or WHERE clauses — extract to a CTE "
        "instead. This keeps every intermediate result named and reviewable, "
        "and avoids a class of correlated-subquery bugs Snowflake handles "
        "inconsistently.\n"
        f"    Read here for more: {_STANDARDS_DOC} — \"Subqueries\" row."
    ),
    "METRIC-INNER-JOIN": (
        "A metric joining to another raw/metric table on the same "
        "grain should use INNER JOIN (plain JOIN), not LEFT/RIGHT — this is "
        "different from a LEFT JOIN to a local CTE for zero-fill, which is "
        "still correct. If you intended a zero-fill pattern, join to a CTE, "
        "not directly to a ref().\n"
        f"    Read here for more: {_STANDARDS_DOC} — \"Metric Layer\" JOIN row."
    ),
    "FIELD-PREFIX-WARN": (
        "This column reference isn't prefixed with its table alias. In a "
        "multi-table query this is ambiguous to a reader even when Snowflake "
        "can resolve it — prefix every field with Alias.Column.\n"
        f"    Read here for more: {_STANDARDS_DOC} — \"Field prefix\" row."
    ),
    "LEFT-JOIN-ORDER": (
        "LEFT JOIN table ordering (FROM table must be the one you want ALL "
        "rows from) can't be checked by static analysis — it depends on which "
        "table actually has more/fewer matching rows at runtime, which isn't "
        "knowable from the SQL text alone. This is a PERMANENT manual-review "
        "item, not a gap we intend to close with tooling.\n"
        f"    Read here for more: {_STANDARDS_DOC} — \"LEFT JOINS\" row."
    ),
}

_DEFAULT_HELP = (
    "No specific guidance is written for this rule code yet. Check "
    f"{_STANDARDS_DOC} for the general standard it likely maps to, or ask in "
    "#cao-support."
)


def get_help(rule_code: str) -> str:
    """Return analyst-facing guidance for a rule code, or a generic fallback."""
    return RULE_HELP.get(rule_code, _DEFAULT_HELP)


def print_help_for_rules(rule_codes: set[str]) -> None:
    """Print one help block per distinct rule code, in a stable order."""
    if not rule_codes:
        return
    print("\nWHAT TO DO ABOUT THIS:")
    for code in sorted(rule_codes):
        print(f"\n  [{code}]")
        for line in get_help(code).split("\n"):
            print(f"  {line}")
