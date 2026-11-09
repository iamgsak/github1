-- =====================================================================
-- 0002_rooms_and_rates.sql
-- Room types, physical rooms, amenities, rate plans, the daily rate
-- grid, restrictions and the daily inventory counter.
--
-- Single source of truth:
--   room_rates        -> price for (room_type, rate_plan, date)
--   rate_restrictions -> sellability for (room_type, rate_plan, date)
--   inventory_daily   -> sellable room count for (room_type, date)
-- The booking engine and every channel push read these three tables.
-- No module keeps its own copy.
-- =====================================================================

CREATE TYPE room_status AS ENUM (
  'AVAILABLE','OCCUPIED','RESERVED','OUT_OF_ORDER','OUT_OF_SERVICE','MAINTENANCE'
);

-- Housekeeping state is orthogonal to sellability: a room can be
-- OCCUPIED+DIRTY or AVAILABLE+DIRTY. Separate columns avoid the classic
-- PMS bug of one overwriting the other.
CREATE TYPE housekeeping_status AS ENUM (
  'CLEAN','DIRTY','INSPECTED','PICKUP','OUT_OF_SERVICE'
);

CREATE TYPE meal_plan AS ENUM ('EP','CP','MAP','AP');

CREATE TABLE amenities (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  code            text NOT NULL,
  name            text NOT NULL,
  icon            text,
  category        text NOT NULL DEFAULT 'GENERAL',
  is_active       boolean NOT NULL DEFAULT true,
  created_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT amenities_uq UNIQUE (organization_id, code)
);

-- total_rooms is denormalised from rooms for fast availability maths and
-- kept in sync by a trigger in 0009.
CREATE TABLE room_types (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id          uuid NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
  code                 text NOT NULL,
  name                 text NOT NULL,
  description          text,
  total_rooms          integer NOT NULL DEFAULT 0,
  max_adults           smallint NOT NULL DEFAULT 2,
  max_children         smallint NOT NULL DEFAULT 1,
  max_occupancy        smallint NOT NULL DEFAULT 3,
  base_occupancy       smallint NOT NULL DEFAULT 2,
  extra_adult_capacity smallint NOT NULL DEFAULT 1,
  extra_child_capacity smallint NOT NULL DEFAULT 1,
  base_rate            numeric(12,2) NOT NULL DEFAULT 0,
  extra_adult_rate     numeric(12,2) NOT NULL DEFAULT 0,
  extra_child_rate     numeric(12,2) NOT NULL DEFAULT 0,
  size_sqft            integer,
  bed_type             text,
  -- FK added in 0004 once the tax tables exist.
  tax_group_id         uuid,
  sort_order           smallint NOT NULL DEFAULT 0,
  is_active            boolean NOT NULL DEFAULT true,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT room_types_uq UNIQUE (property_id, code),
  CONSTRAINT room_types_occupancy_chk CHECK (
    base_occupancy > 0 AND max_adults > 0
    AND max_occupancy >= base_occupancy AND max_occupancy >= max_adults),
  CONSTRAINT room_types_rate_chk CHECK (
    base_rate >= 0 AND extra_adult_rate >= 0 AND extra_child_rate >= 0),
  CONSTRAINT room_types_total_chk CHECK (total_rooms >= 0)
);
CREATE INDEX room_types_property_idx ON room_types(property_id) WHERE is_active;

CREATE TABLE room_type_amenities (
  room_type_id uuid NOT NULL REFERENCES room_types(id) ON DELETE CASCADE,
  amenity_id   uuid NOT NULL REFERENCES amenities(id) ON DELETE CASCADE,
  PRIMARY KEY (room_type_id, amenity_id)
);

CREATE TABLE room_type_images (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  room_type_id uuid NOT NULL REFERENCES room_types(id) ON DELETE CASCADE,
  url          text NOT NULL,
  caption      text,
  sort_order   smallint NOT NULL DEFAULT 0,
  is_primary   boolean NOT NULL DEFAULT false,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX room_type_images_primary_uq
  ON room_type_images(room_type_id) WHERE is_primary;

CREATE TABLE rooms (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id         uuid NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
  room_type_id        uuid NOT NULL REFERENCES room_types(id) ON DELETE RESTRICT,
  room_number         text NOT NULL,
  floor               text,
  building            text,
  status              room_status NOT NULL DEFAULT 'AVAILABLE',
  housekeeping_status housekeeping_status NOT NULL DEFAULT 'CLEAN',
  -- OOO/OOS periods live in room_allocations so they collide with
  -- bookings; this flag only withdraws a room entirely.
  is_active           boolean NOT NULL DEFAULT true,
  notes               text,
  last_cleaned_at     timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT rooms_number_uq UNIQUE (property_id, room_number)
);
CREATE INDEX rooms_property_type_idx ON rooms(property_id, room_type_id) WHERE is_active;
CREATE INDEX rooms_status_idx        ON rooms(property_id, status);
CREATE INDEX rooms_hk_status_idx     ON rooms(property_id, housekeeping_status);

CREATE TABLE cancellation_policies (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id             uuid NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
  code                    text NOT NULL,
  name                    text NOT NULL,
  description             text,
  free_cancellation_hours integer NOT NULL DEFAULT 24,
  penalty_type            text NOT NULL DEFAULT 'FIRST_NIGHT',
  penalty_value           numeric(12,2) NOT NULL DEFAULT 0,
  no_show_penalty_type    text NOT NULL DEFAULT 'FIRST_NIGHT',
  no_show_penalty_value   numeric(12,2) NOT NULL DEFAULT 0,
  is_active               boolean NOT NULL DEFAULT true,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT cancellation_policies_uq UNIQUE (property_id, code),
  CONSTRAINT cancellation_penalty_type_chk
    CHECK (penalty_type IN ('NONE','FIRST_NIGHT','PERCENTAGE','FIXED','FULL_STAY')),
  CONSTRAINT cancellation_noshow_type_chk
    CHECK (no_show_penalty_type IN ('NONE','FIRST_NIGHT','PERCENTAGE','FIXED','FULL_STAY')),
  CONSTRAINT cancellation_hours_chk CHECK (free_cancellation_hours >= 0)
);

-- A derived plan (parent_rate_plan_id set) is priced as parent +/- markup,
-- which keeps OTA-specific and corporate plans in sync automatically.
CREATE TABLE rate_plans (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id            uuid NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
  code                   text NOT NULL,
  name                   text NOT NULL,
  description            text,
  meal_plan              meal_plan NOT NULL DEFAULT 'EP',
  parent_rate_plan_id    uuid REFERENCES rate_plans(id) ON DELETE RESTRICT,
  markup_type            text NOT NULL DEFAULT 'NONE',
  markup_value           numeric(12,2) NOT NULL DEFAULT 0,
  is_refundable          boolean NOT NULL DEFAULT true,
  cancellation_policy_id uuid REFERENCES cancellation_policies(id) ON DELETE SET NULL,
  min_stay               smallint NOT NULL DEFAULT 1,
  max_stay               smallint,
  min_advance_days       smallint NOT NULL DEFAULT 0,
  max_advance_days       smallint,
  is_public              boolean NOT NULL DEFAULT true,
  is_channel_enabled     boolean NOT NULL DEFAULT false,
  -- Prices already include GST (common for OTA parity in India).
  is_tax_inclusive       boolean NOT NULL DEFAULT false,
  valid_from             date,
  valid_to               date,
  is_active              boolean NOT NULL DEFAULT true,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT rate_plans_uq UNIQUE (property_id, code),
  CONSTRAINT rate_plans_markup_chk CHECK (markup_type IN ('NONE','PERCENTAGE','FIXED')),
  CONSTRAINT rate_plans_stay_chk CHECK (min_stay >= 1 AND (max_stay IS NULL OR max_stay >= min_stay)),
  CONSTRAINT rate_plans_validity_chk CHECK (valid_to IS NULL OR valid_from IS NULL OR valid_to >= valid_from),
  CONSTRAINT rate_plans_no_self_parent_chk CHECK (parent_rate_plan_id IS DISTINCT FROM id)
);
CREATE INDEX rate_plans_property_idx ON rate_plans(property_id) WHERE is_active;

CREATE TABLE rate_plan_room_types (
  rate_plan_id uuid NOT NULL REFERENCES rate_plans(id) ON DELETE CASCADE,
  room_type_id uuid NOT NULL REFERENCES room_types(id) ON DELETE CASCADE,
  base_rate    numeric(12,2),
  is_active    boolean NOT NULL DEFAULT true,
  PRIMARY KEY (rate_plan_id, room_type_id),
  CONSTRAINT rate_plan_room_types_rate_chk CHECK (base_rate IS NULL OR base_rate >= 0)
);

-- Seasons bulk-generate room_rates rows; room_rates stays authoritative.
CREATE TABLE rate_seasons (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id      uuid NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
  name             text NOT NULL,
  season_type      text NOT NULL DEFAULT 'SEASONAL',
  start_date       date NOT NULL,
  end_date         date NOT NULL,
  priority         smallint NOT NULL DEFAULT 0,
  adjustment_type  text NOT NULL DEFAULT 'PERCENTAGE',
  adjustment_value numeric(12,2) NOT NULL DEFAULT 0,
  -- ISO weekday numbers the season applies to (1=Mon .. 7=Sun); NULL = all.
  weekdays         smallint[],
  is_active        boolean NOT NULL DEFAULT true,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT rate_seasons_dates_chk CHECK (end_date >= start_date),
  CONSTRAINT rate_seasons_type_chk CHECK (season_type IN ('SEASONAL','WEEKEND','EVENT','PROMOTION','BLACKOUT')),
  CONSTRAINT rate_seasons_adj_chk CHECK (adjustment_type IN ('PERCENTAGE','FIXED','ABSOLUTE')),
  CONSTRAINT rate_seasons_weekdays_chk CHECK (weekdays IS NULL OR (
    array_length(weekdays,1) BETWEEN 1 AND 7
    AND weekdays <@ ARRAY[1,2,3,4,5,6,7]::smallint[]))
);

-- Daily rate grid :: the price source of truth.
CREATE TABLE room_rates (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id      uuid NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
  room_type_id     uuid NOT NULL REFERENCES room_types(id) ON DELETE CASCADE,
  rate_plan_id     uuid NOT NULL REFERENCES rate_plans(id) ON DELETE CASCADE,
  stay_date        date NOT NULL,
  rate             numeric(12,2) NOT NULL,
  extra_adult_rate numeric(12,2) NOT NULL DEFAULT 0,
  extra_child_rate numeric(12,2) NOT NULL DEFAULT 0,
  currency_code    char(3) NOT NULL DEFAULT 'INR',
  -- MANUAL overrides survive bulk regeneration.
  source           text NOT NULL DEFAULT 'MANUAL',
  updated_by       uuid REFERENCES users(id),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT room_rates_uq UNIQUE (room_type_id, rate_plan_id, stay_date),
  CONSTRAINT room_rates_rate_chk CHECK (rate >= 0 AND extra_adult_rate >= 0 AND extra_child_rate >= 0),
  CONSTRAINT room_rates_source_chk CHECK (source IN ('MANUAL','SEASON','DERIVED','DYNAMIC','CHANNEL','IMPORT'))
);
CREATE INDEX room_rates_lookup_idx ON room_rates(property_id, stay_date, room_type_id);

-- Restrictions :: sellability source of truth.
-- rate_plan_id NULL = applies to every rate plan for that room type.
CREATE TABLE rate_restrictions (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id         uuid NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
  room_type_id        uuid NOT NULL REFERENCES room_types(id) ON DELETE CASCADE,
  rate_plan_id        uuid REFERENCES rate_plans(id) ON DELETE CASCADE,
  stay_date           date NOT NULL,
  min_stay            smallint,
  max_stay            smallint,
  stop_sell           boolean NOT NULL DEFAULT false,
  closed_to_arrival   boolean NOT NULL DEFAULT false,
  closed_to_departure boolean NOT NULL DEFAULT false,
  updated_by          uuid REFERENCES users(id),
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT rate_restrictions_uq UNIQUE NULLS NOT DISTINCT (room_type_id, rate_plan_id, stay_date),
  CONSTRAINT rate_restrictions_stay_chk CHECK (
    (min_stay IS NULL OR min_stay >= 1) AND (max_stay IS NULL OR max_stay >= 1)
    AND (min_stay IS NULL OR max_stay IS NULL OR max_stay >= min_stay))
);
CREATE INDEX rate_restrictions_lookup_idx ON rate_restrictions(property_id, stay_date, room_type_id);

-- ---------------------------------------------------------------------
-- Daily inventory counter :: availability source of truth.
--
-- The CHECK is the second line of defence against overselling at the
-- room-TYPE level (the exclusion constraint in 0003 guards the physical
-- room level). Booking flows SELECT ... FOR UPDATE these rows then
-- increment sold_rooms, so concurrent OTA + website bookings serialise
-- and the loser is rejected here rather than overselling.
-- ---------------------------------------------------------------------
CREATE TABLE inventory_daily (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id       uuid NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
  room_type_id      uuid NOT NULL REFERENCES room_types(id) ON DELETE CASCADE,
  stay_date         date NOT NULL,
  total_rooms       integer NOT NULL DEFAULT 0,
  sold_rooms        integer NOT NULL DEFAULT 0,
  blocked_rooms     integer NOT NULL DEFAULT 0,
  ooo_rooms         integer NOT NULL DEFAULT 0,
  overbooking_limit integer NOT NULL DEFAULT 0,
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT inventory_daily_uq UNIQUE (room_type_id, stay_date),
  CONSTRAINT inventory_daily_nonneg_chk CHECK (
    total_rooms >= 0 AND sold_rooms >= 0 AND blocked_rooms >= 0
    AND ooo_rooms >= 0 AND overbooking_limit >= 0),
  CONSTRAINT inventory_daily_capacity_chk
    CHECK (sold_rooms + blocked_rooms + ooo_rooms <= total_rooms + overbooking_limit)
);
CREATE INDEX inventory_daily_lookup_idx ON inventory_daily(property_id, stay_date);

CREATE VIEW v_availability AS
SELECT i.property_id, i.room_type_id, rt.code AS room_type_code,
       rt.name AS room_type_name, i.stay_date, i.total_rooms, i.sold_rooms,
       i.blocked_rooms, i.ooo_rooms, i.overbooking_limit,
       GREATEST(i.total_rooms + i.overbooking_limit
                - i.sold_rooms - i.blocked_rooms - i.ooo_rooms, 0) AS available_rooms
FROM inventory_daily i JOIN room_types rt ON rt.id = i.room_type_id;

CREATE TRIGGER room_types_updated_at            BEFORE UPDATE ON room_types            FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();
CREATE TRIGGER rooms_updated_at                 BEFORE UPDATE ON rooms                 FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();
CREATE TRIGGER cancellation_policies_updated_at BEFORE UPDATE ON cancellation_policies FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();
CREATE TRIGGER rate_plans_updated_at            BEFORE UPDATE ON rate_plans            FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();
CREATE TRIGGER rate_seasons_updated_at          BEFORE UPDATE ON rate_seasons          FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();
CREATE TRIGGER room_rates_updated_at            BEFORE UPDATE ON room_rates            FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();
CREATE TRIGGER rate_restrictions_updated_at     BEFORE UPDATE ON rate_restrictions     FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();
