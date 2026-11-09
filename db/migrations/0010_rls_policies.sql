-- =====================================================================
-- 0010_rls_policies.sql
-- Row Level Security: tenant isolation and sensitive-table restrictions.
--
-- Defence in depth, not the only defence. The API layer checks
-- permissions on every request; RLS is the backstop that makes a missed
-- check, an injected filter, or a direct PostgREST call fail closed
-- instead of leaking another tenant's data.
--
-- Roles:
--   anon          public booking engine, unauthenticated
--   authenticated a signed-in ERP user
--   service_role  trusted server-side worker; bypasses RLS by design
-- =====================================================================

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN BYPASSRLS;
  END IF;
END;
$$;

-- All helpers are STABLE + SECURITY DEFINER so policies can read the
-- RBAC tables without the calling user needing direct access to them.

-- On Supabase auth.uid() is the JWT subject; elsewhere fall back to the GUC.
CREATE OR REPLACE FUNCTION app.auth_user_id() RETURNS uuid
LANGUAGE plpgsql STABLE AS $$
DECLARE v_id uuid;
BEGIN
  BEGIN
    EXECUTE 'SELECT auth.uid()' INTO v_id;
  EXCEPTION WHEN others THEN v_id := NULL;
  END;
  RETURN COALESCE(v_id, app.current_user_id());
END;
$$;

CREATE OR REPLACE FUNCTION app.is_platform_admin() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT COALESCE((SELECT u.is_platform_admin AND u.is_active
                     FROM users u WHERE u.id = app.auth_user_id()), false);
$$;

CREATE OR REPLACE FUNCTION app.current_org_id() RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT u.organization_id FROM users u
   WHERE u.id = app.auth_user_id() AND u.is_active;
$$;

-- A role grant with property_id IS NULL is organization-wide, so it
-- expands to every property of the org.
CREATE OR REPLACE FUNCTION app.user_property_ids() RETURNS uuid[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT COALESCE(array_agg(DISTINCT p.id), '{}')
    FROM properties p
   WHERE p.organization_id = app.current_org_id()
     AND EXISTS (
       SELECT 1 FROM user_roles ur
        WHERE ur.user_id = app.auth_user_id()
          AND (ur.expires_at IS NULL OR ur.expires_at > now())
          AND (ur.property_id IS NULL OR ur.property_id = p.id));
$$;

CREATE OR REPLACE FUNCTION app.has_property_access(p_property_id uuid) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT app.is_platform_admin() OR p_property_id = ANY(app.user_property_ids());
$$;

CREATE OR REPLACE FUNCTION app.has_permission(p_code text, p_property_id uuid DEFAULT NULL)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT app.is_platform_admin() OR EXISTS (
    SELECT 1 FROM user_roles ur
      JOIN role_permissions rp ON rp.role_id = ur.role_id
     WHERE ur.user_id = app.auth_user_id()
       AND rp.permission_code = p_code
       AND (ur.expires_at IS NULL OR ur.expires_at > now())
       AND (p_property_id IS NULL OR ur.property_id IS NULL OR ur.property_id = p_property_id));
$$;

GRANT USAGE ON SCHEMA app TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- Property-scoped tables.
-- ---------------------------------------------------------------------
DO $$
DECLARE
  t text;
  property_scoped text[] := ARRAY[
    'room_types','rooms','cancellation_policies','rate_plans',
    'rate_seasons','room_rates','rate_restrictions','inventory_daily',
    'reservations','reservation_rooms','reservation_room_rates','room_allocations',
    'tax_groups','charge_codes','folios','folio_items','invoices',
    'payment_methods','payments','refunds','payment_gateway_transactions',
    'journal_entries','journal_lines','stores','stock_balances','stock_movements',
    'purchase_requests','purchase_orders','goods_receipts','purchase_invoices',
    'stock_counts','departments','attendance','leave_requests','employee_advances',
    'housekeeping_tasks','assets','maintenance_tickets','corporate_rate_contracts',
    'crm_leads','channels','integration_credentials','ota_reservations',
    'sync_queue','sync_logs','notification_templates','document_series'
  ];
BEGIN
  FOREACH t IN ARRAY property_scoped LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
    EXECUTE format($p$
      CREATE POLICY %1$I_tenant_isolation ON %1$I
        FOR ALL TO authenticated
        USING (property_id IS NULL OR app.has_property_access(property_id))
        WITH CHECK (property_id IS NULL OR app.has_property_access(property_id))
    $p$, t);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I TO authenticated', t);
  END LOOP;
END;
$$;

-- ---------------------------------------------------------------------
-- Child tables carry no tenant column of their own; they inherit scope
-- from their parent. Because the parent is itself under RLS, the EXISTS
-- below is automatically filtered by the parent's policy -- so a child
-- row is reachable exactly when its parent is.
-- ---------------------------------------------------------------------
DO $$
DECLARE
  child_parents text[][] := ARRAY[
    ARRAY['accounting_periods',      'fiscal_years',       'fiscal_year_id'],
    ARRAY['channel_rate_mappings',   'channels',           'channel_id'],
    ARRAY['channel_room_mappings',   'channels',           'channel_id'],
    ARRAY['crm_activities',          'crm_leads',          'lead_id'],
    ARRAY['folio_item_taxes',        'folio_items',        'folio_item_id'],
    ARRAY['goods_receipt_items',     'goods_receipts',     'goods_receipt_id'],
    ARRAY['invoice_items',           'invoices',           'invoice_id'],
    ARRAY['maintenance_attachments', 'maintenance_tickets','ticket_id'],
    ARRAY['ota_reservation_events',  'ota_reservations',   'ota_reservation_id'],
    ARRAY['purchase_invoice_items',  'purchase_invoices',  'purchase_invoice_id'],
    ARRAY['purchase_order_items',    'purchase_orders',    'purchase_order_id'],
    ARRAY['purchase_request_items',  'purchase_requests',  'purchase_request_id'],
    ARRAY['rate_plan_room_types',    'rate_plans',         'rate_plan_id'],
    ARRAY['reservation_guests',      'reservation_rooms',  'reservation_room_id'],
    ARRAY['reservation_status_history','reservations',     'reservation_id'],
    ARRAY['room_type_amenities',     'room_types',         'room_type_id'],
    ARRAY['room_type_images',        'room_types',         'room_type_id'],
    ARRAY['stock_count_items',       'stock_counts',       'stock_count_id'],
    ARRAY['tax_rates',               'tax_groups',         'tax_group_id']
  ];
  i integer;
BEGIN
  FOR i IN 1 .. array_length(child_parents, 1) LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', child_parents[i][1]);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', child_parents[i][1]);
    EXECUTE format($p$
      CREATE POLICY %1$I_inherit_parent ON %1$I
        FOR ALL TO authenticated
        USING (EXISTS (SELECT 1 FROM %2$I p WHERE p.id = %1$I.%3$I))
        WITH CHECK (EXISTS (SELECT 1 FROM %2$I p WHERE p.id = %1$I.%3$I))
    $p$, child_parents[i][1], child_parents[i][2], child_parents[i][3]);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I TO authenticated',
                   child_parents[i][1]);
  END LOOP;
END;
$$;

-- ---------------------------------------------------------------------
-- Organization-scoped tables.
-- ---------------------------------------------------------------------
DO $$
DECLARE
  t text;
  org_scoped text[] := ARRAY[
    'amenities','guests','booking_sources','accounts','fiscal_years',
    'uoms','item_categories','inventory_items','suppliers','employees',
    'corporate_accounts','travel_agents','api_keys','roles'
  ];
BEGIN
  FOREACH t IN ARRAY org_scoped LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
    EXECUTE format($p$
      CREATE POLICY %1$I_org_isolation ON %1$I
        FOR ALL TO authenticated
        USING (app.is_platform_admin() OR organization_id = app.current_org_id())
        WITH CHECK (app.is_platform_admin() OR organization_id = app.current_org_id())
    $p$, t);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %I TO authenticated', t);
  END LOOP;
END;
$$;

-- System roles (organization_id IS NULL) are readable by everyone but
-- writable by nobody through the API.
DROP POLICY roles_org_isolation ON roles;
CREATE POLICY roles_read ON roles
  FOR SELECT TO authenticated
  USING (organization_id IS NULL OR organization_id = app.current_org_id() OR app.is_platform_admin());
CREATE POLICY roles_write ON roles
  FOR ALL TO authenticated
  USING (NOT is_system AND organization_id = app.current_org_id() AND app.has_permission('roles.manage'))
  WITH CHECK (NOT is_system AND organization_id = app.current_org_id() AND app.has_permission('roles.manage'));

ALTER TABLE organizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE organizations FORCE ROW LEVEL SECURITY;
CREATE POLICY organizations_own ON organizations
  FOR SELECT TO authenticated
  USING (app.is_platform_admin() OR id = app.current_org_id());
CREATE POLICY organizations_update ON organizations
  FOR UPDATE TO authenticated
  USING (id = app.current_org_id() AND app.has_permission('organization.manage'))
  WITH CHECK (id = app.current_org_id());
GRANT SELECT, UPDATE ON organizations TO authenticated;

ALTER TABLE properties ENABLE ROW LEVEL SECURITY;
ALTER TABLE properties FORCE ROW LEVEL SECURITY;
CREATE POLICY properties_access ON properties
  FOR SELECT TO authenticated USING (app.has_property_access(id));
CREATE POLICY properties_manage ON properties
  FOR ALL TO authenticated
  USING (app.has_property_access(id) AND app.has_permission('property.manage', id))
  WITH CHECK (organization_id = app.current_org_id());
GRANT SELECT, INSERT, UPDATE ON properties TO authenticated;

-- A user always sees their own row; seeing colleagues needs users.read.
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE users FORCE ROW LEVEL SECURITY;
CREATE POLICY users_self ON users
  FOR SELECT TO authenticated
  USING (id = app.auth_user_id()
         OR app.is_platform_admin()
         OR (organization_id = app.current_org_id() AND app.has_permission('users.read')));
CREATE POLICY users_self_update ON users
  FOR UPDATE TO authenticated
  USING (id = app.auth_user_id()) WITH CHECK (id = app.auth_user_id());
CREATE POLICY users_admin ON users
  FOR ALL TO authenticated
  USING (organization_id = app.current_org_id() AND app.has_permission('users.manage'))
  WITH CHECK (organization_id = app.current_org_id() AND app.has_permission('users.manage'));
GRANT SELECT, INSERT, UPDATE ON users TO authenticated;

ALTER TABLE user_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_roles FORCE ROW LEVEL SECURITY;
CREATE POLICY user_roles_read ON user_roles
  FOR SELECT TO authenticated
  USING (user_id = app.auth_user_id() OR app.has_permission('users.read'));
-- Granting roles is itself a privileged action.
CREATE POLICY user_roles_manage ON user_roles
  FOR ALL TO authenticated
  USING (app.has_permission('users.manage')) WITH CHECK (app.has_permission('users.manage'));
GRANT SELECT, INSERT, UPDATE, DELETE ON user_roles TO authenticated;

ALTER TABLE role_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE role_permissions FORCE ROW LEVEL SECURITY;
CREATE POLICY role_permissions_read ON role_permissions
  FOR SELECT TO authenticated USING (true);
CREATE POLICY role_permissions_manage ON role_permissions
  FOR ALL TO authenticated
  USING (app.has_permission('roles.manage')) WITH CHECK (app.has_permission('roles.manage'));
GRANT SELECT, INSERT, UPDATE, DELETE ON role_permissions TO authenticated;

-- The permission catalogue is public reference data, read-only.
GRANT SELECT ON permissions TO authenticated;

ALTER TABLE settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE settings FORCE ROW LEVEL SECURITY;
CREATE POLICY settings_read ON settings
  FOR SELECT TO authenticated
  USING (organization_id = app.current_org_id()
         AND (property_id IS NULL OR app.has_property_access(property_id)));
CREATE POLICY settings_write ON settings
  FOR ALL TO authenticated
  USING (organization_id = app.current_org_id() AND app.has_permission('settings.manage', property_id))
  WITH CHECK (organization_id = app.current_org_id() AND app.has_permission('settings.manage', property_id));
GRANT SELECT, INSERT, UPDATE, DELETE ON settings TO authenticated;

-- Government ID documents: front office and compliance only.
ALTER TABLE guest_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE guest_documents FORCE ROW LEVEL SECURITY;
CREATE POLICY guest_documents_access ON guest_documents
  FOR ALL TO authenticated
  USING (app.has_permission('guest_documents.read', property_id))
  WITH CHECK (app.has_permission('guest_documents.write', property_id));
GRANT SELECT, INSERT, UPDATE, DELETE ON guest_documents TO authenticated;

-- Employee rows are visible to their own user and to HR.
DROP POLICY employees_org_isolation ON employees;
CREATE POLICY employees_self ON employees
  FOR SELECT TO authenticated
  USING (user_id = app.auth_user_id()
         OR (organization_id = app.current_org_id() AND app.has_permission('employees.read')));
CREATE POLICY employees_manage ON employees
  FOR ALL TO authenticated
  USING (organization_id = app.current_org_id() AND app.has_permission('employees.manage'))
  WITH CHECK (organization_id = app.current_org_id() AND app.has_permission('employees.manage'));

-- Encrypted credentials: never readable through the public API at all.
REVOKE ALL ON integration_credentials FROM authenticated, anon;
DROP POLICY integration_credentials_tenant_isolation ON integration_credentials;
CREATE POLICY integration_credentials_service ON integration_credentials
  FOR ALL TO service_role USING (true) WITH CHECK (true);

-- Server-only tables: raw provider payloads and idempotency bookkeeping
-- are worker-side concerns, never exposed to browser roles.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['webhook_events','idempotency_keys'] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON %I FROM authenticated, anon', t);
    EXECUTE format($p$CREATE POLICY %1$I_service ON %1$I
                      FOR ALL TO service_role USING (true) WITH CHECK (true)$p$, t);
  END LOOP;
END;
$$;

-- Audit logs :: append-only for everyone, immutable to normal users.
ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_logs FORCE ROW LEVEL SECURITY;
CREATE POLICY audit_logs_read ON audit_logs
  FOR SELECT TO authenticated
  USING (app.has_permission('audit.read', property_id)
         AND (property_id IS NULL OR app.has_property_access(property_id)));
GRANT SELECT ON audit_logs TO authenticated;
-- No INSERT grant: rows arrive only via the SECURITY DEFINER audit
-- trigger. No UPDATE/DELETE grant to anyone, ever.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON audit_logs FROM authenticated, anon;

CREATE OR REPLACE FUNCTION app.protect_audit_log()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'audit_logs is append-only and cannot be modified'
    USING ERRCODE = 'restrict_violation';
END;
$$;
CREATE TRIGGER audit_logs_immutable
  BEFORE UPDATE OR DELETE ON audit_logs
  FOR EACH ROW EXECUTE FUNCTION app.protect_audit_log();

CREATE TRIGGER reservation_status_history_immutable
  BEFORE UPDATE OR DELETE ON reservation_status_history
  FOR EACH ROW EXECUTE FUNCTION app.protect_audit_log();

-- ---------------------------------------------------------------------
-- Public booking engine (anon).
-- The anonymous role gets NO table access. Every public read goes
-- through a SECURITY DEFINER RPC that returns only what a shopper needs
-- -- never guest, financial, or operational data.
-- ---------------------------------------------------------------------
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon;

CREATE OR REPLACE FUNCTION app.public_search_availability(
  p_property_id uuid, p_arrival date, p_departure date,
  p_adults integer DEFAULT 2, p_children integer DEFAULT 0, p_rooms integer DEFAULT 1
) RETURNS TABLE (
  room_type_id uuid, room_type_code text, room_type_name text, description text,
  max_occupancy smallint, available_rooms integer,
  rate_plan_id uuid, rate_plan_code text, rate_plan_name text,
  total_rate numeric, nights integer
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT rt.id, rt.code, rt.name, rt.description, rt.max_occupancy,
         app.check_availability(p_property_id, rt.id, p_arrival, p_departure),
         rp.id, rp.code, rp.name,
         (SELECT sum(rr.rate) FROM room_rates rr
           WHERE rr.room_type_id = rt.id AND rr.rate_plan_id = rp.id
             AND rr.stay_date >= p_arrival AND rr.stay_date < p_departure),
         (p_departure - p_arrival)
  FROM room_types rt
  JOIN rate_plan_room_types rprt ON rprt.room_type_id = rt.id AND rprt.is_active
  JOIN rate_plans rp ON rp.id = rprt.rate_plan_id
  WHERE rt.property_id = p_property_id
    AND rt.is_active AND rp.is_active AND rp.is_public
    AND p_departure > p_arrival
    AND rt.max_occupancy >= (p_adults + p_children)
    AND app.check_availability(p_property_id, rt.id, p_arrival, p_departure) >= p_rooms
    -- Respect stop-sell, closed-to-arrival and minimum stay.
    AND NOT EXISTS (
      SELECT 1 FROM rate_restrictions res
       WHERE res.room_type_id = rt.id
         AND (res.rate_plan_id = rp.id OR res.rate_plan_id IS NULL)
         AND res.stay_date >= p_arrival AND res.stay_date < p_departure
         AND (res.stop_sell
              OR (res.closed_to_arrival AND res.stay_date = p_arrival)
              OR (res.min_stay IS NOT NULL AND (p_departure - p_arrival) < res.min_stay)))
    -- Only sell nights that actually have a published price.
    AND (SELECT count(*) FROM room_rates rr
          WHERE rr.room_type_id = rt.id AND rr.rate_plan_id = rp.id
            AND rr.stay_date >= p_arrival AND rr.stay_date < p_departure)
        = (p_departure - p_arrival)
  ORDER BY rt.sort_order, rt.name, rp.code;
$$;

REVOKE ALL ON FUNCTION app.public_search_availability(uuid,date,date,integer,integer,integer) FROM public;
GRANT EXECUTE ON FUNCTION app.public_search_availability(uuid,date,date,integer,integer,integer)
  TO anon, authenticated;

GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO authenticated;
