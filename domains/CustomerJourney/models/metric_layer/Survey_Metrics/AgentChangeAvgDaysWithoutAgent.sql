{{ config(tags=['metric_survey']) }}

-- METRIC: AgentChangeAvgDaysWithoutAgent
-- Average days customers were without an agent during the transition.
-- Campaign grain (1:1 with SurveyRaw AGENT_CHANGE wave).
-- Contract: 1 row per campaign wave ID = 1:1.

SELECT
    Survey.ID
    , (
        SELECT AVG(TRY_CAST(Response.value:AgentChangeDetails:DaysWithoutAgent AS NUMBER))
        FROM TABLE(FLATTEN(INPUT => Survey.Survey:Responses)) AS Response
        WHERE Response.value:AgentChangeDetails:DaysWithoutAgent IS NOT NULL
    ) AS AgentChangeAvgDaysWithoutAgent
FROM {{ ref('SurveyRaw') }} AS Survey
WHERE Survey.Survey:SurveyType = 'AGENT_CHANGE'
