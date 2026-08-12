{{ config(tags=['metric_policy']) }}

-- METRIC: OnboardingNpsScore
-- Average NPS score from new business onboarding surveys, rolled to policy grain (1:1).
-- NULL for policies with no onboarding survey response.
-- Source: SurveyRaw (NEW_BUSINESS survey type)
-- Contract: 1 row per policy ID = 1:1.

WITH OnboardingSurveys AS (
    SELECT
        SurveyResponse.value:SystemIds.PolicyNumber::VARCHAR AS PolicyNumber
        , AVG(SurveyResponse.value:NpsScore::NUMBER) AS AvgNpsScore
        , COUNT(*) AS SurveyResponseCount
    FROM {{ ref('SurveyRaw') }} AS Survey
    CROSS JOIN LATERAL FLATTEN(INPUT => Survey.Survey:Responses) AS SurveyResponse
    WHERE Survey.Survey:SurveyType = 'NEW_BUSINESS'
    GROUP BY SurveyResponse.value:SystemIds.PolicyNumber::VARCHAR
)

SELECT
    Policy.ID
    , OnboardingSurveys.AvgNpsScore AS OnboardingNpsScore
FROM {{ ref('PolicyRaw') }} AS Policy
LEFT JOIN OnboardingSurveys
    ON Policy.Policy:SystemIds.RtenPlcyCntrctNum = OnboardingSurveys.PolicyNumber
