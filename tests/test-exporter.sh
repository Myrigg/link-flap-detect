#!/usr/bin/env bash
# tests/test-exporter.sh
# Automated tests: Prometheus exporter mode (--export).
#
# Tests covered: 140–143
#
# Verifies:
#   - --export writes Prometheus textfile format
#   - Flapping interface appears with is_flapping=1
#   - Transition count matches
#   - No flapping → file has timestamp but no is_flapping lines
#
# Usage (standalone):  bash tests/test-exporter.sh
# Usage (via runner):  sourced by tests/run-tests.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Clear any leaked config from prior test suites
rm -rf "${XDG_CONFIG_HOME:-$TESTDIR/xdg}/link-flap"

echo ""
echo -e "${BOLD}Offline tests — Prometheus exporter mode${RESET}"
echo ""

# Reusable flapping log (4 transitions for eth0)
_exp_input=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$_exp_input" <<EOF
$(ts 500) host kernel: eth0: NIC Link is Down
$(ts 400) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 300) host kernel: eth0: NIC Link is Down
$(ts 200) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 100) host kernel: eth0: NIC Link is Down
EOF

# No-flap input (2 transitions, below threshold of 3)
_exp_noflap=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$_exp_noflap" <<EOF
$(ts 500) host kernel: eth0: NIC Link is Down
$(ts 400) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
EOF

# ── 140: --export writes Prometheus textfile format ──────────────────────────
_metrics="$TESTDIR/metrics-140.prom"
rm -f "$_metrics"
OUT=''; EXITCODE=0
OUT=$(_LINK_FLAP_TEST_INPUT="$_exp_input" \
      bash "$SCRIPT" -w 60 --export "$_metrics" 2>&1) || EXITCODE=$?
if [[ -f "$_metrics" ]] \
   && grep -q "^# HELP link_flap" "$_metrics" \
   && grep -q "^# TYPE link_flap" "$_metrics" \
   && grep -q "link_flap_last_scan_timestamp" "$_metrics"; then
  pass "140: --export writes valid Prometheus textfile format"
else
  fail "140: --export writes valid Prometheus textfile format" \
       "exit=$EXITCODE file=$(cat "$_metrics" 2>/dev/null || echo 'NO FILE')"
fi

# ── 141: Flapping interface has is_flapping=1 ────────────────────────────────
if grep -q 'link_flap_is_flapping{interface="eth0"} 1' "$_metrics" 2>/dev/null; then
  pass "141: Flapping interface eth0 has is_flapping=1"
else
  fail "141: Flapping interface eth0 has is_flapping=1" \
       "$(cat "$_metrics" 2>/dev/null || echo 'NO FILE')"
fi

# ── 142: Transition count matches ────────────────────────────────────────────
_t_count=$(grep 'link_flap_transitions_total{interface="eth0"}' "$_metrics" 2>/dev/null | awk '{print $2}')
if [[ "$_t_count" -ge 3 ]]; then
  pass "142: Transition count in metrics matches (${_t_count} >= 3)"
else
  fail "142: Transition count in metrics matches" \
       "count=$_t_count\n$(cat "$_metrics" 2>/dev/null)"
fi

# ── 143: No flapping → file has timestamp but no is_flapping lines ───────────
_metrics2="$TESTDIR/metrics-143.prom"
rm -f "$_metrics2"
OUT=''; EXITCODE=0
# shellcheck disable=SC2034
OUT=$(_LINK_FLAP_TEST_INPUT="$_exp_noflap" \
      bash "$SCRIPT" -w 60 --export "$_metrics2" 2>&1) || EXITCODE=$?
if [[ -f "$_metrics2" ]] \
   && grep -q "link_flap_last_scan_timestamp" "$_metrics2" \
   && ! grep -q '^link_flap_is_flapping{' "$_metrics2"; then
  pass "143: No flapping → metrics file has timestamp but no is_flapping"
else
  fail "143: No flapping → metrics file has timestamp but no is_flapping" \
       "exit=$EXITCODE\n$(cat "$_metrics2" 2>/dev/null || echo 'NO FILE')"
fi
