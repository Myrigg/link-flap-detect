#!/usr/bin/env bash
# tests/test-wizard-new-checks.sh
# Automated tests: new wizard diagnostic checks — MTU mismatch, autoneg
# mismatch, FEC mode, pause frames, and duplex mismatch.
#
# Tests covered: 223–229
#
# Usage (standalone):  bash tests/test-wizard-new-checks.sh
# Usage (via runner):  sourced by tests/run-tests.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo ""
echo -e "${BOLD}Offline tests — wizard new diagnostic checks${RESET}"
echo ""

# ── 223: MTU mismatch → [WARN] with "MTU" in output ─────────────────────────
wiz_dir=$(mktemp -d "$TESTDIR/wiz223-XXXXXX")
make_wizard_fixture "$wiz_dir"
echo "1500" > "$wiz_dir/mtu"
cat > "$wiz_dir/lldpctl" <<'FIXTURE'
Interface: eth0
  ChassisID:  mac 00:11:22:33:44:55
  SysName:    switch01
  Maximum Frame Size: 9000
FIXTURE
run_wizard_test "$wiz_dir" -d eth0
if echo "$OUT" | grep -qi "\[WARN\]" && echo "$OUT" | grep -qi "MTU"; then
  pass "223: MTU mismatch (local 1500, peer 9000) → [WARN] with MTU"
else
  fail "223: MTU mismatch (local 1500, peer 9000) → [WARN] with MTU" \
       "exit=$EXITCODE\n$OUT"
fi

# ── 224: Autoneg mismatch → [WARN] with "autoneg" in output ─────────────────
wiz_dir=$(mktemp -d "$TESTDIR/wiz224-XXXXXX")
make_wizard_fixture "$wiz_dir"
cat > "$wiz_dir/ethtool" <<'FIXTURE'
Settings for eth0:
    Speed: 1000Mb/s
    Duplex: Full
    Auto-negotiation: on
    Link detected: yes
    Link partner advertised auto-negotiation: No
FIXTURE
run_wizard_test "$wiz_dir" -d eth0
if echo "$OUT" | grep -qi "\[WARN\]" && echo "$OUT" | grep -qi "utoneg.*mismatch\|mismatch.*utoneg"; then
  pass "224: Autoneg mismatch (local on, peer No) → [WARN] with autoneg"
else
  fail "224: Autoneg mismatch (local on, peer No) → [WARN] with autoneg" \
       "exit=$EXITCODE\n$OUT"
fi

# ── 225: FEC disabled on 25G → [WARN] with "FEC" in output ──────────────────
wiz_dir=$(mktemp -d "$TESTDIR/wiz225-XXXXXX")
make_wizard_fixture "$wiz_dir"
cat > "$wiz_dir/ethtool" <<'FIXTURE'
Settings for eth0:
    Speed: 25000Mb/s
    Duplex: Full
    Auto-negotiation: on
    Link detected: yes
FIXTURE
cat > "$wiz_dir/ethtool_fec" <<'FIXTURE'
FEC parameters for eth0:
    Active FEC encoding: Off
    Configured FEC encodings: Off
FIXTURE
run_wizard_test "$wiz_dir" -d eth0
if echo "$OUT" | grep -qi "\[WARN\]" && echo "$OUT" | grep -qi "FEC"; then
  pass "225: FEC disabled on 25G → [WARN] with FEC"
else
  fail "225: FEC disabled on 25G → [WARN] with FEC" \
       "exit=$EXITCODE\n$OUT"
fi

# ── 226: Excessive pause frames → [WARN] with "pause" in output ─────────────
wiz_dir=$(mktemp -d "$TESTDIR/wiz226-XXXXXX")
make_wizard_fixture "$wiz_dir"
cat > "$wiz_dir/ethtool_s" <<'FIXTURE'
NIC statistics:
    rx_pause: 5000
    tx_pause: 2000
    rx_crc_errors: 0
FIXTURE
run_wizard_test "$wiz_dir" -d eth0
if echo "$OUT" | grep -qi "\[WARN\]" && echo "$OUT" | grep -qi "pause"; then
  pass "226: Excessive pause frames → [WARN] with pause"
else
  fail "226: Excessive pause frames → [WARN] with pause" \
       "exit=$EXITCODE\n$OUT"
fi

# ── 227: Duplex mismatch (full/half) → [CAUSE] with "Duplex mismatch" ───────
wiz_dir=$(mktemp -d "$TESTDIR/wiz227-XXXXXX")
make_wizard_fixture "$wiz_dir"
cat > "$wiz_dir/ethtool" <<'FIXTURE'
Settings for eth0:
    Speed: 100Mb/s
    Duplex: Full
    Auto-negotiation: on
    Link detected: yes
    Link partner advertised auto-negotiation: Yes
    Link partner advertised Duplex: Half
FIXTURE
run_wizard_test "$wiz_dir" -d eth0
if echo "$OUT" | grep -qi "\[CAUSE\]" && echo "$OUT" | grep -qi "Duplex mismatch"; then
  pass "227: Duplex mismatch (Full/Half) → [CAUSE] with Duplex mismatch"
else
  fail "227: Duplex mismatch (Full/Half) → [CAUSE] with Duplex mismatch" \
       "exit=$EXITCODE\n$OUT"
fi

# ── 228: FEC enabled (RS) on 25G → no FEC warning (negative) ────────────────
wiz_dir=$(mktemp -d "$TESTDIR/wiz228-XXXXXX")
make_wizard_fixture "$wiz_dir"
cat > "$wiz_dir/ethtool" <<'FIXTURE'
Settings for eth0:
    Speed: 25000Mb/s
    Duplex: Full
    Auto-negotiation: on
    Link detected: yes
FIXTURE
cat > "$wiz_dir/ethtool_fec" <<'FIXTURE'
FEC parameters for eth0:
    Active FEC encoding: RS
    Configured FEC encodings: RS
FIXTURE
run_wizard_test "$wiz_dir" -d eth0
if ! echo "$OUT" | grep -qi "FEC disabled\|FEC.*Off"; then
  pass "228: FEC enabled (RS) on 25G → no FEC warning"
else
  fail "228: FEC enabled (RS) on 25G → no FEC warning" \
       "exit=$EXITCODE\n$OUT"
fi

# ── 229: FEC check skipped on 1G → no FEC in findings ───────────────────────
wiz_dir=$(mktemp -d "$TESTDIR/wiz229-XXXXXX")
make_wizard_fixture "$wiz_dir"
cat > "$wiz_dir/ethtool_fec" <<'FIXTURE'
FEC parameters for eth0:
    Active FEC encoding: Off
    Configured FEC encodings: Off
FIXTURE
run_wizard_test "$wiz_dir" -d eth0
if ! echo "$OUT" | grep -qi "FEC disabled\|FEC.*Off"; then
  pass "229: FEC check skipped on 1G → no FEC in findings"
else
  fail "229: FEC check skipped on 1G → no FEC in findings" \
       "exit=$EXITCODE\n$OUT"
fi
