{{ config(tags=['test_survey_incremental']) }}
-- Guards the merge boundary: ID (hash of SurveyType|InviteWave) must stay
-- unique — the lookback should MERGE/overwrite an existing campaign row,
-- never produce a second row for the same campaign-month.
SELECT SurveyRaw.ID, COUNT(*) AS DuplicateCount
FROM {{ ref('SurveyRaw') }} AS SurveyRaw
GROUP BY SurveyRaw.ID
HAVING COUNT(*) > 1
