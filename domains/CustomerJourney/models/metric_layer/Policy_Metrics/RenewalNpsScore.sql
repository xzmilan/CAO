{{ config(tags=['metric_policy']) }}

-- METRIC: RenewalNpsScore
-- Average NPS score from renewal surveys, rolled to policy grain (1:1).
-- NULL for policies with no renewal survey response.
-- Source: SurveyRaw (RENEWAL survey type)
-- Contract: 1 row per policy ID = 1:1.

WITH RenewalSurveys AS (
    SELECT
        SurveyResponse.value:SystemIds.PolicyNumber::VARCHAR AS PolicyNumber
        , AVG(SurveyResponse.value:NpsScore::NUMBER) AS AvgNpsScore
        , COUNT(*) AS SurveyResponseCount
    FROM {{ ref('SurveyRaw') }} AS Survey
    CROSS JOIN LATERAL FLATTEN(INPUT => Survey.Survey:Responses) AS SurveyResponse
    WHERE Survey.Survey:SurveyType = 'RENEWAL'
    GROUP BY SurveyResponse.value:SystemIds.PolicyNumber::VARCHAR
)

SELECT
    Policy.ID
    , RenewalSurveys.AvgNpsScore AS RenewalNpsScore
FROM {{ ref('PolicyRaw') }} AS Policy
LEFT JOIN RenewalSurveys
    ON Policy.Policy:SystemIds.RtenPlcyCntrctNum = RenewalSurveys.PolicyNumber
