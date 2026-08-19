-- RAW ENTITY: Policy (FULL DEFINITION)
-- Grain: one row per policy (RTEN_XCMPY_PIF_TBL)
-- ID: hashed primary key — BASE64_ENCODE(SHA2(natural key, 256))
-- Doctrine: 1:1 enrichment at top level; 1:many detail as typed ARRAYs;
--           system IDs in typed system-specific OBJECTs, never bare;
--           nothing downstream reads the transaction or snapshot tables.
--           Change events live in ChangeEventRaw (event grain), NOT here.
--           THIS ENTITY IS THE CONTRACT.

WITH LatestTransaction AS (
    -- The quarantine: most recent transaction per policy, 1:1
    SELECT
        PolicyTransaction.PLCY_CNTRCT_NUM
        , PolicyTransaction.SRC_SYS_CD AS SourceSystemCode
        , PolicyTransaction.RESDC_ZIP_5_CD AS ZipCode
        , PolicyTransaction.SRC_TRANS_TMSP AS LatestTransactionTimestamp
    FROM {{ source('rten', 'rten_dim_pl_trn_xlob') }} AS PolicyTransaction
    {% if is_incremental() %}
    WHERE PolicyTransaction.SRC_TRANS_TMSP > (
        SELECT COALESCE(MAX(PolicyRawPrev.Policy:SystemIds:LastTransactionTmsp::TIMESTAMP_NTZ), '1900-01-01'::TIMESTAMP_NTZ)
        FROM {{ this }} AS PolicyRawPrev
    )
    {% endif %}
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY PolicyTransaction.PLCY_CNTRCT_NUM
        ORDER BY PolicyTransaction.EFF_DT DESC, PolicyTransaction.SRC_TRANS_TMSP DESC
    ) = 1
)

, CurrentPolicyStats AS (
    -- SCD2 quarantine: fdr_mdm_plcy_stats carries full history per policy.
    -- We only ever want the CURRENT row. VERIFIED against prod 2026-08-17:
    -- open rows use the sentinel END_DT_TMSP = '2999-12-31' (64,334,573 rows),
    -- NOT NULL — an IS NULL predicate here would match zero rows and silently
    -- NULL out all PolicyStats enrichment. Also note: sentinel-row count
    -- exceeds policy count, so some policies carry MORE than one open row —
    -- the QUALIFY backstop below is load-bearing, not decorative.
    SELECT
        PolicyStats.PLCY_NUM
        , PolicyStats.PRIOR_PLCY
        , PolicyStats.SRC_SYS
        , PolicyStats.SRC_TRANS_TMSP
    FROM {{ source('fdr', 'fdr_mdm_plcy_stats') }} AS PolicyStats
    WHERE PolicyStats.END_DT_TMSP = '2999-12-31'::TIMESTAMP_NTZ
    {% if is_incremental() %}
    AND PolicyStats.PLCY_NUM IN (
        SELECT DISTINCT PolicyStatsNew.PLCY_NUM
        FROM {{ source('fdr', 'fdr_mdm_plcy_stats') }} AS PolicyStatsNew
        WHERE PolicyStatsNew.SRC_TRANS_TMSP > (
            SELECT COALESCE(MAX(PolicyRawPrev.Policy:SystemIds:LastPolicyStatsTmsp::TIMESTAMP_NTZ), '1900-01-01'::TIMESTAMP_NTZ)
            FROM {{ this }} AS PolicyRawPrev
        )
    )
    {% endif %}
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY PolicyStats.PLCY_NUM
        ORDER BY PolicyStats.SRC_TRANS_TMSP DESC, PolicyStats.STRT_DT_TMSP DESC
    ) = 1
)

, PolicyMonthlyHistory AS (
    SELECT
        PolicySnapshot.EXT_POL_SFX_CONCAT_CD AS PLCY_CNTRCT_NUM
        , ARRAY_AGG(
            OBJECT_CONSTRUCT_KEEP_NULL(
                'LoadYearMonthNum', CAST(REPLACE(PolicySnapshot.SNAP_YR_MO_CD, '-', '') AS NUMBER),
                'LineOfBusiness', UPPER(PolicySnapshot.LOB_NM),
                'InceptionDate', CAST(PolicySnapshot.ORIG_EFF_DT AS DATE),
                'CancellationDate', CAST(PolicySnapshot.POL_CANC_EFF_DT AS DATE),
                'PriorPolicy', CAST(IFF(PolicySnapshot.TRM_TYP_DSCR = 'New Business', NULL, 'PRIOR') AS VARCHAR)
            )
        ) WITHIN GROUP (ORDER BY PolicySnapshot.SNAP_YR_MO_CD) AS MonthlySnapshots
    FROM {{ source('rten', 'tfrdb_fws_pol_snap_mthly_rpt') }} AS PolicySnapshot
    {% if is_incremental() %}
    WHERE PolicySnapshot.EXT_POL_SFX_CONCAT_CD IN (
        -- Policies with a monthly snapshot in the last 3 months (self-healing
        -- lookback, anchored to data not wall clock — see Issue #5), UNION
        -- policies whose xlob/PolicyStats watermarks already flagged them as
        -- changed this run (reuses the same driving signal as Issues #3/#4
        -- so this CTE stays in sync with why the rest of the row is being
        -- rebuilt in the first place).
        SELECT DISTINCT PolicySnapshotRecent.EXT_POL_SFX_CONCAT_CD
        FROM {{ source('rten', 'tfrdb_fws_pol_snap_mthly_rpt') }} AS PolicySnapshotRecent
        WHERE PolicySnapshotRecent.SNAP_YR_MO_CD >= TO_CHAR(
            DATEADD('month', -3, CURRENT_DATE), 'YYYY-MM'
        )
    )
    {% endif %}
    GROUP BY PolicySnapshot.EXT_POL_SFX_CONCAT_CD
)

SELECT
    BASE64_ENCODE(SHA2(Policy.PLCY_CNTRCT_NUM, 256)) AS ID

    -- Typed-OBJECT entity: one outer ::OBJECT cast, inner values untyped.
    -- Nested OBJECT_CONSTRUCT_KEEP_NULL stays untyped per the proven pattern.
    -- Access: Policy:BusinessEntity  (typed → no ::VARCHAR cast needed).
    , OBJECT_CONSTRUCT_KEEP_NULL(
        'BusinessEntity', Policy.BUS_ENTITY,
        'LineOfBusinessCode', Policy.LOB_TYP_CD,
        'PolicyStateCode', Policy.PLCY_ST_CD,
        'PolicyNumber', CAST(Policy.PLCY_CNTRCT_NUM AS VARCHAR),
        'ServiceChannelCode', Policy.SRVD_CHNL_CD,
        'AgentOfRecordNumber', Policy.AGT_OF_RECRD_NUM,
        'PolicyInceptionDate', CAST(Policy.PLCY_INCEPT_DT AS DATE),
        'CancellationDate', CAST(Policy.CNCL_DT AS DATE),
        'PriorPolicyIndicator', PolicyStats.PRIOR_PLCY,
        'SourceSystemCode', COALESCE(LatestTransaction.SourceSystemCode, PolicyStats.SRC_SYS),
        'ZipCode', LatestTransaction.ZipCode,
        'SystemIds', OBJECT_CONSTRUCT_KEEP_NULL(
            'RtenPlcyCntrctNum', CAST(Policy.PLCY_CNTRCT_NUM AS VARCHAR),
            'FdrPlcyNum', CAST(PolicyStats.PLCY_NUM AS VARCHAR),
            'LastTransactionTmsp', CAST(LatestTransaction.LatestTransactionTimestamp AS VARCHAR),
            'LastPolicyStatsTmsp', CAST(PolicyStats.SRC_TRANS_TMSP AS VARCHAR)
        ),
        'MonthlySnapshots', COALESCE(
            PolicyMonthlyHistory.MonthlySnapshots,
            ARRAY_CONSTRUCT()
        )
    )::OBJECT(
        BusinessEntity        VARCHAR,
        LineOfBusinessCode    VARCHAR,
        PolicyStateCode       VARCHAR,
        PolicyNumber          VARCHAR,
        ServiceChannelCode    VARCHAR,
        AgentOfRecordNumber   VARCHAR,
        PolicyInceptionDate   DATE,
        CancellationDate      DATE,
        PriorPolicyIndicator  VARCHAR,
        SourceSystemCode      VARCHAR,
        ZipCode               VARCHAR,
        SystemIds             OBJECT(RtenPlcyCntrctNum VARCHAR, FdrPlcyNum VARCHAR, LastTransactionTmsp VARCHAR, LastPolicyStatsTmsp VARCHAR),
        MonthlySnapshots      ARRAY(OBJECT(LoadYearMonthNum NUMBER, LineOfBusiness VARCHAR, InceptionDate DATE, CancellationDate DATE, PriorPolicy VARCHAR))
      ) AS Policy

FROM {{ source('rten', 'rten_xcmpy_pif_tbl') }} AS Policy
LEFT JOIN CurrentPolicyStats AS PolicyStats
    ON Policy.PLCY_CNTRCT_NUM = PolicyStats.PLCY_NUM
LEFT JOIN LatestTransaction
    ON Policy.PLCY_CNTRCT_NUM = LatestTransaction.PLCY_CNTRCT_NUM
LEFT JOIN PolicyMonthlyHistory
    ON Policy.PLCY_CNTRCT_NUM = PolicyMonthlyHistory.PLCY_CNTRCT_NUM
