#!/usr/bin/env bash
# tests/test-webhook.sh
# Automated tests: -W URL webhook alert integration.
#
# Tests covered: 100–103
#
# Verifies that the webhook fires on state changes only:
#   - Fires once when an interface newly enters the flapping state
#   - Does NOT re-fire when the same interface is still flapping next cycle
#   - Fires "cleared" when a previously-flapping interface is gone
#   - Validates that -W rejects non-http/https URLs
#
# Uses _LINK_FLAP_TEST_WEBHOOK_LOG to intercept curl calls — each call writes
# "event:iface:transitions" to the log file instead of hitting a real URL.
#
# Usage (standalone):  bash tests/test-webhook.sh
# Usage (via runner):  sourced by tests/run-tests.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo ""
echo -e "${BOLD}Offline tests — webhook alerts (-W)${RESET}"
echo ""

# ── 100: New flapping → webhook fires with "flapping" event ───────────────────
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts 500) host kernel: eth0: NIC Link is Down
$(ts 400) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 300) host kernel: eth0: NIC Link is Down
$(ts 200) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 100) host kernel: eth0: NIC Link is Down
EOF
wh_log=$(mktemp "$TESTDIR/wh-XXXXXX.log"); : > "$wh_log"
OUT=''; EXITCODE=0
OUT=$(_LINK_FLAP_TEST_INPUT="$t" _LINK_FLAP_TEST_WEBHOOK_LOG="$wh_log" \
      bash "$SCRIPT" -W https://test.example.com -w 60 2>&1) || EXITCODE=$?
if [[ $EXITCODE -eq 1 ]] && grep -q "^flapping:eth0:" "$wh_log"; then
  pass "100: -W fires 'flapping' alert for newly-flapping interface (exit=1)"
else
  fail "100: -W fires 'flapping' alert for newly-flapping interface (exit=1)" \
       "exit=$EXITCODE\nwebhook_log=$(cat "$wh_log")\n$OUT"
fi

# ── 101: Same interface still flapping (prev=eth0) → webhook does NOT re-fire ─
wh_log=$(mktemp "$TESTDIR/wh-XXXXXX.log"); : > "$wh_log"
OUT=''; EXITCODE=0
OUT=$(_LINK_FLAP_TEST_INPUT="$t" _LINK_FLAP_TEST_WEBHOOK_LOG="$wh_log" \
      _FLAP_PREV_FLAPPING="eth0" \
      bash "$SCRIPT" -W https://test.example.com -w 60 2>&1) || EXITCODE=$?
if [[ $EXITCODE -eq 1 ]] && [[ ! -s "$wh_log" ]]; then
  pass "101: -W does not re-fire when interface was already flapping (state unchanged)"
else
  fail "101: -W does not re-fire when interface was already flapping (state unchanged)" \
       "exit=$EXITCODE\nwebhook_log=$(cat "$wh_log")\n$OUT"
fi

# ── 102: Previously flapping, now no events → webhook fires "cleared" ─────────
t_empty=$(mktemp "$TESTDIR/XXXXXX.log"); : > "$t_empty"
wh_log=$(mktemp "$TESTDIR/wh-XXXXXX.log"); : > "$wh_log"
EXITCODE=0
timeout 3 bash -c \
  "_LINK_FLAP_TEST_INPUT='${t_empty}' _LINK_FLAP_TEST_WEBHOOK_LOG='${wh_log}' \
   _FLAP_PREV_FLAPPING='eth0' \
   bash '${SCRIPT}' -W https://test.example.com -f 1 -w 60 2>&1" \
  || EXITCODE=$?
if grep -q "^cleared:eth0:" "$wh_log"; then
  pass "102: -W fires 'cleared' alert when previously-flapping interface is gone"
else
  fail "102: -W fires 'cleared' alert when previously-flapping interface is gone" \
       "exit=$EXITCODE\nwebhook_log=$(cat "$wh_log")"
fi

# ── 103: Invalid -W URL (not http/https) → exit 2 + error message ─────────────
t=$(mktemp "$TESTDIR/XXXXXX.log"); : > "$t"
OUT=''; EXITCODE=0
OUT=$(bash "$SCRIPT" -W ftp://bad-url 2>&1) || EXITCODE=$?
if [[ $EXITCODE -eq 2 ]] && echo "$OUT" | grep -q "Error: -W must be"; then
  pass "103: -W ftp://bad-url → exit 2 + error message"
else
  fail "103: -W ftp://bad-url → exit 2 + error message" "exit=$EXITCODE\n$OUT"
fi
