-- RAW ENTITY: Contact
-- Grain: one row per contact identity (APEX contact)
-- ID: hashed primary key — BASE64_ENCODE(SHA2(ApexContactId, 256))
-- Doctrine: identity grain is FIRST-CLASS. Individual contact events are
--           nested as a typed ARRAY of OBJECTs — consumers FLATTEN when
--           they need event grain. System IDs in typed OBJECTs, never bare.
--           Semantic links carry ONLY the hashed ID (hash-only doctrine).
--           THIS ENTITY IS THE CONTRACT for all contact data.
--           NEVER reads the STG_APEX view (1.76B-row dedup trap) — reads
--           PRD_BRNZ_APEX.CONTACT directly.

WITH ApexContacts AS (
    SELECT
        ApexContact.ID AS ApexContactId
        , ApexContact.ACCOUNTID AS ApexAccountId
        , ApexContact.EMAIL AS PreferredEmail
        , ApexContact.PREFERRED_PHONE_NUMBER_C AS PreferredPhone
        , ApexContact.PREFERRED_PHONE_TYPE_C AS PreferredPhoneType
        , ApexContact.CONTACT_NAME AS ContactName
        , ApexContact.MAILINGSTREET AS MailingStreet
        , ApexContact.MAILINGCITY AS MailingCity
        , ApexContact.MAILINGSTATECODE AS MailingState
        , ApexContact.MAILINGPOSTALCODE AS MailingZip
        , ApexContact.LASTMODIFIEDDATE AS LastModifiedDate
    FROM {{ source('brnz_apex', 'contact') }} AS ApexContact
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

SELECT
    BASE64_ENCODE(SHA2(ApexContacts.ApexContactId, 256)) AS ID

    , OBJECT_CONSTRUCT_KEEP_NULL(
        'Identity', OBJECT_CONSTRUCT_KEEP_NULL(
            'ApexContactId', ApexContacts.ApexContactId,
            'ApexAccountId', ApexContacts.ApexAccountId,
            'ContactName', ApexContacts.ContactName,
            'PreferredEmail', ApexContacts.PreferredEmail,
            'PreferredPhone', ApexContacts.PreferredPhone,
            'PreferredPhoneType', ApexContacts.PreferredPhoneType
        ),
        'MailingAddress', OBJECT_CONSTRUCT_KEEP_NULL(
            'Street', ApexContacts.MailingStreet,
            'City', ApexContacts.MailingCity,
            'State', ApexContacts.MailingState,
            'Zip', ApexContacts.MailingZip
        ),
        'ContactEvents', COALESCE(
            (
                SELECT ARRAY_AGG(
                    OBJECT_CONSTRUCT_KEEP_NULL(
                        'ContactEventId', AllContactEvents.ContactEventId,
                        'ContactChannel', AllContactEvents.ContactChannel,
                        'ContactTimestamp', AllContactEvents.ContactTimestamp,
                        'ContactAttempts', AllContactEvents.ContactAttempts,
                        'TotalCallDurationSeconds', AllContactEvents.TotalCallDurationSeconds,
                        'IsQualifiedContact', AllContactEvents.IsQualifiedContact,
                        'IsQuoteDiscussed', AllContactEvents.IsQuoteDiscussed,
                        'ContactSources', OBJECT_CONSTRUCT_KEEP_NULL(
                            'ContactSpace', AllContactEvents.SourceContactSpace,
                            'Livevox', AllContactEvents.SourceLivevox,
                            'Drips', AllContactEvents.SourceDrips,
                            'Sfmc', AllContactEvents.SourceSfmc,
                            'EaJourney', AllContactEvents.SourceEaJourney,
                            'DbuJourney', AllContactEvents.SourceDbuJourney
                        )
                    )
                ) WITHIN GROUP (ORDER BY AllContactEvents.ContactTimestamp)
                FROM AllContactEvents
                -- TODO: join key TBD — need to map FFQ_QUOTE_ID or phone/email
                -- to APEX contact. This is the diagnosis target.
                WHERE FALSE
            ),
            ARRAY_CONSTRUCT()
        ),
        'SystemIds', OBJECT_CONSTRUCT_KEEP_NULL(
            'ApexContactId', ApexContacts.ApexContactId,
            'ApexAccountId', ApexContacts.ApexAccountId
        )
    ) AS Contact
FROM ApexContacts
