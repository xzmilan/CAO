{{ config(tags=['metric_survey']) }}

-- METRIC: AgentChangeMeetsNeedsRate
-- Share of agent-change respondents who said the new agent meets their needs.
-- Campaign grain (1:1 with SurveyRaw AGENT_CHANGE wave).
-- Contract: 1 row per campaign wave ID = 1:1.

SELECT
    Survey.ID
    , AVG(IFF(Response.value:AgentChangeDetails:MeetsNeedsFlag = '1', 1.0, 0.0)) AS AgentChangeMeetsNeedsRate
FROM {{ ref('SurveyRaw') }} AS Survey
CROSS JOIN LATERAL FLATTEN(INPUT => Survey.Responses) AS Response
WHERE
    Survey.SurveyType = 'AGENT_CHANGE'
    AND Response.value:AgentChangeDetails:MeetsNeedsFlag IS NOT NULL
GROUP BY Survey.ID
