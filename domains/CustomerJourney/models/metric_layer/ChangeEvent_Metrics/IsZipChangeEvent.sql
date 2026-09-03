{{ config(tags=['metric_changeevent']) }}

-- METRIC: IsZipChangeEvent
-- 1 if the event is a ZIP-5 change, else 0.
-- Grain: 1 row per change event ID = 1:1 — every event emits a row.
-- Source: ChangeEventRaw (event-grain entity) — no FLATTEN, no WHERE.
-- Policy-grain rollups (NumberOfZipChangeEvents etc.) SUM this flag.

SELECT
    ChangeEvent.ID
    , CASE
        WHEN ChangeEvent.EventType = 'ZIP_CHANGE' THEN 1
        ELSE 0
    END AS IsZipChangeEvent
FROM {{ ref('ChangeEventRaw') }} AS ChangeEvent
