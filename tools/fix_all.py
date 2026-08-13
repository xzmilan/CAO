#!/usr/bin/env python3
"""
fix_all.py — CAO auto-fix runner.

Runs sql_formatter_snowflake.py in FIX mode across every model file in a domain,
applying safe cosmetic fixes (CP01/CP03/AL/LT — NOT CP02) automatically.

This is the "make it green" companion to lint_all.py. Run it before committing
to auto-fix what can be fixed, then run lint_all.py to verify what remains.

Usage (from anywhere):
    python3 tools/fix_all.py                          # fixes domains/CustomerJourney
    python3 tools/fix_all.py --domain CustomerJourney # same, explicit
    python3 tools/fix_all.py --domain SomeOtherDomain # fixes domains/SomeOtherDomain

Exit code 0 = all files processed (some may have been modified).
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

# tools/ dir = this file's parent; CAO root = parent of tools/.
TOOLS_DIR = Path(__file__).resolve().parent
CAO_ROOT = TOOLS_DIR.parent
sys.path.insert(0, str(TOOLS_DIR))

from sql_formatter_snowflake import format_snowflake_sql  # noqa: E402

CONFIG = CAO_ROOT / ".sqlfluff"


def main() -> int:
    parser = argparse.ArgumentParser(description="CAO auto-fix runner.")
    parser.add_argument("--domain", default="CustomerJourney",
                        help="Domain folder under domains/ to fix (default: CustomerJourney).")
    args = parser.parse_args()

    domain_dir = CAO_ROOT / "domains" / args.domain
    if not domain_dir.is_dir():
        print(f"ERROR: domain not found: {domain_dir}", file=sys.stderr)
        return 1

    sql_files = sorted((domain_dir / "models").rglob("*.sql"))
    print(f"Fixing {len(sql_files)} model files in domains/{args.domain} ...\n")

    fixed_count = 0
    for f in sql_files:
        rel = f.relative_to(domain_dir)
        original = f.read_text()
        formatted, suggestions = format_snowflake_sql(
            original,
            object_name=f.stem,
            config_path=str(CONFIG),
        )
        if formatted != original:
            f.write_text(formatted)
            fixed_count += 1
            print(f"FIXED {rel}")
            if suggestions:
                for s in suggestions:
                    print(f"      [suggestion] {s.get('message', '')[:80]}")
        else:
            print(f"ok    {rel}")

    print(f"\nSUMMARY: {fixed_count}/{len(sql_files)} files modified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
