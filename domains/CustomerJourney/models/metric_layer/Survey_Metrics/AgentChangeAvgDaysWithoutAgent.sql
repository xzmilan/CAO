{{ config(tags=['metric_survey']) }}

-- METRIC: AgentChangeAvgDaysWithoutAgent
-- Average days customers were without an agent during the transition.
-- Campaign grain (1:1 with SurveyRaw AGENT_CHANGE wave).
-- Contract: 1 row per campaign wave ID = 1:1.

SELECT
    Survey.ID
    , AVG(TRY_CAST(Response.value:AgentChangeDetails:DaysWithoutAgent::VARCHAR AS NUMBER)) AS AgentChangeAvgDaysWithoutAgent
FROM {{ ref('SurveyRaw') }} AS Survey
CROSS JOIN LATERAL FLATTEN(INPUT => Survey.Responses) AS Response
WHERE Survey.SurveyType = 'AGENT_CHANGE'
  AND Response.value:AgentChangeDetails:DaysWithoutAgent IS NOT NULL
GROUP BY Survey.ID
