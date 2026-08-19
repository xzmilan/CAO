{{ config(tags=['metric_policy']) }}

-- METRIC: NumberOfPoliciesInForce
-- Count of policies still in force (not cancelled within 90 days of inception)
-- across all monthly snapshots, rolled to policy grain (1:1)
-- Contract: 1 row per policy ID = 1:1

SELECT
    Policy.ID
    , SUM(CASE
        WHEN
            PolicyMonthly.value:"CancellationDate"::DATE IS NULL
            OR DATEDIFF('day', PolicyMonthly.value:"InceptionDate"::DATE, PolicyMonthly.value:"CancellationDate"::DATE) > 90
            THEN 1
        ELSE 0
    END) AS NumberOfPoliciesInForce
FROM {{ ref('PolicyRaw') }} AS Policy
CROSS JOIN LATERAL FLATTEN(INPUT => Policy.Policy:MonthlySnapshots) AS PolicyMonthly
GROUP BY Policy.ID
