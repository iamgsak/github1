-- =====================================================================
-- DEMO TRANSACTIONS -- folio payments and journal entries.
--
-- ***  NOT FOR PRODUCTION.  ***
-- Run after demo_hotel_amoha.sql. This exists so the dashboard's
-- financial figures come from real double-entry postings rather than
-- appearing as zeroes: collections, cash and bank are read from the
-- ledger, so without journals they would legitimately show nothing.
-- =====================================================================

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM journal_entries LIMIT 1) THEN
    RAISE EXCEPTION 'Refusing to seed: journal entries already exist.'
      USING ERRCODE = 'restrict_violation';
  END IF;
END;
$$;

BEGIN;

-- Opening balances. Without these the cash account goes negative the
-- moment an expense is paid, which is not a realistic starting position.
DO $$
DECLARE v_prop uuid; v_org uuid; v_entry uuid := gen_random_uuid(); v_num text;
BEGIN
  SELECT id, organization_id INTO v_prop, v_org FROM properties WHERE code = 'AMOHA';
  v_num := app.next_document_number(v_prop, 'JOURNAL',
             (SELECT fiscal_year FROM document_series WHERE property_id=v_prop AND doc_type='JOURNAL'));
  INSERT INTO journal_entries (id, organization_id, property_id, entry_number, entry_date,
                               journal_type, narration, is_posted, posted_at)
  VALUES (v_entry, v_org, v_prop, v_num, DATE '2026-04-01','OPENING',
          'Opening balances for FY2026-27', true, now());
  INSERT INTO journal_lines (journal_entry_id, property_id, line_number, account_id, debit, credit, description)
  SELECT v_entry, v_prop, v.ln,
         (SELECT id FROM accounts WHERE organization_id=v_org AND code=v.code), v.dr, v.cr, v.descr
    FROM (VALUES (1,'1110',300000::numeric,0::numeric,'Opening cash in hand'),
                 (2,'1120',700000::numeric,0::numeric,'Opening bank balance'),
                 (3,'3100',0::numeric,1000000::numeric,'Owner capital introduced')
         ) AS v(ln, code, dr, cr, descr);
END;
$$;

/*
 * Posts one guest payment and its balanced journal entry.
 *
 *   Debit  Cash / Bank    gross
 *   Credit Room Revenue   net
 *   Credit Output CGST    half the tax
 *   Credit Output SGST    half the tax
 *
 * Accommodation is always intra-state for GST (place of supply is the
 * hotel), hence CGST + SGST and never IGST.
 */
CREATE OR REPLACE FUNCTION pg_temp.demo_settle(
  p_reservation_number text, p_method_code text, p_pay_date date
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_prop uuid; v_org uuid; v_res reservations%ROWTYPE; v_folio uuid;
  v_method uuid; v_acct uuid; v_entry uuid := gen_random_uuid(); v_num text;
  v_net numeric(14,2); v_tax numeric(14,2); v_gross numeric(14,2);
BEGIN
  SELECT * INTO v_res FROM reservations WHERE reservation_number = p_reservation_number;
  IF NOT FOUND THEN RETURN; END IF;

  v_prop := v_res.property_id;
  SELECT organization_id INTO v_org FROM properties WHERE id = v_prop;
  SELECT id INTO v_folio FROM folios WHERE reservation_id = v_res.id LIMIT 1;
  SELECT pm.id, pm.account_id INTO v_method, v_acct FROM payment_methods pm
   WHERE pm.property_id = v_prop AND pm.code = p_method_code;

  v_net := v_res.room_charges; v_tax := v_res.tax_amount; v_gross := v_net + v_tax;

  v_num := app.next_document_number(v_prop, 'JOURNAL',
             (SELECT fiscal_year FROM document_series WHERE property_id = v_prop AND doc_type = 'JOURNAL'));

  INSERT INTO journal_entries (id, organization_id, property_id, entry_number, entry_date,
                               journal_type, narration, source_type, source_id, is_posted, posted_at)
  VALUES (v_entry, v_org, v_prop, v_num, p_pay_date, 'RECEIPT',
          'Room revenue and GST for ' || p_reservation_number,
          'RESERVATION', v_res.id, true, now());

  INSERT INTO journal_lines (journal_entry_id, property_id, line_number, account_id,
                             debit, credit, description, party_type, party_id, tax_type)
  SELECT v_entry, v_prop, v.ln,
         (SELECT id FROM accounts WHERE organization_id = v_org AND code = v.code),
         v.dr, v.cr, v.descr, v.party,
         CASE WHEN v.party IS NULL THEN NULL ELSE v_res.guest_id END, v.tax
    FROM (VALUES
      (1, (SELECT code FROM accounts WHERE id = v_acct), v_gross, 0::numeric,
          'Payment received', 'GUEST', NULL::tax_type),
      (2, '4100', 0::numeric, v_net, 'Room revenue', NULL, NULL::tax_type),
      (3, '2120', 0::numeric, round(v_tax / 2, 2), 'Output CGST', NULL, 'CGST'::tax_type),
      (4, '2121', 0::numeric, v_tax - round(v_tax / 2, 2), 'Output SGST', NULL, 'SGST'::tax_type)
    ) AS v(ln, code, dr, cr, descr, party, tax);

  INSERT INTO payments (property_id, payment_number, payment_direction, payment_date,
                        folio_id, reservation_id, guest_id, payment_method_id,
                        amount, status, journal_entry_id, reference_number)
  VALUES (v_prop,
          app.next_document_number(v_prop, 'RECEIPT',
            (SELECT fiscal_year FROM document_series WHERE property_id = v_prop AND doc_type = 'RECEIPT')),
          'RECEIPT', p_pay_date, v_folio, v_res.id, v_res.guest_id, v_method,
          v_gross, 'CAPTURED', v_entry, 'DEMO-' || p_reservation_number);
END;
$$;

SELECT pg_temp.demo_settle('RES-2026-27/00001', 'CARD',   DATE '2026-09-14');
SELECT pg_temp.demo_settle('RES-2026-27/00002', 'OTACOL', DATE '2026-09-15');
SELECT pg_temp.demo_settle('RES-2026-27/00003', 'UPI',    DATE '2026-09-18');
SELECT pg_temp.demo_settle('RES-2026-27/00005', 'CASH',   DATE '2026-09-19');

/* A few operating expenses so the P&L is not revenue-only. */
CREATE OR REPLACE FUNCTION pg_temp.demo_expense(
  p_date date, p_account text, p_amount numeric, p_narration text
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_prop uuid; v_org uuid; v_entry uuid := gen_random_uuid(); v_num text;
BEGIN
  SELECT id, organization_id INTO v_prop, v_org FROM properties WHERE code = 'AMOHA';
  v_num := app.next_document_number(v_prop, 'JOURNAL',
             (SELECT fiscal_year FROM document_series WHERE property_id = v_prop AND doc_type = 'JOURNAL'));
  INSERT INTO journal_entries (id, organization_id, property_id, entry_number, entry_date,
                               journal_type, narration, is_posted, posted_at)
  VALUES (v_entry, v_org, v_prop, v_num, p_date, 'PAYMENT', p_narration, true, now());
  INSERT INTO journal_lines (journal_entry_id, property_id, line_number, account_id, debit, credit, description)
  VALUES (v_entry, v_prop, 1,
          (SELECT id FROM accounts WHERE organization_id = v_org AND code = p_account),
          p_amount, 0, p_narration),
         (v_entry, v_prop, 2,
          (SELECT id FROM accounts WHERE organization_id = v_org AND code = '1110'),
          0, p_amount, 'Paid in cash');
END;
$$;

SELECT pg_temp.demo_expense(DATE '2026-09-05', '5400', 18500,  'Electricity bill');
SELECT pg_temp.demo_expense(DATE '2026-09-08', '5200', 145000, 'Staff salaries');
SELECT pg_temp.demo_expense(DATE '2026-09-12', '5430', 9200,   'Housekeeping supplies');
SELECT pg_temp.demo_expense(DATE '2026-09-18', '5420', 6400,   'Plumbing repair');

COMMIT;

-- The books must balance. A hard check, not a comment.
DO $$
DECLARE v_net numeric;
BEGIN
  SELECT COALESCE(sum(net_balance), 0) INTO v_net FROM v_trial_balance;
  IF v_net <> 0 THEN
    RAISE EXCEPTION 'Demo transactions left the ledger unbalanced by %', v_net;
  END IF;
  RAISE NOTICE 'Trial balance nets to zero. Demo transactions posted.';
END;
$$;
