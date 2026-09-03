{{ config(tags=['metric_policy']) }}

-- METRIC: AgentChangeDaysWithoutAgent
-- Average days without an agent during the transition, rolled to policy grain (1:1).
-- NULL for policies with no agent change survey response.
-- Source: SurveyRaw (AGENT_CHANGE survey type)
-- Contract: 1 row per policy ID = 1:1.

WITH AgentChangeSurveys AS (
    SELECT
        value:SystemIds.PolicyNumber::VARCHAR AS PolicyNumber
        , AVG(value:AgentChangeDetails.DaysWithoutAgent::NUMBER) AS AvgDaysWithoutAgent
        , COUNT(value) AS SurveyResponseCount
    FROM {{ ref('SurveyRaw') }} AS Survey
    CROSS JOIN LATERAL FLATTEN(INPUT => Survey.Responses)
    WHERE Survey.SurveyType = 'AGENT_CHANGE'
    GROUP BY value:SystemIds.PolicyNumber::VARCHAR
)

SELECT
    Policy.ID
    , AgentChangeSurveys.AvgDaysWithoutAgent AS AgentChangeDaysWithoutAgent
FROM {{ ref('PolicyRaw') }} AS Policy
LEFT JOIN AgentChangeSurveys
    ON Policy.SystemIds:RtenPlcyCntrctNum = AgentChangeSurveys.PolicyNumber
