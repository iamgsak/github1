-- =====================================================================
-- 0008_channels_and_integrations.sql
-- Channel manager / OTA integration, the outbound sync queue (outbox),
-- inbound webhook deduplication, notifications, and API keys.
--
-- OTA safety model -- four independent layers, all database-enforced:
--   1. webhook_events(provider, event_id) UNIQUE
--        the same webhook delivery can only be accepted once
--   2. ota_reservations(channel_id, external_reservation_id) UNIQUE
--        one OTA booking maps to at most one row, ever
--   3. reservations(property, channel, external_reference) UNIQUE
--        that row maps to at most one reservation
--   4. room_allocations exclusion constraint (0003)
--        even if all of the above were bypassed, the room cannot be
--        committed twice
--
-- NO CREDENTIAL IS STORED IN PLAINTEXT. integration_credentials holds
-- application-encrypted ciphertext; the key lives in KMS/env and never
-- reaches the database or the browser.
-- =====================================================================

CREATE TYPE channel_type      AS ENUM ('OTA','CHANNEL_MANAGER','GDS','METASEARCH','CORPORATE_PORTAL');
CREATE TYPE integration_mode  AS ENUM ('MOCK','SANDBOX','PRODUCTION');
CREATE TYPE connection_status AS ENUM ('NOT_CONFIGURED','CONNECTED','ERROR','DISABLED','EXPIRED');
CREATE TYPE sync_type AS ENUM (
  'AVAILABILITY','RATES','RESTRICTIONS','RESERVATIONS','INVENTORY_FULL','MAPPING','TEST'
);
CREATE TYPE sync_direction AS ENUM ('PUSH','PULL');
CREATE TYPE sync_status    AS ENUM ('STARTED','SUCCESS','PARTIAL','FAILED','SKIPPED');
CREATE TYPE job_status     AS ENUM ('PENDING','PROCESSING','SUCCESS','FAILED','DEAD','CANCELLED');
CREATE TYPE notification_channel AS ENUM ('EMAIL','SMS','WHATSAPP','IN_APP','PUSH');
CREATE TYPE notification_status  AS ENUM ('QUEUED','SENDING','SENT','DELIVERED','FAILED','READ','CANCELLED');

-- `adapter` selects the code module that talks to this channel. Adding a
-- new OTA means adding an adapter, not changing any table.
CREATE TABLE channels (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id             uuid NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
  code                    text NOT NULL,
  name                    text NOT NULL,
  channel_type            channel_type NOT NULL DEFAULT 'OTA',
  adapter                 text NOT NULL,
  mode                    integration_mode NOT NULL DEFAULT 'MOCK',
  is_enabled              boolean NOT NULL DEFAULT false,
  connection_status       connection_status NOT NULL DEFAULT 'NOT_CONFIGURED',
  external_property_id    text,
  commission_percent      numeric(5,2) NOT NULL DEFAULT 0,
  -- Who takes the guest's money: the OTA (collect) or the hotel.
  payment_model           text NOT NULL DEFAULT 'HOTEL_COLLECT',
  booking_source_id       uuid REFERENCES booking_sources(id) ON DELETE SET NULL,
  commission_account_id   uuid REFERENCES accounts(id) ON DELETE RESTRICT,
  sync_settings           jsonb NOT NULL DEFAULT '{}'::jsonb,
  sync_horizon_days       integer NOT NULL DEFAULT 365,
  auto_sync_enabled       boolean NOT NULL DEFAULT false,
  last_sync_at            timestamptz,
  last_sync_status        sync_status,
  last_successful_sync_at timestamptz,
  last_error              text,
  last_error_at           timestamptz,
  consecutive_failures    integer NOT NULL DEFAULT 0,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT channels_uq UNIQUE (property_id, code),
  CONSTRAINT channels_commission_chk CHECK (commission_percent BETWEEN 0 AND 100),
  CONSTRAINT channels_payment_model_chk CHECK (payment_model IN ('HOTEL_COLLECT','OTA_COLLECT','MIXED')),
  CONSTRAINT channels_horizon_chk CHECK (sync_horizon_days BETWEEN 1 AND 730),
  -- A channel cannot be switched on until it is actually configured.
  CONSTRAINT channels_enabled_chk CHECK (
    NOT is_enabled OR connection_status IN ('CONNECTED','ERROR')),
  -- Guard against a mock adapter ever being presented as a live channel.
  CONSTRAINT channels_mock_chk CHECK ((mode = 'MOCK') = (adapter LIKE 'MOCK_%'))
);
CREATE INDEX channels_property_idx ON channels(property_id) WHERE is_enabled;

ALTER TABLE booking_sources
  ADD CONSTRAINT booking_sources_channel_fk
  FOREIGN KEY (channel_id) REFERENCES channels(id) ON DELETE SET NULL;
ALTER TABLE reservations
  ADD CONSTRAINT reservations_channel_fk
  FOREIGN KEY (channel_id) REFERENCES channels(id) ON DELETE SET NULL;

-- The database stores ciphertext only; key_id names the KMS key or env
-- key version used, so keys rotate without data loss.
CREATE TABLE integration_credentials (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id      uuid NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
  integration_type text NOT NULL,
  provider         text NOT NULL,
  channel_id       uuid REFERENCES channels(id) ON DELETE CASCADE,
  credential_key   text NOT NULL,
  encrypted_value  bytea NOT NULL,
  key_id           text NOT NULL,
  -- Non-secret fingerprint so the UI can show "...a3f2" without decrypting.
  value_hint       text,
  expires_at       timestamptz,
  rotated_at       timestamptz,
  created_by       uuid REFERENCES users(id),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT integration_credentials_uq UNIQUE (property_id, provider, credential_key),
  CONSTRAINT integration_credentials_type_chk CHECK (integration_type IN
    ('CHANNEL','PAYMENT_GATEWAY','EMAIL','SMS','WHATSAPP','STORAGE','ACCOUNTING','OTHER')),
  -- Defence in depth against a plaintext secret written by mistake.
  CONSTRAINT integration_credentials_hint_chk CHECK (value_hint IS NULL OR length(value_hint) <= 8)
);

-- Bidirectional uniqueness: no ambiguity in either translation
-- direction, so an inbound booking always resolves to one room type.
CREATE TABLE channel_room_mappings (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id         uuid NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
  room_type_id       uuid NOT NULL REFERENCES room_types(id) ON DELETE CASCADE,
  external_room_id   text NOT NULL,
  external_room_name text,
  is_active          boolean NOT NULL DEFAULT true,
  created_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT channel_room_mappings_ext_uq UNIQUE (channel_id, external_room_id),
  CONSTRAINT channel_room_mappings_int_uq UNIQUE (channel_id, room_type_id)
);

CREATE TABLE channel_rate_mappings (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id              uuid NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
  rate_plan_id            uuid NOT NULL REFERENCES rate_plans(id) ON DELETE CASCADE,
  room_type_id            uuid NOT NULL REFERENCES room_types(id) ON DELETE CASCADE,
  external_rate_plan_id   text NOT NULL,
  external_rate_plan_name text,
  is_active               boolean NOT NULL DEFAULT true,
  created_at              timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT channel_rate_mappings_ext_uq UNIQUE (channel_id, external_rate_plan_id, room_type_id),
  CONSTRAINT channel_rate_mappings_int_uq UNIQUE (channel_id, rate_plan_id, room_type_id)
);

-- The raw payload is landed FIRST and processed second, so a parsing bug
-- never loses a booking -- it can be replayed from raw_payload.
CREATE TABLE ota_reservations (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id             uuid NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
  channel_id              uuid NOT NULL REFERENCES channels(id) ON DELETE RESTRICT,
  external_reservation_id text NOT NULL,
  external_status         text,
  external_version        integer NOT NULL DEFAULT 1,
  external_modified_at    timestamptz,
  raw_payload             jsonb NOT NULL,
  -- Hash of the payload: an identical redelivery is detected as a no-op.
  payload_checksum        text NOT NULL,
  reservation_id          uuid REFERENCES reservations(id) ON DELETE SET NULL,
  processing_status       text NOT NULL DEFAULT 'RECEIVED',
  error_message           text,
  retry_count             integer NOT NULL DEFAULT 0,
  received_at             timestamptz NOT NULL DEFAULT now(),
  processed_at            timestamptz,
  acknowledged_at         timestamptz,
  -- *** Layer 2 of OTA safety ***
  CONSTRAINT ota_reservations_uq UNIQUE (channel_id, external_reservation_id),
  CONSTRAINT ota_reservations_status_chk CHECK (processing_status IN
    ('RECEIVED','PROCESSING','PROCESSED','FAILED','IGNORED','DUPLICATE','MANUAL_REVIEW')),
  CONSTRAINT ota_reservations_processed_chk CHECK (
    processing_status <> 'PROCESSED' OR reservation_id IS NOT NULL),
  CONSTRAINT ota_reservations_failed_chk CHECK (
    processing_status <> 'FAILED' OR error_message IS NOT NULL)
);
CREATE INDEX ota_reservations_pending_idx ON ota_reservations(property_id, received_at)
  WHERE processing_status IN ('RECEIVED','FAILED');
CREATE INDEX ota_reservations_reservation_idx ON ota_reservations(reservation_id);

CREATE TABLE ota_reservation_events (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  ota_reservation_id uuid NOT NULL REFERENCES ota_reservations(id) ON DELETE CASCADE,
  event_type         text NOT NULL,
  external_version   integer,
  raw_payload        jsonb NOT NULL,
  applied            boolean NOT NULL DEFAULT false,
  applied_at         timestamptz,
  error_message      text,
  received_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ota_reservation_events_type_chk CHECK (event_type IN
    ('NEW','MODIFY','CANCEL','NO_SHOW','REACTIVATE'))
);
CREATE INDEX ota_reservation_events_res_idx ON ota_reservation_events(ota_reservation_id, received_at);

-- Webhook deduplication :: layer 1. Applies to OTA and payment-gateway
-- webhooks alike.
CREATE TABLE webhook_events (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id        uuid REFERENCES properties(id) ON DELETE CASCADE,
  provider           text NOT NULL,
  channel_id         uuid REFERENCES channels(id) ON DELETE SET NULL,
  -- The provider's own delivery/event id. This is what makes replay safe.
  event_id           text NOT NULL,
  event_type         text,
  signature          text,
  signature_verified boolean NOT NULL DEFAULT false,
  payload            jsonb NOT NULL,
  headers            jsonb,
  source_ip          inet,
  status             job_status NOT NULL DEFAULT 'PENDING',
  attempts           integer NOT NULL DEFAULT 0,
  last_error         text,
  received_at        timestamptz NOT NULL DEFAULT now(),
  processed_at       timestamptz,
  -- *** Layer 1: one delivery, one processing ***
  CONSTRAINT webhook_events_uq UNIQUE (provider, event_id),
  -- An unverified webhook must never be marked successfully processed.
  CONSTRAINT webhook_events_verified_chk CHECK (status <> 'SUCCESS' OR signature_verified)
);
CREATE INDEX webhook_events_pending_idx ON webhook_events(status, received_at)
  WHERE status IN ('PENDING','FAILED');
CREATE INDEX webhook_events_provider_idx ON webhook_events(provider, received_at DESC);

-- Outbound sync queue (transactional outbox). Inventory/rate changes
-- enqueue a job in the SAME transaction that changed the data, so a
-- crash cannot leave the OTA and the PMS disagreeing about availability.
CREATE TABLE sync_queue (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id     uuid NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
  channel_id      uuid NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
  sync_type       sync_type NOT NULL,
  direction       sync_direction NOT NULL DEFAULT 'PUSH',
  payload         jsonb NOT NULL DEFAULT '{}'::jsonb,
  -- Collapses duplicate pending jobs for the same target date range.
  dedupe_key      text,
  priority        smallint NOT NULL DEFAULT 5,
  status          job_status NOT NULL DEFAULT 'PENDING',
  attempts        integer NOT NULL DEFAULT 0,
  max_attempts    integer NOT NULL DEFAULT 5,
  next_attempt_at timestamptz NOT NULL DEFAULT now(),
  locked_at       timestamptz,
  locked_by       text,
  last_error      text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  completed_at    timestamptz,
  CONSTRAINT sync_queue_attempts_chk CHECK (attempts >= 0 AND max_attempts > 0),
  CONSTRAINT sync_queue_priority_chk CHECK (priority BETWEEN 1 AND 9)
);
-- Only one pending job per dedupe key: a burst of rate edits collapses
-- into a single push instead of hammering the OTA.
CREATE UNIQUE INDEX sync_queue_dedupe_uq ON sync_queue(channel_id, dedupe_key)
  WHERE status = 'PENDING' AND dedupe_key IS NOT NULL;
CREATE INDEX sync_queue_ready_idx ON sync_queue(next_attempt_at, priority)
  WHERE status = 'PENDING';

CREATE TABLE sync_logs (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  property_id      uuid NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
  channel_id       uuid REFERENCES channels(id) ON DELETE SET NULL,
  sync_queue_id    uuid REFERENCES sync_queue(id) ON DELETE SET NULL,
  sync_type        sync_type NOT NULL,
  direction        sync_direction NOT NULL,
  status           sync_status NOT NULL DEFAULT 'STARTED',
  date_from        date,
  date_to          date,
  records_total    integer NOT NULL DEFAULT 0,
  records_success  integer NOT NULL DEFAULT 0,
  records_failed   integer NOT NULL DEFAULT 0,
  -- Payloads are stored with credentials redacted by the adapter.
  request_payload  jsonb,
  response_payload jsonb,
  error_message    text,
  started_at       timestamptz NOT NULL DEFAULT now(),
  completed_at     timestamptz,
  duration_ms      integer,
  triggered_by     uuid REFERENCES users(id),
  CONSTRAINT sync_logs_counts_chk CHECK (
    records_total >= 0 AND records_success >= 0 AND records_failed >= 0
    AND records_success + records_failed <= records_total)
);
CREATE INDEX sync_logs_channel_time_idx ON sync_logs(channel_id, started_at DESC);
CREATE INDEX sync_logs_failed_idx ON sync_logs(property_id, started_at DESC)
  WHERE status IN ('FAILED','PARTIAL');

CREATE TABLE notification_templates (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id      uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  property_id          uuid REFERENCES properties(id) ON DELETE CASCADE,
  code                 text NOT NULL,
  channel              notification_channel NOT NULL,
  name                 text NOT NULL,
  subject_template     text,
  body_template        text NOT NULL,
  -- Declared variables, used to validate a template before it is saved.
  variables            jsonb NOT NULL DEFAULT '[]'::jsonb,
  locale               text NOT NULL DEFAULT 'en',
  -- WhatsApp template name registered with the provider, when applicable.
  provider_template_id text,
  is_active            boolean NOT NULL DEFAULT true,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT notification_templates_uq
    UNIQUE NULLS NOT DISTINCT (organization_id, property_id, code, channel, locale)
);

CREATE TABLE notifications (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id         uuid REFERENCES properties(id) ON DELETE CASCADE,
  channel             notification_channel NOT NULL,
  template_code       text,
  user_id             uuid REFERENCES users(id) ON DELETE CASCADE,
  guest_id            uuid REFERENCES guests(id) ON DELETE CASCADE,
  recipient           text,
  subject             text,
  body                text,
  payload             jsonb NOT NULL DEFAULT '{}'::jsonb,
  reference_type      text,
  reference_id        uuid,
  status              notification_status NOT NULL DEFAULT 'QUEUED',
  provider            text,
  provider_message_id text,
  error_message       text,
  retry_count         integer NOT NULL DEFAULT 0,
  scheduled_for       timestamptz NOT NULL DEFAULT now(),
  sent_at             timestamptz,
  delivered_at        timestamptz,
  read_at             timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  -- IN_APP goes to a user; every other channel needs an address.
  CONSTRAINT notifications_recipient_chk CHECK (
    (channel = 'IN_APP' AND user_id IS NOT NULL)
    OR (channel <> 'IN_APP' AND recipient IS NOT NULL)),
  CONSTRAINT notifications_sent_chk CHECK (status NOT IN ('SENT','DELIVERED') OR sent_at IS NOT NULL)
);
CREATE INDEX notifications_queue_idx ON notifications(scheduled_for) WHERE status = 'QUEUED';
CREATE INDEX notifications_user_unread_idx ON notifications(user_id, created_at DESC)
  WHERE channel = 'IN_APP' AND read_at IS NULL;
CREATE INDEX notifications_ref_idx ON notifications(reference_type, reference_id);

-- Only the hash is stored; the key itself is shown once at creation.
CREATE TABLE api_keys (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id       uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  property_id           uuid REFERENCES properties(id) ON DELETE CASCADE,
  name                  text NOT NULL,
  key_prefix            text NOT NULL,
  key_hash              text NOT NULL,
  scopes                text[] NOT NULL DEFAULT '{}',
  -- Origins allowed to use this key from a browser (booking widget).
  allowed_origins       text[],
  rate_limit_per_minute integer NOT NULL DEFAULT 60,
  last_used_at          timestamptz,
  expires_at            timestamptz,
  revoked_at            timestamptz,
  revoked_by            uuid REFERENCES users(id),
  created_by            uuid REFERENCES users(id),
  created_at            timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT api_keys_prefix_uq UNIQUE (key_prefix),
  CONSTRAINT api_keys_hash_uq UNIQUE (key_hash),
  CONSTRAINT api_keys_rate_chk CHECK (rate_limit_per_minute > 0),
  CONSTRAINT api_keys_scopes_chk CHECK (array_length(scopes, 1) > 0)
);
CREATE INDEX api_keys_active_idx ON api_keys(organization_id) WHERE revoked_at IS NULL;

CREATE TRIGGER channels_updated_at                BEFORE UPDATE ON channels                FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();
CREATE TRIGGER integration_credentials_updated_at BEFORE UPDATE ON integration_credentials FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();
CREATE TRIGGER notification_templates_updated_at  BEFORE UPDATE ON notification_templates  FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();
