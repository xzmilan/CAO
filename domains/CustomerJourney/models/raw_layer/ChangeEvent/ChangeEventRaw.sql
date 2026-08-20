-- RAW ENTITY: ChangeEvent
-- Grain: one row per policy change event (ZIP_CHANGE or AGENT_CHANGE)
-- ID: hashed primary key — BASE64_ENCODE(SHA2(natural key, 256))
-- Natural key: PLCY_CNTRCT_NUM + EventType + EFF_DT + SRC_TRANS_TMSP
-- Doctrine: event grain is FIRST-CLASS here. Policy context is denormalized
--           1:1 at build time (legal: still 1 row per event). Downstream
--           consumers NEVER FLATTEN and NEVER read the transaction table.
--           Raw source columns stay unformatted inside system-specific
--           OBJECTs — no aliases, no transforms, values as-is.
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
        WHERE PolicyTransactionNew.SRC_TRANS_TMSP > (
            SELECT COALESCE(MAX(ChangeEventRawPrev.ChangeEvent:SourceTransactionTimestamp::TIMESTAMP_NTZ), '1900-01-01'::TIMESTAMP_NTZ)
            FROM {{ this }} AS ChangeEventRawPrev
        )
        UNION
        -- Signal 2: policies with NO existing rows in this table at all — first-time
        -- seen policies must always be scanned, regardless of their transaction
        -- timestamps relative to the global watermark (Issue #4 fix).
        SELECT DISTINCT PolicyTransactionAny.PLCY_CNTRCT_NUM
        FROM {{ source('rten', 'rten_dim_pl_trn_xlob') }} AS PolicyTransactionAny
        WHERE PolicyTransactionAny.PLCY_CNTRCT_NUM NOT IN (
            SELECT DISTINCT ChangeEventRawExisting.ChangeEvent:Rten:PLCY_CNTRCT_NUM::VARCHAR
            FROM {{ this }} AS ChangeEventRawExisting
        )
    )
    {% endif %}
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

    -- Typed-OBJECT entity: one outer ::OBJECT cast, inner values untyped.
    -- Nested OBJECT_CONSTRUCT_KEEP_NULL stays untyped per the proven pattern.
    -- Access: ChangeEvent:EventType  (typed → no ::VARCHAR cast needed).
    , OBJECT_CONSTRUCT_KEEP_NULL(
        'EventType', AllEvents.EventType,
        'EffectiveDate', CAST(AllEvents.EffectiveDate AS DATE),
        'EventMonth', TO_CHAR(AllEvents.EffectiveDate, 'YYYY-MM'),
        'PreviousZipCode', AllEvents.PreviousZipCode,
        'ZipCode', AllEvents.ZipCode,
        'PreviousAgentNumber', AllEvents.PreviousAgentNumber,
        'AgentNumber', AllEvents.AgentNumber,
        'BusinessEntity', Policy.BUS_ENTITY,
        'LineOfBusinessCode', Policy.LOB_TYP_CD,
        'PolicyStateCode', Policy.PLCY_ST_CD,
        'SourceSystemCode', COALESCE(AllEvents.SourceSystemCode, PolicyStats.SRC_SYS),
        'SourceTransactionTimestamp', AllEvents.SourceTransactionTimestamp,
        'Rten', OBJECT_CONSTRUCT_KEEP_NULL(
            'PLCY_CNTRCT_NUM', AllEvents.PLCY_CNTRCT_NUM,
            'EFF_DT', CAST(AllEvents.EffectiveDate AS VARCHAR),
            'SRC_TRANS_TMSP', CAST(AllEvents.SourceTransactionTimestamp AS VARCHAR),
            'SRC_SYS_CD', AllEvents.SourceSystemCode,
            'PLCY_NUM', CAST(PolicyStats.PLCY_NUM AS VARCHAR)
        ),
        'Policy', OBJECT_CONSTRUCT_KEEP_NULL('ID', PolicyRaw.ID)
    )::OBJECT(
        EventType                  VARCHAR,
        EffectiveDate              DATE,
        EventMonth                 VARCHAR,
        PreviousZipCode            VARCHAR,
        ZipCode                    VARCHAR,
        PreviousAgentNumber        VARCHAR,
        AgentNumber                VARCHAR,
        BusinessEntity             VARCHAR,
        LineOfBusinessCode         VARCHAR,
        PolicyStateCode            VARCHAR,
        SourceSystemCode           VARCHAR,
        SourceTransactionTimestamp VARCHAR,
        Rten                       OBJECT(PLCY_CNTRCT_NUM VARCHAR, EFF_DT VARCHAR, SRC_TRANS_TMSP VARCHAR, SRC_SYS_CD VARCHAR, PLCY_NUM VARCHAR),
        Policy                     OBJECT(ID VARCHAR)
      ) AS ChangeEvent

FROM AllEvents
LEFT JOIN {{ source('rten', 'rten_xcmpy_pif_tbl') }} AS Policy
    ON AllEvents.PLCY_CNTRCT_NUM = Policy.PLCY_CNTRCT_NUM
LEFT JOIN {{ source('fdr', 'fdr_mdm_plcy_stats') }} AS PolicyStats
    ON AllEvents.PLCY_CNTRCT_NUM = PolicyStats.PLCY_NUM
LEFT JOIN {{ ref('PolicyRaw') }} AS PolicyRaw
    ON AllEvents.PLCY_CNTRCT_NUM = PolicyRaw.Policy:SystemIds:RtenPlcyCntrctNum

{% if is_incremental() %}
WHERE AllEvents.SourceTransactionTimestamp > (
    SELECT COALESCE(MAX(ChangeEventRawPrev.ChangeEvent:SourceTransactionTimestamp::TIMESTAMP_NTZ), '1900-01-01'::TIMESTAMP_NTZ)
    FROM {{ this }} AS ChangeEventRawPrev
)
{% endif %}

    /*
    Typed-OBJECT join:PolicyRaw.Policy:SystemIds:RtenPlcyCntrctNum — typed access, no ::VARCHAR.
    This join carries PolicyRaw.ID into the ChangeEvent OBJECT (build-time, raw layer only).
    Do NOT add a plain PolicyID column — see DEPLOY_HANDOFF.md §10. OBJECT-only doctrine.
    */
