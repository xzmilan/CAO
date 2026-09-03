{{ config(tags=['metric_policy']) }}

-- METRIC: LoadMonth
-- Latest archive load month (YYYYMM) per policy, promoted out of the
-- MonthlySnapshots ARRAY. Replaces the 'DEMO' literal in the F04 scorecard views.
-- Owner: Retention Analytics
-- Contract: 1 row per policy ID = 1:1

SELECT
    Policy.ID
    , MAX(PolicyMonthly.value:"LoadYearMonthNum")::VARCHAR AS LoadMonth
FROM {{ ref('PolicyRaw') }} AS Policy
CROSS JOIN LATERAL FLATTEN(INPUT => Policy.MonthlySnapshots) AS PolicyMonthly
GROUP BY Policy.ID
