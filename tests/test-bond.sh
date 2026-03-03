#!/usr/bin/env bash
# tests/test-bond.sh
# Automated tests: bond/LAG member awareness.
#
# Tests covered: 120–124
#
# Verifies bond member detection:
#   - [FLAPPING] line annotated with bond membership
#   - Wizard INFO finding for bond member
#   - Wizard WARN when member carrier_changes >> bond carrier_changes
#   - No annotation when interface is not a bond member
#   - Bond mode shown in wizard finding
#
# Usage (standalone):  bash tests/test-bond.sh
# Usage (via runner):  sourced by tests/run-tests.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Clear any leaked config from prior test suites
rm -rf "${XDG_CONFIG_HOME:-$TESTDIR/xdg}/link-flap"

echo ""
echo -e "${BOLD}Offline tests — bond/LAG member awareness${RESET}"
echo ""

# Reusable flapping log (4 transitions for eth0)
_bond_input=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$_bond_input" <<EOF
$(ts 500) host kernel: eth0: NIC Link is Down
$(ts 400) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 300) host kernel: eth0: NIC Link is Down
$(ts 200) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 100) host kernel: eth0: NIC Link is Down
EOF

# ── 120: [FLAPPING] line annotated with bond membership ──────────────────────
OUT=''; EXITCODE=0
OUT=$(_LINK_FLAP_TEST_INPUT="$_bond_input" _LINK_FLAP_TEST_BOND_MASTERS="eth0=bond0" \
      bash "$SCRIPT" -w 60 2>&1) || EXITCODE=$?
if [[ $EXITCODE -eq 1 ]] && echo "$OUT" | grep -q "bond member of bond0"; then
  pass "120: [FLAPPING] line annotated with bond membership"
else
  fail "120: [FLAPPING] line annotated with bond membership" \
       "exit=$EXITCODE\n$OUT"
fi

# ── 121: Wizard INFO finding for bond member ─────────────────────────────────
_wiz_bond=$(mktemp -d "$TESTDIR/wiz-bond-XXXXXX")
echo "up"   > "$_wiz_bond/operstate"
echo "20"   > "$_wiz_bond/carrier_changes"
echo "on"   > "$_wiz_bond/power_control"
echo "15"   > "$_wiz_bond/bond_carrier_changes"
echo "balance-rr 0" > "$_wiz_bond/bond_mode"
# Minimal ethtool output
cat > "$_wiz_bond/ethtool" <<'ETHTOOL'
Settings for eth0:
	Speed: 1000Mb/s
	Duplex: Full
	Auto-negotiation: on
	Link detected: yes
ETHTOOL
echo "" > "$_wiz_bond/ethtool_s"
echo "" > "$_wiz_bond/ethtool_eee"
echo "" > "$_wiz_bond/ethtool_i"
echo "" > "$_wiz_bond/ip_link"
echo "" > "$_wiz_bond/dmesg"
echo "" > "$_wiz_bond/ip_addr"
echo "" > "$_wiz_bond/ip_route"
echo "" > "$_wiz_bond/all_links"
echo "" > "$_wiz_bond/resolv_conf"
echo "" > "$_wiz_bond/ethtool_m"
echo "" > "$_wiz_bond/lldpctl"

OUT=''; EXITCODE=0
OUT=$(BACKUP_DIR="$TESTDIR/backups" REPORT_DIR="$TESTDIR/reports" \
      _LINK_FLAP_TEST_WIZARD_DIR="$_wiz_bond" \
      _LINK_FLAP_TEST_BOND_MASTERS="eth0=bond0" \
      bash "$SCRIPT" -d eth0 2>&1) || EXITCODE=$?
if echo "$OUT" | grep -q "Bond member of bond0" \
   && echo "$OUT" | grep -q "INFO"; then
  pass "121: Wizard INFO finding for bond member"
else
  fail "121: Wizard INFO finding for bond member" \
       "exit=$EXITCODE\n$OUT"
fi

# ── 122: Wizard WARN when member carrier_changes >> bond carrier_changes ─────
_wiz_bond_warn=$(mktemp -d "$TESTDIR/wiz-bond-warn-XXXXXX")
echo "up"    > "$_wiz_bond_warn/operstate"
echo "200"   > "$_wiz_bond_warn/carrier_changes"
echo "on"    > "$_wiz_bond_warn/power_control"
echo "5"     > "$_wiz_bond_warn/bond_carrier_changes"
echo "802.3ad 4" > "$_wiz_bond_warn/bond_mode"
cat > "$_wiz_bond_warn/ethtool" <<'ETHTOOL'
Settings for eth0:
	Speed: 1000Mb/s
	Duplex: Full
	Auto-negotiation: on
	Link detected: yes
ETHTOOL
echo "" > "$_wiz_bond_warn/ethtool_s"
echo "" > "$_wiz_bond_warn/ethtool_eee"
echo "" > "$_wiz_bond_warn/ethtool_i"
echo "" > "$_wiz_bond_warn/ip_link"
echo "" > "$_wiz_bond_warn/dmesg"
echo "" > "$_wiz_bond_warn/ip_addr"
echo "" > "$_wiz_bond_warn/ip_route"
echo "" > "$_wiz_bond_warn/all_links"
echo "" > "$_wiz_bond_warn/resolv_conf"
echo "" > "$_wiz_bond_warn/ethtool_m"
echo "" > "$_wiz_bond_warn/lldpctl"

OUT=''; EXITCODE=0
OUT=$(BACKUP_DIR="$TESTDIR/backups" REPORT_DIR="$TESTDIR/reports" \
      _LINK_FLAP_TEST_WIZARD_DIR="$_wiz_bond_warn" \
      _LINK_FLAP_TEST_BOND_MASTERS="eth0=bond0" \
      bash "$SCRIPT" -d eth0 2>&1) || EXITCODE=$?
if echo "$OUT" | grep -q "Bond member instability" \
   && echo "$OUT" | grep -q "WARN"; then
  pass "122: Wizard WARN when member carrier_changes >> bond"
else
  fail "122: Wizard WARN when member carrier_changes >> bond" \
       "exit=$EXITCODE\n$OUT"
fi

# ── 123: No bond annotation when interface is not a bond member ──────────────
OUT=''; EXITCODE=0
OUT=$(_LINK_FLAP_TEST_INPUT="$_bond_input" \
      bash "$SCRIPT" -w 60 2>&1) || EXITCODE=$?
if [[ $EXITCODE -eq 1 ]] && ! echo "$OUT" | grep -q "bond member"; then
  pass "123: No bond annotation when interface is not a bond member"
else
  fail "123: No bond annotation when interface is not a bond member" \
       "exit=$EXITCODE\n$OUT"
fi

# ── 124: Bond mode shown in wizard finding ───────────────────────────────────
# Reuse _wiz_bond from test 121 which has bond_mode="balance-rr 0"
OUT=''; EXITCODE=0
OUT=$(BACKUP_DIR="$TESTDIR/backups" REPORT_DIR="$TESTDIR/reports" \
      _LINK_FLAP_TEST_WIZARD_DIR="$_wiz_bond" \
      _LINK_FLAP_TEST_BOND_MASTERS="eth0=bond0" \
      bash "$SCRIPT" -d eth0 2>&1) || EXITCODE=$?
if echo "$OUT" | grep -q "balance-rr"; then
  pass "124: Bond mode shown in wizard finding"
else
  fail "124: Bond mode shown in wizard finding" \
       "exit=$EXITCODE\n$OUT"
fi
