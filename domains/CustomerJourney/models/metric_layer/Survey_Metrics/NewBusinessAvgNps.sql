{{ config(tags=['metric_survey']) }}

-- METRIC: NewBusinessAvgNps
-- Average NPS score across all new-business onboarding survey responses.
-- Campaign grain (1:1 with SurveyRaw NEW_BUSINESS wave).
-- Contract: 1 row per campaign wave ID = 1:1.

SELECT
    Survey.ID
    , (
        SELECT AVG(TRY_CAST(Response.value:NpsScore AS NUMBER))
        FROM TABLE(FLATTEN(INPUT => Survey.Survey:Responses)) AS Response
        WHERE Response.value:NpsScore IS NOT NULL
    ) AS NewBusinessAvgNps
FROM {{ ref('SurveyRaw') }} AS Survey
WHERE Survey.Survey:SurveyType = 'NEW_BUSINESS'
