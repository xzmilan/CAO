{{ config(tags=['metric_survey']) }}

-- METRIC: AgentChangeNoCommsRate
-- Share of agent-change respondents who received NO communication
-- (no letter) about the change. Campaign grain (1:1).
-- Contract: 1 row per campaign wave ID = 1:1.

-- Note: RCVD_FARMERS_LETTER stores '1'/'2'/'3', not 'Y'/'N'.
-- Assumed '2' = "did NOT receive letter" (no comms). CONFIRM Qualtrics codebook.
SELECT
    Survey.ID
    , AVG(IFF(Response.value:AgentChangeDetails:ReceivedLetterFlag = '2', 1.0, 0.0)) AS AgentChangeNoCommsRate
FROM {{ ref('SurveyRaw') }} AS Survey
CROSS JOIN LATERAL FLATTEN(INPUT => Survey.Responses) AS Response
WHERE
    Survey.SurveyType = 'AGENT_CHANGE'
    AND Response.value:AgentChangeDetails:ReceivedLetterFlag IS NOT NULL
GROUP BY Survey.ID
