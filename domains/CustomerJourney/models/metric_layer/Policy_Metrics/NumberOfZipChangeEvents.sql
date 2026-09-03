{{ config(tags=['metric_policy']) }}

-- METRIC: NumberOfZipChangeEvents
-- Count of ZIP-5 change events per policy, rolled to policy grain (1:1)
-- Contract: 1 row per policy ID = 1:1 — every policy emits a row, zero-filled.
-- Pattern: SUM the event-grain IsZipChangeEvent flag — no re-filtering, no WHERE.

WITH ZipChangeCounts AS (
    SELECT
        ChangeEvent.PolicyID
        , SUM(IsZipChangeEvent.IsZipChangeEvent) AS NumberOfZipChangeEvents
    FROM {{ ref('ChangeEventRaw') }} AS ChangeEvent
    JOIN {{ ref('IsZipChangeEvent') }} AS IsZipChangeEvent
        ON ChangeEvent.ID = IsZipChangeEvent.ID
    GROUP BY ChangeEvent.PolicyID
)

SELECT
    Policy.ID
    , COALESCE(ZipChangeCounts.NumberOfZipChangeEvents, 0)
        AS NumberOfZipChangeEvents
FROM {{ ref('PolicyRaw') }} AS Policy
LEFT JOIN ZipChangeCounts
    ON Policy.ID = ZipChangeCounts.PolicyID
