-- =====================================================================
-- 0009_business_rules.sql
-- Server-side business rules: the generic audit trigger, availability
-- reservation/release under lock, room-allocation integrity, and the
-- aggregate maintenance triggers.
--
-- Request context is passed from the application per transaction:
--   SET LOCAL app.current_user_id    = '<uuid>';
--   SET LOCAL app.current_user_email = '<email>';
--   SET LOCAL app.current_ip         = '<ip>';
--   SET LOCAL app.request_id         = '<uuid>';
-- Every helper degrades safely when these are absent (background jobs,
-- migrations, psql).
-- =====================================================================

CREATE OR REPLACE FUNCTION app.current_user_id() RETURNS uuid
LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN NULLIF(current_setting('app.current_user_id', true), '')::uuid;
EXCEPTION WHEN others THEN RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION app.current_user_email() RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('app.current_user_email', true), '');
$$;

CREATE OR REPLACE FUNCTION app.current_ip() RETURNS inet
LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN NULLIF(current_setting('app.current_ip', true), '')::inet;
EXCEPTION WHEN others THEN RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION app.request_id() RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('app.request_id', true), '');
$$;

-- ---------------------------------------------------------------------
-- Generic audit trigger. Records only the columns that actually changed
-- on UPDATE, so the log stays readable and cheap.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.audit_trigger()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_module text := COALESCE(TG_ARGV[0], TG_TABLE_NAME);
  v_old jsonb; v_new jsonb; v_changed text[]; v_record text;
  v_property uuid; v_org uuid;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_old := to_jsonb(OLD);
  ELSIF TG_OP = 'INSERT' THEN
    v_new := to_jsonb(NEW);
  ELSE
    v_old := to_jsonb(OLD);
    v_new := to_jsonb(NEW);
    SELECT array_agg(key) INTO v_changed
      FROM jsonb_each(v_new) WHERE v_old -> key IS DISTINCT FROM value;
    -- Nothing but updated_at moved: not worth an audit row.
    IF v_changed IS NULL OR v_changed <@ ARRAY['updated_at'] THEN RETURN NULL; END IF;
  END IF;

  v_record   := COALESCE(v_new ->> 'id', v_old ->> 'id');
  v_property := NULLIF(COALESCE(v_new ->> 'property_id', v_old ->> 'property_id'), '')::uuid;
  v_org      := NULLIF(COALESCE(v_new ->> 'organization_id', v_old ->> 'organization_id'), '')::uuid;

  IF v_org IS NULL AND v_property IS NOT NULL THEN
    SELECT organization_id INTO v_org FROM public.properties WHERE id = v_property;
  END IF;

  INSERT INTO public.audit_logs (
    organization_id, property_id, user_id, user_email, action, module,
    table_name, record_id, old_values, new_values, changed_fields,
    ip_address, request_id)
  VALUES (
    v_org, v_property, app.current_user_id(), app.current_user_email(),
    TG_OP, v_module, TG_TABLE_NAME, v_record, v_old, v_new, v_changed,
    app.current_ip(), app.request_id());

  RETURN NULL;
END;
$$;

-- room_types.total_rooms follows the rooms table.
CREATE OR REPLACE FUNCTION app.sync_room_type_total()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_ids uuid[];
BEGIN
  v_ids := ARRAY(SELECT DISTINCT x FROM unnest(ARRAY[
    CASE WHEN TG_OP <> 'INSERT' THEN OLD.room_type_id END,
    CASE WHEN TG_OP <> 'DELETE' THEN NEW.room_type_id END]) x WHERE x IS NOT NULL);
  UPDATE room_types rt
     SET total_rooms = (SELECT count(*) FROM rooms r
                         WHERE r.room_type_id = rt.id AND r.is_active)
   WHERE rt.id = ANY(v_ids);
  RETURN NULL;
END;
$$;
CREATE TRIGGER rooms_sync_room_type_total
  AFTER INSERT OR UPDATE OF room_type_id, is_active OR DELETE ON rooms
  FOR EACH ROW EXECUTE FUNCTION app.sync_room_type_total();

-- Idempotent; safe to call concurrently.
CREATE OR REPLACE FUNCTION app.ensure_inventory_rows(
  p_property_id uuid, p_room_type_id uuid, p_from date, p_to date
) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO inventory_daily (property_id, room_type_id, stay_date, total_rooms)
  SELECT p_property_id, p_room_type_id, d::date,
         (SELECT total_rooms FROM room_types WHERE id = p_room_type_id)
    FROM generate_series(p_from, p_to - 1, interval '1 day') d
  ON CONFLICT (room_type_id, stay_date) DO NOTHING;
END;
$$;

-- Lowest availability across the window; what the booking engine and
-- channel push both read.
CREATE OR REPLACE FUNCTION app.check_availability(
  p_property_id uuid, p_room_type_id uuid, p_from date, p_to date
) RETURNS integer LANGUAGE plpgsql STABLE AS $$
DECLARE v_min integer; v_nights integer := p_to - p_from;
BEGIN
  IF v_nights < 1 THEN
    RAISE EXCEPTION 'Departure must be after arrival' USING ERRCODE = 'check_violation';
  END IF;

  SELECT min(GREATEST(i.total_rooms + i.overbooking_limit
                      - i.sold_rooms - i.blocked_rooms - i.ooo_rooms, 0))
    INTO v_min
    FROM inventory_daily i
   WHERE i.room_type_id = p_room_type_id
     AND i.stay_date >= p_from AND i.stay_date < p_to;

  -- A night with no inventory row has never been sold: fall back to the
  -- room type's full count so an unseeded calendar is not "sold out".
  IF v_min IS NULL OR (SELECT count(*) FROM inventory_daily
                        WHERE room_type_id = p_room_type_id
                          AND stay_date >= p_from AND stay_date < p_to) < v_nights THEN
    v_min := LEAST(COALESCE(v_min, 2147483647),
                   (SELECT total_rooms FROM room_types WHERE id = p_room_type_id));
  END IF;

  RETURN GREATEST(COALESCE(v_min, 0), 0);
END;
$$;

-- ---------------------------------------------------------------------
-- Reserve inventory :: the concurrency-critical path.
--
-- Rows are locked in a deterministic order (by date) to rule out
-- deadlocks between simultaneous bookings, and the capacity CHECK on
-- inventory_daily raises if the update would oversell. A simultaneous
-- OTA and website booking for the last room therefore ends with one
-- success and one clean rejection -- never two confirmed bookings.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.reserve_inventory(
  p_property_id uuid, p_room_type_id uuid, p_from date, p_to date, p_rooms integer DEFAULT 1
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_date date;
BEGIN
  IF p_rooms < 1 THEN
    RAISE EXCEPTION 'Rooms to reserve must be positive' USING ERRCODE = 'check_violation';
  END IF;

  PERFORM app.ensure_inventory_rows(p_property_id, p_room_type_id, p_from, p_to);

  -- Deterministic lock order.
  PERFORM 1 FROM inventory_daily
   WHERE room_type_id = p_room_type_id AND stay_date >= p_from AND stay_date < p_to
   ORDER BY stay_date FOR UPDATE;

  FOR v_date IN SELECT d::date FROM generate_series(p_from, p_to - 1, interval '1 day') d LOOP
    BEGIN
      UPDATE inventory_daily
         SET sold_rooms = sold_rooms + p_rooms, updated_at = now()
       WHERE room_type_id = p_room_type_id AND stay_date = v_date;
    EXCEPTION WHEN check_violation THEN
      RAISE EXCEPTION 'No availability for room type % on %', p_room_type_id, v_date
        USING ERRCODE = 'exclusion_violation',
              HINT = 'The requested dates were sold out while this booking was being created.';
    END;
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION app.release_inventory(
  p_property_id uuid, p_room_type_id uuid, p_from date, p_to date, p_rooms integer DEFAULT 1
) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  UPDATE inventory_daily
     SET sold_rooms = GREATEST(sold_rooms - p_rooms, 0), updated_at = now()
   WHERE room_type_id = p_room_type_id AND stay_date >= p_from AND stay_date < p_to;
END;
$$;

-- The exclusion constraint stops overlaps; these checks stop the other
-- ways an allocation can be wrong.
CREATE OR REPLACE FUNCTION app.validate_room_allocation()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_room_property uuid; v_room_type uuid; v_room_active boolean;
  v_res_type uuid; v_res_arrival date; v_res_departure date;
BEGIN
  SELECT property_id, room_type_id, is_active
    INTO v_room_property, v_room_type, v_room_active
    FROM rooms WHERE id = NEW.room_id;

  IF v_room_property IS DISTINCT FROM NEW.property_id THEN
    RAISE EXCEPTION 'Room % belongs to a different property', NEW.room_id
      USING ERRCODE = 'check_violation';
  END IF;

  IF NOT v_room_active AND NEW.allocation_type = 'RESERVATION' THEN
    RAISE EXCEPTION 'Room % is inactive and cannot be assigned to a booking', NEW.room_id
      USING ERRCODE = 'check_violation';
  END IF;

  IF NEW.allocation_type = 'RESERVATION' THEN
    SELECT room_type_id, arrival_date, departure_date
      INTO v_res_type, v_res_arrival, v_res_departure
      FROM reservation_rooms WHERE id = NEW.reservation_room_id;

    -- An upgrade is a deliberate change of the stay line's room type, so
    -- the allocation must always match the line it belongs to.
    IF v_res_type IS DISTINCT FROM v_room_type THEN
      RAISE EXCEPTION 'Room % is type %, but the stay line was sold as type %',
        NEW.room_id, v_room_type, v_res_type USING ERRCODE = 'check_violation';
    END IF;

    -- Allocations may split a stay but never extend beyond it.
    IF NEW.arrival_date < v_res_arrival OR NEW.departure_date > v_res_departure THEN
      RAISE EXCEPTION 'Allocation % .. % falls outside the stay % .. %',
        NEW.arrival_date, NEW.departure_date, v_res_arrival, v_res_departure
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER room_allocations_validate
  BEFORE INSERT OR UPDATE ON room_allocations
  FOR EACH ROW EXECUTE FUNCTION app.validate_room_allocation();

CREATE OR REPLACE FUNCTION app.sync_current_room()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_line uuid := COALESCE(NEW.reservation_room_id, OLD.reservation_room_id);
BEGIN
  IF v_line IS NULL THEN RETURN NULL; END IF;
  UPDATE reservation_rooms rr
     SET current_room_id = (
       SELECT ra.room_id FROM room_allocations ra
        WHERE ra.reservation_room_id = v_line AND ra.is_active
        ORDER BY ra.arrival_date DESC LIMIT 1)
   WHERE rr.id = v_line;
  RETURN NULL;
END;
$$;
CREATE TRIGGER room_allocations_sync_current_room
  AFTER INSERT OR UPDATE OR DELETE ON room_allocations
  FOR EACH ROW EXECUTE FUNCTION app.sync_current_room();

-- OOO blocks consume room-type inventory so the channel push never
-- advertises a room that is physically unavailable.
CREATE OR REPLACE FUNCTION app.sync_ooo_inventory()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_room_type uuid;
BEGIN
  IF TG_OP <> 'INSERT' AND OLD.allocation_type <> 'RESERVATION' AND OLD.is_active THEN
    SELECT room_type_id INTO v_room_type FROM rooms WHERE id = OLD.room_id;
    PERFORM app.ensure_inventory_rows(OLD.property_id, v_room_type, OLD.arrival_date, OLD.departure_date);
    UPDATE inventory_daily SET ooo_rooms = GREATEST(ooo_rooms - 1, 0)
     WHERE room_type_id = v_room_type
       AND stay_date >= OLD.arrival_date AND stay_date < OLD.departure_date;
  END IF;

  IF TG_OP <> 'DELETE' AND NEW.allocation_type <> 'RESERVATION' AND NEW.is_active THEN
    SELECT room_type_id INTO v_room_type FROM rooms WHERE id = NEW.room_id;
    PERFORM app.ensure_inventory_rows(NEW.property_id, v_room_type, NEW.arrival_date, NEW.departure_date);
    UPDATE inventory_daily SET ooo_rooms = ooo_rooms + 1
     WHERE room_type_id = v_room_type
       AND stay_date >= NEW.arrival_date AND stay_date < NEW.departure_date;
  END IF;
  RETURN NULL;
END;
$$;
CREATE TRIGGER room_allocations_sync_ooo
  AFTER INSERT OR UPDATE OR DELETE ON room_allocations
  FOR EACH ROW EXECUTE FUNCTION app.sync_ooo_inventory();

CREATE OR REPLACE FUNCTION app.sync_folio_charges()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_folio uuid := COALESCE(NEW.folio_id, OLD.folio_id);
BEGIN
  UPDATE folios f
     SET total_charges = COALESCE((SELECT sum(fi.total_amount) FROM folio_items fi
                                    WHERE fi.folio_id = v_folio AND NOT fi.is_void), 0)
   WHERE f.id = v_folio;
  RETURN NULL;
END;
$$;
CREATE TRIGGER folio_items_sync_folio
  AFTER INSERT OR UPDATE OR DELETE ON folio_items
  FOR EACH ROW EXECUTE FUNCTION app.sync_folio_charges();

CREATE OR REPLACE FUNCTION app.sync_folio_payments()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_folio uuid := COALESCE(NEW.folio_id, OLD.folio_id);
BEGIN
  IF v_folio IS NULL THEN RETURN NULL; END IF;
  UPDATE folios f
     SET total_payments = COALESCE((
           SELECT sum(CASE WHEN p.payment_direction = 'RECEIPT' THEN p.amount ELSE -p.amount END)
             FROM payments p
            WHERE p.folio_id = v_folio AND NOT p.is_void
              AND p.status IN ('CAPTURED','AUTHORIZED')), 0)
   WHERE f.id = v_folio;
  RETURN NULL;
END;
$$;
CREATE TRIGGER payments_sync_folio
  AFTER INSERT OR UPDATE OR DELETE ON payments
  FOR EACH ROW EXECUTE FUNCTION app.sync_folio_payments();

CREATE OR REPLACE FUNCTION app.sync_reservation_payment()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_res uuid := COALESCE(NEW.reservation_id, OLD.reservation_id);
  v_paid numeric(14,2); v_total numeric(14,2);
BEGIN
  IF v_res IS NULL THEN RETURN NULL; END IF;

  SELECT COALESCE(sum(CASE WHEN p.payment_direction = 'RECEIPT' THEN p.amount ELSE -p.amount END), 0)
    INTO v_paid FROM payments p
   WHERE p.reservation_id = v_res AND NOT p.is_void
     AND p.status IN ('CAPTURED','AUTHORIZED');

  SELECT total_amount INTO v_total FROM reservations WHERE id = v_res;

  UPDATE reservations
     SET paid_amount = v_paid,
         payment_status = CASE
           WHEN v_paid <= 0       THEN 'UNPAID'::payment_status
           WHEN v_paid <  v_total THEN 'PARTIALLY_PAID'::payment_status
           WHEN v_paid =  v_total THEN 'PAID'::payment_status
           ELSE 'OVERPAID'::payment_status END
   WHERE id = v_res;
  RETURN NULL;
END;
$$;
CREATE TRIGGER payments_sync_reservation
  AFTER INSERT OR UPDATE OR DELETE ON payments
  FOR EACH ROW EXECUTE FUNCTION app.sync_reservation_payment();

-- Illegal jumps (e.g. CHECKED_OUT -> CONFIRMED) are refused here rather
-- than relying on every caller to be careful.
CREATE OR REPLACE FUNCTION app.track_reservation_status()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_allowed reservation_status[];
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO reservation_status_history (reservation_id, from_status, to_status, changed_by)
    VALUES (NEW.id, NULL, NEW.status, app.current_user_id());
    RETURN NULL;
  END IF;

  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN RETURN NULL; END IF;

  v_allowed := CASE OLD.status
    WHEN 'INQUIRY'     THEN ARRAY['PENDING','CONFIRMED','WAITLISTED','CANCELLED']
    WHEN 'PENDING'     THEN ARRAY['CONFIRMED','GUARANTEED','WAITLISTED','CANCELLED','NO_SHOW']
    WHEN 'CONFIRMED'   THEN ARRAY['GUARANTEED','CHECKED_IN','CANCELLED','NO_SHOW']
    WHEN 'GUARANTEED'  THEN ARRAY['CHECKED_IN','CANCELLED','NO_SHOW']
    WHEN 'WAITLISTED'  THEN ARRAY['PENDING','CONFIRMED','CANCELLED']
    WHEN 'CHECKED_IN'  THEN ARRAY['CHECKED_OUT']
    WHEN 'CHECKED_OUT' THEN ARRAY[]::text[]
    WHEN 'CANCELLED'   THEN ARRAY[]::text[]
    WHEN 'NO_SHOW'     THEN ARRAY['CANCELLED','CHECKED_IN']
  END::reservation_status[];

  IF NOT (NEW.status = ANY(v_allowed)) THEN
    RAISE EXCEPTION 'Illegal reservation status transition % -> % for %',
      OLD.status, NEW.status, OLD.reservation_number USING ERRCODE = 'check_violation';
  END IF;

  INSERT INTO reservation_status_history (reservation_id, from_status, to_status, reason, changed_by)
  VALUES (NEW.id, OLD.status, NEW.status, NEW.cancellation_reason, app.current_user_id());
  RETURN NULL;
END;
$$;
CREATE TRIGGER reservations_track_status
  AFTER INSERT OR UPDATE OF status ON reservations
  FOR EACH ROW EXECUTE FUNCTION app.track_reservation_status();

-- Stock balance follows the ledger, with weighted-average costing
-- recomputed on every inbound movement.
CREATE OR REPLACE FUNCTION app.apply_stock_movement()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_qty numeric(14,3); v_cost numeric(14,4);
BEGIN
  INSERT INTO stock_balances (property_id, store_id, item_id, quantity, average_cost)
  VALUES (NEW.property_id, NEW.store_id, NEW.item_id, 0, 0)
  ON CONFLICT (store_id, item_id) DO NOTHING;

  SELECT quantity, average_cost INTO v_qty, v_cost
    FROM stock_balances
   WHERE store_id = NEW.store_id AND item_id = NEW.item_id FOR UPDATE;

  IF NEW.quantity > 0 AND NEW.unit_cost > 0 THEN
    -- Weighted average: only inbound movements move the cost.
    v_cost := CASE WHEN v_qty + NEW.quantity = 0 THEN NEW.unit_cost
                   ELSE ((v_qty * v_cost) + (NEW.quantity * NEW.unit_cost)) / (v_qty + NEW.quantity) END;
  END IF;

  UPDATE stock_balances
     SET quantity = v_qty + NEW.quantity, average_cost = v_cost, updated_at = now()
   WHERE store_id = NEW.store_id AND item_id = NEW.item_id;

  UPDATE stock_movements SET balance_after = v_qty + NEW.quantity WHERE id = NEW.id;
  RETURN NULL;
END;
$$;
CREATE TRIGGER stock_movements_apply
  AFTER INSERT ON stock_movements
  FOR EACH ROW EXECUTE FUNCTION app.apply_stock_movement();

CREATE OR REPLACE FUNCTION app.protect_stock_ledger()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  -- balance_after is written back by the apply trigger; nothing else may change.
  IF TG_OP = 'UPDATE' AND NEW.balance_after IS DISTINCT FROM OLD.balance_after
     AND to_jsonb(NEW) - 'balance_after' = to_jsonb(OLD) - 'balance_after' THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'stock_movements is append-only; post a reversing movement instead'
    USING ERRCODE = 'restrict_violation';
END;
$$;
CREATE TRIGGER stock_movements_immutable
  BEFORE UPDATE OR DELETE ON stock_movements
  FOR EACH ROW EXECUTE FUNCTION app.protect_stock_ledger();

-- Audit triggers on the tables that matter legally and financially.
CREATE TRIGGER reservations_audit       AFTER INSERT OR UPDATE OR DELETE ON reservations       FOR EACH ROW EXECUTE FUNCTION app.audit_trigger('RESERVATIONS');
CREATE TRIGGER invoices_audit           AFTER INSERT OR UPDATE OR DELETE ON invoices           FOR EACH ROW EXECUTE FUNCTION app.audit_trigger('BILLING');
CREATE TRIGGER payments_audit           AFTER INSERT OR UPDATE OR DELETE ON payments           FOR EACH ROW EXECUTE FUNCTION app.audit_trigger('PAYMENTS');
CREATE TRIGGER refunds_audit            AFTER INSERT OR UPDATE OR DELETE ON refunds            FOR EACH ROW EXECUTE FUNCTION app.audit_trigger('PAYMENTS');
CREATE TRIGGER folio_items_audit        AFTER INSERT OR UPDATE OR DELETE ON folio_items        FOR EACH ROW EXECUTE FUNCTION app.audit_trigger('FOLIO');
CREATE TRIGGER journal_entries_audit    AFTER INSERT OR UPDATE OR DELETE ON journal_entries    FOR EACH ROW EXECUTE FUNCTION app.audit_trigger('ACCOUNTING');
CREATE TRIGGER accounts_audit           AFTER INSERT OR UPDATE OR DELETE ON accounts           FOR EACH ROW EXECUTE FUNCTION app.audit_trigger('ACCOUNTING');
CREATE TRIGGER tax_rates_audit          AFTER INSERT OR UPDATE OR DELETE ON tax_rates          FOR EACH ROW EXECUTE FUNCTION app.audit_trigger('TAX');
CREATE TRIGGER room_rates_audit         AFTER INSERT OR UPDATE OR DELETE ON room_rates         FOR EACH ROW EXECUTE FUNCTION app.audit_trigger('RATES');
CREATE TRIGGER rate_restrictions_audit  AFTER INSERT OR UPDATE OR DELETE ON rate_restrictions  FOR EACH ROW EXECUTE FUNCTION app.audit_trigger('RATES');
CREATE TRIGGER user_roles_audit         AFTER INSERT OR UPDATE OR DELETE ON user_roles         FOR EACH ROW EXECUTE FUNCTION app.audit_trigger('SECURITY');
CREATE TRIGGER role_permissions_audit   AFTER INSERT OR UPDATE OR DELETE ON role_permissions   FOR EACH ROW EXECUTE FUNCTION app.audit_trigger('SECURITY');
CREATE TRIGGER settings_audit           AFTER INSERT OR UPDATE OR DELETE ON settings           FOR EACH ROW EXECUTE FUNCTION app.audit_trigger('SETTINGS');
CREATE TRIGGER channels_audit           AFTER INSERT OR UPDATE OR DELETE ON channels           FOR EACH ROW EXECUTE FUNCTION app.audit_trigger('CHANNELS');
CREATE TRIGGER integration_credentials_audit AFTER INSERT OR UPDATE OR DELETE ON integration_credentials FOR EACH ROW EXECUTE FUNCTION app.audit_trigger('SECURITY');
CREATE TRIGGER guests_audit             AFTER INSERT OR UPDATE OR DELETE ON guests             FOR EACH ROW EXECUTE FUNCTION app.audit_trigger('GUESTS');
CREATE TRIGGER room_allocations_audit   AFTER INSERT OR UPDATE OR DELETE ON room_allocations   FOR EACH ROW EXECUTE FUNCTION app.audit_trigger('PMS');
