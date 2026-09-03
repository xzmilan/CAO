{{ config(tags=['metric_policy']) }}

-- METRIC: AgentChangeRetentionRate90Days
-- Share of a policy's agent-change events after which the policy stayed in
-- force 90 days, rolled to policy grain (1:1). NULL for policies with no
-- agent changes.
-- Contract: 1 row per policy ID = 1:1.
-- Pattern: AVG of InForce90DaysAfterChangeFlag over agent-change events only
--          (filter inside the aggregate — no WHERE in main SELECT).

WITH AgentChangeRetention AS (
    SELECT
        ChangeEvent.PolicyID
        , AVG(
            IsAgentChangeEvent.IsAgentChangeEvent
            * InForce90DaysAfterChangeFlag.InForce90DaysAfterChangeFlag)
            AS AgentChangeRetentionRate90Days
    FROM {{ ref('ChangeEventRaw') }} AS ChangeEvent
    JOIN {{ ref('IsAgentChangeEvent') }} AS IsAgentChangeEvent
        ON ChangeEvent.ID = IsAgentChangeEvent.ID
    JOIN {{ ref('InForce90DaysAfterChangeFlag') }} AS InForce90DaysAfterChangeFlag
        ON ChangeEvent.ID = InForce90DaysAfterChangeFlag.ID
    WHERE IsAgentChangeEvent.IsAgentChangeEvent = 1
    GROUP BY ChangeEvent.PolicyID
)

SELECT
    Policy.ID
    , AgentChangeRetention.AgentChangeRetentionRate90Days
FROM {{ ref('PolicyRaw') }} AS Policy
LEFT JOIN AgentChangeRetention
    ON Policy.ID = AgentChangeRetention.PolicyID
