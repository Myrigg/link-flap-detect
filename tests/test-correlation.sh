#!/usr/bin/env bash
# tests/test-correlation.sh
# Automated tests: cross-interface correlation — verifies that [CORRELATED] is
# shown when two or more interfaces have flap events within the same 10-second
# window (indicating a shared upstream cause), and suppressed when events are
# temporally separated or only one interface is flapping.
#
# Tests covered: 54–56
#
# All input is synthetic. Safe to run in CI, containers, or any machine.
#
# Usage (standalone):  bash tests/test-correlation.sh
# Usage (via runner):  sourced by tests/run-tests.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo ""
echo -e "${BOLD}Offline tests — cross-interface correlation${RESET}"
echo ""

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
