{{ config(tags=['metric_policy']) }}

-- METRIC: TestStressCheckFlag
-- Deliberately messy test file for the full-gate stress test.
-- Owner: Retention Analytics
-- Contract: 1 row per policy ID = 1:1

SELECT
    policy.*
    , CASE
        WHEN policy.Policy:cancellationdate IS null THEN 1
        ELSE 0
    END AS teststresscheckflag
FROM {{ ref('PolicyRaw') }} AS policy
