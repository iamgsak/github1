-- =====================================================================
-- Integrity test suite.
-- Each block asserts one guarantee the ERP depends on. A test "passes"
-- when the database enforces the rule -- usually by RAISING.
--
-- NOTE: a plpgsql BEGIN/EXCEPTION block is a SUBTRANSACTION. Setup rows
-- created inside one are rolled back along with the deliberate failure,
-- so all setup is done OUTSIDE the exception blocks.
-- =====================================================================

-- A second stay line on the same booking, used as the collision source.
INSERT INTO reservation_rooms (id, reservation_id, property_id, room_type_id, rate_plan_id,
                               arrival_date, departure_date, adults, line_number)
VALUES ('00000000-0000-0000-0000-000000000084','00000000-0000-0000-0000-000000000081',
        '00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-0000000000c1',
        '00000000-0000-0000-0000-0000000000e1', DATE '2026-09-12', DATE '2026-09-16', 2, 2);

-- ---------------------------------------------------------------------
-- RESERVATIONS :: double-booking prevention
-- ---------------------------------------------------------------------
DO $$
BEGIN
  BEGIN
    INSERT INTO room_allocations (property_id, room_id, allocation_type, reservation_room_id,
                                  arrival_date, departure_date)
    VALUES ('00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-0000000000d1',
            'RESERVATION','00000000-0000-0000-0000-000000000084', DATE '2026-09-12', DATE '2026-09-16');
    PERFORM test_ok('reservations','overlapping allocation rejected', false,
                    'INSERT succeeded but should have violated the exclusion constraint');
  EXCEPTION WHEN exclusion_violation THEN
    PERFORM test_ok('reservations','overlapping allocation rejected', true);
  END;
END;
$$;

DO $$
DECLARE v_id uuid;
BEGIN
  -- Back-to-back: departure day == next arrival day is legal.
  BEGIN
    INSERT INTO room_allocations (property_id, room_id, allocation_type, reservation_room_id,
                                  arrival_date, departure_date)
    VALUES ('00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-0000000000d1',
            'RESERVATION','00000000-0000-0000-0000-000000000084', DATE '2026-09-14', DATE '2026-09-16')
    RETURNING id INTO v_id;
    PERFORM test_ok('reservations','back-to-back stay allowed on checkout day', true);
    DELETE FROM room_allocations WHERE id = v_id;
  EXCEPTION WHEN others THEN
    PERFORM test_ok('reservations','back-to-back stay allowed on checkout day', false, SQLERRM);
  END;
END;
$$;

DO $$
DECLARE v_id uuid;
BEGIN
  -- A cancelled (inactive) allocation must stop blocking the room.
  UPDATE room_allocations SET is_active = false, released_at = now()
   WHERE id = '00000000-0000-0000-0000-000000000083';
  BEGIN
    INSERT INTO room_allocations (property_id, room_id, allocation_type, reservation_room_id,
                                  arrival_date, departure_date)
    VALUES ('00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-0000000000d1',
            'RESERVATION','00000000-0000-0000-0000-000000000084', DATE '2026-09-12', DATE '2026-09-16')
    RETURNING id INTO v_id;
    PERFORM test_ok('reservations','released allocation frees the room', true);
    DELETE FROM room_allocations WHERE id = v_id;
  EXCEPTION WHEN others THEN
    PERFORM test_ok('reservations','released allocation frees the room', false, SQLERRM);
  END;
  UPDATE room_allocations SET is_active = true, released_at = NULL
   WHERE id = '00000000-0000-0000-0000-000000000083';
END;
$$;

DO $$
BEGIN
  -- An OOO block must collide with a booking in the same room: this is
  -- why both live in one table.
  BEGIN
    INSERT INTO room_allocations (property_id, room_id, allocation_type, arrival_date, departure_date, reason)
    VALUES ('00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-0000000000d1',
            'OUT_OF_ORDER', DATE '2026-09-11', DATE '2026-09-13', 'AC repair');
    PERFORM test_ok('reservations','OOO block collides with existing booking', false,
                    'OOO block was accepted over an occupied room');
  EXCEPTION WHEN exclusion_violation THEN
    PERFORM test_ok('reservations','OOO block collides with existing booking', true);
  END;
END;
$$;

-- A room of a different type, for the mismatch test.
INSERT INTO room_types (id, property_id, code, name, base_rate)
VALUES ('00000000-0000-0000-0000-0000000000c9','00000000-0000-0000-0000-0000000000b1','STD','Standard',3000);
INSERT INTO rooms (id, property_id, room_type_id, room_number)
VALUES ('00000000-0000-0000-0000-0000000000d9','00000000-0000-0000-0000-0000000000b1',
        '00000000-0000-0000-0000-0000000000c9','201');

DO $$
BEGIN
  BEGIN
    INSERT INTO room_allocations (property_id, room_id, allocation_type, reservation_room_id,
                                  arrival_date, departure_date)
    VALUES ('00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-0000000000d9',
            'RESERVATION','00000000-0000-0000-0000-000000000084', DATE '2026-09-12', DATE '2026-09-16');
    PERFORM test_ok('reservations','room type mismatch rejected', false, 'mismatched allocation accepted');
  EXCEPTION WHEN check_violation THEN
    PERFORM test_ok('reservations','room type mismatch rejected', true);
  END;

  -- An allocation may not extend beyond the stay it belongs to.
  BEGIN
    INSERT INTO room_allocations (property_id, room_id, allocation_type, reservation_room_id,
                                  arrival_date, departure_date)
    VALUES ('00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-0000000000d2',
            'RESERVATION','00000000-0000-0000-0000-000000000084', DATE '2026-09-12', DATE '2026-09-20');
    PERFORM test_ok('reservations','allocation outside stay dates rejected', false, 'accepted');
  EXCEPTION WHEN check_violation THEN
    PERFORM test_ok('reservations','allocation outside stay dates rejected', true);
  END;
END;
$$;

-- Walk the booking through its legal lifecycle first.
UPDATE reservations SET status = 'CHECKED_IN', checked_in_at = now()
 WHERE id = '00000000-0000-0000-0000-000000000081';
UPDATE reservations SET status = 'CHECKED_OUT', checked_out_at = now()
 WHERE id = '00000000-0000-0000-0000-000000000081';

DO $$
BEGIN
  -- A checked-out stay cannot go back.
  BEGIN
    UPDATE reservations SET status = 'CONFIRMED'
     WHERE id = '00000000-0000-0000-0000-000000000081';
    PERFORM test_ok('reservations','illegal status transition rejected', false,
                    'CHECKED_OUT -> CONFIRMED allowed');
  EXCEPTION WHEN check_violation THEN
    PERFORM test_ok('reservations','illegal status transition rejected', true);
  END;
END;
$$;

DO $$
DECLARE v_count integer;
BEGIN
  SELECT count(*) INTO v_count FROM reservation_status_history
   WHERE reservation_id = '00000000-0000-0000-0000-000000000081';
  -- INSERT + CONFIRMED->CHECKED_IN + CHECKED_IN->CHECKED_OUT
  PERFORM test_ok('reservations','status history recorded', v_count >= 3,
                  format('%s history rows', v_count));
END;
$$;

-- ---------------------------------------------------------------------
-- AVAILABILITY :: oversell prevention at the room-type level
-- ---------------------------------------------------------------------
DO $$
DECLARE v_avail integer;
BEGIN
  PERFORM app.ensure_inventory_rows('00000000-0000-0000-0000-0000000000b1',
          '00000000-0000-0000-0000-0000000000c1', DATE '2026-09-20', DATE '2026-09-23');
  v_avail := app.check_availability('00000000-0000-0000-0000-0000000000b1',
             '00000000-0000-0000-0000-0000000000c1', DATE '2026-09-20', DATE '2026-09-23');
  PERFORM test_ok('availability','two rooms available before selling', v_avail = 2, format('got %s', v_avail));

  PERFORM app.reserve_inventory('00000000-0000-0000-0000-0000000000b1',
          '00000000-0000-0000-0000-0000000000c1', DATE '2026-09-20', DATE '2026-09-23', 2);
  v_avail := app.check_availability('00000000-0000-0000-0000-0000000000b1',
             '00000000-0000-0000-0000-0000000000c1', DATE '2026-09-20', DATE '2026-09-23');
  PERFORM test_ok('availability','zero available after selling both', v_avail = 0, format('got %s', v_avail));

  BEGIN
    PERFORM app.reserve_inventory('00000000-0000-0000-0000-0000000000b1',
            '00000000-0000-0000-0000-0000000000c1', DATE '2026-09-20', DATE '2026-09-23', 1);
    PERFORM test_ok('availability','third booking rejected (oversell)', false, 'oversell accepted');
  EXCEPTION WHEN exclusion_violation THEN
    PERFORM test_ok('availability','third booking rejected (oversell)', true);
  END;
END;
$$;

-- ---------------------------------------------------------------------
-- ACCOUNTING :: the books must balance
-- ---------------------------------------------------------------------
DO $$
DECLARE v_entry uuid := gen_random_uuid();
BEGIN
  BEGIN
    INSERT INTO journal_entries (id, organization_id, property_id, entry_number, entry_date,
                                 journal_type, narration, is_posted, posted_at)
    VALUES (v_entry,'00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-0000000000b1',
            'JV-UNBAL-1', DATE '2026-09-15','GENERAL','Deliberately unbalanced', true, now());
    INSERT INTO journal_lines (journal_entry_id, property_id, line_number, account_id, debit)
    SELECT v_entry,'00000000-0000-0000-0000-0000000000b1',1, id, 1000
      FROM accounts WHERE organization_id='00000000-0000-0000-0000-0000000000a1' AND code='1110';
    INSERT INTO journal_lines (journal_entry_id, property_id, line_number, account_id, credit)
    SELECT v_entry,'00000000-0000-0000-0000-0000000000b1',2, id, 900   -- mismatch
      FROM accounts WHERE organization_id='00000000-0000-0000-0000-0000000000a1' AND code='4100';
    -- Force the deferred constraint trigger to fire now.
    SET CONSTRAINTS ALL IMMEDIATE;
    PERFORM test_ok('accounting','unbalanced journal entry rejected', false, 'unbalanced entry accepted');
  EXCEPTION WHEN check_violation THEN
    PERFORM test_ok('accounting','unbalanced journal entry rejected', true);
  END;
END;
$$;

DO $$
DECLARE v_entry uuid := gen_random_uuid();
BEGIN
  -- Rs 5,000 room revenue + 12% GST.
  INSERT INTO journal_entries (id, organization_id, property_id, entry_number, entry_date,
                               journal_type, narration, source_type, source_id, is_posted, posted_at)
  VALUES (v_entry,'00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-0000000000b1',
          'JV-TEST-1', DATE '2026-09-15','SALES','Room revenue with GST',
          'TEST', gen_random_uuid(), true, now());
  INSERT INTO journal_lines (journal_entry_id, property_id, line_number, account_id, debit, credit)
  SELECT v_entry,'00000000-0000-0000-0000-0000000000b1', v.ln, a.id, v.dr, v.cr
    FROM (VALUES (1,'1110',5600.00,0.00),   -- Cash received
                 (2,'4100',0.00,5000.00),   -- Room revenue
                 (3,'2120',0.00,300.00),    -- Output CGST 6%
                 (4,'2121',0.00,300.00)     -- Output SGST 6%
         ) AS v(ln, code, dr, cr)
    JOIN accounts a ON a.code = v.code AND a.organization_id='00000000-0000-0000-0000-0000000000a1';
  SET CONSTRAINTS ALL IMMEDIATE;
  PERFORM test_ok('accounting','balanced journal entry posts', true);
EXCEPTION WHEN others THEN
  PERFORM test_ok('accounting','balanced journal entry posts', false, SQLERRM);
END;
$$;

DO $$
DECLARE v_sum numeric;
BEGIN
  SELECT COALESCE(sum(net_balance),0) INTO v_sum FROM v_trial_balance
   WHERE property_id = '00000000-0000-0000-0000-0000000000b1';
  PERFORM test_ok('accounting','trial balance nets to zero', v_sum = 0, format('net = %s', v_sum));
END;
$$;

DO $$
DECLARE v_entry uuid;
BEGIN
  SELECT id INTO v_entry FROM journal_entries WHERE entry_number = 'JV-TEST-1';
  BEGIN
    UPDATE journal_entries SET narration = 'tampered' WHERE id = v_entry;
    PERFORM test_ok('accounting','posted entry is immutable', false, 'narration edit allowed');
  EXCEPTION WHEN restrict_violation THEN
    PERFORM test_ok('accounting','posted entry is immutable', true);
  END;
  BEGIN
    DELETE FROM journal_entries WHERE id = v_entry;
    PERFORM test_ok('accounting','posted entry cannot be deleted', false, 'delete allowed');
  EXCEPTION WHEN restrict_violation THEN
    PERFORM test_ok('accounting','posted entry cannot be deleted', true);
  END;
  BEGIN
    UPDATE journal_lines SET debit = 9999 WHERE journal_entry_id = v_entry AND line_number = 1;
    PERFORM test_ok('accounting','posted lines are immutable', false, 'line edit allowed');
  EXCEPTION WHEN restrict_violation THEN
    PERFORM test_ok('accounting','posted lines are immutable', true);
  END;
END;
$$;

DO $$
BEGIN
  BEGIN
    INSERT INTO journal_entries (organization_id, property_id, entry_number, entry_date,
                                 journal_type, narration)
    VALUES ('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-0000000000b1',
            'JV-CLOSED-1', DATE '2026-08-15','GENERAL','Into a closed period');
    PERFORM test_ok('accounting','closed period rejects postings', false, 'posting into CLOSED period allowed');
  EXCEPTION WHEN restrict_violation THEN
    PERFORM test_ok('accounting','closed period rejects postings', true);
  END;

  -- A line cannot be both a debit and a credit.
  BEGIN
    INSERT INTO journal_entries (id, organization_id, property_id, entry_number, entry_date, journal_type, narration)
    VALUES ('00000000-0000-0000-0000-0000000000aa','00000000-0000-0000-0000-0000000000a1',
            '00000000-0000-0000-0000-0000000000b1','JV-BOTH-1', DATE '2026-09-16','GENERAL','both sides');
    INSERT INTO journal_lines (journal_entry_id, property_id, line_number, account_id, debit, credit)
    SELECT '00000000-0000-0000-0000-0000000000aa','00000000-0000-0000-0000-0000000000b1',1,id,100,100
      FROM accounts WHERE organization_id='00000000-0000-0000-0000-0000000000a1' AND code='1110';
    PERFORM test_ok('accounting','line cannot be both debit and credit', false, 'accepted');
  EXCEPTION WHEN check_violation THEN
    PERFORM test_ok('accounting','line cannot be both debit and credit', true);
  END;
END;
$$;

-- ---------------------------------------------------------------------
-- GST / INVOICING
-- ---------------------------------------------------------------------
DO $$
BEGIN
  BEGIN
    INSERT INTO invoices (property_id, invoice_number, invoice_date, bill_to_name,
                          taxable_value, cgst_amount, sgst_amount, total_amount)
    VALUES ('00000000-0000-0000-0000-0000000000b1','INV-BAD-1', DATE '2026-09-15','Test Guest',
            5000, 300, 250, 5550);
    PERFORM test_ok('gst','CGST must equal SGST', false, 'unequal split accepted');
  EXCEPTION WHEN check_violation THEN
    PERFORM test_ok('gst','CGST must equal SGST', true);
  END;

  BEGIN
    INSERT INTO invoices (property_id, invoice_number, invoice_date, bill_to_name, is_interstate,
                          taxable_value, cgst_amount, sgst_amount, igst_amount, total_amount)
    VALUES ('00000000-0000-0000-0000-0000000000b1','INV-BAD-2', DATE '2026-09-15','Test Guest', true,
            5000, 300, 300, 600, 6200);
    PERFORM test_ok('gst','CGST/SGST and IGST are mutually exclusive', false, 'both accepted');
  EXCEPTION WHEN check_violation THEN
    PERFORM test_ok('gst','CGST/SGST and IGST are mutually exclusive', true);
  END;

  BEGIN
    INSERT INTO invoices (property_id, invoice_number, invoice_date, bill_to_name, is_b2b,
                          taxable_value, cgst_amount, sgst_amount, total_amount)
    VALUES ('00000000-0000-0000-0000-0000000000b1','INV-BAD-3', DATE '2026-09-15','Corp Guest', true,
            5000, 300, 300, 5600);
    PERFORM test_ok('gst','B2B invoice requires buyer GSTIN', false, 'accepted without GSTIN');
  EXCEPTION WHEN check_violation THEN
    PERFORM test_ok('gst','B2B invoice requires buyer GSTIN', true);
  END;

  BEGIN
    INSERT INTO invoices (property_id, invoice_number, invoice_date, bill_to_name,
                          taxable_value, cgst_amount, sgst_amount, total_amount)
    VALUES ('00000000-0000-0000-0000-0000000000b1','INV-BAD-4', DATE '2026-09-15','Test Guest',
            5000, 300, 300, 9999);
    PERFORM test_ok('gst','invoice total must equal taxable + tax', false, 'bad total accepted');
  EXCEPTION WHEN check_violation THEN
    PERFORM test_ok('gst','invoice total must equal taxable + tax', true);
  END;

  BEGIN
    INSERT INTO invoices (property_id, invoice_number, invoice_date, bill_to_name, place_of_supply,
                          taxable_value, cgst_amount, sgst_amount, total_amount, status, issued_at)
    VALUES ('00000000-0000-0000-0000-0000000000b1','INV-GOOD-1', DATE '2026-09-15','Asha Nair','29',
            5000, 300, 300, 5600, 'ISSUED', now());
    PERFORM test_ok('gst','valid GST invoice accepted', true);
  EXCEPTION WHEN others THEN
    PERFORM test_ok('gst','valid GST invoice accepted', false, SQLERRM);
  END;

  BEGIN
    INSERT INTO invoices (property_id, invoice_number, invoice_type, invoice_date, bill_to_name,
                          taxable_value, cgst_amount, sgst_amount, total_amount)
    VALUES ('00000000-0000-0000-0000-0000000000b1','CRN-BAD-1','CREDIT_NOTE', DATE '2026-09-16','Asha Nair',
            1000, 60, 60, 1120);
    PERFORM test_ok('gst','credit note requires original invoice', false, 'orphan credit note accepted');
  EXCEPTION WHEN check_violation THEN
    PERFORM test_ok('gst','credit note requires original invoice', true);
  END;
END;
$$;

-- ---------------------------------------------------------------------
-- OTA / WEBHOOK IDEMPOTENCY
-- ---------------------------------------------------------------------
INSERT INTO channels (id, property_id, code, name, adapter, mode, connection_status, is_enabled)
VALUES ('00000000-0000-0000-0000-0000000000ca','00000000-0000-0000-0000-0000000000b1',
        'MOCK_OTA','Mock OTA','MOCK_GENERIC','MOCK','CONNECTED', true);

INSERT INTO webhook_events (property_id, provider, channel_id, event_id, event_type,
                            payload, signature_verified, status)
VALUES ('00000000-0000-0000-0000-0000000000b1','MOCK_OTA','00000000-0000-0000-0000-0000000000ca',
        'evt_12345','NEW','{"booking":"XYZ"}'::jsonb, true, 'SUCCESS');

INSERT INTO ota_reservations (property_id, channel_id, external_reservation_id, raw_payload, payload_checksum)
VALUES ('00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-0000000000ca','OTA-BK-77',
        '{"id":"OTA-BK-77"}'::jsonb,'abc123');

INSERT INTO reservations (property_id, reservation_number, guest_id, channel_id, external_reference,
                          status, arrival_date, departure_date, adults)
VALUES ('00000000-0000-0000-0000-0000000000b1','RES-OTA-1','00000000-0000-0000-0000-000000000091',
        '00000000-0000-0000-0000-0000000000ca','OTA-BK-77','CONFIRMED', DATE '2026-09-25', DATE '2026-09-27', 2);

INSERT INTO sync_queue (property_id, channel_id, sync_type, dedupe_key)
VALUES ('00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-0000000000ca','AVAILABILITY','avail:2026-09');

DO $$
BEGIN
  -- Layer 1: the same webhook delivery can only be recorded once.
  BEGIN
    INSERT INTO webhook_events (property_id, provider, channel_id, event_id, event_type,
                                payload, signature_verified)
    VALUES ('00000000-0000-0000-0000-0000000000b1','MOCK_OTA','00000000-0000-0000-0000-0000000000ca',
            'evt_12345','NEW','{"booking":"XYZ"}'::jsonb, true);
    PERFORM test_ok('ota','duplicate webhook delivery rejected', false, 'replay accepted');
  EXCEPTION WHEN unique_violation THEN
    PERFORM test_ok('ota','duplicate webhook delivery rejected', true);
  END;

  BEGIN
    INSERT INTO webhook_events (property_id, provider, event_id, payload, signature_verified, status)
    VALUES ('00000000-0000-0000-0000-0000000000b1','MOCK_OTA','evt_unverified','{}'::jsonb, false, 'SUCCESS');
    PERFORM test_ok('ota','unverified webhook cannot succeed', false, 'accepted');
  EXCEPTION WHEN check_violation THEN
    PERFORM test_ok('ota','unverified webhook cannot succeed', true);
  END;

  -- Layer 2: one OTA booking id maps to at most one staging row.
  BEGIN
    INSERT INTO ota_reservations (property_id, channel_id, external_reservation_id, raw_payload, payload_checksum)
    VALUES ('00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-0000000000ca','OTA-BK-77',
            '{"id":"OTA-BK-77"}'::jsonb,'abc123');
    PERFORM test_ok('ota','duplicate OTA reservation rejected', false, 'duplicate accepted');
  EXCEPTION WHEN unique_violation THEN
    PERFORM test_ok('ota','duplicate OTA reservation rejected', true);
  END;

  -- Layer 3: one external reference maps to at most one reservation.
  BEGIN
    INSERT INTO reservations (property_id, reservation_number, guest_id, channel_id, external_reference,
                              status, arrival_date, departure_date, adults)
    VALUES ('00000000-0000-0000-0000-0000000000b1','RES-OTA-2','00000000-0000-0000-0000-000000000091',
            '00000000-0000-0000-0000-0000000000ca','OTA-BK-77','CONFIRMED', DATE '2026-09-25', DATE '2026-09-27', 2);
    PERFORM test_ok('ota','duplicate external reference rejected', false, 'second reservation created');
  EXCEPTION WHEN unique_violation THEN
    PERFORM test_ok('ota','duplicate external reference rejected', true);
  END;

  -- A MOCK channel may not masquerade as a production adapter.
  BEGIN
    INSERT INTO channels (property_id, code, name, adapter, mode)
    VALUES ('00000000-0000-0000-0000-0000000000b1','FAKE','Fake Booking.com','BOOKING_COM','MOCK');
    PERFORM test_ok('ota','mock mode requires a mock adapter', false, 'mislabelled channel accepted');
  EXCEPTION WHEN check_violation THEN
    PERFORM test_ok('ota','mock mode requires a mock adapter', true);
  END;

  -- Only one pending sync job per dedupe key.
  BEGIN
    INSERT INTO sync_queue (property_id, channel_id, sync_type, dedupe_key)
    VALUES ('00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-0000000000ca',
            'AVAILABILITY','avail:2026-09');
    PERFORM test_ok('ota','sync jobs deduplicate while pending', false, 'duplicate job queued');
  EXCEPTION WHEN unique_violation THEN
    PERFORM test_ok('ota','sync jobs deduplicate while pending', true);
  END;
END;
$$;

-- ---------------------------------------------------------------------
-- PAYMENTS
-- ---------------------------------------------------------------------
INSERT INTO payment_gateway_transactions (property_id, gateway, gateway_order_id, gateway_payment_id,
                                          amount, status, signature_verified_at)
VALUES ('00000000-0000-0000-0000-0000000000b1','MOCK','order_1','pay_abc',5600,'CAPTURED', now());

DO $$
BEGIN
  BEGIN
    INSERT INTO payment_gateway_transactions (property_id, gateway, gateway_order_id, gateway_payment_id,
                                              amount, status, signature_verified_at)
    VALUES ('00000000-0000-0000-0000-0000000000b1','MOCK','order_2','pay_abc',5600,'CAPTURED', now());
    PERFORM test_ok('payments','duplicate gateway payment rejected', false, 'double capture accepted');
  EXCEPTION WHEN unique_violation THEN
    PERFORM test_ok('payments','duplicate gateway payment rejected', true);
  END;

  BEGIN
    INSERT INTO payment_gateway_transactions (property_id, gateway, gateway_payment_id, amount, status)
    VALUES ('00000000-0000-0000-0000-0000000000b1','MOCK','pay_unverified',1000,'CAPTURED');
    PERFORM test_ok('payments','capture requires verification', false, 'unverified capture accepted');
  EXCEPTION WHEN check_violation THEN
    PERFORM test_ok('payments','capture requires verification', true);
  END;
END;
$$;

-- ---------------------------------------------------------------------
-- FOLIO
-- ---------------------------------------------------------------------
INSERT INTO folios (id, property_id, folio_number, reservation_id, guest_id)
VALUES ('00000000-0000-0000-0000-0000000000fa','00000000-0000-0000-0000-0000000000b1','FOL-TEST-1',
        '00000000-0000-0000-0000-000000000081','00000000-0000-0000-0000-000000000091');

DO $$
DECLARE v_charge uuid; v_total numeric; v_balance numeric;
BEGIN
  SELECT id INTO v_charge FROM charge_codes
   WHERE property_id='00000000-0000-0000-0000-0000000000b1' AND code='ROOM';

  BEGIN
    INSERT INTO folio_items (folio_id, property_id, charge_code_id, description,
                             quantity, unit_price, gross_amount, discount_amount,
                             taxable_amount, tax_amount, total_amount)
    VALUES ('00000000-0000-0000-0000-0000000000fa','00000000-0000-0000-0000-0000000000b1', v_charge,
            'Bad maths', 1, 5000, 5000, 0, 5000, 600, 9999);
    PERFORM test_ok('folio','line arithmetic enforced', false, 'inconsistent line accepted');
  EXCEPTION WHEN check_violation THEN
    PERFORM test_ok('folio','line arithmetic enforced', true);
  END;

  INSERT INTO folio_items (folio_id, property_id, charge_code_id, description,
                           quantity, unit_price, gross_amount, discount_amount,
                           taxable_amount, tax_amount, total_amount)
  VALUES ('00000000-0000-0000-0000-0000000000fa','00000000-0000-0000-0000-0000000000b1', v_charge,
          'Room 10 Sep', 1, 5000, 5000, 0, 5000, 600, 5600),
         ('00000000-0000-0000-0000-0000000000fa','00000000-0000-0000-0000-0000000000b1', v_charge,
          'Room 11 Sep', 1, 5000, 5000, 0, 5000, 600, 5600);

  SELECT total_charges, balance INTO v_total, v_balance FROM folios
   WHERE id = '00000000-0000-0000-0000-0000000000fa';
  PERFORM test_ok('folio','folio total tracks its charges', v_total = 11200, format('got %s', v_total));
  PERFORM test_ok('folio','folio balance derives from charges - payments', v_balance = 11200, format('got %s', v_balance));

  INSERT INTO payments (property_id, payment_number, payment_date, folio_id, reservation_id,
                        guest_id, payment_method_id, amount, status)
  SELECT '00000000-0000-0000-0000-0000000000b1','RCP-TEST-1', DATE '2026-09-11',
         '00000000-0000-0000-0000-0000000000fa','00000000-0000-0000-0000-000000000081',
         '00000000-0000-0000-0000-000000000091', pm.id, 5600,'CAPTURED'
    FROM payment_methods pm
   WHERE pm.property_id='00000000-0000-0000-0000-0000000000b1' AND pm.code='CASH';

  SELECT balance INTO v_balance FROM folios WHERE id = '00000000-0000-0000-0000-0000000000fa';
  PERFORM test_ok('folio','payment reduces folio balance', v_balance = 5600, format('got %s', v_balance));

  UPDATE folio_items SET is_void = true, voided_at = now(), void_reason = 'Posted in error'
   WHERE folio_id = '00000000-0000-0000-0000-0000000000fa' AND description = 'Room 11 Sep';
  SELECT total_charges INTO v_total FROM folios WHERE id = '00000000-0000-0000-0000-0000000000fa';
  PERFORM test_ok('folio','voided charge leaves the total', v_total = 5600, format('got %s', v_total));

  BEGIN
    UPDATE folio_items SET is_void = true, voided_at = now(), void_reason = NULL
     WHERE folio_id = '00000000-0000-0000-0000-0000000000fa' AND description = 'Room 10 Sep';
    PERFORM test_ok('folio','void requires a reason', false, 'void without reason accepted');
  EXCEPTION WHEN check_violation THEN
    PERFORM test_ok('folio','void requires a reason', true);
  END;
END;
$$;

-- ---------------------------------------------------------------------
-- AUDIT LOG
-- ---------------------------------------------------------------------
DO $$
DECLARE v_count integer; v_old jsonb; v_new jsonb;
BEGIN
  SELECT count(*) INTO v_count FROM audit_logs
   WHERE table_name = 'reservations' AND record_id = '00000000-0000-0000-0000-000000000081';
  PERFORM test_ok('audit','reservation changes are logged', v_count > 0, format('%s rows', v_count));

  SELECT old_values, new_values INTO v_old, v_new FROM audit_logs
   WHERE table_name='reservations' AND action='UPDATE'
     AND 'status' = ANY(changed_fields) ORDER BY id LIMIT 1;
  PERFORM test_ok('audit','old and new values captured',
                  v_old->>'status' IS DISTINCT FROM v_new->>'status',
                  format('%s -> %s', v_old->>'status', v_new->>'status'));

  BEGIN
    UPDATE audit_logs SET action = 'INSERT' WHERE id = (SELECT min(id) FROM audit_logs);
    PERFORM test_ok('audit','audit log is immutable', false, 'update allowed');
  EXCEPTION WHEN restrict_violation THEN
    PERFORM test_ok('audit','audit log is immutable', true);
  END;

  BEGIN
    DELETE FROM audit_logs WHERE id = (SELECT min(id) FROM audit_logs);
    PERFORM test_ok('audit','audit log cannot be deleted', false, 'delete allowed');
  EXCEPTION WHEN restrict_violation THEN
    PERFORM test_ok('audit','audit log cannot be deleted', true);
  END;
END;
$$;

-- ---------------------------------------------------------------------
-- DOCUMENT NUMBERING
-- ---------------------------------------------------------------------
DO $$
DECLARE n1 text; n2 text;
BEGIN
  n1 := app.next_document_number('00000000-0000-0000-0000-0000000000b1','INVOICE',
        (SELECT fiscal_year FROM document_series
          WHERE property_id='00000000-0000-0000-0000-0000000000b1' AND doc_type='INVOICE'));
  n2 := app.next_document_number('00000000-0000-0000-0000-0000000000b1','INVOICE',
        (SELECT fiscal_year FROM document_series
          WHERE property_id='00000000-0000-0000-0000-0000000000b1' AND doc_type='INVOICE'));
  PERFORM test_ok('numbering','document numbers are sequential and distinct',
                  n1 <> n2 AND n1 LIKE 'INV-%', format('%s then %s', n1, n2));
END;
$$;

-- ---------------------------------------------------------------------
-- INVENTORY (stock)
-- ---------------------------------------------------------------------
INSERT INTO stores (id, property_id, code, name)
VALUES ('00000000-0000-0000-0000-0000000000da','00000000-0000-0000-0000-0000000000b1','MAIN','Main Store');
INSERT INTO inventory_items (id, organization_id, code, name, uom_id)
SELECT '00000000-0000-0000-0000-0000000000db','00000000-0000-0000-0000-0000000000a1','SOAP','Bath Soap', id
  FROM uoms WHERE organization_id='00000000-0000-0000-0000-0000000000a1' AND code='PCS';

DO $$
DECLARE v_qty numeric; v_cost numeric;
BEGIN
  -- 100 @ 10, then 100 @ 20  =>  weighted average must be 15.
  INSERT INTO stock_movements (property_id, store_id, item_id, movement_type, quantity, unit_cost, total_cost)
  VALUES ('00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-0000000000da',
          '00000000-0000-0000-0000-0000000000db','PURCHASE',100,10,1000);
  INSERT INTO stock_movements (property_id, store_id, item_id, movement_type, quantity, unit_cost, total_cost)
  VALUES ('00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-0000000000da',
          '00000000-0000-0000-0000-0000000000db','PURCHASE',100,20,2000);

  SELECT quantity, average_cost INTO v_qty, v_cost FROM stock_balances
   WHERE store_id = '00000000-0000-0000-0000-0000000000da' AND item_id = '00000000-0000-0000-0000-0000000000db';
  PERFORM test_ok('inventory','stock quantity accumulates', v_qty = 200, format('got %s', v_qty));
  PERFORM test_ok('inventory','weighted average cost is correct', v_cost = 15, format('got %s', v_cost));

  INSERT INTO stock_movements (property_id, store_id, item_id, movement_type, quantity, unit_cost, total_cost)
  VALUES ('00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-0000000000da',
          '00000000-0000-0000-0000-0000000000db','CONSUMPTION',-50,15,-750);
  SELECT quantity, average_cost INTO v_qty, v_cost FROM stock_balances
   WHERE store_id = '00000000-0000-0000-0000-0000000000da' AND item_id = '00000000-0000-0000-0000-0000000000db';
  PERFORM test_ok('inventory','consumption reduces stock', v_qty = 150, format('got %s', v_qty));
  PERFORM test_ok('inventory','consumption does not move average cost', v_cost = 15, format('got %s', v_cost));

  BEGIN
    INSERT INTO stock_movements (property_id, store_id, item_id, movement_type, quantity, unit_cost)
    VALUES ('00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-0000000000da',
            '00000000-0000-0000-0000-0000000000db','CONSUMPTION',50,15);
    PERFORM test_ok('inventory','movement direction enforced', false, 'positive consumption accepted');
  EXCEPTION WHEN check_violation THEN
    PERFORM test_ok('inventory','movement direction enforced', true);
  END;

  BEGIN
    DELETE FROM stock_movements WHERE store_id = '00000000-0000-0000-0000-0000000000da';
    PERFORM test_ok('inventory','stock ledger is append-only', false, 'delete allowed');
  EXCEPTION WHEN restrict_violation THEN
    PERFORM test_ok('inventory','stock ledger is append-only', true);
  END;
END;
$$;
