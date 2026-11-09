-- =====================================================================
-- 0006_inventory_and_purchasing.sql
-- Item master, stores, stock balances, the stock movement ledger, and
-- the purchase workflow:
--   Purchase Request -> Approval -> Purchase Order -> Goods Receipt
--   -> Supplier Invoice -> Payment
--
-- stock_movements is append-only, mirroring the accounting design:
-- stock_balances is a cached aggregate, the ledger is truth.
-- =====================================================================

CREATE TYPE stock_movement_type AS ENUM (
  'OPENING','PURCHASE','PURCHASE_RETURN','CONSUMPTION','SALE',
  'TRANSFER_IN','TRANSFER_OUT','ADJUSTMENT','WASTAGE','PRODUCTION'
);
CREATE TYPE purchase_status AS ENUM (
  'DRAFT','PENDING_APPROVAL','APPROVED','REJECTED','PARTIALLY_RECEIVED',
  'RECEIVED','INVOICED','CANCELLED','CLOSED'
);

CREATE TABLE uoms (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  code              text NOT NULL,
  name              text NOT NULL,
  base_uom_id       uuid REFERENCES uoms(id) ON DELETE RESTRICT,
  conversion_factor numeric(14,6) NOT NULL DEFAULT 1,
  is_active         boolean NOT NULL DEFAULT true,
  CONSTRAINT uoms_uq UNIQUE (organization_id, code),
  CONSTRAINT uoms_factor_chk CHECK (conversion_factor > 0),
  CONSTRAINT uoms_no_self_base_chk CHECK (base_uom_id IS DISTINCT FROM id)
);

CREATE TABLE item_categories (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id      uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  code                 text NOT NULL,
  name                 text NOT NULL,
  parent_category_id   uuid REFERENCES item_categories(id) ON DELETE RESTRICT,
  -- Where consumption hits the P&L / where stock value sits.
  expense_account_id   uuid REFERENCES accounts(id) ON DELETE RESTRICT,
  inventory_account_id uuid REFERENCES accounts(id) ON DELETE RESTRICT,
  is_active            boolean NOT NULL DEFAULT true,
  CONSTRAINT item_categories_uq UNIQUE (organization_id, code),
  CONSTRAINT item_categories_no_self_parent_chk CHECK (parent_category_id IS DISTINCT FROM id)
);

CREATE TABLE inventory_items (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id    uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  code               text NOT NULL,
  name               text NOT NULL,
  description        text,
  category_id        uuid REFERENCES item_categories(id) ON DELETE RESTRICT,
  uom_id             uuid NOT NULL REFERENCES uoms(id) ON DELETE RESTRICT,
  item_type          text NOT NULL DEFAULT 'STOCK',
  hsn_code           text,
  tax_group_id       uuid REFERENCES tax_groups(id) ON DELETE SET NULL,
  valuation_method   text NOT NULL DEFAULT 'WEIGHTED_AVG',
  reorder_level      numeric(14,3) NOT NULL DEFAULT 0,
  min_stock          numeric(14,3) NOT NULL DEFAULT 0,
  max_stock          numeric(14,3),
  average_cost       numeric(14,4) NOT NULL DEFAULT 0,
  last_purchase_cost numeric(14,4),
  is_perishable      boolean NOT NULL DEFAULT false,
  shelf_life_days    integer,
  is_active          boolean NOT NULL DEFAULT true,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT inventory_items_uq UNIQUE (organization_id, code),
  CONSTRAINT inventory_items_type_chk CHECK (item_type IN ('STOCK','SERVICE','ASSET','CONSUMABLE')),
  CONSTRAINT inventory_items_valuation_chk CHECK (valuation_method IN ('WEIGHTED_AVG','FIFO','STANDARD')),
  CONSTRAINT inventory_items_levels_chk CHECK (
    reorder_level >= 0 AND min_stock >= 0 AND (max_stock IS NULL OR max_stock >= min_stock)),
  CONSTRAINT inventory_items_cost_chk CHECK (average_cost >= 0)
);
CREATE INDEX inventory_items_category_idx ON inventory_items(category_id) WHERE is_active;
CREATE INDEX inventory_items_search_idx ON inventory_items
  USING gin (to_tsvector('simple', code || ' ' || name));

CREATE TABLE stores (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id uuid NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
  code        text NOT NULL,
  name        text NOT NULL,
  store_type  text NOT NULL DEFAULT 'MAIN',
  location    text,
  manager_id  uuid REFERENCES users(id) ON DELETE SET NULL,
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT stores_uq UNIQUE (property_id, code),
  CONSTRAINT stores_type_chk CHECK (store_type IN
    ('MAIN','KITCHEN','BAR','HOUSEKEEPING','MAINTENANCE','MINIBAR','LAUNDRY'))
);

-- Cached balance per (store, item). Rebuildable from stock_movements.
CREATE TABLE stock_balances (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id  uuid NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
  store_id     uuid NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
  item_id      uuid NOT NULL REFERENCES inventory_items(id) ON DELETE RESTRICT,
  quantity     numeric(14,3) NOT NULL DEFAULT 0,
  average_cost numeric(14,4) NOT NULL DEFAULT 0,
  stock_value  numeric(16,2) GENERATED ALWAYS AS (round(quantity * average_cost, 2)) STORED,
  updated_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT stock_balances_uq UNIQUE (store_id, item_id),
  CONSTRAINT stock_balances_cost_chk CHECK (average_cost >= 0)
);
CREATE INDEX stock_balances_item_idx ON stock_balances(item_id);

-- Append-only stock ledger. quantity is signed: + in, - out.
CREATE TABLE stock_movements (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id             uuid NOT NULL REFERENCES properties(id) ON DELETE RESTRICT,
  store_id                uuid NOT NULL REFERENCES stores(id) ON DELETE RESTRICT,
  item_id                 uuid NOT NULL REFERENCES inventory_items(id) ON DELETE RESTRICT,
  movement_type           stock_movement_type NOT NULL,
  movement_date           date NOT NULL DEFAULT CURRENT_DATE,
  quantity                numeric(14,3) NOT NULL,
  unit_cost               numeric(14,4) NOT NULL DEFAULT 0,
  total_cost              numeric(16,2) NOT NULL DEFAULT 0,
  balance_after           numeric(14,3),
  reference_type          text,
  reference_id            uuid,
  -- Transfers create a paired OUT/IN so both legs reconcile.
  counterpart_movement_id uuid REFERENCES stock_movements(id) ON DELETE SET NULL,
  journal_entry_id        uuid REFERENCES journal_entries(id) ON DELETE SET NULL,
  notes                   text,
  created_by              uuid REFERENCES users(id),
  created_at              timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT stock_movements_qty_chk CHECK (quantity <> 0),
  CONSTRAINT stock_movements_cost_chk CHECK (unit_cost >= 0),
  CONSTRAINT stock_movements_direction_chk CHECK (
    (movement_type IN ('OPENING','PURCHASE','TRANSFER_IN','PRODUCTION') AND quantity > 0)
    OR (movement_type IN ('CONSUMPTION','SALE','TRANSFER_OUT','WASTAGE','PURCHASE_RETURN') AND quantity < 0)
    OR movement_type = 'ADJUSTMENT')
);
CREATE INDEX stock_movements_item_date_idx ON stock_movements(item_id, movement_date DESC);
CREATE INDEX stock_movements_store_idx     ON stock_movements(store_id, movement_date DESC);
CREATE INDEX stock_movements_ref_idx       ON stock_movements(reference_type, reference_id);

CREATE TABLE suppliers (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id    uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  code               text NOT NULL,
  name               text NOT NULL,
  contact_person     text,
  phone              text,
  email              citext,
  address_line1      text,
  city               text,
  state              text,
  state_code         char(2),
  postal_code        text,
  country_code       char(2) NOT NULL DEFAULT 'IN',
  gstin              text,
  pan                text,
  payment_terms_days smallint NOT NULL DEFAULT 30,
  credit_limit       numeric(14,2) NOT NULL DEFAULT 0,
  opening_balance    numeric(14,2) NOT NULL DEFAULT 0,
  payable_account_id uuid REFERENCES accounts(id) ON DELETE RESTRICT,
  bank_details       jsonb,
  is_active          boolean NOT NULL DEFAULT true,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT suppliers_uq UNIQUE (organization_id, code),
  CONSTRAINT suppliers_terms_chk CHECK (payment_terms_days >= 0),
  CONSTRAINT suppliers_gstin_chk CHECK (
    gstin IS NULL OR gstin ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z]{1}[1-9A-Z]{1}Z[0-9A-Z]{1}$')
);

CREATE TABLE purchase_requests (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id      uuid NOT NULL REFERENCES properties(id) ON DELETE RESTRICT,
  request_number   text NOT NULL,
  request_date     date NOT NULL DEFAULT CURRENT_DATE,
  store_id         uuid REFERENCES stores(id) ON DELETE RESTRICT,
  department       text,
  required_by      date,
  status           purchase_status NOT NULL DEFAULT 'DRAFT',
  notes            text,
  requested_by     uuid REFERENCES users(id),
  approved_by      uuid REFERENCES users(id),
  approved_at      timestamptz,
  rejection_reason text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT purchase_requests_uq UNIQUE (property_id, request_number),
  CONSTRAINT purchase_requests_approved_chk CHECK (status <> 'APPROVED' OR approved_by IS NOT NULL),
  CONSTRAINT purchase_requests_rejected_chk CHECK (status <> 'REJECTED' OR rejection_reason IS NOT NULL)
);

CREATE TABLE purchase_request_items (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  purchase_request_id uuid NOT NULL REFERENCES purchase_requests(id) ON DELETE CASCADE,
  item_id             uuid NOT NULL REFERENCES inventory_items(id) ON DELETE RESTRICT,
  quantity            numeric(14,3) NOT NULL,
  uom_id              uuid NOT NULL REFERENCES uoms(id) ON DELETE RESTRICT,
  estimated_cost      numeric(14,2) NOT NULL DEFAULT 0,
  notes               text,
  CONSTRAINT purchase_request_items_qty_chk CHECK (quantity > 0)
);

CREATE TABLE purchase_orders (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id         uuid NOT NULL REFERENCES properties(id) ON DELETE RESTRICT,
  po_number           text NOT NULL,
  po_date             date NOT NULL DEFAULT CURRENT_DATE,
  supplier_id         uuid NOT NULL REFERENCES suppliers(id) ON DELETE RESTRICT,
  purchase_request_id uuid REFERENCES purchase_requests(id) ON DELETE SET NULL,
  store_id            uuid REFERENCES stores(id) ON DELETE RESTRICT,
  expected_date       date,
  status              purchase_status NOT NULL DEFAULT 'DRAFT',
  subtotal            numeric(14,2) NOT NULL DEFAULT 0,
  discount_amount     numeric(14,2) NOT NULL DEFAULT 0,
  tax_amount          numeric(14,2) NOT NULL DEFAULT 0,
  total_amount        numeric(14,2) NOT NULL DEFAULT 0,
  terms               text,
  notes               text,
  created_by          uuid REFERENCES users(id),
  approved_by         uuid REFERENCES users(id),
  approved_at         timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT purchase_orders_uq UNIQUE (property_id, po_number),
  CONSTRAINT purchase_orders_amounts_chk CHECK (
    subtotal >= 0 AND discount_amount >= 0 AND tax_amount >= 0 AND total_amount >= 0)
);
CREATE INDEX purchase_orders_supplier_idx ON purchase_orders(supplier_id, po_date DESC);
CREATE INDEX purchase_orders_status_idx   ON purchase_orders(property_id, status);

CREATE TABLE purchase_order_items (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  purchase_order_id uuid NOT NULL REFERENCES purchase_orders(id) ON DELETE CASCADE,
  item_id           uuid NOT NULL REFERENCES inventory_items(id) ON DELETE RESTRICT,
  line_number       smallint NOT NULL,
  quantity          numeric(14,3) NOT NULL,
  uom_id            uuid NOT NULL REFERENCES uoms(id) ON DELETE RESTRICT,
  unit_price        numeric(14,4) NOT NULL DEFAULT 0,
  discount_amount   numeric(14,2) NOT NULL DEFAULT 0,
  tax_amount        numeric(14,2) NOT NULL DEFAULT 0,
  total_amount      numeric(14,2) NOT NULL DEFAULT 0,
  received_quantity numeric(14,3) NOT NULL DEFAULT 0,
  CONSTRAINT purchase_order_items_line_uq UNIQUE (purchase_order_id, line_number),
  CONSTRAINT purchase_order_items_qty_chk CHECK (quantity > 0),
  -- Never receive more than ordered.
  CONSTRAINT purchase_order_items_received_chk CHECK (
    received_quantity >= 0 AND received_quantity <= quantity)
);

CREATE TABLE goods_receipts (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id        uuid NOT NULL REFERENCES properties(id) ON DELETE RESTRICT,
  grn_number         text NOT NULL,
  receipt_date       date NOT NULL DEFAULT CURRENT_DATE,
  supplier_id        uuid NOT NULL REFERENCES suppliers(id) ON DELETE RESTRICT,
  purchase_order_id  uuid REFERENCES purchase_orders(id) ON DELETE RESTRICT,
  store_id           uuid NOT NULL REFERENCES stores(id) ON DELETE RESTRICT,
  supplier_dc_number text,
  status             purchase_status NOT NULL DEFAULT 'DRAFT',
  total_amount       numeric(14,2) NOT NULL DEFAULT 0,
  notes              text,
  received_by        uuid REFERENCES users(id),
  journal_entry_id   uuid REFERENCES journal_entries(id) ON DELETE SET NULL,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT goods_receipts_uq UNIQUE (property_id, grn_number)
);

CREATE TABLE goods_receipt_items (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  goods_receipt_id       uuid NOT NULL REFERENCES goods_receipts(id) ON DELETE CASCADE,
  purchase_order_item_id uuid REFERENCES purchase_order_items(id) ON DELETE SET NULL,
  item_id                uuid NOT NULL REFERENCES inventory_items(id) ON DELETE RESTRICT,
  line_number            smallint NOT NULL,
  ordered_quantity       numeric(14,3),
  received_quantity      numeric(14,3) NOT NULL,
  rejected_quantity      numeric(14,3) NOT NULL DEFAULT 0,
  unit_cost              numeric(14,4) NOT NULL DEFAULT 0,
  total_cost             numeric(16,2) NOT NULL DEFAULT 0,
  batch_number           text,
  expiry_date            date,
  stock_movement_id      uuid REFERENCES stock_movements(id) ON DELETE SET NULL,
  CONSTRAINT goods_receipt_items_line_uq UNIQUE (goods_receipt_id, line_number),
  CONSTRAINT goods_receipt_items_qty_chk CHECK (received_quantity > 0 AND rejected_quantity >= 0)
);

CREATE TABLE purchase_invoices (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id             uuid NOT NULL REFERENCES properties(id) ON DELETE RESTRICT,
  invoice_number          text NOT NULL,
  supplier_invoice_number text NOT NULL,
  invoice_date            date NOT NULL,
  due_date                date,
  supplier_id             uuid NOT NULL REFERENCES suppliers(id) ON DELETE RESTRICT,
  goods_receipt_id        uuid REFERENCES goods_receipts(id) ON DELETE RESTRICT,
  purchase_order_id       uuid REFERENCES purchase_orders(id) ON DELETE RESTRICT,
  subtotal                numeric(14,2) NOT NULL DEFAULT 0,
  discount_amount         numeric(14,2) NOT NULL DEFAULT 0,
  taxable_value           numeric(14,2) NOT NULL DEFAULT 0,
  cgst_amount             numeric(14,2) NOT NULL DEFAULT 0,
  sgst_amount             numeric(14,2) NOT NULL DEFAULT 0,
  igst_amount             numeric(14,2) NOT NULL DEFAULT 0,
  total_amount            numeric(14,2) NOT NULL DEFAULT 0,
  paid_amount             numeric(14,2) NOT NULL DEFAULT 0,
  balance_amount          numeric(14,2) GENERATED ALWAYS AS (total_amount - paid_amount) STORED,
  status                  purchase_status NOT NULL DEFAULT 'DRAFT',
  -- Input tax credit is only claimable on a valid supplier GSTIN.
  itc_eligible            boolean NOT NULL DEFAULT true,
  journal_entry_id        uuid REFERENCES journal_entries(id) ON DELETE SET NULL,
  notes                   text,
  created_by              uuid REFERENCES users(id),
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT purchase_invoices_uq UNIQUE (property_id, invoice_number),
  -- The same supplier bill cannot be entered twice.
  CONSTRAINT purchase_invoices_supplier_uq UNIQUE (supplier_id, supplier_invoice_number),
  CONSTRAINT purchase_invoices_due_chk CHECK (due_date IS NULL OR due_date >= invoice_date),
  CONSTRAINT purchase_invoices_amounts_chk CHECK (subtotal >= 0 AND total_amount >= 0 AND paid_amount >= 0)
);
CREATE INDEX purchase_invoices_supplier_idx ON purchase_invoices(supplier_id, invoice_date DESC);

CREATE TABLE purchase_invoice_items (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  purchase_invoice_id uuid NOT NULL REFERENCES purchase_invoices(id) ON DELETE CASCADE,
  item_id             uuid REFERENCES inventory_items(id) ON DELETE RESTRICT,
  line_number         smallint NOT NULL,
  description         text NOT NULL,
  hsn_code            text,
  quantity            numeric(14,3) NOT NULL DEFAULT 1,
  unit_price          numeric(14,4) NOT NULL DEFAULT 0,
  discount_amount     numeric(14,2) NOT NULL DEFAULT 0,
  taxable_value       numeric(14,2) NOT NULL DEFAULT 0,
  cgst_amount         numeric(14,2) NOT NULL DEFAULT 0,
  sgst_amount         numeric(14,2) NOT NULL DEFAULT 0,
  igst_amount         numeric(14,2) NOT NULL DEFAULT 0,
  total_amount        numeric(14,2) NOT NULL DEFAULT 0,
  CONSTRAINT purchase_invoice_items_line_uq UNIQUE (purchase_invoice_id, line_number)
);

CREATE TABLE stock_counts (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id  uuid NOT NULL REFERENCES properties(id) ON DELETE RESTRICT,
  count_number text NOT NULL,
  store_id     uuid NOT NULL REFERENCES stores(id) ON DELETE RESTRICT,
  count_date   date NOT NULL DEFAULT CURRENT_DATE,
  status       text NOT NULL DEFAULT 'DRAFT',
  counted_by   uuid REFERENCES users(id),
  approved_by  uuid REFERENCES users(id),
  approved_at  timestamptz,
  notes        text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT stock_counts_uq UNIQUE (property_id, count_number),
  CONSTRAINT stock_counts_status_chk CHECK (status IN ('DRAFT','IN_PROGRESS','COMPLETED','APPROVED','CANCELLED'))
);

CREATE TABLE stock_count_items (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  stock_count_id    uuid NOT NULL REFERENCES stock_counts(id) ON DELETE CASCADE,
  item_id           uuid NOT NULL REFERENCES inventory_items(id) ON DELETE RESTRICT,
  system_quantity   numeric(14,3) NOT NULL DEFAULT 0,
  counted_quantity  numeric(14,3) NOT NULL DEFAULT 0,
  variance_quantity numeric(14,3) GENERATED ALWAYS AS (counted_quantity - system_quantity) STORED,
  unit_cost         numeric(14,4) NOT NULL DEFAULT 0,
  notes             text,
  stock_movement_id uuid REFERENCES stock_movements(id) ON DELETE SET NULL,
  CONSTRAINT stock_count_items_uq UNIQUE (stock_count_id, item_id),
  CONSTRAINT stock_count_items_qty_chk CHECK (counted_quantity >= 0)
);

CREATE TRIGGER inventory_items_updated_at   BEFORE UPDATE ON inventory_items   FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();
CREATE TRIGGER suppliers_updated_at         BEFORE UPDATE ON suppliers         FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();
CREATE TRIGGER purchase_requests_updated_at BEFORE UPDATE ON purchase_requests FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();
CREATE TRIGGER purchase_orders_updated_at   BEFORE UPDATE ON purchase_orders   FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();
CREATE TRIGGER goods_receipts_updated_at    BEFORE UPDATE ON goods_receipts    FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();
CREATE TRIGGER purchase_invoices_updated_at BEFORE UPDATE ON purchase_invoices FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();
