-- VIEW: TestMessyCiCheckView
-- TEST VIEW ONLY — deliberately messy formatting + a wider field list,
-- to exercise the auto-fix (Job 0) and lint gate (Job 2) CI jobs against
-- the trial Snowflake account. Safe to delete after the test PR closes.
-- Pure SELECT from PolicyWide — no aggregation, no derivation logic.

select
    policy.Policy:SystemIds:RtenPlcyCntrctNum as PolicyNumber
    ,policy.Policy:BusinessEntity as BusinessEntity
    ,policy.Policy:LineOfBusinessCode as LineOfBusinessCode
    ,policy.Policy:PolicyStateCode as PolicyStateCode
    ,policy.Policy:SourceSystemCode as SourceSystemCode
    ,cast(policy.TenureDays:TenureDays as NUMBER) as TenureDays
    ,policy.TermType:TermType as TermType
    ,policy.InceptionMonth:InceptionMonth as InceptionMonth
    ,policy.NumberOfPoliciesInForce:NumberOfPoliciesInForce as numberofpoliciesinforce
    ,policy.NumberOfZipChangeEvents:NumberOfZipChangeEvents as NumberOfZipChangeEvents
    ,policy.NumberOfAgentChangeEvents:NumberOfAgentChangeEvents as NumberOfAgentChangeEvents
    ,policy.TestMessyCiCheckFlag:TestMessyCiCheckFlag as TestMessyCiCheckFlag
from {{ ref('PolicyWide') }} as policy
where policy.NumberOfPoliciesInForce:NumberOfPoliciesInForce > 0
