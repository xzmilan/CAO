-- CAO Governed Definition (Snowflake)
-- FarmersOnboarding
-- Format: keyword/function UPPER | PascalCase aliases | ID all-caps | explicit AS
-- VIEW: FarmersOnboarding
-- NB cohort, Farmers business entity, by inception month

SELECT
    'DEMO' AS LoadMonth
    , Policy.Policy:BusinessEntity AS BusinessEntity
    , Policy.InceptionMonth:InceptionMonth AS InceptionMonth
    , COUNT(*) AS NumberOfNewBusinessPolicies
FROM {{ ref('PolicyWide') }} AS Policy
WHERE
    Policy.TermType:TermType = 'NB'
    AND Policy.Policy:BusinessEntity = 'FARMERS'
GROUP BY 1, 2, 3
ORDER BY InceptionMonth
