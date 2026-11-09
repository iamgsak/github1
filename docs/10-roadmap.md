# 11 — Development Roadmap

Each phase follows the same discipline: explain what is being built, name the
tables and APIs, implement, **test**, verify permissions and responsiveness,
update documentation — then move on. A phase is not "done" because a screen
renders.

---

## Phase 0 — Architecture & database design ✅ COMPLETE

Delivered: this documentation set, 12 migrations (94 tables, 291 FKs, 173
checks, 4 exclusion constraints, 101 RLS policies, 78 triggers), the
permission catalogue and 11 built-in roles, tenant provisioning functions, and
97 automated tests covering integrity, security and concurrency.

## Phase 1 — Authentication, users, roles, property setup ✅ RUNNING

Delivered: Next.js 16 app with scrypt password hashing, server-side sessions
in `user_sessions`, httpOnly session cookies, account lockout after 5 failed
attempts, and login/logout audit rows.

Screens live: login, app shell with permission-driven sidebar, owner
dashboard (occupancy, ADR, RevPAR, arrivals/departures, ledger-derived cash
and bank, revenue by booking source), reservations list with search and
filters, reservation detail with per-night breakdown and status history, room
status board, guest list, settings.

Migration `0012_local_auth.sql` adds credentials and sessions for the local
auth adapter; Supabase Auth remains the production path, selected at runtime.

Verified: unauthenticated access redirects to login; unknown and wrong
passwords return identical messages (no user enumeration); front desk,
housekeeping and owner each see a different sidebar, different dashboard
tiles, and are refused pages they lack permission for.

Still to build in this area: forgot/reset password, user and role editors,
audit log viewer.

## Phase 2 — Rooms, room types, availability
Room type and room CRUD, room status board actions, availability calendar
with bulk edit.

## Phase 3 — Reservations, guests, calendar
Create/edit wizard, guest profile, drag-and-drop calendar.
**Tests: double-booking prevention under concurrency** (already in place at
the database level).

## Phase 4 — Front desk, check-in/out, folio
Arrivals/departures/in-house, check-in and check-out flows, folio view,
charge posting. Mobile-friendly by requirement.

## Phase 5 — Billing, payments, invoices
GST-compliant PDF invoices, email delivery, payment collection, the refund
approval flow.

## Phase 6 — Accounting, GST, financial reports
Automatic posting from every folio, invoice and payment; the full report set;
period close. **Exit criterion: the trial balance nets to zero and the P&L
reconciles to the folios.**

## Phase 7 — Booking engine
Public search, selection, checkout, mock gateway end to end, confirmation
email, embeddable widget, promo codes.

## Phase 8 — Channel manager / OTA
Mock adapter fully working; real adapters only where credentials exist.
**Tests: duplicate webhook, simultaneous OTA + web booking, mapping failures.**

## Phase 9 — Housekeeping & maintenance
Mobile-first task board, room status flow, turnaround time, tickets with
photos, room blocking that consumes inventory.

## Phase 10 — Inventory & purchasing
PR → PO → GRN → invoice → payment workflow, supplier balances, stock
valuation posting to the ledger.

## Phase 11 — CRM, corporate, travel agents
Lead pipeline, contract rates, credit limits, commissions, city ledger.

## Phase 12 — Analytics & revenue management
Owner one-screen dashboard charts, seasonal and dynamic pricing, promotions.

## Phase 13 — Notifications & integrations
Email/SMS/WhatsApp adapters, template editor, consent handling, data import.

## Phase 14 — Security, testing, optimisation
Penetration review, rate limiting, query tuning at realistic volumes,
accessibility pass, full mobile QA, load testing.

## Phase 15 — Production deployment
Supabase production project, Vercel production, real credentials, backup and
restore drill, monitoring, staff training, go-live.

---

## Definition of done, every phase

1. Feature works end to end against a real database — not a mockup.
2. Permissions enforced at API **and** database level.
3. Automated tests pass, including the integrity suite.
4. Works on mobile, tablet and desktop.
5. Errors are handled and surfaced legibly.
6. Sensitive actions are audited.
7. Documentation updated.
8. No hardcoded secrets.

---

## Production readiness checklist

| Item | Status |
|---|---|
| No hardcoded secrets | ✅ `.env.example` documents names only |
| Database migrations work | ✅ 12 migrations, clean from scratch, verified |
| Reservations cannot double-book | ✅ verified under real concurrency |
| OTA events are idempotent | ✅ 4 layers, verified |
| Payment webhooks are verified | ✅ enforced by constraint |
| Accounting balances | ✅ verified, trial balance nets to zero |
| Inventory balances | ✅ verified, weighted average correct |
| Permissions work | ✅ 39 security tests |
| RLS tenant isolation | ✅ verified as the real roles |
| Audit logs work | ✅ verified, append-only |
| Authentication works | ✅ Phase 1, verified in a browser |
| APIs are secured | ✅ `withAuth` + RLS; more endpoints per phase |
| Reports reconcile to transactions | Phase 6 |
| PDF invoices work | Phase 5 |
| Excel exports work | Phase 6 |
| Mobile UI works | ✅ Phase 1 screens; more per phase |
| Backup and restore drill | Phase 15 |
