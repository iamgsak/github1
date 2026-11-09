-- =====================================================================
-- 0007_operations_crm_hr.sql
-- Housekeeping, maintenance, employees/HR, CRM leads, and the B2B
-- accounts (corporate + travel agent) that reservations refer to.
-- =====================================================================

CREATE TYPE housekeeping_task_status AS ENUM (
  'PENDING','ASSIGNED','IN_PROGRESS','COMPLETED','INSPECTED','REJECTED','CANCELLED'
);
CREATE TYPE maintenance_status AS ENUM (
  'OPEN','ASSIGNED','IN_PROGRESS','WAITING_PARTS','COMPLETED','CLOSED','CANCELLED'
);
CREATE TYPE priority_level AS ENUM ('LOW','MEDIUM','HIGH','URGENT');
CREATE TYPE lead_status AS ENUM (
  'NEW','CONTACTED','FOLLOW_UP','QUOTATION','NEGOTIATION','CONFIRMED','LOST'
);

CREATE TABLE departments (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id uuid NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
  code        text NOT NULL,
  name        text NOT NULL,
  is_active   boolean NOT NULL DEFAULT true,
  CONSTRAINT departments_uq UNIQUE (property_id, code)
);

-- Salary and bank details are restricted to HR roles by RLS in 0010.
CREATE TABLE employees (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  property_id       uuid REFERENCES properties(id) ON DELETE SET NULL,
  employee_code     text NOT NULL,
  user_id           uuid REFERENCES users(id) ON DELETE SET NULL,
  first_name        text NOT NULL,
  last_name         text,
  full_name         text GENERATED ALWAYS AS (
                      btrim(first_name || ' ' || COALESCE(last_name,''))) STORED,
  phone             text,
  email             citext,
  department_id     uuid REFERENCES departments(id) ON DELETE SET NULL,
  designation       text,
  employment_type   text NOT NULL DEFAULT 'FULL_TIME',
  date_of_joining   date NOT NULL,
  date_of_leaving   date,
  salary_amount     numeric(14,2),
  bank_details      jsonb,
  emergency_contact jsonb,
  address           text,
  date_of_birth     date,
  is_active         boolean NOT NULL DEFAULT true,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT employees_code_uq UNIQUE (organization_id, employee_code),
  CONSTRAINT employees_user_uq UNIQUE (user_id),
  CONSTRAINT employees_type_chk CHECK (employment_type IN
    ('FULL_TIME','PART_TIME','CONTRACT','TRAINEE','CONSULTANT')),
  CONSTRAINT employees_leaving_chk CHECK (date_of_leaving IS NULL OR date_of_leaving >= date_of_joining),
  CONSTRAINT employees_salary_chk CHECK (salary_amount IS NULL OR salary_amount >= 0)
);
CREATE INDEX employees_property_idx   ON employees(property_id) WHERE is_active;
CREATE INDEX employees_department_idx ON employees(department_id);

CREATE TABLE attendance (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id     uuid NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  property_id     uuid NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
  attendance_date date NOT NULL,
  status          text NOT NULL DEFAULT 'PRESENT',
  check_in_time   timestamptz,
  check_out_time  timestamptz,
  hours_worked    numeric(5,2),
  shift           text,
  notes           text,
  marked_by       uuid REFERENCES users(id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT attendance_uq UNIQUE (employee_id, attendance_date),
  CONSTRAINT attendance_status_chk CHECK (status IN
    ('PRESENT','ABSENT','HALF_DAY','LEAVE','HOLIDAY','WEEK_OFF','ON_DUTY')),
  CONSTRAINT attendance_times_chk CHECK (
    check_out_time IS NULL OR check_in_time IS NULL OR check_out_time > check_in_time)
);
CREATE INDEX attendance_date_idx ON attendance(property_id, attendance_date);

CREATE TABLE leave_requests (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id uuid NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  property_id uuid NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
  leave_type  text NOT NULL,
  from_date   date NOT NULL,
  to_date     date NOT NULL,
  days        numeric(4,1) NOT NULL,
  reason      text,
  status      text NOT NULL DEFAULT 'PENDING',
  approved_by uuid REFERENCES users(id),
  approved_at timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT leave_requests_dates_chk CHECK (to_date >= from_date),
  CONSTRAINT leave_requests_days_chk CHECK (days > 0),
  CONSTRAINT leave_requests_status_chk CHECK (status IN ('PENDING','APPROVED','REJECTED','CANCELLED'))
);

CREATE TABLE employee_advances (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id      uuid NOT NULL REFERENCES employees(id) ON DELETE RESTRICT,
  property_id      uuid NOT NULL REFERENCES properties(id) ON DELETE RESTRICT,
  advance_date     date NOT NULL DEFAULT CURRENT_DATE,
  amount           numeric(14,2) NOT NULL,
  recovered_amount numeric(14,2) NOT NULL DEFAULT 0,
  balance_amount   numeric(14,2) GENERATED ALWAYS AS (amount - recovered_amount) STORED,
  reason           text,
  journal_entry_id uuid REFERENCES journal_entries(id) ON DELETE SET NULL,
  approved_by      uuid REFERENCES users(id),
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT employee_advances_amount_chk CHECK (
    amount > 0 AND recovered_amount >= 0 AND recovered_amount <= amount)
);

CREATE TABLE housekeeping_tasks (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id         uuid NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
  room_id             uuid NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
  reservation_room_id uuid REFERENCES reservation_rooms(id) ON DELETE SET NULL,
  task_type           text NOT NULL DEFAULT 'DAILY_CLEAN',
  status              housekeeping_task_status NOT NULL DEFAULT 'PENDING',
  priority            priority_level NOT NULL DEFAULT 'MEDIUM',
  scheduled_date      date NOT NULL DEFAULT CURRENT_DATE,
  assigned_to         uuid REFERENCES employees(id) ON DELETE SET NULL,
  assigned_at         timestamptz,
  started_at          timestamptz,
  completed_at        timestamptz,
  -- Room turnaround time, the core housekeeping KPI.
  duration_minutes    integer GENERATED ALWAYS AS (
    CASE WHEN started_at IS NOT NULL AND completed_at IS NOT NULL
         THEN GREATEST(0, (EXTRACT(EPOCH FROM (completed_at - started_at)) / 60)::integer)
    END) STORED,
  inspected_by        uuid REFERENCES employees(id) ON DELETE SET NULL,
  inspected_at        timestamptz,
  rejection_reason    text,
  notes               text,
  created_by          uuid REFERENCES users(id),
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT housekeeping_task_type_chk CHECK (task_type IN
    ('DAILY_CLEAN','CHECKOUT_CLEAN','DEEP_CLEAN','TURNDOWN','INSPECTION','LINEN_CHANGE')),
  CONSTRAINT housekeeping_assigned_chk CHECK (status <> 'ASSIGNED' OR assigned_to IS NOT NULL),
  CONSTRAINT housekeeping_completed_chk CHECK (
    status NOT IN ('COMPLETED','INSPECTED') OR completed_at IS NOT NULL),
  CONSTRAINT housekeeping_rejected_chk CHECK (status <> 'REJECTED' OR rejection_reason IS NOT NULL),
  CONSTRAINT housekeeping_times_chk CHECK (
    completed_at IS NULL OR started_at IS NULL OR completed_at >= started_at)
);
CREATE INDEX housekeeping_tasks_room_date_idx ON housekeeping_tasks(room_id, scheduled_date DESC);
CREATE INDEX housekeeping_tasks_assignee_idx  ON housekeeping_tasks(assigned_to, scheduled_date);
CREATE INDEX housekeeping_tasks_open_idx      ON housekeeping_tasks(property_id, scheduled_date)
  WHERE status IN ('PENDING','ASSIGNED','IN_PROGRESS');

CREATE TABLE assets (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id    uuid NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
  code           text NOT NULL,
  name           text NOT NULL,
  category       text,
  room_id        uuid REFERENCES rooms(id) ON DELETE SET NULL,
  location       text,
  purchase_date  date,
  purchase_cost  numeric(14,2),
  warranty_until date,
  is_active      boolean NOT NULL DEFAULT true,
  CONSTRAINT assets_uq UNIQUE (property_id, code)
);

CREATE TABLE maintenance_tickets (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id        uuid NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
  ticket_number      text NOT NULL,
  room_id            uuid REFERENCES rooms(id) ON DELETE SET NULL,
  asset_id           uuid REFERENCES assets(id) ON DELETE SET NULL,
  category           text,
  priority           priority_level NOT NULL DEFAULT 'MEDIUM',
  title              text NOT NULL,
  description        text,
  status             maintenance_status NOT NULL DEFAULT 'OPEN',
  reported_by        uuid REFERENCES users(id),
  assigned_to        uuid REFERENCES employees(id) ON DELETE SET NULL,
  vendor_id          uuid REFERENCES suppliers(id) ON DELETE SET NULL,
  estimated_cost     numeric(14,2),
  actual_cost        numeric(14,2),
  -- True while the room is blocked from sale; the block itself is a
  -- room_allocations row, so it collides with bookings.
  blocks_room        boolean NOT NULL DEFAULT false,
  room_allocation_id uuid REFERENCES room_allocations(id) ON DELETE SET NULL,
  scheduled_date     date,
  started_at         timestamptz,
  completed_at       timestamptz,
  closed_at          timestamptz,
  resolution_notes   text,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT maintenance_tickets_uq UNIQUE (property_id, ticket_number),
  CONSTRAINT maintenance_target_chk CHECK (room_id IS NOT NULL OR asset_id IS NOT NULL),
  CONSTRAINT maintenance_assigned_chk CHECK (
    status NOT IN ('ASSIGNED','IN_PROGRESS') OR assigned_to IS NOT NULL OR vendor_id IS NOT NULL),
  CONSTRAINT maintenance_completed_chk CHECK (status <> 'COMPLETED' OR completed_at IS NOT NULL),
  CONSTRAINT maintenance_closed_chk CHECK (status <> 'CLOSED' OR closed_at IS NOT NULL),
  CONSTRAINT maintenance_cost_chk CHECK (
    (estimated_cost IS NULL OR estimated_cost >= 0) AND (actual_cost IS NULL OR actual_cost >= 0))
);
CREATE INDEX maintenance_tickets_open_idx ON maintenance_tickets(property_id, status)
  WHERE status NOT IN ('CLOSED','CANCELLED');
CREATE INDEX maintenance_tickets_room_idx ON maintenance_tickets(room_id);

CREATE TABLE maintenance_attachments (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ticket_id       uuid NOT NULL REFERENCES maintenance_tickets(id) ON DELETE CASCADE,
  url             text NOT NULL,
  caption         text,
  attachment_type text NOT NULL DEFAULT 'PHOTO',
  uploaded_by     uuid REFERENCES users(id),
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE corporate_accounts (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id       uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  code                  text NOT NULL,
  company_name          text NOT NULL,
  contact_person        text,
  phone                 text,
  email                 citext,
  address_line1         text,
  city                  text,
  state                 text,
  state_code            char(2),
  postal_code           text,
  gstin                 text,
  pan                   text,
  credit_limit          numeric(14,2) NOT NULL DEFAULT 0,
  payment_terms_days    smallint NOT NULL DEFAULT 30,
  discount_percent      numeric(5,2) NOT NULL DEFAULT 0,
  receivable_account_id uuid REFERENCES accounts(id) ON DELETE RESTRICT,
  contract_start        date,
  contract_end          date,
  is_active             boolean NOT NULL DEFAULT true,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT corporate_accounts_uq UNIQUE (organization_id, code),
  CONSTRAINT corporate_accounts_credit_chk CHECK (credit_limit >= 0),
  CONSTRAINT corporate_accounts_discount_chk CHECK (discount_percent BETWEEN 0 AND 100),
  CONSTRAINT corporate_accounts_contract_chk CHECK (
    contract_end IS NULL OR contract_start IS NULL OR contract_end >= contract_start),
  CONSTRAINT corporate_accounts_gstin_chk CHECK (
    gstin IS NULL OR gstin ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z]{1}[1-9A-Z]{1}Z[0-9A-Z]{1}$')
);

CREATE TABLE corporate_rate_contracts (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  corporate_account_id uuid NOT NULL REFERENCES corporate_accounts(id) ON DELETE CASCADE,
  property_id          uuid NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
  room_type_id         uuid NOT NULL REFERENCES room_types(id) ON DELETE CASCADE,
  rate_plan_id         uuid REFERENCES rate_plans(id) ON DELETE SET NULL,
  contract_rate        numeric(12,2) NOT NULL,
  valid_from           date NOT NULL,
  valid_to             date NOT NULL,
  is_active            boolean NOT NULL DEFAULT true,
  CONSTRAINT corporate_rate_contracts_rate_chk CHECK (contract_rate >= 0),
  CONSTRAINT corporate_rate_contracts_dates_chk CHECK (valid_to >= valid_from),
  -- One active contracted rate per company/room type/date range.
  CONSTRAINT corporate_rate_contracts_no_overlap
    EXCLUDE USING gist (corporate_account_id WITH =, room_type_id WITH =,
                        daterange(valid_from, valid_to, '[]') WITH &&)
    WHERE (is_active)
);

CREATE TABLE travel_agents (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id       uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  code                  text NOT NULL,
  agency_name           text NOT NULL,
  contact_person        text,
  phone                 text,
  email                 citext,
  address_line1         text,
  city                  text,
  state                 text,
  state_code            char(2),
  gstin                 text,
  pan                   text,
  commission_percent    numeric(5,2) NOT NULL DEFAULT 0,
  credit_limit          numeric(14,2) NOT NULL DEFAULT 0,
  payment_terms_days    smallint NOT NULL DEFAULT 15,
  receivable_account_id uuid REFERENCES accounts(id) ON DELETE RESTRICT,
  iata_code             text,
  is_active             boolean NOT NULL DEFAULT true,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT travel_agents_uq UNIQUE (organization_id, code),
  CONSTRAINT travel_agents_commission_chk CHECK (commission_percent BETWEEN 0 AND 100),
  CONSTRAINT travel_agents_credit_chk CHECK (credit_limit >= 0)
);

-- Wire the deferred FKs declared in 0003/0004.
ALTER TABLE reservations
  ADD CONSTRAINT reservations_corporate_fk
    FOREIGN KEY (corporate_account_id) REFERENCES corporate_accounts(id) ON DELETE SET NULL,
  ADD CONSTRAINT reservations_travel_agent_fk
    FOREIGN KEY (travel_agent_id) REFERENCES travel_agents(id) ON DELETE SET NULL;
ALTER TABLE folios
  ADD CONSTRAINT folios_corporate_fk
    FOREIGN KEY (corporate_account_id) REFERENCES corporate_accounts(id) ON DELETE SET NULL;
ALTER TABLE invoices
  ADD CONSTRAINT invoices_corporate_fk
    FOREIGN KEY (corporate_account_id) REFERENCES corporate_accounts(id) ON DELETE SET NULL,
  ADD CONSTRAINT invoices_travel_agent_fk
    FOREIGN KEY (travel_agent_id) REFERENCES travel_agents(id) ON DELETE SET NULL;
ALTER TABLE payments
  ADD CONSTRAINT payments_corporate_fk
    FOREIGN KEY (corporate_account_id) REFERENCES corporate_accounts(id) ON DELETE SET NULL,
  ADD CONSTRAINT payments_travel_agent_fk
    FOREIGN KEY (travel_agent_id) REFERENCES travel_agents(id) ON DELETE SET NULL;

CREATE TABLE crm_leads (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id              uuid NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
  lead_number              text NOT NULL,
  source                   text NOT NULL,
  contact_name             text NOT NULL,
  company_name             text,
  phone                    text,
  email                    citext,
  guest_id                 uuid REFERENCES guests(id) ON DELETE SET NULL,
  corporate_account_id     uuid REFERENCES corporate_accounts(id) ON DELETE SET NULL,
  travel_agent_id          uuid REFERENCES travel_agents(id) ON DELETE SET NULL,
  requirement              text,
  arrival_date             date,
  departure_date           date,
  room_nights              integer,
  estimated_value          numeric(14,2),
  status                   lead_status NOT NULL DEFAULT 'NEW',
  assigned_to              uuid REFERENCES users(id) ON DELETE SET NULL,
  expected_close_date      date,
  next_follow_up_at        timestamptz,
  lost_reason              text,
  converted_reservation_id uuid REFERENCES reservations(id) ON DELETE SET NULL,
  converted_at             timestamptz,
  notes                    text,
  created_by               uuid REFERENCES users(id),
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT crm_leads_uq UNIQUE (property_id, lead_number),
  CONSTRAINT crm_leads_source_chk CHECK (source IN (
    'WEBSITE','GOOGLE','INSTAGRAM','FACEBOOK','WHATSAPP','PHONE',
    'EMAIL','WALK_IN','CORPORATE','TRAVEL_AGENT','REFERRAL','OTHER')),
  CONSTRAINT crm_leads_contact_chk CHECK (phone IS NOT NULL OR email IS NOT NULL),
  CONSTRAINT crm_leads_dates_chk CHECK (
    departure_date IS NULL OR arrival_date IS NULL OR departure_date > arrival_date),
  CONSTRAINT crm_leads_lost_chk CHECK (status <> 'LOST' OR lost_reason IS NOT NULL),
  CONSTRAINT crm_leads_confirmed_chk CHECK (
    status <> 'CONFIRMED' OR converted_reservation_id IS NOT NULL)
);
CREATE INDEX crm_leads_status_idx   ON crm_leads(property_id, status);
CREATE INDEX crm_leads_assignee_idx ON crm_leads(assigned_to, next_follow_up_at);
CREATE INDEX crm_leads_followup_idx ON crm_leads(property_id, next_follow_up_at)
  WHERE status NOT IN ('CONFIRMED','LOST');

CREATE TABLE crm_activities (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id           uuid NOT NULL REFERENCES crm_leads(id) ON DELETE CASCADE,
  activity_type     text NOT NULL,
  subject           text,
  notes             text,
  activity_at       timestamptz NOT NULL DEFAULT now(),
  next_follow_up_at timestamptz,
  outcome           text,
  created_by        uuid REFERENCES users(id),
  created_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT crm_activities_type_chk CHECK (activity_type IN
    ('CALL','EMAIL','MEETING','WHATSAPP','SMS','SITE_VISIT','QUOTATION','NOTE'))
);
CREATE INDEX crm_activities_lead_idx ON crm_activities(lead_id, activity_at DESC);

CREATE TRIGGER employees_updated_at           BEFORE UPDATE ON employees           FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();
CREATE TRIGGER housekeeping_tasks_updated_at  BEFORE UPDATE ON housekeeping_tasks  FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();
CREATE TRIGGER maintenance_tickets_updated_at BEFORE UPDATE ON maintenance_tickets FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();
CREATE TRIGGER corporate_accounts_updated_at  BEFORE UPDATE ON corporate_accounts  FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();
CREATE TRIGGER travel_agents_updated_at       BEFORE UPDATE ON travel_agents       FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();
CREATE TRIGGER crm_leads_updated_at           BEFORE UPDATE ON crm_leads           FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();
