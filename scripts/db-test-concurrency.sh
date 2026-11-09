#!/usr/bin/env bash
# Concurrency tests: two genuinely simultaneous sessions competing for
# the same room -- an OTA booking and a direct website booking arriving
# at nearly the same time.
#
# Uses two real psql sessions driven through FIFOs so the transactions
# actually overlap in time; a sequential script would not exercise the
# locking at all.
set -uo pipefail

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

psql_args=(-q -At)
[[ -n "${DATABASE_URL:-}" ]] && psql_args=("$DATABASE_URL" "${psql_args[@]}")

ok()  { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $1${2:+ -- $2}"; FAIL=$((FAIL+1)); }

declare -A FD

# Each session gets a FIFO held open on a persistent descriptor. Opening
# read-write keeps it open between writes -- a plain `echo > fifo` would
# close it and psql would see EOF and exit after the first statement.
start_session() {
  mkfifo "$TMP/$1.in"
  psql "${psql_args[@]}" < "$TMP/$1.in" > "$TMP/$1.out" 2>&1 &
  local fd
  exec {fd}<>"$TMP/$1.in"
  FD[$1]=$fd
}
send() { printf '%s\n' "$2" >&"${FD[$1]}"; }

# Waits until a backend is blocked on a lock.
wait_until_blocked() {
  local i=0
  while (( i < $2 )); do
    local n
    n=$(psql "${psql_args[@]}" -c "
      SELECT count(*) FROM pg_stat_activity
       WHERE state = 'active' AND wait_event_type = 'Lock'
         AND query ILIKE '%$1%'")
    [[ "$n" -ge 1 ]] && return 0
    sleep 0.1; i=$((i+1))
  done
  return 1
}

echo "=== Scenario 1: OTA vs website, competing for the last room ==="

psql "${psql_args[@]}" >/dev/null <<'SQL'
-- One room type, two physical rooms. Pre-sell one so exactly one is left.
SELECT app.ensure_inventory_rows('00000000-0000-0000-0000-0000000000b1',
       '00000000-0000-0000-0000-0000000000c1', DATE '2026-10-01', DATE '2026-10-03');
UPDATE inventory_daily SET sold_rooms = 1, blocked_rooms = 0, ooo_rooms = 0
 WHERE room_type_id = '00000000-0000-0000-0000-0000000000c1'
   AND stay_date >= DATE '2026-10-01' AND stay_date < DATE '2026-10-03';
SQL

start_session ota
start_session web

send ota "BEGIN; SELECT app.reserve_inventory('00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-0000000000c1', DATE '2026-10-01', DATE '2026-10-03', 1); SELECT 'ota-reserved';"
sleep 1
send web "BEGIN; SELECT app.reserve_inventory('00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-0000000000c1', DATE '2026-10-01', DATE '2026-10-03', 1); SELECT 'web-reserved';"

if wait_until_blocked "reserve_inventory" 50; then
  ok "website booking blocks while the OTA booking holds the inventory lock"
else
  bad "website booking blocks while the OTA booking holds the inventory lock" "never observed waiting on a lock"
fi

send ota "COMMIT;"; sleep 2
send web "COMMIT;"; sleep 1
send ota "\\q"; send web "\\q"
wait 2>/dev/null

grep -q 'ota-reserved' "$TMP/ota.out" \
  && ok "OTA booking succeeded" \
  || bad "OTA booking succeeded" "$(tail -3 "$TMP/ota.out" | tr '\n' ' ')"

if grep -qi 'No availability' "$TMP/web.out"; then
  ok "website booking was rejected instead of overselling"
else
  bad "website booking was rejected instead of overselling" "$(tail -5 "$TMP/web.out" | tr '\n' ' ')"
fi

SOLD=$(psql "${psql_args[@]}" -c "SELECT max(sold_rooms) FROM inventory_daily
        WHERE room_type_id='00000000-0000-0000-0000-0000000000c1'
          AND stay_date >= DATE '2026-10-01' AND stay_date < DATE '2026-10-03'")
[[ "$SOLD" == "2" ]] && ok "final sold count is 2 of 2 rooms (no oversell)" \
  || bad "final sold count is 2 of 2 rooms (no oversell)" "sold_rooms = $SOLD"

echo
echo "=== Scenario 2: two sessions assigning the same physical room ==="

psql "${psql_args[@]}" >/dev/null <<'SQL'
INSERT INTO reservations (id, property_id, reservation_number, guest_id, status,
                          arrival_date, departure_date, adults)
VALUES ('00000000-0000-0000-0000-0000000000e8','00000000-0000-0000-0000-0000000000b1',
        'RES-CONC-1','00000000-0000-0000-0000-000000000091','CONFIRMED',
        DATE '2026-10-10', DATE '2026-10-14', 2)
ON CONFLICT DO NOTHING;
INSERT INTO reservation_rooms (id, reservation_id, property_id, room_type_id, rate_plan_id,
                               arrival_date, departure_date, adults, line_number)
VALUES ('00000000-0000-0000-0000-0000000000e9','00000000-0000-0000-0000-0000000000e8',
        '00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-0000000000c1',
        '00000000-0000-0000-0000-0000000000e1', DATE '2026-10-10', DATE '2026-10-14', 2, 1),
       ('00000000-0000-0000-0000-0000000000ea','00000000-0000-0000-0000-0000000000e8',
        '00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-0000000000c1',
        '00000000-0000-0000-0000-0000000000e1', DATE '2026-10-10', DATE '2026-10-14', 2, 2)
ON CONFLICT DO NOTHING;
SQL

start_session s1
start_session s2

send s1 "BEGIN; INSERT INTO room_allocations (property_id, room_id, allocation_type, reservation_room_id, arrival_date, departure_date) VALUES ('00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-0000000000d2','RESERVATION','00000000-0000-0000-0000-0000000000e9', DATE '2026-10-10', DATE '2026-10-12'); SELECT 's1-allocated';"
sleep 1
send s2 "BEGIN; INSERT INTO room_allocations (property_id, room_id, allocation_type, reservation_room_id, arrival_date, departure_date) VALUES ('00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-0000000000d2','RESERVATION','00000000-0000-0000-0000-0000000000ea', DATE '2026-10-11', DATE '2026-10-13'); SELECT 's2-allocated';"

if wait_until_blocked "room_allocations" 50; then
  ok "second assignment waits on the exclusion constraint"
else
  bad "second assignment waits on the exclusion constraint" "never observed waiting"
fi

send s1 "COMMIT;"; sleep 2
send s2 "COMMIT;"; sleep 1
send s1 "\\q"; send s2 "\\q"
wait 2>/dev/null

grep -q 's1-allocated' "$TMP/s1.out" \
  && ok "first room assignment succeeded" \
  || bad "first room assignment succeeded" "$(tail -3 "$TMP/s1.out" | tr '\n' ' ')"

if grep -qi 'conflicting key value violates exclusion constraint' "$TMP/s2.out"; then
  ok "second room assignment rejected by the database"
else
  bad "second room assignment rejected by the database" "$(tail -5 "$TMP/s2.out" | tr '\n' ' ')"
fi

N=$(psql "${psql_args[@]}" -c "SELECT count(*) FROM room_allocations
      WHERE room_id='00000000-0000-0000-0000-0000000000d2' AND is_active
        AND stay_range && daterange(DATE '2026-10-10', DATE '2026-10-14','[)')")
[[ "$N" == "1" ]] && ok "exactly one active allocation survives for that room and window" \
  || bad "exactly one active allocation survives for that room and window" "found $N"

echo
echo "Concurrency: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
