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
PASS=0; FAIL=0; SKIP=0
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
skip() { echo -e "  ${YELLOW}SKIP${RESET}  $1"; (( SKIP++ )) || true; }

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

# run_tshark TSHARK_DATA_FILE [SCRIPT_ARGS...]
# Injects pre-canned "epoch iface state" lines via _LINK_FLAP_TEST_TSHARK.
run_tshark() {
  local f="$1"; shift
  OUT=''; EXITCODE=0
  OUT=$(_LINK_FLAP_TEST_TSHARK="$f" bash "$SCRIPT" "$@" 2>&1) || EXITCODE=$?
}

# run_with_prom INPUT_FILE PROM_JSON_FILE [SCRIPT_ARGS...]
# Combines _LINK_FLAP_TEST_INPUT and _LINK_FLAP_TEST_PROM for Prometheus enrichment tests.
run_with_prom() {
  local input_f="$1" prom_f="$2"; shift 2
  OUT=''; EXITCODE=0
  OUT=$(_LINK_FLAP_TEST_INPUT="$input_f" _LINK_FLAP_TEST_PROM="$prom_f" \
        bash "$SCRIPT" "$@" 2>&1) || EXITCODE=$?
}

# run_tshark_with_prom TSHARK_DATA_FILE PROM_JSON_FILE [SCRIPT_ARGS...]
# Combines _LINK_FLAP_TEST_TSHARK and _LINK_FLAP_TEST_PROM.
run_tshark_with_prom() {
  local tshark_f="$1" prom_f="$2"; shift 2
  OUT=''; EXITCODE=0
  OUT=$(_LINK_FLAP_TEST_TSHARK="$tshark_f" _LINK_FLAP_TEST_PROM="$prom_f" \
        bash "$SCRIPT" "$@" 2>&1) || EXITCODE=$?
}

# run_wizard_test WIZARD_DIR [SCRIPT_ARGS...]
# Runs the diagnostic wizard with canned sysfs/command output files.
run_wizard_test() {
  local wiz_dir="$1"; shift
  OUT=''; EXITCODE=0
  OUT=$(BACKUP_DIR="$TESTDIR/backups" REPORT_DIR="$TESTDIR/reports" \
        _LINK_FLAP_TEST_WIZARD_DIR="$wiz_dir" \
        bash "$SCRIPT" "$@" 2>&1) || EXITCODE=$?
}

# run_rollback_test BACKUP_ID [SCRIPT_ARGS...]
# Runs rollback/list with BACKUP_DIR redirected to the test directory.
run_rollback_test() {
  local bid="$1"; shift
  OUT=''; EXITCODE=0
  OUT=$(BACKUP_DIR="$TESTDIR/backups" bash "$SCRIPT" -R "$bid" "$@" 2>&1) || EXITCODE=$?
}

# run_with_ne INPUT_FILE NE_METRICS_FILE [SCRIPT_ARGS...]
# Combines _LINK_FLAP_TEST_INPUT and _LINK_FLAP_TEST_NODE_EXPORTER for NE enrichment tests.
run_with_ne() {
  local input_f="$1" ne_f="$2"; shift 2
  OUT=''; EXITCODE=0
  OUT=$(_LINK_FLAP_TEST_INPUT="$input_f" _LINK_FLAP_TEST_NODE_EXPORTER="$ne_f" \
        bash "$SCRIPT" "$@" 2>&1) || EXITCODE=$?
}

# run_wizard_ne_test WIZARD_DIR NE_METRICS_FILE [SCRIPT_ARGS...]
# Runs the diagnostic wizard with canned sysfs/command output AND canned NE metrics.
run_wizard_ne_test() {
  local wiz_dir="$1" ne_f="$2"; shift 2
  OUT=''; EXITCODE=0
  OUT=$(BACKUP_DIR="$TESTDIR/backups" REPORT_DIR="$TESTDIR/reports" \
        _LINK_FLAP_TEST_WIZARD_DIR="$wiz_dir" \
        _LINK_FLAP_TEST_NODE_EXPORTER="$ne_f" \
        bash "$SCRIPT" "$@" 2>&1) || EXITCODE=$?
}

# run_with_iperf3 INPUT_FILE IPERF3_JSON [SCRIPT_ARGS...]
# Combines _LINK_FLAP_TEST_INPUT and _LINK_FLAP_TEST_IPERF3 for iperf3 enrichment tests.
run_with_iperf3() {
  local input_f="$1" iperf3_f="$2"; shift 2
  OUT=''; EXITCODE=0
  OUT=$(_LINK_FLAP_TEST_INPUT="$input_f" _LINK_FLAP_TEST_IPERF3="$iperf3_f" \
        bash "$SCRIPT" -3 test-server.example.com "$@" 2>&1) || EXITCODE=$?
}

# run_wizard_iperf3_test WIZARD_DIR IPERF3_JSON [SCRIPT_ARGS...]
# Runs the diagnostic wizard with canned sysfs/command output AND canned iperf3 JSON.
run_wizard_iperf3_test() {
  local wiz_dir="$1" iperf3_f="$2"; shift 2
  OUT=''; EXITCODE=0
  OUT=$(BACKUP_DIR="$TESTDIR/backups" REPORT_DIR="$TESTDIR/reports" \
        _LINK_FLAP_TEST_WIZARD_DIR="$wiz_dir" \
        _LINK_FLAP_TEST_IPERF3="$iperf3_f" \
        bash "$SCRIPT" -3 test-server.example.com "$@" 2>&1) || EXITCODE=$?
}

# run_real_wizard_test IFACE [SCRIPT_ARGS...]
# Runs the diagnostic wizard against a real interface — no sysfs/command mocking.
run_real_wizard_test() {
  local iface="$1"; shift
  OUT=''; EXITCODE=0
  OUT=$(BACKUP_DIR="$TESTDIR/real-backups" REPORT_DIR="$TESTDIR/real-reports" \
        bash "$SCRIPT" -d "$iface" "$@" 2>&1) || EXITCODE=$?
}

# ── Offline tests (1–37) ──────────────────────────────────────────────────────
# Entirely self-contained: all input is synthetic or canned. No journald, no
# syslog files, no sysfs, no ethtool. Safe to run in CI, containers, or on any
# machine — root not required.

echo ""
echo -e "${BOLD}link-flap-detect.sh — test suite${RESET}"
echo ""
echo -e "${BOLD}Offline tests${RESET} — synthetic data, no system dependencies"
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
if [[ $EXITCODE -eq 1 ]] \
   && echo "$OUT" | grep -q "\[FLAPPING\]" \
   && echo "$OUT" | grep -q "1 interface(s) flapping"; then
  pass "4 transitions ≥ threshold 3: exit 1, [FLAPPING] + summary count reported"
else
  fail "4 transitions ≥ threshold 3: exit 1, [FLAPPING] + summary count reported" "exit=$EXITCODE\n$OUT"
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
   && ! echo "$OUT" | grep -q "\[FLAPPING\].*eth1" \
   && echo "$OUT" | grep -q "1 interface(s) flapping"; then
  pass "multiple ifaces: only flapping eth0 reported; stable eth1 silent; summary count=1"
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

# 51. -f 0 is rejected (must be >= 1) → exit 1 + error
t=$(mktemp "$TESTDIR/XXXXXX.log"); : > "$t"
run "$t" -f 0
if [[ $EXITCODE -eq 1 ]] && echo "$OUT" | grep -qi "error"; then
  pass "51: invalid -f 0 → exit 1 + error message"
else
  fail "51: invalid -f 0 → exit 1 + error message" "exit=$EXITCODE\n$OUT"
fi

# 52. -f abc is rejected (non-numeric) → exit 1 + error
t=$(mktemp "$TESTDIR/XXXXXX.log"); : > "$t"
run "$t" -f abc
if [[ $EXITCODE -eq 1 ]] && echo "$OUT" | grep -qi "error"; then
  pass "52: invalid -f abc → exit 1 + error message"
else
  fail "52: invalid -f abc → exit 1 + error message" "exit=$EXITCODE\n$OUT"
fi

# 53. Empty log + -f 1 → "next scan" message appears; follow header shown
#     Use timeout(1) to break the infinite exec loop after 3s; exit 124 expected.
t=$(mktemp "$TESTDIR/XXXXXX.log"); : > "$t"
OUT=''; EXITCODE=0
OUT=$(timeout 3 bash -c "_LINK_FLAP_TEST_INPUT='$t' bash '$SCRIPT' -f 1 -w 60 2>&1") || EXITCODE=$?
if echo "$OUT" | grep -q "next scan in 1s" && echo "$OUT" | grep -q "Follow:"; then
  pass "53: follow mode (-f 1): header and 'next scan' message appear"
else
  fail "53: follow mode (-f 1): header and 'next scan' message appear" "exit=$EXITCODE\n$OUT"
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

# ── Offline tests (23–28): synthetic tshark/pcap data ────────────────────────
# These tests mock tshark output using _LINK_FLAP_TEST_TSHARK. tshark need not
# be installed — the test injects pre-canned "epoch iface state" lines directly.

# 23. STP: 4 TCN events on stp-aabb → 3 transitions ≥ threshold 3 → exit 1, [FLAPPING]
t=$(mktemp "$TESTDIR/XXXXXX.dat")
cat > "$t" <<EOF
1709386700 stp-aabb DOWN
1709386760 stp-aabb UP
1709386820 stp-aabb DOWN
1709386880 stp-aabb UP
EOF
run_tshark "$t" -w 60 -t 3
if [[ $EXITCODE -eq 1 ]] && echo "$OUT" | grep -q "\[FLAPPING\]"; then
  pass "tshark STP: 4 TCN events → stp-aabb flapping detected"
else
  fail "tshark STP: 4 TCN events → stp-aabb flapping detected" "exit=$EXITCODE\n$OUT"
fi

# 24. STP: 2 TCN events → 1 transition < threshold 3 → exit 0
t=$(mktemp "$TESTDIR/XXXXXX.dat")
cat > "$t" <<EOF
1709386700 stp-aabb DOWN
1709386760 stp-aabb UP
EOF
run_tshark "$t" -w 60 -t 3
if [[ $EXITCODE -eq 0 ]] && ! echo "$OUT" | grep -q "\[FLAPPING\]"; then
  pass "tshark STP: 2 TCN events → below threshold, no flapping"
else
  fail "tshark STP: 2 TCN events → below threshold, no flapping" "exit=$EXITCODE\n$OUT"
fi

# 25. LACP: alternating sync/desync on lacp-ccdd → flapping detected
t=$(mktemp "$TESTDIR/XXXXXX.dat")
cat > "$t" <<EOF
1709386700 lacp-ccdd DOWN
1709386760 lacp-ccdd UP
1709386820 lacp-ccdd DOWN
1709386880 lacp-ccdd UP
EOF
run_tshark "$t" -w 60 -t 3
if [[ $EXITCODE -eq 1 ]] && echo "$OUT" | grep -q "\[FLAPPING\]"; then
  pass "tshark LACP: alternating sync/desync → lacp-ccdd flapping detected"
else
  fail "tshark LACP: alternating sync/desync → lacp-ccdd flapping detected" "exit=$EXITCODE\n$OUT"
fi

# 26. LACP: all UP (no state change) → exit 0, no flapping
t=$(mktemp "$TESTDIR/XXXXXX.dat")
cat > "$t" <<EOF
1709386700 lacp-ccdd UP
1709386760 lacp-ccdd UP
1709386820 lacp-ccdd UP
1709386880 lacp-ccdd UP
EOF
run_tshark "$t" -w 60 -t 3
if [[ $EXITCODE -eq 0 ]] && ! echo "$OUT" | grep -q "\[FLAPPING\]"; then
  pass "tshark LACP: all UP → no state transitions, no flapping"
else
  fail "tshark LACP: all UP → no state transitions, no flapping" "exit=$EXITCODE\n$OUT"
fi

# 27. Interface filter -i stp-aabb: stp-aabb flaps, lacp-ccdd does not match → exit 1
t=$(mktemp "$TESTDIR/XXXXXX.dat")
cat > "$t" <<EOF
1709386700 stp-aabb DOWN
1709386760 stp-aabb UP
1709386820 stp-aabb DOWN
1709386880 stp-aabb UP
1709386700 lacp-ccdd DOWN
1709386760 lacp-ccdd UP
1709386820 lacp-ccdd DOWN
1709386880 lacp-ccdd UP
EOF
run_tshark "$t" -w 60 -t 3 -i stp-aabb
if [[ $EXITCODE -eq 1 ]] \
   && echo "$OUT" | grep -q "\[FLAPPING\].*stp-aabb" \
   && ! echo "$OUT" | grep -q "lacp-ccdd"; then
  pass "tshark -i stp-aabb filter: only stp-aabb reported, lacp-ccdd excluded"
else
  fail "tshark -i stp-aabb filter: only stp-aabb reported, lacp-ccdd excluded" "exit=$EXITCODE\n$OUT"
fi

# 28. Mixed STP + LACP: both interfaces flap independently → exit 1, 2 [FLAPPING] lines
t=$(mktemp "$TESTDIR/XXXXXX.dat")
cat > "$t" <<EOF
1709386700 stp-aabb DOWN
1709386760 stp-aabb UP
1709386820 stp-aabb DOWN
1709386880 stp-aabb UP
1709386700 lacp-ccdd DOWN
1709386760 lacp-ccdd UP
1709386820 lacp-ccdd DOWN
1709386880 lacp-ccdd UP
EOF
run_tshark "$t" -w 60 -t 3
flap_count=$(echo "$OUT" | grep -c "\[FLAPPING\]" || true)
if [[ $EXITCODE -eq 1 ]] && [[ "$flap_count" -eq 2 ]]; then
  pass "tshark mixed STP+LACP: both stp-aabb and lacp-ccdd reported as flapping"
else
  fail "tshark mixed STP+LACP: both stp-aabb and lacp-ccdd reported as flapping" "exit=$EXITCODE flap_count=$flap_count\n$OUT"
fi

# ── Offline tests (29–31): synthetic Prometheus API responses ────────────────
# Tests mock the Prometheus API response via _LINK_FLAP_TEST_PROM. No real
# Prometheus server needed. Two canned response files are created per run.

PROM_DATA=$(mktemp "$TESTDIR/prom-data-XXXXXX.json")
PROM_EMPTY=$(mktemp "$TESTDIR/prom-empty-XXXXXX.json")
echo '{"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[1709386700,"1"]}]}}' > "$PROM_DATA"
echo '{"status":"success","data":{"resultType":"vector","result":[]}}' > "$PROM_EMPTY"

# 29. eth0 flapping + canned Prometheus data → [Prometheus] block with "Current state"
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts 500) host kernel: eth0: NIC Link is Down
$(ts 400) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 300) host kernel: eth0: NIC Link is Down
$(ts 200) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 100) host kernel: eth0: NIC Link is Down
EOF
run_with_prom "$t" "$PROM_DATA" -w 60 -t 3 -m http://prom:9090
if [[ $EXITCODE -eq 1 ]] \
   && echo "$OUT" | grep -q "\[FLAPPING\]" \
   && echo "$OUT" | grep -q "\[Prometheus\]" \
   && echo "$OUT" | grep -q "Current state"; then
  pass "Prometheus enrichment: flapping eth0 shows [Prometheus] block with current state"
else
  fail "Prometheus enrichment: flapping eth0 shows [Prometheus] block with current state" "exit=$EXITCODE\n$OUT"
fi

# 30. eth0 flapping + empty Prometheus result → no [Prometheus] section
run_with_prom "$t" "$PROM_EMPTY" -w 60 -t 3 -m http://prom:9090
if [[ $EXITCODE -eq 1 ]] \
   && echo "$OUT" | grep -q "\[FLAPPING\]" \
   && ! echo "$OUT" | grep -q "\[Prometheus\]"; then
  pass "Prometheus enrichment: empty result → no [Prometheus] section shown"
else
  fail "Prometheus enrichment: empty result → no [Prometheus] section shown" "exit=$EXITCODE\n$OUT"
fi

# 31. stp-aabb flapping + canned Prometheus data → [Prometheus] skipped (synthetic iface)
t=$(mktemp "$TESTDIR/XXXXXX.dat")
cat > "$t" <<EOF
1709386700 stp-aabb DOWN
1709386760 stp-aabb UP
1709386820 stp-aabb DOWN
1709386880 stp-aabb UP
EOF
run_tshark_with_prom "$t" "$PROM_DATA" -w 60 -t 3 -m http://prom:9090
if [[ $EXITCODE -eq 1 ]] \
   && echo "$OUT" | grep -q "\[FLAPPING\]" \
   && ! echo "$OUT" | grep -q "\[Prometheus\]"; then
  pass "Prometheus enrichment: synthetic stp-* iface → [Prometheus] block skipped"
else
  fail "Prometheus enrichment: synthetic stp-* iface → [Prometheus] block skipped" "exit=$EXITCODE\n$OUT"
fi

# ── Offline tests (32–37): canned sysfs/command data, backup/wizard logic ────

# 32. Wizard creates backup dir and a subdirectory inside it
wiz_dir=$(mktemp -d "$TESTDIR/wiz-XXXXXX")
echo "up" > "$wiz_dir/operstate"
run_wizard_test "$wiz_dir" -d eth0 -w 60
backup_count=$(ls -1 "$TESTDIR/backups" 2>/dev/null | wc -l)
if [[ $EXITCODE -eq 0 ]] && [[ -d "$TESTDIR/backups" ]] && [[ "$backup_count" -gt 0 ]]; then
  pass "wizard: creates backup dir with at least one backup subdirectory"
else
  fail "wizard: creates backup dir with at least one backup subdirectory" "exit=$EXITCODE backups=$backup_count\n$OUT"
fi

# 33. -R list shows available backups
mkdir -p "$TESTDIR/backups/20240101-000000-eth0"
printf '%s\n' "iface=eth0" "ts=20240101-000000" "files=" \
  > "$TESTDIR/backups/20240101-000000-eth0/.manifest"
run_rollback_test "list"
if [[ $EXITCODE -eq 0 ]] && echo "$OUT" | grep -q "20240101-000000-eth0"; then
  pass "rollback: -R list shows available backups"
else
  fail "rollback: -R list shows available backups" "exit=$EXITCODE\n$OUT"
fi

# 34. -R nonexistent-id → exit 1 + "not found"
run_rollback_test "nonexistent-backup-id-xyz"
if [[ $EXITCODE -eq 1 ]] && echo "$OUT" | grep -qi "not found"; then
  pass "rollback: -R nonexistent-id → exit 1 + 'not found'"
else
  fail "rollback: -R nonexistent-id → exit 1 + 'not found'" "exit=$EXITCODE\n$OUT"
fi

# 35. EEE enabled → [CAUSE] + "EEE" in output
wiz_dir=$(mktemp -d "$TESTDIR/wiz-XXXXXX")
echo "EEE status: enabled" > "$wiz_dir/ethtool_eee"
run_wizard_test "$wiz_dir" -d eth0 -w 60
if [[ $EXITCODE -eq 0 ]] && echo "$OUT" | grep -q "\[CAUSE\]" \
   && echo "$OUT" | grep -qi "EEE"; then
  pass "wizard: EEE enabled → [CAUSE] with 'EEE' in output"
else
  fail "wizard: EEE enabled → [CAUSE] with 'EEE' in output" "exit=$EXITCODE\n$OUT"
fi

# 36. power/control=auto → [CAUSE] + "power" in output
wiz_dir=$(mktemp -d "$TESTDIR/wiz-XXXXXX")
echo "auto" > "$wiz_dir/power_control"
run_wizard_test "$wiz_dir" -d eth0 -w 60
if [[ $EXITCODE -eq 0 ]] && echo "$OUT" | grep -q "\[CAUSE\]" \
   && echo "$OUT" | grep -qi "power"; then
  pass "wizard: power/control=auto → [CAUSE] with 'power' in output"
else
  fail "wizard: power/control=auto → [CAUSE] with 'power' in output" "exit=$EXITCODE\n$OUT"
fi

# 37. High carrier changes (50) → [WARN] in output
wiz_dir=$(mktemp -d "$TESTDIR/wiz-XXXXXX")
echo "50" > "$wiz_dir/carrier_changes"
run_wizard_test "$wiz_dir" -d eth0 -w 60
if [[ $EXITCODE -eq 0 ]] && echo "$OUT" | grep -q "\[WARN\]"; then
  pass "wizard: carrier_changes=50 → [WARN] in output"
else
  fail "wizard: carrier_changes=50 → [WARN] in output" "exit=$EXITCODE\n$OUT"
fi

# ── Offline tests (42–45): synthetic node_exporter metrics ───────────────────
# Uses _LINK_FLAP_TEST_NODE_EXPORTER to inject canned Prometheus text-format responses.
# No real node_exporter or network access required.

# Shared canned node_exporter metrics file for tests 42–44
NE_CANNED=$(mktemp "$TESTDIR/ne-XXXXXX.txt")
cat > "$NE_CANNED" <<'EOF'
# HELP node_network_up Value is 1 if operstate is 'up', 0 otherwise.
node_network_up{device="eth0"} 1
node_network_carrier_changes_total{device="eth0"} 5
node_network_receive_errs_total{device="eth0"} 0
node_network_transmit_errs_total{device="eth0"} 0
node_network_receive_drop_total{device="eth0"} 0
node_network_transmit_drop_total{device="eth0"} 0
EOF

# 42. eth0 flapping + canned NE data → [node_exporter] block shown
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts 500) host kernel: eth0: NIC Link is Down
$(ts 400) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 300) host kernel: eth0: NIC Link is Down
$(ts 200) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 100) host kernel: eth0: NIC Link is Down
EOF
run_with_ne "$t" "$NE_CANNED" -w 60 -t 3
if [[ $EXITCODE -eq 1 ]] \
   && echo "$OUT" | grep -q "\[FLAPPING\]" \
   && echo "$OUT" | grep -q "\[node_exporter\]"; then
  pass "42: node_exporter: flapping eth0 shows [node_exporter] block"
else
  fail "42: node_exporter: flapping eth0 shows [node_exporter] block" "exit=$EXITCODE\n$OUT"
fi

# 43. eth0 flapping + -e off → no [node_exporter] block (NE disabled)
run_with_ne "$t" "$NE_CANNED" -w 60 -t 3 -e off
if [[ $EXITCODE -eq 1 ]] \
   && echo "$OUT" | grep -q "\[FLAPPING\]" \
   && ! echo "$OUT" | grep -q "\[node_exporter\]"; then
  pass "43: node_exporter: -e off disables [node_exporter] block"
else
  fail "43: node_exporter: -e off disables [node_exporter] block" "exit=$EXITCODE\n$OUT"
fi

# 44. stp-* synthetic iface + canned NE data → [node_exporter] block skipped
t=$(mktemp "$TESTDIR/XXXXXX.dat")
cat > "$t" <<EOF
1709386700 stp-aabb DOWN
1709386760 stp-aabb UP
1709386820 stp-aabb DOWN
1709386880 stp-aabb UP
EOF
OUT=''; EXITCODE=0
OUT=$(_LINK_FLAP_TEST_TSHARK="$t" _LINK_FLAP_TEST_NODE_EXPORTER="$NE_CANNED" \
      bash "$SCRIPT" -w 60 -t 3 2>&1) || EXITCODE=$?
if [[ $EXITCODE -eq 1 ]] \
   && echo "$OUT" | grep -q "\[FLAPPING\]" \
   && ! echo "$OUT" | grep -q "\[node_exporter\]"; then
  pass "44: node_exporter: synthetic stp-* iface → [node_exporter] block skipped"
else
  fail "44: node_exporter: synthetic stp-* iface → [node_exporter] block skipped" "exit=$EXITCODE\n$OUT"
fi

# 45. Wizard with canned NE metrics showing rx_errors=10 → [WARN] + "RX errors" in output
NE_ERRORS=$(mktemp "$TESTDIR/ne-err-XXXXXX.txt")
cat > "$NE_ERRORS" <<'EOF'
node_network_up{device="eth0"} 1
node_network_receive_errs_total{device="eth0"} 10
node_network_transmit_errs_total{device="eth0"} 0
EOF
wiz_dir=$(mktemp -d "$TESTDIR/wiz-ne-XXXXXX")
echo "up" > "$wiz_dir/operstate"
run_wizard_ne_test "$wiz_dir" "$NE_ERRORS" -d eth0 -w 60
if [[ $EXITCODE -eq 0 ]] \
   && echo "$OUT" | grep -q "\[WARN\]" \
   && echo "$OUT" | grep -qi "RX errors"; then
  pass "45: node_exporter: wizard with rx_errors=10 → [WARN] with 'RX errors'"
else
  fail "45: node_exporter: wizard with rx_errors=10 → [WARN] with 'RX errors'" "exit=$EXITCODE\n$OUT"
fi

# ── Live system tests (38–41) ─────────────────────────────────────────────────
# These tests read from actual system sources — no synthetic log injection.
# They require root privileges and a running systemd (journald).
# Each test skips gracefully if its prerequisite is unavailable.

echo ""
echo -e "${BOLD}Live system tests${RESET} — reads journald, /var/log/syslog, and /sys/class/net on this machine"
echo ""

# Helper: find first non-virtual, non-loopback interface
_real_iface() {
  ip link show 2>/dev/null \
    | awk -F': ' '/^[0-9]/ && $2 !~ /^(lo|veth|virbr|docker|tun|tap|br-)/ {
        sub(/@.*/, "", $2); print $2; exit
      }'
}

# 38. Live journald code path — source label correct, output format valid
if ! command -v journalctl &>/dev/null; then
  skip "38: live journald scan (journalctl not available)"
else
  OUT=''; EXITCODE=0
  OUT=$(bash "$SCRIPT" -w 5 2>&1) || EXITCODE=$?
  if [[ $EXITCODE -le 1 ]] \
     && echo "$OUT" | grep -q "Link Flap Detector" \
     && echo "$OUT" | grep -q "journald" \
     && echo "$OUT" | grep -qE "No link state events found|No flapping detected|\[FLAPPING\]"; then
    pass "38: live journald — source=journald, valid output (exit=$EXITCODE)"
  else
    fail "38: live journald — source=journald, valid output" "exit=$EXITCODE\n$OUT"
  fi
fi

# 39. Real /var/log/syslog — parse entire file without crashing
if [[ ! -r /var/log/syslog ]]; then
  skip "39: real syslog parse (/var/log/syslog not readable)"
else
  line_count=$(wc -l < /var/log/syslog)
  OUT=''; EXITCODE=0
  OUT=$(_LINK_FLAP_TEST_INPUT=/var/log/syslog bash "$SCRIPT" -w 9999 2>&1) || EXITCODE=$?
  if [[ $EXITCODE -le 1 ]] && echo "$OUT" | grep -q "Link Flap Detector"; then
    pass "39: real /var/log/syslog (${line_count} lines) parsed without error (exit=$EXITCODE)"
  else
    fail "39: real /var/log/syslog parsed without error" "exit=$EXITCODE lines=$line_count\n$OUT"
  fi
fi

# 40. Real wizard on a live interface — reads actual sysfs; report matches /sys/class/net/
REAL_IFACE=$(_real_iface)
if [[ -z "$REAL_IFACE" ]]; then
  skip "40: wizard on real interface (no physical interface found)"
else
  # Capture ground-truth values from sysfs before running the wizard
  real_operstate=$(cat "/sys/class/net/${REAL_IFACE}/operstate" 2>/dev/null || echo "")
  real_carrier_changes=$(cat "/sys/class/net/${REAL_IFACE}/carrier_changes" 2>/dev/null || echo "")

  run_real_wizard_test "$REAL_IFACE" -w 5
  report_count=$(ls -1 "$TESTDIR/real-reports" 2>/dev/null | wc -l)
  backup_count=$(ls -1 "$TESTDIR/real-backups" 2>/dev/null | wc -l)

  ok=1
  [[ $EXITCODE -eq 0 ]]                              || ok=0
  echo "$OUT" | grep -q "Diagnostic Report"          || ok=0
  [[ $backup_count -gt 0 ]]                          || ok=0
  [[ $report_count -gt 0 ]]                          || ok=0
  # Verify the wizard read real sysfs: carrier_changes value must appear in output
  if [[ -n "$real_carrier_changes" ]]; then
    echo "$OUT" | grep -q "carrier_changes.*:.*${real_carrier_changes}" || ok=0
  fi
  # operstate value must appear in output
  if [[ -n "$real_operstate" ]]; then
    echo "$OUT" | grep -q "operstate.*:.*${real_operstate}" || ok=0
  fi

  if [[ $ok -eq 1 ]]; then
    pass "40: wizard -d ${REAL_IFACE} reads real sysfs (operstate=${real_operstate}, carrier_changes=${real_carrier_changes})"
  else
    fail "40: wizard -d ${REAL_IFACE} reads real sysfs" \
      "exit=$EXITCODE backups=$backup_count reports=$report_count operstate=${real_operstate} carrier_changes=${real_carrier_changes}\n$OUT"
  fi
fi

# 41. Live journald with real interface filter — filter label shown, pipeline completes cleanly
REAL_IFACE=$(_real_iface)
if [[ -z "$REAL_IFACE" ]] || ! command -v journalctl &>/dev/null; then
  skip "41: live journald with -i filter (journalctl or physical interface unavailable)"
else
  OUT=''; EXITCODE=0
  OUT=$(bash "$SCRIPT" -w 5 -i "$REAL_IFACE" 2>&1) || EXITCODE=$?
  if [[ $EXITCODE -le 1 ]] \
     && echo "$OUT" | grep -q "Link Flap Detector" \
     && echo "$OUT" | grep -q "Interface filter" \
     && echo "$OUT" | grep -q "$REAL_IFACE"; then
    pass "41: live journald -i ${REAL_IFACE} — filter label present, exit=$EXITCODE"
  else
    fail "41: live journald -i ${REAL_IFACE} — filter label present" "exit=$EXITCODE\n$OUT"
  fi
fi

# 46. Live node_exporter probe — header shows "node_exporter:" if running at default URL
_NE_URL="${NODE_EXPORTER_URL:-http://localhost:9100}"
REAL_IFACE=$(_real_iface)
if [[ -z "$REAL_IFACE" ]]; then
  skip "46: live node_exporter probe (no physical interface found)"
elif ! curl -sf --max-time 3 "${_NE_URL}/metrics" &>/dev/null; then
  skip "46: live node_exporter probe (not running at ${_NE_URL})"
else
  OUT=''; EXITCODE=0
  OUT=$(bash "$SCRIPT" -w 5 -i "$REAL_IFACE" 2>&1) || EXITCODE=$?
  if [[ $EXITCODE -le 1 ]] && echo "$OUT" | grep -q "node_exporter"; then
    pass "46: live node_exporter — probed at ${_NE_URL}, shown in header (exit=$EXITCODE)"
  else
    fail "46: live node_exporter — probed at ${_NE_URL}, shown in header" "exit=$EXITCODE\n$OUT"
  fi
fi

# ── Offline tests (47–48): canned iperf3 JSON output ─────────────────────────
# Tests mock iperf3 via _LINK_FLAP_TEST_IPERF3. iperf3 need not be installed.

# 47. eth0 flapping + iperf3 data (retransmits=0, bps=943M) → [FLAPPING] + [iperf3] in output
IPERF3_CLEAN=$(mktemp "$TESTDIR/iperf3-clean-XXXXXX.json")
cat > "$IPERF3_CLEAN" <<'EOF'
{"end":{"sum_sent":{"bits_per_second":943000000,"retransmits":0}}}
EOF

t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts 500) host kernel: eth0: NIC Link is Down
$(ts 400) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 300) host kernel: eth0: NIC Link is Down
$(ts 200) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 100) host kernel: eth0: NIC Link is Down
EOF
run_with_iperf3 "$t" "$IPERF3_CLEAN" -w 60 -t 3
if [[ $EXITCODE -eq 1 ]] \
   && echo "$OUT" | grep -q "\[FLAPPING\]" \
   && echo "$OUT" | grep -q "\[iperf3\]" \
   && echo "$OUT" | grep -q "943" \
   && echo "$OUT" | grep -q "Retransmits.*: 0"; then
  pass "47: iperf3 enrichment: flapping eth0 shows [iperf3] block, bandwidth 943, retransmits 0"
else
  fail "47: iperf3 enrichment: flapping eth0 shows [iperf3] block, bandwidth 943, retransmits 0" "exit=$EXITCODE\n$OUT"
fi

# 48. Wizard + retransmits=12, bps=450M → [WARN] + "retransmit" in output
IPERF3_RETRANS=$(mktemp "$TESTDIR/iperf3-retrans-XXXXXX.json")
cat > "$IPERF3_RETRANS" <<'EOF'
{"end":{"sum_sent":{"bits_per_second":450000000,"retransmits":12}}}
EOF

wiz_dir=$(mktemp -d "$TESTDIR/wiz-iperf3-XXXXXX")
echo "up" > "$wiz_dir/operstate"
run_wizard_iperf3_test "$wiz_dir" "$IPERF3_RETRANS" -d eth0 -w 60
if [[ $EXITCODE -eq 0 ]] \
   && echo "$OUT" | grep -q "\[WARN\]" \
   && echo "$OUT" | grep -qi "retransmit"; then
  pass "48: iperf3 wizard: retransmits=12 → [WARN] with 'retransmit' in output"
else
  fail "48: iperf3 wizard: retransmits=12 → [WARN] with 'retransmit' in output" "exit=$EXITCODE\n$OUT"
fi

# 49. Live iperf3 probe — always SKIP (no server available in automated suite)
skip "49: live iperf3 probe (no server available in automated suite)"

# 50. stp-aabb flapping + iperf3 data → [FLAPPING] present, [iperf3] block skipped (synthetic iface)
t=$(mktemp "$TESTDIR/XXXXXX.dat")
cat > "$t" <<EOF
1709386700 stp-aabb DOWN
1709386760 stp-aabb UP
1709386820 stp-aabb DOWN
1709386880 stp-aabb UP
EOF
OUT=''; EXITCODE=0
OUT=$(_LINK_FLAP_TEST_TSHARK="$t" _LINK_FLAP_TEST_IPERF3="$IPERF3_CLEAN" \
      bash "$SCRIPT" -3 test-server.example.com -w 60 -t 3 2>&1) || EXITCODE=$?
if [[ $EXITCODE -eq 1 ]] \
   && echo "$OUT" | grep -q "\[FLAPPING\]" \
   && ! echo "$OUT" | grep -q "\[iperf3\]"; then
  pass "50: iperf3: synthetic stp-* iface → [iperf3] block skipped"
else
  fail "50: iperf3: synthetic stp-* iface → [iperf3] block skipped" "exit=$EXITCODE\n$OUT"
fi

# ── Offline tests (54–56): cross-interface correlation ───────────────────────

# 54. eth0 + eth1 both flapping with overlapping epochs → [CORRELATED] in output
t=$(mktemp "$TESTDIR/XXXXXX.log")
# Use fixed epochs so eth0 and eth1 events fall in the same 10-second bucket
BASE=$(( $(date +%s) - 300 ))
cat > "$t" <<EOF
$(date -d "@$(( BASE ))"     "+%Y-%m-%dT%H:%M:%S+0000") host kernel: eth0: NIC Link is Down
$(date -d "@$(( BASE + 2 ))" "+%Y-%m-%dT%H:%M:%S+0000") host kernel: eth1: NIC Link is Down
$(date -d "@$(( BASE + 4 ))" "+%Y-%m-%dT%H:%M:%S+0000") host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(date -d "@$(( BASE + 6 ))" "+%Y-%m-%dT%H:%M:%S+0000") host kernel: eth1: NIC Link is Up 1000 Mbps Full Duplex
$(date -d "@$(( BASE + 8 ))" "+%Y-%m-%dT%H:%M:%S+0000") host kernel: eth0: NIC Link is Down
$(date -d "@$(( BASE + 10))" "+%Y-%m-%dT%H:%M:%S+0000") host kernel: eth1: NIC Link is Down
$(date -d "@$(( BASE + 12))" "+%Y-%m-%dT%H:%M:%S+0000") host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(date -d "@$(( BASE + 14))" "+%Y-%m-%dT%H:%M:%S+0000") host kernel: eth1: NIC Link is Up 1000 Mbps Full Duplex
EOF
run "$t" -w 60 -t 3
if [[ $EXITCODE -eq 1 ]] \
   && echo "$OUT" | grep -q "\[CORRELATED\]"; then
  pass "54: two ifaces flapping simultaneously → [CORRELATED] shown"
else
  fail "54: two ifaces flapping simultaneously → [CORRELATED] shown" "exit=$EXITCODE\n$OUT"
fi

# 55. eth0 + eth1 both flapping but events 90s apart → no [CORRELATED]
t=$(mktemp "$TESTDIR/XXXXXX.log")
BASE=$(( $(date +%s) - 600 ))
cat > "$t" <<EOF
$(date -d "@$(( BASE ))"     "+%Y-%m-%dT%H:%M:%S+0000") host kernel: eth0: NIC Link is Down
$(date -d "@$(( BASE + 2 ))" "+%Y-%m-%dT%H:%M:%S+0000") host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(date -d "@$(( BASE + 4 ))" "+%Y-%m-%dT%H:%M:%S+0000") host kernel: eth0: NIC Link is Down
$(date -d "@$(( BASE + 6 ))" "+%Y-%m-%dT%H:%M:%S+0000") host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(date -d "@$(( BASE + 90))" "+%Y-%m-%dT%H:%M:%S+0000") host kernel: eth1: NIC Link is Down
$(date -d "@$(( BASE + 92))" "+%Y-%m-%dT%H:%M:%S+0000") host kernel: eth1: NIC Link is Up 1000 Mbps Full Duplex
$(date -d "@$(( BASE + 94))" "+%Y-%m-%dT%H:%M:%S+0000") host kernel: eth1: NIC Link is Down
$(date -d "@$(( BASE + 96))" "+%Y-%m-%dT%H:%M:%S+0000") host kernel: eth1: NIC Link is Up 1000 Mbps Full Duplex
EOF
run "$t" -w 60 -t 3
if [[ $EXITCODE -eq 1 ]] \
   && ! echo "$OUT" | grep -q "\[CORRELATED\]"; then
  pass "55: two ifaces flapping but 90s apart → no [CORRELATED]"
else
  fail "55: two ifaces flapping but 90s apart → no [CORRELATED]" "exit=$EXITCODE\n$OUT"
fi

# 56. Only one interface flapping → no [CORRELATED] (guard: FLAPPING_COUNT < 2)
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts 500) host kernel: eth0: NIC Link is Down
$(ts 400) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 300) host kernel: eth0: NIC Link is Down
$(ts 200) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 100) host kernel: eth0: NIC Link is Down
EOF
run "$t" -w 60 -t 3
if [[ $EXITCODE -eq 1 ]] \
   && ! echo "$OUT" | grep -q "\[CORRELATED\]"; then
  pass "56: single interface flapping → no [CORRELATED]"
else
  fail "56: single interface flapping → no [CORRELATED]" "exit=$EXITCODE\n$OUT"
fi

# 57. Wizard summary includes "Verify" re-run hint
wiz_dir=$(mktemp -d "$TESTDIR/wiz-verify-XXXXXX")
echo "up" > "$wiz_dir/operstate"
run_wizard_test "$wiz_dir" -d eth0 -w 60
if [[ $EXITCODE -eq 0 ]] && echo "$OUT" | grep -q "Verify"; then
  pass "57: wizard summary includes 'Verify' re-run hint"
else
  fail "57: wizard summary includes 'Verify' re-run hint" "exit=$EXITCODE\n$OUT"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
TOTAL=$(( PASS + FAIL ))
echo ""
if [[ $FAIL -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}All ${TOTAL} tests passed.${RESET}"
  [[ $SKIP -gt 0 ]] && echo -e "  ${YELLOW}(${SKIP} skipped — prerequisites not available on this system)${RESET}"
  echo ""
  exit 0
else
  echo -e "${RED}${BOLD}${FAIL} of ${TOTAL} tests failed.${RESET}"
  [[ $SKIP -gt 0 ]] && echo -e "  ${YELLOW}(${SKIP} skipped — prerequisites not available on this system)${RESET}"
  echo ""
  exit 1
fi
