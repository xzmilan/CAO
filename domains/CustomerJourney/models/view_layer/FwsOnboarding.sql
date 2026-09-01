-- CAO Governed Definition (Snowflake)
-- FwsOnboarding
-- Format: keyword/function UPPER | PascalCase aliases | ID all-caps | explicit AS
-- VIEW: FwsOnboarding
-- NB cohort, FWS business entity, by inception month
-- Pattern: period aggregation (sanctioned scorecard view) — grain-shaping
-- aggregation over metric-supplied atoms only. GROUP BY ALL, no positionals.

SELECT
    Policy.LoadMonth:LoadMonth AS LoadMonth
    , Policy.Policy:BusinessEntity AS BusinessEntity
    , Policy.InceptionMonth:InceptionMonth AS InceptionMonth
    , COUNT(*) AS NumberOfNewBusinessPolicies
FROM {{ ref('PolicyWide') }} AS Policy
WHERE
    Policy.TermType:TermType = 'NB'
    AND Policy.Policy:BusinessEntity = 'FWS'
GROUP BY ALL
ORDER BY InceptionMonth
