-- =====================================================================
-- 0004_billing_and_payments.sql
-- Configurable GST, charge codes, folios, folio items, invoices,
-- payments, refunds and payment-gateway transactions.
--
-- Tax rates are DATA, never constants in code. Indian room tariff uses
-- slabs (per-night value bands), so tax_rates carries min/max night
-- value and an effective-date window; historic invoices keep reprinting
-- with the rate that applied on their invoice date.
-- =====================================================================

CREATE TYPE tax_type AS ENUM ('CGST','SGST','IGST','UTGST','CESS','VAT','SERVICE_CHARGE');
CREATE TYPE folio_status AS ENUM ('OPEN','CLOSED','SETTLED','VOID');
CREATE TYPE folio_type   AS ENUM ('GUEST','MASTER','COMPANY','SPLIT','HOUSE');
CREATE TYPE invoice_type   AS ENUM ('TAX_INVOICE','PROFORMA','CREDIT_NOTE','DEBIT_NOTE');
CREATE TYPE invoice_status AS ENUM ('DRAFT','ISSUED','PARTIALLY_PAID','PAID','CANCELLED','CREDITED');
CREATE TYPE payment_txn_status AS ENUM (
  'INITIATED','PENDING','AUTHORIZED','CAPTURED','FAILED',
  'CANCELLED','REFUNDED','PARTIALLY_REFUNDED'
);
CREATE TYPE payment_direction AS ENUM ('RECEIPT','REFUND');

CREATE TABLE tax_groups (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id   uuid NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
  code          text NOT NULL,
  name          text NOT NULL,
  -- SAC 996311 = hotel accommodation, 996331 = restaurant service.
  hsn_sac_code  text,
  applies_to    text NOT NULL DEFAULT 'ROOM',
  -- Slab tax keyed off the per-night tariff rather than the line total.
  is_slab_based boolean NOT NULL DEFAULT false,
  is_active     boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT tax_groups_uq UNIQUE (property_id, code),
  CONSTRAINT tax_groups_applies_chk CHECK (applies_to IN
    ('ROOM','FOOD','BEVERAGE','SERVICE','GOODS','TRANSPORT','OTHER'))
);

CREATE TABLE tax_rates (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tax_group_id   uuid NOT NULL REFERENCES tax_groups(id) ON DELETE CASCADE,
  tax_type       tax_type NOT NULL,
  rate_percent   numeric(6,3) NOT NULL,
  -- Slab bounds on the per-night tariff. NULL = unbounded.
  min_amount     numeric(12,2),
  max_amount     numeric(12,2),
  effective_from date NOT NULL,
  effective_to   date,
  created_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT tax_rates_percent_chk CHECK (rate_percent >= 0 AND rate_percent <= 100),
  CONSTRAINT tax_rates_slab_chk CHECK (max_amount IS NULL OR min_amount IS NULL OR max_amount > min_amount),
  CONSTRAINT tax_rates_period_chk CHECK (effective_to IS NULL OR effective_to >= effective_from)
);
CREATE INDEX tax_rates_lookup_idx ON tax_rates(tax_group_id, effective_from DESC);

ALTER TABLE room_types
  ADD CONSTRAINT room_types_tax_group_fk
  FOREIGN KEY (tax_group_id) REFERENCES tax_groups(id) ON DELETE SET NULL;

-- revenue_account_id is wired to the chart of accounts in 0005, which is
-- what makes every folio posting produce a correct journal entry.
CREATE TABLE charge_codes (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id        uuid NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
  code               text NOT NULL,
  name               text NOT NULL,
  category           text NOT NULL,
  tax_group_id       uuid REFERENCES tax_groups(id) ON DELETE SET NULL,
  revenue_account_id uuid,
  default_price      numeric(12,2) NOT NULL DEFAULT 0,
  is_tax_inclusive   boolean NOT NULL DEFAULT false,
  is_negative        boolean NOT NULL DEFAULT false,
  is_system          boolean NOT NULL DEFAULT false,
  is_active          boolean NOT NULL DEFAULT true,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT charge_codes_uq UNIQUE (property_id, code),
  CONSTRAINT charge_codes_category_chk CHECK (category IN (
    'ROOM','FOOD','BEVERAGE','LAUNDRY','TRANSPORT','SPA','TELEPHONE',
    'MINIBAR','EXTRA_BED','EARLY_CHECKIN','LATE_CHECKOUT','DAMAGE',
    'MISC','DISCOUNT','ADJUSTMENT','CANCELLATION_FEE','NO_SHOW_FEE')),
  CONSTRAINT charge_codes_price_chk CHECK (default_price >= 0)
);

CREATE TABLE folios (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id          uuid NOT NULL REFERENCES properties(id) ON DELETE RESTRICT,
  folio_number         text NOT NULL,
  folio_type           folio_type NOT NULL DEFAULT 'GUEST',
  reservation_id       uuid REFERENCES reservations(id) ON DELETE RESTRICT,
  reservation_room_id  uuid REFERENCES reservation_rooms(id) ON DELETE RESTRICT,
  guest_id             uuid REFERENCES guests(id) ON DELETE RESTRICT,
  corporate_account_id uuid,
  status               folio_status NOT NULL DEFAULT 'OPEN',
  currency_code        char(3) NOT NULL DEFAULT 'INR',
  -- Maintained by trigger from folio_items and payments (0009).
  total_charges        numeric(14,2) NOT NULL DEFAULT 0,
  total_payments       numeric(14,2) NOT NULL DEFAULT 0,
  balance              numeric(14,2) GENERATED ALWAYS AS (total_charges - total_payments) STORED,
  opened_at            timestamptz NOT NULL DEFAULT now(),
  closed_at            timestamptz,
  closed_by            uuid REFERENCES users(id),
  notes                text,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT folios_number_uq UNIQUE (property_id, folio_number),
  CONSTRAINT folios_closed_chk CHECK (status = 'OPEN' OR closed_at IS NOT NULL)
);
CREATE INDEX folios_reservation_idx ON folios(reservation_id);
CREATE INDEX folios_guest_idx       ON folios(guest_id);
CREATE INDEX folios_open_idx        ON folios(property_id) WHERE status = 'OPEN';

ALTER TABLE reservation_rooms
  ADD CONSTRAINT reservation_rooms_folio_fk
  FOREIGN KEY (folio_id) REFERENCES folios(id) ON DELETE SET NULL;

-- Folio items :: charges. Never deleted -- voided.
CREATE TABLE folio_items (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  folio_id        uuid NOT NULL REFERENCES folios(id) ON DELETE RESTRICT,
  property_id     uuid NOT NULL REFERENCES properties(id) ON DELETE RESTRICT,
  item_date       date NOT NULL DEFAULT CURRENT_DATE,
  charge_code_id  uuid NOT NULL REFERENCES charge_codes(id) ON DELETE RESTRICT,
  description     text NOT NULL,
  quantity        numeric(10,3) NOT NULL DEFAULT 1,
  unit_price      numeric(12,2) NOT NULL DEFAULT 0,
  gross_amount    numeric(14,2) NOT NULL DEFAULT 0,
  discount_amount numeric(14,2) NOT NULL DEFAULT 0,
  taxable_amount  numeric(14,2) NOT NULL DEFAULT 0,
  tax_amount      numeric(14,2) NOT NULL DEFAULT 0,
  total_amount    numeric(14,2) NOT NULL DEFAULT 0,
  -- Provenance: which reservation night / POS ticket produced this line.
  reference_type  text,
  reference_id    uuid,
  transferred_from_folio_id uuid REFERENCES folios(id) ON DELETE SET NULL,
  transferred_to_folio_id   uuid REFERENCES folios(id) ON DELETE SET NULL,
  is_void          boolean NOT NULL DEFAULT false,
  voided_at        timestamptz,
  voided_by        uuid REFERENCES users(id),
  void_reason      text,
  journal_entry_id uuid,   -- FK added in 0005
  posted_by        uuid REFERENCES users(id),
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT folio_items_qty_chk CHECK (quantity <> 0),
  CONSTRAINT folio_items_void_chk CHECK (
    NOT is_void OR (voided_at IS NOT NULL AND void_reason IS NOT NULL)),
  CONSTRAINT folio_items_tax_chk CHECK (tax_amount >= 0),
  -- Line arithmetic must close, to the paisa.
  CONSTRAINT folio_items_math_chk CHECK (
    taxable_amount = gross_amount - discount_amount
    AND total_amount = taxable_amount + tax_amount)
);
CREATE INDEX folio_items_folio_idx ON folio_items(folio_id) WHERE NOT is_void;
CREATE INDEX folio_items_date_idx  ON folio_items(property_id, item_date);
CREATE INDEX folio_items_ref_idx   ON folio_items(reference_type, reference_id);

CREATE TABLE folio_item_taxes (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  folio_item_id  uuid NOT NULL REFERENCES folio_items(id) ON DELETE CASCADE,
  tax_type       tax_type NOT NULL,
  rate_percent   numeric(6,3) NOT NULL,
  taxable_amount numeric(14,2) NOT NULL,
  tax_amount     numeric(14,2) NOT NULL,
  CONSTRAINT folio_item_taxes_uq UNIQUE (folio_item_id, tax_type),
  CONSTRAINT folio_item_taxes_amount_chk CHECK (tax_amount >= 0 AND taxable_amount >= 0)
);

-- Invoices :: GST documents. Cancelled or credited, never deleted.
CREATE TABLE invoices (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id          uuid NOT NULL REFERENCES properties(id) ON DELETE RESTRICT,
  invoice_number       text NOT NULL,
  invoice_type         invoice_type NOT NULL DEFAULT 'TAX_INVOICE',
  invoice_date         date NOT NULL DEFAULT CURRENT_DATE,
  folio_id             uuid REFERENCES folios(id) ON DELETE RESTRICT,
  reservation_id       uuid REFERENCES reservations(id) ON DELETE RESTRICT,
  guest_id             uuid REFERENCES guests(id) ON DELETE RESTRICT,
  corporate_account_id uuid,
  travel_agent_id      uuid,
  -- Bill-to details are snapshotted: a later edit to the guest master
  -- must never alter an already-issued statutory document.
  bill_to_name         text NOT NULL,
  bill_to_address      text,
  bill_to_gstin        text,
  bill_to_state_code   char(2),
  place_of_supply      char(2),
  is_b2b               boolean NOT NULL DEFAULT false,
  is_interstate        boolean NOT NULL DEFAULT false,
  currency_code        char(3) NOT NULL DEFAULT 'INR',
  subtotal             numeric(14,2) NOT NULL DEFAULT 0,
  discount_total       numeric(14,2) NOT NULL DEFAULT 0,
  taxable_value        numeric(14,2) NOT NULL DEFAULT 0,
  cgst_amount          numeric(14,2) NOT NULL DEFAULT 0,
  sgst_amount          numeric(14,2) NOT NULL DEFAULT 0,
  igst_amount          numeric(14,2) NOT NULL DEFAULT 0,
  cess_amount          numeric(14,2) NOT NULL DEFAULT 0,
  round_off            numeric(6,2) NOT NULL DEFAULT 0,
  total_amount         numeric(14,2) NOT NULL DEFAULT 0,
  amount_paid          numeric(14,2) NOT NULL DEFAULT 0,
  balance_due          numeric(14,2) GENERATED ALWAYS AS (total_amount - amount_paid) STORED,
  status               invoice_status NOT NULL DEFAULT 'DRAFT',
  original_invoice_id  uuid REFERENCES invoices(id) ON DELETE RESTRICT,
  notes                text,
  terms                text,
  pdf_url              text,
  irn                  text,   -- e-invoice reference, when applicable
  journal_entry_id     uuid,
  issued_by            uuid REFERENCES users(id),
  issued_at            timestamptz,
  cancelled_at         timestamptz,
  cancelled_by         uuid REFERENCES users(id),
  cancellation_reason  text,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT invoices_number_uq UNIQUE (property_id, invoice_number),
  CONSTRAINT invoices_amounts_chk CHECK (
    subtotal >= 0 AND discount_total >= 0 AND taxable_value >= 0
    AND cgst_amount >= 0 AND sgst_amount >= 0 AND igst_amount >= 0 AND cess_amount >= 0),
  -- GST is either intra-state (CGST+SGST) or inter-state (IGST), never both.
  CONSTRAINT invoices_gst_mode_chk CHECK (
    (is_interstate AND cgst_amount = 0 AND sgst_amount = 0)
    OR (NOT is_interstate AND igst_amount = 0)),
  -- Equal split between centre and state is a legal requirement.
  CONSTRAINT invoices_cgst_sgst_chk CHECK (is_interstate OR cgst_amount = sgst_amount),
  CONSTRAINT invoices_b2b_gstin_chk CHECK (NOT is_b2b OR bill_to_gstin IS NOT NULL),
  CONSTRAINT invoices_credit_note_chk CHECK (
    invoice_type NOT IN ('CREDIT_NOTE','DEBIT_NOTE') OR original_invoice_id IS NOT NULL),
  CONSTRAINT invoices_issued_chk CHECK (status = 'DRAFT' OR issued_at IS NOT NULL),
  CONSTRAINT invoices_cancel_chk CHECK (
    status <> 'CANCELLED' OR (cancelled_at IS NOT NULL AND cancellation_reason IS NOT NULL)),
  CONSTRAINT invoices_total_chk CHECK (
    total_amount = taxable_value + cgst_amount + sgst_amount + igst_amount + cess_amount + round_off)
);
CREATE INDEX invoices_property_date_idx ON invoices(property_id, invoice_date DESC);
CREATE INDEX invoices_guest_idx         ON invoices(guest_id);
CREATE INDEX invoices_status_idx        ON invoices(property_id, status);
CREATE INDEX invoices_folio_idx         ON invoices(folio_id);

CREATE TABLE invoice_items (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id      uuid NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
  folio_item_id   uuid REFERENCES folio_items(id) ON DELETE SET NULL,
  line_number     smallint NOT NULL,
  description     text NOT NULL,
  hsn_sac_code    text,
  quantity        numeric(10,3) NOT NULL DEFAULT 1,
  unit_price      numeric(12,2) NOT NULL DEFAULT 0,
  gross_amount    numeric(14,2) NOT NULL DEFAULT 0,
  discount_amount numeric(14,2) NOT NULL DEFAULT 0,
  taxable_value   numeric(14,2) NOT NULL DEFAULT 0,
  cgst_rate       numeric(6,3) NOT NULL DEFAULT 0,
  cgst_amount     numeric(14,2) NOT NULL DEFAULT 0,
  sgst_rate       numeric(6,3) NOT NULL DEFAULT 0,
  sgst_amount     numeric(14,2) NOT NULL DEFAULT 0,
  igst_rate       numeric(6,3) NOT NULL DEFAULT 0,
  igst_amount     numeric(14,2) NOT NULL DEFAULT 0,
  cess_amount     numeric(14,2) NOT NULL DEFAULT 0,
  total_amount    numeric(14,2) NOT NULL DEFAULT 0,
  CONSTRAINT invoice_items_line_uq UNIQUE (invoice_id, line_number),
  CONSTRAINT invoice_items_math_chk CHECK (
    taxable_value = gross_amount - discount_amount
    AND total_amount = taxable_value + cgst_amount + sgst_amount + igst_amount + cess_amount)
);

CREATE TABLE payment_methods (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id        uuid NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
  code               text NOT NULL,
  name               text NOT NULL,
  method_type        text NOT NULL,
  account_id         uuid,   -- FK added in 0005
  requires_reference boolean NOT NULL DEFAULT false,
  is_active          boolean NOT NULL DEFAULT true,
  sort_order         smallint NOT NULL DEFAULT 0,
  created_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT payment_methods_uq UNIQUE (property_id, code),
  CONSTRAINT payment_methods_type_chk CHECK (method_type IN (
    'CASH','CARD','UPI','BANK_TRANSFER','GATEWAY','CHEQUE','WALLET',
    'CITY_LEDGER','OTA_COLLECT','COMPLIMENTARY','VOUCHER'))
);

CREATE TABLE payments (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id          uuid NOT NULL REFERENCES properties(id) ON DELETE RESTRICT,
  payment_number       text NOT NULL,
  payment_direction    payment_direction NOT NULL DEFAULT 'RECEIPT',
  payment_date         date NOT NULL DEFAULT CURRENT_DATE,
  folio_id             uuid REFERENCES folios(id) ON DELETE RESTRICT,
  reservation_id       uuid REFERENCES reservations(id) ON DELETE RESTRICT,
  invoice_id           uuid REFERENCES invoices(id) ON DELETE RESTRICT,
  guest_id             uuid REFERENCES guests(id) ON DELETE RESTRICT,
  corporate_account_id uuid,
  travel_agent_id      uuid,
  payment_method_id    uuid NOT NULL REFERENCES payment_methods(id) ON DELETE RESTRICT,
  amount               numeric(14,2) NOT NULL,
  currency_code        char(3) NOT NULL DEFAULT 'INR',
  status               payment_txn_status NOT NULL DEFAULT 'CAPTURED',
  reference_number     text,
  gateway_txn_id       uuid,
  notes                text,
  received_by          uuid REFERENCES users(id),
  journal_entry_id     uuid,
  is_void              boolean NOT NULL DEFAULT false,
  voided_at            timestamptz,
  voided_by            uuid REFERENCES users(id),
  void_reason          text,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT payments_number_uq UNIQUE (property_id, payment_number),
  CONSTRAINT payments_amount_chk CHECK (amount > 0),
  CONSTRAINT payments_void_chk CHECK (
    NOT is_void OR (voided_at IS NOT NULL AND void_reason IS NOT NULL))
);
CREATE INDEX payments_property_date_idx ON payments(property_id, payment_date DESC);
CREATE INDEX payments_folio_idx         ON payments(folio_id) WHERE NOT is_void;
CREATE INDEX payments_reservation_idx   ON payments(reservation_id);
CREATE INDEX payments_invoice_idx       ON payments(invoice_id);

CREATE TABLE refunds (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id       uuid NOT NULL REFERENCES properties(id) ON DELETE RESTRICT,
  payment_id        uuid NOT NULL REFERENCES payments(id) ON DELETE RESTRICT,
  refund_payment_id uuid REFERENCES payments(id) ON DELETE RESTRICT,
  amount            numeric(14,2) NOT NULL,
  reason            text NOT NULL,
  status            payment_txn_status NOT NULL DEFAULT 'INITIATED',
  gateway_refund_id text,
  requested_by      uuid REFERENCES users(id),
  approved_by       uuid REFERENCES users(id),
  processed_at      timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT refunds_amount_chk CHECK (amount > 0)
);
CREATE INDEX refunds_payment_idx ON refunds(payment_id);

-- The browser's "payment succeeded" callback is never trusted. A row
-- reaches CAPTURED only after server-side signature verification or a
-- verified webhook.
CREATE TABLE payment_gateway_transactions (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id           uuid NOT NULL REFERENCES properties(id) ON DELETE RESTRICT,
  gateway               text NOT NULL,
  gateway_mode          text NOT NULL DEFAULT 'SANDBOX',
  gateway_order_id      text,
  gateway_payment_id    text,
  gateway_signature     text,
  amount                numeric(14,2) NOT NULL,
  currency_code         char(3) NOT NULL DEFAULT 'INR',
  status                payment_txn_status NOT NULL DEFAULT 'INITIATED',
  reservation_id        uuid REFERENCES reservations(id) ON DELETE SET NULL,
  payment_id            uuid REFERENCES payments(id) ON DELETE SET NULL,
  guest_id              uuid REFERENCES guests(id) ON DELETE SET NULL,
  idempotency_key       text,
  request_payload       jsonb,
  response_payload      jsonb,
  signature_verified_at timestamptz,
  webhook_received_at   timestamptz,
  error_code            text,
  error_message         text,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pg_txn_amount_chk CHECK (amount > 0),
  CONSTRAINT pg_txn_mode_chk CHECK (gateway_mode IN ('SANDBOX','PRODUCTION','MOCK')),
  -- A gateway payment id can be recorded exactly once: replayed webhooks
  -- and double-clicked checkouts cannot create a second payment.
  CONSTRAINT pg_txn_payment_uq UNIQUE NULLS NOT DISTINCT (gateway, gateway_payment_id),
  CONSTRAINT pg_txn_captured_chk CHECK (
    status <> 'CAPTURED' OR signature_verified_at IS NOT NULL OR webhook_received_at IS NOT NULL)
);
CREATE INDEX pg_txn_order_idx       ON payment_gateway_transactions(gateway, gateway_order_id);
CREATE INDEX pg_txn_reservation_idx ON payment_gateway_transactions(reservation_id);
CREATE INDEX pg_txn_idem_idx        ON payment_gateway_transactions(idempotency_key);

ALTER TABLE payments
  ADD CONSTRAINT payments_gateway_txn_fk
  FOREIGN KEY (gateway_txn_id) REFERENCES payment_gateway_transactions(id) ON DELETE SET NULL;

CREATE TRIGGER tax_groups_updated_at   BEFORE UPDATE ON tax_groups   FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();
CREATE TRIGGER charge_codes_updated_at BEFORE UPDATE ON charge_codes FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();
CREATE TRIGGER folios_updated_at       BEFORE UPDATE ON folios       FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();
CREATE TRIGGER invoices_updated_at     BEFORE UPDATE ON invoices     FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();
CREATE TRIGGER payments_updated_at     BEFORE UPDATE ON payments     FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();
CREATE TRIGGER refunds_updated_at      BEFORE UPDATE ON refunds      FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();
CREATE TRIGGER pg_txn_updated_at       BEFORE UPDATE ON payment_gateway_transactions FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();
