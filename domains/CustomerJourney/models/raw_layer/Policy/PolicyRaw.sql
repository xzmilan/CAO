-- RAW ENTITY: Policy (FULL DEFINITION)
-- Grain: one row per policy × line of business (RTEN_XCMPY_PIF_TBL)
-- ID: hashed primary key — BASE64_ENCODE(SHA2(natural key, 256))
--   Natural key = CONCAT_WS('|', PLCY_CNTRCT_NUM, BUS_ENTITY, LOB_TYP_CD)
--   Verified 2026-08-24: PLCY_CNTRCT_NUM alone is NOT unique (840K duplicate
--   contract numbers — multi-line policies emit one row per LOB). Adding
--   LOB_TYP_CD alone is already 1:1 with the row count; BUS_ENTITY is folded
--   in for self-documenting keys (LOB codes recur across FARMERS/FWS/SPECIALTY).
-- Doctrine  1:1 business attributes are FLAT
--           TOP-LEVEL COLUMNS — no wrapping "Policy" OBJECT. System IDs
--           stay in a typed SystemIds OBJECT (never bare). 1:many detail
--           stays a typed ARRAY. This is what lets the Wide Layer use the
--           Snowflake OBJECT_CONSTRUCT(alias.*) qualified-wildcard pattern
--           instead of hand-built per-metric ::OBJECT(...) casts.
--           Nothing downstream reads the transaction or snapshot tables.
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

    WHERE
        PolicyTransaction.SRC_TRANS_TMSP > (
            SELECT COALESCE(MAX(PolicyRawPrev.SystemIds:LastTransactionTmsp::TIMESTAMP_NTZ), '1900-01-01'::TIMESTAMP_NTZ)
            FROM {{ this }} AS PolicyRawPrev
        )

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
    WHERE
        PolicyStats.END_DT_TMSP = '2999-12-31'::TIMESTAMP_NTZ

        AND PolicyStats.PLCY_NUM IN (
            SELECT DISTINCT PolicyStatsNew.PLCY_NUM
            FROM {{ source('fdr', 'fdr_mdm_plcy_stats') }} AS PolicyStatsNew
            WHERE PolicyStatsNew.SRC_TRANS_TMSP > (
                SELECT COALESCE(MAX(PolicyRawPrev.SystemIds:LastPolicyStatsTmsp::TIMESTAMP_NTZ), '1900-01-01'::TIMESTAMP_NTZ)
                FROM {{ this }} AS PolicyRawPrev
            )
        )

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
                'LoadYearMonthNum', CAST(REPLACE(PolicySnapshot.SNAP_YR_MO_CD, '-', '') AS NUMBER)
                , 'LineOfBusiness', UPPER(PolicySnapshot.LOB_NM)
                , 'InceptionDate', CAST(PolicySnapshot.ORIG_EFF_DT AS DATE)
                , 'CancellationDate', CAST(PolicySnapshot.POL_CANC_EFF_DT AS DATE)
                , 'PriorPolicy', CAST(IFF(PolicySnapshot.TRM_TYP_DSCR = 'New Business', NULL, 'PRIOR') AS VARCHAR)
            )
        ) WITHIN GROUP (ORDER BY PolicySnapshot.SNAP_YR_MO_CD) AS MonthlySnapshots
    FROM {{ source('rten', 'tfrdb_fws_pol_snap_mthly_rpt') }} AS PolicySnapshot
    GROUP BY PolicySnapshot.EXT_POL_SFX_CONCAT_CD
)

SELECT
    BASE64_ENCODE(SHA2(CONCAT_WS('|', Policy.PLCY_CNTRCT_NUM, Policy.BUS_ENTITY, Policy.LOB_TYP_CD), 256)) AS ID

    -- 1:1 business attributes — flat top-level columns, no wrapping OBJECT.
    , Policy.BUS_ENTITY AS BusinessUnit
    , Policy.LOB_TYP_CD AS LineOfBusines
    , Policy.PLCY_ST_CD AS PolicyStateCode
    , CAST(Policy.PLCY_CNTRCT_NUM AS VARCHAR) AS PolicyNumber
    , Policy.SRVD_CHNL_CD AS ServiceChannelCode
    , Policy.AGT_OF_RECRD_NUM AS AgentOfRecordNumber
    , CAST(Policy.PLCY_INCEPT_DT AS DATE) AS PolicyInceptionDate
    , CAST(Policy.CNCL_DT AS DATE) AS Cancellate
    , PolicyStats.PRIOR_PLCY AS PriorPolicyIndicator
    , COALESCE(LatestTransaction.SourceSystemCode, PolicyStats.SRC_SYS) AS SourceSystemCode
    , LatestTransaction.ZipCode AS ZipCode

    -- System IDs — quarantined in a typed OBJECT, never bare (unchanged doctrine)
    , OBJECT_CONSTRUCT_KEEP_NULL(
        'RtenPlcyCntrctNum', CAST(Policy.PLCY_CNTRCT_NUM AS VARCHAR)
        , 'FdrPlcyNum', CAST(PolicyStats.PLCY_NUM AS VARCHAR)
        , 'LastTransactionTmsp', CAST(LatestTransaction.LatestTransactionTimestamp AS VARCHAR)
        , 'LastPolicyStatsTmsp', CAST(PolicyStats.SRC_TRANS_TMSP AS VARCHAR)
    )::OBJECT(
        RtenPlcyCntrctNumRenamed VARCHAR
        , FdrPlcyNum VARCHAR
        , LastTransactionTmsp VARCHAR
        , LastPolicyStatsTmsp VARCHAR
    ) AS SystemIds

    -- 1:many detail — typed ARRAY, cast before COALESCE (unchanged doctrine)
    , COALESCE(
        PolicyMonthlyHistory.MonthlySnapshots::ARRAY (OBJECT(
            LoadYearMonthNum NUMBER
            , LineOfBusiness VARCHAR
            , InceptionDate DATE
            , CancellationDate DATE
            , PriorPolicy VARCHAR
        ))
        , ARRAY_CONSTRUCT()::ARRAY (OBJECT(
            LoadYearMonthNum NUMBER
            , LineOfBusiness VARCHAR
            , InceptionDate DATE
            , CancellationDate DATE
            , PriorPolicy VARCHAR
        ))
    ) AS MonthlySnapshots

FROM {{ source('rten', 'rten_xcmpy_pif_tbl') }} AS Policy
LEFT JOIN CurrentPolicyStats AS PolicyStats
    ON Policy.PLCY_CNTRCT_NUM = PolicyStats.PLCY_NUM
LEFT JOIN LatestTransaction
    ON Policy.PLCY_CNTRCT_NUM = LatestTransaction.PLCY_CNTRCT_NUM
LEFT JOIN PolicyMonthlyHistory
    ON Policy.PLCY_CNTRCT_NUM = PolicyMonthlyHistory.PLCY_CNTRCT_NUM
