{{ config(tags=['metric_survey']) }}

-- METRIC: AgentChangeAvgNps
-- Average NPS score across all agent-change survey responses in a wave.
-- Campaign grain (1:1 with SurveyRaw AGENT_CHANGE wave).
-- Contract: 1 row per campaign wave ID = 1:1.

SELECT
    Survey.ID
    , (
        SELECT AVG(TRY_CAST(Response.value:NpsScore AS NUMBER))
        FROM TABLE(FLATTEN(INPUT => Survey.Survey:Responses)) AS Response
        WHERE Response.value:NpsScore IS NOT NULL
    ) AS AgentChangeAvgNps
FROM {{ ref('SurveyRaw') }} AS Survey
WHERE Survey.Survey:SurveyType = 'AGENT_CHANGE'
