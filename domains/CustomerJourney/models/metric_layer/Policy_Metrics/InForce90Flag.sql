{{ config(tags=['metric_policy']) }}

-- METRIC: InForce90Flag
-- 1 if policy survived > 90 days from inception. 0 if cancelled within 90 days.
-- Owner: Retention Analytics
-- Contract: 1 row per policy ID = 1:1

SELECT
    Policy.ID
    , CASE
        WHEN
            Policy.CancellationDate IS NULL
            OR DATEDIFF('day', Policy.PolicyInceptionDate, Policy.CancellationDate) > 90
            THEN 1
        ELSE 0
    END AS InForce90Flag
FROM {{ ref('PolicyRaw') }} AS Policy
