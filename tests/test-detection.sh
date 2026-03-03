#!/usr/bin/env bash
# tests/test-detection.sh
# Automated tests: core flap detection — log parsing, thresholds, interface
# filtering, pattern matching, timestamp handling, and flag validation.
#
# Tests covered: 1–22, 51–53, 59, 63–65
#
# All input is synthetic. No journald, syslog, sysfs, or ethtool access.
# Safe to run in CI, containers, or any machine — root not required.
#
# Usage (standalone):  bash tests/test-detection.sh
# Usage (via runner):  sourced by tests/run-tests.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo ""
echo -e "${BOLD}Offline tests — core flap detection${RESET}"
echo ""

# ── Basic threshold and exit-code behaviour ───────────────────────────────────

# 1. Empty log → exit 0, informational "no events" message
t=$(mktemp "$TESTDIR/XXXXXX.log"); : > "$t"
run "$t" -w 60
if [[ $EXITCODE -eq 0 ]] && echo "$OUT" | grep -q "No link state events"; then
  pass "1: empty log → exit 0, 'No link state events found'"
else
  fail "1: empty log → exit 0, 'No link state events found'" "exit=$EXITCODE\n$OUT"
fi

# 2. Two transitions (Down→Up→Down) — below default threshold of 3 → exit 0
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts 300) host kernel: eth0: NIC Link is Down
$(ts 200) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 100) host kernel: eth0: NIC Link is Down
EOF
run "$t" -w 60 -t 3
if [[ $EXITCODE -eq 0 ]] && echo "$OUT" | grep -q "No flapping detected"; then
  pass "2: 2 transitions < threshold 3 → exit 0, 'No flapping detected'"
else
  fail "2: 2 transitions < threshold 3 → exit 0, 'No flapping detected'" "exit=$EXITCODE\n$OUT"
fi

# 3. Four transitions ≥ threshold 3 → exit 1, [FLAPPING] in output
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts 500) host kernel: eth0: NIC Link is Down
$(ts 400) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 300) host kernel: eth0: NIC Link is Down
$(ts 200) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 100) host kernel: eth0: NIC Link is Down
EOF
run "$t" -w 60 -t 3
if [[ $EXITCODE -eq 1 ]] \
   && echo "$OUT" | grep -q "\[FLAPPING\]" \
   && echo "$OUT" | grep -q "1 interface flapping"; then
  pass "3: 4 transitions ≥ threshold 3 → exit 1, [FLAPPING] + summary count reported"
else
  fail "3: 4 transitions ≥ threshold 3 → exit 1, [FLAPPING] + summary count reported" "exit=$EXITCODE\n$OUT"
fi

# 4. Interface filter -i eth1 excludes eth0 events entirely → exit 0
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts 500) host kernel: eth0: NIC Link is Down
$(ts 400) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 300) host kernel: eth0: NIC Link is Down
$(ts 200) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 100) host kernel: eth0: NIC Link is Down
EOF
run "$t" -w 60 -t 3 -i eth1
if [[ $EXITCODE -eq 0 ]] && ! echo "$OUT" | grep -q "\[FLAPPING\]"; then
  pass "4: interface filter -i eth1 excludes eth0 events"
else
  fail "4: interface filter -i eth1 excludes eth0 events" "exit=$EXITCODE\n$OUT"
fi

# 5. Threshold override: -t 6 means 4 transitions are not enough → exit 0
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts 500) host kernel: eth0: NIC Link is Down
$(ts 400) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 300) host kernel: eth0: NIC Link is Down
$(ts 200) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 100) host kernel: eth0: NIC Link is Down
EOF
run "$t" -w 60 -t 6
if [[ $EXITCODE -eq 0 ]]; then
  pass "5: threshold override -t 6: 4 transitions not enough → exit 0"
else
  fail "5: threshold override -t 6: 4 transitions not enough → exit 0" "exit=$EXITCODE\n$OUT"
fi

# 6. Verbose mode shows individual UP/DOWN event lines
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts 300) host kernel: eth0: NIC Link is Down
$(ts 200) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 100) host kernel: eth0: NIC Link is Down
EOF
run "$t" -w 60 -v
if echo "$OUT" | grep -qE "UP|DOWN"; then
  pass "6: verbose mode (-v) shows UP/DOWN event lines"
else
  fail "6: verbose mode (-v) shows UP/DOWN event lines" "output:\n$OUT"
fi

# 7. Multiple interfaces: eth0 flaps (above threshold), eth1 does not
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts 500) host kernel: eth0: NIC Link is Down
$(ts 450) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 400) host kernel: eth0: NIC Link is Down
$(ts 350) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 300) host kernel: eth0: NIC Link is Down
$(ts 100) host kernel: eth1: NIC Link is Down
$(ts  50) host kernel: eth1: NIC Link is Up 1000 Mbps Full Duplex
EOF
run "$t" -w 60 -t 3
if [[ $EXITCODE -eq 1 ]] \
   && echo "$OUT" | grep -q "\[FLAPPING\].*eth0" \
   && ! echo "$OUT" | grep -q "\[FLAPPING\].*eth1" \
   && echo "$OUT" | grep -q "1 interface flapping"; then
  pass "7: multiple ifaces: only flapping eth0 reported; stable eth1 silent; summary count=1"
else
  fail "7: multiple ifaces: only flapping eth0 reported; stable eth1 silent" "exit=$EXITCODE\n$OUT"
fi

# ── Log pattern matching ───────────────────────────────────────────────────────

# 8. Pattern: kernel "carrier acquired / carrier lost"
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts 500) host kernel: ens18: carrier lost
$(ts 400) host kernel: ens18: carrier acquired
$(ts 300) host kernel: ens18: carrier lost
$(ts 200) host kernel: ens18: carrier acquired
$(ts 100) host kernel: ens18: carrier lost
EOF
run "$t" -w 60 -t 3
if [[ $EXITCODE -eq 1 ]] && echo "$OUT" | grep -q "\[FLAPPING\]"; then
  pass "8: kernel 'carrier acquired/lost' pattern → flap detected"
else
  fail "8: kernel 'carrier acquired/lost' pattern → flap detected" "exit=$EXITCODE\n$OUT"
fi

# 9. Pattern: systemd-networkd "Gained/Lost carrier"
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts 500) host systemd-networkd[1]: ens3: Lost carrier
$(ts 400) host systemd-networkd[1]: ens3: Gained carrier
$(ts 300) host systemd-networkd[1]: ens3: Lost carrier
$(ts 200) host systemd-networkd[1]: ens3: Gained carrier
$(ts 100) host systemd-networkd[1]: ens3: Lost carrier
EOF
run "$t" -w 60 -t 3
if [[ $EXITCODE -eq 1 ]] && echo "$OUT" | grep -q "\[FLAPPING\]"; then
  pass "9: systemd-networkd 'Gained/Lost carrier' pattern → flap detected"
else
  fail "9: systemd-networkd 'Gained/Lost carrier' pattern → flap detected" "exit=$EXITCODE\n$OUT"
fi

# 10. Pattern: NetworkManager "device (iface): link connected/disconnected"
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts 500) host NetworkManager[1]: <info> device (eth0): link disconnected
$(ts 400) host NetworkManager[1]: <info> device (eth0): link connected
$(ts 300) host NetworkManager[1]: <info> device (eth0): link disconnected
$(ts 200) host NetworkManager[1]: <info> device (eth0): link connected
$(ts 100) host NetworkManager[1]: <info> device (eth0): link disconnected
EOF
run "$t" -w 60 -t 3
if [[ $EXITCODE -eq 1 ]] && echo "$OUT" | grep -q "\[FLAPPING\]"; then
  pass "10: NetworkManager 'link connected/disconnected' pattern → flap detected"
else
  fail "10: NetworkManager 'link connected/disconnected' pattern → flap detected" "exit=$EXITCODE\n$OUT"
fi

# ── Virtual interface filtering ────────────────────────────────────────────────

# 11. Virtual interfaces (veth*, docker*, br-*, lo) are silently ignored by default
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts 500) host kernel: veth0abc: NIC Link is Down
$(ts 400) host kernel: veth0abc: NIC Link is Up
$(ts 300) host kernel: veth0abc: NIC Link is Down
$(ts 200) host kernel: veth0abc: NIC Link is Up
$(ts 100) host kernel: veth0abc: NIC Link is Down
$(ts  90) host kernel: docker0: NIC Link is Down
$(ts  80) host kernel: docker0: NIC Link is Up
$(ts  70) host kernel: docker0: NIC Link is Down
$(ts  60) host kernel: docker0: NIC Link is Up
$(ts  50) host kernel: docker0: NIC Link is Down
EOF
run "$t" -w 60 -t 3
if [[ $EXITCODE -eq 0 ]] && ! echo "$OUT" | grep -q "\[FLAPPING\]"; then
  pass "11: virtual ifaces (veth*, docker*) filtered by default"
else
  fail "11: virtual ifaces (veth*, docker*) filtered by default" "exit=$EXITCODE\n$OUT"
fi

# 18. br-* bridge interfaces are silently filtered by default
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts 500) host kernel: br-abc123: NIC Link is Down
$(ts 400) host kernel: br-abc123: NIC Link is Up
$(ts 300) host kernel: br-abc123: NIC Link is Down
$(ts 200) host kernel: br-abc123: NIC Link is Up
$(ts 100) host kernel: br-abc123: NIC Link is Down
EOF
run "$t" -w 60 -t 3
if [[ $EXITCODE -eq 0 ]] && ! echo "$OUT" | grep -q "\[FLAPPING\]"; then
  pass "18: br-* bridge interface filtered by default"
else
  fail "18: br-* bridge interface filtered by default" "exit=$EXITCODE\n$OUT"
fi

# 19. tun0 and tap0 interfaces are silently filtered by default
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts 500) host kernel: tun0: NIC Link is Down
$(ts 450) host kernel: tun0: NIC Link is Up
$(ts 400) host kernel: tun0: NIC Link is Down
$(ts 350) host kernel: tun0: NIC Link is Up
$(ts 300) host kernel: tun0: NIC Link is Down
$(ts 200) host kernel: tap0: NIC Link is Down
$(ts 150) host kernel: tap0: NIC Link is Up
$(ts 100) host kernel: tap0: NIC Link is Down
$(ts  50) host kernel: tap0: NIC Link is Up
$(ts  10) host kernel: tap0: NIC Link is Down
EOF
run "$t" -w 60 -t 3
if [[ $EXITCODE -eq 0 ]] && ! echo "$OUT" | grep -q "\[FLAPPING\]"; then
  pass "19: tun0 and tap0 interfaces filtered by default"
else
  fail "19: tun0 and tap0 interfaces filtered by default" "exit=$EXITCODE\n$OUT"
fi

# ── Timestamp handling ─────────────────────────────────────────────────────────

# 15. Syslog-format timestamps ("Mon DD HH:MM:SS") are parsed correctly
#     Verifies fix: second awk pass uses -F'\t' so spaced ts_raw is not split on spaces
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts_syslog 500) host kernel: eth0: NIC Link is Down
$(ts_syslog 400) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts_syslog 300) host kernel: eth0: NIC Link is Down
$(ts_syslog 200) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts_syslog 100) host kernel: eth0: NIC Link is Down
EOF
run "$t" -w 60 -t 3
if [[ $EXITCODE -eq 1 ]] && echo "$OUT" | grep -q "\[FLAPPING\]"; then
  pass "15: syslog-format timestamps (Mon DD HH:MM:SS) parsed correctly → flap detected"
else
  fail "15: syslog-format timestamps (Mon DD HH:MM:SS) parsed correctly → flap detected" "exit=$EXITCODE\n$OUT"
fi

# 60. Cross-year syslog: future-month timestamps corrected to previous year → flapping detected
#     Without the fix, date(1) parses them as future epochs and the window filter drops them.
FUT_BASE=$(date -d "+6 months" "+%b %_d")
FUT_H=$(date "+%H")
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
${FUT_BASE} ${FUT_H}:00:00 host kernel: eth0: NIC Link is Down
${FUT_BASE} ${FUT_H}:00:02 host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
${FUT_BASE} ${FUT_H}:00:04 host kernel: eth0: NIC Link is Down
${FUT_BASE} ${FUT_H}:00:06 host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
${FUT_BASE} ${FUT_H}:00:08 host kernel: eth0: NIC Link is Down
EOF
run "$t" -w 43200 -t 3
if [[ $EXITCODE -eq 1 ]] && echo "$OUT" | grep -q "\[FLAPPING\]"; then
  pass "60: cross-year syslog timestamps corrected — flapping detected despite future-year parse"
else
  fail "60: cross-year syslog timestamps corrected — flapping detected despite future-year parse" "exit=$EXITCODE\n$OUT"
fi

# ── Transition edge cases ──────────────────────────────────────────────────────

# 16. All events same state → 0 transitions → no flapping
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts 500) host kernel: eth0: NIC Link is Down
$(ts 400) host kernel: eth0: NIC Link is Down
$(ts 300) host kernel: eth0: NIC Link is Down
$(ts 200) host kernel: eth0: NIC Link is Down
$(ts 100) host kernel: eth0: NIC Link is Down
EOF
run "$t" -w 60 -t 3
if [[ $EXITCODE -eq 0 ]] && ! echo "$OUT" | grep -q "\[FLAPPING\]"; then
  pass "16: all events same state: 0 transitions → no flapping"
else
  fail "16: all events same state: 0 transitions → no flapping" "exit=$EXITCODE\n$OUT"
fi

# 17. Exactly at threshold (transitions == FLAP_THRESHOLD) → detected
#     Down→Up→Down→Up = 3 transitions; threshold = 3 → should trigger
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts 400) host kernel: eth0: NIC Link is Down
$(ts 300) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 200) host kernel: eth0: NIC Link is Down
$(ts 100) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
EOF
run "$t" -w 60 -t 3
if [[ $EXITCODE -eq 1 ]] && echo "$OUT" | grep -q "\[FLAPPING\]"; then
  pass "17: exactly at threshold (3 transitions, -t 3): detected"
else
  fail "17: exactly at threshold (3 transitions, -t 3): detected" "exit=$EXITCODE\n$OUT"
fi

# ── NetworkManager state-change pattern ───────────────────────────────────────

# 20. NM state change: alternating activated/deactivating → flap detected
#     Verifies the "-> word" last-arrow extraction and UP/DOWN mapping
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts 500) host NetworkManager[1]: <info> device (eth0): state change: disconnected -> activated
$(ts 400) host NetworkManager[1]: <info> device (eth0): state change: activated -> deactivating
$(ts 300) host NetworkManager[1]: <info> device (eth0): state change: deactivating -> disconnected -> config -> activated
$(ts 200) host NetworkManager[1]: <info> device (eth0): state change: activated -> deactivating
$(ts 100) host NetworkManager[1]: <info> device (eth0): state change: deactivating -> disconnected
EOF
run "$t" -w 60 -t 3
if [[ $EXITCODE -eq 1 ]] && echo "$OUT" | grep -q "\[FLAPPING\]"; then
  pass "20: NM state change: alternating activated/deactivating → flap detected"
else
  fail "20: NM state change: alternating activated/deactivating → flap detected" "exit=$EXITCODE\n$OUT"
fi

# 21. Malformed NM state change lines (no '->' arrow) produce no events
#     Verifies fix: arrow="" initialized each record, no state inherited from prior record
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts 200) host NetworkManager[1]: <info> device (eth0): state change: preparing
$(ts 100) host NetworkManager[1]: <info> device (eth1): state change: configuring
EOF
run "$t" -w 60
if [[ $EXITCODE -eq 0 ]] && echo "$OUT" | grep -q "No link state events found"; then
  pass "21: NM state change: lines with no '->' arrow produce no events"
else
  fail "21: NM state change: lines with no '->' arrow produce no events" "exit=$EXITCODE\n$OUT"
fi

# 22. NM state change: arrow pollution — valid record followed by malformed for same iface
#     After the fix: malformed produces no event, so eth0 has 1 event → count<2 → skipped.
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts 200) host NetworkManager[1]: <info> device (eth0): state change: disconnected -> activated
$(ts 100) host NetworkManager[1]: <info> device (eth0): state change: preparing
EOF
run "$t" -w 60 -v
if [[ $EXITCODE -eq 0 ]] && ! echo "$OUT" | grep -qE "Events: [2-9]"; then
  pass "22: NM state change: malformed line after valid does not produce spurious event"
else
  fail "22: NM state change: malformed line after valid does not produce spurious event" "exit=$EXITCODE\n$OUT"
fi

# ── Flag validation ────────────────────────────────────────────────────────────

# 12. -w 0 is rejected as invalid → exit 1, error to stderr
t=$(mktemp "$TESTDIR/XXXXXX.log"); : > "$t"
run "$t" -w 0
if [[ $EXITCODE -eq 1 ]] && echo "$OUT" | grep -qi "error"; then
  pass "12: invalid -w 0 → exit 1 + error message"
else
  fail "12: invalid -w 0 → exit 1 + error message" "exit=$EXITCODE\n$OUT"
fi

# 13. -t 1 is rejected (must be >= 2) → exit 1, error to stderr
t=$(mktemp "$TESTDIR/XXXXXX.log"); : > "$t"
run "$t" -t 1
if [[ $EXITCODE -eq 1 ]] && echo "$OUT" | grep -qi "error"; then
  pass "13: invalid -t 1 → exit 1 + error message"
else
  fail "13: invalid -t 1 → exit 1 + error message" "exit=$EXITCODE\n$OUT"
fi

# 14. -h prints usage and exits 0 (does not hang or error)
t=$(mktemp "$TESTDIR/XXXXXX.log"); : > "$t"
run "$t" -h
if [[ $EXITCODE -eq 0 ]] && echo "$OUT" | grep -qi "usage\|options\|-w"; then
  pass "14: -h prints usage text and exits 0"
else
  fail "14: -h prints usage text and exits 0" "exit=$EXITCODE\n$OUT"
fi

# 51. -f 0 is rejected (must be >= 1) → exit 1 + error
t=$(mktemp "$TESTDIR/XXXXXX.log"); : > "$t"
run "$t" -f 0
if [[ $EXITCODE -eq 1 ]] && echo "$OUT" | grep -qi "error"; then
  pass "51: invalid -f 0 → exit 1 + error message"
else
  fail "51: invalid -f 0 → exit 1 + error message" "exit=$EXITCODE\n$OUT"
fi

# 52. -f abc is rejected (non-numeric) → exit 1 + error
t=$(mktemp "$TESTDIR/XXXXXX.log"); : > "$t"
run "$t" -f abc
if [[ $EXITCODE -eq 1 ]] && echo "$OUT" | grep -qi "error"; then
  pass "52: invalid -f abc → exit 1 + error message"
else
  fail "52: invalid -f abc → exit 1 + error message" "exit=$EXITCODE\n$OUT"
fi

# 53. Empty log + -f 1 → "next scan" message appears; follow header shown
#     Use timeout(1) to break the infinite exec loop after 3s; exit 124 expected.
t=$(mktemp "$TESTDIR/XXXXXX.log"); : > "$t"
OUT=''; EXITCODE=0
OUT=$(timeout 3 bash -c "_LINK_FLAP_TEST_INPUT='$t' bash '$SCRIPT' -f 1 -w 60 2>&1") || EXITCODE=$?
if echo "$OUT" | grep -q "next scan in 1s" && echo "$OUT" | grep -q "Follow:" \
   && [[ $EXITCODE -eq 124 || $EXITCODE -le 1 ]]; then
  pass "53: follow mode (-f 1): header and 'next scan' message appear"
else
  fail "53: follow mode (-f 1): header and 'next scan' message appear" "exit=$EXITCODE\n$OUT"
fi

# 59. -n with invalid (non-http) URL → exit 1 + error
t=$(mktemp "$TESTDIR/XXXXXX.log"); : > "$t"
run "$t" -n ftp://bad-url
if [[ $EXITCODE -eq 1 ]] && echo "$OUT" | grep -qi "error"; then
  pass "59: -n ftp://bad-url → exit 1 + error (-n URL validation)"
else
  fail "59: -n ftp://bad-url → exit 1 + error (-n URL validation)" "exit=$EXITCODE\n$OUT"
fi

# 63. -w 999999 (exceeds 43200 max) → exit 1 + error
OUT=''; EXITCODE=0
run /dev/null -w 999999
if [[ $EXITCODE -eq 1 ]] && echo "$OUT" | grep -qi "error"; then
  pass "63: -w 999999 → exit 1 + error (exceeds max 43200)"
else
  fail "63: -w 999999 → exit 1 + error (exceeds max 43200)" "exit=$EXITCODE\n$OUT"
fi

# 64. -p /nonexistent → exit 1 + "cannot read" error
OUT=''; EXITCODE=0
run /dev/null -p /tmp/this-file-does-not-exist-link-flap-test.pcap
if [[ $EXITCODE -eq 1 ]] && echo "$OUT" | grep -qi "cannot read"; then
  pass "64: -p /nonexistent → exit 1 + cannot read error"
else
  fail "64: -p /nonexistent → exit 1 + cannot read error" "exit=$EXITCODE\n$OUT"
fi

# 65. -i zzzz_no_iface with a valid log → interface filter matches nothing → exit 0
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
2024-11-01T14:23:05+0000 host kernel: eth0: NIC Link is Up 1000 Mbps
2024-11-01T14:24:00+0000 host kernel: eth0: NIC Link is Down
2024-11-01T14:24:30+0000 host kernel: eth0: NIC Link is Up 1000 Mbps
EOF
OUT=''; EXITCODE=0
run "$t" -i zzzz_no_iface -w 60
if [[ $EXITCODE -eq 0 ]] && echo "$OUT" | grep -qE "No link state events found|No flapping detected"; then
  pass "65: -i nonexistent_iface → exit 0 + no-events message"
else
  fail "65: -i nonexistent_iface → exit 0 + no-events message" "exit=$EXITCODE\n$OUT"
fi
