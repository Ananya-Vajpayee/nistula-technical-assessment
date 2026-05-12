-- =============================================================================
-- Nistula Unified Messaging Platform — PostgreSQL Schema
-- =============================================================================
-- Design goals:
--   1. One guest record per real person, regardless of how many channels
--      they contact us through (WhatsApp, Airbnb, Booking.com, etc.)
--   2. All messages — inbound and outbound, from every channel — in a
--      single `messages` table. No per-channel tables.
--   3. Messages are grouped into conversations, which are optionally
--      linked to a reservation.
--   4. Every AI-processed message has a full audit trail: what was
--      classified, what was drafted, what confidence was assigned,
--      whether an agent edited it, and what was ultimately sent.
--   5. Schema is append-only friendly — nothing is deleted, only
--      soft-deleted or superseded.
-- =============================================================================

-- Enable UUID generation (Postgres 13+: gen_random_uuid() is built-in)
-- For older versions: CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- -----------------------------------------------------------------------------
-- ENUM TYPES
-- Keep these narrow — easier to extend than to restrict later.
-- -----------------------------------------------------------------------------

CREATE TYPE channel_source AS ENUM (
    'whatsapp',
    'booking_com',
    'airbnb',
    'instagram',
    'direct',
    'email',          -- anticipated near-future channel
    'sms'             -- anticipated near-future channel
);

CREATE TYPE message_direction AS ENUM (
    'inbound',        -- guest → Nistula
    'outbound'        -- Nistula → guest
);

CREATE TYPE query_type AS ENUM (
    'pre_sales_availability',
    'pre_sales_pricing',
    'post_sales_checkin',
    'special_request',
    'complaint',
    'general_enquiry'
);

-- How the outbound message came to exist and how it was sent
CREATE TYPE message_status AS ENUM (
    'ai_drafted',       -- Claude produced a draft; not yet reviewed
    'agent_edited',     -- agent modified the AI draft before sending
    'agent_composed',   -- agent wrote from scratch, no AI involvement
    'auto_sent',        -- sent automatically (confidence >= 0.85)
    'agent_sent',       -- agent reviewed and manually sent
    'escalated',        -- routed to human; no reply sent yet
    'failed'            -- delivery attempted but failed
);

CREATE TYPE reservation_status AS ENUM (
    'enquiry',
    'tentative',
    'confirmed',
    'checked_in',
    'checked_out',
    'cancelled',
    'no_show'
);

-- -----------------------------------------------------------------------------
-- PROPERTIES
-- -----------------------------------------------------------------------------

CREATE TABLE properties (
    property_id     TEXT        PRIMARY KEY,           -- e.g. 'villa-b1'
    name            TEXT        NOT NULL,              -- 'Villa B1'
    location        TEXT        NOT NULL,              -- 'Assagao, North Goa'
    bedrooms        SMALLINT    NOT NULL,
    max_guests      SMALLINT    NOT NULL,
    base_rate_inr   NUMERIC(10,2) NOT NULL,            -- per night, up to base_occupancy
    base_occupancy  SMALLINT    NOT NULL DEFAULT 4,    -- guests included in base_rate
    extra_guest_rate_inr NUMERIC(10,2),               -- per extra guest per night
    checkin_time    TIME        NOT NULL DEFAULT '14:00',
    checkout_time   TIME        NOT NULL DEFAULT '11:00',
    amenities       JSONB,                             -- flexible: pool, chef, caretaker hrs…
    is_active       BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE properties IS
    'One row per bookable villa or property unit.';
COMMENT ON COLUMN properties.amenities IS
    'Flexible JSON for property features: {"pool": true, "wifi_password": "...", '
    '"caretaker_hours": "8am-10pm", "chef_on_call": true}';


-- -----------------------------------------------------------------------------
-- GUESTS
-- -----------------------------------------------------------------------------
-- Design decision: one row per real human being.
-- A guest may contact us through WhatsApp today and Booking.com tomorrow.
-- We do NOT create two guest records — we create one guest + two
-- guest_channel_identities. This is the hardest deduplication problem;
-- see thinking.md for the full reasoning.
-- -----------------------------------------------------------------------------

CREATE TABLE guests (
    guest_id        UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    full_name       TEXT        NOT NULL,
    -- Contact fields are nullable because we may only know one of them
    -- depending on first-contact channel. They are filled in over time.
    email           TEXT        UNIQUE,
    phone           TEXT        UNIQUE,
    nationality     TEXT,
    preferred_language TEXT     DEFAULT 'en',
    notes           TEXT,                              -- freeform agent notes
    is_vip          BOOLEAN     NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE guests IS
    'One record per real guest, across all contact channels. '
    'Channel-specific IDs live in guest_channel_identities.';


-- -----------------------------------------------------------------------------
-- GUEST CHANNEL IDENTITIES
-- -----------------------------------------------------------------------------
-- Maps a channel-specific identifier (e.g. a WhatsApp number, an Airbnb
-- user ID, a Booking.com reservation holder ID) to a canonical guest.
-- One guest can have many identities; one identity maps to exactly one guest.
-- -----------------------------------------------------------------------------

CREATE TABLE guest_channel_identities (
    identity_id     UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    guest_id        UUID        NOT NULL REFERENCES guests(guest_id) ON DELETE RESTRICT,
    source          channel_source NOT NULL,
    -- The identifier as the external platform provides it
    -- e.g. '+919876543210' for WhatsApp, 'airbnb_uid_9923' for Airbnb
    external_id     TEXT        NOT NULL,
    display_name    TEXT,                              -- name on that channel
    metadata        JSONB,                             -- channel-specific extra data
    verified        BOOLEAN     NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE (source, external_id)                       -- one identity per channel
);

COMMENT ON TABLE guest_channel_identities IS
    'Maps channel-specific IDs (WhatsApp numbers, Airbnb UIDs, etc.) '
    'to a canonical guest record. Supports many-to-one: one guest, many channels.';


-- -----------------------------------------------------------------------------
-- RESERVATIONS
-- -----------------------------------------------------------------------------

CREATE TABLE reservations (
    reservation_id  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    reference       TEXT        UNIQUE NOT NULL,       -- 'NIS-2024-0891'
    guest_id        UUID        NOT NULL REFERENCES guests(guest_id) ON DELETE RESTRICT,
    property_id     TEXT        NOT NULL REFERENCES properties(property_id) ON DELETE RESTRICT,
    source          channel_source NOT NULL,           -- channel through which booking was made
    status          reservation_status NOT NULL DEFAULT 'enquiry',
    checkin_date    DATE        NOT NULL,
    checkout_date   DATE        NOT NULL,
    num_guests      SMALLINT    NOT NULL,
    total_amount_inr NUMERIC(12,2),
    special_requests TEXT,
    internal_notes  TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT checkout_after_checkin CHECK (checkout_date > checkin_date),
    CONSTRAINT positive_guests CHECK (num_guests > 0)
);

COMMENT ON TABLE reservations IS
    'A confirmed or in-progress booking. Pre-sales conversations exist '
    'without a reservation; the FK is added once a booking is made.';


-- -----------------------------------------------------------------------------
-- CONVERSATIONS
-- -----------------------------------------------------------------------------
-- A conversation is a thread — a logical grouping of messages about
-- one topic between one guest and Nistula. It may span multiple channels
-- (e.g. initial WhatsApp enquiry followed up by email).
-- Optionally linked to a reservation once one exists.
-- -----------------------------------------------------------------------------

CREATE TABLE conversations (
    conversation_id UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    guest_id        UUID        NOT NULL REFERENCES guests(guest_id) ON DELETE RESTRICT,
    reservation_id  UUID        REFERENCES reservations(reservation_id) ON DELETE SET NULL,
    property_id     TEXT        REFERENCES properties(property_id) ON DELETE SET NULL,
    -- Primary channel of the conversation (can evolve over time — see messages)
    primary_source  channel_source NOT NULL,
    subject         TEXT,                              -- e.g. 'April 20-24 availability enquiry'
    is_open         BOOLEAN     NOT NULL DEFAULT TRUE,
    assigned_agent_id UUID,                            -- FK to a staff/users table (out of scope here)
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    closed_at       TIMESTAMPTZ
);

CREATE INDEX idx_conversations_guest     ON conversations(guest_id);
CREATE INDEX idx_conversations_reservation ON conversations(reservation_id);

COMMENT ON TABLE conversations IS
    'A thread grouping related messages. One conversation can span multiple '
    'channels. Linked to a reservation once a booking exists.';


-- -----------------------------------------------------------------------------
-- MESSAGES
-- -----------------------------------------------------------------------------
-- The central table. Every message ever sent or received — regardless of
-- channel, direction, or whether AI was involved — lands here.
-- AI processing details live in ai_processing_log to keep this table lean.
-- -----------------------------------------------------------------------------

CREATE TABLE messages (
    message_id      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID        NOT NULL REFERENCES conversations(conversation_id) ON DELETE RESTRICT,
    guest_id        UUID        NOT NULL REFERENCES guests(guest_id) ON DELETE RESTRICT,

    -- Channel and direction
    source          channel_source NOT NULL,
    direction       message_direction NOT NULL,

    -- The actual content
    body            TEXT        NOT NULL,

    -- Status only meaningful for outbound messages
    status          message_status,

    -- For inbound: the external platform's own message ID (for deduplication)
    external_message_id TEXT,

    -- Timestamps
    sent_at         TIMESTAMPTZ,                       -- when it left or arrived externally
    received_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),-- when our system ingested it

    -- Soft delete — never hard-delete messages
    is_deleted      BOOLEAN     NOT NULL DEFAULT FALSE,
    deleted_at      TIMESTAMPTZ,

    CONSTRAINT external_id_unique_per_source UNIQUE (source, external_message_id)
);

CREATE INDEX idx_messages_conversation  ON messages(conversation_id);
CREATE INDEX idx_messages_guest         ON messages(guest_id);
CREATE INDEX idx_messages_received_at   ON messages(received_at DESC);

COMMENT ON TABLE messages IS
    'All messages in the system — inbound and outbound, every channel. '
    'AI processing details are stored in ai_processing_log (one-to-one with inbound messages).';
COMMENT ON COLUMN messages.status IS
    'NULL for inbound messages. For outbound: how it was created and sent.';
COMMENT ON COLUMN messages.external_message_id IS
    'The ID the originating platform assigned (e.g. WhatsApp message SID). '
    'Used for deduplication on duplicate webhook delivery.';


-- -----------------------------------------------------------------------------
-- AI PROCESSING LOG
-- -----------------------------------------------------------------------------
-- One row per inbound message that was passed through the AI pipeline.
-- Stores everything needed to audit, retrain, and improve the system:
--   - what was classified
--   - what confidence was assigned
--   - what the AI drafted
--   - whether an agent changed it before sending
--   - which message was ultimately sent in reply
-- -----------------------------------------------------------------------------

CREATE TABLE ai_processing_log (
    log_id              UUID    PRIMARY KEY DEFAULT gen_random_uuid(),

    -- The inbound message that triggered AI processing
    inbound_message_id  UUID    NOT NULL UNIQUE
                                REFERENCES messages(message_id) ON DELETE RESTRICT,

    -- The outbound message that was sent (NULL until actually sent)
    outbound_message_id UUID    REFERENCES messages(message_id) ON DELETE SET NULL,

    -- Classification
    query_type          query_type NOT NULL,
    classification_model TEXT   NOT NULL DEFAULT 'claude-sonnet-4-20250514',

    -- Confidence and routing decision at time of processing
    confidence_score    NUMERIC(4,3) NOT NULL                  -- 0.000 – 1.000
                        CHECK (confidence_score BETWEEN 0 AND 1),
    action_taken        message_status NOT NULL,               -- auto_sent / agent_review / escalated

    -- The AI draft as returned by Claude (before any agent edits)
    ai_draft            TEXT    NOT NULL,
    drafting_model      TEXT    NOT NULL DEFAULT 'claude-sonnet-4-20250514',

    -- What was actually sent (may differ from ai_draft if agent edited)
    final_text          TEXT,

    -- Was the AI draft modified before sending?
    was_edited          BOOLEAN NOT NULL DEFAULT FALSE,
    edit_summary        TEXT,                                  -- optional agent note on what changed

    -- Who reviewed / sent it (NULL if auto_sent)
    reviewed_by_agent_id UUID,

    -- Timing
    processed_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    reviewed_at         TIMESTAMPTZ,
    sent_at             TIMESTAMPTZ
);

CREATE INDEX idx_ai_log_inbound     ON ai_processing_log(inbound_message_id);
CREATE INDEX idx_ai_log_query_type  ON ai_processing_log(query_type);
CREATE INDEX idx_ai_log_confidence  ON ai_processing_log(confidence_score);
CREATE INDEX idx_ai_log_action      ON ai_processing_log(action_taken);

COMMENT ON TABLE ai_processing_log IS
    'Full audit trail for every AI-processed inbound message. '
    'Tracks classification, confidence, the raw AI draft, any agent edits, '
    'and the final text sent. Designed to support retraining and QA workflows.';
COMMENT ON COLUMN ai_processing_log.was_edited IS
    'TRUE if an agent modified ai_draft before sending. '
    'Useful for identifying cases where AI confidence was high but draft was wrong.';
COMMENT ON COLUMN ai_processing_log.confidence_score IS
    'Score from 0 to 1. >=0.85 → auto_sent, 0.60-0.84 → agent_review, <0.60 → escalated. '
    'Complaints are always escalated regardless of score.';


-- =============================================================================
-- VIEWS — convenience queries
-- =============================================================================

-- Full message view joining the most commonly needed context
CREATE VIEW v_messages_full AS
SELECT
    m.message_id,
    m.conversation_id,
    m.source,
    m.direction,
    m.body,
    m.status,
    m.received_at,
    m.sent_at,
    g.guest_id,
    g.full_name          AS guest_name,
    g.email              AS guest_email,
    c.reservation_id,
    r.reference          AS booking_ref,
    c.property_id,
    -- AI fields (NULL for non-AI-processed or outbound messages)
    ai.query_type,
    ai.confidence_score,
    ai.action_taken,
    ai.was_edited,
    ai.ai_draft,
    ai.final_text
FROM messages m
JOIN guests g        ON g.guest_id        = m.guest_id
JOIN conversations c ON c.conversation_id = m.conversation_id
LEFT JOIN reservations r
                     ON r.reservation_id  = c.reservation_id
LEFT JOIN ai_processing_log ai
                     ON ai.inbound_message_id = m.message_id
WHERE m.is_deleted = FALSE;

COMMENT ON VIEW v_messages_full IS
    'Convenience view joining messages with guest, conversation, reservation, '
    'and AI processing data. Excludes soft-deleted messages.';


-- How well is the AI performing? Rolling 7-day accuracy summary
CREATE VIEW v_ai_performance_7d AS
SELECT
    query_type,
    COUNT(*)                                           AS total,
    ROUND(AVG(confidence_score)::NUMERIC, 3)          AS avg_confidence,
    COUNT(*) FILTER (WHERE action_taken = 'auto_sent')  AS auto_sent,
    COUNT(*) FILTER (WHERE action_taken = 'agent_sent'
                       AND was_edited = FALSE)         AS agent_sent_unchanged,
    COUNT(*) FILTER (WHERE was_edited = TRUE)          AS agent_edited,
    COUNT(*) FILTER (WHERE action_taken = 'escalated') AS escalated
FROM ai_processing_log
WHERE processed_at >= NOW() - INTERVAL '7 days'
GROUP BY query_type
ORDER BY total DESC;

COMMENT ON VIEW v_ai_performance_7d IS
    'Rolling 7-day AI performance breakdown by query type. '
    'Key metric: agent_edited / total = % of cases where the AI was wrong '
    'but confidence was high enough to require human correction.';


-- =============================================================================
-- DESIGN DECISIONS
-- =============================================================================
--
-- 1. GUEST DEDUPLICATION (hardest decision — see thinking.md for full discussion)
--    The guests table holds one row per real person. Channel-specific identifiers
--    live in guest_channel_identities. This means the same guest booking via
--    WhatsApp and later via Booking.com can be linked to one record — but it
--    requires a deduplication step at ingest time. We can't rely on the
--    platform to provide a consistent ID; matching logic (phone number, email,
--    name+dates) needs to be built into the ingestion layer. The schema supports
--    this without forcing premature merges — a guest can exist with multiple
--    unmerged identities until a human or confident matcher resolves them.
--
-- 2. MESSAGES AS A SINGLE TABLE
--    All channels share one messages table rather than having per-channel
--    tables (e.g. whatsapp_messages, airbnb_messages). This keeps queries
--    simple ("show me all messages for this guest"), avoids JOIN hell, and
--    makes adding a new channel (email, SMS) a non-event — just a new
--    channel_source enum value. The trade-off: channel-specific metadata
--    (e.g. WhatsApp reaction emojis, Booking.com thread IDs) is stored in
--    JSONB on the conversation or can be added to a channel_metadata column
--    if needed.
--
-- 3. AI AUDIT AS A SEPARATE TABLE
--    ai_processing_log is intentionally separate from messages rather than
--    extra columns on messages. Reasons: (a) most messages don't go through
--    AI (outbound agent-composed messages, system messages); (b) the log has
--    a richer shape than message metadata — it has two message FKs, timing
--    across multiple events, and edit tracking; (c) it's the foundation for
--    a future retraining pipeline that reads only from this table.
--
-- 4. SOFT DELETES ONLY
--    Messages are never hard-deleted (is_deleted flag). This satisfies
--    audit requirements, lets us reconstruct dispute histories, and avoids
--    orphaned FK rows. Guests and reservations use ON DELETE RESTRICT for
--    the same reason — data is only archived, never destroyed.
--
-- 5. RESERVATIONS ARE OPTIONAL ON CONVERSATIONS
--    A conversation can exist before a reservation (pre-sales enquiry) and
--    the FK is filled in later when a booking is made. This avoids forcing
--    a NULL reservation_id FK on all pre-sales threads while still allowing
--    the link once it exists.
-- =============================================================================

-- =============================================================================
-- THE HARDEST DESIGN DECISION
-- =============================================================================
--
-- The hardest decision was guest deduplication — specifically, how to represent
-- one real human being who contacts us through multiple channels. A guest might
-- enquire via WhatsApp today and book via Airbnb tomorrow. The naive approach
-- (one guest record per contact) creates duplicates that are painful to merge
-- later because merges have write-amplification consequences across reservations,
-- messages, and conversations.
--
-- The solution was to separate identity from personhood: the `guests` table holds
-- one row per real human, and `guest_channel_identities` maps each platform ID
-- (WhatsApp number, Airbnb UID, Booking.com ID) to that canonical guest. This
-- means deduplication logic runs at ingest time using a confidence hierarchy:
-- exact phone match → auto-merge, exact email match → auto-merge, name + dates
-- → flag for agent review, name only → create new record as potential duplicate.
-- This is preferable to premature merging — the schema supports unresolved
-- identities gracefully, and the matching logic can improve over time without
-- any schema changes.
-- =============================================================================