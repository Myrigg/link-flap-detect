#!/usr/bin/env bash
# tests/test-live-system.sh
# Automated tests: live system integration — reads from actual system sources
# (journald, /var/log/syslog, /sys/class/net) to verify the tool operates
# correctly on real hardware without crashing or misreporting.
#
# Tests covered: 38–41, 46
#
# Each test skips gracefully if its prerequisite is unavailable (no journalctl,
# no physical interface, no readable syslog, no node_exporter running).
# Tests may require a running systemd. Root is not required but test 40
# produces more complete results when run as root.
#
# Usage (standalone):  bash tests/test-live-system.sh
# Usage (via runner):  sourced by tests/run-tests.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo ""
echo -e "${BOLD}Live system tests — reads journald, /var/log/syslog, and /sys/class/net on this machine${RESET}"
echo ""

# Helper: find first non-virtual, non-loopback interface
_real_iface() {
  ip link show 2>/dev/null \
    | awk -F': ' '/^[0-9]/ && $2 !~ /^(lo|veth|virbr|docker|tun|tap|br-)/ {
        sub(/@.*/, "", $2); print $2; exit
      }'
}

# 38. Live journald code path — source label correct, output format valid
if ! command -v journalctl &>/dev/null; then
  skip "38: live journald scan (journalctl not available)"
else
  OUT=''; EXITCODE=0
  OUT=$(bash "$SCRIPT" -w 5 2>&1) || EXITCODE=$?
  if [[ $EXITCODE -le 1 ]] \
     && echo "$OUT" | grep -q "Link Flap Detector" \
     && echo "$OUT" | grep -q "journald" \
     && echo "$OUT" | grep -qE "No link state events found|No flapping detected|\[FLAPPING\]"; then
    pass "38: live journald — source=journald, valid output (exit=$EXITCODE)"
  else
    fail "38: live journald — source=journald, valid output" "exit=$EXITCODE\n$OUT"
  fi
fi

# 39. Real /var/log/syslog — parse entire file without crashing
if [[ ! -r /var/log/syslog ]]; then
  skip "39: real syslog parse (/var/log/syslog not readable)"
else
  line_count=$(wc -l < /var/log/syslog)
  OUT=''; EXITCODE=0
  OUT=$(_LINK_FLAP_TEST_INPUT=/var/log/syslog bash "$SCRIPT" -w 9999 2>&1) || EXITCODE=$?
  if [[ $EXITCODE -le 1 ]] && echo "$OUT" | grep -q "Link Flap Detector"; then
    pass "39: real /var/log/syslog (${line_count} lines) parsed without error (exit=$EXITCODE)"
  else
    fail "39: real /var/log/syslog parsed without error" "exit=$EXITCODE lines=$line_count\n$OUT"
  fi
fi

# 40. Real wizard on a live interface — reads actual sysfs; report matches /sys/class/net/
REAL_IFACE=$(_real_iface)
if [[ -z "$REAL_IFACE" ]]; then
  skip "40: wizard on real interface (no physical interface found)"
else
  # Capture ground-truth values from sysfs before running the wizard
  real_operstate=$(cat "/sys/class/net/${REAL_IFACE}/operstate" 2>/dev/null || echo "")
  real_carrier_changes=$(cat "/sys/class/net/${REAL_IFACE}/carrier_changes" 2>/dev/null || echo "")

  run_real_wizard_test "$REAL_IFACE" -w 5
  report_count=$(ls -1 "$TESTDIR/real-reports" 2>/dev/null | wc -l)
  backup_count=$(ls -1 "$TESTDIR/real-backups" 2>/dev/null | wc -l)

  ok=1
  [[ $EXITCODE -eq 0 ]]                              || ok=0
  echo "$OUT" | grep -q "Diagnostic Report"          || ok=0
  [[ $backup_count -gt 0 ]]                          || ok=0
  [[ $report_count -gt 0 ]]                          || ok=0
  # Verify the wizard read real sysfs: carrier_changes value must appear in output
  if [[ -n "$real_carrier_changes" ]]; then
    echo "$OUT" | grep -q "carrier_changes.*:.*${real_carrier_changes}" || ok=0
  fi
  # operstate value must appear in output
  if [[ -n "$real_operstate" ]]; then
    echo "$OUT" | grep -q "operstate.*:.*${real_operstate}" || ok=0
  fi

  if [[ $ok -eq 1 ]]; then
    pass "40: wizard -d ${REAL_IFACE} reads real sysfs (operstate=${real_operstate}, carrier_changes=${real_carrier_changes})"
  else
    fail "40: wizard -d ${REAL_IFACE} reads real sysfs" \
      "exit=$EXITCODE backups=$backup_count reports=$report_count operstate=${real_operstate} carrier_changes=${real_carrier_changes}\n$OUT"
  fi
fi

# 41. Live journald with real interface filter — filter label shown, pipeline completes cleanly
REAL_IFACE=$(_real_iface)
if [[ -z "$REAL_IFACE" ]] || ! command -v journalctl &>/dev/null; then
  skip "41: live journald with -i filter (journalctl or physical interface unavailable)"
else
  OUT=''; EXITCODE=0
  OUT=$(bash "$SCRIPT" -w 5 -i "$REAL_IFACE" 2>&1) || EXITCODE=$?
  if [[ $EXITCODE -le 1 ]] \
     && echo "$OUT" | grep -q "Link Flap Detector" \
     && echo "$OUT" | grep -q "Interface filter" \
     && echo "$OUT" | grep -q "$REAL_IFACE"; then
    pass "41: live journald -i ${REAL_IFACE} — filter label present, exit=$EXITCODE"
  else
    fail "41: live journald -i ${REAL_IFACE} — filter label present" "exit=$EXITCODE\n$OUT"
  fi
fi

# 46. Live node_exporter probe — header shows "node_exporter:" if running at default URL
_NE_URL="${NODE_EXPORTER_URL:-http://localhost:9100}"
REAL_IFACE=$(_real_iface)
if [[ -z "$REAL_IFACE" ]]; then
  skip "46: live node_exporter probe (no physical interface found)"
elif ! curl -sf --max-time 3 "${_NE_URL}/metrics" &>/dev/null; then
  skip "46: live node_exporter probe (not running at ${_NE_URL})"
else
  OUT=''; EXITCODE=0
  OUT=$(bash "$SCRIPT" -w 5 -i "$REAL_IFACE" 2>&1) || EXITCODE=$?
  if [[ $EXITCODE -le 1 ]] && echo "$OUT" | grep -q "node_exporter"; then
    pass "46: live node_exporter — probed at ${_NE_URL}, shown in header (exit=$EXITCODE)"
  else
    fail "46: live node_exporter — probed at ${_NE_URL}, shown in header" "exit=$EXITCODE\n$OUT"
  fi
fi
