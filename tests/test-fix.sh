#!/usr/bin/env bash
# tests/test-fix.sh
# Automated tests: auto-apply fixes (--fix).
#
# Tests covered: 129–132
#
# Verifies:
#   - --fix logs single-command fixes via test hook
#   - --fix skips multi-step instructions
#   - --fix without wizard (-d) is a no-op (no crash)
#   - --fix summary shows applied count
#
# Usage (standalone):  bash tests/test-fix.sh
# Usage (via runner):  sourced by tests/run-tests.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Clear any leaked config from prior test suites
rm -rf "${XDG_CONFIG_HOME:-$TESTDIR/xdg}/link-flap"

echo ""
echo -e "${BOLD}Offline tests — auto-apply fixes (--fix)${RESET}"
echo ""

# Wizard dir with EEE enabled (CAUSE finding with single-command fix)
_wiz_fix=$(mktemp -d "$TESTDIR/wiz-fix-XXXXXX")
echo "up"   > "$_wiz_fix/operstate"
echo "5"    > "$_wiz_fix/carrier_changes"
echo "on"   > "$_wiz_fix/power_control"
cat > "$_wiz_fix/ethtool" <<'ETHTOOL'
Settings for eth0:
	Speed: 1000Mb/s
	Duplex: Full
	Auto-negotiation: on
	Link detected: yes
ETHTOOL
cat > "$_wiz_fix/ethtool_eee" <<'EEE_OUT'
EEE settings for eth0:
	EEE status: enabled - active
	Tx LPI: 100 (us)
EEE_OUT
echo "" > "$_wiz_fix/ethtool_s"
echo "" > "$_wiz_fix/ethtool_i"
echo "" > "$_wiz_fix/ip_link"
echo "" > "$_wiz_fix/dmesg"
echo "" > "$_wiz_fix/ip_addr"
echo "" > "$_wiz_fix/ip_route"
echo "" > "$_wiz_fix/all_links"
echo "" > "$_wiz_fix/resolv_conf"
echo "" > "$_wiz_fix/ethtool_m"
echo "" > "$_wiz_fix/lldpctl"

# ── 129: --fix logs single-command fixes via test hook ───────────────────────
_fix_log="$TESTDIR/fix-commands.log"
rm -f "$_fix_log"
OUT=''; EXITCODE=0
OUT=$(BACKUP_DIR="$TESTDIR/backups" REPORT_DIR="$TESTDIR/reports" \
      _LINK_FLAP_TEST_WIZARD_DIR="$_wiz_fix" \
      _LINK_FLAP_TEST_FIX_LOG="$_fix_log" \
      bash "$SCRIPT" -d eth0 --fix 2>&1) || EXITCODE=$?
if [[ -f "$_fix_log" ]] && grep -q "ethtool --set-eee" "$_fix_log"; then
  pass "129: --fix logs single-command EEE fix via test hook"
else
  fail "129: --fix logs single-command EEE fix via test hook" \
       "exit=$EXITCODE fix_log=$(cat "$_fix_log" 2>/dev/null || echo 'NO FILE')\n$OUT"
fi

# ── 130: --fix skips multi-step instructions ─────────────────────────────────
# Physical layer failure generates a multi-step fix ("1. Replace cable 2. ...")
_wiz_multi=$(mktemp -d "$TESTDIR/wiz-multi-XXXXXX")
echo "down"    > "$_wiz_multi/operstate"
echo "600"     > "$_wiz_multi/carrier_changes"
echo "on"      > "$_wiz_multi/power_control"
cat > "$_wiz_multi/ethtool" <<'ETHTOOL'
Settings for eth0:
	Speed: Unknown!
	Duplex: Unknown!
	Auto-negotiation: on
	Link detected: no
ETHTOOL
echo "" > "$_wiz_multi/ethtool_eee"
cat > "$_wiz_multi/ethtool_s" <<'STATS'
NIC statistics:
     tx_packets: 100000
     tx_dropped: 6000
     rx_packets: 100000
     rx_dropped: 0
STATS
echo "" > "$_wiz_multi/ethtool_i"
echo "" > "$_wiz_multi/ip_link"
echo "" > "$_wiz_multi/dmesg"
echo "" > "$_wiz_multi/ip_addr"
echo "" > "$_wiz_multi/ip_route"
echo "" > "$_wiz_multi/all_links"
echo "" > "$_wiz_multi/resolv_conf"
echo "" > "$_wiz_multi/ethtool_m"
echo "" > "$_wiz_multi/lldpctl"

_fix_log2="$TESTDIR/fix-multi.log"
rm -f "$_fix_log2"
OUT=''; EXITCODE=0
OUT=$(BACKUP_DIR="$TESTDIR/backups" REPORT_DIR="$TESTDIR/reports" \
      _LINK_FLAP_TEST_WIZARD_DIR="$_wiz_multi" \
      _LINK_FLAP_TEST_FIX_LOG="$_fix_log2" \
      bash "$SCRIPT" -d eth0 --fix 2>&1) || EXITCODE=$?
# The multi-step "1. Replace cable" fix should NOT appear in the log
if [[ ! -f "$_fix_log2" ]] || ! grep -q "Replace" "$_fix_log2" 2>/dev/null; then
  pass "130: --fix skips multi-step instructions (numbered lists)"
else
  fail "130: --fix skips multi-step instructions (numbered lists)" \
       "exit=$EXITCODE fix_log=$(cat "$_fix_log2" 2>/dev/null || echo 'NO FILE')"
fi

# ── 131: --fix without wizard (-d) is a no-op ───────────────────────────────
_cron_input=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$_cron_input" <<EOF
$(ts 500) host kernel: eth0: NIC Link is Down
$(ts 400) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 300) host kernel: eth0: NIC Link is Down
$(ts 200) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 100) host kernel: eth0: NIC Link is Down
EOF
OUT=''; EXITCODE=0
OUT=$(_LINK_FLAP_TEST_INPUT="$_cron_input" \
      bash "$SCRIPT" -w 60 --fix 2>&1) || EXITCODE=$?
if [[ $EXITCODE -eq 1 ]] && echo "$OUT" | grep -q "FLAPPING"; then
  pass "131: --fix without wizard (-d) is a no-op (no crash)"
else
  fail "131: --fix without wizard (-d) is a no-op (no crash)" \
       "exit=$EXITCODE\n$OUT"
fi

# ── 132: --fix output shows [APPLIED] and summary count ─────────────────────
if echo "$OUT" | grep -q "APPLIED" 2>/dev/null; then
  # If run without -d, [APPLIED] should NOT appear
  fail "132: --fix summary shows applied count in wizard mode" \
       "APPLIED appeared without -d wizard mode"
else
  # Re-check test 129 output for APPLIED and summary
  OUT2=''; EXITCODE2=0
  _fix_log3="$TESTDIR/fix-summary.log"
  rm -f "$_fix_log3"
  OUT2=$(BACKUP_DIR="$TESTDIR/backups" REPORT_DIR="$TESTDIR/reports" \
        _LINK_FLAP_TEST_WIZARD_DIR="$_wiz_fix" \
        _LINK_FLAP_TEST_FIX_LOG="$_fix_log3" \
        bash "$SCRIPT" -d eth0 --fix 2>&1) || EXITCODE2=$?
  if echo "$OUT2" | grep -q "APPLIED" && echo "$OUT2" | grep -q "applied"; then
    pass "132: --fix summary shows [APPLIED] and applied count"
  else
    fail "132: --fix summary shows [APPLIED] and applied count" \
         "exit=$EXITCODE2\n$OUT2"
  fi
fi

# ── 305: --fix-dry-run shows [DRY RUN], no [APPLIED] ────────────────────────
_fix_log_dry="$TESTDIR/fix-dry.log"
rm -f "$_fix_log_dry"
OUT=''; EXITCODE=0
OUT=$(BACKUP_DIR="$TESTDIR/backups" REPORT_DIR="$TESTDIR/reports" \
      _LINK_FLAP_TEST_WIZARD_DIR="$_wiz_fix" \
      _LINK_FLAP_TEST_FIX_LOG="$_fix_log_dry" \
      bash "$SCRIPT" -d eth0 --fix-dry-run 2>&1) || EXITCODE=$?
if echo "$OUT" | grep -q "DRY RUN" \
   && ! echo "$OUT" | grep -q "APPLIED"; then
  pass "305: --fix-dry-run shows [DRY RUN], no [APPLIED]"
else
  fail "305: --fix-dry-run shows [DRY RUN], no [APPLIED]" \
       "exit=$EXITCODE\n$OUT"
fi

# ── 306: --fix --dry-run (separate flags) works the same ────────────────────
OUT=''; EXITCODE=0
OUT=$(BACKUP_DIR="$TESTDIR/backups" REPORT_DIR="$TESTDIR/reports" \
      _LINK_FLAP_TEST_WIZARD_DIR="$_wiz_fix" \
      _LINK_FLAP_TEST_FIX_LOG="$_fix_log_dry" \
      bash "$SCRIPT" -d eth0 --fix --dry-run 2>&1) || EXITCODE=$?
if echo "$OUT" | grep -q "DRY RUN" \
   && ! echo "$OUT" | grep -q "APPLIED"; then
  pass "306: --fix --dry-run (separate flags) shows [DRY RUN]"
else
  fail "306: --fix --dry-run (separate flags) shows [DRY RUN]" \
       "exit=$EXITCODE\n$OUT"
fi

# ── 307: --fix-dry-run exit code remains 0 ──────────────────────────────────
if [[ $EXITCODE -eq 0 ]]; then
  pass "307: --fix-dry-run exit code is 0"
else
  fail "307: --fix-dry-run exit code is 0" "exit=$EXITCODE"
fi
