-- VIEW: AgencyChangeSurvey (Agency Change Journey — Jessica Campbell)
-- Pure SELECT from SurveyWide — all measures are pre-computed campaign-grain metrics.
-- No aggregation, no derivation logic in the view layer.
-- JO sheet coverage: Agent Change CSAT, % meets needs, % no comms, cycle time.
-- Change-month/reporting-month series come from the campaign wave (InviteWave).

SELECT
    Survey.Survey:SurveyType AS SurveyType
    , Survey.Survey:InviteWave AS InviteWave
    , Survey.Survey:InvitesSent AS InvitesSent
    , Survey.Survey:ResponseCount AS ResponseCount
    , Survey.Survey:ResponseRate AS ResponseRate
    , Survey.AgentChangeAvgNps:AgentChangeAvgNps AS AgentChangeAvgNps
    , Survey.AgentChangeMeetsNeedsRate:AgentChangeMeetsNeedsRate AS AgentChangeMeetsNeedsRate
    , Survey.AgentChangeNoCommsRate:AgentChangeNoCommsRate AS AgentChangeNoCommsRate
    , Survey.AgentChangeAvgDaysWithoutAgent:AgentChangeAvgDaysWithoutAgent AS AgentChangeAvgDaysWithoutAgent
FROM {{ ref('SurveyWide') }} AS Survey
WHERE Survey.Survey:SurveyType = 'AGENT_CHANGE'
