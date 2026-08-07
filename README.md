# CAO — Consumer Analytics Orchestration

An AO-style domain monorepo. Each **domain** under `domains/` is a
self-contained dbt project (its own `dbt_project.yml`, `profiles.yml`,
`models/`, `tools/`). Shared platform tooling lives at the repo root.

## Layout

```
CAO/
├── .github/workflows/        # one CI workflow per domain, path-filtered
├── .sqlfluff                 # shared SQL lint rules (Snowflake dialect)
├── CODEOWNERS                # per-domain review ownership
└── domains/
    └── CustomerJourney/      # domain #1 — retention / customer-journey scorecards
        ├── dbt_project.yml
        ├── profiles.yml
        ├── models/           # raw_layer / metric_layer / wide_layer / view_layer
        ├── seeds/  macros/  tests/
        └── tools/
            └── generate_wide_layer.py   # wide-table auto-assembly
```

## Add a new domain

1. `cp -R` an existing domain (or scaffold fresh) into `domains/<NewDomain>/`.
2. Give it its own `dbt_project.yml` (`name:` must be unique) and `profiles.yml`.
3. Copy `.github/workflows/customer_journey_ci.yml` → `<new_domain>_ci.yml` and
   update the two `paths:` blocks and the `working-directory`/domain folder.
4. Add a `/domains/<NewDomain>/  @owner` line to `CODEOWNERS`.

## How a change flows (PR-gated)

1. Edit files inside `domains/<Domain>/` on a branch.
2. Open a PR → CI runs **only for the domain(s) whose files changed**:
   - **Auto-assembly check** — wide tables in sync with `metric_layer/`.
   - **SQLFluff lint** — style against `.sqlfluff`.
   - **dbt compile** — Jinja + DAG validation (no warehouse needed).
3. CODEOWNERS reviewer approves; branch protection requires green checks.
4. Merge to `main` → the **deploy** job pushes to Snowflake via
   `snow dbt deploy --temporary-connection` and runs the build.
   (Currently gated `if: false` until Snowflake is reachable from CI runners.)

## Docs

Business-requirement docs, JO CSVs, and Snowflake discovery diagnostics are
kept **local-only** (not committed) — see the sibling `FarmersContract/docs/`
working folder. This repo is code + CI only.
