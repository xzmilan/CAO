{{ config(tags=['metric_policy']) }}

-- METRIC: NumberOfAgentChangePoliciesInForce90Days
-- Count of agent-change events whose policy was still in force 90 days
-- post-change, rolled to policy grain (1:1)
-- Contract: 1 row per policy ID = 1:1 — every policy emits a row, zero-filled.
-- Pattern: SUM of event-grain flags (IsAgentChangeEvent × InForce90DaysAfterChangeFlag).

WITH AgentChangeInForce AS (
    SELECT
        ChangeEvent.PolicyID
        , SUM(
            IsAgentChangeEvent.IsAgentChangeEvent
            * InForce90DaysAfterChangeFlag.InForce90DaysAfterChangeFlag)
            AS NumberOfAgentChangePoliciesInForce90Days
    FROM {{ ref('ChangeEventRaw') }} AS ChangeEvent
    JOIN {{ ref('IsAgentChangeEvent') }} AS IsAgentChangeEvent
        ON ChangeEvent.ID = IsAgentChangeEvent.ID
    JOIN {{ ref('InForce90DaysAfterChangeFlag') }} AS InForce90DaysAfterChangeFlag
        ON ChangeEvent.ID = InForce90DaysAfterChangeFlag.ID
    GROUP BY ChangeEvent.PolicyID
)

SELECT
    Policy.ID
    , COALESCE(AgentChangeInForce.NumberOfAgentChangePoliciesInForce90Days, 0)
        AS NumberOfAgentChangePoliciesInForce90Days
FROM {{ ref('PolicyRaw') }} AS Policy
LEFT JOIN AgentChangeInForce
    ON Policy.ID = AgentChangeInForce.PolicyID
