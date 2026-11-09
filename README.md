# Hotel Amoha — Hotel ERP

A production-grade, multi-property-capable Hotel ERP: PMS, booking engine,
channel manager, folio and billing, double-entry accounting with Indian GST,
inventory and purchasing, housekeeping, maintenance, CRM and reporting.

> **Status: Phase 0 complete, Phase 1 running.**
> The schema, integrity guarantees, security model and test suite are built
> and verified. The web application runs locally: authentication, RBAC, the
> owner dashboard, reservations, rooms, guests and settings, all reading live
> data from the database.

---

## What exists today

| | |
|---|---|
| Migrations | 12, forward-only, applied cleanly from an empty database |
| Tables / views / enums | 94 / 3 / 34 |
| Constraints | 291 foreign keys, 173 checks, 120 unique, **4 exclusion** |
| Indexes | 276 |
| Security | RLS on 92 tables, 101 policies, 85 permissions, 11 built-in roles |
| Automation | 78 triggers, 38 functions |
| Tests | **97 passing** — 50 integrity, 39 security, 8 concurrency |

Everything above has been executed against a real PostgreSQL 16 instance.
Nothing here is a diagram of an intention.

---

## The guarantees, and how they are proven

These are enforced by the database, so an application bug cannot bypass them.

| Guarantee | Mechanism | Proof |
|---|---|---|
| A room is never double-booked | `EXCLUDE USING gist` on `room_allocations` | Two concurrent sessions: one wins, one is rejected |
| A room type is never oversold | Capacity CHECK + locked `SELECT … FOR UPDATE` | Simultaneous OTA + web booking for the last room: sold count ends at 2 of 2 |
| Checkout day is free for the next arrival | `daterange` `'[)'` semantics | 10→14 and 14→16 coexist; 12→16 rejected |
| The same OTA webhook never books twice | 4 layers of unique constraints | Replay asserted to be a no-op |
| A payment is never captured on the browser's word | `pg_txn_captured_chk` | Unverified capture rejected |
| The same gateway payment is never banked twice | `pg_txn_payment_uq` | Duplicate rejected |
| The ledger always balances | Deferred constraint trigger | Unbalanced entry rejected; trial balance nets to zero |
| Posted accounting is immutable | BEFORE triggers | Edit and delete both rejected |
| Nothing posts into a closed period | BEFORE trigger | Rejected |
| GST arithmetic is always valid | 5 invoice CHECKs | Unequal CGST/SGST, mixed IGST, bad totals all rejected |
| Tenants cannot see each other's data | RLS on 92 tables | Cross-tenant reads return 0 rows; cross-tenant write refused |
| Audit logs cannot be altered | Revoked grants + trigger | Update and delete both rejected |
| A mock OTA cannot pose as a live one | `channels_mock_chk` | Mislabelled channel rejected |

Run them yourself:

```bash
./scripts/dev-db.sh start     # local PostgreSQL 16
./scripts/db-test.sh          # migrate, seed fixtures, run all three suites
```

```
Integrity: 50 passed, 0 failed
Security: 39 passed, 0 failed
Concurrency: 8 passed, 0 failed
ALL SUITES PASSED
```

---

## Running it locally

You need **Node 20+** and **PostgreSQL 16**.

```bash
npm install

# 1. Start a local database
./scripts/dev-db.sh start
export PGHOST=/var/lib/postgresql/hotel-erp PGPORT=5433 PGUSER=postgres PGDATABASE=erp
./scripts/dev-db.sh reset

# 2. Apply migrations and load demo data
./scripts/db-migrate.sh
psql -f db/seed/demo_hotel_amoha.sql      # property, rooms, rates, bookings
psql -f db/seed/demo_transactions.sql     # payments + posted journal entries
node scripts/seed-users.mjs               # demo staff accounts

# 3. Run the app
npm run dev                               # http://localhost:3000
```

Already have a database? Set `DATABASE_URL` instead of the `PG*` variables and
every script uses it.

### Demo accounts

All use the password `Amoha@2026` (override with `DEMO_PASSWORD`).

| Email | Role | What they can see |
|---|---|---|
| `owner@hotelamoha.test` | Owner | Everything, including all financials |
| `gm@hotelamoha.test` | General Manager | Operations + financials, no org admin |
| `frontdesk@hotelamoha.test` | Front Desk | Reservations, rooms, guests — **no** accounting, settings or financial reports |
| `accounts@hotelamoha.test` | Accountant | Ledger, GST, billing |
| `housekeeping@hotelamoha.test` | Housekeeping | Room status only |

Signing in as different roles is the quickest way to see RBAC working: the
sidebar, the dashboard tiles and the pages themselves all change.

### What the app does today

| Screen | Status |
|---|---|
| Login | Real auth: scrypt passwords, server-side sessions, httpOnly cookies, lockout after 5 failures |
| Dashboard | Live KPIs — occupancy, ADR, RevPAR, arrivals/departures, cash & bank **from the ledger**, revenue by booking source |
| Reservations | Live list with search, status filter and pagination; responsive table → cards |
| Reservation detail | Stay lines, per-night rate breakdown, status history, charges |
| Rooms | Status board grouped by floor, occupancy read from the room-night ledger |
| Guests | Profiles with stay counts and revenue aggregated from real bookings |
| Settings | Property details, built-in roles, users and their permission counts |
| Front desk, housekeeping, rates, billing, accounting, channels, reports | Routed placeholders — scheduled in the roadmap |

---

## Documentation

| | |
|---|---|
| [01 — System Architecture](docs/00-architecture.md) | Principles, stack, module dependency map, transactions, error handling |
| [02 — Database Design](docs/01-database.md) | The three key design decisions, ERDs, table catalogue, constraints |
| [03 — Auth & RBAC](docs/02-auth-and-rbac.md) | Sessions, 85 permissions, 11 roles, RLS, secrets, audit |
| [04 — Reservation Lifecycle](docs/03-reservation-lifecycle.md) | States, room inventory, double-booking defence, modifications, night audit |
| [05 — Booking Engine](docs/04-booking-engine.md) | Public flow, holds, conversion design, website embedding |
| [06 — Channel Manager / OTA](docs/05-channel-manager.md) | Adapter interface, outbox sync, four-layer idempotency, commission |
| [07 — Payments](docs/06-payments.md) | Gateway abstraction, verification, refunds, ledger posting |
| [08 — Accounting & GST](docs/07-accounting-and-gst.md) | Double entry, the four rules, standard postings, GST configuration |
| [09 — API Structure](docs/08-api-structure.md) | Conventions, error envelope, endpoint list, rate limits |
| [10 — Integrations & Recovery](docs/09-integrations-and-notifications.md) | Adapters, notifications, imports, backup and recovery |
| [11 — Roadmap](docs/10-roadmap.md) | Phases 0–15, definition of done, production checklist |

---

## Repository layout

```
db/migrations/   12 numbered, forward-only SQL migrations
db/seed/         demo data for Hotel Amoha (mock integrations only)
db/tests/        fixtures + the SQL integrity suite
scripts/         dev-db, db-migrate, db-test (+ security, concurrency), seed-users
docs/            the documentation set above
src/             the Next.js application
```

---

## Honest scope

**No OTA is connected and no OTA API is simulated as if it were real.**
Channels are an adapter interface with a mock implementation. Real adapters
will be written only when Hotel Amoha holds approved API credentials. The
database refuses to let a mock channel be labelled as a live one
(`channels_mock_chk`), and the UI marks sandbox channels explicitly.

**No payment gateway is connected.** Same approach: an interface plus a mock.

**The GST rates seeded are defaults, not legal advice.** They are
configuration rows with effective-date windows, editable in Settings, and must
be verified against the current notification before go-live. One India-specific
rule is worth flagging: for accommodation the place of supply is the hotel's
location, so room revenue is always CGST + SGST, never IGST — even for an
out-of-state guest.

**The UI covers Phase 1, not the whole ERP.** Login, dashboard, reservations,
rooms, guests and settings are real and read live data. Front desk actions
(check-in/out), billing, accounting screens, housekeeping and the channel
manager are routed but not yet built. No screen fakes data: where a module has
no UI, it says so rather than showing a mockup.

---

## Next step

Phase 2–4 — room and rate management screens, the reservation calendar, and
front-desk check-in/check-out with folio posting. See the
[roadmap](docs/10-roadmap.md).
