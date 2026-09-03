{{ config(tags=['metric_policy']) }}

-- METRIC: RnpsScore
-- Average relationship NPS score, rolled to policy grain (1:1).
-- NULL for policies with no RNPS survey response.
-- Source: SurveyRaw (RNPS survey type)
-- Contract: 1 row per policy ID = 1:1.

WITH RnpsSurveys AS (
    SELECT
        SurveyResponse.value:SystemIds.PolicyNumber::VARCHAR AS PolicyNumber
        , AVG(SurveyResponse.value:NpsScore::NUMBER) AS AvgNpsScore
        , COUNT(*) AS SurveyResponseCount
    FROM {{ ref('SurveyRaw') }} AS Survey
    CROSS JOIN LATERAL FLATTEN(INPUT => Survey.Responses) AS SurveyResponse
    WHERE Survey.SurveyType = 'RNPS'
    GROUP BY SurveyResponse.value:SystemIds.PolicyNumber::VARCHAR
)

SELECT
    Policy.ID
    , RnpsSurveys.AvgNpsScore AS RnpsScore
FROM {{ ref('PolicyRaw') }} AS Policy
LEFT JOIN RnpsSurveys
    ON Policy.SystemIds:RtenPlcyCntrctNum = RnpsSurveys.PolicyNumber
