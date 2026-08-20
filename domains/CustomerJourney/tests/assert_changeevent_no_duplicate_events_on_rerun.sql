{{ config(tags=['test_changeevent_incremental']) }}
-- Guards the merge boundary: ID (hash of natural key incl. SRC_TRANS_TMSP)
-- must remain unique after incremental merges — a duplicate means the
-- same transaction got re-classified as "new" on a re-run.
SELECT ChangeEventRaw.ID, COUNT(*) AS DuplicateCount
FROM {{ ref('ChangeEventRaw') }} AS ChangeEventRaw
GROUP BY ChangeEventRaw.ID
HAVING COUNT(*) > 1
