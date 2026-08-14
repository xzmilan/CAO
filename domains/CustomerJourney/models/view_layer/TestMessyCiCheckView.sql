-- CAO Governed Definition (Snowflake)
-- TestMessyCiCheckView
-- Format: keyword/function UPPER | PascalCase aliases | ID all-caps | explicit AS
-- VIEW: TestMessyCiCheckView
-- TEST VIEW ONLY — deliberately messy formatting + a wider field list,
-- to exercise the auto-fix (Job 0) and lint gate (Job 2) CI jobs against
-- the trial Snowflake account. Safe to delete after the test PR closes.
-- Pure SELECT from PolicyWide — no aggregation, no derivation logic.

SELECT
    Policy.Policy:SystemIds:RtenPlcyCntrctNum AS PolicyNumber
    , Policy.Policy:BusinessEntity AS BusinessEntity
    , Policy.Policy:LineOfBusinessCode AS LineOfBusinessCode
    , Policy.Policy:PolicyStateCode AS PolicyStateCode
    , Policy.Policy:SourceSystemCode AS SourceSystemCode
    , CAST(Policy.TenureDays:TenureDays AS NUMBER) AS TenureDays
    , Policy.TermType:TermType AS TermType
    , Policy.InceptionMonth:InceptionMonth AS InceptionMonth
    , Policy.NumberOfPoliciesInForce:NumberOfPoliciesInForce AS NumberOfPoliciesInForce
    , Policy.NumberOfZipChangeEvents:NumberOfZipChangeEvents AS NumberOfZipChangeEvents
    , Policy.NumberOfAgentChangeEvents:NumberOfAgentChangeEvents AS NumberOfAgentChangeEvents
    , Policy.TestMessyCiCheckFlag:TestMessyCiCheckFlag AS TestMessyCiCheckFlag
FROM {{ ref('PolicyWide') }} AS Policy
WHERE Policy.NumberOfPoliciesInForce:NumberOfPoliciesInForce > 0
