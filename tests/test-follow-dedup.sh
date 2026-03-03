#!/usr/bin/env bash
# tests/test-follow-dedup.sh
# Automated tests: follow-mode alert deduplication.
#
# Tests covered: 104–108
#
# Verifies that follow mode deduplicates output:
#   - First cycle: full [FLAPPING] block
#   - Continued flapping: compact [STILL FLAPPING] one-liner
#   - Cleared: [CLEARED] message when interface stabilises
#   - Mixed: one new, one continued, one cleared
#   - Without -f, dedup is disabled
#
# Usage (standalone):  bash tests/test-follow-dedup.sh
# Usage (via runner):  sourced by tests/run-tests.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo ""
echo -e "${BOLD}Offline tests — follow-mode alert deduplication${RESET}"
echo ""

# Clear any leaked config from prior test suites (e.g. invalid WEBHOOK_URL)
rm -rf "${XDG_CONFIG_HOME:-$TESTDIR/xdg}/link-flap"

# Reusable flapping log (4 transitions for eth0)
_dedup_log=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$_dedup_log" <<EOF
$(ts 500) host kernel: eth0: NIC Link is Down
$(ts 400) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 300) host kernel: eth0: NIC Link is Down
$(ts 200) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 100) host kernel: eth0: NIC Link is Down
EOF

# ── 104: First cycle — full [FLAPPING] block (no prev state) ────────────────
OUT=''; EXITCODE=0
OUT=$(_LINK_FLAP_TEST_INPUT="$_dedup_log" \
      bash "$SCRIPT" -w 60 2>&1) || EXITCODE=$?
if [[ $EXITCODE -eq 1 ]] && echo "$OUT" | grep -q '\[FLAPPING\]' \
   && ! echo "$OUT" | grep -q '\[STILL FLAPPING\]'; then
  pass "104: First cycle — full [FLAPPING] block, no [STILL FLAPPING]"
else
  fail "104: First cycle — full [FLAPPING] block, no [STILL FLAPPING]" \
       "exit=$EXITCODE\n$OUT"
fi

# ── 105: Second cycle with same interface still flapping → [STILL FLAPPING] ──
EXITCODE=0
timeout 3 bash -c \
  "_LINK_FLAP_TEST_INPUT='${_dedup_log}' \
   _FLAP_PREV_FLAPPING='eth0' _FLAP_PREV_TRANSITIONS='eth0=4' \
   bash '${SCRIPT}' -w 60 -f 1 2>&1" \
  > "$TESTDIR/t105.out" 2>&1 || EXITCODE=$?
OUT=$(cat "$TESTDIR/t105.out")
if echo "$OUT" | grep -q '\[STILL FLAPPING\].*eth0' \
   && echo "$OUT" | grep -q 'was 4' \
   && ! echo "$OUT" | grep -q '\[FLAPPING\]'; then
  pass "105: Still flapping — [STILL FLAPPING] with previous count, no full [FLAPPING]"
else
  fail "105: Still flapping — [STILL FLAPPING] with previous count, no full [FLAPPING]" \
       "exit=$EXITCODE\n$OUT"
fi

# ── 106: Previously flapping, now no events → [CLEARED] ─────────────────────
_empty_log=$(mktemp "$TESTDIR/XXXXXX.log"); : > "$_empty_log"
EXITCODE=0
timeout 3 bash -c \
  "_LINK_FLAP_TEST_INPUT='${_empty_log}' \
   _FLAP_PREV_FLAPPING='eth0' _FLAP_PREV_TRANSITIONS='eth0=4' \
   bash '${SCRIPT}' -f 1 -w 60 2>&1" \
  > "$TESTDIR/t106.out" 2>&1 || EXITCODE=$?
OUT=$(cat "$TESTDIR/t106.out")
if echo "$OUT" | grep -q '\[CLEARED\].*eth0' \
   && echo "$OUT" | grep -q 'stabilised'; then
  pass "106: Previously flapping, now no events — [CLEARED] shown"
else
  fail "106: Previously flapping, now no events — [CLEARED] shown" \
       "exit=$EXITCODE\n$OUT"
fi

# ── 107: Mixed — eth0 still flapping, enp3s0 newly flapping, eth1 cleared ───
_mixed_log=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$_mixed_log" <<EOF
$(ts 500) host kernel: eth0: NIC Link is Down
$(ts 400) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 300) host kernel: eth0: NIC Link is Down
$(ts 200) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 100) host kernel: eth0: NIC Link is Down
$(ts 500) host kernel: enp3s0: NIC Link is Down
$(ts 400) host kernel: enp3s0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 300) host kernel: enp3s0: NIC Link is Down
$(ts 200) host kernel: enp3s0: NIC Link is Up 1000 Mbps Full Duplex
EOF
EXITCODE=0
timeout 3 bash -c \
  "_LINK_FLAP_TEST_INPUT='${_mixed_log}' \
   _FLAP_PREV_FLAPPING='eth0 eth1' _FLAP_PREV_TRANSITIONS='eth0=3,eth1=5' \
   bash '${SCRIPT}' -w 60 -f 1 2>&1" \
  > "$TESTDIR/t107.out" 2>&1 || EXITCODE=$?
OUT=$(cat "$TESTDIR/t107.out")
_ok=1
echo "$OUT" | grep -q '\[STILL FLAPPING\].*eth0' || _ok=0
echo "$OUT" | grep -q '\[FLAPPING\].*enp3s0'     || _ok=0
echo "$OUT" | grep -q '\[CLEARED\].*eth1'         || _ok=0
if [[ $_ok -eq 1 ]]; then
  pass "107: Mixed — eth0 still flapping, enp3s0 new, eth1 cleared"
else
  fail "107: Mixed — eth0 still flapping, enp3s0 new, eth1 cleared" \
       "exit=$EXITCODE\n$OUT"
fi

# ── 108: Without follow mode, prev state is ignored (no dedup) ───────────────
OUT=''; EXITCODE=0
OUT=$(_LINK_FLAP_TEST_INPUT="$_dedup_log" \
      _FLAP_PREV_FLAPPING="eth0" _FLAP_PREV_TRANSITIONS="eth0=4" \
      bash "$SCRIPT" -w 60 2>&1) || EXITCODE=$?
if [[ $EXITCODE -eq 1 ]] && echo "$OUT" | grep -q '\[FLAPPING\]' \
   && ! echo "$OUT" | grep -q '\[STILL FLAPPING\]'; then
  pass "108: Without -f, prev state ignored — full [FLAPPING] shown even with _PREV set"
else
  fail "108: Without -f, prev state ignored — full [FLAPPING] shown even with _PREV set" \
       "exit=$EXITCODE\n$OUT"
fi
