{{ config(tags=['metric_policy']) }}

-- METRIC: AgentChangeDaysWithoutAgent
-- Average days without an agent during the transition, rolled to policy grain (1:1).
-- NULL for policies with no agent change survey response.
-- Source: SurveyRaw (AGENT_CHANGE survey type)
-- Contract: 1 row per policy ID = 1:1.

WITH AgentChangeSurveys AS (
    SELECT
        SurveyResponse.value:SystemIds.PolicyNumber::VARCHAR AS PolicyNumber
        , AVG(SurveyResponse.value:AgentChangeDetails.DaysWithoutAgent::NUMBER) AS AvgDaysWithoutAgent
    FROM {{ ref('SurveyRaw') }} AS Survey
    CROSS JOIN LATERAL FLATTEN(INPUT => Survey.Survey:Responses) AS SurveyResponse
    WHERE Survey.Survey:SurveyType = 'AGENT_CHANGE'
    GROUP BY SurveyResponse.value:SystemIds.PolicyNumber::VARCHAR
)

SELECT
    Policy.ID
    , AgentChangeSurveys.AvgDaysWithoutAgent AS AgentChangeDaysWithoutAgent
FROM {{ ref('PolicyRaw') }} AS Policy
LEFT JOIN AgentChangeSurveys
    ON Policy.Policy:SystemIds.RtenPlcyCntrctNum = AgentChangeSurveys.PolicyNumber
