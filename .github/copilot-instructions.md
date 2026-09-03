# GITHUB COPILOT INSTRUCTIONS: MESA SEMANTIC ENGINEERING — UNIVERSAL CLIENT STANDARDS

These rules apply to ALL GitHub Copilot Chat inquiries and inline edits in this workspace. Every model
must treat MESA's four-tier architecture as non-negotiable — the constraints below are structural,
not stylistic. Breaking them produces code that looks like SQL but isn't valid MESA SQL.

This file is **client-agnostic**. It is the single canonical contract for every domain under
`domains/`, and it should be copied verbatim into any new client engagement. Client-specific
details (source-system names, natural keys, BI tool wiring) belong in that client's `domains/<Client>/`
folder and in its `CODEOWNERS` entry — never in this file.

## 1. THE FOUR-TIER ARCHITECTURE (NON-NEGOTIABLE)

Data flows unidirectionally across four tiers. No layer can be skipped. No raw data enters above
Tier 1. No metric logic lives outside Tier 2.

```
RAW LAYER (Tier 1)        →  METRIC LAYER (Tier 2)  →  WIDE LAYER (Tier 3)  →  VIEW LAYER (Tier 4)
  Business concept tables     One file = one metric     Pure assembly, no logic   Consumer-facing views
  Hashed PKs, PascalCase      2 columns: ID + value     SELECT full STRUCTs only  WHERE filters allowed
  No calculations             LEFT JOIN (1:1 fill)      No aliases, no CASE       ID aliased for BI
```

Every tier has exactly one job. If you find yourself putting logic from one tier into another,
stop — you're about to break the contract.

---

## 2. RAW LAYER RULES (TIER 1)

The Raw Layer represents business concepts, not system concepts. `Policy` is a business concept.
A source system's `PLCY_CNTRCT` table is a system concept. The Raw Layer abstracts away the source
system so downstream layers never need to know where a field physically came from.

### What "entity" actually means — the materials-list analogy

If a new engineer asks "what IS an entity, really?" — use this: **an entity is a raw material,
not a metaphor for one.** Think of building a bridge deck. Before you pour anything, you assemble
the materials list: Portland cement powder, water, gravel, sand, the mixer. Every one of those
materials just IS what it is. Nobody asks "what does this bag of cement mean?" It has an
identity — cement, not flour — and that identity is stable and uninterpreted. That materials list
is the Raw Layer. `Customer`, `Policy`, `Order` are cement, water, gravel — enriched enough to be
identifiable (hashed ID, clean business name, STRUCT boundary) but never answering a question.

The mixing calculation — water-cement ratio, aggregate proportions, the psi rating the mix cures
to — is the Metric Layer. That's where "IS" becomes "MEANS": the materials didn't change, but a
calculation produced a conclusion, with an owner and a version. **Nobody confuses a bag of cement
with the psi rating of the mix.** That one sentence is the entire Raw Layer / Metric Layer
boundary. If a transformation only makes an identity clearer (a hash, a clean name, a STRUCT), it
stays in the Raw Layer. The moment a transformation produces an answer (a `SUM`, a `CASE WHEN`, a
threshold), it has crossed into MEANS and belongs in the Metric Layer instead.

This is also why MESA differs from every other "semantic layer." Power BI measures, LookML,
dbt's Semantic Layer/MetricFlow, Cube, a medallion gold layer — every one of them starts at MEANS
and assumes the IS was already solved by whatever table happens to have an ID column. None of them
formally declare what a `Customer` IS, with a governed, single-owner contract. MESA is the only
one that governs both halves — identity in the Raw Layer, interpretation in the Metric Layer — as
two separate, separately-owned concerns.

**What "starting at MEANS" literally looks like in each tool** — the first artifact a builder
writes is always an interpretation, never an identity declaration:

| Tool | The first thing you write | What it silently assumes |
|---|---|---|
| **Power BI / DAX** | `Revenue = CALCULATE(SUM(Orders[Amount]), ...)` | `Orders`, `Customer`, and their keys already exist and mean one thing to everyone |
| **LookML (Looker)** | `measure: revenue { sql: ${TABLE}.amount ;; type: sum }` inside an `explore` | The underlying table's grain and key are already correct; LookML never declares identity, only computation |
| **dbt Semantic Layer / MetricFlow** | `metrics: - name: revenue_usd, type: simple, type_params: {measure: order_amount}` | The dbt *model* underneath (`stg_orders`) already has a settled grain/PK — MetricFlow starts one layer above that decision |
| **Cube** | `measures: { revenue: { sql: 'amount', type: 'sum' } }` in a cube definition | The SQL table backing the cube already has a stable, agreed identity column |
| **Medallion gold layer** | `gold_customer_360.sql` with `SUM(...)`, `CASE WHEN`, and a `customer_tier` derived column | Bronze/Silver already resolved what a "customer" is; Gold jumps straight to interpretation with no separate identity contract |
| **Star schema / Kimball** | `DimCustomer` + a `FactSales` row keyed by a surrogate key from the ETL load | The surrogate key IS the identity decision — but it's made inside ETL load logic, not in a governed, owned, reviewable file |

Every row in that table starts with a calculation, a formula, or a join — not a declaration of
"here is what a Customer IS, and here is the one file that owns that answer." That's the tell.
If the very first artifact in a tool already contains a `SUM`, a `CASE`, or an aggregation, you're
looking at a MEANS-only semantic layer — useful, but it inherited its IS from whatever table
happened to be sitting underneath it, unowned and ungoverned. MESA is the only one that makes the
IS a first-class, separately-owned artifact — the Raw Layer file — before any MEANS is written
at all.

This dbt project was created using MESA (Metric Encapsulated Semantic Architecture) standards, which applies engineering practices to data modeling.
Why MESA works: Every tool in the table above works correctly on top of an identity question nobody wrote down. That's not a flaw
in any one of them — it's the default state of the industry: computation is governed, identity is
guessed. If you're reviewing a PR and you can't point to the one file that says what a `Customer`
IS, the assumption is still silent. Make it a file before you make it a metric. MESA removes the guesswork 
and makes identity a first-class, reviewable, owned artifact.

### The assumptions this contract exists to close

Every rule in this document maps back to a specific silent assumption the rest of the industry
tolerates. Use this table when someone asks "why are we so strict about this":

| Silent assumption (industry default) | MESA rule that closes it |
|---|---|
| The ID column already means one thing across every source system | Hashed ID with `source_system` baked into the hash input (Sec. 6) |
| Everyone editing this shared model agrees on what changed | One file = one metric = one CODEOWNERS-enforced owner (Sec. 3) |
| The relationship between two tables is obvious enough not to write down | Link STRUCTs declared once in the Raw Layer (Sec. 2) |
| This column will still mean the same thing next quarter | Explicit column lists, `SELECT *` banned everywhere (Sec. 6, item 1) |
| A LEFT JOIN silently tolerating missing rows is harmless | LEFT JOIN in the Metric Layer (1:1 zero/NULL-fill); INNER JOIN in the Wide Layer — no silent NULL (Sec. 3, Sec. 4) |
| This metric doesn't already exist somewhere else | One browsable Metric Layer folder, one metric per file (Sec. 3) |
| Cross-entity joins are safe wherever they're convenient | Entity isolation — cross-entity joins only at the View Layer, only on declared links (Sec. 5) |
| Someone tested this before it shipped | dbt tests as a CI build gate, not a courtesy (Sec. 3, Sec. 7) |

If a new rule gets proposed for this file, it should close a specific silent assumption. If it
doesn't, ask whether it's a style preference instead of a governance requirement.

### How to build a Raw Layer — it's an enriched table, so start from the end

The Raw Layer is NOT a passthrough copy of a source table. It's an **enriched table**: it takes
raw system fields and adds stable meaning — a hashed ID, PascalCase business names, STRUCT
boundaries, and link STRUCTs — before anything downstream touches it. The one thing it does NOT
add is calculations; that's Tier 2's job. 

Because it's enriched, you don't build it by opening the source schema and copying columns. You
build it backwards, starting from the reporting goals:

1. **Know what the business needs to report first.** The View Layer (Tier 4) defines the domain's
   vocabulary. Read the reporting goals — the questions, scorecards, and dashboards the business
   actually asked for. Those goals name the entities and fields that matter.
2. **Name the business entities.** From the goals, extract the business concepts (`Customer`,
   `Policy`, `Order`, `Claim`, `Survey`). One concept = one Raw Layer table at one grain.
3. **Fix the grain before anything else.** "One row = one policy." If the reality is "one row =
   one policy per month," that's a snapshot and it belongs in the Metric Layer, not here. Grain is
   the hardest decision to reverse — settle it up front.
4. **Split enriched from system-specific.** For each field, decide: is this a stable business
   attribute (top-level PascalCase column) or a source-system ID / raw flag (goes inside the system
   STRUCT)? This is the enrich step, it's a judgment call, and it's the entire reason the Raw Layer
   exists.
5. **Map to source systems last.** Only now do you find where each business field physically lives
   in the source. This is the only place source-system names belong.
6. **Declare relationships with link STRUCTs, never joins.** If a Policy links to a Customer, embed
   `STRUCT(Customer.ID) AS Customer` — don't join the two Raw Layer tables together.

Source-driven is backwards. Goal-driven is correct. Start from `PLCY_CNTRCT` and you end up with a
system concept; start from "what does the business need to report about policies" and you end up
with a `Policy` entity.

### What the Raw Layer MUST do:
- **Hashed primary key on every table:** `TO_BASE64(SHA256(CONCAT(source_system, '-', source_id))) AS ID`
  (Snowflake: `BASE64_ENCODE(SHA2(CONCAT(source_system, '-', source_id), 256)) AS ID`)
  The `source_system` prefix in the hash input is CRITICAL — without it, two different source
  systems with the same integer ID will collide. This is not theoretical; it happened in production.
- **PascalCase aliases for all columns:** `Source.Oracle_Account_Number__c AS OracleAccountNumber`
- **STRUCTs for system-specific fields:** System IDs and raw source fields live inside a
  system-specific STRUCT — `Source.Account.Id`, `Source.Account.Type`. These are quarantined
  here and must never leak into downstream layers.
- **Link STRUCTs for relationships:** When referencing another Raw Layer entity, embed its ID in a
  STRUCT named after the target entity: `STRUCT(Customer.ID) AS Customer`. Multiple links to the
  same entity go in a plural STRUCT: `STRUCT(AccountManagerPerson.ID AS AccountManagerID, ...) AS Persons`
- **SAFE_CAST only:** Never use bare `CAST`. `SAFE_CAST` returns NULL instead of killing the query.
- **LastModifiedDate:** Must be included from the primary source — used for incremental refresh.
- **Explicit column lists:** Every column is listed individually. Never `SELECT *` — not even as a
  convenience during development. `SELECT *` hides schema changes and breaks downstream contracts.

### What the Raw Layer MUST NOT do:
- ❌ No calculations or business logic (exception: boolean→binary `IF(x,1,0)`, scale conversions)
- ❌ No aggregations, no GROUP BY
- ❌ No WHERE filters that remove rows (the Raw Layer is the source of truth — don't pre-filter it)
- ❌ No metric-like columns (KPI scores, period summaries, usage counts)
- ❌ No `SELECT *` — ever
- ❌ No cross-entity joins that mix grains (a Policy table should not join to Claims at the Raw Layer)
- ❌ No system IDs exposed as top-level columns — they live in system-specific STRUCTs only

### Grain rule:
One Raw Layer table = one business entity = one grain. If the table is really "one row per entity
per month," it's a snapshot table and belongs in the Metric Layer, not the Raw Layer.

---

## 3. METRIC LAYER RULES (TIER 2)

The Metric Layer is the center of the universe. Every metric is a single SQL file that returns
exactly two columns. This is the contract that makes the Wide Layer mechanical and the audit trail
clean.

### What the Metric Layer MUST do:
- **One file = one metric:** Each `.sql` file in the metric directory computes exactly one value.
  The file name IS the metric name.
- **Exactly 2 columns:** `SELECT ID, [calculated_value] AS MetricName` — nothing more, nothing less.
  If you need a third column, you're defining two metrics in one file. Split them.
- **LEFT JOIN (not INNER JOIN):** `LEFT JOIN` from the Raw Layer base table to the metric CTE.
  Every entity ID emits a row — the 1:1 zero/NULL-fill contract. This is what makes the Wide
  Layer mechanical: the metric resolves to exactly one value per entity ID, filled explicitly.
  - **The fill must be explicit** — `COALESCE(..., 0)` for counts/flags, or a documented `NULL`
    for scores (e.g., no survey response, no change event) — never a silent NULL.
  - A metric may reach a child grain only via a CTE that `FLATTEN`/`UNNEST`s and then aggregates
    back to entity grain — the terminal SELECT is always 1:1 per ID.
  - *(INNER JOIN belongs to the Wide Layer, not here — see Sec. 4.)*
- **Source from Raw Layer only:** Metrics reference Raw Layer tables and other metrics from the
  same entity. They never reference raw source tables directly.
- **Handle grain reduction internally:** If a metric aggregates from a child grain (e.g., total
  order value per client), the GROUP BY happens inside the metric file. By the time the metric
  reaches the Wide Layer, it's already at the entity grain.

### What the Metric Layer CAN do (the Shape Contract)
The only thing that matters downstream is the **shape** of the output. Inside the file you have
room to work — as long as you land on one row per ID.

- **CTEs are allowed, and encouraged.** Build up a conclusion step by step with `WITH` blocks —
  filter an event stream, compute an intermediate value, aggregate a child grain up — then select
  the final answer. The "no subqueries in JOIN/WHERE" rule pushes you toward CTEs precisely so
  the logic stays readable and auditable.
- **The final SELECT produces exactly one row per ID.** Whatever CTEs you stack above it, the
  terminal statement must resolve every entity ID to a single value. If your CTEs can produce
  more than one row per ID, you haven't finished — collapse it with an aggregation or a `QUALIFY
  ROW_NUMBER()` pick before the final select.
- **Exactly one Raw Layer base table in the final SELECT.** A metric reads from *one* entity's
  Raw Layer table as its anchor. It may reference other metrics of the same entity, and it may
  reach child-grain data through CTEs — but the terminal `FROM` fans out from a single Raw Layer
  entity (joined 1:1 by ID on any other tables). Two Raw Layer entities in one metric means the
  relationship wasn't declared at the Raw Layer first — that's the smell that says stop.
- **The two output columns never change:** `ID` and the metric value. All the CTE sophistication
  collapses into that single scalar.

### Naming conventions (enforced):
| Pattern | Prefix/Suffix | Example |
|---------|--------------|---------|
| Binary/boolean | `Is` | `IsLive`, `IsTerminated`, `HasPro` |
| Count | `NumberOf` | `NumberOfCasesLast30Days` |
| Distinct count | `NumberOfDistinct` | `NumberOfDistinctProducts` |
| Average count | `AverageNumberOf` | `AverageNumberOfEmployees` |
| Date | `Date` suffix | `FirstContractDate`, `LastModifiedDate` |
| Timeframe | Include exact days | `NumberOfCasesClosedLast30Days` |
| Previous value | `Previous` prefix | `PreviousRateIncreaseDate` |
| Next value | `Next` prefix | `NextRenewalDate` |
| Past tense | `Has` prefix for binary | `HasPended` |
| Unit of measure | Prefix with unit | `MonthsToLive`, `SecondsToAnswer` |

### What the Metric Layer MUST NOT do:
- ❌ No `SELECT *` — every column is explicit
- ❌ No INNER JOIN — use LEFT JOIN with an explicit `COALESCE`/documented NULL fill (never a
  silent NULL). A metric's base entity must emit a row for every ID.
- ❌ No raw source table references — Raw Layer only
- ❌ No `WITH RECURSIVE` — the build system wraps each metric as a CTE, and recursive CTEs break
  the assembly step
- ❌ No subqueries in JOIN or WHERE clauses — use CTEs instead
- ❌ No more than 2 output columns
- ❌ No cross-entity joins that haven't been declared at the Raw Layer (the relationship must
  exist as a link STRUCT in the Raw Layer first)

---

## 4. WIDE LAYER RULES (TIER 3)

The Wide Layer is the dumbest layer in the stack — and that's exactly what makes it powerful.
It does one thing: joins the Raw Layer entity to its Metric Layer calcs. Nothing else.

### What the Wide Layer MUST do:
- **SELECT full STRUCTs only:** `SELECT Customer, CustomerMetrics` — the entire Raw Layer object and
  the entire Metric object, passed through as STRUCTs for BigQuery and a python script for Snowflake/Redshift/AWS. No individual column selection, no aliases, no CASE statements, no renaming.
- **JOIN on ID only (INNER JOIN):** `JOIN Metrics.CustomerMetrics ON Customer.ID = CustomerMetrics.ID`
  — the Wide Layer is the one place INNER JOIN lives. Because every metric already emitted a
  row per ID (LEFT-JOIN 1:1 fill in Sec. 3), the INNER JOIN here drops nothing and is purely
  mechanical.
- **Include related entities:** The Wide Layer can join additional Raw Layer tables via the link
  STRUCTs declared in the Raw Layer (e.g., Customer wide table includes Person data via the
  `Persons` link STRUCT)

### What the Wide Layer CAN do (the Assembly Contract)
The Wide Layer is not a single-table file — it is the *assembly* of one entity. Within that
single job it has latitude:

- **One base entity + its metrics.** The Wide Layer anchors on one Raw Layer entity (`Customer`)
  and INNER JOINs every metric of that entity onto it on `ID`. That is the whole point — it's the
  mechanical fan-out.
- **Related entities via declared link STRUCTs.** If the Raw Layer declared a relationship
  (`Customer` embeds `STRUCT(Person.ID) AS Persons`), the Wide Layer may bring that related Raw
  Layer table in — again joined strictly on ID — so downstream consumers get the related data
  without doing the join themselves. The relationship must already exist in the Raw Layer; the
  Wide Layer only *assembles* what was already declared.
- **Auto-generated.** This layer is written by the assembly tool, not by hand. The latitude above
  is for the tool — a human edit to a Wide Layer file is the one thing that is never correct.

### What the Wide Layer MUST NOT do:
- ❌ No `SELECT *` — use STRUCT pass-through
- ❌ No individual column selection — the whole STRUCT, or nothing
- ❌ No aliases on selected objects
- ❌ No CASE statements
- ❌ No WHERE filters
- ❌ No business logic of any kind
- ❌ No transformations
- ❌ No renaming
- ❌ No hand-editing — the Wide Layer is auto-generated. If you're typing column names into a
  Wide Layer file, something has gone wrong.

The Wide Layer has exactly one job: assembly. If you put logic here, you've created a hidden
metric layer that nobody knows to audit, and you've broken the mechanical contract that makes
the Wide Layer auto-generatable.

---

## 5. VIEW LAYER RULES (TIER 4)

The View Layer is the consumer contract. It's the only surface exposed to BI tools, APIs, and
downstream applications. It selects specific columns from the Wide Layer, applies business
filters, and renames everything to match what business users see.

### What the View Layer MUST do:
- **Alias ID with table prefix:** `ID AS CustomerID` — enables BI auto-join between datasets
- **Business-readable names:** Aliases match what users see in the source UI (source-system labels,
  not API names)
- **WHERE filters allowed:** Business views can filter to specific segments
- **LastModifiedDate as the last field:** Required for BI incremental refresh
- **STRUCT field prefixing:** When pulling `Person.ID` from a STRUCT, alias as `PersonID`
- **Explicit column lists:** Every column is listed individually. No `SELECT *`.

### What the View Layer MUST NOT do:
- ❌ No new metric definitions — metrics live in Tier 2 only
- ❌ No raw source table references — Wide Layer only
- ❌ No system IDs exposed (unless the output goes to a tool that joins back to the source system)
- ❌ No `SELECT *`
- ❌ No business logic disguised as a "simple filter" — if you're computing a new value, it's a
  metric and belongs in Tier 2

### What the View Layer CAN do (the Consumer Contract)
The View Layer is the only layer that decides *what a consumer sees*. That latitude is what the
other layers are forbidden from doing — so it's bounded, not free:

- **Join multiple wide tables — as long as there's a join key.** A view may combine
  `CustomerWide` + `PolicyWide` + `ClaimWide`, provided the relationship was declared as a link
  STRUCT at the Raw Layer and carried through the Wide Layer. The join key is the shared ID (or a
  natural key if the view feeds a system-join back to the source). What a view may NOT do is
  *invent* a relationship that doesn't exist — if you're reaching for a join the Wide Layer didn't
  expose, the relationship belongs in the Raw Layer first, not here.
- **Rename and reshape to match the business.** The View Layer is where `ID` becomes `CustomerID`
  and `Policy:PolicyStateCode` becomes the label business users actually read. Aliasing, field
  selection, and STRUCT flattening are the point of this layer.
- **Filter to a segment.** `WHERE` clauses scoping to a business segment belong here — this is the
  delivery layer, and "which rows does this consumer get" is a delivery decision.
- **Pre-aggregate a reporting grain.** A view may present a period-aggregated or UNION+dedup shape
  if that's what the consumer needs — the underlying measures still come from the Metric Layer.

The view transforms *presentation*, never *meaning*. Anything that changes what a metric *means*
is a metric, and stays in Tier 2.

### View Layer patterns (choose explicitly):
1. **Flat SELECT** — no join needed, just column selection from one wide table
2. **UNION + dedup GROUP BY** — merge entity data from multiple sources with explicit deduplication
3. **Period aggregation** — pre-aggregated grain for reporting

"Just join and hope for the best" is not one of the patterns.

---

## 6. CROSS-CUTTING RULES (ALL TIERS)

### SQL formatting (see the domain's SQL standards file for full detail):
- PascalCase for all aliases
- Commas BEFORE fields (leading-comma style)
- Every field prefixed with its table alias
- CTEs instead of subqueries in JOIN/WHERE
- Every Raw Layer file opens with a doctrine header comment (grain, ID formula, doctrine notes)
- `UPPER()` or `LOWER()` for all text comparisons

### "This is just formatting, why does it matter?" — it isn't just formatting

Every rule above looks cosmetic until you've been the one debugging what it prevents. Same
principle as Python forcing indentation to be syntactically load-bearing: force the visible shape
of code to match its actual behavior, and a whole category of bugs can't hide in the gap between
what a line *looks like* it does and what it *actually* does.

| "Small" rule | Software engineering principle | Silent assumption it closes |
|---|---|---|
| One enforced formatter, no personal style | WYSIWYG — visual shape must match real structure | "Everyone will parse my formatting as easily as I did" |
| `SELECT *` banned, explicit columns always | Explicit interfaces over implicit ones | "The schema I'm reading today is the schema I'll read tomorrow" |
| `SAFE_CAST`, never bare `CAST` | Defensive programming at the boundary | "The data will always be clean enough for this cast to succeed" |
| `ID` all-caps + PascalCase aliases, simultaneously | Naming conventions as type signals | "Anyone can tell the entity key from a computed value just by looking" |
| Leading commas, not trailing | Minimal diff surface + safe line-by-line commenting | "A 2-line diff means 2 things actually changed" / "Commenting out any one line is safe" |
| `INNER JOIN` only in Metric Layer, never `LEFT JOIN` | Fail loud, not quiet | "A NULL and a missing row mean the same thing" |
| Doctrine header on every Raw Layer file (grain, ID formula, rules) | Contracts declared, not discovered | "Anyone can infer the grain and identity rule just by reading the SELECT" |

If an analyst pushes back on one of these as "just bureaucracy," it's common and expected. Because MESA 
applies engineering standards to data every rule there is tied to a bug it
has actually prevented, not a style preference.

### The `SELECT *` ban — why it's structural, not stylistic:
`SELECT *` is banned in every tier because it silently absorbs schema changes. When a source
table adds a column, `SELECT *` picks it up with no warning — and downstream consumers break
in ways that are hard to trace. Explicit column lists mean schema changes are visible in diffs,
reviewable in PRs, and fail CI if they break contracts. This is not a preference. It's a
governance requirement.

### Hashed IDs — the construction rule:
```sql
-- BigQuery
TO_BASE64(SHA256(CONCAT(source_system, '-', source_id))) AS ID

-- Snowflake
BASE64_ENCODE(SHA2(CONCAT(source_system, '-', source_id), 256)) AS ID
```
The `source_system` prefix is mandatory. Without it, source-system-1 ID 123 and source-system-2
ID 123 produce the same hash — a collision that silently merges two different entities.

### STRUCT patterns (Snowflake):
- Always `OBJECT_CONSTRUCT_KEEP_NULL` — never plain `OBJECT_CONSTRUCT` (drops NULL keys, breaks
  typed casts)
- Cast at the outermost level: `OBJECT_CONSTRUCT_KEEP_NULL(...)::OBJECT(ID VARCHAR, Name VARCHAR)`
- System IDs: flat typed OBJECT, one key per source system, named `<System><Table><Field>`

### Doctrine header comments:
Every Raw Layer file opens with a doctrine header instead of a dependency-import block —
there is no `Semantic_Shared`/`Calc_Shared` schema in this architecture (that naming is a legacy
AO convention and does not apply here). The header states the grain, the ID construction formula,
and any doctrine notes specific to that entity:
```sql
-- RAW ENTITY: Survey
-- Grain: one row per survey campaign/invite wave
-- ID: hashed primary key — BASE64_ENCODE(SHA2(SurveyType || '|' || InviteWave, 256))
-- Doctrine: campaign grain is FIRST-CLASS. Individual responses are nested
--           as a typed ARRAY of OBJECTs — consumers FLATTEN when they need
--           response grain. System IDs in typed OBJECTs, never bare.
--           THIS ENTITY IS THE CONTRACT for all survey data.
```
This makes the grain and identity rule readable in five lines, without having to reverse-engineer
them from the `SELECT`. A reviewer checks the header before checking the query.

---

## 7. WHAT TO NEVER DO (INSTANT REJECTION)

These are hard stops. If you see any of these in a PR, reject it immediately — they're not style
issues, they're architecture violations:

1. **`SELECT *` in any tier** — breaks schema contracts, hides changes, fails governance
2. **Business logic in the Wide Layer** — creates hidden, unauditable metric paths
3. **Raw source references in Metric or View Layers** — bypasses the Raw Layer contract
4. **More than 2 columns in a Metric file** — breaks the one-file-one-metric contract
5. **INNER JOIN in the Metric Layer** — use LEFT JOIN with an explicit `COALESCE`/documented
   NULL fill (never a silent NULL). INNER JOIN is the Wide Layer's job (Sec. 4).
6. **Bare `CAST` instead of `SAFE_CAST`** — kills queries on bad data instead of returning NULL
7. **System IDs as top-level columns** — they live in system-specific STRUCTs only
8. **Cross-entity joins at the Raw Layer** — relationships are declared via link STRUCTs, not
   by joining two Raw Layer tables together
9. **Metric logic in the View Layer** — if you're computing a value, it's a metric; put it in Tier 2 
    
    (UNION+dedup reshaping is allowed in Tier 4. Period re-aggregation is allowed only for additive metrics — sums, counts, min/max. Ratios, averages, and distinct counts must stay at their Metric Layer grain or get a new metric file at the target grain. If you find yourself writing AVG() over an existing average, stop — that's a new metric, not a view.)
10. **Hand-editing Wide Layer files** — they're auto-generated; manual edits will be overwritten

---

## 8. ONBOARDING A NEW DOMAIN 

When a new domain is added, do NOT modify this file. Instead:

1. Scaffold `domains/<NewDomain>/` with the four-layer `models/` structure
   (`raw_layer / metric_layer / wide_layer / view_layer`).
2. Put domain-specific rules in that domain: source-system names, natural keys, grain decisions,
   BI-tool wiring, and a SQL-standards reference file if the domain has one.
3. Add a `/domains/<NewDomain>/  @owner` entry to `CODEOWNERS`.
4. Reference this file from the domain so the AI agent picks up both — the universal contract
   (here) and the domain specifics (in the domain).

The four-tier contract above does not change per domain. What changes is the source map, the
naming of business concepts, and the list of systems feeding the Raw Layer — all of which live
in the domain's folder, not in this universal instruction file.