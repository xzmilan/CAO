#!/usr/bin/env python3
"""
lint_all.py — CAO CI lint gate runner.

Runs sql_formatter_snowflake.py across every model file in a domain and exits
non-zero if ANY file has a finding. This is the authoritative CAO Snowflake
lint gate.

There are two things raw sqlfluff can't do, so this wrapper handles them:
  (a) Snowflake-only syntax — colon field access (Policy.Policy:Field) and
      multi-field ::OBJECT(Field TYPE, ...) casts. These are protected before
      sqlfluff parses and restored after, because raw sqlfluff throws PRS on
      both of them;
  (b) the CAO identifier doctrine — ID all-caps, raw source columns
      UPPER_SNAKE, metric aliases PascalCase. This is enforced in Python
      because sqlfluff's CP02 'consistent' policy can't express it (CP02
      would force ONE case per file and would semantically rename
      identifiers — it'd turn ID→Id or TenureDays→TENUREDAYS). So CP02 is
      disabled and this check replaces it.

After those pass, the sqlfluff engine (CP01/CP03/AL/LT) runs normally.

Usage (from anywhere):
    python3 tools/lint_all.py                          # lints domains/CustomerJourney
    python3 tools/lint_all.py --domain CustomerJourney # same, explicit
    python3 tools/lint_all.py --domain SomeOtherDomain # lints domains/SomeOtherDomain

Exit code 0 = all files clean (gate passes). 1 = one or more findings (gate fails).
Paths are resolved relative to this file's location, so it works regardless of CWD.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

# tools/ dir = this file's parent; CAO root = parent of tools/.
TOOLS_DIR = Path(__file__).resolve().parent
CAO_ROOT = TOOLS_DIR.parent
sys.path.insert(0, str(TOOLS_DIR))

from sql_formatter_snowflake import lint_snowflake_sql  # noqa: E402

CONFIG = CAO_ROOT / ".sqlfluff"


def main() -> int:
    parser = argparse.ArgumentParser(description="CAO CI lint gate runner.")
    parser.add_argument("--domain", default="CustomerJourney",
                        help="Domain folder under domains/ to lint (default: CustomerJourney).")
    args = parser.parse_args()

    domain_dir = CAO_ROOT / "domains" / args.domain
    if not domain_dir.is_dir():
        print(f"ERROR: domain not found: {domain_dir}", file=sys.stderr)
        return 1

    sql_files = sorted((domain_dir / "models").rglob("*.sql"))
    print(f"Linting {len(sql_files)} model files in domains/{args.domain} ...\n")

    total = 0
    failed = 0
    for f in sql_files:
        rel = f.relative_to(domain_dir)
        findings = lint_snowflake_sql(f.read_text(), str(CONFIG), file_path=str(rel))
        if findings:
            failed += 1
            total += len(findings)
            print(f"FAIL {rel}  ({len(findings)} findings)")
            for x in findings:
                print(f"      [{x['rule']}] {x['message'][:100]}")
        else:
            print(f"ok   {rel}")

    print(f"\nSUMMARY: {failed}/{len(sql_files)} files with findings, {total} total")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
