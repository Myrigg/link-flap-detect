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
