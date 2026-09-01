-- CAO Governed Definition (Snowflake)
-- FarmersOnboardingCA
-- Format: keyword/function UPPER | PascalCase aliases | ID all-caps | explicit AS
-- VIEW: FarmersOnboardingCA (CONTRACT ITEM 4c / Farmers Auto Onboarding CA — Joe Spinelli)
-- NB cohort, Farmers business entity, California state, Auto LOB, by inception month
-- Pattern: period aggregation (sanctioned scorecard view) — aggregates only
-- metric-supplied atoms (InForce90Flag). GROUP BY ALL, no positionals.

SELECT
    Policy.LoadMonth:LoadMonth AS LoadMonth
    , Policy.Policy:BusinessEntity AS BusinessEntity
    , Policy.Policy:LineOfBusinessCode AS LineOfBusinessCode
    , Policy.Policy:PolicyStateCode AS PolicyStateCode
    , Policy.InceptionMonth:InceptionMonth AS InceptionMonth
    , COUNT(*) AS NumberOfNewBusinessPolicies
    , SUM(CASE WHEN Policy.InForce90Flag:InForce90Flag = 1 THEN 1 ELSE 0 END) AS NumberInForce90Days
    , DIV0(
        SUM(CASE WHEN Policy.InForce90Flag:InForce90Flag = 1 THEN 1 ELSE 0 END),
        COUNT(*)
    ) AS RetentionRatio90Days
FROM {{ ref('PolicyWide') }} AS Policy
WHERE
    Policy.TermType:TermType = 'NB'
    AND Policy.Policy:BusinessEntity = 'FARMERS'
    AND Policy.Policy:PolicyStateCode = 'CA'
    AND Policy.Policy:LineOfBusinessCode = 'AUTO'
GROUP BY ALL
ORDER BY InceptionMonth
