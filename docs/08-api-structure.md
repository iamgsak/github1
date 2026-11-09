# 09 — API Structure

REST under `/api/v1`. Pages and API handlers share one service layer, so
there is one code path and one set of rules.

---

## 1. Conventions

| Aspect | Rule |
|---|---|
| Auth | Session cookie (UI) or `Authorization: Bearer <api-key>` (partners) |
| Property scope | `X-Property-Id` header, validated against the caller's access |
| Idempotency | `Idempotency-Key` header, required on booking and payment writes |
| Pagination | `?page=1&pageSize=50`, max 200; `meta.total` returned |
| Filtering | `?status=CONFIRMED&arrivalFrom=2026-09-01&q=nair` |
| Sorting | `?sort=-arrivalDate` (`-` = descending) |
| Casing | `camelCase` in JSON, `snake_case` in the database |
| Dates | Stay dates `YYYY-MM-DD`; timestamps ISO-8601 UTC |

### Status codes

`200` ok · `201` created · `204` deleted · `400` validation · `401`
unauthenticated · `403` lacks permission · `404` not found or not visible to
this tenant · `409` conflict (double booking, duplicate number) · `422`
business rule violated · `429` rate limited · `500` unexpected.

`404` rather than `403` for another tenant's records, so the API does not
confirm that an id exists.

### Error translation

| PostgreSQL | API code | HTTP |
|---|---|---|
| `exclusion_violation` on `room_allocations` | `ROOM_ALREADY_ALLOCATED` | 409 |
| capacity CHECK on `inventory_daily` | `NO_AVAILABILITY` | 409 |
| `unique_violation` on an external reference | `DUPLICATE_BOOKING` | 409 |
| `check_violation` on a status transition | `BUSINESS_RULE_VIOLATION` | 422 |
| `restrict_violation` on a posted journal | `IMMUTABLE_RECORD` | 422 |

Implemented in `src/lib/errors.ts`.

---

## 2. Endpoints

**Auth** — `POST /auth/login` · `POST /auth/logout` · `POST /auth/refresh` ·
`POST /auth/forgot-password` · `POST /auth/reset-password` · `GET /auth/me`

**Properties & setup** — `GET|PATCH /properties/:id` ·
`GET|POST /room-types` · `GET|PATCH|DELETE /room-types/:id` ·
`GET|POST /rooms` · `GET|PATCH /rooms/:id` · `PATCH /rooms/:id/status`

**Rates & availability** — `GET|POST /rate-plans` · `GET /rates` ·
`PUT /rates` (bulk grid) · `GET|PUT /availability` · `GET|PUT /restrictions`

**Reservations** — `GET|POST /reservations` · `GET|PATCH /reservations/:id` ·
`POST /reservations/:id/confirm|cancel|no-show` ·
`POST /reservations/:id/rooms/:lineId/assign` ·
`POST /reservations/:id/extend` · `GET /reservations/calendar`

**Front office** — `GET /front-desk/dashboard|arrivals|departures|in-house` ·
`POST /front-desk/check-in` · `POST /front-desk/check-out`

**Guests** — `GET|POST /guests` · `GET|PATCH /guests/:id` ·
`GET /guests/:id/history` · `GET|POST /guests/:id/documents`

**Folios & billing** — `GET /folios` · `GET /folios/:id` ·
`POST /folios/:id/items` · `POST /folios/:id/items/:itemId/void` ·
`POST /folios/:id/transfer|split` · `GET|POST /invoices` ·
`GET /invoices/:id/pdf` · `POST /invoices/:id/email|cancel|credit-note`

**Payments** — `GET|POST /payments` · `POST /payments/:id/void` ·
`POST /refunds` · `POST /refunds/:id/approve` ·
`POST /webhooks/payments/:gateway`

**Accounting** — `GET|POST /accounts` · `GET|POST /journal-entries` ·
`POST /journal-entries/:id/post|reverse` ·
`GET /accounting/ledger|trial-balance|profit-loss|balance-sheet|cash-flow` ·
`POST /accounting/periods/:id/close`

**Tax** — `GET|POST /tax-groups` · `GET|POST /tax-rates` ·
`GET /tax/gst-summary`

**Housekeeping** — `GET /housekeeping/board` · `GET|POST /housekeeping/tasks` ·
`POST /housekeeping/tasks/:id/assign|start|complete|inspect`

**Maintenance** — `GET|POST /maintenance/tickets` ·
`POST /maintenance/tickets/:id/assign|complete|close`

**Inventory** — `GET|POST /inventory/items|stores` · `GET /inventory/stock` ·
`POST /inventory/movements|transfers|adjustments` · `GET|POST /inventory/counts`

**Purchasing** — `GET|POST /purchasing/requests` ·
`POST /purchasing/requests/:id/approve|reject` ·
`GET|POST /purchasing/orders|receipts|invoices` · `GET|POST /suppliers`

**CRM & B2B** — `GET|POST /crm/leads` · `POST /crm/leads/:id/activities|convert` ·
`GET|POST /corporate-accounts` · `GET|POST /travel-agents`

**Employees** — `GET|POST /employees` · `GET|POST /attendance` ·
`GET|POST /leave-requests`

**Channels** — `GET|POST /channels` · `POST /channels/:id/test-connection|sync` ·
`GET|PUT /channels/:id/mappings` · `GET /channels/:id/logs` ·
`POST /webhooks/channels/:channel`

**Reports** — `GET /reports/:report?from=&to=&propertyId=&format=json|pdf|xlsx|csv`

**Dashboard** — `GET /dashboard/owner|kpis` · `GET /dashboard/charts/:chart`

**Admin** — `GET|POST /users` · `GET|POST|PATCH /roles` · `GET /permissions` ·
`GET|PUT /settings` · `GET|POST|DELETE /api-keys` · `GET /audit-logs` ·
`GET /search?q=`

**Public** (no session) — see [05 — Booking Engine](04-booking-engine.md#3-public-api-surface).

---

## 3. Global search

`GET /search?q=` searches reservations (number, external reference), guests
(name, phone, email), rooms, invoices, payments, suppliers, employees and
corporate accounts. Results are permission-filtered per type — a housekeeper
searching a guest name sees the room assignment, not the folio balance.

---

## 4. Rate limiting

| Surface | Limit |
|---|---|
| Public booking endpoints | 30 req/min per IP |
| Authenticated API | 300 req/min per user |
| Partner API keys | `api_keys.rate_limit_per_minute`, default 60 |
| Login | 5 failures per account per 15 min, then lockout |
| Webhooks | Per provider, generous, with dedupe absorbing bursts |

---

## 5. Documentation

An OpenAPI 3.1 document is generated from the Zod schemas, so the contract
cannot drift from the validation. Served at `/api/v1/openapi.json`.
