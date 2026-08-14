-- CAO Governed Definition (Snowflake)
-- TestMessyCiCheckView
-- Format: keyword/function UPPER | PascalCase aliases | ID all-caps | explicit AS
-- VIEW: TestMessyCiCheckView
-- TEST VIEW ONLY — deliberately messy formatting + a wider field list,
-- to exercise the auto-fix (Job 0) and lint gate (Job 2) CI jobs against
-- the trial Snowflake account. Safe to delete after the test PR closes.
-- Pure SELECT from PolicyWide — no aggregation, no derivation logic.

SELECT
    policy.Policy:SystemIds:RtenPlcyCntrctNum AS PolicyNumber
    , policy.Policy:BusinessEntity AS BusinessEntity
    , policy.Policy:LineOfBusinessCode AS LineOfBusinessCode
    , policy.Policy:PolicyStateCode AS PolicyStateCode
    , policy.Policy:SourceSystemCode AS SourceSystemCode
    , cast(policy.TenureDays:TenureDays AS NUMBER) AS TenureDays
    , policy.TermType:TermType AS TermType
    , policy.InceptionMonth:InceptionMonth AS InceptionMonth
    , policy.NumberOfPoliciesInForce:NumberOfPoliciesInForce AS numberofpoliciesinforce
    , policy.NumberOfZipChangeEvents:NumberOfZipChangeEvents AS NumberOfZipChangeEvents
    , policy.NumberOfAgentChangeEvents:NumberOfAgentChangeEvents AS NumberOfAgentChangeEvents
    , policy.TestMessyCiCheckFlag:TestMessyCiCheckFlag AS TestMessyCiCheckFlag
FROM {{ ref('PolicyWide') }} AS policy
WHERE policy.NumberOfPoliciesInForce:NumberOfPoliciesInForce > 0
