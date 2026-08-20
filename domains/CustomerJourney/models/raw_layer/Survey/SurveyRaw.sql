-- RAW ENTITY: Survey
-- Grain: one row per survey campaign/invite wave (e.g., "Agent Change Jan 2026")
-- ID: hashed primary key — BASE64_ENCODE(SHA2(SurveyType || '|' || InviteWave, 256))
-- Doctrine: campaign grain is FIRST-CLASS. Individual responses are nested
--           as a typed ARRAY of OBJECTs — consumers FLATTEN when they need
--           response grain. System IDs in typed OBJECTs, never bare.
--           Semantic links carry ONLY the hashed ID (hash-only doctrine).
--           THIS ENTITY IS THE CONTRACT for all survey data.

WITH AgentChangeResponses AS (
    SELECT
        AgentChangeInvite.POLICY_NUMBER AS PolicyNumber
        , AgentChangeResponse.RESPONSEID AS ResponseId
        , CAST(AgentChangeResponse.STARTDATE AS TIMESTAMP_NTZ) AS ResponseDate
        , TRY_CAST(AgentChangeResponse.Q1 AS NUMBER) AS NpsScore
        , AgentChangeResponse.Q1A AS VerbatimText
        , TRY_CAST(AgentChangeResponse.Q4_1 AS NUMBER) AS ProcessRating1
        , TRY_CAST(AgentChangeResponse.Q4_2 AS NUMBER) AS ProcessRating2
        , TRY_CAST(AgentChangeResponse.Q4_3 AS NUMBER) AS ProcessRating3
        , TRY_CAST(AgentChangeResponse.Q4_4 AS NUMBER) AS ProcessRating4
        , TRY_CAST(AgentChangeResponse.Q4_5 AS NUMBER) AS ProcessRating5
        , TRY_CAST(AgentChangeResponse.Q4_6 AS NUMBER) AS ProcessRating6
        , AgentChangeResponse.MEET_NEEDS AS MeetsNeedsFlag
        , AgentChangeResponse.RCVD_FARMERS_LETTER AS ReceivedLetterFlag
        , AgentChangeResponse.LETTER_EFFECTIVENESS AS LetterEffectiveness
        , AgentChangeResponse.NUM_DAYS_NO_AGENT AS DaysWithoutAgent
        , AgentChangeResponse.XFER_INIT_BY AS TransferInitiatedBy
        , AgentChangeResponse.NEW_AGENT_SERIES AS NewAgentSeries
        , AgentChangeResponse.AGENT_ID AS AgentId
        , AgentChangeResponse.ECN AS Ecn
        , AgentChangeResponse.ENTPRS_HH_NUM AS HouseholdNumber
        , AgentChangeResponse.ECMS_ACCOUNT_NUMBER AS EcmsAccountNumber
    FROM {{ source('tnps', 'agtchg_invites_sent') }} AS AgentChangeInvite
    LEFT JOIN {{ source('qualtrics', 'agentchange_responses') }} AS AgentChangeResponse
        ON AgentChangeInvite.POLICY_NUMBER = AgentChangeResponse.POLICY_NUMBER_1
)

, AgentChangeCampaign AS (
    SELECT
        'AGENT_CHANGE' AS SurveyType
        , DATE_TRUNC('month', AgentChangeInvite.INVITE_PULL_DATE) AS InviteWave
        , COUNT(DISTINCT AgentChangeInvite.POLICY_NUMBER) AS InvitesSent
        , ARRAY_AGG(
            OBJECT_CONSTRUCT_KEEP_NULL(
                'ResponseId', AgentChangeResponses.ResponseId,
                'ResponseDate', AgentChangeResponses.ResponseDate,
                'NpsScore', AgentChangeResponses.NpsScore,
                'VerbatimText', AgentChangeResponses.VerbatimText,
                'ProcessRatings', OBJECT_CONSTRUCT_KEEP_NULL(
                    'Rating1', AgentChangeResponses.ProcessRating1,
                    'Rating2', AgentChangeResponses.ProcessRating2,
                    'Rating3', AgentChangeResponses.ProcessRating3,
                    'Rating4', AgentChangeResponses.ProcessRating4,
                    'Rating5', AgentChangeResponses.ProcessRating5,
                    'Rating6', AgentChangeResponses.ProcessRating6
                ),
                'AgentChangeDetails', OBJECT_CONSTRUCT_KEEP_NULL(
                    'MeetsNeedsFlag', AgentChangeResponses.MeetsNeedsFlag,
                    'ReceivedLetterFlag', AgentChangeResponses.ReceivedLetterFlag,
                    'LetterEffectiveness', AgentChangeResponses.LetterEffectiveness,
                    'DaysWithoutAgent', AgentChangeResponses.DaysWithoutAgent,
                    'TransferInitiatedBy', AgentChangeResponses.TransferInitiatedBy,
                    'NewAgentSeries', AgentChangeResponses.NewAgentSeries
                ),
                'SystemIds', OBJECT_CONSTRUCT_KEEP_NULL(
                    'PolicyNumber', AgentChangeResponses.PolicyNumber,
                    'AgentId', AgentChangeResponses.AgentId,
                    'Ecn', AgentChangeResponses.Ecn,
                    'HouseholdNumber', AgentChangeResponses.HouseholdNumber,
                    'EcmsAccountNumber', AgentChangeResponses.EcmsAccountNumber
                )
            )
        ) WITHIN GROUP (ORDER BY AgentChangeResponses.ResponseDate) AS Responses
    FROM {{ source('tnps', 'agtchg_invites_sent') }} AS AgentChangeInvite
    LEFT JOIN AgentChangeResponses
        ON AgentChangeInvite.POLICY_NUMBER = AgentChangeResponses.PolicyNumber
    {% if is_incremental() %}
    WHERE DATE_TRUNC('month', AgentChangeInvite.INVITE_PULL_DATE) >= DATEADD(
        'month', -3,
        (SELECT COALESCE(MAX(SurveyRawPrev.Survey:InviteWave::DATE), CURRENT_DATE) FROM {{ this }} AS SurveyRawPrev)
    )
    {% endif %}
    GROUP BY
        'AGENT_CHANGE'
        , DATE_TRUNC('month', AgentChangeInvite.INVITE_PULL_DATE)
)

SELECT
    BASE64_ENCODE(SHA2(AgentChangeCampaign.SurveyType || '|' || CAST(AgentChangeCampaign.InviteWave AS VARCHAR), 256)) AS ID

    , OBJECT_CONSTRUCT_KEEP_NULL(
        'SurveyType', AgentChangeCampaign.SurveyType,
        'InviteWave', CAST(AgentChangeCampaign.InviteWave AS DATE),
        'InvitesSent', AgentChangeCampaign.InvitesSent,
        'ResponseCount', ARRAY_SIZE(AgentChangeCampaign.Responses),
        'ResponseRate', DIV0(ARRAY_SIZE(AgentChangeCampaign.Responses), AgentChangeCampaign.InvitesSent),
        'Responses', AgentChangeCampaign.Responses
    ) AS Survey
FROM AgentChangeCampaign
