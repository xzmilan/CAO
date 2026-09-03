{{ config(tags=['metric_survey']) }}

-- METRIC: AgentChangeResponseRate
-- Share of agent-change survey invites that received a response.
-- Campaign grain (1:1 with SurveyRaw AGENT_CHANGE wave).
-- Contract: 1 row per campaign wave ID = 1:1.

SELECT
    Survey.ID
    , Survey.ResponseRate AS AgentChangeResponseRate
FROM {{ ref('SurveyRaw') }} AS Survey
WHERE Survey.SurveyType = 'AGENT_CHANGE'
