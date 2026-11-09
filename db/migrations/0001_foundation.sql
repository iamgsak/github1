-- =====================================================================
-- 0001_foundation.sql
-- Hotel ERP :: Foundation
--   extensions, helper schema, tenancy (organizations -> properties),
--   users, RBAC primitives, settings, document numbering, audit log,
--   idempotency keys.
--
-- Tenancy rule: every business table is scoped by property_id (physical
-- hotel) and reachable to an organization_id (tenant). Nothing here is
-- global except the permission catalogue and system roles.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;    -- gen_random_uuid(), digest()
CREATE EXTENSION IF NOT EXISTS btree_gist;  -- room-night exclusion constraints
CREATE EXTENSION IF NOT EXISTS citext;      -- case-insensitive email

-- `app` holds security/helper functions referenced by RLS policies.
CREATE SCHEMA IF NOT EXISTS app;

CREATE OR REPLACE FUNCTION app.set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------
-- Organizations (SaaS tenant)
-- ---------------------------------------------------------------------
CREATE TABLE organizations (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name              text NOT NULL,
  slug              citext NOT NULL UNIQUE,
  legal_name        text,
  country_code      char(2) NOT NULL DEFAULT 'IN',
  base_currency     char(3) NOT NULL DEFAULT 'INR',
  subscription_plan text NOT NULL DEFAULT 'STANDARD',
  is_active         boolean NOT NULL DEFAULT true,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT organizations_slug_chk CHECK (slug ~ '^[a-z0-9][a-z0-9-]{1,62}$')
);

-- ---------------------------------------------------------------------
-- Properties (physical hotels)
-- ---------------------------------------------------------------------
CREATE TABLE properties (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  uuid NOT NULL REFERENCES organizations(id) ON DELETE RESTRICT,
  code             text NOT NULL,
  name             text NOT NULL,
  legal_name       text,
  address_line1    text,
  address_line2    text,
  city             text,
  state            text,
  -- GST place-of-supply code, e.g. '29' for Karnataka.
  state_code       char(2),
  postal_code      text,
  country_code     char(2) NOT NULL DEFAULT 'IN',
  phone            text,
  email            citext,
  website          text,
  gstin            text,
  pan              text,
  logo_url         text,
  currency_code    char(3) NOT NULL DEFAULT 'INR',
  timezone         text NOT NULL DEFAULT 'Asia/Kolkata',
  check_in_time    time NOT NULL DEFAULT '14:00',
  check_out_time   time NOT NULL DEFAULT '11:00',
  -- Night audit boundary; nights roll over at this time.
  night_audit_time time NOT NULL DEFAULT '03:00',
  is_active        boolean NOT NULL DEFAULT true,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT properties_code_uq UNIQUE (organization_id, code),
  -- 15-char GSTIN: 2 state + 10 PAN + entity + Z + checksum
  CONSTRAINT properties_gstin_chk CHECK (
    gstin IS NULL OR gstin ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z]{1}[1-9A-Z]{1}Z[0-9A-Z]{1}$'),
  CONSTRAINT properties_pan_chk CHECK (pan IS NULL OR pan ~ '^[A-Z]{5}[0-9]{4}[A-Z]$'),
  CONSTRAINT properties_state_code_chk CHECK (state_code IS NULL OR state_code ~ '^[0-9]{2}$')
);
CREATE INDEX properties_org_idx ON properties(organization_id) WHERE is_active;

-- ---------------------------------------------------------------------
-- Users. Mirrors the identity provider (Supabase auth.users) by primary
-- key. The FK is added only when that schema exists, so the same
-- migration runs on a plain PostgreSQL instance (CI, local, self-host).
-- ---------------------------------------------------------------------
CREATE TABLE users (
  id                uuid PRIMARY KEY,
  organization_id   uuid REFERENCES organizations(id) ON DELETE RESTRICT,
  email             citext NOT NULL UNIQUE,
  full_name         text NOT NULL,
  phone             text,
  avatar_url        text,
  -- Platform operator, not a hotel role. Bypasses org scoping.
  is_platform_admin boolean NOT NULL DEFAULT false,
  is_active         boolean NOT NULL DEFAULT true,
  last_login_at     timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX users_org_idx ON users(organization_id);

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables
             WHERE table_schema = 'auth' AND table_name = 'users') THEN
    ALTER TABLE users ADD CONSTRAINT users_auth_fk
      FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;
  END IF;
END;
$$;

-- ---------------------------------------------------------------------
-- RBAC
-- permissions: global catalogue, code = '<module>.<action>'
-- roles: system roles (organization_id IS NULL) + per-org custom roles
-- user_roles: grant, optionally scoped to one property
--             (property_id IS NULL => all properties in the org)
-- ---------------------------------------------------------------------
CREATE TABLE permissions (
  code         text PRIMARY KEY,
  module       text NOT NULL,
  action       text NOT NULL,
  description  text NOT NULL,
  -- Financially/legally sensitive permissions are surfaced separately
  -- in the role editor and require a deliberate grant.
  is_sensitive boolean NOT NULL DEFAULT false,
  CONSTRAINT permissions_code_chk CHECK (code ~ '^[a-z_]+\.[a-z_]+$')
);

CREATE TABLE roles (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid REFERENCES organizations(id) ON DELETE CASCADE,
  code            text NOT NULL,
  name            text NOT NULL,
  description     text,
  is_system       boolean NOT NULL DEFAULT false,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT roles_code_uq UNIQUE NULLS NOT DISTINCT (organization_id, code),
  CONSTRAINT roles_system_chk CHECK (NOT is_system OR organization_id IS NULL)
);

CREATE TABLE role_permissions (
  role_id         uuid NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
  permission_code text NOT NULL REFERENCES permissions(code) ON DELETE CASCADE,
  PRIMARY KEY (role_id, permission_code)
);

CREATE TABLE user_roles (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role_id     uuid NOT NULL REFERENCES roles(id) ON DELETE RESTRICT,
  property_id uuid REFERENCES properties(id) ON DELETE CASCADE,
  granted_by  uuid REFERENCES users(id),
  granted_at  timestamptz NOT NULL DEFAULT now(),
  expires_at  timestamptz,
  CONSTRAINT user_roles_uq UNIQUE NULLS NOT DISTINCT (user_id, role_id, property_id)
);
CREATE INDEX user_roles_user_idx ON user_roles(user_id);
CREATE INDEX user_roles_property_idx ON user_roles(property_id);

-- ---------------------------------------------------------------------
-- Settings. Secrets never live here -- see integration_credentials.
-- ---------------------------------------------------------------------
CREATE TABLE settings (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  property_id     uuid REFERENCES properties(id) ON DELETE CASCADE,
  category        text NOT NULL,
  key             text NOT NULL,
  value           jsonb NOT NULL,
  description     text,
  updated_by      uuid REFERENCES users(id),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT settings_uq UNIQUE NULLS NOT DISTINCT (organization_id, property_id, category, key)
);

-- ---------------------------------------------------------------------
-- Document numbering. Sequential per series, allocated under a row lock.
-- ---------------------------------------------------------------------
CREATE TYPE document_type AS ENUM (
  'RESERVATION','FOLIO','INVOICE','CREDIT_NOTE','DEBIT_NOTE','PROFORMA',
  'RECEIPT','REFUND','JOURNAL','PURCHASE_REQUEST','PURCHASE_ORDER',
  'GOODS_RECEIPT','PURCHASE_INVOICE','MAINTENANCE_TICKET','LEAD','GUEST'
);

CREATE TABLE document_series (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id     uuid NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
  doc_type        document_type NOT NULL,
  prefix          text NOT NULL DEFAULT '',
  suffix          text NOT NULL DEFAULT '',
  next_number     bigint NOT NULL DEFAULT 1,
  padding         smallint NOT NULL DEFAULT 5,
  -- Financial-year reset for the GST invoice series (e.g. 2026-27).
  reset_frequency text NOT NULL DEFAULT 'FISCAL_YEAR',
  fiscal_year     text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT document_series_uq UNIQUE (property_id, doc_type, fiscal_year),
  CONSTRAINT document_series_next_chk CHECK (next_number > 0),
  CONSTRAINT document_series_padding_chk CHECK (padding BETWEEN 0 AND 12),
  CONSTRAINT document_series_reset_chk
    CHECK (reset_frequency IN ('NEVER','FISCAL_YEAR','CALENDAR_YEAR','MONTHLY'))
);

-- Allocates the next number atomically. The UPDATE takes a row lock, so
-- concurrent callers serialise and never receive the same number.
CREATE OR REPLACE FUNCTION app.next_document_number(
  p_property_id uuid,
  p_doc_type    document_type,
  p_fiscal_year text DEFAULT NULL
) RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  v_num bigint; v_prefix text; v_suffix text; v_pad smallint;
BEGIN
  UPDATE document_series
     SET next_number = next_number + 1, updated_at = now()
   WHERE property_id = p_property_id
     AND doc_type    = p_doc_type
     AND fiscal_year IS NOT DISTINCT FROM p_fiscal_year
  RETURNING next_number - 1, prefix, suffix, padding
       INTO v_num, v_prefix, v_suffix, v_pad;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No document series for property % / type % / FY %',
      p_property_id, p_doc_type, COALESCE(p_fiscal_year, '-')
      USING ERRCODE = 'no_data_found';
  END IF;

  RETURN v_prefix || lpad(v_num::text, v_pad, '0') || v_suffix;
END;
$$;

-- ---------------------------------------------------------------------
-- Audit log :: append-only. UPDATE/DELETE revoked in 0010.
-- ---------------------------------------------------------------------
CREATE TABLE audit_logs (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  organization_id uuid,
  property_id     uuid,
  user_id         uuid,
  user_email      text,
  action          text NOT NULL,
  module          text NOT NULL,
  table_name      text NOT NULL,
  record_id       text,
  old_values      jsonb,
  new_values      jsonb,
  changed_fields  text[],
  ip_address      inet,
  user_agent      text,
  request_id      text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT audit_logs_action_chk
    CHECK (action IN ('INSERT','UPDATE','DELETE','LOGIN','LOGOUT','LOGIN_FAILED',
                      'VOID','CANCEL','POST','REVERSE','EXPORT','SYNC','APPROVE','REJECT'))
);
CREATE INDEX audit_logs_property_time_idx ON audit_logs(property_id, created_at DESC);
CREATE INDEX audit_logs_record_idx        ON audit_logs(table_name, record_id);
CREATE INDEX audit_logs_user_idx          ON audit_logs(user_id, created_at DESC);

-- ---------------------------------------------------------------------
-- Idempotency keys :: guards non-idempotent endpoints (booking creation,
-- payment capture, OTA replay).
-- ---------------------------------------------------------------------
CREATE TABLE idempotency_keys (
  key           text PRIMARY KEY,
  scope         text NOT NULL,
  request_hash  text NOT NULL,
  status        text NOT NULL DEFAULT 'IN_PROGRESS',
  response_body jsonb,
  response_code integer,
  created_at    timestamptz NOT NULL DEFAULT now(),
  expires_at    timestamptz NOT NULL DEFAULT now() + interval '24 hours',
  CONSTRAINT idempotency_status_chk CHECK (status IN ('IN_PROGRESS','COMPLETED','FAILED'))
);
CREATE INDEX idempotency_keys_expiry_idx ON idempotency_keys(expires_at);

CREATE TRIGGER organizations_updated_at   BEFORE UPDATE ON organizations   FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();
CREATE TRIGGER properties_updated_at      BEFORE UPDATE ON properties      FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();
CREATE TRIGGER users_updated_at           BEFORE UPDATE ON users           FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();
CREATE TRIGGER roles_updated_at           BEFORE UPDATE ON roles           FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();
CREATE TRIGGER settings_updated_at        BEFORE UPDATE ON settings        FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();
CREATE TRIGGER document_series_updated_at BEFORE UPDATE ON document_series FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();
