{{ config(tags=['metric_survey']) }}

-- METRIC: CssCesAvgScore
-- Average CES score across all CSS survey responses.
-- Campaign grain (1:1 with SurveyRaw CSS_CES wave).
-- Contract: 1 row per campaign wave ID = 1:1.

SELECT
    Survey.ID
    , AVG(TRY_CAST(Response.value:NpsScore::VARCHAR AS NUMBER)) AS CssCesAvgScore
FROM {{ ref('SurveyRaw') }} AS Survey
CROSS JOIN LATERAL FLATTEN(INPUT => Survey.Survey:Responses) AS Response
WHERE Survey.Survey:SurveyType = 'CSS_CES'
  AND Response.value:NpsScore IS NOT NULL
GROUP BY Survey.ID
