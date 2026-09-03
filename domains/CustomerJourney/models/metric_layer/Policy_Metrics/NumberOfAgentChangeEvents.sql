{{ config(tags=['metric_policy']) }}

-- METRIC: NumberOfAgentChangeEvents
-- Count of agent-of-record change events per policy, rolled to policy grain (1:1)
-- Contract: 1 row per policy ID = 1:1 — every policy emits a row, zero-filled.
-- Pattern: SUM the event-grain IsAgentChangeEvent flag — no re-filtering, no WHERE.

WITH AgentChangeCounts AS (
    SELECT
        ChangeEvent.PolicyID
        , SUM(IsAgentChangeEvent.IsAgentChangeEvent) AS NumberOfAgentChangeEvents
    FROM {{ ref('ChangeEventRaw') }} AS ChangeEvent
    JOIN {{ ref('IsAgentChangeEvent') }} AS IsAgentChangeEvent
        ON ChangeEvent.ID = IsAgentChangeEvent.ID
    GROUP BY ChangeEvent.PolicyID
)

SELECT
    Policy.ID
    , COALESCE(AgentChangeCounts.NumberOfAgentChangeEvents, 0)
        AS NumberOfAgentChangeEvents
FROM {{ ref('PolicyRaw') }} AS Policy
LEFT JOIN AgentChangeCounts
    ON Policy.ID = AgentChangeCounts.PolicyID
