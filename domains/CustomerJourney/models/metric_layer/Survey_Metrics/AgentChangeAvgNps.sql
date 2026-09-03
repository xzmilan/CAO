{{ config(tags=['metric_survey']) }}

-- METRIC: AgentChangeAvgNps
-- Average NPS score across all agent-change survey responses in a wave.
-- Campaign grain (1:1 with SurveyRaw AGENT_CHANGE wave).
-- Contract: 1 row per campaign wave ID = 1:1.

SELECT
    Survey.ID
    , AVG(TRY_CAST(Response.value:NpsScore::VARCHAR AS NUMBER)) AS AgentChangeAvgNps
FROM {{ ref('SurveyRaw') }} AS Survey
CROSS JOIN LATERAL FLATTEN(INPUT => Survey.Responses) AS Response
WHERE Survey.SurveyType = 'AGENT_CHANGE'
  AND Response.value:NpsScore IS NOT NULL
GROUP BY Survey.ID
