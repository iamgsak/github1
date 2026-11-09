# 03 — Authentication & Authorization

---

## 1. Authentication

Two adapters, selected at runtime by `AUTH_PROVIDER`:

- **`supabase`** (production) — Supabase Auth issues JWTs. `public.users`
  mirrors `auth.users` by primary key.
- **`local`** (development, CI, self-hosting) — `user_credentials` and
  `user_sessions` from migration `0012`. No external dependency, which is what
  lets the whole stack run on a plain PostgreSQL cluster.

The `auth.users` foreign key is created only when that schema exists, so one
set of migrations serves both.

**Server-side sessions, not stateless JWTs.** Deactivating a user or revoking
a session takes effect on the *very next request* — `getSessionUser()` joins
`user_sessions` to `users` and requires `u.is_active`. A stateless token could
not do that without a revocation list.

Session rules:

- Token stored in an `httpOnly; Secure; SameSite=Lax` cookie — never
  `localStorage`, so XSS cannot exfiltrate a session.
- Only the SHA-256 **hash** of the token is stored; a database leak yields no
  live sessions.
- Passwords hashed with **scrypt** (Node standard library, memory-hard, no
  native dependency), compared in constant time.
- Account locks for 15 minutes after 5 failed attempts.
- Unknown email and wrong password return **byte-identical** responses, so the
  login cannot be used to discover which addresses exist. Verified by test.
- Both successes and failures write to `audit_logs`.

**Request context.** Each transaction sets `app.current_user_id`,
`app.current_user_email`, `app.current_ip` and `app.request_id` via
`SET LOCAL`. The audit trigger and RLS helpers read these, which is how a
database-level audit row knows who performed the change. `SET LOCAL` scopes it
to the transaction so it cannot leak to the next borrower of a pooled
connection.

---

## 2. Authorization model

Three concepts, deliberately separate:

```
Permission   an atomic capability, e.g. payments.refund
Role         a named bundle of permissions
Grant        (user, role, property?)  -- property NULL = all properties
```

**85 permissions** across 20 modules, coded `<module>.<action>`. Financially
or legally sensitive ones carry `is_sensitive = true`.

### Built-in roles

| Role | Scope |
|---|---|
| `SUPER_ADMIN` | Platform operator. Everything. |
| `OWNER` | Full business visibility including all financials. |
| `GENERAL_MANAGER` | Everything except platform/org admin and period close. |
| `HOTEL_MANAGER` | Full operations; reads financials, cannot post or refund. |
| `FRONT_DESK` | Reservations, check-in/out, folios, collections. |
| `ACCOUNTANT` | Ledger, GST, invoicing, financial reports. |
| `STORE_MANAGER` | Inventory and purchasing (cannot self-approve). |
| `HOUSEKEEPING` | Room status, cleaning tasks, inspections. |
| `MAINTENANCE` | Tickets and assets. |
| `SALES_CRM` | Leads, corporate accounts, travel agents. |
| `AUDITOR` | Read-only everywhere, including audit logs. |

The front-desk boundary, implemented exactly and asserted by tests:

| Front desk **can** | Front desk **cannot** |
|---|---|
| View / create / modify reservations | Delete or adjust accounting entries |
| Check in, check out | Change GST configuration |
| Assign and change rooms | Change system settings |
| Collect payments and deposits | Issue refunds |
| Create and print invoices | Cancel an issued invoice |
| Post charges, transfer charges | Void a posted charge |
| Upload guest ID documents | Read financial reports or audit logs |

Separation of duties is built in rather than assumed: `STORE_MANAGER` may
raise purchase orders but not approve them; `FRONT_DESK` may take money but
not give it back; `ACCOUNTANT` may post the ledger but not sell rooms.

---

## 3. Enforcement — three layers

**1. UI** hides what the user cannot do. Convenience only, never a control.

**2. API** — every handler declares its requirement:

```ts
export const POST = withAuth(
  { permission: 'payments.refund' },
  async (req, ctx) => { /* ctx.user, ctx.propertyId are proven */ }
);
```

`withAuth` also refuses an `X-Property-Id` header naming a property the user
lacks, so the scope header cannot be used to reach another tenant.

**3. Database** — RLS. **92 tables carry RLS, with 101 policies.** Four helper
functions (all `STABLE SECURITY DEFINER`) back them:

| Function | Answers |
|---|---|
| `app.auth_user_id()` | Who is calling? (`auth.uid()`, falling back to the GUC) |
| `app.current_org_id()` | Which tenant? |
| `app.user_property_ids()` | Which properties may they see? |
| `app.has_permission(code, property)` | May they do this, here? |

Policies fall into four shapes:

- **Property-scoped** (47 tables): visible when `property_id` is in the user's
  property list.
- **Organization-scoped** (14 tables): visible within the user's tenant.
- **Child tables** (19 tables): no tenant column of their own; the policy is
  `EXISTS (SELECT 1 FROM parent WHERE parent.id = child.fk)`. Because the
  parent is itself under RLS, the subquery is filtered automatically — a child
  row is reachable exactly when its parent is.
- **Sensitive**: an explicit permission on top of tenant scope
  (`guest_documents`, `employees`, `audit_logs`), or no user access at all
  (`integration_credentials`, `webhook_events`, `idempotency_keys`,
  `user_credentials`, `user_sessions` are `service_role` only).

`FORCE ROW LEVEL SECURITY` is set on every one, so even a table owner is
subject to its policies.

### Verified behaviour

The security suite runs as the real `authenticated` and `anon` roles, not as a
superuser (which would bypass RLS). All 39 checks pass:

- A user of another tenant sees **zero** rows of Hotel Amoha's reservations,
  guests, rooms, invoices, ledger and invoice line items.
- A cross-tenant INSERT is refused by RLS.
- Front desk cannot read `audit_logs`; the owner reads them.
- `integration_credentials` and `webhook_events` are `permission denied` even
  for the owner — those are worker-only tables.
- `anon` is denied on reservations, guests, invoices and the ledger, and can
  reach availability only through one narrow RPC.

---

## 4. The public booking engine

The anonymous role has **no table access whatsoever**. Public reads go through
a single `SECURITY DEFINER` function, `app.public_search_availability()`,
which returns only what a shopper needs: room type, description, occupancy,
available count, rate plan and total price. It respects stop-sell,
closed-to-arrival and minimum-stay, and refuses to sell a night with no
published price.

That is the entire public surface of the database. Guest data, financials and
operational state are unreachable from an unauthenticated session by
construction, not by remembering to filter.

---

## 5. Secrets

- No secret is ever committed. `.env.example` documents names only.
- `SUPABASE_SERVICE_ROLE_KEY` is server-only; anything prefixed
  `NEXT_PUBLIC_` is assumed public and must never hold a credential.
- OTA and gateway credentials live in `integration_credentials` as
  application-encrypted ciphertext (AES-GCM, key from KMS/env). The database
  stores bytes it cannot read; `key_id` records which key version was used so
  keys can be rotated. A non-secret `value_hint` (≤ 8 chars) lets the UI show
  `…a3f2` without decryption.
- Adapters redact credentials before writing payloads to `sync_logs`.

---

## 6. Audit

The generic trigger `app.audit_trigger('<module>')` is attached to 18
security-, money- and legally-sensitive tables. It records user, email, IP,
request id, action, module, table, record, old values, new values and
**exactly which fields changed**. An update touching only `updated_at` is
skipped, keeping the log readable.

`audit_logs` is append-only: no role holds INSERT (rows arrive only via the
`SECURITY DEFINER` trigger), UPDATE/DELETE are revoked from every role, and a
trigger raises on either. Both are asserted by tests.
