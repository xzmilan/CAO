{{ config(tags=['metric_policy']) }}

-- METRIC: CssCesScore
-- Average CES score from CSS (Customer Self-Service) surveys, rolled to policy grain (1:1).
-- NULL for policies with no CSS CES survey response.
-- Source: SurveyRaw (CSS_CES survey type)
-- Contract: 1 row per policy ID = 1:1.

WITH CssCesSurveys AS (
    SELECT
        SurveyResponse.value:SystemIds.PolicyNumber::VARCHAR AS PolicyNumber
        , AVG(SurveyResponse.value:NpsScore::NUMBER) AS AvgNpsScore
        , COUNT(*) AS SurveyResponseCount
    FROM {{ ref('SurveyRaw') }} AS Survey
    CROSS JOIN LATERAL FLATTEN(INPUT => Survey.Survey:Responses) AS SurveyResponse
    WHERE Survey.Survey:SurveyType = 'CSS_CES'
    GROUP BY SurveyResponse.value:SystemIds.PolicyNumber::VARCHAR
)

SELECT
    Policy.ID
    , CssCesSurveys.AvgNpsScore AS CssCesScore
FROM {{ ref('PolicyRaw') }} AS Policy
LEFT JOIN CssCesSurveys
    ON Policy.Policy:SystemIds.RtenPlcyCntrctNum = CssCesSurveys.PolicyNumber
