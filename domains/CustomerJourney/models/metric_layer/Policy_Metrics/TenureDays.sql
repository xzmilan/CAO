{{ config(tags=['metric_policy']) }}

-- METRIC: TenureDays
-- Days since policy inception, as of today.
-- Owner: Retention Analytics
-- Contract: 1 row per policy ID = 1:1

SELECT
    Policy.ID
    , DATEDIFF('day', Policy.PolicyInceptionDate, CURRENT_DATE()) AS TenureDays
FROM {{ ref('PolicyRaw') }} AS Policy
