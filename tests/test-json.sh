#!/usr/bin/env bash
# tests/test-json.sh
# Automated tests: -j JSON output mode.
#
# Tests covered: 109–114
#
# Verifies that -j emits valid, structured JSON and suppresses human output:
#   - Valid JSON on flapping detection
#   - Valid JSON with no events
#   - Correct interface fields (name, status, transitions, events)
#   - No ANSI colour codes in output
#   - Config block includes window/threshold/source
#   - Correlation flag set when applicable
#
# Usage (standalone):  bash tests/test-json.sh
# Usage (via runner):  sourced by tests/run-tests.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Clear any leaked config from prior test suites
rm -rf "${XDG_CONFIG_HOME:-$TESTDIR/xdg}/link-flap"

echo ""
echo -e "${BOLD}Offline tests — JSON output mode (-j)${RESET}"
echo ""

# Reusable flapping log (4 transitions for eth0)
_json_log=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$_json_log" <<EOF
$(ts 500) host kernel: eth0: NIC Link is Down
$(ts 400) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 300) host kernel: eth0: NIC Link is Down
$(ts 200) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 100) host kernel: eth0: NIC Link is Down
EOF

# ── 109: Flapping detected with -j → valid JSON with flapping interface ──────
OUT=''; EXITCODE=0
OUT=$(_LINK_FLAP_TEST_INPUT="$_json_log" \
      bash "$SCRIPT" -j -w 60 2>&1) || EXITCODE=$?
if [[ $EXITCODE -eq 1 ]] \
   && echo "$OUT" | python3 -m json.tool > /dev/null 2>&1 \
   && echo "$OUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['summary']['flapping_found'] == True
assert d['summary']['flapping_count'] == 1
assert 'eth0' in d['summary']['flapping_interfaces']
assert len(d['interfaces']) > 0
assert d['interfaces'][0]['status'] == 'flapping'
assert d['interfaces'][0]['transitions'] >= 3
"; then
  pass "109: -j flapping → valid JSON with status=flapping, correct summary"
else
  fail "109: -j flapping → valid JSON with status=flapping, correct summary" \
       "exit=$EXITCODE\n$OUT"
fi

# ── 110: No events with -j → valid JSON with empty interfaces ────────────────
_empty_log=$(mktemp "$TESTDIR/XXXXXX.log"); : > "$_empty_log"
OUT=''; EXITCODE=0
OUT=$(_LINK_FLAP_TEST_INPUT="$_empty_log" \
      bash "$SCRIPT" -j -w 60 2>&1) || EXITCODE=$?
if [[ $EXITCODE -eq 0 ]] \
   && echo "$OUT" | python3 -m json.tool > /dev/null 2>&1 \
   && echo "$OUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['summary']['flapping_found'] == False
assert d['interfaces'] == []
"; then
  pass "110: -j no events → valid JSON with empty interfaces array"
else
  fail "110: -j no events → valid JSON with empty interfaces array" \
       "exit=$EXITCODE\n$OUT"
fi

# ── 111: JSON contains correct per-interface event data ──────────────────────
OUT=''; EXITCODE=0
OUT=$(_LINK_FLAP_TEST_INPUT="$_json_log" \
      bash "$SCRIPT" -j -w 60 2>&1) || EXITCODE=$?
if echo "$OUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
iface = d['interfaces'][0]
assert iface['name'] == 'eth0'
assert iface['event_count'] == 5
assert iface['span_seconds'] >= 0
assert len(iface['events']) == 5
assert all('epoch' in e and 'state' in e for e in iface['events'])
assert iface['events'][0]['state'] in ('UP', 'DOWN')
" 2>/dev/null; then
  pass "111: -j per-interface events contain epoch, state, correct count"
else
  fail "111: -j per-interface events contain epoch, state, correct count" \
       "exit=$EXITCODE\n$OUT"
fi

# ── 112: No ANSI colour codes in -j output ──────────────────────────────────
OUT=''; EXITCODE=0
OUT=$(_LINK_FLAP_TEST_INPUT="$_json_log" \
      bash "$SCRIPT" -j -w 60 2>&1) || EXITCODE=$?
if ! echo "$OUT" | grep -qP '\x1b\['; then
  pass "112: -j output contains no ANSI escape codes"
else
  fail "112: -j output contains no ANSI escape codes" \
       "ANSI codes found in output"
fi

# ── 113: JSON config block includes window, threshold, log_source ────────────
OUT=''; EXITCODE=0
OUT=$(_LINK_FLAP_TEST_INPUT="$_json_log" \
      bash "$SCRIPT" -j -w 30 -t 2 2>&1) || EXITCODE=$?
if echo "$OUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['config']['window_minutes'] == 30
assert d['config']['flap_threshold'] == 2
assert d['config']['log_source'] is not None
assert 'version' in d
" 2>/dev/null; then
  pass "113: -j config block has window_minutes, flap_threshold, log_source, version"
else
  fail "113: -j config block has window_minutes, flap_threshold, log_source, version" \
       "exit=$EXITCODE\n$OUT"
fi

# ── 222: -j with flapping data + wizard mock → valid JSON output ─────────────
_json_wiz_dir=$(mktemp -d "$TESTDIR/json-wiz-XXXXXX")
make_wizard_fixture "$_json_wiz_dir"
OUT=''; EXITCODE=0
OUT=$(BACKUP_DIR="$TESTDIR/json-backups" REPORT_DIR="$TESTDIR/json-reports" \
      _LINK_FLAP_TEST_INPUT="$_json_log" \
      _LINK_FLAP_TEST_WIZARD_DIR="$_json_wiz_dir" \
      bash "$SCRIPT" -j -w 60 2>&1) || EXITCODE=$?
if [[ $EXITCODE -eq 1 ]] \
   && echo "$OUT" | python3 -m json.tool > /dev/null 2>&1 \
   && echo "$OUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['summary']['flapping_found'] == True
assert len(d['interfaces']) > 0
" 2>/dev/null; then
  pass "222: -j with flapping + wizard mock → valid JSON output"
else
  fail "222: -j with flapping + wizard mock → valid JSON output" \
       "exit=$EXITCODE\n$OUT"
fi

# ── 114: Correlation detected in JSON ────────────────────────────────────────
_corr_log=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$_corr_log" <<EOF
$(ts 500) host kernel: eth0: NIC Link is Down
$(ts 499) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 498) host kernel: eth0: NIC Link is Down
$(ts 497) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 500) host kernel: enp3s0: NIC Link is Down
$(ts 499) host kernel: enp3s0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 498) host kernel: enp3s0: NIC Link is Down
$(ts 497) host kernel: enp3s0: NIC Link is Up 1000 Mbps Full Duplex
EOF
OUT=''; EXITCODE=0
OUT=$(_LINK_FLAP_TEST_INPUT="$_corr_log" \
      bash "$SCRIPT" -j -w 60 2>&1) || EXITCODE=$?
if echo "$OUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['correlation']['detected'] == True
assert d['summary']['flapping_count'] == 2
" 2>/dev/null; then
  pass "114: -j correlation detected when two interfaces flap simultaneously"
else
  fail "114: -j correlation detected when two interfaces flap simultaneously" \
       "exit=$EXITCODE\n$OUT"
fi
