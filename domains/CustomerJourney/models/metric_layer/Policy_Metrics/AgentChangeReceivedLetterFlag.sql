{{ config(tags=['metric_policy']) }}

-- METRIC: AgentChangeReceivedLetterFlag
-- 1 if the customer received a Farmers letter about the agent change,
-- 0 if not. NULL for policies with no agent change survey response.
-- Source: SurveyRaw (AGENT_CHANGE survey type)
-- Contract: 1 row per policy ID = 1:1.

WITH AgentChangeSurveys AS (
    SELECT
        value:SystemIds.PolicyNumber::VARCHAR AS PolicyNumber
        -- Note: RCVD_FARMERS_LETTER stores '1'/'2'/'3', not 'Y'/'N'.
        -- Assumed '1' = received, '2'/'3' = did not. CONFIRM Qualtrics codebook.
        , MAX(
            CASE
                WHEN UPPER(value:AgentChangeDetails.ReceivedLetterFlag::VARCHAR) = '1' THEN 1
                WHEN UPPER(value:AgentChangeDetails.ReceivedLetterFlag::VARCHAR) IN ('2', '3') THEN 0
                ELSE NULL
            END
        ) AS ReceivedLetterFlag
        , COUNT(value) AS SurveyResponseCount
    FROM {{ ref('SurveyRaw') }} AS Survey
    CROSS JOIN LATERAL FLATTEN(INPUT => Survey.Responses)
    WHERE Survey.SurveyType = 'AGENT_CHANGE'
    GROUP BY value:SystemIds.PolicyNumber::VARCHAR
)

SELECT
    Policy.ID
    , AgentChangeSurveys.ReceivedLetterFlag AS AgentChangeReceivedLetterFlag
FROM {{ ref('PolicyRaw') }} AS Policy
LEFT JOIN AgentChangeSurveys
    ON Policy.SystemIds:RtenPlcyCntrctNum = AgentChangeSurveys.PolicyNumber
