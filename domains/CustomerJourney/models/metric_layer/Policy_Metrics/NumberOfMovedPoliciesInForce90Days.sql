{{ config(tags=['metric_policy']) }}

-- METRIC: NumberOfMovedPoliciesInForce90Days
-- Count of ZIP-change events whose policy was still in force 90 days post-move,
-- rolled to policy grain (1:1)
-- Contract: 1 row per policy ID = 1:1 — every policy emits a row, zero-filled.
-- Pattern: SUM of event-grain flags (IsZipChangeEvent × InForce90DaysAfterChangeFlag).

WITH MovedInForce AS (
    SELECT
        ChangeEvent.PolicyID
        , SUM(
            IsZipChangeEvent.IsZipChangeEvent
            * InForce90DaysAfterChangeFlag.InForce90DaysAfterChangeFlag)
            AS NumberOfMovedPoliciesInForce90Days
    FROM {{ ref('ChangeEventRaw') }} AS ChangeEvent
    JOIN {{ ref('IsZipChangeEvent') }} AS IsZipChangeEvent
        ON ChangeEvent.ID = IsZipChangeEvent.ID
    JOIN {{ ref('InForce90DaysAfterChangeFlag') }} AS InForce90DaysAfterChangeFlag
        ON ChangeEvent.ID = InForce90DaysAfterChangeFlag.ID
    GROUP BY ChangeEvent.PolicyID
)

SELECT
    Policy.ID
    , COALESCE(MovedInForce.NumberOfMovedPoliciesInForce90Days, 0)
        AS NumberOfMovedPoliciesInForce90Days
FROM {{ ref('PolicyRaw') }} AS Policy
LEFT JOIN MovedInForce
    ON Policy.ID = MovedInForce.PolicyID
