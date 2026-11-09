-- =====================================================================
-- 0005_accounting.sql
-- Double-entry accounting: chart of accounts, fiscal periods, journal
-- entries and lines, plus the constraints that keep the books balanced.
--
-- Non-negotiable rules enforced here by the database:
--   1. A line is either a debit or a credit, never both, never zero.
--   2. A posted entry's debits must equal its credits (deferred check,
--      so multi-statement posting in one transaction is allowed).
--   3. A posted entry is immutable. Corrections happen by reversal.
--   4. Nothing may post into a CLOSED or LOCKED accounting period.
--
-- Every financial report reads from journal_lines. No report sums
-- reservation totals directly.
-- =====================================================================

CREATE TYPE account_type AS ENUM ('ASSET','LIABILITY','EQUITY','REVENUE','EXPENSE');
CREATE TYPE journal_type AS ENUM (
  'SALES','RECEIPT','PAYMENT','PURCHASE','CONTRA','GENERAL',
  'ADJUSTMENT','OPENING','CLOSING','INVENTORY','PAYROLL'
);
CREATE TYPE period_status AS ENUM ('OPEN','CLOSED','LOCKED');

CREATE TABLE accounts (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  property_id       uuid REFERENCES properties(id) ON DELETE CASCADE,
  code              text NOT NULL,
  name              text NOT NULL,
  account_type      account_type NOT NULL,
  account_subtype   text,
  parent_account_id uuid REFERENCES accounts(id) ON DELETE RESTRICT,
  -- Group accounts are headings and cannot be posted to directly.
  is_group          boolean NOT NULL DEFAULT false,
  -- Derived from type: assets/expenses are debit-normal.
  normal_balance    text GENERATED ALWAYS AS (
                      CASE WHEN account_type IN ('ASSET','EXPENSE') THEN 'DEBIT' ELSE 'CREDIT' END
                    ) STORED,
  currency_code     char(3) NOT NULL DEFAULT 'INR',
  is_cash           boolean NOT NULL DEFAULT false,
  is_bank           boolean NOT NULL DEFAULT false,
  bank_details      jsonb,
  is_system         boolean NOT NULL DEFAULT false,
  is_active         boolean NOT NULL DEFAULT true,
  description       text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT accounts_code_uq UNIQUE (organization_id, code),
  CONSTRAINT accounts_no_self_parent_chk CHECK (parent_account_id IS DISTINCT FROM id),
  CONSTRAINT accounts_cash_bank_chk CHECK (NOT (is_cash AND is_bank)),
  CONSTRAINT accounts_cash_is_asset_chk CHECK (NOT (is_cash OR is_bank) OR account_type = 'ASSET')
);
CREATE INDEX accounts_org_type_idx ON accounts(organization_id, account_type) WHERE is_active;
CREATE INDEX accounts_parent_idx   ON accounts(parent_account_id);

ALTER TABLE charge_codes
  ADD CONSTRAINT charge_codes_revenue_account_fk
  FOREIGN KEY (revenue_account_id) REFERENCES accounts(id) ON DELETE RESTRICT;
ALTER TABLE payment_methods
  ADD CONSTRAINT payment_methods_account_fk
  FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE RESTRICT;

-- India: 1 Apr -> 31 Mar
CREATE TABLE fiscal_years (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  name            text NOT NULL,
  start_date      date NOT NULL,
  end_date        date NOT NULL,
  status          period_status NOT NULL DEFAULT 'OPEN',
  created_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fiscal_years_uq UNIQUE (organization_id, name),
  CONSTRAINT fiscal_years_dates_chk CHECK (end_date > start_date),
  CONSTRAINT fiscal_years_no_overlap
    EXCLUDE USING gist (organization_id WITH =, daterange(start_date, end_date, '[]') WITH &&)
);

CREATE TABLE accounting_periods (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  fiscal_year_id uuid NOT NULL REFERENCES fiscal_years(id) ON DELETE CASCADE,
  name           text NOT NULL,
  start_date     date NOT NULL,
  end_date       date NOT NULL,
  status         period_status NOT NULL DEFAULT 'OPEN',
  closed_at      timestamptz,
  closed_by      uuid REFERENCES users(id),
  CONSTRAINT accounting_periods_uq UNIQUE (fiscal_year_id, name),
  CONSTRAINT accounting_periods_dates_chk CHECK (end_date >= start_date),
  CONSTRAINT accounting_periods_no_overlap
    EXCLUDE USING gist (fiscal_year_id WITH =, daterange(start_date, end_date, '[]') WITH &&)
);
CREATE INDEX accounting_periods_range_idx ON accounting_periods(start_date, end_date);

-- source_type/source_id tie each entry to the business document that
-- produced it, so every ledger line is traceable to an operational event.
CREATE TABLE journal_entries (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id      uuid NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,
  property_id          uuid NOT NULL REFERENCES properties(id) ON DELETE RESTRICT,
  entry_number         text NOT NULL,
  entry_date           date NOT NULL,
  period_id            uuid REFERENCES accounting_periods(id) ON DELETE RESTRICT,
  journal_type         journal_type NOT NULL DEFAULT 'GENERAL',
  narration            text NOT NULL,
  source_type          text,
  source_id            uuid,
  currency_code        char(3) NOT NULL DEFAULT 'INR',
  total_debit          numeric(16,2) NOT NULL DEFAULT 0,
  total_credit         numeric(16,2) NOT NULL DEFAULT 0,
  is_posted            boolean NOT NULL DEFAULT false,
  posted_at            timestamptz,
  posted_by            uuid REFERENCES users(id),
  is_reversed          boolean NOT NULL DEFAULT false,
  reversed_at          timestamptz,
  reversal_of_entry_id uuid REFERENCES journal_entries(id) ON DELETE RESTRICT,
  created_by           uuid REFERENCES users(id),
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT journal_entries_number_uq UNIQUE (property_id, entry_number),
  CONSTRAINT journal_entries_posted_chk CHECK (NOT is_posted OR posted_at IS NOT NULL),
  CONSTRAINT journal_entries_no_self_reversal_chk CHECK (reversal_of_entry_id IS DISTINCT FROM id),
  CONSTRAINT journal_entries_totals_chk CHECK (total_debit >= 0 AND total_credit >= 0)
);
CREATE INDEX journal_entries_property_date_idx ON journal_entries(property_id, entry_date DESC);
CREATE INDEX journal_entries_source_idx        ON journal_entries(source_type, source_id);
CREATE INDEX journal_entries_period_idx        ON journal_entries(period_id);
-- One posted entry per source document: re-running a posting job cannot
-- double-count revenue.
CREATE UNIQUE INDEX journal_entries_source_uq
  ON journal_entries(source_type, source_id)
  WHERE source_type IS NOT NULL AND source_id IS NOT NULL AND NOT is_reversed;

CREATE TABLE journal_lines (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  journal_entry_id uuid NOT NULL REFERENCES journal_entries(id) ON DELETE CASCADE,
  property_id      uuid NOT NULL REFERENCES properties(id) ON DELETE RESTRICT,
  line_number      smallint NOT NULL,
  account_id       uuid NOT NULL REFERENCES accounts(id) ON DELETE RESTRICT,
  debit            numeric(16,2) NOT NULL DEFAULT 0,
  credit           numeric(16,2) NOT NULL DEFAULT 0,
  description      text,
  -- Sub-ledger dimensions: who this line is receivable from / payable to.
  party_type       text,
  party_id         uuid,
  cost_center      text,
  tax_type         tax_type,
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT journal_lines_uq UNIQUE (journal_entry_id, line_number),
  CONSTRAINT journal_lines_sign_chk CHECK (debit >= 0 AND credit >= 0),
  CONSTRAINT journal_lines_one_side_chk CHECK (
    (debit > 0 AND credit = 0) OR (credit > 0 AND debit = 0)),
  CONSTRAINT journal_lines_party_chk CHECK (
    party_type IS NULL OR party_type IN
      ('GUEST','CORPORATE','TRAVEL_AGENT','SUPPLIER','EMPLOYEE','CHANNEL'))
);
CREATE INDEX journal_lines_entry_idx   ON journal_lines(journal_entry_id);
CREATE INDEX journal_lines_account_idx ON journal_lines(account_id);
CREATE INDEX journal_lines_party_idx   ON journal_lines(party_type, party_id);

ALTER TABLE folio_items ADD CONSTRAINT folio_items_journal_fk
  FOREIGN KEY (journal_entry_id) REFERENCES journal_entries(id) ON DELETE SET NULL;
ALTER TABLE invoices ADD CONSTRAINT invoices_journal_fk
  FOREIGN KEY (journal_entry_id) REFERENCES journal_entries(id) ON DELETE SET NULL;
ALTER TABLE payments ADD CONSTRAINT payments_journal_fk
  FOREIGN KEY (journal_entry_id) REFERENCES journal_entries(id) ON DELETE SET NULL;

-- RULE 2 :: a posted entry must balance. DEFERRABLE INITIALLY DEFERRED
-- so the header and its lines can be inserted as separate statements in
-- one transaction; the check fires at COMMIT.
CREATE OR REPLACE FUNCTION app.assert_journal_balanced()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_entry_id uuid := COALESCE(NEW.id, OLD.id);
  v_posted boolean; v_debit numeric(16,2); v_credit numeric(16,2); v_lines integer;
BEGIN
  SELECT is_posted INTO v_posted FROM journal_entries WHERE id = v_entry_id;
  -- Entry deleted later in the same transaction: nothing to verify.
  IF NOT FOUND OR NOT v_posted THEN RETURN NULL; END IF;

  SELECT COALESCE(sum(debit),0), COALESCE(sum(credit),0), count(*)
    INTO v_debit, v_credit, v_lines
    FROM journal_lines WHERE journal_entry_id = v_entry_id;

  IF v_lines < 2 THEN
    RAISE EXCEPTION 'Journal entry % must have at least two lines (found %)',
      v_entry_id, v_lines USING ERRCODE = 'check_violation';
  END IF;
  IF v_debit <> v_credit THEN
    RAISE EXCEPTION 'Journal entry % is unbalanced: debits % <> credits %',
      v_entry_id, v_debit, v_credit USING ERRCODE = 'check_violation';
  END IF;
  RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER journal_entries_balanced
  AFTER INSERT OR UPDATE ON journal_entries
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION app.assert_journal_balanced();

CREATE CONSTRAINT TRIGGER journal_lines_balanced
  AFTER INSERT OR UPDATE OR DELETE ON journal_lines
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION app.assert_journal_balanced();

CREATE OR REPLACE FUNCTION app.sync_journal_totals()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_entry_id uuid := COALESCE(NEW.journal_entry_id, OLD.journal_entry_id);
BEGIN
  UPDATE journal_entries je
     SET total_debit = COALESCE(t.d,0), total_credit = COALESCE(t.c,0)
    FROM (SELECT sum(debit) d, sum(credit) c FROM journal_lines
           WHERE journal_entry_id = v_entry_id) t
   WHERE je.id = v_entry_id;
  RETURN NULL;
END;
$$;
CREATE TRIGGER journal_lines_sync_totals
  AFTER INSERT OR UPDATE OR DELETE ON journal_lines
  FOR EACH ROW EXECUTE FUNCTION app.sync_journal_totals();

-- RULE 3 :: posted entries are immutable; only reversal bookkeeping
-- columns may change after posting.
CREATE OR REPLACE FUNCTION app.protect_posted_journal()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.is_posted THEN
      RAISE EXCEPTION 'Posted journal entry % cannot be deleted; post a reversal instead',
        OLD.entry_number USING ERRCODE = 'restrict_violation';
    END IF;
    RETURN OLD;
  END IF;
  IF OLD.is_posted THEN
    IF NEW.entry_date   IS DISTINCT FROM OLD.entry_date
    OR NEW.property_id  IS DISTINCT FROM OLD.property_id
    OR NEW.journal_type IS DISTINCT FROM OLD.journal_type
    OR NEW.entry_number IS DISTINCT FROM OLD.entry_number
    OR NEW.narration    IS DISTINCT FROM OLD.narration
    OR NEW.is_posted    IS DISTINCT FROM OLD.is_posted THEN
      RAISE EXCEPTION 'Posted journal entry % is immutable; post a reversal instead',
        OLD.entry_number USING ERRCODE = 'restrict_violation';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER journal_entries_immutable
  BEFORE UPDATE OR DELETE ON journal_entries
  FOR EACH ROW EXECUTE FUNCTION app.protect_posted_journal();

CREATE OR REPLACE FUNCTION app.protect_posted_journal_lines()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_entry_id uuid := COALESCE(NEW.journal_entry_id, OLD.journal_entry_id);
  v_posted boolean;
BEGIN
  SELECT is_posted INTO v_posted FROM journal_entries WHERE id = v_entry_id;
  -- Cascade delete of an unposted entry, or entry already gone.
  IF NOT FOUND THEN RETURN COALESCE(NEW, OLD); END IF;
  IF v_posted THEN
    RAISE EXCEPTION 'Lines of posted journal entry % cannot be modified', v_entry_id
      USING ERRCODE = 'restrict_violation';
  END IF;
  RETURN COALESCE(NEW, OLD);
END;
$$;
CREATE TRIGGER journal_lines_immutable
  BEFORE UPDATE OR DELETE ON journal_lines
  FOR EACH ROW EXECUTE FUNCTION app.protect_posted_journal_lines();

-- RULE 4 :: no posting into a closed period; also resolves period_id
-- automatically from entry_date.
CREATE OR REPLACE FUNCTION app.assert_period_open()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_status period_status; v_period uuid;
BEGIN
  IF NEW.period_id IS NULL THEN
    SELECT ap.id, ap.status INTO v_period, v_status
      FROM accounting_periods ap
      JOIN fiscal_years fy ON fy.id = ap.fiscal_year_id
     WHERE fy.organization_id = NEW.organization_id
       AND NEW.entry_date BETWEEN ap.start_date AND ap.end_date
     LIMIT 1;
    NEW.period_id := v_period;
  ELSE
    SELECT status INTO v_status FROM accounting_periods WHERE id = NEW.period_id;
  END IF;

  IF v_status IS NOT NULL AND v_status <> 'OPEN' THEN
    RAISE EXCEPTION 'Accounting period for % is % and cannot accept postings',
      NEW.entry_date, v_status USING ERRCODE = 'restrict_violation';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER journal_entries_period_open
  BEFORE INSERT OR UPDATE ON journal_entries
  FOR EACH ROW EXECUTE FUNCTION app.assert_period_open();

-- Reporting views :: every financial report starts from these.
CREATE VIEW v_general_ledger AS
SELECT jl.id AS line_id, je.id AS entry_id, je.organization_id, je.property_id,
       je.entry_number, je.entry_date, je.journal_type, je.narration,
       je.source_type, je.source_id,
       a.id AS account_id, a.code AS account_code, a.name AS account_name, a.account_type,
       jl.debit, jl.credit, jl.debit - jl.credit AS signed_amount,
       jl.party_type, jl.party_id, jl.tax_type, jl.description
FROM journal_lines jl
JOIN journal_entries je ON je.id = jl.journal_entry_id
JOIN accounts a ON a.id = jl.account_id
WHERE je.is_posted;

-- Sum of net_balance across every account of a property must be zero.
CREATE VIEW v_trial_balance AS
SELECT je.organization_id, je.property_id, a.id AS account_id,
       a.code AS account_code, a.name AS account_name, a.account_type, a.normal_balance,
       sum(jl.debit) AS total_debit, sum(jl.credit) AS total_credit,
       sum(jl.debit - jl.credit) AS net_balance
FROM journal_lines jl
JOIN journal_entries je ON je.id = jl.journal_entry_id
JOIN accounts a ON a.id = jl.account_id
WHERE je.is_posted
GROUP BY je.organization_id, je.property_id, a.id, a.code, a.name, a.account_type, a.normal_balance;

CREATE TRIGGER accounts_updated_at        BEFORE UPDATE ON accounts        FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();
CREATE TRIGGER journal_entries_updated_at BEFORE UPDATE ON journal_entries FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();
