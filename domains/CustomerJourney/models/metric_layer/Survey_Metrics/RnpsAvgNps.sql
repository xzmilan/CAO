{{ config(tags=['metric_survey']) }}

-- METRIC: RnpsAvgNps
-- Average NPS score across all relationship NPS survey responses.
-- Campaign grain (1:1 with SurveyRaw RNPS wave).
-- Contract: 1 row per campaign wave ID = 1:1.

SELECT
    Survey.ID
    , (
        SELECT AVG(TRY_CAST(Response.value:NpsScore AS NUMBER))
        FROM TABLE(FLATTEN(INPUT => Survey.Survey:Responses)) AS Response
        WHERE Response.value:NpsScore IS NOT NULL
    ) AS RnpsAvgNps
FROM {{ ref('SurveyRaw') }} AS Survey
WHERE Survey.Survey:SurveyType = 'RNPS'
