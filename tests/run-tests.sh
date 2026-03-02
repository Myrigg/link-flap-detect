#!/usr/bin/env bash
# tests/run-tests.sh
# Non-destructive test suite for link-flap-detect.sh
#
# Properties guaranteed:
#   - No system logs are read  (uses _LINK_FLAP_TEST_INPUT to inject synthetic data)
#   - No root access required
#   - No side effects outside /tmp  (temp dir cleaned on exit)
#   - Idempotent — safe to run repeatedly
#
# Usage:
#   bash tests/run-tests.sh

set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/link-flap-detect.sh"

if [[ ! -f "$SCRIPT" ]]; then
  echo "Error: $SCRIPT not found." >&2; exit 1
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
PASS=0; FAIL=0
TESTDIR=$(mktemp -d /tmp/link-flap-tests-XXXXXX)
trap 'rm -rf "$TESTDIR"' EXIT

if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BOLD=''; RESET=''
fi

pass() { echo -e "  ${GREEN}PASS${RESET}  $1"; (( PASS++ )) || true; }
fail() {
  echo -e "  ${RED}FAIL${RESET}  $1"
  echo -e "        ${YELLOW}$2${RESET}"
  (( FAIL++ )) || true
}

# ts N — ISO 8601 timestamp N seconds ago (always within any reasonable window)
ts() { date -d "@$(( $(date +%s) - $1 ))" "+%Y-%m-%dT%H:%M:%S+0000"; }

# ts_syslog N — syslog-style "Mon DD HH:MM:SS" timestamp N seconds ago
# Tests that the second awk pass correctly uses -F'\t' to parse spaced timestamps
ts_syslog() { date -d "@$(( $(date +%s) - $1 ))" "+%b %e %H:%M:%S"; }

# run INPUT_FILE [SCRIPT_ARGS...]
# Populates OUT (stdout+stderr) and EXITCODE.
OUT=''; EXITCODE=0
run() {
  local f="$1"; shift
  OUT=''; EXITCODE=0
  OUT=$(_LINK_FLAP_TEST_INPUT="$f" bash "$SCRIPT" "$@" 2>&1) || EXITCODE=$?
}

# ── Tests ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}link-flap-detect.sh — test suite${RESET}"
echo ""

# 1. Empty log → exit 0, informational "no events" message
t=$(mktemp "$TESTDIR/XXXXXX.log"); : > "$t"
run "$t" -w 60
if [[ $EXITCODE -eq 0 ]] && echo "$OUT" | grep -q "No link state events"; then
  pass "empty log: exit 0, 'No link state events found'"
else
  fail "empty log: exit 0, 'No link state events found'" "exit=$EXITCODE\n$OUT"
fi

# 2. Two transitions (Down→Up→Down) — below default threshold of 3 → exit 0
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts 300) host kernel: eth0: NIC Link is Down
$(ts 200) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 100) host kernel: eth0: NIC Link is Down
EOF
run "$t" -w 60 -t 3
if [[ $EXITCODE -eq 0 ]] && echo "$OUT" | grep -q "No flapping detected"; then
  pass "2 transitions < threshold 3: exit 0, 'No flapping detected'"
else
  fail "2 transitions < threshold 3: exit 0, 'No flapping detected'" "exit=$EXITCODE\n$OUT"
fi

# 3. Four transitions ≥ threshold 3 → exit 1, [FLAPPING] in output
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts 500) host kernel: eth0: NIC Link is Down
$(ts 400) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 300) host kernel: eth0: NIC Link is Down
$(ts 200) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 100) host kernel: eth0: NIC Link is Down
EOF
run "$t" -w 60 -t 3
if [[ $EXITCODE -eq 1 ]] && echo "$OUT" | grep -q "\[FLAPPING\]"; then
  pass "4 transitions ≥ threshold 3: exit 1, [FLAPPING] reported"
else
  fail "4 transitions ≥ threshold 3: exit 1, [FLAPPING] reported" "exit=$EXITCODE\n$OUT"
fi

# 4. Interface filter -i eth1 excludes eth0 events entirely → exit 0
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts 500) host kernel: eth0: NIC Link is Down
$(ts 400) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 300) host kernel: eth0: NIC Link is Down
$(ts 200) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 100) host kernel: eth0: NIC Link is Down
EOF
run "$t" -w 60 -t 3 -i eth1
if [[ $EXITCODE -eq 0 ]] && ! echo "$OUT" | grep -q "\[FLAPPING\]"; then
  pass "interface filter -i eth1 excludes eth0 events"
else
  fail "interface filter -i eth1 excludes eth0 events" "exit=$EXITCODE\n$OUT"
fi

# 5. Threshold override: -t 6 means 4 transitions are not enough → exit 0
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts 500) host kernel: eth0: NIC Link is Down
$(ts 400) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 300) host kernel: eth0: NIC Link is Down
$(ts 200) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 100) host kernel: eth0: NIC Link is Down
EOF
run "$t" -w 60 -t 6
if [[ $EXITCODE -eq 0 ]]; then
  pass "threshold override -t 6: 4 transitions not enough → exit 0"
else
  fail "threshold override -t 6: 4 transitions not enough → exit 0" "exit=$EXITCODE\n$OUT"
fi

# 6. Verbose mode shows individual UP/DOWN event lines
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts 300) host kernel: eth0: NIC Link is Down
$(ts 200) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 100) host kernel: eth0: NIC Link is Down
EOF
run "$t" -w 60 -v
if echo "$OUT" | grep -qE "UP|DOWN"; then
  pass "verbose mode (-v) shows UP/DOWN event lines"
else
  fail "verbose mode (-v) shows UP/DOWN event lines" "output:\n$OUT"
fi

# 7. Multiple interfaces: eth0 flaps (above threshold), eth1 does not
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts 500) host kernel: eth0: NIC Link is Down
$(ts 450) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 400) host kernel: eth0: NIC Link is Down
$(ts 350) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 300) host kernel: eth0: NIC Link is Down
$(ts 100) host kernel: eth1: NIC Link is Down
$(ts  50) host kernel: eth1: NIC Link is Up 1000 Mbps Full Duplex
EOF
run "$t" -w 60 -t 3
if [[ $EXITCODE -eq 1 ]] \
   && echo "$OUT" | grep -q "\[FLAPPING\].*eth0" \
   && ! echo "$OUT" | grep -q "\[FLAPPING\].*eth1"; then
  pass "multiple ifaces: only flapping eth0 reported; stable eth1 silent"
else
  fail "multiple ifaces: only flapping eth0 reported; stable eth1 silent" "exit=$EXITCODE\n$OUT"
fi

# 8. Pattern: kernel "carrier acquired / carrier lost"
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts 500) host kernel: ens18: carrier lost
$(ts 400) host kernel: ens18: carrier acquired
$(ts 300) host kernel: ens18: carrier lost
$(ts 200) host kernel: ens18: carrier acquired
$(ts 100) host kernel: ens18: carrier lost
EOF
run "$t" -w 60 -t 3
if [[ $EXITCODE -eq 1 ]] && echo "$OUT" | grep -q "\[FLAPPING\]"; then
  pass "kernel 'carrier acquired/lost' pattern → flap detected"
else
  fail "kernel 'carrier acquired/lost' pattern → flap detected" "exit=$EXITCODE\n$OUT"
fi

# 9. Pattern: systemd-networkd "Gained/Lost carrier"
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts 500) host systemd-networkd[1]: ens3: Lost carrier
$(ts 400) host systemd-networkd[1]: ens3: Gained carrier
$(ts 300) host systemd-networkd[1]: ens3: Lost carrier
$(ts 200) host systemd-networkd[1]: ens3: Gained carrier
$(ts 100) host systemd-networkd[1]: ens3: Lost carrier
EOF
run "$t" -w 60 -t 3
if [[ $EXITCODE -eq 1 ]] && echo "$OUT" | grep -q "\[FLAPPING\]"; then
  pass "systemd-networkd 'Gained/Lost carrier' pattern → flap detected"
else
  fail "systemd-networkd 'Gained/Lost carrier' pattern → flap detected" "exit=$EXITCODE\n$OUT"
fi

# 10. Pattern: NetworkManager "device (iface): link connected/disconnected"
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts 500) host NetworkManager[1]: <info> device (eth0): link disconnected
$(ts 400) host NetworkManager[1]: <info> device (eth0): link connected
$(ts 300) host NetworkManager[1]: <info> device (eth0): link disconnected
$(ts 200) host NetworkManager[1]: <info> device (eth0): link connected
$(ts 100) host NetworkManager[1]: <info> device (eth0): link disconnected
EOF
run "$t" -w 60 -t 3
if [[ $EXITCODE -eq 1 ]] && echo "$OUT" | grep -q "\[FLAPPING\]"; then
  pass "NetworkManager 'link connected/disconnected' pattern → flap detected"
else
  fail "NetworkManager 'link connected/disconnected' pattern → flap detected" "exit=$EXITCODE\n$OUT"
fi

# 11. Virtual interfaces (veth*, docker*, br-*, lo) are silently ignored by default
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts 500) host kernel: veth0abc: NIC Link is Down
$(ts 400) host kernel: veth0abc: NIC Link is Up
$(ts 300) host kernel: veth0abc: NIC Link is Down
$(ts 200) host kernel: veth0abc: NIC Link is Up
$(ts 100) host kernel: veth0abc: NIC Link is Down
$(ts  90) host kernel: docker0: NIC Link is Down
$(ts  80) host kernel: docker0: NIC Link is Up
$(ts  70) host kernel: docker0: NIC Link is Down
$(ts  60) host kernel: docker0: NIC Link is Up
$(ts  50) host kernel: docker0: NIC Link is Down
EOF
run "$t" -w 60 -t 3
if [[ $EXITCODE -eq 0 ]] && ! echo "$OUT" | grep -q "\[FLAPPING\]"; then
  pass "virtual ifaces (veth*, docker*) filtered by default"
else
  fail "virtual ifaces (veth*, docker*) filtered by default" "exit=$EXITCODE\n$OUT"
fi

# 12. -w 0 is rejected as invalid → exit 1, error to stderr
t=$(mktemp "$TESTDIR/XXXXXX.log"); : > "$t"
run "$t" -w 0
if [[ $EXITCODE -eq 1 ]] && echo "$OUT" | grep -qi "error"; then
  pass "invalid -w 0 → exit 1 + error message"
else
  fail "invalid -w 0 → exit 1 + error message" "exit=$EXITCODE\n$OUT"
fi

# 13. -t 1 is rejected (must be >= 2) → exit 1, error to stderr
t=$(mktemp "$TESTDIR/XXXXXX.log"); : > "$t"
run "$t" -t 1
if [[ $EXITCODE -eq 1 ]] && echo "$OUT" | grep -qi "error"; then
  pass "invalid -t 1 → exit 1 + error message"
else
  fail "invalid -t 1 → exit 1 + error message" "exit=$EXITCODE\n$OUT"
fi

# 14. -h prints usage and exits 0 (does not hang or error)
t=$(mktemp "$TESTDIR/XXXXXX.log"); : > "$t"
run "$t" -h
if [[ $EXITCODE -eq 0 ]] && echo "$OUT" | grep -qi "usage\|options\|-w"; then
  pass "-h prints usage text and exits 0"
else
  fail "-h prints usage text and exits 0" "exit=$EXITCODE\n$OUT"
fi

# 15. Syslog-format timestamps ("Mon DD HH:MM:SS") are parsed correctly
#     Verifies fix: second awk pass uses -F'\t' so spaced ts_raw is not split on spaces
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts_syslog 500) host kernel: eth0: NIC Link is Down
$(ts_syslog 400) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts_syslog 300) host kernel: eth0: NIC Link is Down
$(ts_syslog 200) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts_syslog 100) host kernel: eth0: NIC Link is Down
EOF
run "$t" -w 60 -t 3
if [[ $EXITCODE -eq 1 ]] && echo "$OUT" | grep -q "\[FLAPPING\]"; then
  pass "syslog-format timestamps (Mon DD HH:MM:SS) parsed correctly → flap detected"
else
  fail "syslog-format timestamps (Mon DD HH:MM:SS) parsed correctly → flap detected" "exit=$EXITCODE\n$OUT"
fi

# 16. All events same state → 0 transitions → no flapping
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts 500) host kernel: eth0: NIC Link is Down
$(ts 400) host kernel: eth0: NIC Link is Down
$(ts 300) host kernel: eth0: NIC Link is Down
$(ts 200) host kernel: eth0: NIC Link is Down
$(ts 100) host kernel: eth0: NIC Link is Down
EOF
run "$t" -w 60 -t 3
if [[ $EXITCODE -eq 0 ]] && ! echo "$OUT" | grep -q "\[FLAPPING\]"; then
  pass "all events same state: 0 transitions → no flapping"
else
  fail "all events same state: 0 transitions → no flapping" "exit=$EXITCODE\n$OUT"
fi

# 17. Exactly at threshold (transitions == FLAP_THRESHOLD) → detected
#     Down→Up→Down→Up = 3 transitions; threshold = 3 → should trigger
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts 400) host kernel: eth0: NIC Link is Down
$(ts 300) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 200) host kernel: eth0: NIC Link is Down
$(ts 100) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
EOF
run "$t" -w 60 -t 3
if [[ $EXITCODE -eq 1 ]] && echo "$OUT" | grep -q "\[FLAPPING\]"; then
  pass "exactly at threshold (3 transitions, -t 3): detected"
else
  fail "exactly at threshold (3 transitions, -t 3): detected" "exit=$EXITCODE\n$OUT"
fi

# 18. br-* bridge interfaces are silently filtered by default
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts 500) host kernel: br-abc123: NIC Link is Down
$(ts 400) host kernel: br-abc123: NIC Link is Up
$(ts 300) host kernel: br-abc123: NIC Link is Down
$(ts 200) host kernel: br-abc123: NIC Link is Up
$(ts 100) host kernel: br-abc123: NIC Link is Down
EOF
run "$t" -w 60 -t 3
if [[ $EXITCODE -eq 0 ]] && ! echo "$OUT" | grep -q "\[FLAPPING\]"; then
  pass "br-* bridge interface filtered by default"
else
  fail "br-* bridge interface filtered by default" "exit=$EXITCODE\n$OUT"
fi

# 19. tun0 and tap0 interfaces are silently filtered by default
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts 500) host kernel: tun0: NIC Link is Down
$(ts 450) host kernel: tun0: NIC Link is Up
$(ts 400) host kernel: tun0: NIC Link is Down
$(ts 350) host kernel: tun0: NIC Link is Up
$(ts 300) host kernel: tun0: NIC Link is Down
$(ts 200) host kernel: tap0: NIC Link is Down
$(ts 150) host kernel: tap0: NIC Link is Up
$(ts 100) host kernel: tap0: NIC Link is Down
$(ts  50) host kernel: tap0: NIC Link is Up
$(ts  10) host kernel: tap0: NIC Link is Down
EOF
run "$t" -w 60 -t 3
if [[ $EXITCODE -eq 0 ]] && ! echo "$OUT" | grep -q "\[FLAPPING\]"; then
  pass "tun0 and tap0 interfaces filtered by default"
else
  fail "tun0 and tap0 interfaces filtered by default" "exit=$EXITCODE\n$OUT"
fi

# 20. NM state change: alternating activated/deactivating → flap detected
#     Verifies the "-> word" last-arrow extraction and UP/DOWN mapping
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts 500) host NetworkManager[1]: <info> device (eth0): state change: disconnected -> activated
$(ts 400) host NetworkManager[1]: <info> device (eth0): state change: activated -> deactivating
$(ts 300) host NetworkManager[1]: <info> device (eth0): state change: deactivating -> disconnected -> config -> activated
$(ts 200) host NetworkManager[1]: <info> device (eth0): state change: activated -> deactivating
$(ts 100) host NetworkManager[1]: <info> device (eth0): state change: deactivating -> disconnected
EOF
run "$t" -w 60 -t 3
if [[ $EXITCODE -eq 1 ]] && echo "$OUT" | grep -q "\[FLAPPING\]"; then
  pass "NM state change: alternating activated/deactivating → flap detected"
else
  fail "NM state change: alternating activated/deactivating → flap detected" "exit=$EXITCODE\n$OUT"
fi

# 21. Malformed NM state change lines (no '->' arrow) produce no events
#     Verifies fix: arrow="" initialized each record, no state inherited from prior record
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts 200) host NetworkManager[1]: <info> device (eth0): state change: preparing
$(ts 100) host NetworkManager[1]: <info> device (eth1): state change: configuring
EOF
run "$t" -w 60
if [[ $EXITCODE -eq 0 ]] && echo "$OUT" | grep -q "No link state events found"; then
  pass "NM state change: lines with no '->' arrow produce no events"
else
  fail "NM state change: lines with no '->' arrow produce no events" "exit=$EXITCODE\n$OUT"
fi

# 22. NM state change: arrow pollution — valid record followed by malformed for same iface
#     Before the arrow="" fix, the malformed record would inherit the previous arrow value.
#     After the fix: malformed produces no event, so eth0 has 1 event → count<2 → skipped.
#     In both cases FLAPPING_FOUND=0, but only after the fix does the malformed line
#     NOT contribute a spurious event. We verify via total transition count in verbose mode.
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts 200) host NetworkManager[1]: <info> device (eth0): state change: disconnected -> activated
$(ts 100) host NetworkManager[1]: <info> device (eth0): state change: preparing
EOF
run "$t" -w 60 -v
# After fix: 1 real UP event, malformed produces nothing → count=1 → skipped
# → "No link state events found" or "No flapping detected" (both fine: exit 0)
# → verbose output does NOT show "2" events or a spurious duplicate
if [[ $EXITCODE -eq 0 ]] && ! echo "$OUT" | grep -qE "Events: [2-9]"; then
  pass "NM state change: malformed line after valid does not produce spurious event"
else
  fail "NM state change: malformed line after valid does not produce spurious event" "exit=$EXITCODE\n$OUT"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
TOTAL=$(( PASS + FAIL ))
echo ""
if [[ $FAIL -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}All ${TOTAL} tests passed.${RESET}"
  echo ""
  exit 0
else
  echo -e "${RED}${BOLD}${FAIL} of ${TOTAL} tests failed.${RESET}"
  echo ""
  exit 1
fi
