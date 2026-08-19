{{ config(tags=['metric_policy']) }}

-- METRIC: AgentChangeCsatScore
-- Average NPS score from agent change surveys, rolled to policy grain (1:1).
-- NULL for policies with no agent change survey response.
-- Source: SurveyRaw (AGENT_CHANGE survey type)
-- Contract: 1 row per policy ID = 1:1.

WITH AgentChangeSurveys AS (
    SELECT
        SurveyResponse.value:SystemIds.PolicyNumber::VARCHAR AS PolicyNumber
        , AVG(SurveyResponse.value:NpsScore::NUMBER) AS AvgNpsScore
        , COUNT(*) AS SurveyResponseCount
    FROM {{ ref('SurveyRaw') }} AS Survey
    CROSS JOIN LATERAL FLATTEN(INPUT => Survey.Survey:Responses) AS SurveyResponse
    WHERE Survey.Survey:SurveyType = 'AGENT_CHANGE'
    GROUP BY SurveyResponse.value:SystemIds.PolicyNumber::VARCHAR
)

SELECT
    Policy.ID
    , AgentChangeSurveys.AvgNpsScore AS AgentChangeCsatScore
FROM {{ ref('PolicyRaw') }} AS Policy
LEFT JOIN AgentChangeSurveys
    ON Policy.Policy:SystemIds.RtenPlcyCntrctNum = AgentChangeSurveys.PolicyNumber
