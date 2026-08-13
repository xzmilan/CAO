-- CAO Governed Definition (Snowflake)
-- ChangedAddress
-- Format: keyword/function UPPER | PascalCase aliases | ID all-caps | explicit AS
-- VIEW: ChangedAddress (CONTRACT ITEM 4d / Move Journey — Edgar Lattuada)
-- Pure SELECT from PolicyWide — all measures are pre-computed policy-grain metrics.
-- No aggregation, no derivation logic in the view layer.
-- JO sheet coverage: Policy Count (moved), 90-day Retention (count + rate).
-- Change-month/reporting-month series come from the F04 archive scorecard (T-3/T-4).
-- NOT covered here (source not yet in project): Contacts per 100 PIF (F06), rNPS/CES (F05).

SELECT
    Policy.Policy:SystemIds:RtenPlcyCntrctNum AS PolicyNumber
    , Policy.Policy:BusinessEntity AS BusinessEntity
    , Policy.Policy:LineOfBusinessCode AS LineOfBusinessCode
    , Policy.Policy:PolicyStateCode AS PolicyStateCode
    , Policy.Policy:SourceSystemCode AS SourceSystemCode
    , Policy.Policy:ZipCode AS ZipCode
    , Policy.NumberOfZipChangeEvents:NumberOfZipChangeEvents AS NumberOfZipChangeEvents
    , Policy.NumberOfMovedPoliciesInForce90Days:NumberOfMovedPoliciesInForce90Days AS NumberOfMovedPoliciesInForce90Days
    , Policy.MovedPolicyRetentionRate90Days:MovedPolicyRetentionRate90Days AS MovedPolicyRetentionRate90Days
FROM {{ ref('PolicyWide') }} AS Policy
WHERE Policy.NumberOfZipChangeEvents:NumberOfZipChangeEvents > 0
