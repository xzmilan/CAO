{{
    config(
        tags=['test_changeevent_eventtype']
    )
}}
-- Custom data test: ChangeEvent:EventType must be ZIP_CHANGE or AGENT_CHANGE.
-- YAML column tests don't reach into OBJECT fields, so this SQL test covers the gate.
SELECT ChangeEvent.ChangeEvent:EventType::VARCHAR AS event_type
FROM {{ ref('ChangeEventRaw') }} AS ChangeEvent
WHERE ChangeEvent.ChangeEvent:EventType::VARCHAR NOT IN ('ZIP_CHANGE', 'AGENT_CHANGE')
