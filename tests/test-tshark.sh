#!/usr/bin/env bash
# tests/test-tshark.sh
# Automated tests: tshark/pcap analysis — STP topology-change notifications and
# LACP synchronisation state changes detected from packet captures.
#
# Tests covered: 23–28
#
# All input is synthetic ("epoch iface state" lines injected via
# _LINK_FLAP_TEST_TSHARK). tshark does not need to be installed.
# Safe to run in CI, containers, or any machine — root not required.
#
# Usage (standalone):  bash tests/test-tshark.sh
# Usage (via runner):  sourced by tests/run-tests.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo ""
echo -e "${BOLD}Offline tests — tshark / packet-capture analysis${RESET}"
echo ""

# ── STP topology-change notifications ─────────────────────────────────────────

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
  pass "23: tshark STP: 4 TCN events → stp-aabb flapping detected"
else
  fail "23: tshark STP: 4 TCN events → stp-aabb flapping detected" "exit=$EXITCODE\n$OUT"
fi

# 24. STP: 2 TCN events → 1 transition < threshold 3 → exit 0
t=$(mktemp "$TESTDIR/XXXXXX.dat")
cat > "$t" <<EOF
1709386700 stp-aabb DOWN
1709386760 stp-aabb UP
EOF
run_tshark "$t" -w 60 -t 3
if [[ $EXITCODE -eq 0 ]] && ! echo "$OUT" | grep -q "\[FLAPPING\]"; then
  pass "24: tshark STP: 2 TCN events → below threshold, no flapping"
else
  fail "24: tshark STP: 2 TCN events → below threshold, no flapping" "exit=$EXITCODE\n$OUT"
fi

# ── LACP synchronisation state changes ────────────────────────────────────────

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
  pass "25: tshark LACP: alternating sync/desync → lacp-ccdd flapping detected"
else
  fail "25: tshark LACP: alternating sync/desync → lacp-ccdd flapping detected" "exit=$EXITCODE\n$OUT"
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
  pass "26: tshark LACP: all UP → no state transitions, no flapping"
else
  fail "26: tshark LACP: all UP → no state transitions, no flapping" "exit=$EXITCODE\n$OUT"
fi

# ── Interface filtering with tshark data ──────────────────────────────────────

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
  pass "27: tshark -i stp-aabb filter: only stp-aabb reported, lacp-ccdd excluded"
else
  fail "27: tshark -i stp-aabb filter: only stp-aabb reported, lacp-ccdd excluded" "exit=$EXITCODE\n$OUT"
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
  pass "28: tshark mixed STP+LACP: both stp-aabb and lacp-ccdd reported as flapping"
else
  fail "28: tshark mixed STP+LACP: both stp-aabb and lacp-ccdd reported as flapping" "exit=$EXITCODE flap_count=$flap_count\n$OUT"
fi
