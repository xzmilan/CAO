{{ config(tags=['metric_survey']) }}

-- METRIC: CssCesAvgScore
-- Average CES score across all CSS survey responses.
-- Campaign grain (1:1 with SurveyRaw CSS_CES wave).
-- Contract: 1 row per campaign wave ID = 1:1.

SELECT
    Survey.ID
    , (
        SELECT AVG(TRY_CAST(Response.value:NpsScore AS NUMBER))
        FROM TABLE(FLATTEN(INPUT => Survey.Survey:Responses)) AS Response
        WHERE Response.value:NpsScore IS NOT NULL
    ) AS CssCesAvgScore
FROM {{ ref('SurveyRaw') }} AS Survey
WHERE Survey.Survey:SurveyType = 'CSS_CES'
