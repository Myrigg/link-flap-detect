#!/usr/bin/env bash
# tests/test-prometheus.sh
# Automated tests: Prometheus metric enrichment — verifies that flap output
# includes a [Prometheus] context block when a Prometheus API response is
# available, and correctly suppresses it for synthetic (stp-*/lacp-*) interfaces
# or when no data is returned.
#
# Tests covered: 29–31, 62–63
#
# Prometheus API calls are mocked via _LINK_FLAP_TEST_PROM. No real Prometheus
# server needed. Safe to run in CI, containers, or any machine.
#
# Usage (standalone):  bash tests/test-prometheus.sh
# Usage (via runner):  sourced by tests/run-tests.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo ""
echo -e "${BOLD}Offline tests — Prometheus metric enrichment${RESET}"
echo ""

# Shared canned Prometheus API responses
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
  pass "29: Prometheus enrichment: flapping eth0 shows [Prometheus] block with current state"
else
  fail "29: Prometheus enrichment: flapping eth0 shows [Prometheus] block with current state" "exit=$EXITCODE\n$OUT"
fi

# 30. eth0 flapping + empty Prometheus result → no [Prometheus] section
run_with_prom "$t" "$PROM_EMPTY" -w 60 -t 3 -m http://prom:9090
if [[ $EXITCODE -eq 1 ]] \
   && echo "$OUT" | grep -q "\[FLAPPING\]" \
   && ! echo "$OUT" | grep -q "\[Prometheus\]"; then
  pass "30: Prometheus enrichment: empty result → no [Prometheus] section shown"
else
  fail "30: Prometheus enrichment: empty result → no [Prometheus] section shown" "exit=$EXITCODE\n$OUT"
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
  pass "31: Prometheus enrichment: synthetic stp-* iface → [Prometheus] block skipped"
else
  fail "31: Prometheus enrichment: synthetic stp-* iface → [Prometheus] block skipped" "exit=$EXITCODE\n$OUT"
fi

# 62. Prometheus set but unreachable → dim note "returned no data" in output
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts 500) host kernel: eth0: NIC Link is Down
$(ts 400) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 300) host kernel: eth0: NIC Link is Down
$(ts 200) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 100) host kernel: eth0: NIC Link is Down
EOF
OUT=''; EXITCODE=0
OUT=$(_LINK_FLAP_TEST_INPUT="$t" bash "$SCRIPT" -w 60 -t 3 \
      -m http://127.0.0.1:19999 2>&1) || EXITCODE=$?
if [[ $EXITCODE -eq 1 ]] \
   && echo "$OUT" | grep -q "\[FLAPPING\]" \
   && echo "$OUT" | grep -q "returned no data"; then
  pass "62: Prometheus unreachable → dim 'returned no data' note in output"
else
  fail "62: Prometheus unreachable → dim 'returned no data' note in output" "exit=$EXITCODE\n$OUT"
fi

# 63. Prometheus reachable but empty result → "no network metrics found" (not "verify connectivity")
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts 500) host kernel: eth0: NIC Link is Down
$(ts 400) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 300) host kernel: eth0: NIC Link is Down
$(ts 200) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 100) host kernel: eth0: NIC Link is Down
EOF
run_with_prom "$t" "$PROM_EMPTY" -w 60 -t 3 -m http://prom:9090
if [[ $EXITCODE -eq 1 ]] \
   && echo "$OUT" | grep -q "\[FLAPPING\]" \
   && echo "$OUT" | grep -qi "no network metrics found" \
   && ! echo "$OUT" | grep -q "verify connectivity"; then
  pass "63: Prometheus connected, empty result → 'no network metrics found' (not 'verify connectivity')"
else
  fail "63: Prometheus connected, empty result → 'no network metrics found' (not 'verify connectivity')" "exit=$EXITCODE\n$OUT"
fi
