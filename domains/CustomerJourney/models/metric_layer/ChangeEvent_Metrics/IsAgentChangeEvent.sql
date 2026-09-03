{{ config(tags=['metric_changeevent']) }}

-- METRIC: IsAgentChangeEvent
-- 1 if the event is an agent-of-record change, else 0.
-- Grain: 1 row per change event ID = 1:1 — every event emits a row.
-- Source: ChangeEventRaw (event-grain entity) — no FLATTEN, no WHERE.
-- Policy-grain rollups (NumberOfAgentChangeEvents etc.) SUM this flag.

SELECT
    ChangeEvent.ID
    , CASE
        WHEN ChangeEvent.EventType = 'AGENT_CHANGE' THEN 1
        ELSE 0
    END AS IsAgentChangeEvent
FROM {{ ref('ChangeEventRaw') }} AS ChangeEvent
