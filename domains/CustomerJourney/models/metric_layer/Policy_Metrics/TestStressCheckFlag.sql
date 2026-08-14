{{ config(tags=['metric_policy']) }}

-- METRIC: TestStressCheckFlag
-- Deliberately messy test file for the full-gate stress test.
-- Owner: Retention Analytics
-- Contract: 1 row per policy ID = 1:1

SELECT
    Policy.*
    , CASE
        WHEN Policy.Policy:cancellationdate IS null THEN 1
        ELSE 0
    END AS TestStressCheckFlag
FROM {{ ref('PolicyRaw') }} AS Policy
