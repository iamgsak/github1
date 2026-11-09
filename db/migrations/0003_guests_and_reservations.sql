-- =====================================================================
-- 0003_guests_and_reservations.sql
-- Guests, booking sources, reservations, per-room stay lines, the
-- nightly rate breakdown, and room_allocations -- the physical
-- room-night ledger that makes double booking impossible.
--
-- Two-layer model (standard PMS separation):
--   reservation_rooms  = COMMERCIAL line. What was sold: room type, rate
--                        plan, dates, occupancy, money. No physical room.
--   room_allocations   = PHYSICAL line. Which actual room is occupied for
--                        which date range, by a booking or by a block.
-- One reservation_room may have several allocations over its stay, which
-- is exactly how a mid-stay room move is represented without losing
-- history.
-- =====================================================================

CREATE TYPE reservation_status AS ENUM (
  'INQUIRY','PENDING','CONFIRMED','GUARANTEED','WAITLISTED',
  'CHECKED_IN','CHECKED_OUT','CANCELLED','NO_SHOW'
);

CREATE TYPE reservation_room_status AS ENUM (
  'RESERVED','CHECKED_IN','CHECKED_OUT','CANCELLED','NO_SHOW'
);

CREATE TYPE payment_status AS ENUM (
  'UNPAID','PARTIALLY_PAID','PAID','OVERPAID','REFUNDED','PARTIALLY_REFUNDED'
);

CREATE TYPE allocation_type AS ENUM (
  'RESERVATION','OUT_OF_ORDER','OUT_OF_SERVICE','HOUSE_USE','MAINTENANCE'
);

CREATE TYPE id_document_type AS ENUM (
  'PASSPORT','AADHAAR','PAN','DRIVING_LICENSE','VOTER_ID','VISA','OTHER'
);

-- ---------------------------------------------------------------------
-- Guests :: organization-scoped so a returning guest is recognised
-- across every property of the group. Government ID numbers are NOT
-- stored here -- see guest_documents.
-- ---------------------------------------------------------------------
CREATE TABLE guests (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id    uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  guest_code         text,
  title              text,
  first_name         text NOT NULL,
  last_name          text,
  full_name          text GENERATED ALWAYS AS (
                       btrim(first_name || ' ' || COALESCE(last_name,''))) STORED,
  email              citext,
  phone              text,
  alt_phone          text,
  address_line1      text,
  address_line2      text,
  city               text,
  state              text,
  state_code         char(2),
  postal_code        text,
  country_code       char(2) NOT NULL DEFAULT 'IN',
  date_of_birth      date,
  gender             text,
  nationality        text,
  company_name       text,
  gstin              text,
  preferences        jsonb NOT NULL DEFAULT '{}'::jsonb,
  notes              text,
  -- Consent is per channel and must be explicit (DPDP Act 2023).
  marketing_consent  boolean NOT NULL DEFAULT false,
  email_consent      boolean NOT NULL DEFAULT false,
  sms_consent        boolean NOT NULL DEFAULT false,
  whatsapp_consent   boolean NOT NULL DEFAULT false,
  consent_updated_at timestamptz,
  is_blacklisted     boolean NOT NULL DEFAULT false,
  blacklist_reason   text,
  vip_tier           text,
  created_by         uuid REFERENCES users(id),
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT guests_code_uq UNIQUE (organization_id, guest_code),
  CONSTRAINT guests_contact_chk CHECK (email IS NOT NULL OR phone IS NOT NULL),
  CONSTRAINT guests_gender_chk CHECK (gender IS NULL OR gender IN ('MALE','FEMALE','OTHER','UNDISCLOSED')),
  CONSTRAINT guests_dob_chk CHECK (date_of_birth IS NULL OR date_of_birth < CURRENT_DATE),
  CONSTRAINT guests_blacklist_chk CHECK (NOT is_blacklisted OR blacklist_reason IS NOT NULL),
  CONSTRAINT guests_gstin_chk CHECK (
    gstin IS NULL OR gstin ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z]{1}[1-9A-Z]{1}Z[0-9A-Z]{1}$')
);
CREATE INDEX guests_org_phone_idx ON guests(organization_id, phone);
CREATE INDEX guests_org_email_idx ON guests(organization_id, email);
CREATE INDEX guests_search_idx ON guests
  USING gin (to_tsvector('simple',
    COALESCE(first_name,'') || ' ' || COALESCE(last_name,'') || ' ' ||
    COALESCE(email::text,'') || ' ' || COALESCE(phone,'')));

-- Identity documents live apart so RLS can restrict them to front-office
-- and compliance roles only.
CREATE TABLE guest_documents (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  guest_id         uuid NOT NULL REFERENCES guests(id) ON DELETE CASCADE,
  property_id      uuid REFERENCES properties(id) ON DELETE SET NULL,
  document_type    id_document_type NOT NULL,
  -- Ciphertext produced by the application (AES-GCM, key from KMS/env).
  -- The database never receives the plaintext ID number.
  document_number_encrypted bytea,
  document_number_last4     text,
  -- Deterministic HMAC for exact-match lookup without decryption.
  document_number_hash      text,
  issuing_country  char(2),
  issue_date       date,
  expiry_date      date,
  file_url         text,
  verified_at      timestamptz,
  verified_by      uuid REFERENCES users(id),
  uploaded_by      uuid REFERENCES users(id),
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT guest_documents_last4_chk CHECK (
    document_number_last4 IS NULL OR document_number_last4 ~ '^[A-Z0-9]{1,4}$'),
  CONSTRAINT guest_documents_expiry_chk CHECK (
    expiry_date IS NULL OR issue_date IS NULL OR expiry_date > issue_date)
);
CREATE INDEX guest_documents_guest_idx ON guest_documents(guest_id);
CREATE INDEX guest_documents_hash_idx  ON guest_documents(document_number_hash);

-- A table, not an enum, so a new OTA or campaign is added from Settings
-- without a migration.
CREATE TABLE booking_sources (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id        uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  code                   text NOT NULL,
  name                   text NOT NULL,
  category               text NOT NULL,
  default_commission_pct numeric(5,2) NOT NULL DEFAULT 0,
  channel_id             uuid,   -- FK added in 0008
  is_active              boolean NOT NULL DEFAULT true,
  created_at             timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT booking_sources_uq UNIQUE (organization_id, code),
  CONSTRAINT booking_sources_category_chk CHECK (category IN (
    'DIRECT_WEBSITE','OTA','WALK_IN','PHONE','EMAIL','WHATSAPP',
    'CORPORATE','TRAVEL_AGENT','GDS','METASEARCH','OTHER')),
  CONSTRAINT booking_sources_commission_chk CHECK (default_commission_pct BETWEEN 0 AND 100)
);

-- ---------------------------------------------------------------------
-- Reservations (booking header). Money columns are maintained from the
-- child lines inside the booking transaction; balance is derived.
-- ---------------------------------------------------------------------
CREATE TABLE reservations (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id            uuid NOT NULL REFERENCES properties(id) ON DELETE RESTRICT,
  reservation_number     text NOT NULL,
  booking_source_id      uuid REFERENCES booking_sources(id) ON DELETE SET NULL,
  -- FKs to channels / corporate / travel agents added in 0007 and 0008.
  channel_id             uuid,
  corporate_account_id   uuid,
  travel_agent_id        uuid,
  external_reference     text,
  group_reservation_id   uuid REFERENCES reservations(id) ON DELETE SET NULL,
  is_group_master        boolean NOT NULL DEFAULT false,
  guest_id               uuid NOT NULL REFERENCES guests(id) ON DELETE RESTRICT,
  status                 reservation_status NOT NULL DEFAULT 'PENDING',
  arrival_date           date NOT NULL,
  departure_date         date NOT NULL,
  nights                 integer GENERATED ALWAYS AS (departure_date - arrival_date) STORED,
  adults                 smallint NOT NULL DEFAULT 1,
  children               smallint NOT NULL DEFAULT 0,
  rooms_count            smallint NOT NULL DEFAULT 1,
  currency_code          char(3) NOT NULL DEFAULT 'INR',
  room_charges           numeric(14,2) NOT NULL DEFAULT 0,
  extras_charges         numeric(14,2) NOT NULL DEFAULT 0,
  discount_amount        numeric(14,2) NOT NULL DEFAULT 0,
  tax_amount             numeric(14,2) NOT NULL DEFAULT 0,
  total_amount           numeric(14,2) NOT NULL DEFAULT 0,
  paid_amount            numeric(14,2) NOT NULL DEFAULT 0,
  balance_amount         numeric(14,2) GENERATED ALWAYS AS (total_amount - paid_amount) STORED,
  commission_amount      numeric(14,2) NOT NULL DEFAULT 0,
  payment_status         payment_status NOT NULL DEFAULT 'UNPAID',
  cancellation_policy_id uuid REFERENCES cancellation_policies(id) ON DELETE SET NULL,
  promo_code             text,
  special_requests       text,
  internal_notes         text,
  estimated_arrival_time time,
  -- Untouched copy of the OTA payload, for dispute resolution.
  source_metadata        jsonb NOT NULL DEFAULT '{}'::jsonb,
  booked_at              timestamptz NOT NULL DEFAULT now(),
  confirmed_at           timestamptz,
  checked_in_at          timestamptz,
  checked_out_at         timestamptz,
  cancelled_at           timestamptz,
  cancelled_by           uuid REFERENCES users(id),
  cancellation_reason    text,
  created_by             uuid REFERENCES users(id),
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT reservations_number_uq UNIQUE (property_id, reservation_number),
  CONSTRAINT reservations_dates_chk CHECK (departure_date > arrival_date),
  CONSTRAINT reservations_occupancy_chk CHECK (adults >= 1 AND children >= 0 AND rooms_count >= 1),
  CONSTRAINT reservations_amounts_chk CHECK (
    room_charges >= 0 AND extras_charges >= 0 AND discount_amount >= 0
    AND tax_amount >= 0 AND total_amount >= 0 AND commission_amount >= 0),
  CONSTRAINT reservations_cancelled_chk CHECK (
    status <> 'CANCELLED' OR (cancelled_at IS NOT NULL AND cancellation_reason IS NOT NULL)),
  CONSTRAINT reservations_checkin_chk CHECK (status <> 'CHECKED_IN' OR checked_in_at IS NOT NULL),
  CONSTRAINT reservations_checkout_chk CHECK (status <> 'CHECKED_OUT' OR checked_out_at IS NOT NULL),
  CONSTRAINT reservations_no_self_group_chk CHECK (group_reservation_id IS DISTINCT FROM id)
);
CREATE INDEX reservations_property_arrival_idx   ON reservations(property_id, arrival_date);
CREATE INDEX reservations_property_departure_idx ON reservations(property_id, departure_date);
CREATE INDEX reservations_property_status_idx    ON reservations(property_id, status);
CREATE INDEX reservations_guest_idx              ON reservations(guest_id);
CREATE INDEX reservations_source_idx             ON reservations(booking_source_id);
CREATE INDEX reservations_group_idx              ON reservations(group_reservation_id);
-- Date-range overlap search for the calendar.
CREATE INDEX reservations_stay_range_idx ON reservations
  USING gist (property_id, daterange(arrival_date, departure_date, '[)'));

-- The same OTA booking must never land twice, even across retries.
CREATE UNIQUE INDEX reservations_external_ref_uq
  ON reservations(property_id, channel_id, external_reference)
  WHERE external_reference IS NOT NULL AND channel_id IS NOT NULL;

CREATE TABLE reservation_rooms (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reservation_id  uuid NOT NULL REFERENCES reservations(id) ON DELETE CASCADE,
  property_id     uuid NOT NULL REFERENCES properties(id) ON DELETE RESTRICT,
  room_type_id    uuid NOT NULL REFERENCES room_types(id) ON DELETE RESTRICT,
  rate_plan_id    uuid NOT NULL REFERENCES rate_plans(id) ON DELETE RESTRICT,
  line_number     smallint NOT NULL DEFAULT 1,
  arrival_date    date NOT NULL,
  departure_date  date NOT NULL,
  stay_range      daterange GENERATED ALWAYS AS
                    (daterange(arrival_date, departure_date, '[)')) STORED,
  adults          smallint NOT NULL DEFAULT 1,
  children        smallint NOT NULL DEFAULT 0,
  guest_id        uuid REFERENCES guests(id) ON DELETE SET NULL,
  status          reservation_room_status NOT NULL DEFAULT 'RESERVED',
  room_charges    numeric(14,2) NOT NULL DEFAULT 0,
  discount_amount numeric(14,2) NOT NULL DEFAULT 0,
  tax_amount      numeric(14,2) NOT NULL DEFAULT 0,
  total_amount    numeric(14,2) NOT NULL DEFAULT 0,
  checked_in_at   timestamptz,
  checked_out_at  timestamptz,
  folio_id        uuid,   -- FK added in 0004
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT reservation_rooms_line_uq UNIQUE (reservation_id, line_number),
  CONSTRAINT reservation_rooms_dates_chk CHECK (departure_date > arrival_date),
  CONSTRAINT reservation_rooms_occupancy_chk CHECK (adults >= 1 AND children >= 0),
  CONSTRAINT reservation_rooms_amounts_chk CHECK (
    room_charges >= 0 AND discount_amount >= 0 AND tax_amount >= 0 AND total_amount >= 0)
);
CREATE INDEX reservation_rooms_reservation_idx ON reservation_rooms(reservation_id);
CREATE INDEX reservation_rooms_type_dates_idx  ON reservation_rooms(room_type_id, arrival_date, departure_date);
CREATE INDEX reservation_rooms_folio_idx       ON reservation_rooms(folio_id);

-- Nightly price breakdown :: what room revenue is posted from. Reports
-- never re-derive revenue by dividing a stay total by nights.
CREATE TABLE reservation_room_rates (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reservation_room_id uuid NOT NULL REFERENCES reservation_rooms(id) ON DELETE CASCADE,
  property_id         uuid NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
  stay_date           date NOT NULL,
  rate_amount         numeric(12,2) NOT NULL DEFAULT 0,
  extra_person_amount numeric(12,2) NOT NULL DEFAULT 0,
  discount_amount     numeric(12,2) NOT NULL DEFAULT 0,
  taxable_amount      numeric(12,2) NOT NULL DEFAULT 0,
  tax_amount          numeric(12,2) NOT NULL DEFAULT 0,
  total_amount        numeric(12,2) NOT NULL DEFAULT 0,
  -- True once the night audit has posted this night to the folio.
  is_posted           boolean NOT NULL DEFAULT false,
  posted_at           timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT reservation_room_rates_uq UNIQUE (reservation_room_id, stay_date),
  CONSTRAINT reservation_room_rates_amounts_chk CHECK (
    rate_amount >= 0 AND extra_person_amount >= 0 AND discount_amount >= 0
    AND taxable_amount >= 0 AND tax_amount >= 0 AND total_amount >= 0)
);
CREATE INDEX reservation_room_rates_date_idx ON reservation_room_rates(property_id, stay_date);

CREATE TABLE reservation_guests (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reservation_room_id uuid NOT NULL REFERENCES reservation_rooms(id) ON DELETE CASCADE,
  guest_id            uuid NOT NULL REFERENCES guests(id) ON DELETE RESTRICT,
  is_primary          boolean NOT NULL DEFAULT false,
  created_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT reservation_guests_uq UNIQUE (reservation_room_id, guest_id)
);
CREATE UNIQUE INDEX reservation_guests_primary_uq
  ON reservation_guests(reservation_room_id) WHERE is_primary;

CREATE TABLE reservation_status_history (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  reservation_id uuid NOT NULL REFERENCES reservations(id) ON DELETE CASCADE,
  from_status    reservation_status,
  to_status      reservation_status NOT NULL,
  reason         text,
  changed_by     uuid REFERENCES users(id),
  created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX reservation_status_history_res_idx ON reservation_status_history(reservation_id, created_at);

-- ---------------------------------------------------------------------
-- room_allocations :: THE physical room-night ledger.
--
-- Every reason a room is unavailable -- a booking, an out-of-order
-- block, house use -- is a row here. Because they share one table, ONE
-- exclusion constraint guarantees a room is never double-committed,
-- whatever the cause. PostgreSQL enforces it, not application code, so
-- it holds under concurrent OTA + web + front-desk writes regardless of
-- transaction interleaving.
--
-- '[)' range semantics mean checkout day is free for the next arrival:
-- a stay 01->05 and a stay 05->07 in the same room do NOT conflict.
-- ---------------------------------------------------------------------
CREATE TABLE room_allocations (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id         uuid NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
  room_id             uuid NOT NULL REFERENCES rooms(id) ON DELETE RESTRICT,
  allocation_type     allocation_type NOT NULL DEFAULT 'RESERVATION',
  reservation_room_id uuid REFERENCES reservation_rooms(id) ON DELETE CASCADE,
  arrival_date        date NOT NULL,
  departure_date      date NOT NULL,
  stay_range          daterange GENERATED ALWAYS AS
                        (daterange(arrival_date, departure_date, '[)')) STORED,
  -- Set false on cancel/no-show/room-move; the row is kept for history
  -- and stops blocking the room.
  is_active           boolean NOT NULL DEFAULT true,
  reason              text,
  released_at         timestamptz,
  released_by         uuid REFERENCES users(id),
  created_by          uuid REFERENCES users(id),
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT room_allocations_dates_chk CHECK (departure_date > arrival_date),
  CONSTRAINT room_allocations_link_chk CHECK (
    (allocation_type = 'RESERVATION' AND reservation_room_id IS NOT NULL)
    OR (allocation_type <> 'RESERVATION' AND reservation_room_id IS NULL)),
  CONSTRAINT room_allocations_block_reason_chk CHECK (
    allocation_type = 'RESERVATION' OR reason IS NOT NULL),
  -- ***** The double-booking guard *****
  CONSTRAINT room_allocations_no_overlap
    EXCLUDE USING gist (room_id WITH =, stay_range WITH &&) WHERE (is_active)
);
CREATE INDEX room_allocations_res_room_idx ON room_allocations(reservation_room_id);
CREATE INDEX room_allocations_property_idx ON room_allocations(property_id, arrival_date, departure_date);
CREATE INDEX room_allocations_room_idx     ON room_allocations(room_id) WHERE is_active;

-- Denormalised pointer for "which room is this line in right now".
ALTER TABLE reservation_rooms
  ADD COLUMN current_room_id uuid REFERENCES rooms(id) ON DELETE SET NULL;
CREATE INDEX reservation_rooms_current_room_idx ON reservation_rooms(current_room_id);

CREATE TRIGGER guests_updated_at            BEFORE UPDATE ON guests            FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();
CREATE TRIGGER reservations_updated_at      BEFORE UPDATE ON reservations      FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();
CREATE TRIGGER reservation_rooms_updated_at BEFORE UPDATE ON reservation_rooms FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();
CREATE TRIGGER room_allocations_updated_at  BEFORE UPDATE ON room_allocations  FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();
