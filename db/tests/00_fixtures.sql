-- Deterministic fixtures for the integrity tests.
-- Fixed UUIDs so assertions can reference rows directly.

CREATE TABLE IF NOT EXISTS test_results (
  suite  text, name text, passed boolean, detail text,
  run_at timestamptz DEFAULT now()
);
TRUNCATE test_results;

CREATE OR REPLACE FUNCTION test_ok(p_suite text, p_name text, p_passed boolean, p_detail text DEFAULT NULL)
RETURNS void LANGUAGE sql AS $$
  INSERT INTO test_results(suite, name, passed, detail) VALUES (p_suite, p_name, p_passed, p_detail);
$$;

INSERT INTO organizations (id, name, slug, legal_name)
VALUES ('00000000-0000-0000-0000-0000000000a1','Amoha Hospitality','amoha','Amoha Hospitality Pvt Ltd');
-- A second tenant, used to prove cross-tenant isolation.
INSERT INTO organizations (id, name, slug)
VALUES ('00000000-0000-0000-0000-0000000000a2','Rival Group','rival');

INSERT INTO properties (id, organization_id, code, name, city, state, state_code, gstin, currency_code)
VALUES ('00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-0000000000a1',
        'AMOHA','Hotel Amoha','Bengaluru','Karnataka','29','29ABCDE1234F1Z5','INR');
INSERT INTO properties (id, organization_id, code, name)
VALUES ('00000000-0000-0000-0000-0000000000b2','00000000-0000-0000-0000-0000000000a2','RIVAL','Rival Hotel');

SELECT app.provision_organization_defaults('00000000-0000-0000-0000-0000000000a1');
SELECT app.provision_property_defaults('00000000-0000-0000-0000-0000000000b1');

INSERT INTO fiscal_years (id, organization_id, name, start_date, end_date)
VALUES ('00000000-0000-0000-0000-0000000000f1','00000000-0000-0000-0000-0000000000a1',
        'FY2026-27', DATE '2026-04-01', DATE '2027-03-31');
INSERT INTO accounting_periods (id, fiscal_year_id, name, start_date, end_date, status)
VALUES ('00000000-0000-0000-0000-0000000000f2','00000000-0000-0000-0000-0000000000f1',
        'Sep 2026', DATE '2026-09-01', DATE '2026-09-30','OPEN'),
       ('00000000-0000-0000-0000-0000000000f3','00000000-0000-0000-0000-0000000000f1',
        'Aug 2026', DATE '2026-08-01', DATE '2026-08-31','CLOSED');

-- Room type with exactly TWO rooms: makes oversell tests unambiguous.
INSERT INTO room_types (id, property_id, code, name, total_rooms, base_occupancy, max_adults, max_occupancy, base_rate)
VALUES ('00000000-0000-0000-0000-0000000000c1','00000000-0000-0000-0000-0000000000b1',
        'DLX','Deluxe Room', 0, 2, 2, 3, 5000);

INSERT INTO rooms (id, property_id, room_type_id, room_number, floor) VALUES
  ('00000000-0000-0000-0000-0000000000d1','00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-0000000000c1','101','1'),
  ('00000000-0000-0000-0000-0000000000d2','00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-0000000000c1','102','1');

INSERT INTO rate_plans (id, property_id, code, name, meal_plan, is_public)
VALUES ('00000000-0000-0000-0000-0000000000e1','00000000-0000-0000-0000-0000000000b1','BAR','Best Available Rate','CP', true);

INSERT INTO rate_plan_room_types (rate_plan_id, room_type_id, base_rate)
VALUES ('00000000-0000-0000-0000-0000000000e1','00000000-0000-0000-0000-0000000000c1', 5000);

INSERT INTO room_rates (property_id, room_type_id, rate_plan_id, stay_date, rate)
SELECT '00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-0000000000c1',
       '00000000-0000-0000-0000-0000000000e1', d::date, 5000
  FROM generate_series(DATE '2026-09-01', DATE '2026-09-30', interval '1 day') d;

INSERT INTO guests (id, organization_id, first_name, last_name, email, phone)
VALUES ('00000000-0000-0000-0000-000000000091','00000000-0000-0000-0000-0000000000a1',
        'Asha','Nair','asha@example.com','+919999000011');

-- Front-desk operator, owner, and a rival-tenant user for the RBAC tests.
INSERT INTO users (id, organization_id, email, full_name) VALUES
  ('00000000-0000-0000-0000-000000000071','00000000-0000-0000-0000-0000000000a1','frontdesk@amoha.test','Front Desk User'),
  ('00000000-0000-0000-0000-000000000072','00000000-0000-0000-0000-0000000000a1','owner@amoha.test','Owner User'),
  ('00000000-0000-0000-0000-000000000073','00000000-0000-0000-0000-0000000000a2','rival@rival.test','Rival User');

INSERT INTO user_roles (user_id, role_id, property_id)
SELECT '00000000-0000-0000-0000-000000000071', id, '00000000-0000-0000-0000-0000000000b1'
  FROM roles WHERE code = 'FRONT_DESK' AND is_system;
INSERT INTO user_roles (user_id, role_id, property_id)
SELECT '00000000-0000-0000-0000-000000000072', id, NULL FROM roles WHERE code = 'OWNER' AND is_system;
INSERT INTO user_roles (user_id, role_id, property_id)
SELECT '00000000-0000-0000-0000-000000000073', id, '00000000-0000-0000-0000-0000000000b2'
  FROM roles WHERE code = 'OWNER' AND is_system;

-- A confirmed booking in room 101 for 10 -> 14 Sep: the collision target.
INSERT INTO reservations (id, property_id, reservation_number, guest_id, status,
                          arrival_date, departure_date, adults, total_amount)
VALUES ('00000000-0000-0000-0000-000000000081','00000000-0000-0000-0000-0000000000b1',
        'RES-TEST-0001','00000000-0000-0000-0000-000000000091','CONFIRMED',
        DATE '2026-09-10', DATE '2026-09-14', 2, 20000);

INSERT INTO reservation_rooms (id, reservation_id, property_id, room_type_id, rate_plan_id,
                               arrival_date, departure_date, adults, total_amount)
VALUES ('00000000-0000-0000-0000-000000000082','00000000-0000-0000-0000-000000000081',
        '00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-0000000000c1',
        '00000000-0000-0000-0000-0000000000e1', DATE '2026-09-10', DATE '2026-09-14', 2, 20000);

INSERT INTO room_allocations (id, property_id, room_id, allocation_type, reservation_room_id,
                              arrival_date, departure_date)
VALUES ('00000000-0000-0000-0000-000000000083','00000000-0000-0000-0000-0000000000b1',
        '00000000-0000-0000-0000-0000000000d1','RESERVATION','00000000-0000-0000-0000-000000000082',
        DATE '2026-09-10', DATE '2026-09-14');
