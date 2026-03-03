#!/usr/bin/env bash
# tests/test-wizard.sh
# Automated tests: diagnostic wizard and config backup/rollback — verifies that
# the wizard creates backups, produces a structured diagnostic report with the
# correct findings (CAUSE/WARN) for known hardware conditions, and that rollback
# handles list, restore, and partial-restore (non-root) scenarios correctly.
#
# Tests covered: 32–37, 57–58, 61, 200–206
#
# Sysfs/command output is mocked via _LINK_FLAP_TEST_WIZARD_DIR.
# Safe to run without root — test 61 skips automatically when running as root.
#
# Usage (standalone):  bash tests/test-wizard.sh
# Usage (via runner):  sourced by tests/run-tests.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo ""
echo -e "${BOLD}Offline tests — diagnostic wizard and config backup/rollback${RESET}"
echo ""

# ── Backup creation ────────────────────────────────────────────────────────────

# 32. Wizard creates backup dir and a subdirectory inside it
wiz_dir=$(mktemp -d "$TESTDIR/wiz-XXXXXX")
echo "up" > "$wiz_dir/operstate"
run_wizard_test "$wiz_dir" -d eth0 -w 60
backup_count=$(ls -1 "$TESTDIR/backups" 2>/dev/null | wc -l)
if [[ $EXITCODE -eq 0 ]] && [[ -d "$TESTDIR/backups" ]] && [[ "$backup_count" -gt 0 ]]; then
  pass "32: wizard: creates backup dir with at least one backup subdirectory"
else
  fail "32: wizard: creates backup dir with at least one backup subdirectory" "exit=$EXITCODE backups=$backup_count\n$OUT"
fi

# ── Rollback ──────────────────────────────────────────────────────────────────

# 33. -r list shows available backups
mkdir -p "$TESTDIR/backups/20240101-000000-eth0"
printf '%s\n' "iface=eth0" "ts=20240101-000000" "files=" \
  > "$TESTDIR/backups/20240101-000000-eth0/.manifest"
run_rollback_test "list"
if [[ $EXITCODE -eq 0 ]] && echo "$OUT" | grep -q "20240101-000000-eth0"; then
  pass "33: rollback: -r list shows available backups"
else
  fail "33: rollback: -r list shows available backups" "exit=$EXITCODE\n$OUT"
fi

# 34. -r nonexistent-id → exit 1 + "not found"
run_rollback_test "nonexistent-backup-id-xyz"
if [[ $EXITCODE -eq 1 ]] && echo "$OUT" | grep -qi "not found"; then
  pass "34: rollback: -r nonexistent-id → exit 1 + 'not found'"
else
  fail "34: rollback: -r nonexistent-id → exit 1 + 'not found'" "exit=$EXITCODE\n$OUT"
fi

# 61. Partial rollback: backup exists but /etc/ is not writable → exit 2 + "Partial restore"
#     Skip when running as root since root can always write /etc/.
if [[ $(id -u) -eq 0 ]]; then
  skip "61: partial rollback → exit 2 (skipped — running as root, /etc/ is writable)"
else
  mkdir -p "$TESTDIR/backups/test-partial-restore/netplan"
  echo "network: {}" > "$TESTDIR/backups/test-partial-restore/netplan/00-test.yaml"
  printf '%s\n' "iface=eth0" "ts=20260101-000000" "files=netplan" \
    > "$TESTDIR/backups/test-partial-restore/.manifest"
  run_rollback_test "test-partial-restore"
  if [[ $EXITCODE -eq 2 ]] && echo "$OUT" | grep -qi "partial restore"; then
    pass "61: partial rollback (no /etc/ write perms) → exit 2 + 'Partial restore'"
  else
    fail "61: partial rollback (no /etc/ write perms) → exit 2 + 'Partial restore'" "exit=$EXITCODE\n$OUT"
  fi
fi

# ── Wizard findings — hardware conditions ─────────────────────────────────────

# 35. EEE enabled → [CAUSE] + "EEE" in output
wiz_dir=$(mktemp -d "$TESTDIR/wiz-XXXXXX")
echo "EEE status: enabled" > "$wiz_dir/ethtool_eee"
run_wizard_test "$wiz_dir" -d eth0 -w 60
if [[ $EXITCODE -eq 0 ]] && echo "$OUT" | grep -q "\[CAUSE\]" \
   && echo "$OUT" | grep -qi "EEE"; then
  pass "35: wizard: EEE enabled → [CAUSE] with 'EEE' in output"
else
  fail "35: wizard: EEE enabled → [CAUSE] with 'EEE' in output" "exit=$EXITCODE\n$OUT"
fi

# 36. power/control=auto → [CAUSE] + "power" in output
wiz_dir=$(mktemp -d "$TESTDIR/wiz-XXXXXX")
echo "auto" > "$wiz_dir/power_control"
run_wizard_test "$wiz_dir" -d eth0 -w 60
if [[ $EXITCODE -eq 0 ]] && echo "$OUT" | grep -q "\[CAUSE\]" \
   && echo "$OUT" | grep -qi "power"; then
  pass "36: wizard: power/control=auto → [CAUSE] with 'power' in output"
else
  fail "36: wizard: power/control=auto → [CAUSE] with 'power' in output" "exit=$EXITCODE\n$OUT"
fi

# 37. High carrier changes (50) → [WARN] in output
wiz_dir=$(mktemp -d "$TESTDIR/wiz-XXXXXX")
echo "50" > "$wiz_dir/carrier_changes"
run_wizard_test "$wiz_dir" -d eth0 -w 60
if [[ $EXITCODE -eq 0 ]] && echo "$OUT" | grep -q "\[WARN\]"; then
  pass "37: wizard: carrier_changes=50 → [WARN] in output"
else
  fail "37: wizard: carrier_changes=50 → [WARN] in output" "exit=$EXITCODE\n$OUT"
fi

# ── Wizard report structure ────────────────────────────────────────────────────

# 57. Wizard summary includes "Verify" re-run hint
wiz_dir=$(mktemp -d "$TESTDIR/wiz-verify-XXXXXX")
echo "up" > "$wiz_dir/operstate"
run_wizard_test "$wiz_dir" -d eth0 -w 60
if [[ $EXITCODE -eq 0 ]] && echo "$OUT" | grep -q "Verify"; then
  pass "57: wizard summary includes 'Verify' re-run hint"
else
  fail "57: wizard summary includes 'Verify' re-run hint" "exit=$EXITCODE\n$OUT"
fi

# 58. Auto-wizard fires when flapping detected (no -d) and _LINK_FLAP_TEST_WIZARD_DIR provided
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts 500) host kernel: eth0: NIC Link is Down
$(ts 400) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 300) host kernel: eth0: NIC Link is Down
$(ts 200) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 100) host kernel: eth0: NIC Link is Down
EOF
wiz_dir=$(mktemp -d "$TESTDIR/wiz-auto-XXXXXX")
echo "up" > "$wiz_dir/operstate"
OUT=''; EXITCODE=0
OUT=$(BACKUP_DIR="$TESTDIR/backups" REPORT_DIR="$TESTDIR/reports" \
      _LINK_FLAP_TEST_INPUT="$t" \
      _LINK_FLAP_TEST_WIZARD_DIR="$wiz_dir" \
      bash "$SCRIPT" -w 60 -t 3 2>&1) || EXITCODE=$?
if [[ $EXITCODE -eq 1 ]] \
   && echo "$OUT" | grep -q "\[FLAPPING\]" \
   && echo "$OUT" | grep -q "Diagnostic:"; then
  pass "58: auto-wizard fires on flapping detection (no -d flag needed)"
else
  fail "58: auto-wizard fires on flapping detection (no -d flag needed)" "exit=$EXITCODE\n$OUT"
fi

# ── Additional wizard findings ─────────────────────────────────────────────

# 200. Half-duplex → [WARN]
wiz_dir=$(mktemp -d "$TESTDIR/wiz-XXXXXX")
make_wizard_fixture "$wiz_dir"
cat > "$wiz_dir/ethtool" <<'EOF'
Settings for eth0:
    Speed: 1000Mb/s
    Duplex: Half
    Auto-negotiation: on
    Link detected: yes
EOF
run_wizard_test "$wiz_dir" -d eth0 -w 60
if [[ $EXITCODE -eq 0 ]] && echo "$OUT" | grep -q "\[WARN\]" \
   && echo "$OUT" | grep -qi "Half-duplex"; then
  pass "200: wizard: Half-duplex → [WARN]"
else
  fail "200: wizard: Half-duplex → [WARN]" "exit=$EXITCODE\n$OUT"
fi

# 201. No physical link → [CAUSE]
wiz_dir=$(mktemp -d "$TESTDIR/wiz-XXXXXX")
make_wizard_fixture "$wiz_dir"
cat > "$wiz_dir/ethtool" <<'EOF'
Settings for eth0:
    Speed: Unknown!
    Duplex: Unknown!
    Auto-negotiation: on
    Link detected: no
EOF
run_wizard_test "$wiz_dir" -d eth0 -w 60
if [[ $EXITCODE -eq 0 ]] && echo "$OUT" | grep -q "\[CAUSE\]" \
   && echo "$OUT" | grep -qi "No physical link"; then
  pass "201: wizard: No physical link → [CAUSE]"
else
  fail "201: wizard: No physical link → [CAUSE]" "exit=$EXITCODE\n$OUT"
fi

# 202. RX CRC errors → [CAUSE]
wiz_dir=$(mktemp -d "$TESTDIR/wiz-XXXXXX")
make_wizard_fixture "$wiz_dir"
cat > "$wiz_dir/ethtool_s" <<'EOF'
NIC statistics:
     rx_crc_errors: 42
     tx_packets: 100000
EOF
run_wizard_test "$wiz_dir" -d eth0 -w 60
if [[ $EXITCODE -eq 0 ]] && echo "$OUT" | grep -q "\[CAUSE\]" \
   && echo "$OUT" | grep -qi "CRC"; then
  pass "202: wizard: RX CRC errors → [CAUSE]"
else
  fail "202: wizard: RX CRC errors → [CAUSE]" "exit=$EXITCODE\n$OUT"
fi

# 203. dmesg hardware error → [CAUSE]
wiz_dir=$(mktemp -d "$TESTDIR/wiz-XXXXXX")
make_wizard_fixture "$wiz_dir"
printf '%s\n' "[12345.678] eth0: hardware error detected" > "$wiz_dir/dmesg"
run_wizard_test "$wiz_dir" -d eth0 -w 60
if [[ $EXITCODE -eq 0 ]] && echo "$OUT" | grep -q "\[CAUSE\]" \
   && echo "$OUT" | grep -qi "Hardware error"; then
  pass "203: wizard: dmesg hardware error → [CAUSE]"
else
  fail "203: wizard: dmesg hardware error → [CAUSE]" "exit=$EXITCODE\n$OUT"
fi

# 204. dmesg NIC reset → [WARN]
wiz_dir=$(mktemp -d "$TESTDIR/wiz-XXXXXX")
make_wizard_fixture "$wiz_dir"
printf '%s\n' "[12345.678] eth0: Reset adapter" > "$wiz_dir/dmesg"
run_wizard_test "$wiz_dir" -d eth0 -w 60
if [[ $EXITCODE -eq 0 ]] && echo "$OUT" | grep -q "\[WARN\]" \
   && echo "$OUT" | grep -qi "reset"; then
  pass "204: wizard: dmesg NIC reset → [WARN]"
else
  fail "204: wizard: dmesg NIC reset → [WARN]" "exit=$EXITCODE\n$OUT"
fi

# 205. Regular flap interval (evenly-spaced events) → [WARN]
_reg_input=$(mktemp "$TESTDIR/XXXXXX.log")
_now=$(date +%s)
# 5 alternating Down/Up events at exact 10 s intervals → spread = 0 < 30
{
  echo "$(date -d "@$(( _now - 50 ))" "+%Y-%m-%dT%H:%M:%S+0000") host kernel: eth0: NIC Link is Down"
  echo "$(date -d "@$(( _now - 40 ))" "+%Y-%m-%dT%H:%M:%S+0000") host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex"
  echo "$(date -d "@$(( _now - 30 ))" "+%Y-%m-%dT%H:%M:%S+0000") host kernel: eth0: NIC Link is Down"
  echo "$(date -d "@$(( _now - 20 ))" "+%Y-%m-%dT%H:%M:%S+0000") host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex"
  echo "$(date -d "@$(( _now - 10 ))" "+%Y-%m-%dT%H:%M:%S+0000") host kernel: eth0: NIC Link is Down"
} > "$_reg_input"
wiz_dir=$(mktemp -d "$TESTDIR/wiz-XXXXXX")
make_wizard_fixture "$wiz_dir"
OUT=''; EXITCODE=0
OUT=$(BACKUP_DIR="$TESTDIR/backups" REPORT_DIR="$TESTDIR/reports" \
      _LINK_FLAP_TEST_INPUT="$_reg_input" \
      _LINK_FLAP_TEST_WIZARD_DIR="$wiz_dir" \
      bash "$SCRIPT" -w 60 -t 3 2>&1) || EXITCODE=$?
if echo "$OUT" | grep -qi "Regular flap interval"; then
  pass "205: wizard: regular flap interval → [WARN]"
else
  fail "205: wizard: regular flap interval → [WARN]" "exit=$EXITCODE\n$OUT"
fi

# 206. carrier_changes below threshold → no carrier finding
wiz_dir=$(mktemp -d "$TESTDIR/wiz-XXXXXX")
make_wizard_fixture "$wiz_dir"
echo "3" > "$wiz_dir/carrier_changes"
run_wizard_test "$wiz_dir" -d eth0 -w 60
if [[ $EXITCODE -eq 0 ]] \
   && ! echo "$OUT" | grep -qi "carrier.*\[WARN\]\|\[WARN\].*carrier" \
   && ! echo "$OUT" | grep -qi "carrier.*\[CAUSE\]\|\[CAUSE\].*carrier"; then
  pass "206: wizard: carrier_changes=3 → no carrier finding"
else
  fail "206: wizard: carrier_changes=3 → no carrier finding" "exit=$EXITCODE\n$OUT"
fi
