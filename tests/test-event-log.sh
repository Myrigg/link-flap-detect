#!/usr/bin/env bash
# tests/test-event-log.sh
# Automated tests: persistent event log.
#
# Tests covered: 115–119
#
# Verifies the event log feature:
#   - FLAPPING events appended to log file on detection
#   - Log format: ISO 8601 tab-separated fields
#   - --events queries the log (default, N, all, date filter)
#   - No log file → graceful message
#   - Normal (non-test) mode is not affected
#
# Usage (standalone):  bash tests/test-event-log.sh
# Usage (via runner):  sourced by tests/run-tests.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Clear any leaked config from prior test suites
rm -rf "${XDG_CONFIG_HOME:-$TESTDIR/xdg}/link-flap"

echo ""
echo -e "${BOLD}Offline tests — persistent event log${RESET}"
echo ""

# Reusable flapping log (4 transitions for eth0)
_evlog_input=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$_evlog_input" <<EOF
$(ts 500) host kernel: eth0: NIC Link is Down
$(ts 400) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 300) host kernel: eth0: NIC Link is Down
$(ts 200) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 100) host kernel: eth0: NIC Link is Down
EOF

# Use a test-specific event log path
_evlog="$TESTDIR/test-events.log"

# ── 115: Flapping detection appends FLAPPING entry to event log ──────────────
rm -f "$_evlog"
OUT=''; EXITCODE=0
OUT=$(_LINK_FLAP_TEST_INPUT="$_evlog_input" EVENT_LOG="$_evlog" \
      bash "$SCRIPT" -w 60 2>&1) || EXITCODE=$?
if [[ $EXITCODE -eq 1 ]] && [[ -f "$_evlog" ]] \
   && grep -q "FLAPPING" "$_evlog" \
   && grep -q "eth0" "$_evlog"; then
  pass "115: Flapping detection appends FLAPPING entry to event log"
else
  fail "115: Flapping detection appends FLAPPING entry to event log" \
       "exit=$EXITCODE log=$(cat "$_evlog" 2>/dev/null || echo 'NO FILE')\n$OUT"
fi

# ── 116: Event log format is tab-separated with ISO 8601 timestamp ───────────
if [[ -f "$_evlog" ]]; then
  _line=$(head -1 "$_evlog")
  _fields=$(echo "$_line" | awk -F'\t' '{print NF}')
  _ts_field=$(echo "$_line" | cut -f1)
  if [[ "$_fields" -ge 3 ]] && [[ "$_ts_field" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
    pass "116: Event log format is tab-separated with ISO 8601 timestamp"
  else
    fail "116: Event log format is tab-separated with ISO 8601 timestamp" \
         "fields=$_fields ts=$_ts_field line=$_line"
  fi
else
  fail "116: Event log format is tab-separated with ISO 8601 timestamp" \
       "No event log file"
fi

# ── 117: --events shows recent entries ───────────────────────────────────────
# Pre-populate the log with a few entries
cat > "$_evlog" <<'EOF'
2026-03-01T10:00:00+0000	eth0	FLAPPING	transitions=5
2026-03-02T12:00:00+0000	eth0	FLAPPING	transitions=8
2026-03-03T14:00:00+0000	enp3s0	FLAPPING	transitions=3
EOF
OUT=''; EXITCODE=0
OUT=$(EVENT_LOG="$_evlog" bash "$SCRIPT" --events 2 2>&1) || EXITCODE=$?
if [[ $EXITCODE -eq 0 ]] \
   && echo "$OUT" | grep -q "enp3s0" \
   && echo "$OUT" | grep -q "2026-03-02"; then
  pass "117: --events 2 shows last 2 entries from event log"
else
  fail "117: --events 2 shows last 2 entries from event log" \
       "exit=$EXITCODE\n$OUT"
fi

# ── 118: --events all shows everything ───────────────────────────────────────
OUT=''; EXITCODE=0
OUT=$(EVENT_LOG="$_evlog" bash "$SCRIPT" --events all 2>&1) || EXITCODE=$?
_count=$(echo "$OUT" | grep -c "FLAPPING" || true)
if [[ $EXITCODE -eq 0 ]] && [[ "$_count" -eq 3 ]]; then
  pass "118: --events all shows all 3 entries"
else
  fail "118: --events all shows all 3 entries" \
       "exit=$EXITCODE count=$_count\n$OUT"
fi

# ── 119: --events with no log file → graceful message ───────────────────────
rm -f "$TESTDIR/nonexistent-events.log"
OUT=''; EXITCODE=0
OUT=$(EVENT_LOG="$TESTDIR/nonexistent-events.log" bash "$SCRIPT" --events 10 2>&1) || EXITCODE=$?
if [[ $EXITCODE -eq 0 ]] && echo "$OUT" | grep -qi "no event log"; then
  pass "119: --events with no log file → graceful 'no event log' message"
else
  fail "119: --events with no log file → graceful 'no event log' message" \
       "exit=$EXITCODE\n$OUT"
fi
