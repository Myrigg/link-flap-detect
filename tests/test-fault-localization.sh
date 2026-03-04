#!/usr/bin/env bash
# tests/test-fault-localization.sh
# Automated tests: fault localization — layer-by-layer fault report.
#
# Tests covered: 83–95, 96–99, 210–218, 219–219d, 220–222, 235–241
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
#   91: r8169 driver emits advisory in findings and fault localization
#   92: tg3 driver emits advisory with source URL
#   93: virtio_net driver emits INFO-level note (not WARN)
#   94: igb driver emits no advisory (negative test)
#   95: e1000e driver emits no advisory (negative test)
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
  # Power management off (not auto)
  echo "on"   > "$d/power_control"
  # MTU — healthy, no LLDP peer mismatch
  echo "1500" > "$d/mtu"
  echo ""     > "$d/lldpctl"
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

# ── 87b: VPN detected when tailscale0 in ip link show ───────────────────────
wiz_dir=$(_fl_base)
cat > "$wiz_dir/all_links" <<'EOF'
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500
3: tailscale0: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP> mtu 1280
EOF

run_wizard_test "$wiz_dir" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                          || ok=0
echo "$OUT" | grep -q "tailscale0"             || ok=0
echo "$OUT" | grep -qi "VPN\|tunnel"           || ok=0

if [[ $ok -eq 1 ]]; then
  pass "87b: fault localization VPN detected — tailscale0 in ip link show (exit=$EXITCODE)"
else
  fail "87b: fault localization VPN detected — tailscale0 in ip link show" "exit=$EXITCODE\n$OUT"
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

# ── 91: r8169 driver advisory in findings and fault localization ───────────────
wiz_dir=$(_fl_base)
cat > "$wiz_dir/ethtool_i" <<'EOF'
driver: r8169
version: 6.1.0-NAPI
firmware-version: rtl8168g-2_0.0.1 03/26/13
EOF

run_wizard_test "$wiz_dir" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                                        || ok=0
echo "$OUT" | grep -qi "advisory"                            || ok=0
echo "$OUT" | grep -qi "r8169"                               || ok=0
echo "$OUT" | grep -qi "realtek.com"                         || ok=0
echo "$OUT" | grep -qi "EEE"                                 || ok=0

if [[ $ok -eq 1 ]]; then
  pass "91: r8169 driver advisory shown with realtek.com source (exit=$EXITCODE)"
else
  fail "91: r8169 driver advisory shown with realtek.com source" "exit=$EXITCODE\n$OUT"
fi

# ── 92: tg3 driver advisory with kernel.org source URL ────────────────────────
wiz_dir=$(_fl_base)
cat > "$wiz_dir/ethtool_i" <<'EOF'
driver: tg3
version: 3.137
firmware-version: 5719-v1.39
EOF

run_wizard_test "$wiz_dir" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                                        || ok=0
echo "$OUT" | grep -qi "advisory"                            || ok=0
echo "$OUT" | grep -qi "tg3"                                 || ok=0
echo "$OUT" | grep -qi "kernel.org"                          || ok=0

if [[ $ok -eq 1 ]]; then
  pass "92: tg3 driver advisory shown with kernel.org source (exit=$EXITCODE)"
else
  fail "92: tg3 driver advisory shown with kernel.org source" "exit=$EXITCODE\n$OUT"
fi

# ── 93: virtio_net emits INFO-level note (not WARN) ───────────────────────────
wiz_dir=$(_fl_base)
cat > "$wiz_dir/ethtool_i" <<'EOF'
driver: virtio_net
version: 1.0.0
firmware-version: N/A
EOF

run_wizard_test "$wiz_dir" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                                        || ok=0
echo "$OUT" | grep -qi "virtio_net"                          || ok=0
echo "$OUT" | grep -qi "migration\|hypervisor"               || ok=0
echo "$OUT" | grep -qi "qemu.org"                            || ok=0
# Should be INFO level, not a WARN or CAUSE
echo "$OUT" | grep -qi "\[INFO\].*virtio\|\[INFO\].*driver note" || ok=0

if [[ $ok -eq 1 ]]; then
  pass "93: virtio_net emits INFO-level note with qemu.org source (exit=$EXITCODE)"
else
  fail "93: virtio_net emits INFO-level note with qemu.org source" "exit=$EXITCODE\n$OUT"
fi

# ── 94: igb driver emits no advisory (negative test) ──────────────────────────
wiz_dir=$(_fl_base)
cat > "$wiz_dir/ethtool_i" <<'EOF'
driver: igb
version: 5.14.2-k
firmware-version: 3.25.0
EOF

run_wizard_test "$wiz_dir" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                                        || ok=0
# No advisory should appear for igb
echo "$OUT" | grep -qi "Advisory" && ok=0 || true

if [[ $ok -eq 1 ]]; then
  pass "94: igb driver emits no advisory (exit=$EXITCODE)"
else
  fail "94: igb driver emits no advisory" "exit=$EXITCODE\n$OUT"
fi

# ── 95: e1000e driver emits no advisory (negative test) ───────────────────────
wiz_dir=$(_fl_base)
cat > "$wiz_dir/ethtool_i" <<'EOF'
driver: e1000e
version: 3.8.7-NAPI
firmware-version: 3.25.0
EOF

run_wizard_test "$wiz_dir" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                                        || ok=0
# No advisory should appear for e1000e
echo "$OUT" | grep -qi "Advisory" && ok=0 || true

if [[ $ok -eq 1 ]]; then
  pass "95: e1000e driver emits no advisory (exit=$EXITCODE)"
else
  fail "95: e1000e driver emits no advisory" "exit=$EXITCODE\n$OUT"
fi

# ── 96: cdc_ncm advisory emitted (WARN level, kernel.org source) ──────────────
wiz_dir=$(_fl_base)
cat > "$wiz_dir/ethtool_i" <<'EOF'
driver: cdc_ncm
version: (unset)
firmware-version: 6.17.9-14-generic
EOF
# cdc_ncm commonly reports Unknown speed — provide that so the USB path is exercised
cat > "$wiz_dir/ethtool" <<'EOF'
Settings for enx001122334455:
    Speed: Unknown!
    Duplex: Unknown!
    Auto-negotiation: off
    Link detected: yes
EOF
# Simulate USB-attached interface via fixture file
echo "/sys/devices/pci0000:00/0000:00:14.0/usb1/1-1/1-1.2/net/enx001122334455" \
  > "$wiz_dir/iface_usb_path"

run_wizard_test "$wiz_dir" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                                        || ok=0
echo "$OUT" | grep -qi "cdc_ncm"                             || ok=0
echo "$OUT" | grep -qi "advisory\|driver note"               || ok=0
echo "$OUT" | grep -qi "kernel.org"                          || ok=0
echo "$OUT" | grep -qi "USB"                                 || ok=0

if [[ $ok -eq 1 ]]; then
  pass "96: cdc_ncm driver advisory shown with kernel.org source (exit=$EXITCODE)"
else
  fail "96: cdc_ncm driver advisory shown with kernel.org source" "exit=$EXITCODE\n$OUT"
fi

# ── 97: cdc_ncm Unknown speed does NOT trigger Layer 1 SUSPECT ────────────────
#    For USB NICs, Unknown speed is a driver limitation, not an autoneg failure.
wiz_dir=$(_fl_base)
cat > "$wiz_dir/ethtool_i" <<'EOF'
driver: cdc_ncm
version: (unset)
firmware-version: 6.17.9-14-generic
EOF
cat > "$wiz_dir/ethtool" <<'EOF'
Settings for enx001122334455:
    Speed: Unknown!
    Duplex: Unknown!
    Auto-negotiation: off
    Link detected: yes
EOF
echo "2" > "$wiz_dir/carrier_changes"
echo "/sys/devices/pci0000:00/0000:00:14.0/usb1/1-1/1-1.2/net/enx001122334455" \
  > "$wiz_dir/iface_usb_path"

run_wizard_test "$wiz_dir" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                                        || ok=0
# Must NOT mark Layer 1 as SUSPECT solely because of Unknown speed on a USB NIC
if echo "$OUT" | grep -i "Layer 1" | grep -qi "SUSPECT"; then ok=0; fi
# The evidence line should mention "driver limitation", not "autoneg failed"
echo "$OUT" | grep -qi "limitation\|driver limit" || ok=0

if [[ $ok -eq 1 ]]; then
  pass "97: cdc_ncm Unknown speed does not trigger Layer 1 SUSPECT (exit=$EXITCODE)"
else
  fail "97: cdc_ncm Unknown speed does not trigger Layer 1 SUSPECT" "exit=$EXITCODE\n$OUT"
fi

# ── 98: cdc_ncm high RX drops + stable link → USB NIC finding emitted ─────────
wiz_dir=$(_fl_base)
cat > "$wiz_dir/ethtool_i" <<'EOF'
driver: cdc_ncm
version: (unset)
firmware-version: 6.17.9-14-generic
EOF
echo "2" > "$wiz_dir/carrier_changes"
echo "/sys/devices/pci0000:00/0000:00:14.0/usb1/1-1/1-1.2/net/enx001122334455" \
  > "$wiz_dir/iface_usb_path"

NE_CDC_DROPS=$(mktemp "$TESTDIR/ne-cdc-drop-XXXXXX.txt")
cat > "$NE_CDC_DROPS" <<'EOF'
node_network_up{device="eth0"} 1
node_network_carrier_changes_total{device="eth0"} 2
node_network_receive_errs_total{device="eth0"} 0
node_network_transmit_errs_total{device="eth0"} 0
node_network_receive_drop_total{device="eth0"} 50000
node_network_transmit_drop_total{device="eth0"} 0
node_network_receive_packets_total{device="eth0"} 500000
node_network_transmit_packets_total{device="eth0"} 500000
EOF

run_wizard_ne_test "$wiz_dir" "$NE_CDC_DROPS" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                                        || ok=0
echo "$OUT" | grep -qi "USB NIC"                             || ok=0
echo "$OUT" | grep -qi "stable link\|carrier"                || ok=0

if [[ $ok -eq 1 ]]; then
  pass "98: cdc_ncm high RX drops with stable link → USB NIC finding (exit=$EXITCODE)"
else
  fail "98: cdc_ncm high RX drops with stable link → USB NIC finding" "exit=$EXITCODE\n$OUT"
fi

# ── 99: Non-USB NIC Unknown speed still triggers Layer 1 SUSPECT (regression) ─
#    Confirms that the USB carve-out doesn't break the standard path.
wiz_dir=$(_fl_base)
cat > "$wiz_dir/ethtool_i" <<'EOF'
driver: igb
version: 5.14.2-k
firmware-version: 3.25.0
EOF
cat > "$wiz_dir/ethtool" <<'EOF'
Settings for eth0:
    Speed: Unknown!
    Duplex: Unknown!
    Auto-negotiation: off
    Link detected: yes
EOF
echo "3" > "$wiz_dir/carrier_changes"
# No iface_usb_path file → not a USB NIC

run_wizard_test "$wiz_dir" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                                                          || ok=0
# "Status : SUSPECT" appears 2–3 lines after "Layer 1 — Physical"
echo "$OUT" | grep -A3 "Layer 1 — Physical" | grep -qi "SUSPECT"              || ok=0
echo "$OUT" | grep -qi "autoneg failed"                                        || ok=0

if [[ $ok -eq 1 ]]; then
  pass "99: non-USB NIC Unknown speed still triggers Layer 1 SUSPECT (exit=$EXITCODE)"
else
  fail "99: non-USB NIC Unknown speed still triggers Layer 1 SUSPECT" "exit=$EXITCODE\n$OUT"
fi

# ── 210: Switch Port SUSPECT when half-duplex ──────────────────────────────
wiz_dir=$(_fl_base)
cat > "$wiz_dir/ethtool" <<'EOF'
Settings for eth0:
    Speed: 1000Mb/s
    Duplex: Half
    Auto-negotiation: on
    Link detected: yes
EOF
cat > "$wiz_dir/ping_gw" <<'EOF'
1 packets transmitted, 1 received, 0% packet loss
EOF

run_wizard_test "$wiz_dir" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                             || ok=0
echo "$OUT" | grep -qi "Switch Port"              || ok=0
echo "$OUT" | grep -q "SUSPECT"                   || ok=0

if [[ $ok -eq 1 ]]; then
  pass "210: fault localization Switch Port SUSPECT for half-duplex (exit=$EXITCODE)"
else
  fail "210: fault localization Switch Port SUSPECT for half-duplex" "exit=$EXITCODE\n$OUT"
fi

# ── 211: NIC Driver SUSPECT when dmesg reset ───────────────────────────────
wiz_dir=$(_fl_base)
printf '%s\n' "[12345.678] eth0: Reset adapter" > "$wiz_dir/dmesg"
cat > "$wiz_dir/ping_gw" <<'EOF'
1 packets transmitted, 1 received, 0% packet loss
EOF

run_wizard_test "$wiz_dir" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                             || ok=0
echo "$OUT" | grep -qi "NIC Driver\|Driver"       || ok=0
echo "$OUT" | grep -q "SUSPECT"                   || ok=0

if [[ $ok -eq 1 ]]; then
  pass "211: fault localization NIC Driver SUSPECT for dmesg reset (exit=$EXITCODE)"
else
  fail "211: fault localization NIC Driver SUSPECT for dmesg reset" "exit=$EXITCODE\n$OUT"
fi

# ── 212: Internet UNREACHABLE (gateway OK) ─────────────────────────────────
wiz_dir=$(_fl_base)
cat > "$wiz_dir/ping_gw" <<'EOF'
PING 192.168.1.1 (192.168.1.1) 56(84) bytes of data.
64 bytes from 192.168.1.1: icmp_seq=1 ttl=64 time=1.82 ms

--- 192.168.1.1 ping statistics ---
1 packets transmitted, 1 received, 0% packet loss, time 0ms
EOF
cat > "$wiz_dir/ping_inet" <<'EOF'
PING 8.8.8.8 (8.8.8.8) 56(84) bytes of data.

--- 8.8.8.8 ping statistics ---
1 packets transmitted, 0 received, 100% packet loss, time 2000ms
EOF
echo "142.250.80.46" > "$wiz_dir/dig_dns"

run_wizard_test "$wiz_dir" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                             || ok=0
echo "$OUT" | grep -qi "Internet"                  || ok=0
echo "$OUT" | grep -qi "UNREACHABLE"               || ok=0

if [[ $ok -eq 1 ]]; then
  pass "212: fault localization Internet UNREACHABLE (gateway OK) (exit=$EXITCODE)"
else
  fail "212: fault localization Internet UNREACHABLE (gateway OK)" "exit=$EXITCODE\n$OUT"
fi

# ── 213: No default route → gateway UNKNOWN ────────────────────────────────
wiz_dir=$(_fl_base)
echo "10.0.0.0/24 dev eth0 scope link" > "$wiz_dir/ip_route"

run_wizard_test "$wiz_dir" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                             || ok=0
echo "$OUT" | grep -qi "not configured"            || ok=0

if [[ $ok -eq 1 ]]; then
  pass "213: fault localization no default route → 'not configured' (exit=$EXITCODE)"
else
  fail "213: fault localization no default route → 'not configured'" "exit=$EXITCODE\n$OUT"
fi

# ── 214: DNS SUSPECT (nameserver present, dig empty) ───────────────────────
wiz_dir=$(_fl_base)
echo "nameserver 8.8.8.8" > "$wiz_dir/resolv_conf"
echo "" > "$wiz_dir/dig_dns"
cat > "$wiz_dir/ping_gw" <<'EOF'
1 packets transmitted, 1 received, 0% packet loss
EOF

run_wizard_test "$wiz_dir" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                             || ok=0
echo "$OUT" | grep -qi "DNS"                       || ok=0
echo "$OUT" | grep -q "SUSPECT"                    || ok=0

if [[ $ok -eq 1 ]]; then
  pass "214: fault localization DNS SUSPECT (nameserver present, dig empty) (exit=$EXITCODE)"
else
  fail "214: fault localization DNS SUSPECT (nameserver present, dig empty)" "exit=$EXITCODE\n$OUT"
fi

# ── 215: Verdict — "No fault detected" ─────────────────────────────────────
wiz_dir=$(_fl_base)
cat > "$wiz_dir/ping_gw" <<'EOF'
1 packets transmitted, 1 received, 0% packet loss
EOF
cat > "$wiz_dir/ping_inet" <<'EOF'
1 packets transmitted, 1 received, 0% packet loss
EOF
echo "142.250.80.46" > "$wiz_dir/dig_dns"
cat > "$wiz_dir/ethtool_i" <<'EOF'
driver: e1000e
version: 3.8.7-NAPI
firmware-version: 3.25.0
EOF

run_wizard_test "$wiz_dir" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                             || ok=0
echo "$OUT" | grep -qi "No fault detected"         || ok=0
# Switch Port should be OK (not UNKNOWN) for a healthy link
echo "$OUT" | grep -A3 "Layer 2 — Switch Port" | grep -qi "OK" || ok=0

if [[ $ok -eq 1 ]]; then
  pass "215: fault localization verdict 'No fault detected' + Switch Port OK (exit=$EXITCODE)"
else
  fail "215: fault localization verdict 'No fault detected' + Switch Port OK" "exit=$EXITCODE\n$OUT"
fi

# ── 216: Verdict — "NIC DRIVER or firmware" ────────────────────────────────
wiz_dir=$(_fl_base)
printf '%s\n' "[12345.678] eth0: Reset adapter" > "$wiz_dir/dmesg"
cat > "$wiz_dir/ping_gw" <<'EOF'
1 packets transmitted, 1 received, 0% packet loss
EOF
cat > "$wiz_dir/ping_inet" <<'EOF'
1 packets transmitted, 1 received, 0% packet loss
EOF
echo "142.250.80.46" > "$wiz_dir/dig_dns"

run_wizard_test "$wiz_dir" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                             || ok=0
echo "$OUT" | grep -qi "NIC DRIVER"                || ok=0

if [[ $ok -eq 1 ]]; then
  pass "216: fault localization verdict 'NIC DRIVER or firmware' (exit=$EXITCODE)"
else
  fail "216: fault localization verdict 'NIC DRIVER or firmware'" "exit=$EXITCODE\n$OUT"
fi

# ── 217: Verdict — "Physical and driver both" ──────────────────────────────
wiz_dir=$(_fl_base)
echo "1000" > "$wiz_dir/carrier_changes"
cat > "$wiz_dir/ethtool" <<'EOF'
Settings for eth0:
    Speed: Unknown!
    Duplex: Unknown!
    Auto-negotiation: off
    Link detected: no
EOF
printf '%s\n' "[12345.678] eth0: Reset adapter" > "$wiz_dir/dmesg"
cat > "$wiz_dir/ping_gw" <<'EOF'
1 packets transmitted, 1 received, 0% packet loss
EOF
cat > "$wiz_dir/ping_inet" <<'EOF'
1 packets transmitted, 1 received, 0% packet loss
EOF
echo "142.250.80.46" > "$wiz_dir/dig_dns"

run_wizard_test "$wiz_dir" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                             || ok=0
echo "$OUT" | grep -qi "Physical.*driver\|physical layer and driver" || ok=0

if [[ $ok -eq 1 ]]; then
  pass "217: fault localization verdict 'Physical and driver both' (exit=$EXITCODE)"
else
  fail "217: fault localization verdict 'Physical and driver both'" "exit=$EXITCODE\n$OUT"
fi

# ── 218: USB NIC fault localization says "driver limitation", not SUSPECT ──
wiz_dir=$(_fl_base)
cat > "$wiz_dir/ethtool_i" <<'EOF'
driver: cdc_ncm
version: (unset)
firmware-version: 6.17.9-14-generic
EOF
cat > "$wiz_dir/ethtool" <<'EOF'
Settings for enx001122334455:
    Speed: Unknown!
    Duplex: Unknown!
    Auto-negotiation: off
    Link detected: yes
EOF
echo "2" > "$wiz_dir/carrier_changes"
echo "/sys/devices/pci0000:00/0000:00:14.0/usb1/1-1/1-1.2/net/enx001122334455" \
  > "$wiz_dir/iface_usb_path"
cat > "$wiz_dir/ping_gw" <<'EOF'
1 packets transmitted, 1 received, 0% packet loss
EOF
cat > "$wiz_dir/ping_inet" <<'EOF'
1 packets transmitted, 1 received, 0% packet loss
EOF
echo "142.250.80.46" > "$wiz_dir/dig_dns"

run_wizard_test "$wiz_dir" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                                                          || ok=0
# Layer 1 must NOT be SUSPECT for USB NIC with Unknown speed
if echo "$OUT" | grep -i "Layer 1" | grep -qi "SUSPECT"; then ok=0; fi
# Evidence should mention "driver limitation"
echo "$OUT" | grep -qi "limitation\|driver limit"                               || ok=0
# USB path should appear in fault localization output
echo "$OUT" | grep -qi "USB path\|usb"                                          || ok=0

if [[ $ok -eq 1 ]]; then
  pass "218: USB NIC fault localization shows 'driver limitation' not SUSPECT (exit=$EXITCODE)"
else
  fail "218: USB NIC fault localization shows 'driver limitation' not SUSPECT" "exit=$EXITCODE\n$OUT"
fi

# ── 219: Switch Port SUSPECT → verdict mentions SWITCH PORT ──────────────
wiz_dir=$(_fl_base)
cat > "$wiz_dir/ethtool" <<'EOF'
Settings for eth0:
    Speed: 1000Mb/s
    Duplex: Half
    Auto-negotiation: on
    Link detected: yes
EOF
# All other layers healthy
cat > "$wiz_dir/ping_gw" <<'EOF'
1 packets transmitted, 1 received, 0% packet loss
EOF
cat > "$wiz_dir/ping_inet" <<'EOF'
1 packets transmitted, 1 received, 0% packet loss
EOF
echo "142.250.80.46" > "$wiz_dir/dig_dns"

run_wizard_test "$wiz_dir" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                             || ok=0
echo "$OUT" | grep -qi "VERDICT"                   || ok=0
echo "$OUT" | grep -qi "SWITCH PORT"               || ok=0

if [[ $ok -eq 1 ]]; then
  pass "219: fault localization verdict mentions SWITCH PORT for half-duplex (exit=$EXITCODE)"
else
  fail "219: fault localization verdict mentions SWITCH PORT for half-duplex" "exit=$EXITCODE\n$OUT"
fi

# ── 219b: Duplex mismatch → Switch Port SUSPECT + verdict mentions SWITCH PORT ─
wiz_dir=$(_fl_base)
cat > "$wiz_dir/ethtool" <<'EOF'
Settings for eth0:
    Speed: 1000Mb/s
    Duplex: Full
    Auto-negotiation: on
    Link detected: yes
    Link partner advertised auto-negotiation: Yes
    Link partner advertised Duplex: Half
EOF
# All other layers healthy
cat > "$wiz_dir/ping_gw" <<'EOF'
1 packets transmitted, 1 received, 0% packet loss
EOF
cat > "$wiz_dir/ping_inet" <<'EOF'
1 packets transmitted, 1 received, 0% packet loss
EOF
echo "142.250.80.46" > "$wiz_dir/dig_dns"

run_wizard_test "$wiz_dir" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                             || ok=0
echo "$OUT" | grep -A3 "Layer 2 — Switch Port" | grep -qi "SUSPECT" || ok=0
echo "$OUT" | grep -qi "Duplex mismatch"           || ok=0
echo "$OUT" | grep -qi "VERDICT"                   || ok=0
echo "$OUT" | grep -qi "SWITCH PORT"               || ok=0

if [[ $ok -eq 1 ]]; then
  pass "219b: duplex mismatch → Switch Port SUSPECT + verdict SWITCH PORT (exit=$EXITCODE)"
else
  fail "219b: duplex mismatch → Switch Port SUSPECT + verdict SWITCH PORT" "exit=$EXITCODE\n$OUT"
fi

# ── 219c: Autoneg mismatch → Switch Port SUSPECT ──────────────────────────
wiz_dir=$(_fl_base)
cat > "$wiz_dir/ethtool" <<'EOF'
Settings for eth0:
    Speed: 1000Mb/s
    Duplex: Full
    Auto-negotiation: on
    Link detected: yes
    Link partner advertised auto-negotiation: No
EOF
# All other layers healthy
cat > "$wiz_dir/ping_gw" <<'EOF'
1 packets transmitted, 1 received, 0% packet loss
EOF
cat > "$wiz_dir/ping_inet" <<'EOF'
1 packets transmitted, 1 received, 0% packet loss
EOF
echo "142.250.80.46" > "$wiz_dir/dig_dns"

run_wizard_test "$wiz_dir" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                             || ok=0
echo "$OUT" | grep -A3 "Layer 2 — Switch Port" | grep -qi "SUSPECT" || ok=0
echo "$OUT" | grep -qi "Autoneg mismatch"          || ok=0

if [[ $ok -eq 1 ]]; then
  pass "219c: autoneg mismatch → Switch Port SUSPECT (exit=$EXITCODE)"
else
  fail "219c: autoneg mismatch → Switch Port SUSPECT" "exit=$EXITCODE\n$OUT"
fi

# ── 219d: Healthy link → Switch Port OK ───────────────────────────────────
wiz_dir=$(_fl_base)
# Default _fl_base already has Full duplex, link up, autoneg on
cat > "$wiz_dir/ping_gw" <<'EOF'
1 packets transmitted, 1 received, 0% packet loss
EOF
cat > "$wiz_dir/ping_inet" <<'EOF'
1 packets transmitted, 1 received, 0% packet loss
EOF
echo "142.250.80.46" > "$wiz_dir/dig_dns"

run_wizard_test "$wiz_dir" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                             || ok=0
echo "$OUT" | grep -A3 "Layer 2 — Switch Port" | grep -qi "OK" || ok=0
echo "$OUT" | grep -qi "No configuration issues detected"      || ok=0

if [[ $ok -eq 1 ]]; then
  pass "219d: healthy link → Switch Port OK (exit=$EXITCODE)"
else
  fail "219d: healthy link → Switch Port OK" "exit=$EXITCODE\n$OUT"
fi

# ── 220: Duplex mismatch local Half / peer Full → [CAUSE] ───────────────
wiz_dir=$(_fl_base)
cat > "$wiz_dir/ethtool" <<'EOF'
Settings for eth0:
    Speed: 100Mb/s
    Duplex: Half
    Auto-negotiation: on
    Link detected: yes
    Link partner advertised auto-negotiation: Yes
    Link partner advertised Duplex: Full
EOF

run_wizard_test "$wiz_dir" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                                          || ok=0
echo "$OUT" | grep -qi "\[CAUSE\]"                              || ok=0
echo "$OUT" | grep -qi "Duplex mismatch"                        || ok=0
echo "$OUT" | grep -qi "local Half.*peer Full\|Half.*Full"      || ok=0

if [[ $ok -eq 1 ]]; then
  pass "220: duplex mismatch local Half / peer Full → [CAUSE] (exit=$EXITCODE)"
else
  fail "220: duplex mismatch local Half / peer Full → [CAUSE]" "exit=$EXITCODE\n$OUT"
fi

# ── 221: RX CRC errors → Layer 1 SUSPECT ─────────────────────────────────
wiz_dir=$(_fl_base)
cat > "$wiz_dir/ethtool_s" <<'EOF'
     rx_crc_errors: 42
EOF
cat > "$wiz_dir/ping_gw" <<'EOF'
1 packets transmitted, 1 received, 0% packet loss
EOF

run_wizard_test "$wiz_dir" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                                          || ok=0
echo "$OUT" | grep -A3 "Layer 1 — Physical" | grep -qi "SUSPECT" || ok=0
echo "$OUT" | grep -qi "CRC"                                    || ok=0

if [[ $ok -eq 1 ]]; then
  pass "221: RX CRC errors trigger Layer 1 SUSPECT (exit=$EXITCODE)"
else
  fail "221: RX CRC errors trigger Layer 1 SUSPECT" "exit=$EXITCODE\n$OUT"
fi

# ── 222: Firmware failure in dmesg → Layer 2 Driver SUSPECT ──────────────
wiz_dir=$(_fl_base)
printf '%s\n' "[12345.678] eth0: failed to load firmware rtl_nic/rtl8168g-2.fw" > "$wiz_dir/dmesg"
cat > "$wiz_dir/ping_gw" <<'EOF'
1 packets transmitted, 1 received, 0% packet loss
EOF
cat > "$wiz_dir/ping_inet" <<'EOF'
1 packets transmitted, 1 received, 0% packet loss
EOF
echo "142.250.80.46" > "$wiz_dir/dig_dns"

run_wizard_test "$wiz_dir" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                             || ok=0
echo "$OUT" | grep -qi "NIC Driver\|Driver"        || ok=0
echo "$OUT" | grep -q "SUSPECT"                    || ok=0
echo "$OUT" | grep -qi "NIC DRIVER"                || ok=0

if [[ $ok -eq 1 ]]; then
  pass "222: firmware failure in dmesg → NIC Driver SUSPECT verdict (exit=$EXITCODE)"
else
  fail "222: firmware failure in dmesg → NIC Driver SUSPECT verdict" "exit=$EXITCODE\n$OUT"
fi

# ── 235: EEE enabled → L2drv SUSPECT + NIC DRIVER verdict ──────────────────
wiz_dir=$(_fl_base)
echo "EEE status: enabled" > "$wiz_dir/ethtool_eee"
cat > "$wiz_dir/ethtool_i" <<'EOF'
driver: r8169
version: 6.1.0-NAPI
firmware-version: rtl8168g-2_0.0.1
EOF
cat > "$wiz_dir/ping_gw" <<'EOF'
1 packets transmitted, 1 received, 0% packet loss
EOF
cat > "$wiz_dir/ping_inet" <<'EOF'
1 packets transmitted, 1 received, 0% packet loss
EOF
echo "142.250.80.46" > "$wiz_dir/dig_dns"

run_wizard_test "$wiz_dir" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                             || ok=0
echo "$OUT" | grep -A3 "Layer 2 — NIC Driver" | grep -qi "SUSPECT" || ok=0
echo "$OUT" | grep -qi "NIC DRIVER"                || ok=0

if [[ $ok -eq 1 ]]; then
  pass "235: EEE enabled → L2drv SUSPECT + NIC DRIVER verdict (exit=$EXITCODE)"
else
  fail "235: EEE enabled → L2drv SUSPECT + NIC DRIVER verdict" "exit=$EXITCODE\n$OUT"
fi

# ── 236: power/control=auto → L2drv SUSPECT + NIC DRIVER verdict ───────────
wiz_dir=$(_fl_base)
echo "auto" > "$wiz_dir/power_control"
cat > "$wiz_dir/ethtool_i" <<'EOF'
driver: igb
version: 5.14.2-k
firmware-version: 3.25.0
EOF
cat > "$wiz_dir/ping_gw" <<'EOF'
1 packets transmitted, 1 received, 0% packet loss
EOF
cat > "$wiz_dir/ping_inet" <<'EOF'
1 packets transmitted, 1 received, 0% packet loss
EOF
echo "142.250.80.46" > "$wiz_dir/dig_dns"

run_wizard_test "$wiz_dir" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                             || ok=0
echo "$OUT" | grep -A3 "Layer 2 — NIC Driver" | grep -qi "SUSPECT" || ok=0
echo "$OUT" | grep -qi "NIC DRIVER"                || ok=0

if [[ $ok -eq 1 ]]; then
  pass "236: power/control=auto → L2drv SUSPECT + NIC DRIVER verdict (exit=$EXITCODE)"
else
  fail "236: power/control=auto → L2drv SUSPECT + NIC DRIVER verdict" "exit=$EXITCODE\n$OUT"
fi

# ── 237: operstate shown correctly in DUT section ──────────────────────────
wiz_dir=$(_fl_base)
echo "2" > "$wiz_dir/carrier_changes"
cat > "$wiz_dir/ping_gw" <<'EOF'
1 packets transmitted, 1 received, 0% packet loss
EOF

dut_dir=$(mktemp -d "$TESTDIR/dut-237-XXXXXX")
echo "5000"    > "$dut_dir/carrier_changes"
echo "down"    > "$dut_dir/operstate"
cat > "$dut_dir/dut_ethtool" <<'EOF'
Settings for eth1:
    Speed: Unknown!
    Duplex: Unknown!
    Auto-negotiation: off
    Link detected: no
EOF

run_fault_loc_test "$wiz_dir" "$dut_dir" "eth1" -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                             || ok=0
# Host operstate should show "up", not "unknown"
echo "$OUT" | grep -i "Link state" | grep -qi "up" || ok=0
# Should NOT show "unknown" for host side
if echo "$OUT" | grep -i "Link state.*vs host" | grep -qi ": unknown"; then ok=0; fi

if [[ $ok -eq 1 ]]; then
  pass "237: operstate shown correctly in DUT section — host shows 'up' (exit=$EXITCODE)"
else
  fail "237: operstate shown correctly in DUT section — host shows 'up'" "exit=$EXITCODE\n$OUT"
fi

# ── 238: MTU mismatch → L2sw SUSPECT + SWITCH PORT verdict ────────────────
wiz_dir=$(_fl_base)
echo "1500" > "$wiz_dir/mtu"
echo "  Maximum Frame Size: 9000" > "$wiz_dir/lldpctl"
cat > "$wiz_dir/ping_gw" <<'EOF'
1 packets transmitted, 1 received, 0% packet loss
EOF
cat > "$wiz_dir/ping_inet" <<'EOF'
1 packets transmitted, 1 received, 0% packet loss
EOF
echo "142.250.80.46" > "$wiz_dir/dig_dns"

run_wizard_test "$wiz_dir" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                             || ok=0
echo "$OUT" | grep -A3 "Layer 2 — Switch Port" | grep -qi "SUSPECT" || ok=0
echo "$OUT" | grep -qi "MTU mismatch"              || ok=0
echo "$OUT" | grep -qi "SWITCH PORT"               || ok=0

if [[ $ok -eq 1 ]]; then
  pass "238: MTU mismatch (1500 vs 9000) → L2sw SUSPECT + SWITCH PORT verdict (exit=$EXITCODE)"
else
  fail "238: MTU mismatch (1500 vs 9000) → L2sw SUSPECT + SWITCH PORT verdict" "exit=$EXITCODE\n$OUT"
fi

# ── 239: L2drv UNKNOWN (no ethtool -i) → verdict "No fault detected" ──────
wiz_dir=$(_fl_base)
# No ethtool_i file → L2drv UNKNOWN
cat > "$wiz_dir/ping_gw" <<'EOF'
1 packets transmitted, 1 received, 0% packet loss
EOF
cat > "$wiz_dir/ping_inet" <<'EOF'
1 packets transmitted, 1 received, 0% packet loss
EOF
echo "142.250.80.46" > "$wiz_dir/dig_dns"

run_wizard_test "$wiz_dir" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                             || ok=0
echo "$OUT" | grep -A3 "Layer 2 — NIC Driver" | grep -qi "UNKNOWN" || ok=0
echo "$OUT" | grep -qi "No fault detected"         || ok=0

if [[ $ok -eq 1 ]]; then
  pass "239: L2drv UNKNOWN → verdict still 'No fault detected' (exit=$EXITCODE)"
else
  fail "239: L2drv UNKNOWN → verdict still 'No fault detected'" "exit=$EXITCODE\n$OUT"
fi

# ── 240: L1 SUSPECT + L2sw SUSPECT → combined verdict PHYSICAL + SWITCH PORT
wiz_dir=$(_fl_base)
echo "1000" > "$wiz_dir/carrier_changes"
cat > "$wiz_dir/ethtool" <<'EOF'
Settings for eth0:
    Speed: Unknown!
    Duplex: Half
    Auto-negotiation: off
    Link detected: no
EOF
cat > "$wiz_dir/ping_gw" <<'EOF'
1 packets transmitted, 1 received, 0% packet loss
EOF
cat > "$wiz_dir/ping_inet" <<'EOF'
1 packets transmitted, 1 received, 0% packet loss
EOF
echo "142.250.80.46" > "$wiz_dir/dig_dns"

run_wizard_test "$wiz_dir" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                             || ok=0
echo "$OUT" | grep -qi "PHYSICAL"                   || ok=0
echo "$OUT" | grep -qi "SWITCH PORT"                || ok=0

if [[ $ok -eq 1 ]]; then
  pass "240: L1 + L2sw SUSPECT → combined verdict PHYSICAL + SWITCH PORT (exit=$EXITCODE)"
else
  fail "240: L1 + L2sw SUSPECT → combined verdict PHYSICAL + SWITCH PORT" "exit=$EXITCODE\n$OUT"
fi

# ── 241: EEE disabled + power on → L2drv stays OK (negative test) ──────────
wiz_dir=$(_fl_base)
# _fl_base already sets EEE disabled + power on — verify L2drv is not SUSPECT
cat > "$wiz_dir/ethtool_i" <<'EOF'
driver: igb
version: 5.14.2-k
firmware-version: 3.25.0
EOF
cat > "$wiz_dir/ping_gw" <<'EOF'
1 packets transmitted, 1 received, 0% packet loss
EOF
cat > "$wiz_dir/ping_inet" <<'EOF'
1 packets transmitted, 1 received, 0% packet loss
EOF
echo "142.250.80.46" > "$wiz_dir/dig_dns"

run_wizard_test "$wiz_dir" -d eth0 -w 60

ok=1
[[ $EXITCODE -eq 0 ]]                             || ok=0
echo "$OUT" | grep -A3 "Layer 2 — NIC Driver" | grep -qi "OK" || ok=0
echo "$OUT" | grep -qi "No fault detected"         || ok=0
# Must NOT be SUSPECT
if echo "$OUT" | grep -A3 "Layer 2 — NIC Driver" | grep -qi "SUSPECT"; then ok=0; fi

if [[ $ok -eq 1 ]]; then
  pass "241: EEE disabled + power on → L2drv stays OK (exit=$EXITCODE)"
else
  fail "241: EEE disabled + power on → L2drv stays OK" "exit=$EXITCODE\n$OUT"
fi
