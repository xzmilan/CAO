{{ config(tags=['metric_policy']) }}

-- METRIC: TestMessyCiCheckFlag
-- TEST METRIC ONLY — deliberately messy formatting to exercise the
-- auto-fix (Job 0) and auto-assembly (Job 1) CI jobs against the trial
-- Snowflake account. Safe to delete after the test PR closes.
-- Contract: 1 row per policy ID = 1:1.

select
      policy.id
    ,case when policy.policy:BusinessEntity = 'FARMERS' then 1 else 0 end as TestMessyCiCheckFlag
from {{ ref('PolicyRaw') }} as policy
