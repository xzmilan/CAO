-- CAO Governed Definition (Snowflake)
-- OnboardingSurvey
-- Format: keyword/function UPPER | PascalCase aliases | ID all-caps | explicit AS
-- VIEW: OnboardingSurvey (Onboarding Journeys — Kim Baker, Deanne Martin, Joe Spinelli)
-- Pure SELECT from SurveyWide — all measures are pre-computed campaign-grain metrics.
-- No aggregation, no derivation logic in the view layer.
-- JO sheet coverage: Onboarding tNPS/CSAT, response rates.
-- Campaign wave = invite month.

SELECT
    Survey.Survey:SurveyType AS SurveyType
    , Survey.Survey:InviteWave AS InviteWave
    , Survey.Survey:InvitesSent AS InvitesSent
    , Survey.Survey:ResponseCount AS ResponseCount
    , Survey.Survey:ResponseRate AS ResponseRate
    , Survey.NewBusinessAvgNps:NewBusinessAvgNps AS NewBusinessAvgNps
FROM {{ ref('SurveyWide') }} AS Survey
WHERE Survey.Survey:SurveyType = 'NEW_BUSINESS'
