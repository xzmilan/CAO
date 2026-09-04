-- RAW ENTITY: Contact
-- Grain: one row per contact identity (APEX contact)
-- ID: hashed primary key — BASE64_ENCODE(SHA2(ApexContactId, 256))
-- Doctrine: identity grain is FIRST-CLASS. 1:1 identity/address attributes
--           are flat top-level columns — no wrapping "Contact" OBJECT.
--           Individual contact events stay nested as a typed ARRAY of
--           OBJECTs — consumers FLATTEN when they need event grain.
--           System IDs in typed OBJECTs, never bare. Semantic links carry
--           ONLY the hashed ID (hash-only doctrine).
--           THIS ENTITY IS THE CONTRACT for all contact data.
--           NEVER reads the STG_APEX view (1.76B-row dedup trap) — reads
--           PRD_BRNZ_APEX.CONTACT directly.

WITH ApexContacts AS (
    -- GRAX archive table: 1.88B rows = ~10 versions per contact.
    -- Dedup to latest non-deleted version per contact ID (182M contacts).
    SELECT
        ApexContact.ID AS ApexContactId
        , ApexContact.ACCOUNTID AS ApexAccountId
        , ApexContact.EMAIL AS PreferredEmail
        , ApexContact.PREFERRED_PHONE_NUMBER__C AS PreferredPhone
        , ApexContact.PREFERRED_PHONE_TYPE__C AS PreferredPhoneType
        , ApexContact.NAME AS ContactName
        , ApexContact.MAILINGSTREET AS MailingStreet
        , ApexContact.MAILINGCITY AS MailingCity
        , ApexContact.MAILINGSTATECODE AS MailingState
        , ApexContact.MAILINGPOSTALCODE AS MailingZip
        , ApexContact.LASTMODIFIEDDATE AS LastModifiedDate
    FROM {{ source('brnz_apex', 'contact') }} AS ApexContact
    WHERE ApexContact.ISDELETED = FALSE
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY ApexContact.ID
        ORDER BY ApexContact.GRAX__IDSEQ DESC
    ) = 1
)

, ContactSpaceEvents AS (
    SELECT
        ContactSpaceEvent.FFQ_QUOTE_ID AS FfqQuoteId
        , CAST(ContactSpaceEvent.TIMESTAMP AS TIMESTAMP_NTZ) AS ContactTimestamp
        , ContactSpaceEvent.CONTACTSPACE_CONTACT_ATTEMPTS AS ContactAttempts
        , ContactSpaceEvent.CONTACTSPACE_TOTAL_CALL_DURATION AS TotalCallDurationSeconds
        , ContactSpaceEvent.CONTACTSPACE_IS_QUALIFIED_CONTACT AS IsQualifiedContact
        , ContactSpaceEvent.CONTACTSPACE_IS_QUOTE_DISCUSSED AS IsQuoteDiscussed
        , ContactSpaceEvent.CONTACT_SOURCE_CONTACTSPACE AS SourceContactSpace
        , ContactSpaceEvent.CONTACT_SOURCE_LIVEVOX AS SourceLivevox
        , ContactSpaceEvent.CONTACT_SOURCE_DRIPS AS SourceDrips
        , ContactSpaceEvent.CONTACT_SOURCE_SFMC AS SourceSfmc
        , ContactSpaceEvent.CONTACT_SOURCE_EA_JOURNEY AS SourceEaJourney
        , ContactSpaceEvent.CONTACT_SOURCE_DBU_JOURNEY AS SourceDbuJourney
    FROM {{ source('ssrocha', 'contact_space_performance') }} AS ContactSpaceEvent
)

, PhoneOutcomes AS (
    SELECT
        PhoneOutcome.ID AS PhoneOutcomeId
        , CAST(PhoneOutcome.TIMESTAMP AS TIMESTAMP_NTZ) AS ContactTimestamp
    FROM {{ source('contactspace_prod', 'phone_outcome_recorded') }} AS PhoneOutcome
)

, AllContactEvents AS (
    SELECT
        ContactSpaceEvents.FfqQuoteId AS ContactEventId
        , 'CONTACTSPACE' AS ContactChannel
        , ContactSpaceEvents.ContactTimestamp
        , ContactSpaceEvents.ContactAttempts
        , ContactSpaceEvents.TotalCallDurationSeconds
        , ContactSpaceEvents.IsQualifiedContact
        , ContactSpaceEvents.IsQuoteDiscussed
        , ContactSpaceEvents.SourceContactSpace
        , ContactSpaceEvents.SourceLivevox
        , ContactSpaceEvents.SourceDrips
        , ContactSpaceEvents.SourceSfmc
        , ContactSpaceEvents.SourceEaJourney
        , ContactSpaceEvents.SourceDbuJourney
    FROM ContactSpaceEvents
    UNION ALL
    SELECT
        PhoneOutcomes.PhoneOutcomeId
        , 'PHONE'
        , PhoneOutcomes.ContactTimestamp
        , CAST(NULL AS NUMBER)
        , CAST(NULL AS NUMBER)
        , CAST(NULL AS BOOLEAN)
        , CAST(NULL AS BOOLEAN)
        , CAST(NULL AS VARCHAR)
        , CAST(NULL AS VARCHAR)
        , CAST(NULL AS VARCHAR)
        , CAST(NULL AS VARCHAR)
        , CAST(NULL AS VARCHAR)
        , CAST(NULL AS VARCHAR)
    FROM PhoneOutcomes
)

, ContactEventsByContact AS (
    SELECT
        ApexContacts.ApexContactId
        , ARRAY_AGG(
            OBJECT_CONSTRUCT_KEEP_NULL(
                'ContactEventId', AllContactEvents.ContactEventId
                , 'ContactChannel', AllContactEvents.ContactChannel
                , 'ContactTimestamp', AllContactEvents.ContactTimestamp
                , 'ContactAttempts', AllContactEvents.ContactAttempts
                , 'TotalCallDurationSeconds', AllContactEvents.TotalCallDurationSeconds
                , 'IsQualifiedContact', AllContactEvents.IsQualifiedContact
                , 'IsQuoteDiscussed', AllContactEvents.IsQuoteDiscussed
                , 'ContactSources', OBJECT_CONSTRUCT_KEEP_NULL(
                    'ContactSpace', AllContactEvents.SourceContactSpace
                    , 'Livevox', AllContactEvents.SourceLivevox
                    , 'Drips', AllContactEvents.SourceDrips
                    , 'Sfmc', AllContactEvents.SourceSfmc
                    , 'EaJourney', AllContactEvents.SourceEaJourney
                    , 'DbuJourney', AllContactEvents.SourceDbuJourney
                )
            )
        ) WITHIN GROUP (ORDER BY AllContactEvents.ContactTimestamp) AS ContactEvents
    FROM ApexContacts
    LEFT JOIN AllContactEvents
    -- TODO: join key TBD — need to map FFQ_QUOTE_ID or phone/email
        -- to APEX contact. This is the diagnosis target.
        ON FALSE
    GROUP BY ApexContacts.ApexContactId
)

SELECT
    -- 1:1 identity/address attributes — flat top-level columns, no
    -- wrapping OBJECT.
    , ApexContacts.ContactName AS ContactName
    , ApexContacts.PreferredEmail AS PreferredEmail
    , ApexContacts.PreferredPhone AS PreferredPhone
    , ApexContacts.PreferredPhoneType AS PreferredPhoneType
    , ApexContacts.MailingStreet AS MailingStreet
    , ApexContacts.MailingCity AS MailingCity
    , ApexContacts.MailingState AS MailingState
    , ApexContacts.MailingZip AS MailingZip

    -- 1:many detail — typed ARRAY, cast before COALESCE.
    , COALESCE(
        ContactEventsByContact.ContactEvents::ARRAY(OBJECT(
            ContactEventId VARCHAR
            , ContactChannel VARCHAR
            , ContactTimestamp TIMESTAMP_NTZ
            , ContactAttempts NUMBER
            , TotalCallDurationSeconds NUMBER
            , IsQualifiedContact BOOLEAN
            , IsQuoteDiscussed BOOLEAN
            , ContactSources OBJECT(ContactSpace VARCHAR, Livevox VARCHAR, Drips VARCHAR, Sfmc VARCHAR, EaJourney VARCHAR, DbuJourney VARCHAR)
        ))
        , ARRAY_CONSTRUCT()::ARRAY(OBJECT(
            ContactEventId VARCHAR
            , ContactChannel VARCHAR
            , ContactTimestamp TIMESTAMP_NTZ
            , ContactAttempts NUMBER
            , TotalCallDurationSeconds NUMBER
            , IsQualifiedContact BOOLEAN
            , IsQuoteDiscussed BOOLEAN
            , ContactSources OBJECT(ContactSpace VARCHAR, Livevox VARCHAR, Drips VARCHAR, Sfmc VARCHAR, EaJourney VARCHAR, DbuJourney VARCHAR)
        ))
    ) AS ContactEvents

    -- System IDs — quarantined in a typed OBJECT, never bare.
    , OBJECT_CONSTRUCT_KEEP_NULL(
        'ApexContactId', ApexContacts.ApexContactId
        , 'ApexAccountId', ApexContacts.ApexAccountId
    )::OBJECT(
        ApexContactId VARCHAR
        , ApexAccountId VARCHAR
    ) AS SystemIdspexAccountId', ApexContacts.ApexAccountId
        )
    ) AS Contact
FROM ApexContacts
LEFT JOIN ContactEventsByContact
    ON ApexContacts.ApexContactId = ContactEventsByContact.ApexContactId
