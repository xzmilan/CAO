{{ config(tags=['metric_changeevent']) }}

-- METRIC: InForce90DaysAfterChangeFlag
-- 1 if the policy was still in force 90 days after the change event, else 0.
-- Grain: 1 row per change event (event-grain metric) — every event emits a row.
-- Contract item: F04 in_force_90_flag (both CHANGED_ADDRESS and CHANGED_PRODUCER).
-- Rule: in-force at +90 days = no cancellation, or cancellation after event + 90 days.
-- Pattern: LEFT JOIN from the base entity so an event with an unresolved Policy
--          link still emits a row; no WHERE in main SELECT.


/* STEVE CHECK THIS - An event whose Policy.ID link fails to resolve will get flag = 1 (because CancellationDate IS NULL → "in force").
Should unresolved links as flag = 0 or exclude them via a data test?
Is there a case when a ChangeEvent ID would not have a corresponding Policy.ID? Test with live data.
 I'd recommend a dbt test on ChangeEventRaw.Policy.ID (not_null) as the real guard instead. */

SELECT
    ChangeEvent.ID
    , IFF(
        Policy.Policy:CancellationDate IS NULL
        OR Policy.Policy:CancellationDate > DATEADD(DAY, 90, ChangeEvent.ChangeEvent:EffectiveDate)
        , 1, 0
    ) AS InForce90DaysAfterChangeFlag
FROM {{ ref('ChangeEventRaw') }} AS ChangeEvent
LEFT JOIN {{ ref('PolicyRaw') }} AS Policy
    ON ChangeEvent.ChangeEvent:Policy:ID = Policy.ID
