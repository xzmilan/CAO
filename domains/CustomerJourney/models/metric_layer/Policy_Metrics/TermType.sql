{{ config(tags=['metric_policy']) }}

-- METRIC: TermType
-- NB = New Business (PriorPolicyIndicator IS NULL)
-- RB = Renewal Business (PriorPolicyIndicator IS NOT NULL)
-- Owner: Retention Analytics
-- Contract: 1 row per policy ID = 1:1

SELECT
    Policy.ID
    , CASE
        WHEN Policy.PriorPolicyIndicator IS NULL THEN 'NB'
        ELSE 'RB'
    END AS TermType
FROM {{ ref('PolicyRaw') }} AS Policy
