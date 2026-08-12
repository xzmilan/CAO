{{ config(tags=['metric_survey']) }}

-- METRIC: AgentChangeNoCommsRate
-- Share of agent-change respondents who received NO communication
-- (no letter) about the change. Campaign grain (1:1).
-- Contract: 1 row per campaign wave ID = 1:1.

SELECT
    Survey.ID
    , (
        SELECT AVG(IFF(Response.value:AgentChangeDetails:ReceivedLetterFlag = 'N', 1.0, 0.0))
        FROM TABLE(FLATTEN(INPUT => Survey.Survey:Responses)) AS Response
        WHERE Response.value:AgentChangeDetails:ReceivedLetterFlag IS NOT NULL
    ) AS AgentChangeNoCommsRate
FROM {{ ref('SurveyRaw') }} AS Survey
WHERE Survey.Survey:SurveyType = 'AGENT_CHANGE'
