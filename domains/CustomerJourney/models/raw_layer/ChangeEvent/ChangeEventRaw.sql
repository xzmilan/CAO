-- RAW ENTITY: ChangeEvent
-- Grain: one row per policy change event (ZIP_CHANGE or AGENT_CHANGE)
-- ID: hashed primary key — BASE64_ENCODE(SHA2(natural key, 256))
-- Natural key: PLCY_CNTRCT_NUM + EventType + EFF_DT + SRC_TRANS_TMSP
-- Doctrine: event grain is FIRST-CLASS here. 1:1 event attributes are flat
--           top-level columns — no wrapping "ChangeEvent" OBJECT. Policy
--           context is denormalized 1:1 at build time as a flat PolicyID
--           column (legal: still 1 row per event). Downstream consumers
--           NEVER FLATTEN and NEVER read the transaction table. Raw source
--           columns stay unformatted inside the system-specific Rten
--           OBJECT — no aliases, no transforms, values as-is.
--           THIS ENTITY IS THE CONTRACT for all change-event data.

WITH RankedTransactions AS (
    SELECT
        PolicyTransaction.PLCY_CNTRCT_NUM
        , PolicyTransaction.EFF_DT AS EffectiveDate
        , PolicyTransaction.SRC_TRANS_TMSP AS SourceTransactionTimestamp
        , PolicyTransaction.SRC_SYS_CD AS SourceSystemCode
        , PolicyTransaction.RESDC_ZIP_5_CD AS CurrentZip
        , PolicyTransaction.AGT_OF_RECRD_NUM AS CurrentAgentNumber
        , LAG(PolicyTransaction.RESDC_ZIP_5_CD) OVER (
            PARTITION BY PolicyTransaction.PLCY_CNTRCT_NUM
            ORDER BY PolicyTransaction.EFF_DT, PolicyTransaction.SRC_TRANS_TMSP
        ) AS PreviousZip
        , LAG(PolicyTransaction.AGT_OF_RECRD_NUM) OVER (
            PARTITION BY PolicyTransaction.PLCY_CNTRCT_NUM
            ORDER BY PolicyTransaction.EFF_DT, PolicyTransaction.SRC_TRANS_TMSP
        ) AS PreviousAgentNumber
    FROM {{ source('rten', 'rten_dim_pl_trn_xlob') }} AS PolicyTransaction

    {% if is_incremental() %}
    WHERE PolicyTransaction.PLCY_CNTRCT_NUM IN (
        -- Signal 1: policies with a transaction newer than the global watermark
        SELECT DISTINCT PolicyTransactionNew.PLCY_CNTRCT_NUM
        FROM {{ source('rten', 'rten_dim_pl_trn_xlob') }} AS PolicyTransactionNew
        WHERE
            PolicyTransactionNew.SRC_TRANS_TMSP > (
                SELECT COALESCE(MAX(ChangeEventRawPrev.SourceTransactionTimestamp::TIMESTAMP_NTZ), '1900-01-01'::TIMESTAMP_NTZ)
                FROM {{ this }} AS ChangeEventRawPrev
            )
        UNION
        -- Signal 2: policies with NO existing rows in this table at all — first-time
        -- seen policies must always be scanned, regardless of their transaction
        -- timestamps relative to the global watermark.
        SELECT DISTINCT PolicyTransactionAny.PLCY_CNTRCT_NUM
        FROM {{ source('rten', 'rten_dim_pl_trn_xlob') }} AS PolicyTransactionAny
        WHERE PolicyTransactionAny.PLCY_CNTRCT_NUM NOT IN (
            SELECT DISTINCT ChangeEventRawExisting.Rten:PLCY_CNTRCT_NUM::VARCHAR
            FROM {{ this }} AS ChangeEventRawExisting
        )
    )
    {% endif %}

)

, CurrentPolicyStats AS (
    -- SCD2 quarantine: fdr_mdm_plcy_stats carries full history per policy.
    -- Dedupe to the CURRENT row (open sentinel + ROW_NUMBER backstop) so the
    -- event grain below doesn't fan out across a policy's version history.
    -- See PolicyRaw.sql for the full rationale (VERIFIED against prod).
    SELECT
        PolicyStats.PLCY_NUM
        , PolicyStats.SRC_SYS
    FROM {{ source('fdr', 'fdr_mdm_plcy_stats') }} AS PolicyStats
    WHERE PolicyStats.END_DT_TMSP = '2999-12-31'::TIMESTAMP_NTZ
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY PolicyStats.PLCY_NUM
        ORDER BY PolicyStats.SRC_TRANS_TMSP DESC, PolicyStats.STRT_DT_TMSP DESC
    ) = 1
)

, ZipChangeEvents AS (
    SELECT
        PLCY_CNTRCT_NUM
        , 'ZIP_CHANGE' AS EventType
        , EffectiveDate
        , SourceTransactionTimestamp
        , SourceSystemCode
        , PreviousZip AS PreviousZipCode
        , CurrentZip AS ZipCode
        , CAST(NULL AS VARCHAR) AS PreviousAgentNumber
        , CAST(NULL AS VARCHAR) AS AgentNumber
    FROM RankedTransactions
    WHERE
        PreviousZip IS NOT NULL
        AND CurrentZip <> PreviousZip
)

, AgentChangeEvents AS (
    SELECT
        PLCY_CNTRCT_NUM
        , 'AGENT_CHANGE' AS EventType
        , EffectiveDate
        , SourceTransactionTimestamp
        , SourceSystemCode
        , CAST(NULL AS VARCHAR) AS PreviousZipCode
        , CAST(NULL AS VARCHAR) AS ZipCode
        , PreviousAgentNumber
        , CurrentAgentNumber AS AgentNumber
    FROM RankedTransactions
    WHERE
        PreviousAgentNumber IS NOT NULL
        AND CurrentAgentNumber <> PreviousAgentNumber
)

, AllEvents AS (
    SELECT
        ZipChangeEvents.PLCY_CNTRCT_NUM
        , ZipChangeEvents.EventType
        , ZipChangeEvents.EffectiveDate
        , ZipChangeEvents.SourceTransactionTimestamp
        , ZipChangeEvents.SourceSystemCode
        , ZipChangeEvents.PreviousZipCode
        , ZipChangeEvents.ZipCode
        , ZipChangeEvents.PreviousAgentNumber
        , ZipChangeEvents.AgentNumber
    FROM ZipChangeEvents
    UNION ALL
    SELECT
        AgentChangeEvents.PLCY_CNTRCT_NUM
        , AgentChangeEvents.EventType
        , AgentChangeEvents.EffectiveDate
        , AgentChangeEvents.SourceTransactionTimestamp
        , AgentChangeEvents.SourceSystemCode
        , AgentChangeEvents.PreviousZipCode
        , AgentChangeEvents.ZipCode
        , AgentChangeEvents.PreviousAgentNumber
        , AgentChangeEvents.AgentNumber
    FROM AgentChangeEvents
)

SELECT
    BASE64_ENCODE(SHA2(
        AllEvents.PLCY_CNTRCT_NUM || '|' || AllEvents.EventType || '|' ||
        CAST(AllEvents.EffectiveDate AS VARCHAR) || '|' ||
        CAST(AllEvents.SourceTransactionTimestamp AS VARCHAR)
        , 256
    )) AS ID

    -- 1:1 event attributes — flat top-level columns, no wrapping OBJECT.
    , AllEvents.EventType AS EventType
    , CAST(AllEvents.EffectiveDate AS DATE) AS EffectiveDate
    , TO_CHAR(AllEvents.EffectiveDate, 'YYYY-MM') AS EventMonth
    , AllEvents.PreviousZipCode AS PreviousZipCode
    , AllEvents.ZipCode AS ZipCode
    , AllEvents.PreviousAgentNumber AS PreviousAgentNumber
    , AllEvents.AgentNumber AS AgentNumber
    , Policy.BUS_ENTITY AS BusinessEntity
    , Policy.LOB_TYP_CD AS LineOfBusinessCode
    , Policy.PLCY_ST_CD AS PolicyStateCode
    , COALESCE(AllEvents.SourceSystemCode, PolicyStats.SRC_SYS) AS SourceSystemCode
    , AllEvents.SourceTransactionTimestamp AS SourceTransactionTimestamp

    -- Link to PolicyRaw — flat PolicyID column (this entity's one documented
    -- exception to the link-STRUCT convention; needed at build time so the
    -- Wide Layer's OBJECT_CONSTRUCT(alias.*) can pack it as a flat field).
    , PolicyRaw.ID AS PolicyID

    -- System-specific raw fields — quarantined in a typed OBJECT, values
    -- as-is, no aliases/transforms inside.
    , OBJECT_CONSTRUCT_KEEP_NULL(
        'PLCY_CNTRCT_NUM', AllEvents.PLCY_CNTRCT_NUM
        , 'EFF_DT', CAST(AllEvents.EffectiveDate AS VARCHAR)
        , 'SRC_TRANS_TMSP', CAST(AllEvents.SourceTransactionTimestamp AS VARCHAR)
        , 'SRC_SYS_CD', AllEvents.SourceSystemCode
        , 'PLCY_NUM', CAST(PolicyStats.PLCY_NUM AS VARCHAR)
    )::OBJECT(
        PLCY_CNTRCT_NUM VARCHAR
        , EFF_DT VARCHAR
        , SRC_TRANS_TMSP VARCHAR
        , SRC_SYS_CD VARCHAR
        , PLCY_NUM VARCHAR
    ) AS Rten

FROM AllEvents
LEFT JOIN {{ source('rten', 'rten_xcmpy_pif_tbl') }} AS Policy
    ON AllEvents.PLCY_CNTRCT_NUM = Policy.PLCY_CNTRCT_NUM
LEFT JOIN CurrentPolicyStats AS PolicyStats
    ON AllEvents.PLCY_CNTRCT_NUM = PolicyStats.PLCY_NUM
LEFT JOIN {{ ref('PolicyRaw') }} AS PolicyRaw
    ON AllEvents.PLCY_CNTRCT_NUM = PolicyRaw.SystemIds:RtenPlcyCntrctNum

{% if is_incremental() %}
WHERE
    AllEvents.SourceTransactionTimestamp > (
        SELECT COALESCE(MAX(ChangeEventRawPrev.SourceTransactionTimestamp::TIMESTAMP_NTZ), '1900-01-01'::TIMESTAMP_NTZ)
        FROM {{ this }} AS ChangeEventRawPrev
    )
{% endif %}


/*
    Typed access:PolicyRaw.SystemIds:RtenPlcyCntrctNum — no ::VARCHAR cast
    needed (typed OBJECT). This join carries PolicyRaw.ID into the flat
    PolicyID column above (build-time, raw layer only).
    */
