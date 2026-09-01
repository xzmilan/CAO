{{ config(tags=['metric_survey']) }}

-- METRIC: RnpsAvgNps
-- Average NPS score across all relationship NPS survey responses.
-- Campaign grain (1:1 with SurveyRaw RNPS wave).
-- Contract: 1 row per campaign wave ID = 1:1.

SELECT
    Survey.ID
    , AVG(TRY_CAST(Response.value:NpsScore::VARCHAR AS NUMBER)) AS RnpsAvgNps
FROM {{ ref('SurveyRaw') }} AS Survey
CROSS JOIN LATERAL FLATTEN(INPUT => Survey.Survey:Responses) AS Response
WHERE Survey.Survey:SurveyType = 'RNPS'
  AND Response.value:NpsScore IS NOT NULL
GROUP BY Survey.ID
