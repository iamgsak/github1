-- =====================================================================
-- DEMO DATA -- Hotel Amoha
--
-- ***  NOT FOR PRODUCTION.  ***
-- Guarded so it cannot run against a database that already holds real
-- bookings. Every integration created here is a MOCK: the channel uses
-- the MOCK_GENERIC adapter. Nothing here represents live OTA or payment
-- connectivity.
-- =====================================================================

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM reservations LIMIT 1) THEN
    RAISE EXCEPTION 'Refusing to seed demo data: reservations already exist. %',
      'Run this only against an empty database.' USING ERRCODE = 'restrict_violation';
  END IF;
END;
$$;

BEGIN;

INSERT INTO organizations (id, name, slug, legal_name)
VALUES ('11111111-1111-1111-1111-111111111111','Amoha Hospitality','amoha-demo',
        'Amoha Hospitality Private Limited');

INSERT INTO properties (id, organization_id, code, name, legal_name,
                        address_line1, city, state, state_code, postal_code,
                        phone, email, website, gstin, pan, currency_code, timezone,
                        check_in_time, check_out_time)
VALUES ('22222222-2222-2222-2222-222222222222','11111111-1111-1111-1111-111111111111',
        'AMOHA','Hotel Amoha','Amoha Hospitality Private Limited',
        '12 MG Road','Bengaluru','Karnataka','29','560001',
        '+91 80 4000 1234','frontdesk@hotelamoha.example','https://hotelamoha.example',
        '29ABCDE1234F1Z5','ABCDE1234F','INR','Asia/Kolkata','14:00','11:00');

SELECT app.provision_organization_defaults('11111111-1111-1111-1111-111111111111');
SELECT app.provision_property_defaults('22222222-2222-2222-2222-222222222222');

INSERT INTO fiscal_years (id, organization_id, name, start_date, end_date)
VALUES ('33333333-3333-3333-3333-333333333333','11111111-1111-1111-1111-111111111111',
        'FY2026-27', DATE '2026-04-01', DATE '2027-03-31');

INSERT INTO accounting_periods (fiscal_year_id, name, start_date, end_date)
SELECT '33333333-3333-3333-3333-333333333333', to_char(d, 'Mon YYYY'),
       d::date, (d + interval '1 month - 1 day')::date
  FROM generate_series(DATE '2026-04-01', DATE '2027-03-01', interval '1 month') d;

INSERT INTO amenities (organization_id, code, name, category) VALUES
  ('11111111-1111-1111-1111-111111111111','WIFI','Free Wi-Fi','CONNECTIVITY'),
  ('11111111-1111-1111-1111-111111111111','AC','Air Conditioning','COMFORT'),
  ('11111111-1111-1111-1111-111111111111','TV','Smart TV','ENTERTAINMENT'),
  ('11111111-1111-1111-1111-111111111111','BFAST','Breakfast Included','FOOD'),
  ('11111111-1111-1111-1111-111111111111','MINIBAR','Minibar','FOOD'),
  ('11111111-1111-1111-1111-111111111111','SAFE','In-room Safe','SECURITY'),
  ('11111111-1111-1111-1111-111111111111','BALCONY','Private Balcony','COMFORT');

INSERT INTO room_types (id, property_id, code, name, description,
                        max_adults, max_children, max_occupancy, base_occupancy,
                        extra_adult_capacity, base_rate, extra_adult_rate, sort_order)
VALUES
  ('44444444-0000-0000-0000-000000000001','22222222-2222-2222-2222-222222222222',
   'STD','Standard Room','Comfortable 220 sq ft room with city view.',2,1,3,2,1,3500,800,1),
  ('44444444-0000-0000-0000-000000000002','22222222-2222-2222-2222-222222222222',
   'DLX','Deluxe Room','Spacious 320 sq ft room with balcony.',3,2,4,2,2,5500,1000,2),
  ('44444444-0000-0000-0000-000000000003','22222222-2222-2222-2222-222222222222',
   'STE','Executive Suite','Two-room suite with living area.',4,2,5,2,2,9500,1500,3);

-- 24 rooms: floors 1-2 standard, 3 deluxe, 4 suites.
INSERT INTO rooms (property_id, room_type_id, room_number, floor)
SELECT '22222222-2222-2222-2222-222222222222','44444444-0000-0000-0000-000000000001',
       (100 + n)::text, '1' FROM generate_series(1,8) n;
INSERT INTO rooms (property_id, room_type_id, room_number, floor)
SELECT '22222222-2222-2222-2222-222222222222','44444444-0000-0000-0000-000000000001',
       (200 + n)::text, '2' FROM generate_series(1,6) n;
INSERT INTO rooms (property_id, room_type_id, room_number, floor)
SELECT '22222222-2222-2222-2222-222222222222','44444444-0000-0000-0000-000000000002',
       (300 + n)::text, '3' FROM generate_series(1,7) n;
INSERT INTO rooms (property_id, room_type_id, room_number, floor)
SELECT '22222222-2222-2222-2222-222222222222','44444444-0000-0000-0000-000000000003',
       (400 + n)::text, '4' FROM generate_series(1,3) n;

INSERT INTO room_type_amenities (room_type_id, amenity_id)
SELECT rt.id, a.id FROM room_types rt, amenities a
 WHERE rt.property_id = '22222222-2222-2222-2222-222222222222'
   AND a.organization_id = '11111111-1111-1111-1111-111111111111'
   AND (a.code IN ('WIFI','AC','TV')
        OR (rt.code <> 'STD' AND a.code IN ('BFAST','MINIBAR','SAFE'))
        OR (rt.code = 'STE' AND a.code = 'BALCONY'));

INSERT INTO cancellation_policies (id, property_id, code, name, description,
                                   free_cancellation_hours, penalty_type)
VALUES ('55555555-0000-0000-0000-000000000001','22222222-2222-2222-2222-222222222222',
        'FLEX','Flexible','Free cancellation up to 24 hours before arrival.',24,'FIRST_NIGHT'),
       ('55555555-0000-0000-0000-000000000002','22222222-2222-2222-2222-222222222222',
        'NONREF','Non-Refundable','No refund once booked.',0,'FULL_STAY');

INSERT INTO rate_plans (id, property_id, code, name, meal_plan, is_refundable,
                        cancellation_policy_id, is_public, is_channel_enabled)
VALUES ('66666666-0000-0000-0000-000000000001','22222222-2222-2222-2222-222222222222',
        'BAR','Best Available Rate','CP', true,'55555555-0000-0000-0000-000000000001', true, true),
       ('66666666-0000-0000-0000-000000000002','22222222-2222-2222-2222-222222222222',
        'NR','Non-Refundable (-10%)','CP', false,'55555555-0000-0000-0000-000000000002', true, true),
       ('66666666-0000-0000-0000-000000000003','22222222-2222-2222-2222-222222222222',
        'CORP','Corporate Rate','CP', true,'55555555-0000-0000-0000-000000000001', false, false);

INSERT INTO rate_plan_room_types (rate_plan_id, room_type_id, base_rate)
SELECT rp.id, rt.id,
       CASE rp.code WHEN 'NR' THEN rt.base_rate * 0.90
                    WHEN 'CORP' THEN rt.base_rate * 0.85
                    ELSE rt.base_rate END
  FROM rate_plans rp, room_types rt
 WHERE rp.property_id = '22222222-2222-2222-2222-222222222222'
   AND rt.property_id = '22222222-2222-2222-2222-222222222222';

-- Nightly rate grid for a year, with a weekend uplift.
INSERT INTO room_rates (property_id, room_type_id, rate_plan_id, stay_date, rate,
                        extra_adult_rate, source)
SELECT '22222222-2222-2222-2222-222222222222', rprt.room_type_id, rprt.rate_plan_id, d::date,
       round(rprt.base_rate * CASE WHEN EXTRACT(ISODOW FROM d) IN (5,6) THEN 1.20 ELSE 1.00 END, 2),
       rt.extra_adult_rate, 'SEASON'
  FROM rate_plan_room_types rprt
  JOIN room_types rt ON rt.id = rprt.room_type_id
  CROSS JOIN generate_series(DATE '2026-04-01', DATE '2027-03-31', interval '1 day') d
 WHERE rt.property_id = '22222222-2222-2222-2222-222222222222';

INSERT INTO guests (organization_id, guest_code, first_name, last_name, email, phone,
                    city, state, state_code, country_code, email_consent, whatsapp_consent)
VALUES
  ('11111111-1111-1111-1111-111111111111','GST-00001','Asha','Nair','asha.nair@example.com','+919810000001','Bengaluru','Karnataka','29','IN',true,true),
  ('11111111-1111-1111-1111-111111111111','GST-00002','Rohit','Sharma','rohit.sharma@example.com','+919810000002','Mumbai','Maharashtra','27','IN',true,false),
  ('11111111-1111-1111-1111-111111111111','GST-00003','Meera','Iyer','meera.iyer@example.com','+919810000003','Chennai','Tamil Nadu','33','IN',true,true),
  ('11111111-1111-1111-1111-111111111111','GST-00004','Daniel','Fischer','daniel.fischer@example.com','+4915100000004','Berlin',NULL,NULL,'DE',true,false),
  ('11111111-1111-1111-1111-111111111111','GST-00005','Priya','Menon','priya.menon@example.com','+919810000005','Kochi','Kerala','32','IN',false,false);

INSERT INTO corporate_accounts (organization_id, code, company_name, contact_person,
                                phone, email, city, state, state_code, gstin,
                                credit_limit, payment_terms_days, discount_percent)
VALUES ('11111111-1111-1111-1111-111111111111','CORP001','Nimbus Technologies Pvt Ltd',
        'Vikram Rao','+918000000001','accounts@nimbus.example','Bengaluru','Karnataka','29',
        '29AABCN1234M1Z8', 500000, 30, 10);

INSERT INTO travel_agents (organization_id, code, agency_name, contact_person,
                           phone, email, commission_percent, credit_limit)
VALUES ('11111111-1111-1111-1111-111111111111','TA001','Southern Skies Travel',
        'Latha Krishnan','+918000000002','ops@southernskies.example', 10, 200000);

INSERT INTO stores (id, property_id, code, name, store_type) VALUES
  ('77777777-0000-0000-0000-000000000001','22222222-2222-2222-2222-222222222222','MAIN','Main Store','MAIN'),
  ('77777777-0000-0000-0000-000000000002','22222222-2222-2222-2222-222222222222','HK','Housekeeping Store','HOUSEKEEPING');

INSERT INTO suppliers (organization_id, code, name, contact_person, phone, email,
                       city, state, state_code, gstin, payment_terms_days)
VALUES ('11111111-1111-1111-1111-111111111111','SUP001','Deccan Supplies','Ganesh K',
        '+918000000003','sales@deccansupplies.example','Bengaluru','Karnataka','29',
        '29AAACD5678K1ZQ', 30);

INSERT INTO inventory_items (organization_id, code, name, category_id, uom_id, reorder_level, min_stock)
SELECT '11111111-1111-1111-1111-111111111111', v.code, v.name, NULL, u.id, v.reorder, v.minimum
  FROM (VALUES
    ('SOAP','Bath Soap 75g','PCS',200::numeric,100::numeric),
    ('SHAMPOO','Shampoo Sachet','PCS',300,150),
    ('TOWEL','Bath Towel','PCS',100,50),
    ('BEDSHEET','Bed Sheet Double','PCS',80,40),
    ('TEA','Tea Bags','PKT',100,50),
    ('WATER','Mineral Water 1L','BTL',400,200)
  ) AS v(code, name, uom, reorder, minimum)
  JOIN uoms u ON u.code = v.uom AND u.organization_id = '11111111-1111-1111-1111-111111111111';

INSERT INTO stock_movements (property_id, store_id, item_id, movement_type,
                             movement_date, quantity, unit_cost, total_cost)
SELECT '22222222-2222-2222-2222-222222222222','77777777-0000-0000-0000-000000000002',
       i.id,'OPENING', DATE '2026-04-01', v.qty, v.cost, v.qty * v.cost
  FROM (VALUES ('SOAP',500::numeric,12::numeric),('SHAMPOO',800,6),('TOWEL',200,180),
               ('BEDSHEET',150,450),('TEA',300,4),('WATER',600,9)
       ) AS v(code, qty, cost)
  JOIN inventory_items i ON i.code = v.code
   AND i.organization_id = '11111111-1111-1111-1111-111111111111';

-- MOCK channel (NOT a live OTA connection).
INSERT INTO channels (id, property_id, code, name, channel_type, adapter, mode,
                      is_enabled, connection_status, commission_percent, payment_model)
VALUES ('88888888-0000-0000-0000-000000000001','22222222-2222-2222-2222-222222222222',
        'MOCK_OTA','Sandbox OTA (MOCK — not a live connection)','OTA',
        'MOCK_GENERIC','MOCK', true,'CONNECTED', 15,'OTA_COLLECT');

INSERT INTO channel_room_mappings (channel_id, room_type_id, external_room_id, external_room_name)
SELECT '88888888-0000-0000-0000-000000000001', rt.id, 'EXT-' || rt.code, rt.name || ' (sandbox)'
  FROM room_types rt WHERE rt.property_id = '22222222-2222-2222-2222-222222222222';

-- Books one stay end to end (inventory, stay line, nightly rates, room
-- allocation, folio) exactly as the application would.
CREATE OR REPLACE FUNCTION pg_temp.demo_book(
  p_number text, p_guest_code text, p_rt_code text, p_source text,
  p_arrival date, p_departure date, p_status reservation_status, p_adults smallint DEFAULT 2
) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
  v_prop uuid := '22222222-2222-2222-2222-222222222222';
  v_org  uuid := '11111111-1111-1111-1111-111111111111';
  v_rt uuid; v_rp uuid; v_guest uuid; v_src uuid; v_res uuid; v_line uuid;
  v_room uuid; v_total numeric := 0; v_tax numeric; v_folio uuid;
BEGIN
  SELECT id INTO v_rt FROM room_types WHERE property_id = v_prop AND code = p_rt_code;
  SELECT id INTO v_rp FROM rate_plans WHERE property_id = v_prop AND code = 'BAR';
  SELECT id INTO v_guest FROM guests WHERE organization_id = v_org AND guest_code = p_guest_code;
  SELECT id INTO v_src FROM booking_sources WHERE organization_id = v_org AND code = p_source;

  SELECT COALESCE(sum(rate),0) INTO v_total FROM room_rates
   WHERE room_type_id = v_rt AND rate_plan_id = v_rp
     AND stay_date >= p_arrival AND stay_date < p_departure;
  -- 12% GST for tariffs at or below Rs 7,500 a night, else 18%.
  v_tax := round(v_total * CASE WHEN v_total / GREATEST(p_departure - p_arrival,1) > 7500
                                THEN 0.18 ELSE 0.12 END, 2);

  PERFORM app.reserve_inventory(v_prop, v_rt, p_arrival, p_departure, 1);

  v_res := gen_random_uuid();
  INSERT INTO reservations (id, property_id, reservation_number, booking_source_id, guest_id,
                            status, arrival_date, departure_date, adults, rooms_count,
                            room_charges, tax_amount, total_amount, cancellation_policy_id,
                            checked_in_at, checked_out_at)
  VALUES (v_res, v_prop, p_number, v_src, v_guest, p_status, p_arrival, p_departure,
          p_adults, 1, v_total, v_tax, v_total + v_tax,
          '55555555-0000-0000-0000-000000000001',
          CASE WHEN p_status IN ('CHECKED_IN','CHECKED_OUT') THEN p_arrival + time '14:05' END,
          CASE WHEN p_status = 'CHECKED_OUT' THEN p_departure + time '10:40' END);

  v_line := gen_random_uuid();
  INSERT INTO reservation_rooms (id, reservation_id, property_id, room_type_id, rate_plan_id,
                                 arrival_date, departure_date, adults, guest_id,
                                 room_charges, tax_amount, total_amount, status)
  VALUES (v_line, v_res, v_prop, v_rt, v_rp, p_arrival, p_departure, p_adults, v_guest,
          v_total, v_tax, v_total + v_tax,
          CASE p_status WHEN 'CHECKED_IN' THEN 'CHECKED_IN'::reservation_room_status
                        WHEN 'CHECKED_OUT' THEN 'CHECKED_OUT'::reservation_room_status
                        ELSE 'RESERVED'::reservation_room_status END);

  INSERT INTO reservation_room_rates (reservation_room_id, property_id, stay_date,
                                      rate_amount, taxable_amount, tax_amount, total_amount)
  SELECT v_line, v_prop, rr.stay_date, rr.rate, rr.rate,
         round(rr.rate * 0.12, 2), rr.rate + round(rr.rate * 0.12, 2)
    FROM room_rates rr
   WHERE rr.room_type_id = v_rt AND rr.rate_plan_id = v_rp
     AND rr.stay_date >= p_arrival AND rr.stay_date < p_departure;

  -- First free room of the right type for the whole window.
  SELECT r.id INTO v_room FROM rooms r
   WHERE r.property_id = v_prop AND r.room_type_id = v_rt AND r.is_active
     AND NOT EXISTS (SELECT 1 FROM room_allocations ra
                      WHERE ra.room_id = r.id AND ra.is_active
                        AND ra.stay_range && daterange(p_arrival, p_departure, '[)'))
   ORDER BY r.room_number LIMIT 1;

  IF v_room IS NOT NULL THEN
    INSERT INTO room_allocations (property_id, room_id, allocation_type, reservation_room_id,
                                  arrival_date, departure_date)
    VALUES (v_prop, v_room,'RESERVATION', v_line, p_arrival, p_departure);
  END IF;

  v_folio := gen_random_uuid();
  INSERT INTO folios (id, property_id, folio_number, reservation_id, reservation_room_id,
                      guest_id, status, closed_at)
  VALUES (v_folio, v_prop,'FOL-' || p_number, v_res, v_line, v_guest,
          CASE WHEN p_status = 'CHECKED_OUT' THEN 'SETTLED'::folio_status ELSE 'OPEN'::folio_status END,
          -- A settled folio must record when it closed (folios_closed_chk).
          CASE WHEN p_status = 'CHECKED_OUT' THEN p_departure + time '10:40' END);
  UPDATE reservation_rooms SET folio_id = v_folio WHERE id = v_line;

  RETURN v_res;
END;
$$;

SELECT pg_temp.demo_book('RES-2026-27/00001','GST-00001','DLX','DIRECT_WEB', DATE '2026-09-10', DATE '2026-09-14','CHECKED_OUT');
SELECT pg_temp.demo_book('RES-2026-27/00002','GST-00002','STD','BOOKING_COM', DATE '2026-09-12', DATE '2026-09-15','CHECKED_OUT');
SELECT pg_temp.demo_book('RES-2026-27/00003','GST-00003','STE','DIRECT_WEB', DATE '2026-09-18', DATE '2026-09-21','CHECKED_IN');
SELECT pg_temp.demo_book('RES-2026-27/00004','GST-00004','DLX','MAKEMYTRIP', DATE '2026-09-20', DATE '2026-09-24','CONFIRMED');
SELECT pg_temp.demo_book('RES-2026-27/00005','GST-00005','STD','WALK_IN', DATE '2026-09-19', DATE '2026-09-20','CONFIRMED');
SELECT pg_temp.demo_book('RES-2026-27/00006','GST-00001','STD','CORPORATE', DATE '2026-10-01', DATE '2026-10-05','CONFIRMED');
SELECT pg_temp.demo_book('RES-2026-27/00007','GST-00002','DLX','AGODA', DATE '2026-10-08', DATE '2026-10-10','CONFIRMED');

INSERT INTO housekeeping_tasks (property_id, room_id, task_type, status, scheduled_date)
SELECT '22222222-2222-2222-2222-222222222222', r.id,'DAILY_CLEAN','PENDING', CURRENT_DATE
  FROM rooms r WHERE r.property_id = '22222222-2222-2222-2222-222222222222'
 ORDER BY r.room_number LIMIT 8;

INSERT INTO maintenance_tickets (property_id, ticket_number, room_id, category, priority,
                                 title, description, status)
SELECT '22222222-2222-2222-2222-222222222222','MNT-2026-27/00001', r.id,'PLUMBING','HIGH',
       'Leaking tap in bathroom','Guest reported a dripping tap.','OPEN'
  FROM rooms r WHERE r.property_id = '22222222-2222-2222-2222-222222222222' AND r.room_number = '301';

INSERT INTO crm_leads (property_id, lead_number, source, contact_name, company_name,
                       phone, email, requirement, arrival_date, departure_date,
                       room_nights, estimated_value, status)
VALUES ('22222222-2222-2222-2222-222222222222','LEAD-2026-27/00001','WEBSITE',
        'Sanjay Gupta','Orion Systems','+919810000009','sanjay@orion.example',
        'Ten rooms for a three-day offsite.', DATE '2026-11-10', DATE '2026-11-13', 30, 165000,'QUOTATION');

COMMIT;

\echo ''
\echo '  Demo data loaded for Hotel Amoha.'
\echo '  All integrations are MOCK. No live OTA or payment connection exists.'
\echo ''
