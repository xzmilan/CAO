-- CAO Governed Definition (Snowflake)
-- CssCesSurvey
-- Format: keyword/function UPPER | PascalCase aliases | ID all-caps | explicit AS
-- VIEW: CssCesSurvey (CSS/Move/Renewal Journeys — CES metric)
-- Pure SELECT from SurveyWide — all measures are pre-computed campaign-grain metrics.
-- No aggregation, no derivation logic in the view layer.
-- JO sheet coverage: CSS CES (Move + Renewal journeys).
-- Campaign wave = response month.

SELECT
    Survey.Survey:SurveyType AS SurveyType
    , Survey.Survey:InviteWave AS InviteWave
    , Survey.Survey:InvitesSent AS InvitesSent
    , Survey.Survey:ResponseCount AS ResponseCount
    , Survey.Survey:ResponseRate AS ResponseRate
    , Survey.CssCesAvgScore:CssCesAvgScore AS CssCesAvgScore
FROM {{ ref('SurveyWide') }} AS Survey
WHERE Survey.Survey:SurveyType = 'CSS_CES'
