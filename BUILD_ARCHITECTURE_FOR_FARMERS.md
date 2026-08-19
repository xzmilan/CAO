# CAO CustomerJourney — Build Architecture for Farmers

**Audience:** Director, director's analyst, IT team, and up to the director's leadership.
**Purpose:** This document explains how the CustomerJourney pipeline builds nightly, what each layer does and the purpose behind the design.
**Date:** 2026-08-18
**Author:** Steven Passanante

---

## The short version 

When new changes to code are merged in GitHub those changes get deployed once per day from GitHub to Snowflake, unless overridden. There's a daily build at 7:00 AM ET that takes whatever code is merged to `main` in GitHub, pushes it into Snowflake as a native DBT PROJECT object, and then tells Snowflake to execute the full pipeline — raw entities → metrics → wide tables → business views — in dependency order.

The raw layer is **incremental** — it only reprocesses policies that actually changed since the last run, not all 42 million policies every night. The metric and wide layers are **full rebuilds** — they recompute from scratch every night regardless of how few rows changed upstream. Views are free — they're saved query text, always current, zero build cost.

The big cost win is on the raw layer: the policy transaction table (`rten_dim_pl_trn_xlob`) is 421 million rows / 172 GB, and it only scans new transactions since the last run.

---

## How the daily build actually runs — step by step

This is the sequence that fires every day at 7:00 AM ET (12:00 UTC), triggered by a GitHub Actions schedule:

1. **GitHub Actions checks out the repo** — whatever's been merged to `main` by 7am is what runs. There's no separate "sync" step and no drift between git and Snowflake — the code in git is the source of truth, and Snowflake gets a fresh copy every night.

2. **Wide layer SQL gets regenerated** — a Python script (`tools/generate_wide_layer.py`) reads the metric files and writes fresh wide-layer SQL. This happens on the GitHub runner, not Snowflake — it's just file generation, no warehouse cost.

3. **The dbt project gets deployed into Snowflake** — `snow dbt deploy` uploads the project source (`.sql` files, `dbt_project.yml`, macros, YAML) into Snowflake as a native **DBT PROJECT object**. This is Snowflake's feature where dbt projects run *inside* Snowflake's own compute, not from an external orchestrator hitting Snowflake via a connection. This step is fast — it's a code upload, not data movement.

4. **Snowflake executes the build** — `snow dbt execute ... build` tells Snowflake to run the just-uploaded DBT PROJECT. This is the step that actually does warehouse compute and billing. dbt's `build` command runs the entire DAG in dependency order: raw → metric → wide → view.

5. **Tests run** — dbt runs data tests (uniqueness, not-null, custom SQL assertions) after the build. If a test fails, the job reports failure but the tables are already built — the failure is a signal to investigate, not a rollback.

A manual trigger (`workflow_dispatch`) is also available from the GitHub Actions tab for on-demand runs — useful for testing a change immediately rather than waiting for the schedule.

---

## The key concept: code gets replaced, data does not

**The deploy step replaces the model definitions (the code). It does not touch the materialized tables.**

When dbt's incremental logic runs, it checks: "does the target table — say, `RAW_POLICY.PolicyRaw` — already exist in Snowflake right now?" If yes (it was built last night and just sits there in the schema), then `is_incremental()` evaluates true, and the compiled SQL becomes a `MERGE` statement that:
- Reads the high-water-mark timestamp out of the **existing table**
- Filters the source to only rows newer than that watermark
- Merges just those new/changed rows into the existing table

The table itself is never dropped or recreated during an incremental run. It's the same physical table, updated in place, night after night.

**What would reset it (and only these things):**
- Running with `--full-refresh` explicitly (manual trigger only, not part of the nightly cron)
- Someone manually dropping or truncating the table in Snowflake
- A schema/database rename that points at a different target

---

## How each layer updates 

Materialization type (`table` vs `incremental` vs `view`) controls *how* a model rebuilds, not *whether* it runs.

### Raw layer (incremental)
- Runs as a `MERGE` — only reprocesses policies flagged by the watermark signals
- A policy that changed in the source gets picked up, reprocessed, and merged into the existing table
- A policy that didn't change is skipped entirely
- **Cost scales with new activity volume, not total table size**

### Metric layer (full rebuild every night)
- Runs as `CREATE OR REPLACE TABLE` — recomputes every metric for every policy, every night
- It doesn't matter that raw layer only touched 500 policies — metric layer does a fresh join against the entire `PolicyRaw` table (all 42M rows) and recomputes everything
- **Cost is flat every night, independent of raw's incremental savings**

### Wide layer (full rebuild every night)
- Same story — full rebuild, joining the entire metric + raw tables together
- It's a pure pass-through (no aggregation, no transformation), but still gets rebuilt from scratch every night
- **Cost is flat every night**

### View layer (no build cost)
- Views are saved query text — "updated" is instantaneous and continuous
- A view always reflects whatever's in wide/metric/raw at query time
- `dbt build` still issues the `CREATE VIEW` DDL, but that's nearly free

---

## The incremental design — what it catches and what it saves

The raw layer uses three change-detection signals, unioned together, to decide which policies to reprocess each night:

1. **New transactions in the policy transaction table** — watermark on `SRC_TRANS_TMSP` (when the source system recorded the transaction). This is the primary signal and catches the vast majority of changes.

2. **Changed rows in the policy master table (`fdr_mdm_plcy_stats`)** — this is an SCD2 table (slowly-changing dimension, type 2 — it keeps full history with effective/end dates). We filter to the current row only and watermark on its `SRC_TRANS_TMSP`. This catches attribute changes (policy status, agent of record, prior-policy flag) that don't necessarily produce a transaction.

3. **Rolling lookback on monthly snapshots** — the FWS monthly snapshot table (`tfrdb_fws_pol_snap_mthly_rpt`) gets a 3-month rolling window so late-arriving monthly data still lands in the right place.

**One deliberate exception:** the driving policy spine (`rten_xcmpy_pif_tbl`, the current-state snapshot — ~42M rows) is read in full every night, by design. That table has no reliable per-row change signal — its timestamp columns are batch/ETL metadata, not row-level change markers — so there's nothing safe to watermark on. This is an accepted tradeoff: it's the smallest of the four sources by an order of magnitude, it's a current-state snapshot (it doesn't grow with history the way the 421M-row transaction table does), and the full read is what guarantees the watermarked enrichment tables can never drift silently away from the spine. Any change that touches a policy almost always lands in the transaction table or the SCD2 master first — both watermarked — so the expensive scans stay incremental while the spine read stays flat and predictable. The reconciliation backstop for anything truly silent (an in-place source correction that leaves no transaction or SCD2 footprint) is the periodic `--full-refresh`, same mechanism that covers delete propagation.

### What this costs — and why it's designed this way

**The cost profile:**
- Only new/changed transactions get scanned and processed each night
- Cost scales with **new activity volume** — typically a tiny fraction of the 421M rows
- A quiet night (few new transactions) costs nearly nothing; a busy night costs proportionally more
- You pay for what changed, not for what's already there

**Why this matters:**
- The policy transaction table is 421M rows / 172GB and only grows — scanning it in full every night would mean warehouse cost scales with total table size forever
- A full scan + window-function sort over 421M rows is measured in minutes of warehouse time, not seconds — at Farmers credit rates, that's real dollars per run, every night, indefinitely
- The incremental design means the cost of a nightly build stays roughly flat over time, even as the underlying data grows

---

## The deploy cadence — why nightly, not per-merge

The deploy runs on a schedule (7am ET nightly), not on every PR merge to `main`.

**Why:**
- Merges to `main` just update the branch — the next scheduled run picks up everything accumulated since the prior run in one batched deploy
- With incremental raw models, triggering a full deploy pipeline on every merge means paying Snowflake warehouse spin-up and MERGE overhead per-merge instead of once per day for the same eventual freshness
- For a customer-journey/retention semantic layer feeding metrics and Power BI dataflows (not a real-time app), nightly freshness is acceptable — retention scorecards and drift analysis don't need intraday updates

**If we didn't do this:**
- Per-merge deploys during active development weeks could mean multiple full-pipeline runs per day
- Each run has warehouse startup overhead (Snowflake bills per-second with a minimum spin-up cost) — frequent runs pay that startup cost repeatedly even when the actual work is small
- Batching to a schedule amortizes that startup cost across more accumulated work per run

A manual trigger stays available for on-demand runs when someone needs a change deployed immediately rather than waiting for the schedule.

---

## Known tradeoffs and open items

These are documented honestly — not problems, but design decisions with accepted limitations:

### Delete non-propagation
Merge-based incremental never deletes. If a policy is removed from the source `rten_xcmpy_pif_tbl`, it stays in `PolicyRaw` until a `--full-refresh` runs. Same for voided transactions or withdrawn survey campaigns.
- **Mitigation:** A periodic full-refresh cadence (e.g., monthly) as a reconciliation backstop. This is documented in the model YAML, not just a comment.

### Metric and wide layers are still full rebuilds
The incremental design covers the raw layer. Metric and wide layers do a full `CREATE OR REPLACE TABLE` every night, joining against the entire raw table regardless of how few rows changed.
- **Impact:** With the raw layer incremental, these become the dominant per-run cost.
- **Next step:** Metric layer is the best candidate for the same incremental treatment (it joins 1:1 to the raw entity's ID, so it can scope to the same changed-policy set). This is a documented phase-2 opportunity.

### Contact entity is a scaffold
`ContactRaw` builds successfully but its core join is a placeholder (`ON FALSE`) pending diagnosis work on how contact events map to APEX contacts. It deploys every night and produces a table where contact events are always an empty array.
- **Status:** Documented as scaffold in the model YAML. Nothing downstream reads it yet. Will be completed when the join diagnosis lands.

### Survey scope is partial
`SurveyRaw` only implements the agent-change campaign type today. New business, renewal, RNPS, and CSS CES campaign types have sources declared but no CTEs built yet.
- **Status:** Documented scope gap, not a bug. When the remaining campaign types are built, the renewal invite source (9.8M rows) will need the same incremental lookback pattern from day one.

### DST drift on the schedule
GitHub Actions cron is always UTC and doesn't adjust for daylight saving time. The 7am ET schedule is pinned to EST (12:00 UTC) — during EDT months (mid-March to early November), the actual run lands at 8am ET, one hour later than intended.
- **Impact:** Minimal for an analytics pipeline — a 1-hour drift twice a year doesn't affect data correctness, only the exact run time.
- **Mitigation:** Documented in the workflow file. Can be manually flipped twice a year or replaced with a DST-aware external scheduler if it ever matters.

---

## The architecture at a glance

```
GitHub (main)
    │
    │  7am ET nightly cron (or manual trigger)
    ▼
GitHub Actions runner
    │
    ├── Regenerate wide-layer SQL (local file generation, no warehouse cost)
    │
    ├── snow dbt deploy  →  uploads project source into Snowflake DBT PROJECT object
    │                        (code upload, not data movement)
    │
    └── snow dbt execute build  →  Snowflake runs the full DAG:
         │
         ├── Raw layer (incremental MERGE)
         │   ├── PolicyRaw         — watermarks + SCD2 current-row + full spine read
         │   ├── ChangeEventRaw    — watermark + anti-join for new policies
         │   ├── SurveyRaw         — 3-month rolling lookback
         │   └── ContactRaw        — scaffold (placeholder join)
         │
         ├── Metric layer (full rebuild)
         │   └── Recomputes all metrics from raw, every night
         │
         ├── Wide layer (full rebuild)
         │   └── Pass-through join of raw + metrics, every night
         │
         └── View layer (views — no build cost)
             └── Always current, reflects whatever's in wide/metric/raw
```

