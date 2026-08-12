{{ config(tags=['metric_survey']) }}

-- METRIC: AgentChangeMeetsNeedsRate
-- Share of agent-change respondents who said the new agent meets their needs.
-- Campaign grain (1:1 with SurveyRaw AGENT_CHANGE wave).
-- Contract: 1 row per campaign wave ID = 1:1.

SELECT
    Survey.ID
    , (
        SELECT AVG(IFF(Response.value:AgentChangeDetails:MeetsNeedsFlag = 'Y', 1.0, 0.0))
        FROM TABLE(FLATTEN(INPUT => Survey.Survey:Responses)) AS Response
        WHERE Response.value:AgentChangeDetails:MeetsNeedsFlag IS NOT NULL
    ) AS AgentChangeMeetsNeedsRate
FROM {{ ref('SurveyRaw') }} AS Survey
WHERE Survey.Survey:SurveyType = 'AGENT_CHANGE'
