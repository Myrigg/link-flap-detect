#!/usr/bin/env bash
# tests/test-iperf3.sh
# Automated tests: iperf3 bandwidth enrichment — verifies that flap output
# includes an [iperf3] context block with bandwidth and retransmit data, that the
# wizard raises a [WARN] finding for non-zero retransmits, and that the block is
# correctly suppressed for synthetic (stp-*/lacp-*) interfaces.
#
# Tests covered: 47–50
#
# iperf3 results are mocked via _LINK_FLAP_TEST_IPERF3. iperf3 does not need to
# be installed. Test 49 always skips (no server available in automated runs).
# Safe to run in CI, containers, or any machine — root not required.
#
# Usage (standalone):  bash tests/test-iperf3.sh
# Usage (via runner):  sourced by tests/run-tests.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo ""
echo -e "${BOLD}Offline tests — iperf3 bandwidth enrichment${RESET}"
echo ""

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
   && echo "$OUT" | grep -qi "retransmit" \
   && echo "$OUT" | grep -qi "bandwidth"; then
  pass "48: iperf3 wizard: retransmits=12 → [WARN] with 'retransmit' + bandwidth in output"
else
  fail "48: iperf3 wizard: retransmits=12 → [WARN] with 'retransmit' + bandwidth in output" "exit=$EXITCODE\n$OUT"
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
OUT=$(XDG_CONFIG_HOME="$TESTDIR/cfg-iperf3" \
      _LINK_FLAP_TEST_TSHARK="$t" _LINK_FLAP_TEST_IPERF3="$IPERF3_CLEAN" \
      bash "$SCRIPT" -b test-server.example.com -w 60 -t 3 2>&1) || EXITCODE=$?
if [[ $EXITCODE -eq 1 ]] \
   && echo "$OUT" | grep -q "\[FLAPPING\]" \
   && ! echo "$OUT" | grep -q "\[iperf3\]"; then
  pass "50: iperf3: synthetic stp-* iface → [iperf3] block skipped"
else
  fail "50: iperf3: synthetic stp-* iface → [iperf3] block skipped" "exit=$EXITCODE\n$OUT"
fi
