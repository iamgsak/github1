# 10 — Integrations, Notifications & Recovery

---

## 1. Adapter pattern, everywhere

Every external dependency sits behind an interface, is selected by
configuration, and has a mock implementation for development.

| Concern | Interface | Providers |
|---|---|---|
| OTA / channel | `ChannelAdapter` | Booking.com, Agoda, Expedia, MMT, Goibibo, Airbnb, aggregators, `MOCK_GENERIC` |
| Payments | `PaymentGatewayAdapter` | Razorpay, Cashfree, PayU, `MOCK` |
| Email | `EmailAdapter` | SMTP, Resend, SendGrid, `MOCK` |
| SMS | `SmsAdapter` | MSG91, Twilio, Gupshup, `MOCK` |
| WhatsApp | `WhatsAppAdapter` | WhatsApp Cloud API, Gupshup, `MOCK` |
| Storage | `StorageAdapter` | Supabase Storage, S3-compatible |
| Auth | `AuthAdapter` | Supabase Auth, local credentials |

No provider name appears in business logic. Switching SMS vendors is a
settings change plus one adapter file.

---

## 2. Notifications

`notification_templates` holds subject and body per code, channel and locale,
with declared variables so a template is validated before it is saved.
`notifications` is the outbox: queued, sent, delivered, failed, read — with
provider message id and retry count.

Catalogue: booking confirmation · booking modification · cancellation ·
payment confirmation · payment pending · refund processed · check-in reminder
· check-out reminder · invoice delivered · low stock alert · maintenance alert
· OTA sync failure · daily summary for the owner.

Delivery rules:

- **Consent is checked per channel.** `guests.email_consent`,
  `sms_consent`, `whatsapp_consent` and `marketing_consent` are separate
  booleans with a `consent_updated_at` timestamp. Transactional messages are
  sent regardless; marketing requires explicit consent. This is the DPDP Act
  2023 posture.
- **WhatsApp** requires provider-approved templates
  (`provider_template_id`); free-form messages outside the service window are
  not attempted.
- Failures retry with backoff and surface in the UI rather than vanishing.
- `IN_APP` goes to a user; every other channel needs an address — enforced by
  `notifications_recipient_chk`.

---

## 3. Data import

CSV/Excel import with validation and preview for: guests, rooms, room types,
suppliers, inventory items, chart of accounts, and opening balances.

Every import runs: parse → validate row by row → **preview with per-row
errors** → confirm → transactional insert. Nothing is written until the user
confirms, and a failed row never leaves a half-imported file behind. Opening
balances post as a single balanced `OPENING` journal entry, so imported
history obeys the same accounting rules as everything else.

---

## 4. Backup and recovery

| Concern | Approach |
|---|---|
| Backups | Supabase automated daily snapshots + point-in-time recovery |
| Retention | 30 days PITR; monthly archives kept 7 years for statutory records |
| Migrations | Numbered, forward-only, each applied in a single transaction |
| Destructive changes | Not permitted on production data. A replacement column is added, backfilled, then the old one retired once nothing reads it. |
| Verification | `scripts/db-test.sh` runs the full suite against a fresh database in CI on every PR |
| Restore drill | Restore to a scratch project and run the suite against it — a backup that has never been restored is not a backup |
| Monitoring | Error tracking, structured logs with `requestId`, per-channel integration health |

Because the ledger is append-only and every operational document links to its
journal entry, a restore can be verified for *correctness* — the trial balance
must still net to zero — not merely for completeness.
