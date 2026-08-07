-- VIEW: ChangedProducer (CONTRACT ITEM 4e / Agency Change Journey — Jessica Campbell)
-- Pure SELECT from PolicyWide — all measures are pre-computed policy-grain metrics.
-- No aggregation, no derivation logic in the view layer.
-- JO sheet coverage: Policy Count (agent change), 90-day Retention (count + rate).
-- Change-month/reporting-month series come from the F04 archive scorecard (T-3/T-4).
-- NOT covered here (source not yet in project): Contacts per 100 PIF (F06),
-- CSAT / comms / policy-review survey measures (F05), reassignment cycle time.
-- TODO(journey): company-initiated vs customer-initiated split needs a discriminator
-- source (book-of-business transfer flag) — not available in rten_dim_pl_trn_xlob.

SELECT
    Policy.Policy:SystemIds:RtenPlcyCntrctNum AS PolicyNumber
    , Policy.Policy:BusinessEntity AS BusinessEntity
    , Policy.Policy:LineOfBusinessCode AS LineOfBusinessCode
    , Policy.Policy:PolicyStateCode AS PolicyStateCode
    , Policy.Policy:SourceSystemCode AS SourceSystemCode
    , Policy.Policy:AgentOfRecordNumber AS AgentOfRecordNumber
    , Policy.NumberOfAgentChangeEvents:NumberOfAgentChangeEvents AS NumberOfAgentChangeEvents
    , Policy.NumberOfAgentChangePoliciesInForce90Days:NumberOfAgentChangePoliciesInForce90Days AS NumberOfAgentChangePoliciesInForce90Days
    , Policy.AgentChangeRetentionRate90Days:AgentChangeRetentionRate90Days AS AgentChangeRetentionRate90Days
FROM {{ ref('PolicyWide') }} AS Policy
WHERE Policy.NumberOfAgentChangeEvents:NumberOfAgentChangeEvents > 0
