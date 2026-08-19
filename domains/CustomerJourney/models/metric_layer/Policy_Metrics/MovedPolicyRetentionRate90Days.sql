{{ config(tags=['metric_policy']) }}

-- METRIC: MovedPolicyRetentionRate90Days
-- Share of a policy's ZIP-change events after which the policy stayed in force
-- 90 days, rolled to policy grain (1:1). NULL for policies with no moves.
-- Contract: 1 row per policy ID = 1:1.
-- Pattern: AVG of InForce90DaysAfterChangeFlag over ZIP-change events only
--          (filter inside the aggregate — no WHERE in main SELECT).

WITH MoveRetention AS (
    SELECT
        ChangeEvent.ChangeEvent:Policy:ID::VARCHAR AS PolicyID
        , AVG(
            IsZipChangeEvent.IsZipChangeEvent
            * InForce90DaysAfterChangeFlag.InForce90DaysAfterChangeFlag)
            AS MovedPolicyRetentionRate90Days
    FROM {{ ref('ChangeEventRaw') }} AS ChangeEvent
    JOIN {{ ref('IsZipChangeEvent') }} AS IsZipChangeEvent
        ON ChangeEvent.ID = IsZipChangeEvent.ID
    JOIN {{ ref('InForce90DaysAfterChangeFlag') }} AS InForce90DaysAfterChangeFlag
        ON ChangeEvent.ID = InForce90DaysAfterChangeFlag.ID
    WHERE IsZipChangeEvent.IsZipChangeEvent = 1
    GROUP BY ChangeEvent.ChangeEvent:Policy:ID::VARCHAR
)

SELECT
    Policy.ID
    , MoveRetention.MovedPolicyRetentionRate90Days
FROM {{ ref('PolicyRaw') }} AS Policy
LEFT JOIN MoveRetention
    ON Policy.ID = MoveRetention.PolicyID
