{{ config(tags=['test_policy_incremental']) }}
-- Guards against the incremental watermark going backward/stale: every
-- row's LastTransactionTmsp must be a valid, non-future timestamp.
SELECT PolicyRaw.ID
FROM {{ ref('PolicyRaw') }} AS PolicyRaw
WHERE PolicyRaw.Policy:SystemIds:LastTransactionTmsp IS NOT NULL
  AND TRY_CAST(PolicyRaw.Policy:SystemIds:LastTransactionTmsp::VARCHAR AS TIMESTAMP_NTZ) > CURRENT_TIMESTAMP()
