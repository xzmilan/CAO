{{ config(tags=['metric_policy']) }}

-- METRIC: InceptionMonth
-- Cohort grain — YYYY-MM of policy inception
-- Owner: Retention Analytics
-- Contract: 1 row per policy ID = 1:1

SELECT
    Policy.ID
    , TO_CHAR(Policy.Policy:PolicyInceptionDate, 'YYYY-MM') AS InceptionMonth
FROM {{ ref('PolicyRaw') }} AS Policy
