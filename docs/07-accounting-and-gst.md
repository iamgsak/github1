# 08 — Accounting & GST

The brief's rule, restated because it drives the whole design:

> Do not create accounting reports by simply adding random reservation
> totals. All financial reports must derive from properly recorded accounting
> transactions.

```
Business event → Journal Entry → Ledger → Trial Balance → P&L → Balance Sheet → Cash Flow
```

---

## 1. Chart of accounts

64 system accounts are provisioned per organization by
`app.provision_organization_defaults()`, covering assets, liabilities, equity,
revenue and expenses for an Indian hotel — including the ones that matter
here: `1150 Accounts Receivable – OTA`, `2120/2121/2122` output GST,
`1170/1171/1172` input GST, `5300 OTA Commission`, `5310 Travel Agent
Commission` and `5320 Payment Gateway Charges`.

Accounts are editable and extendable; `is_system` marks the ones posting logic
depends on so they cannot be deleted out from under it.

---

## 2. The four rules

| # | Rule | Enforced by |
|---|---|---|
| 1 | A line is a debit **or** a credit, never both, never zero | `journal_lines_one_side_chk` |
| 2 | A posted entry balances, and has ≥ 2 lines | Deferred constraint trigger |
| 3 | A posted entry is immutable — correct by reversal | BEFORE trigger on entries and lines |
| 4 | Nothing posts into a `CLOSED`/`LOCKED` period | BEFORE trigger (also resolves the period) |

Rule 2 is deferred to COMMIT, which allows a header and its lines to be
inserted as separate statements inside one transaction while still being
impossible to leave unbalanced.

`journal_entries_source_uq` permits one non-reversed entry per source
document, so re-running a posting job cannot double-count revenue.

All four rules, plus "the trial balance nets to zero", are asserted by tests.

---

## 3. Standard postings

**Room revenue, ₹5,000 + 12% GST, paid in cash**

| Account | Debit | Credit |
|---|---:|---:|
| 1110 Cash in Hand | 5,600.00 | |
| 4100 Room Revenue | | 5,000.00 |
| 2120 Output CGST | | 300.00 |
| 2121 Output SGST | | 300.00 |

**OTA booking, OTA collects, 15% commission on ₹5,000**

| Account | Debit | Credit |
|---|---:|---:|
| 1150 Accounts Receivable – OTA | 4,850.00 | |
| 5300 OTA Commission | 750.00 | |
| 4100 Room Revenue | | 5,000.00 |
| 2120 Output CGST | | 300.00 |
| 2121 Output SGST | | 300.00 |

Commission is its own expense line, so net channel revenue is a ledger fact.

**Purchase of supplies on credit, ₹10,000 + 18% GST**

| Account | Debit | Credit |
|---|---:|---:|
| 1162 Inventory – General Stores | 10,000.00 | |
| 1170 Input CGST | 900.00 | |
| 1171 Input SGST | 900.00 | |
| 2110 Accounts Payable – Suppliers | | 11,800.00 |

---

## 4. GST — configurable, never hard-coded

`tax_groups` and `tax_rates` are data. Rates carry `effective_from` /
`effective_to`, so an invoice reprinted next year still shows the rate that
applied on its invoice date.

Seeded defaults for India (editable in Settings, and to be verified against
the current notification before go-live):

| Group | SAC | Rate |
|---|---|---|
| `GST_ROOM` | 996311 | 12% (CGST 6 + SGST 6) up to ₹7,500/night; 18% (9+9) above — **slab-based on the per-night tariff** |
| `GST_FOOD` | 996331 | 5% (CGST 2.5 + SGST 2.5) |
| `GST_SERVICE` | 999799 | 18% (CGST 9 + SGST 9) |
| `GST_EXEMPT` | — | Nil |

### An India-specific detail that is easy to get wrong

For **accommodation, the place of supply is the location of the hotel**. Room
revenue is therefore *always* intra-state — CGST + SGST — even when the guest
is from another state and even when they supply an out-of-state GSTIN. IGST
does not apply to the room tariff. The `is_interstate` flag exists for goods
and for services whose place-of-supply rules differ; it must not be set from
the guest's home state.

The schema enforces the arithmetic regardless:

| Constraint | Prevents |
|---|---|
| `invoices_gst_mode_chk` | CGST/SGST and IGST on one invoice |
| `invoices_cgst_sgst_chk` | An unequal central/state split |
| `invoices_total_chk` | A total that does not equal taxable + tax + round-off |
| `invoices_b2b_gstin_chk` | A B2B invoice with no buyer GSTIN |
| `invoices_credit_note_chk` | An orphan credit note |

Also supported: tax-inclusive and tax-exclusive pricing, B2B/B2C
classification, customer GSTIN capture, credit and debit notes, and input tax
credit eligibility on purchases (`purchase_invoices.itc_eligible`).

---

## 5. Invoicing

Invoice numbers come from `document_series`: sequential, per property, per
financial year, configurable prefix (`INV-2026-27/00001`).

Bill-to details are **snapshotted onto the invoice**. Editing a guest's
address later must never alter an already-issued statutory document.

Invoices are never deleted. The workflows are cancel (with reason, audited),
credit note, and debit note — each linked to the original. `invoices.cancel`
and `invoices.credit_note` are sensitive permissions the front desk lacks.

---

## 6. Reports

All read from `journal_lines` via `v_general_ledger` and `v_trial_balance`:

Day Book · Cash Book · Bank Book · General Ledger · Trial Balance · Profit &
Loss · Balance Sheet · Cash Flow · Accounts Receivable (ageing) · Accounts
Payable (ageing) · Expense Report · Revenue Report · Tax Report · GST summary
(GSTR-1 / GSTR-3B shaped).

Every report supports date range, property filter and account filter, and
exports to PDF, Excel and CSV.

**Reconciliation is a first-class check, not a hope.** Because operational
documents carry `journal_entry_id` and journals carry
`source_type`/`source_id`, the system can assert that every invoice and
payment has exactly one posted entry, and that revenue in the P&L equals
revenue on the folios. Any divergence is a reportable defect.
