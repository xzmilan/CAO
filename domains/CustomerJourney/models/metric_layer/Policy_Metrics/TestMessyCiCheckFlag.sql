{{ config(tags=['metric_policy']) }}

-- METRIC: TestMessyCiCheckFlag
-- TEST METRIC ONLY — deliberately messy formatting to exercise the
-- auto-fix (Job 0) and auto-assembly (Job 1) CI jobs against the trial
-- Snowflake account. Safe to delete after the test PR closes.
-- Contract: 1 row per policy ID = 1:1.

SELECT
    policy.id
    , CASE WHEN policy.policy:BusinessEntity = 'FARMERS' THEN 1 ELSE 0 END AS TestMessyCiCheckFlag
FROM {{ ref('PolicyRaw') }} AS policy
