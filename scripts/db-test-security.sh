#!/usr/bin/env bash
# Security tests: RLS tenant isolation and RBAC permission boundaries,
# executed as the real `authenticated` and `anon` roles rather than as a
# superuser (which bypasses RLS entirely).
set -uo pipefail

PASS=0; FAIL=0
FRONTDESK='00000000-0000-0000-0000-000000000071'
OWNER='00000000-0000-0000-0000-000000000072'
RIVAL='00000000-0000-0000-0000-000000000073'

psql_args=(-q -At)
[[ -n "${DATABASE_URL:-}" ]] && psql_args=("$DATABASE_URL" "${psql_args[@]}")

as_user() { psql "${psql_args[@]}" -c "SET app.current_user_id='$1'; SET ROLE authenticated; $2" 2>&1 | tail -1; }
as_anon()  { psql "${psql_args[@]}" -c "SET ROLE anon; $1" 2>&1 | tail -1; }

check() {
  if [[ "$3" == "$2" ]]; then echo "  PASS  $1"; PASS=$((PASS+1))
  else echo "  FAIL  $1 -- expected '$2', got '$3'"; FAIL=$((FAIL+1)); fi
}
check_contains() {
  if [[ "$3" == *"$2"* ]]; then echo "  PASS  $1"; PASS=$((PASS+1))
  else echo "  FAIL  $1 -- expected to contain '$2', got '$3'"; FAIL=$((FAIL+1)); fi
}

echo "=== Tenant isolation (RLS) ==="
# Compared against the true count rather than a literal, so the result
# does not depend on which other suites have run first.
TRUE_RES=$(psql "${psql_args[@]}" -c "SELECT count(*) FROM reservations
             WHERE property_id='00000000-0000-0000-0000-0000000000b1'")
check "own-org user sees exactly their own reservations" \
      "$TRUE_RES" "$(as_user "$FRONTDESK" 'SELECT count(*) FROM reservations;')"
check "other-tenant user sees none of them" "0" "$(as_user "$RIVAL" 'SELECT count(*) FROM reservations;')"
check "other-tenant user sees no guests"    "0" "$(as_user "$RIVAL" 'SELECT count(*) FROM guests;')"
check "other-tenant user sees no rooms"     "0" "$(as_user "$RIVAL" 'SELECT count(*) FROM rooms;')"
check "other-tenant user sees no invoices"  "0" "$(as_user "$RIVAL" 'SELECT count(*) FROM invoices;')"
check "other-tenant user sees no journal lines" "0" "$(as_user "$RIVAL" 'SELECT count(*) FROM journal_lines;')"
check "child rows inherit the parent's tenant scope" "0" "$(as_user "$RIVAL" 'SELECT count(*) FROM invoice_items;')"
check "user sees only their own property list" "1" "$(as_user "$FRONTDESK" 'SELECT count(*) FROM properties;')"

echo
echo "=== Cross-tenant writes are refused ==="
check_contains "cannot insert into another tenant's property" "row-level security" \
  "$(as_user "$RIVAL" "INSERT INTO rooms (property_id, room_type_id, room_number) VALUES ('00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-0000000000c1','999');")"

echo
echo "=== RBAC: front desk boundaries ==="
check "front desk may collect payments"       "t" "$(as_user "$FRONTDESK" "SELECT app.has_permission('payments.collect');")"
check "front desk may check guests in"        "t" "$(as_user "$FRONTDESK" "SELECT app.has_permission('reservations.checkin');")"
check "front desk may create invoices"        "t" "$(as_user "$FRONTDESK" "SELECT app.has_permission('invoices.create');")"
check "front desk may NOT refund"             "f" "$(as_user "$FRONTDESK" "SELECT app.has_permission('payments.refund');")"
check "front desk may NOT post accounting"    "f" "$(as_user "$FRONTDESK" "SELECT app.has_permission('accounting.post');")"
check "front desk may NOT change GST config"  "f" "$(as_user "$FRONTDESK" "SELECT app.has_permission('tax.manage');")"
check "front desk may NOT change settings"    "f" "$(as_user "$FRONTDESK" "SELECT app.has_permission('settings.manage');")"
check "front desk may NOT void charges"       "f" "$(as_user "$FRONTDESK" "SELECT app.has_permission('folio.void');")"
check "front desk may NOT cancel invoices"    "f" "$(as_user "$FRONTDESK" "SELECT app.has_permission('invoices.cancel');")"
check "front desk may NOT read financial reports" "f" "$(as_user "$FRONTDESK" "SELECT app.has_permission('reports.financial');")"
check "front desk may NOT manage users"       "f" "$(as_user "$FRONTDESK" "SELECT app.has_permission('users.manage');")"
check "front desk may NOT read audit logs"    "f" "$(as_user "$FRONTDESK" "SELECT app.has_permission('audit.read');")"

echo
echo "=== RBAC: owner has full business visibility ==="
for p in payments.refund accounting.post reports.financial audit.read tax.manage \
         settings.manage users.manage channels.manage dashboard.financial; do
  check "owner may $p" "t" "$(as_user "$OWNER" "SELECT app.has_permission('$p');")"
done

echo
echo "=== Sensitive tables ==="
check "front desk cannot read audit logs through RLS" "0" "$(as_user "$FRONTDESK" 'SELECT count(*) FROM audit_logs;')"
OWNER_AUDIT="$(as_user "$OWNER" 'SELECT count(*) FROM audit_logs;')"
if [[ "$OWNER_AUDIT" -gt 0 ]] 2>/dev/null; then
  echo "  PASS  owner can read audit logs ($OWNER_AUDIT rows)"; PASS=$((PASS+1))
else
  echo "  FAIL  owner can read audit logs -- got '$OWNER_AUDIT'"; FAIL=$((FAIL+1))
fi
check_contains "encrypted credentials are unreachable by app users" "permission denied" \
  "$(as_user "$OWNER" 'SELECT count(*) FROM integration_credentials;')"
check_contains "raw webhook payloads are unreachable by app users" "permission denied" \
  "$(as_user "$OWNER" 'SELECT count(*) FROM webhook_events;')"

echo
echo "=== Public booking engine (anon) ==="
check_contains "anon cannot read reservations" "permission denied" "$(as_anon 'SELECT count(*) FROM reservations;')"
check_contains "anon cannot read guests"       "permission denied" "$(as_anon 'SELECT count(*) FROM guests;')"
check_contains "anon cannot read invoices"     "permission denied" "$(as_anon 'SELECT count(*) FROM invoices;')"
check_contains "anon cannot read the ledger"   "permission denied" "$(as_anon 'SELECT count(*) FROM journal_lines;')"
AVAIL="$(as_anon "SELECT count(*) FROM app.public_search_availability('00000000-0000-0000-0000-0000000000b1', DATE '2026-09-05', DATE '2026-09-07', 2, 0, 1);")"
if [[ "$AVAIL" =~ ^[0-9]+$ ]]; then
  echo "  PASS  anon can search availability through the public RPC ($AVAIL offers)"; PASS=$((PASS+1))
else
  echo "  FAIL  anon can search availability through the public RPC -- got '$AVAIL'"; FAIL=$((FAIL+1))
fi

echo
echo "Security: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
