{{ config(tags=['metric_policy']) }}

-- METRIC: AgentChangeReceivedLetterFlag
-- 1 if the customer received a Farmers letter about the agent change,
-- 0 if not. NULL for policies with no agent change survey response.
-- Source: SurveyRaw (AGENT_CHANGE survey type)
-- Contract: 1 row per policy ID = 1:1.

WITH AgentChangeSurveys AS (
    SELECT
        SurveyResponse.value:SystemIds.PolicyNumber::VARCHAR AS PolicyNumber
        , MAX(
            CASE
                WHEN UPPER(SurveyResponse.value:AgentChangeDetails.ReceivedLetterFlag::VARCHAR) = 'Y' THEN 1
                WHEN UPPER(SurveyResponse.value:AgentChangeDetails.ReceivedLetterFlag::VARCHAR) = 'N' THEN 0
                ELSE NULL
            END
        ) AS ReceivedLetterFlag
    FROM {{ ref('SurveyRaw') }} AS Survey
    CROSS JOIN LATERAL FLATTEN(INPUT => Survey.Survey:Responses) AS SurveyResponse
    WHERE Survey.Survey:SurveyType = 'AGENT_CHANGE'
    GROUP BY SurveyResponse.value:SystemIds.PolicyNumber::VARCHAR
)

SELECT
    Policy.ID
    , AgentChangeSurveys.ReceivedLetterFlag AS AgentChangeReceivedLetterFlag
FROM {{ ref('PolicyRaw') }} AS Policy
LEFT JOIN AgentChangeSurveys
    ON Policy.Policy:SystemIds.RtenPlcyCntrctNum = AgentChangeSurveys.PolicyNumber
