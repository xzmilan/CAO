{{ config(tags=['metric_survey']) }}

-- METRIC: NewBusinessAvgNps
-- Average NPS score across all new-business onboarding survey responses.
-- Campaign grain (1:1 with SurveyRaw NEW_BUSINESS wave).
-- Contract: 1 row per campaign wave ID = 1:1.

SELECT
    Survey.ID
    , AVG(TRY_CAST(Response.value:NpsScore::VARCHAR AS NUMBER)) AS NewBusinessAvgNps
FROM {{ ref('SurveyRaw') }} AS Survey
CROSS JOIN LATERAL FLATTEN(INPUT => Survey.Responses) AS Response
WHERE
    Survey.SurveyType = 'NEW_BUSINESS'
    AND Response.value:NpsScore IS NOT NULL
GROUP BY Survey.ID
