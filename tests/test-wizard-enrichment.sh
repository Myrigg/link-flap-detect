#!/usr/bin/env bash
# tests/test-wizard-enrichment.sh
# Automated tests: wizard contextual enrichment — severity tiers and synthesis.
#
# Tests covered: 78–82, 207–209
#
# Verifies that the wizard raises correctly-levelled findings for:
#   - Unknown speed/duplex (autoneg failure)
#   - High TX drop counts (> 5000 → CAUSE)
#   - High RX drop counts (> 5000 → CAUSE)
#   - Severe carrier instability (> 500 → CAUSE, not just WARN)
#   - Combined physical-layer failure signature (>= 2 indicators → CAUSE)
#
# All tests are fully offline. node_exporter data is injected via
# _LINK_FLAP_TEST_NODE_EXPORTER; sysfs/ethtool data via _LINK_FLAP_TEST_WIZARD_DIR.
#
# Usage (standalone):  bash tests/test-wizard-enrichment.sh
# Usage (via runner):  sourced by tests/run-tests.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo ""
echo -e "${BOLD}Offline tests — wizard contextual enrichment${RESET}"
echo ""

# ── 78: Unknown speed → CAUSE ─────────────────────────────────────────────────
wiz_dir=$(mktemp -d "$TESTDIR/wiz-enrich-XXXXXX")
echo "unknown" > "$wiz_dir/operstate"
cat > "$wiz_dir/ethtool" <<'EOF'
Settings for enp2s0:
    Supported ports: [ TP ]
    Speed: Unknown!
    Duplex: Unknown!
    Auto-negotiation: off
    Link detected: no
EOF

run_wizard_test "$wiz_dir" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                              || ok=0
echo "$OUT" | grep -q "\[CAUSE\]"                  || ok=0
echo "$OUT" | grep -qi "speed"                     || ok=0

if [[ $ok -eq 1 ]]; then
  pass "78: wizard [CAUSE] when speed is Unknown! (autoneg failure)"
else
  fail "78: wizard [CAUSE] when speed is Unknown! (autoneg failure)" "exit=$EXITCODE\n$OUT"
fi

# ── 79: TX drops > 5000 → CAUSE ──────────────────────────────────────────────
wiz_dir=$(mktemp -d "$TESTDIR/wiz-txdrop-XXXXXX")
echo "up" > "$wiz_dir/operstate"

NE_TX_DROP=$(mktemp "$TESTDIR/ne-txdrop-XXXXXX.txt")
cat > "$NE_TX_DROP" <<'EOF'
node_network_up{device="eth0"} 1
node_network_carrier_changes_total{device="eth0"} 5
node_network_receive_errs_total{device="eth0"} 0
node_network_transmit_errs_total{device="eth0"} 0
node_network_receive_drop_total{device="eth0"} 0
node_network_transmit_drop_total{device="eth0"} 53792
EOF

run_wizard_ne_test "$wiz_dir" "$NE_TX_DROP" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                              || ok=0
echo "$OUT" | grep -q "\[CAUSE\]"                  || ok=0
echo "$OUT" | grep -qi "TX drop"                   || ok=0

if [[ $ok -eq 1 ]]; then
  pass "79: wizard [CAUSE] for TX drops > 5000 (exit=$EXITCODE)"
else
  fail "79: wizard [CAUSE] for TX drops > 5000" "exit=$EXITCODE\n$OUT"
fi

# ── 80: RX drops > 5000 → CAUSE ──────────────────────────────────────────────
wiz_dir=$(mktemp -d "$TESTDIR/wiz-rxdrop-XXXXXX")
echo "up" > "$wiz_dir/operstate"

NE_RX_DROP=$(mktemp "$TESTDIR/ne-rxdrop-XXXXXX.txt")
cat > "$NE_RX_DROP" <<'EOF'
node_network_up{device="eth0"} 1
node_network_carrier_changes_total{device="eth0"} 5
node_network_receive_errs_total{device="eth0"} 0
node_network_transmit_errs_total{device="eth0"} 0
node_network_receive_drop_total{device="eth0"} 10000
node_network_transmit_drop_total{device="eth0"} 0
EOF

run_wizard_ne_test "$wiz_dir" "$NE_RX_DROP" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                              || ok=0
echo "$OUT" | grep -q "\[CAUSE\]"                  || ok=0
echo "$OUT" | grep -qi "RX drop"                   || ok=0

if [[ $ok -eq 1 ]]; then
  pass "80: wizard [CAUSE] for RX drops > 5000 (exit=$EXITCODE)"
else
  fail "80: wizard [CAUSE] for RX drops > 5000" "exit=$EXITCODE\n$OUT"
fi

# ── 81: carrier_changes > 500 → CAUSE (not just WARN) ─────────────────────────
wiz_dir=$(mktemp -d "$TESTDIR/wiz-cc-XXXXXX")
echo "up" > "$wiz_dir/operstate"
echo "1000" > "$wiz_dir/carrier_changes"

run_wizard_test "$wiz_dir" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                              || ok=0
echo "$OUT" | grep -q "\[CAUSE\]"                  || ok=0
echo "$OUT" | grep -qi "carrier"                   || ok=0

if [[ $ok -eq 1 ]]; then
  pass "81: wizard [CAUSE] for carrier_changes > 500 (exit=$EXITCODE)"
else
  fail "81: wizard [CAUSE] for carrier_changes > 500" "exit=$EXITCODE\n$OUT"
fi

# ── 82: Combined physical-layer signature → CAUSE "Physical layer" ─────────────
wiz_dir=$(mktemp -d "$TESTDIR/wiz-phys-XXXXXX")
echo "unknown" > "$wiz_dir/operstate"
echo "1000" > "$wiz_dir/carrier_changes"
cat > "$wiz_dir/ethtool" <<'EOF'
Settings for enp2s0:
    Speed: Unknown!
    Duplex: Unknown!
    Auto-negotiation: off
    Link detected: no
EOF

NE_PHYS=$(mktemp "$TESTDIR/ne-phys-XXXXXX.txt")
cat > "$NE_PHYS" <<'EOF'
node_network_up{device="eth0"} 0
node_network_carrier_changes_total{device="eth0"} 1000
node_network_receive_errs_total{device="eth0"} 0
node_network_transmit_errs_total{device="eth0"} 33
node_network_receive_drop_total{device="eth0"} 0
node_network_transmit_drop_total{device="eth0"} 10000
EOF

run_wizard_ne_test "$wiz_dir" "$NE_PHYS" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                              || ok=0
echo "$OUT" | grep -q "\[CAUSE\]"                  || ok=0
echo "$OUT" | grep -qi "physical layer"            || ok=0

if [[ $ok -eq 1 ]]; then
  pass "82: wizard [CAUSE] physical layer failure signature (exit=$EXITCODE)"
else
  fail "82: wizard [CAUSE] physical layer failure signature" "exit=$EXITCODE\n$OUT"
fi

# ── 207: TX errors (node_exporter) → WARN ──────────────────────────────────
wiz_dir=$(mktemp -d "$TESTDIR/wiz-txerr-XXXXXX")
make_wizard_fixture "$wiz_dir"

NE_TX_ERR=$(mktemp "$TESTDIR/ne-txerr-XXXXXX.txt")
cat > "$NE_TX_ERR" <<'EOF'
node_network_up{device="eth0"} 1
node_network_carrier_changes_total{device="eth0"} 5
node_network_receive_errs_total{device="eth0"} 0
node_network_transmit_errs_total{device="eth0"} 5
node_network_receive_drop_total{device="eth0"} 0
node_network_transmit_drop_total{device="eth0"} 0
EOF

run_wizard_ne_test "$wiz_dir" "$NE_TX_ERR" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                              || ok=0
echo "$OUT" | grep -q "\[WARN\]"                  || ok=0
echo "$OUT" | grep -qi "TX error"                  || ok=0

if [[ $ok -eq 1 ]]; then
  pass "207: wizard [WARN] for TX errors via node_exporter (exit=$EXITCODE)"
else
  fail "207: wizard [WARN] for TX errors via node_exporter" "exit=$EXITCODE\n$OUT"
fi

# ── 208: Rate-based TX drops > 1% → CAUSE ──────────────────────────────────
wiz_dir=$(mktemp -d "$TESTDIR/wiz-txrate-XXXXXX")
make_wizard_fixture "$wiz_dir"

NE_TX_RATE=$(mktemp "$TESTDIR/ne-txrate-XXXXXX.txt")
cat > "$NE_TX_RATE" <<'EOF'
node_network_up{device="eth0"} 1
node_network_carrier_changes_total{device="eth0"} 5
node_network_receive_errs_total{device="eth0"} 0
node_network_transmit_errs_total{device="eth0"} 0
node_network_receive_drop_total{device="eth0"} 0
node_network_transmit_drop_total{device="eth0"} 2000
node_network_receive_packets_total{device="eth0"} 100000
node_network_transmit_packets_total{device="eth0"} 100000
EOF

run_wizard_ne_test "$wiz_dir" "$NE_TX_RATE" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                              || ok=0
echo "$OUT" | grep -q "\[CAUSE\]"                  || ok=0
echo "$OUT" | grep -qi "TX.*packet loss\|TX.*drop"  || ok=0

if [[ $ok -eq 1 ]]; then
  pass "208: wizard [CAUSE] for rate-based TX drops > 1% (exit=$EXITCODE)"
else
  fail "208: wizard [CAUSE] for rate-based TX drops > 1%" "exit=$EXITCODE\n$OUT"
fi

# ── 209: Rate-based RX drops 0.1%–1% → WARN ────────────────────────────────
wiz_dir=$(mktemp -d "$TESTDIR/wiz-rxrate-XXXXXX")
make_wizard_fixture "$wiz_dir"

NE_RX_RATE=$(mktemp "$TESTDIR/ne-rxrate-XXXXXX.txt")
cat > "$NE_RX_RATE" <<'EOF'
node_network_up{device="eth0"} 1
node_network_carrier_changes_total{device="eth0"} 5
node_network_receive_errs_total{device="eth0"} 0
node_network_transmit_errs_total{device="eth0"} 0
node_network_receive_drop_total{device="eth0"} 300
node_network_transmit_drop_total{device="eth0"} 0
node_network_receive_packets_total{device="eth0"} 100000
node_network_transmit_packets_total{device="eth0"} 100000
EOF

run_wizard_ne_test "$wiz_dir" "$NE_RX_RATE" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                              || ok=0
echo "$OUT" | grep -q "\[WARN\]"                   || ok=0
echo "$OUT" | grep -qi "RX.*packet loss\|RX.*drop"  || ok=0

if [[ $ok -eq 1 ]]; then
  pass "209: wizard [WARN] for rate-based RX drops 0.3% (exit=$EXITCODE)"
else
  fail "209: wizard [WARN] for rate-based RX drops 0.3%" "exit=$EXITCODE\n$OUT"
fi
