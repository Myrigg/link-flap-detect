#!/usr/bin/env bash
# tests/test-node-exporter.sh
# Automated tests: node_exporter metric enrichment — verifies that flap output
# includes a [node_exporter] context block when metrics are available, that -n off
# disables it, that synthetic (stp-*/lacp-*) interfaces are correctly skipped,
# and that the wizard reports RX error findings from node_exporter data.
#
# Tests covered: 42–45
#
# node_exporter responses are mocked via _LINK_FLAP_TEST_NODE_EXPORTER.
# No real node_exporter or network access required.
# Safe to run in CI, containers, or any machine — root not required.
#
# Usage (standalone):  bash tests/test-node-exporter.sh
# Usage (via runner):  sourced by tests/run-tests.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo ""
echo -e "${BOLD}Offline tests — node_exporter metric enrichment${RESET}"
echo ""

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

# 43. eth0 flapping + -n off → no [node_exporter] block (NE disabled)
run_with_ne "$t" "$NE_CANNED" -w 60 -t 3 -n off
if [[ $EXITCODE -eq 1 ]] \
   && echo "$OUT" | grep -q "\[FLAPPING\]" \
   && ! echo "$OUT" | grep -q "\[node_exporter\]"; then
  pass "43: node_exporter: -n off disables [node_exporter] block"
else
  fail "43: node_exporter: -n off disables [node_exporter] block" "exit=$EXITCODE\n$OUT"
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
