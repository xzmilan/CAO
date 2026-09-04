-- CAO Governed Definition (Snowflake)
-- MoveSurvey
-- Format: keyword/function UPPER | PascalCase aliases | ID all-caps | explicit AS
-- VIEW: MoveSurvey (Move Journey — Edgar Lattuada)
-- Pure SELECT from SurveyWide — all measures are pre-computed campaign-grain metrics.
-- No aggregation, no derivation logic in the view layer.
-- JO sheet coverage: Move rNPS.
-- Campaign wave = invite month.

SELECT
    Survey.*
FROM {{ ref('SurveyWide') }} AS Survey
WHERE Survey.Survey:SurveyType = 'RNPS'
