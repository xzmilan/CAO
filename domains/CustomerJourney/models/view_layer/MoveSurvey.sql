-- CAO Governed Definition (Snowflake)
-- MoveSurvey
-- Format: keyword/function UPPER | PascalCase aliases | ID all-caps | explicit AS
-- VIEW: MoveSurvey (Move Journey — Edgar Lattuada)
-- Pure SELECT from SurveyWide — all measures are pre-computed campaign-grain metrics.
-- No aggregation, no derivation logic in the view layer.
-- JO sheet coverage: Move rNPS.
-- Campaign wave = invite month.

SELECT
    Survey.Survey:SurveyType AS SurveyType
    , Survey.Survey:InviteWave AS InviteWave
    , Survey.Survey:InvitesSent AS InvitesSent
    , Survey.Survey:ResponseCount AS ResponseCount
    , Survey.Survey:ResponseRate AS ResponseRate
    , Survey.RnpsAvgNps:RnpsAvgNps AS RnpsAvgNps
FROM {{ ref('SurveyWide') }} AS Survey
WHERE Survey.Survey:SurveyType = 'RNPS'
