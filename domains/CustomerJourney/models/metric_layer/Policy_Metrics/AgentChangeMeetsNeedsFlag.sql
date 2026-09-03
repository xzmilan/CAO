{{ config(tags=['metric_policy']) }}

-- METRIC: AgentChangeMeetsNeedsFlag
-- 1 if the new agent meets the customer's needs (from agent change survey),
-- 0 if not. NULL for policies with no agent change survey response.
-- Source: SurveyRaw (AGENT_CHANGE survey type)
-- Contract: 1 row per policy ID = 1:1.

WITH AgentChangeSurveys AS (
    SELECT
        value:SystemIds.PolicyNumber::VARCHAR AS PolicyNumber
        , MAX(
            CASE
                WHEN UPPER(value:AgentChangeDetails.MeetsNeedsFlag::VARCHAR) = '1' THEN 1
                WHEN UPPER(value:AgentChangeDetails.MeetsNeedsFlag::VARCHAR) = '2' THEN 0
                ELSE NULL
            END
        ) AS MeetsNeedsFlag
        , COUNT(value) AS SurveyResponseCount
    FROM {{ ref('SurveyRaw') }} AS Survey
    CROSS JOIN LATERAL FLATTEN(INPUT => Survey.Responses)
    WHERE Survey.SurveyType = 'AGENT_CHANGE'
    GROUP BY value:SystemIds.PolicyNumber::VARCHAR
)

SELECT
    Policy.ID
    , AgentChangeSurveys.MeetsNeedsFlag AS AgentChangeMeetsNeedsFlag
FROM {{ ref('PolicyRaw') }} AS Policy
LEFT JOIN AgentChangeSurveys
    ON Policy.SystemIds:RtenPlcyCntrctNum = AgentChangeSurveys.PolicyNumber
