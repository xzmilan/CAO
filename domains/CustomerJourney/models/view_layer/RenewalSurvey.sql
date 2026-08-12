-- VIEW: RenewalSurvey (Renewal Journey — Marc Steidler)
-- Pure SELECT from SurveyWide — all measures are pre-computed campaign-grain metrics.
-- No aggregation, no derivation logic in the view layer.
-- JO sheet coverage: Renewal tNPS.
-- Campaign wave = invite month.

SELECT
    Survey.Survey:SurveyType AS SurveyType
    , Survey.Survey:InviteWave AS InviteWave
    , Survey.Survey:InvitesSent AS InvitesSent
    , Survey.Survey:ResponseCount AS ResponseCount
    , Survey.Survey:ResponseRate AS ResponseRate
    , Survey.RenewalAvgNps:RenewalAvgNps AS RenewalAvgNps
FROM {{ ref('SurveyWide') }} AS Survey
WHERE Survey.Survey:SurveyType = 'RENEWAL'
