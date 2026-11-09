-- =====================================================================
-- 0011_seed_system_data.sql
-- System reference data (permission catalogue + built-in roles) and the
-- provisioning functions that give a new organization/property its
-- chart of accounts, tax configuration, charge codes and number series.
--
-- This file contains NO demo/business data -- see db/seed/ for that.
-- It is idempotent and safe to re-run.
-- =====================================================================

INSERT INTO permissions (code, module, action, description, is_sensitive) VALUES
  ('dashboard.read',            'DASHBOARD',   'read',        'View the operational dashboard', false),
  ('dashboard.financial',       'DASHBOARD',   'financial',   'View revenue, profit and cash KPIs', true),
  ('organization.manage',       'ORGANIZATION','manage',      'Edit organization settings', true),
  ('property.manage',           'PROPERTY',    'manage',      'Create and edit properties', true),
  ('users.read',                'USERS',       'read',        'View other users', false),
  ('users.manage',              'USERS',       'manage',      'Create, edit, deactivate users and grant roles', true),
  ('roles.manage',              'USERS',       'manage_roles','Create roles and change permissions', true),
  ('rooms.read',                'PMS',         'read',        'View rooms', false),
  ('rooms.manage',              'PMS',         'manage',      'Create and edit rooms and room types', false),
  ('rates.read',                'RATES',       'read',        'View rate plans and prices', false),
  ('rates.manage',              'RATES',       'manage',      'Create and change rates and rate plans', true),
  ('availability.read',         'RATES',       'read_avail',  'View availability', false),
  ('availability.manage',       'RATES',       'manage_avail','Change inventory, restrictions and stop-sell', true),
  ('reservations.read',         'RESERVATIONS','read',        'View reservations', false),
  ('reservations.create',       'RESERVATIONS','create',      'Create reservations', false),
  ('reservations.update',       'RESERVATIONS','update',      'Modify reservations', false),
  ('reservations.cancel',       'RESERVATIONS','cancel',      'Cancel reservations and mark no-show', false),
  ('reservations.checkin',      'FRONT_OFFICE','checkin',     'Check guests in', false),
  ('reservations.checkout',     'FRONT_OFFICE','checkout',    'Check guests out', false),
  ('reservations.assign_room',  'FRONT_OFFICE','assign_room', 'Assign and change rooms', false),
  ('reservations.override_rate','RESERVATIONS','override_rate','Override the selling rate', true),
  ('guests.read',               'GUESTS',      'read',        'View guest profiles', false),
  ('guests.manage',             'GUESTS',      'manage',      'Create and edit guest profiles', false),
  ('guest_documents.read',      'GUESTS',      'read_docs',   'View guest identity documents', true),
  ('guest_documents.write',     'GUESTS',      'write_docs',  'Upload guest identity documents', true),
  ('folio.read',                'BILLING',     'read',        'View folios', false),
  ('folio.post_charge',         'BILLING',     'post',        'Post charges to a folio', false),
  ('folio.discount',            'BILLING',     'discount',    'Apply discounts', true),
  ('folio.transfer',            'BILLING',     'transfer',    'Transfer or split charges between folios', false),
  ('folio.void',                'BILLING',     'void',        'Void a posted charge', true),
  ('invoices.read',             'BILLING',     'read_invoice','View invoices', false),
  ('invoices.create',           'BILLING',     'create_invoice','Generate invoices', false),
  ('invoices.cancel',           'BILLING',     'cancel_invoice','Cancel an issued invoice', true),
  ('invoices.credit_note',      'BILLING',     'credit_note', 'Issue credit and debit notes', true),
  ('payments.read',             'PAYMENTS',    'read',        'View payments', false),
  ('payments.collect',          'PAYMENTS',    'collect',     'Collect payments and deposits', false),
  ('payments.refund',           'PAYMENTS',    'refund',      'Issue refunds', true),
  ('payments.void',             'PAYMENTS',    'void',        'Void a payment', true),
  ('accounting.read',           'ACCOUNTING',  'read',        'View ledgers and accounting reports', true),
  ('accounting.post',           'ACCOUNTING',  'post',        'Post journal entries', true),
  ('accounting.adjust',         'ACCOUNTING',  'adjust',      'Post adjustments and reversals', true),
  ('accounting.close_period',   'ACCOUNTING',  'close',       'Close or lock an accounting period', true),
  ('accounting.manage_coa',     'ACCOUNTING',  'manage_coa',  'Edit the chart of accounts', true),
  ('tax.read',                  'TAX',         'read',        'View tax configuration', false),
  ('tax.manage',                'TAX',         'manage',      'Change GST and tax configuration', true),
  ('reports.operational',       'REPORTS',     'operational', 'Run operational reports', false),
  ('reports.financial',         'REPORTS',     'financial',   'Run financial reports', true),
  ('reports.export',            'REPORTS',     'export',      'Export reports to PDF/Excel/CSV', false),
  ('inventory.read',            'INVENTORY',   'read',        'View stock', false),
  ('inventory.manage',          'INVENTORY',   'manage',      'Issue, transfer and consume stock', false),
  ('inventory.adjust',          'INVENTORY',   'adjust',      'Adjust stock and approve counts', true),
  ('purchasing.read',           'PURCHASING',  'read',        'View purchase documents', false),
  ('purchasing.create',         'PURCHASING',  'create',      'Raise purchase requests and orders', false),
  ('purchasing.approve',        'PURCHASING',  'approve',     'Approve purchase requests and orders', true),
  ('purchasing.receive',        'PURCHASING',  'receive',     'Record goods receipts', false),
  ('suppliers.read',            'PURCHASING',  'read_supplier','View suppliers', false),
  ('suppliers.manage',          'PURCHASING',  'manage_supplier','Create and edit suppliers', false),
  ('housekeeping.read',         'HOUSEKEEPING','read',        'View housekeeping board', false),
  ('housekeeping.assign',       'HOUSEKEEPING','assign',      'Assign housekeeping tasks', false),
  ('housekeeping.update',       'HOUSEKEEPING','update',      'Update room and task status', false),
  ('housekeeping.inspect',      'HOUSEKEEPING','inspect',     'Inspect and approve cleaned rooms', false),
  ('maintenance.read',          'MAINTENANCE', 'read',        'View maintenance tickets', false),
  ('maintenance.create',        'MAINTENANCE', 'create',      'Raise maintenance tickets', false),
  ('maintenance.assign',        'MAINTENANCE', 'assign',      'Assign maintenance tickets', false),
  ('maintenance.close',         'MAINTENANCE', 'close',       'Complete and close tickets', false),
  ('crm.read',                  'CRM',         'read',        'View leads', false),
  ('crm.manage',                'CRM',         'manage',      'Create and progress leads', false),
  ('corporate.read',            'B2B',         'read',        'View corporate accounts', false),
  ('corporate.manage',          'B2B',         'manage',      'Manage corporate accounts and contract rates', true),
  ('travel_agents.read',        'B2B',         'read_agent',  'View travel agents', false),
  ('travel_agents.manage',      'B2B',         'manage_agent','Manage travel agents and commissions', true),
  ('employees.read',            'HR',          'read',        'View employee records', true),
  ('employees.manage',          'HR',          'manage',      'Manage employees, attendance and leave', true),
  ('payroll.read',              'HR',          'read_payroll','View salary and payroll data', true),
  ('channels.read',             'CHANNELS',    'read',        'View channel status and sync logs', false),
  ('channels.manage',           'CHANNELS',    'manage',      'Configure channels, credentials and mappings', true),
  ('channels.sync',             'CHANNELS',    'sync',        'Trigger a manual channel synchronisation', false),
  ('booking_engine.manage',     'BOOKING_ENGINE','manage',    'Configure the public booking engine', true),
  ('notifications.read',        'NOTIFICATIONS','read',       'View notifications', false),
  ('notifications.manage',      'NOTIFICATIONS','manage',     'Configure templates and providers', true),
  ('settings.read',             'SETTINGS',    'read',        'View system settings', false),
  ('settings.manage',           'SETTINGS',    'manage',      'Change system settings', true),
  ('audit.read',                'AUDIT',       'read',        'View audit logs', true),
  ('api_keys.manage',           'SETTINGS',    'manage_keys', 'Create and revoke API keys', true),
  ('data_import.execute',       'SETTINGS',    'import',      'Import master data from CSV/Excel', true)
ON CONFLICT (code) DO UPDATE
  SET module = EXCLUDED.module, action = EXCLUDED.action,
      description = EXCLUDED.description, is_sensitive = EXCLUDED.is_sensitive;

INSERT INTO roles (organization_id, code, name, description, is_system) VALUES
  (NULL,'SUPER_ADMIN',    'Super Admin',     'Platform operator. Full access to every module.', true),
  (NULL,'OWNER',          'Owner',           'Full business visibility including all financials.', true),
  (NULL,'GENERAL_MANAGER','General Manager', 'Runs the property end to end.', true),
  (NULL,'HOTEL_MANAGER',  'Hotel Manager',   'Day-to-day operations, limited financial access.', true),
  (NULL,'FRONT_DESK',     'Front Desk',      'Reservations, check-in/out, folios and collections.', true),
  (NULL,'ACCOUNTANT',     'Accountant',      'Accounting, GST, invoicing and financial reports.', true),
  (NULL,'STORE_MANAGER',  'Store Manager',   'Inventory, purchasing and suppliers.', true),
  (NULL,'HOUSEKEEPING',   'Housekeeping',    'Room status, cleaning tasks and inspections.', true),
  (NULL,'MAINTENANCE',    'Maintenance',     'Maintenance tickets and asset upkeep.', true),
  (NULL,'SALES_CRM',      'Sales / CRM',     'Leads, corporate accounts and travel agents.', true),
  (NULL,'AUDITOR',        'Auditor',         'Read-only access to records, reports and audit logs.', true)
ON CONFLICT (organization_id, code) DO UPDATE
  SET name = EXCLUDED.name, description = EXCLUDED.description;

-- Rebuild system-role permissions so this file stays the single source
-- of truth for what each built-in role can do.
DELETE FROM role_permissions rp USING roles r WHERE rp.role_id = r.id AND r.is_system;

INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r CROSS JOIN permissions p
 WHERE r.is_system AND r.code IN ('SUPER_ADMIN','OWNER');

INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r CROSS JOIN permissions p
 WHERE r.is_system AND r.code = 'GENERAL_MANAGER'
   AND p.code NOT IN ('organization.manage','property.manage','roles.manage',
                      'accounting.close_period','accounting.manage_coa','api_keys.manage');

-- Full operations; reads financials but cannot post to the ledger,
-- change tax config, or refund.
INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r CROSS JOIN permissions p
 WHERE r.is_system AND r.code = 'HOTEL_MANAGER'
   AND (p.module IN ('DASHBOARD','PMS','RATES','RESERVATIONS','FRONT_OFFICE','GUESTS',
                     'BILLING','HOUSEKEEPING','MAINTENANCE','CRM','B2B','INVENTORY',
                     'PURCHASING','CHANNELS','NOTIFICATIONS','REPORTS')
        OR p.code IN ('payments.read','payments.collect','tax.read','settings.read','audit.read'))
   AND p.code NOT IN ('invoices.cancel','folio.void','accounting.post','tax.manage',
                      'channels.manage','booking_engine.manage','purchasing.approve');

-- Exactly the front-office job. Deliberately excludes accounting, tax,
-- settings, refunds, voids and financial reports.
INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r, permissions p
 WHERE r.is_system AND r.code = 'FRONT_DESK'
   AND p.code IN (
     'dashboard.read','rooms.read','rates.read','availability.read',
     'reservations.read','reservations.create','reservations.update','reservations.cancel',
     'reservations.checkin','reservations.checkout','reservations.assign_room',
     'guests.read','guests.manage','guest_documents.read','guest_documents.write',
     'folio.read','folio.post_charge','folio.transfer',
     'invoices.read','invoices.create','payments.read','payments.collect',
     'housekeeping.read','housekeeping.update','maintenance.create',
     'reports.operational','notifications.read');

INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r CROSS JOIN permissions p
 WHERE r.is_system AND r.code = 'ACCOUNTANT'
   AND (p.module IN ('ACCOUNTING','TAX','BILLING','PAYMENTS','REPORTS')
        OR p.code IN ('dashboard.read','dashboard.financial','reservations.read','guests.read',
                      'folio.read','inventory.read','purchasing.read','suppliers.read',
                      'suppliers.manage','corporate.read','travel_agents.read',
                      'audit.read','settings.read','data_import.execute'));

INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r CROSS JOIN permissions p
 WHERE r.is_system AND r.code = 'STORE_MANAGER'
   AND (p.module IN ('INVENTORY','PURCHASING')
        OR p.code IN ('dashboard.read','reports.operational','reports.export','notifications.read'))
   AND p.code <> 'purchasing.approve';

INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r, permissions p
 WHERE r.is_system AND r.code = 'HOUSEKEEPING'
   AND p.code IN ('dashboard.read','rooms.read','housekeeping.read','housekeeping.assign',
                  'housekeeping.update','housekeeping.inspect','maintenance.create',
                  'maintenance.read','reservations.read','inventory.read','notifications.read');

INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r, permissions p
 WHERE r.is_system AND r.code = 'MAINTENANCE'
   AND p.code IN ('dashboard.read','rooms.read','maintenance.read','maintenance.create',
                  'maintenance.assign','maintenance.close','housekeeping.read',
                  'inventory.read','notifications.read');

INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r CROSS JOIN permissions p
 WHERE r.is_system AND r.code = 'SALES_CRM'
   AND (p.module IN ('CRM','B2B')
        OR p.code IN ('dashboard.read','reservations.read','reservations.create',
                      'guests.read','guests.manage','rates.read','availability.read',
                      'reports.operational','reports.export','notifications.read'));

-- Read-only everywhere that matters, nothing that writes.
INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, p.code FROM roles r CROSS JOIN permissions p
 WHERE r.is_system AND r.code = 'AUDITOR'
   AND (p.action LIKE 'read%' OR p.code IN ('reports.operational','reports.financial',
                                            'reports.export','dashboard.read',
                                            'dashboard.financial','audit.read'));

-- ---------------------------------------------------------------------
-- Organization provisioning :: chart of accounts, booking sources, UoMs.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.provision_organization_defaults(p_org_id uuid)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE a record;
BEGIN
  FOR a IN
    SELECT * FROM (VALUES
      ('1000','Assets','ASSET',true,false,false),
      ('1100','Current Assets','ASSET',true,false,false),
      ('1110','Cash in Hand','ASSET',false,true,false),
      ('1120','Bank Account','ASSET',false,false,true),
      ('1130','Accounts Receivable - Guests','ASSET',false,false,false),
      ('1140','Accounts Receivable - Corporate','ASSET',false,false,false),
      ('1145','Accounts Receivable - Travel Agents','ASSET',false,false,false),
      ('1150','Accounts Receivable - OTA','ASSET',false,false,false),
      ('1160','Inventory - Food & Beverage','ASSET',false,false,false),
      ('1161','Inventory - Housekeeping','ASSET',false,false,false),
      ('1162','Inventory - General Stores','ASSET',false,false,false),
      ('1170','Input CGST','ASSET',false,false,false),
      ('1171','Input SGST','ASSET',false,false,false),
      ('1172','Input IGST','ASSET',false,false,false),
      ('1180','Advances to Suppliers','ASSET',false,false,false),
      ('1185','Employee Advances','ASSET',false,false,false),
      ('1200','Fixed Assets','ASSET',true,false,false),
      ('1210','Land & Building','ASSET',false,false,false),
      ('1220','Furniture & Fixtures','ASSET',false,false,false),
      ('1230','Plant & Equipment','ASSET',false,false,false),
      ('1240','Accumulated Depreciation','ASSET',false,false,false),
      ('2000','Liabilities','LIABILITY',true,false,false),
      ('2110','Accounts Payable - Suppliers','LIABILITY',false,false,false),
      ('2120','Output CGST','LIABILITY',false,false,false),
      ('2121','Output SGST','LIABILITY',false,false,false),
      ('2122','Output IGST','LIABILITY',false,false,false),
      ('2130','Advance from Guests','LIABILITY',false,false,false),
      ('2140','Salaries Payable','LIABILITY',false,false,false),
      ('2150','TDS Payable','LIABILITY',false,false,false),
      ('2160','Other Payables','LIABILITY',false,false,false),
      ('2210','Loans','LIABILITY',false,false,false),
      ('3000','Equity','EQUITY',true,false,false),
      ('3100','Owner Capital','EQUITY',false,false,false),
      ('3200','Retained Earnings','EQUITY',false,false,false),
      ('3300','Drawings','EQUITY',false,false,false),
      ('4000','Revenue','REVENUE',true,false,false),
      ('4100','Room Revenue','REVENUE',false,false,false),
      ('4110','Food Revenue','REVENUE',false,false,false),
      ('4120','Beverage Revenue','REVENUE',false,false,false),
      ('4130','Laundry Revenue','REVENUE',false,false,false),
      ('4140','Transport Revenue','REVENUE',false,false,false),
      ('4150','Other Operating Revenue','REVENUE',false,false,false),
      ('4160','Cancellation & No-Show Revenue','REVENUE',false,false,false),
      ('4900','Discounts Allowed','REVENUE',false,false,false),
      ('5000','Expenses','EXPENSE',true,false,false),
      ('5100','Cost of Food & Beverage','EXPENSE',false,false,false),
      ('5200','Salaries & Wages','EXPENSE',false,false,false),
      ('5210','Staff Welfare','EXPENSE',false,false,false),
      ('5300','OTA Commission','EXPENSE',false,false,false),
      ('5310','Travel Agent Commission','EXPENSE',false,false,false),
      ('5320','Payment Gateway Charges','EXPENSE',false,false,false),
      ('5400','Electricity & Water','EXPENSE',false,false,false),
      ('5410','Fuel & Gas','EXPENSE',false,false,false),
      ('5420','Repairs & Maintenance','EXPENSE',false,false,false),
      ('5430','Housekeeping Supplies','EXPENSE',false,false,false),
      ('5440','Laundry Expenses','EXPENSE',false,false,false),
      ('5450','Rent','EXPENSE',false,false,false),
      ('5460','Insurance','EXPENSE',false,false,false),
      ('5470','Marketing & Advertising','EXPENSE',false,false,false),
      ('5480','Telephone & Internet','EXPENSE',false,false,false),
      ('5490','Professional Fees','EXPENSE',false,false,false),
      ('5500','Bank Charges','EXPENSE',false,false,false),
      ('5510','Depreciation','EXPENSE',false,false,false),
      ('5900','Miscellaneous Expenses','EXPENSE',false,false,false)
    ) AS t(code, name, atype, is_group, is_cash, is_bank)
  LOOP
    INSERT INTO accounts (organization_id, code, name, account_type, is_group, is_cash, is_bank, is_system)
    VALUES (p_org_id, a.code, a.name, a.atype::account_type, a.is_group, a.is_cash, a.is_bank, true)
    ON CONFLICT (organization_id, code) DO NOTHING;
  END LOOP;

  -- Commission defaults are placeholders; real figures come from each
  -- signed OTA contract.
  INSERT INTO booking_sources (organization_id, code, name, category, default_commission_pct) VALUES
    (p_org_id,'DIRECT_WEB','Direct Website','DIRECT_WEBSITE',0),
    (p_org_id,'WALK_IN','Walk-in','WALK_IN',0),
    (p_org_id,'PHONE','Phone','PHONE',0),
    (p_org_id,'EMAIL','Email','EMAIL',0),
    (p_org_id,'WHATSAPP','WhatsApp','WHATSAPP',0),
    (p_org_id,'CORPORATE','Corporate','CORPORATE',0),
    (p_org_id,'TRAVEL_AGENT','Travel Agent','TRAVEL_AGENT',0),
    (p_org_id,'BOOKING_COM','Booking.com','OTA',15),
    (p_org_id,'AGODA','Agoda','OTA',15),
    (p_org_id,'EXPEDIA','Expedia','OTA',15),
    (p_org_id,'MAKEMYTRIP','MakeMyTrip','OTA',15),
    (p_org_id,'GOIBIBO','Goibibo','OTA',15),
    (p_org_id,'AIRBNB','Airbnb','OTA',3)
  ON CONFLICT (organization_id, code) DO NOTHING;

  INSERT INTO uoms (organization_id, code, name) VALUES
    (p_org_id,'PCS','Pieces'), (p_org_id,'KG','Kilogram'), (p_org_id,'GM','Gram'),
    (p_org_id,'LTR','Litre'), (p_org_id,'ML','Millilitre'), (p_org_id,'BOX','Box'),
    (p_org_id,'PKT','Packet'), (p_org_id,'BTL','Bottle'), (p_org_id,'SET','Set'),
    (p_org_id,'ROLL','Roll')
  ON CONFLICT (organization_id, code) DO NOTHING;
END;
$$;

-- ---------------------------------------------------------------------
-- Property provisioning :: tax config, charge codes, payment methods,
-- document series.
--
-- GST NOTE (India): for accommodation the place of supply is the
-- location of the hotel, so room revenue is ALWAYS intra-state --
-- CGST + SGST -- even for a guest from another state. IGST rows exist
-- for goods and for services where place-of-supply rules differ.
-- The rates below are seeded defaults, editable in Settings; verify
-- them against the current notification before going live.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.provision_property_defaults(p_property_id uuid)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_org uuid; v_room_tax uuid; v_food_tax uuid; v_svc_tax uuid; v_exempt_tax uuid;
  v_fy text; d record;
BEGIN
  SELECT organization_id INTO v_org FROM properties WHERE id = p_property_id;
  IF v_org IS NULL THEN RAISE EXCEPTION 'Property % not found', p_property_id; END IF;

  INSERT INTO tax_groups (property_id, code, name, hsn_sac_code, applies_to, is_slab_based) VALUES
    (p_property_id,'GST_ROOM','GST - Accommodation','996311','ROOM',true),
    (p_property_id,'GST_FOOD','GST - Restaurant','996331','FOOD',false),
    (p_property_id,'GST_SERVICE','GST - Services','999799','SERVICE',false),
    (p_property_id,'GST_EXEMPT','GST Exempt / Nil',NULL,'OTHER',false)
  ON CONFLICT (property_id, code) DO NOTHING;

  SELECT id INTO v_room_tax   FROM tax_groups WHERE property_id = p_property_id AND code = 'GST_ROOM';
  SELECT id INTO v_food_tax   FROM tax_groups WHERE property_id = p_property_id AND code = 'GST_FOOD';
  SELECT id INTO v_svc_tax    FROM tax_groups WHERE property_id = p_property_id AND code = 'GST_SERVICE';
  SELECT id INTO v_exempt_tax FROM tax_groups WHERE property_id = p_property_id AND code = 'GST_EXEMPT';

  -- Accommodation slabs: 12% up to Rs 7,500 per night, 18% above.
  IF NOT EXISTS (SELECT 1 FROM tax_rates WHERE tax_group_id = v_room_tax) THEN
    INSERT INTO tax_rates (tax_group_id, tax_type, rate_percent, min_amount, max_amount, effective_from) VALUES
      (v_room_tax,'CGST',6.0,   0, 7500, DATE '2020-04-01'),
      (v_room_tax,'SGST',6.0,   0, 7500, DATE '2020-04-01'),
      (v_room_tax,'CGST',9.0,7500, NULL, DATE '2020-04-01'),
      (v_room_tax,'SGST',9.0,7500, NULL, DATE '2020-04-01');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM tax_rates WHERE tax_group_id = v_food_tax) THEN
    INSERT INTO tax_rates (tax_group_id, tax_type, rate_percent, effective_from) VALUES
      (v_food_tax,'CGST',2.5, DATE '2020-04-01'), (v_food_tax,'SGST',2.5, DATE '2020-04-01');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM tax_rates WHERE tax_group_id = v_svc_tax) THEN
    INSERT INTO tax_rates (tax_group_id, tax_type, rate_percent, effective_from) VALUES
      (v_svc_tax,'CGST',9.0, DATE '2020-04-01'), (v_svc_tax,'SGST',9.0, DATE '2020-04-01');
  END IF;

  INSERT INTO charge_codes (property_id, code, name, category, tax_group_id, revenue_account_id, is_negative, is_system)
  SELECT p_property_id, c.code, c.name, c.category,
         CASE c.tax WHEN 'ROOM' THEN v_room_tax WHEN 'FOOD' THEN v_food_tax
                    WHEN 'SVC' THEN v_svc_tax ELSE v_exempt_tax END,
         (SELECT id FROM accounts WHERE organization_id = v_org AND code = c.acct),
         c.neg, true
    FROM (VALUES
      ('ROOM','Room Charge','ROOM','ROOM','4100',false),
      ('EXTRABED','Extra Bed','EXTRA_BED','ROOM','4100',false),
      ('EARLYCI','Early Check-in','EARLY_CHECKIN','ROOM','4100',false),
      ('LATECO','Late Check-out','LATE_CHECKOUT','ROOM','4100',false),
      ('FOOD','Food','FOOD','FOOD','4110',false),
      ('BEVERAGE','Beverage','BEVERAGE','FOOD','4120',false),
      ('MINIBAR','Minibar','MINIBAR','FOOD','4120',false),
      ('LAUNDRY','Laundry','LAUNDRY','SVC','4130',false),
      ('TRANSPORT','Transport','TRANSPORT','SVC','4140',false),
      ('MISC','Miscellaneous','MISC','SVC','4150',false),
      ('DAMAGE','Damage Recovery','DAMAGE','SVC','4150',false),
      ('CANCELFEE','Cancellation Fee','CANCELLATION_FEE','SVC','4160',false),
      ('NOSHOWFEE','No-Show Charge','NO_SHOW_FEE','SVC','4160',false),
      ('DISCOUNT','Discount','DISCOUNT','NIL','4900',true),
      ('ADJUST','Adjustment','ADJUSTMENT','NIL','4900',true)
    ) AS c(code, name, category, tax, acct, neg)
  ON CONFLICT (property_id, code) DO NOTHING;

  INSERT INTO payment_methods (property_id, code, name, method_type, account_id, requires_reference, sort_order)
  SELECT p_property_id, m.code, m.name, m.mtype,
         (SELECT id FROM accounts WHERE organization_id = v_org AND code = m.acct),
         m.needs_ref, m.ord
    FROM (VALUES
      ('CASH','Cash','CASH','1110',false,1),
      ('CARD','Credit/Debit Card','CARD','1120',true,2),
      ('UPI','UPI','UPI','1120',true,3),
      ('BANK','Bank Transfer','BANK_TRANSFER','1120',true,4),
      ('GATEWAY','Online Payment','GATEWAY','1120',true,5),
      ('CHEQUE','Cheque','CHEQUE','1120',true,6),
      ('CITYLED','City Ledger (Credit)','CITY_LEDGER','1140',false,7),
      ('OTACOL','Collected by OTA','OTA_COLLECT','1150',false,8),
      ('COMP','Complimentary','COMPLIMENTARY','4900',false,9)
    ) AS m(code, name, mtype, acct, needs_ref, ord)
  ON CONFLICT (property_id, code) DO NOTHING;

  -- Document series for the current Indian financial year (Apr -> Mar).
  v_fy := CASE WHEN EXTRACT(MONTH FROM CURRENT_DATE) >= 4
               THEN EXTRACT(YEAR FROM CURRENT_DATE)::int || '-' ||
                    right((EXTRACT(YEAR FROM CURRENT_DATE)::int + 1)::text, 2)
               ELSE (EXTRACT(YEAR FROM CURRENT_DATE)::int - 1) || '-' ||
                    right(EXTRACT(YEAR FROM CURRENT_DATE)::text, 2) END;

  FOR d IN
    SELECT * FROM (VALUES
      ('RESERVATION','RES-'),('FOLIO','FOL-'),('INVOICE','INV-'),
      ('CREDIT_NOTE','CRN-'),('DEBIT_NOTE','DBN-'),('PROFORMA','PRO-'),
      ('RECEIPT','RCP-'),('REFUND','REF-'),('JOURNAL','JV-'),
      ('PURCHASE_REQUEST','PR-'),('PURCHASE_ORDER','PO-'),
      ('GOODS_RECEIPT','GRN-'),('PURCHASE_INVOICE','PINV-'),
      ('MAINTENANCE_TICKET','MNT-'),('LEAD','LEAD-'),('GUEST','GST-')
    ) AS t(dtype, prefix)
  LOOP
    INSERT INTO document_series (property_id, doc_type, prefix, fiscal_year, next_number, padding)
    VALUES (p_property_id, d.dtype::document_type, d.prefix || v_fy || '/', v_fy, 1, 5)
    ON CONFLICT (property_id, doc_type, fiscal_year) DO NOTHING;
  END LOOP;
END;
$$;
