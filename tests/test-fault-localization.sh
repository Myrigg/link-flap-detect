#!/usr/bin/env bash
# tests/test-fault-localization.sh
# Automated tests: fault localization — layer-by-layer fault report.
#
# Tests covered: 83–90
#
# Verifies that the [FAULT LOCALIZATION] section of the wizard report
# correctly identifies:
#   83: Driver name displayed from ethtool -i output
#   84: Physical layer SUSPECT when speed is Unknown!
#   85: Gateway reachable — Layer 3 OK
#   86: Gateway unreachable — Layer 3 SUSPECT
#   87: VPN detected when tun0 appears in ip link show
#   88: DNS OK when resolv.conf + dig return a result
#   89: DUT SUSPECT when DUT carrier_changes >> host
#   90: Verdict names "PHYSICAL" when only Layer 1 is SUSPECT
#
# All tests are fully offline — live network commands (ping, dig) are
# mocked via the _wiz_cmd file mechanism in _LINK_FLAP_TEST_WIZARD_DIR.
#
# Usage (standalone):  bash tests/test-fault-localization.sh
# Usage (via runner):  sourced by tests/run-tests.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo ""
echo -e "${BOLD}Offline tests — fault localization${RESET}"
echo ""

# ── Shared base wizard dir (stable, no issues) ────────────────────────────────
_fl_base() {
  local d
  d=$(mktemp -d "$TESTDIR/wiz-fl-XXXXXX")
  echo "up"  > "$d/operstate"
  echo "3"   > "$d/carrier_changes"
  # Healthy ethtool output
  cat > "$d/ethtool" <<'EOF'
Settings for eth0:
    Speed: 1000Mb/s
    Duplex: Full
    Auto-negotiation: on
    Link detected: yes
EOF
  # No driver errors in dmesg
  echo "" > "$d/dmesg"
  # No EEE
  echo "EEE status: disabled" > "$d/ethtool_eee"
  # Stable routing
  echo "default via 192.168.1.1 dev eth0" > "$d/ip_route"
  # No VPN interfaces
  cat > "$d/all_links" <<'EOF'
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500
EOF
  # Healthy resolv.conf
  echo "nameserver 8.8.8.8" > "$d/resolv_conf"
  echo "$d"
}

# ── 83: Driver name shown from ethtool -i ─────────────────────────────────────
wiz_dir=$(_fl_base)
cat > "$wiz_dir/ethtool_i" <<'EOF'
driver: e1000e
version: 3.8.7-NAPI
firmware-version: 3.25.0
EOF

run_wizard_test "$wiz_dir" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                    || ok=0
echo "$OUT" | grep -q "e1000e"           || ok=0

if [[ $ok -eq 1 ]]; then
  pass "83: fault localization shows driver name from ethtool -i (exit=$EXITCODE)"
else
  fail "83: fault localization shows driver name from ethtool -i" "exit=$EXITCODE\n$OUT"
fi

# ── 84: Physical SUSPECT when Unknown speed ────────────────────────────────────
wiz_dir=$(_fl_base)
echo "1000" > "$wiz_dir/carrier_changes"
cat > "$wiz_dir/ethtool" <<'EOF'
Settings for eth0:
    Speed: Unknown!
    Duplex: Unknown!
    Auto-negotiation: off
    Link detected: no
EOF

run_wizard_test "$wiz_dir" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                            || ok=0
echo "$OUT" | grep -i "Physical"                 || ok=0
echo "$OUT" | grep -q "SUSPECT"                  || ok=0

if [[ $ok -eq 1 ]]; then
  pass "84: fault localization Physical SUSPECT for Unknown speed + high carrier_changes (exit=$EXITCODE)"
else
  fail "84: fault localization Physical SUSPECT for Unknown speed + high carrier_changes" "exit=$EXITCODE\n$OUT"
fi

# ── 85: Gateway reachable — Layer 3 OK ───────────────────────────────────────
wiz_dir=$(_fl_base)
# Canned ping output showing 1 received
cat > "$wiz_dir/ping_gw" <<'EOF'
PING 192.168.1.1 (192.168.1.1) 56(84) bytes of data.
64 bytes from 192.168.1.1: icmp_seq=1 ttl=64 time=1.82 ms

--- 192.168.1.1 ping statistics ---
1 packets transmitted, 1 received, 0% packet loss, time 0ms
rtt min/avg/max/mdev = 1.821/1.821/1.821/0.000 ms
EOF
cat > "$wiz_dir/ping_inet" <<'EOF'
PING 8.8.8.8 (8.8.8.8) 56(84) bytes of data.
64 bytes from 8.8.8.8: icmp_seq=1 ttl=118 time=12.3 ms

--- 8.8.8.8 ping statistics ---
1 packets transmitted, 1 received, 0% packet loss
EOF
cat > "$wiz_dir/dig_dns" <<'EOF'
142.250.80.46
EOF

run_wizard_test "$wiz_dir" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                            || ok=0
echo "$OUT" | grep -q "192.168.1.1"              || ok=0
echo "$OUT" | grep -qi "reachable"               || ok=0

if [[ $ok -eq 1 ]]; then
  pass "85: fault localization Layer 3 OK — gateway reachable (exit=$EXITCODE)"
else
  fail "85: fault localization Layer 3 OK — gateway reachable" "exit=$EXITCODE\n$OUT"
fi

# ── 86: Gateway unreachable — Layer 3 SUSPECT ────────────────────────────────
wiz_dir=$(_fl_base)
# Canned ping output showing 0 received
cat > "$wiz_dir/ping_gw" <<'EOF'
PING 192.168.1.1 (192.168.1.1) 56(84) bytes of data.

--- 192.168.1.1 ping statistics ---
1 packets transmitted, 0 received, 100% packet loss, time 2000ms
EOF
cat > "$wiz_dir/dig_dns" <<'EOF'
EOF

run_wizard_test "$wiz_dir" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                             || ok=0
echo "$OUT" | grep -qi "SUSPECT"                  || ok=0
echo "$OUT" | grep -qi "gateway\|Layer 3"         || ok=0

if [[ $ok -eq 1 ]]; then
  pass "86: fault localization Layer 3 SUSPECT — gateway unreachable (exit=$EXITCODE)"
else
  fail "86: fault localization Layer 3 SUSPECT — gateway unreachable" "exit=$EXITCODE\n$OUT"
fi

# ── 87: VPN detected when tun0 in ip link show ───────────────────────────────
wiz_dir=$(_fl_base)
cat > "$wiz_dir/all_links" <<'EOF'
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500
3: tun0: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP> mtu 1500
EOF

run_wizard_test "$wiz_dir" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                       || ok=0
echo "$OUT" | grep -q "tun0"                || ok=0
echo "$OUT" | grep -qi "VPN\|tunnel"        || ok=0

if [[ $ok -eq 1 ]]; then
  pass "87: fault localization VPN detected — tun0 in ip link show (exit=$EXITCODE)"
else
  fail "87: fault localization VPN detected — tun0 in ip link show" "exit=$EXITCODE\n$OUT"
fi

# ── 88: DNS OK when resolv.conf + dig return result ──────────────────────────
wiz_dir=$(_fl_base)
echo "nameserver 8.8.8.8" > "$wiz_dir/resolv_conf"
echo "142.250.80.46"      > "$wiz_dir/dig_dns"
# Gateway reachable (so Layer 3 doesn't confuse verdict)
cat > "$wiz_dir/ping_gw" <<'EOF'
1 packets transmitted, 1 received, 0% packet loss
EOF

run_wizard_test "$wiz_dir" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                      || ok=0
echo "$OUT" | grep -qi "DNS"               || ok=0
echo "$OUT" | grep -q "8.8.8.8"           || ok=0

if [[ $ok -eq 1 ]]; then
  pass "88: fault localization DNS OK — resolv.conf + dig result present (exit=$EXITCODE)"
else
  fail "88: fault localization DNS OK — resolv.conf + dig result present" "exit=$EXITCODE\n$OUT"
fi

# ── 89: DUT SUSPECT when DUT carrier_changes >> host ─────────────────────────
wiz_dir=$(_fl_base)
echo "2" > "$wiz_dir/carrier_changes"
# Gateway reachable
cat > "$wiz_dir/ping_gw" <<'EOF'
1 packets transmitted, 1 received, 0% packet loss
EOF

dut_dir=$(mktemp -d "$TESTDIR/dut-XXXXXX")
echo "5000"    > "$dut_dir/carrier_changes"
echo "unknown" > "$dut_dir/operstate"
cat > "$dut_dir/dut_ethtool" <<'EOF'
Settings for eth1:
    Speed: Unknown!
    Duplex: Unknown!
    Auto-negotiation: off
    Link detected: no
EOF

run_fault_loc_test "$wiz_dir" "$dut_dir" "eth1" -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                         || ok=0
echo "$OUT" | grep -qi "DUT"                  || ok=0
echo "$OUT" | grep -q "SUSPECT"               || ok=0

if [[ $ok -eq 1 ]]; then
  pass "89: fault localization DUT SUSPECT when DUT carrier_changes >> host (exit=$EXITCODE)"
else
  fail "89: fault localization DUT SUSPECT when DUT carrier_changes >> host" "exit=$EXITCODE\n$OUT"
fi

# ── 90: Verdict names "PHYSICAL" when only Layer 1 is SUSPECT ─────────────────
wiz_dir=$(_fl_base)
echo "1000" > "$wiz_dir/carrier_changes"
cat > "$wiz_dir/ethtool" <<'EOF'
Settings for eth0:
    Speed: Unknown!
    Duplex: Unknown!
    Auto-negotiation: off
    Link detected: no
EOF
# Gateway reachable, DNS OK → only physical is suspect
cat > "$wiz_dir/ping_gw" <<'EOF'
1 packets transmitted, 1 received, 0% packet loss
EOF
cat > "$wiz_dir/ping_inet" <<'EOF'
1 packets transmitted, 1 received, 0% packet loss
EOF
echo "142.250.80.46" > "$wiz_dir/dig_dns"

run_wizard_test "$wiz_dir" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                            || ok=0
echo "$OUT" | grep -qi "VERDICT"                 || ok=0
echo "$OUT" | grep -qi "PHYSICAL"                || ok=0

if [[ $ok -eq 1 ]]; then
  pass "90: fault localization VERDICT names PHYSICAL when only Layer 1 is SUSPECT (exit=$EXITCODE)"
else
  fail "90: fault localization VERDICT names PHYSICAL when only Layer 1 is SUSPECT" "exit=$EXITCODE\n$OUT"
fi
