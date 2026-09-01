{{ config(tags=['metric_survey']) }}

-- METRIC: RenewalAvgNps
-- Average NPS score across all renewal survey responses.
-- Campaign grain (1:1 with SurveyRaw RENEWAL wave).
-- Contract: 1 row per campaign wave ID = 1:1.

SELECT
    Survey.ID
    , AVG(TRY_CAST(Response.value:NpsScore::VARCHAR AS NUMBER)) AS RenewalAvgNps
FROM {{ ref('SurveyRaw') }} AS Survey
CROSS JOIN LATERAL FLATTEN(INPUT => Survey.Survey:Responses) AS Response
WHERE Survey.Survey:SurveyType = 'RENEWAL'
  AND Response.value:NpsScore IS NOT NULL
GROUP BY Survey.ID
