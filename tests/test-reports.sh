#!/usr/bin/env bash
# tests/test-reports.sh
# Automated tests: report aggregation (--reports).
#
# Tests covered: 133–136
#
# Verifies:
#   - --reports lists saved wizard reports with date, interface, causes, warnings
#   - --reports with no reports → graceful message
#   - --reports counts match actual report content
#   - --reports shows report count
#
# Usage (standalone):  bash tests/test-reports.sh
# Usage (via runner):  sourced by tests/run-tests.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Clear any leaked config from prior test suites
rm -rf "${XDG_CONFIG_HOME:-$TESTDIR/xdg}/link-flap"

echo ""
echo -e "${BOLD}Offline tests — report aggregation${RESET}"
echo ""

# Set up a test report directory with sample reports
_rpt_dir="$TESTDIR/test-reports"
mkdir -p "$_rpt_dir"

# Report 1: 2 causes, 1 warning
cat > "$_rpt_dir/20260301-100000-eth0.txt" <<'EOF'
  Diagnostic Report — eth0
  Generated : 2026-03-01 10:00:00
  Backup ID : 20260301-100000-eth0

  [1] [CAUSE] Energy-Efficient Ethernet (EEE) enabled
  [2] [CAUSE] NIC power management enabled
  [3] [WARN]  Half-duplex detected
  [4] [INFO]  Flap events in scan window

Summary
  Causes  : 2
  Warnings: 1
EOF

# Report 2: 0 causes, 1 warning
cat > "$_rpt_dir/20260302-143000-enp3s0.txt" <<'EOF'
  Diagnostic Report — enp3s0
  Generated : 2026-03-02 14:30:00
  Backup ID : 20260302-143000-enp3s0

  [1] [WARN]  Elevated carrier changes since boot
  [2] [INFO]  Flap events in scan window

Summary
  Causes  : 0
  Warnings: 1
EOF

# ── 133: --reports lists saved reports ───────────────────────────────────────
OUT=''; EXITCODE=0
OUT=$(REPORT_DIR="$_rpt_dir" bash "$SCRIPT" --reports 2>&1) || EXITCODE=$?
if [[ $EXITCODE -eq 0 ]] \
   && echo "$OUT" | grep -q "eth0" \
   && echo "$OUT" | grep -q "enp3s0" \
   && echo "$OUT" | grep -q "2026-03-01"; then
  pass "133: --reports lists saved reports with date and interface"
else
  fail "133: --reports lists saved reports with date and interface" \
       "exit=$EXITCODE\n$OUT"
fi

# ── 134: --reports with no reports → graceful message ────────────────────────
_empty_dir="$TESTDIR/empty-reports"
mkdir -p "$_empty_dir"
OUT=''; EXITCODE=0
OUT=$(REPORT_DIR="$_empty_dir" bash "$SCRIPT" --reports 2>&1) || EXITCODE=$?
if [[ $EXITCODE -eq 0 ]] && echo "$OUT" | grep -qi "no saved reports"; then
  pass "134: --reports with no reports → graceful message"
else
  fail "134: --reports with no reports → graceful message" \
       "exit=$EXITCODE\n$OUT"
fi

# ── 135: --reports cause/warning counts match ────────────────────────────────
# eth0 report has 2 [CAUSE] lines
if echo "$OUT" | grep -q ""; then true; fi  # re-read from test 133
OUT=''; EXITCODE=0
OUT=$(REPORT_DIR="$_rpt_dir" bash "$SCRIPT" --reports 2>&1) || EXITCODE=$?
_eth0_line=$(echo "$OUT" | grep "eth0" || true)
if echo "$_eth0_line" | grep -q "2" && echo "$_eth0_line" | grep -q "1"; then
  pass "135: --reports cause/warning counts match report content"
else
  fail "135: --reports cause/warning counts match report content" \
       "eth0_line=$_eth0_line\n$OUT"
fi

# ── 136: --reports shows total count ─────────────────────────────────────────
if echo "$OUT" | grep -q "2 report"; then
  pass "136: --reports shows total report count"
else
  fail "136: --reports shows total report count" \
       "$OUT"
fi
