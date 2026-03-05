#!/usr/bin/env bash
# tests/test-iperf3-settings.sh
# Automated tests: iperf3 configurable settings — port, duration, protocol,
# bitrate, server mode, config persistence and loading, validation.
#
# Tests covered: 261–271
#
# Usage (standalone):  bash tests/test-iperf3-settings.sh
# Usage (via runner):  sourced by tests/run-tests.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo ""
echo -e "${BOLD}Offline tests — iperf3 configurable settings${RESET}"
echo ""

# Helper: run with config dir isolation and iperf3 test mode
run_iperf3_settings() {
  local cfg_dir="$TESTDIR/cfg-iperf3-settings-$$"
  mkdir -p "$cfg_dir/link-flap"
  local input_f="$1"; shift
  OUT=''; EXITCODE=0
  OUT=$(XDG_CONFIG_HOME="$cfg_dir" \
        _LINK_FLAP_TEST_IPERF3="$input_f" \
        bash "$SCRIPT" "$@" 2>&1) || EXITCODE=$?
}

# Minimal iperf3 TCP fixture
IPERF3_TCP=$(mktemp "$TESTDIR/iperf3-tcp-XXXXXX.json")
cat > "$IPERF3_TCP" <<'EOF'
{"end":{"sum_sent":{"bits_per_second":943000000,"retransmits":0}}}
EOF

# UDP fixture with jitter and lost packets
IPERF3_UDP=$(mktemp "$TESTDIR/iperf3-udp-XXXXXX.json")
cat > "$IPERF3_UDP" <<'EOF'
{"end":{"sum":{"bits_per_second":500000000,"jitter_ms":0.45,"lost_packets":3,"packets":42000}}}
EOF

# Flapping log for tests that need it
FLAP_LOG=$(mktemp "$TESTDIR/iperf3-set-XXXXXX.log")
cat > "$FLAP_LOG" <<EOF
$(ts 500) host kernel: eth0: NIC Link is Down
$(ts 400) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 300) host kernel: eth0: NIC Link is Down
$(ts 200) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 100) host kernel: eth0: NIC Link is Down
EOF

# 261. IPERF3_PORT=9999 in config, shows in --config show
cfg261="$TESTDIR/cfg-261"
mkdir -p "$cfg261/link-flap"
printf 'IPERF3_PORT=9999\n' > "$cfg261/link-flap/config"
CFG_OUT=''
CFG_OUT=$(XDG_CONFIG_HOME="$cfg261" bash "$SCRIPT" --config show 2>&1) || true
if echo "$CFG_OUT" | grep -q "IPERF3_PORT.*9999"; then
  pass "261: IPERF3_PORT=9999 in config shows in --config show"
else
  fail "261: IPERF3_PORT=9999 in config shows in --config show" "config show output:\n$CFG_OUT"
fi

# 262. --iperf3-duration 10 saved, used in wizard warning text
cfg262="$TESTDIR/cfg-262"
mkdir -p "$cfg262/link-flap"
wiz262=$(mktemp -d "$TESTDIR/wiz-262-XXXXXX")
echo "up" > "$wiz262/operstate"
make_wizard_fixture "$wiz262"
IPERF3_RETRANS262=$(mktemp "$TESTDIR/iperf3-retrans-262-XXXXXX.json")
cat > "$IPERF3_RETRANS262" <<'EOF'
{"end":{"sum_sent":{"bits_per_second":450000000,"retransmits":5}}}
EOF
OUT=''; EXITCODE=0
OUT=$(XDG_CONFIG_HOME="$cfg262" \
      BACKUP_DIR="$TESTDIR/backups" REPORT_DIR="$TESTDIR/reports" \
      _LINK_FLAP_TEST_WIZARD_DIR="$wiz262" \
      _LINK_FLAP_TEST_IPERF3="$IPERF3_RETRANS262" \
      bash "$SCRIPT" -b test-server --iperf3-duration 10 -d eth0 -w 60 2>&1) || EXITCODE=$?
if echo "$OUT" | grep -q "10s test"; then
  pass "262: --iperf3-duration 10 reflected in wizard finding text"
else
  fail "262: --iperf3-duration 10 in wizard text" "exit=$EXITCODE\n$OUT"
fi

# 263. --iperf3-udp with UDP JSON fixture shows jitter + lost_packets
run_with_iperf3 "$FLAP_LOG" "$IPERF3_UDP" --iperf3-udp -w 60 -t 3
if [[ $EXITCODE -eq 1 ]] \
   && echo "$OUT" | grep -q "Jitter" \
   && echo "$OUT" | grep -q "Lost packets" \
   && echo "$OUT" | grep -q "500"; then
  pass "263: --iperf3-udp shows jitter, lost packets, and bandwidth from UDP fixture"
else
  fail "263: --iperf3-udp UDP display" "exit=$EXITCODE\n$OUT"
fi

# 264. IPERF3_BITRATE=100M in config, shows in --config show
cfg264="$TESTDIR/cfg-264"
mkdir -p "$cfg264/link-flap"
printf 'IPERF3_BITRATE=100M\n' > "$cfg264/link-flap/config"
CFG_OUT=''
CFG_OUT=$(XDG_CONFIG_HOME="$cfg264" bash "$SCRIPT" --config show 2>&1) || true
if echo "$CFG_OUT" | grep -q "IPERF3_BITRATE.*100M"; then
  pass "264: IPERF3_BITRATE=100M in config shows in --config show"
else
  fail "264: IPERF3_BITRATE=100M in config shows in --config show" "config show:\n$CFG_OUT"
fi

# 265. --iperf3-port 99999 → exit 2 (validation failure)
OUT=''; EXITCODE=0
OUT=$(XDG_CONFIG_HOME="$TESTDIR/cfg-265" \
      _LINK_FLAP_TEST_INPUT="$FLAP_LOG" \
      bash "$SCRIPT" --iperf3-port 99999 -w 60 2>&1) || EXITCODE=$?
if [[ $EXITCODE -eq 2 ]] && echo "$OUT" | grep -qi "iperf3-port"; then
  pass "265: --iperf3-port 99999 → exit 2 (validation)"
else
  fail "265: --iperf3-port 99999 validation" "exit=$EXITCODE\n$OUT"
fi

# 266. --iperf3-duration 0 → exit 2 (validation failure)
OUT=''; EXITCODE=0
OUT=$(XDG_CONFIG_HOME="$TESTDIR/cfg-266" \
      _LINK_FLAP_TEST_INPUT="$FLAP_LOG" \
      bash "$SCRIPT" --iperf3-duration 0 -w 60 2>&1) || EXITCODE=$?
if [[ $EXITCODE -eq 2 ]] && echo "$OUT" | grep -qi "iperf3-duration"; then
  pass "266: --iperf3-duration 0 → exit 2 (validation)"
else
  fail "266: --iperf3-duration 0 validation" "exit=$EXITCODE\n$OUT"
fi

# 267. --iperf3-server in test mode → prints server mode info
OUT=''; EXITCODE=0
OUT=$(XDG_CONFIG_HOME="$TESTDIR/cfg-267" \
      _LINK_FLAP_TEST_IPERF3="1" \
      bash "$SCRIPT" --iperf3-server 2>&1) || EXITCODE=$?
if [[ $EXITCODE -eq 0 ]] && echo "$OUT" | grep -q "iperf3 server mode: port=5201"; then
  pass "267: --iperf3-server test mode → prints 'iperf3 server mode: port=5201'"
else
  fail "267: --iperf3-server test mode" "exit=$EXITCODE\n$OUT"
fi

# 268. Saved IPERF3_PORT=9999 loads from config
cfg268="$TESTDIR/cfg-268"
mkdir -p "$cfg268/link-flap"
printf 'IPERF3_PORT=9999\n' > "$cfg268/link-flap/config"
OUT=''; EXITCODE=0
OUT=$(XDG_CONFIG_HOME="$cfg268" \
      _LINK_FLAP_TEST_IPERF3="1" \
      bash "$SCRIPT" --iperf3-server 2>&1) || EXITCODE=$?
if [[ $EXITCODE -eq 0 ]] && echo "$OUT" | grep -q "port=9999"; then
  pass "268: saved IPERF3_PORT=9999 loads from config"
else
  fail "268: config load IPERF3_PORT=9999" "exit=$EXITCODE\n$OUT"
fi

# 269. Flag --iperf3-port 8888 overrides saved IPERF3_PORT=9999
cfg269="$TESTDIR/cfg-269"
mkdir -p "$cfg269/link-flap"
printf 'IPERF3_PORT=9999\n' > "$cfg269/link-flap/config"
OUT=''; EXITCODE=0
OUT=$(XDG_CONFIG_HOME="$cfg269" \
      _LINK_FLAP_TEST_IPERF3="1" \
      bash "$SCRIPT" --iperf3-server --iperf3-port 8888 2>&1) || EXITCODE=$?
if [[ $EXITCODE -eq 0 ]] && echo "$OUT" | grep -q "port=8888"; then
  pass "269: --iperf3-port 8888 overrides saved 9999"
else
  fail "269: flag overrides saved config" "exit=$EXITCODE\n$OUT"
fi

# 270. UDP wizard: lost_packets=3 → [WARN] with "packet loss"
wiz270=$(mktemp -d "$TESTDIR/wiz-270-XXXXXX")
make_wizard_fixture "$wiz270"
OUT=''; EXITCODE=0
OUT=$(XDG_CONFIG_HOME="$TESTDIR/cfg-270" \
      BACKUP_DIR="$TESTDIR/backups" REPORT_DIR="$TESTDIR/reports" \
      _LINK_FLAP_TEST_WIZARD_DIR="$wiz270" \
      _LINK_FLAP_TEST_IPERF3="$IPERF3_UDP" \
      bash "$SCRIPT" -b test-server --iperf3-udp -d eth0 -w 60 2>&1) || EXITCODE=$?
if echo "$OUT" | grep -q "\[WARN\]" \
   && echo "$OUT" | grep -qi "packet loss"; then
  pass "270: UDP wizard: lost_packets=3 → [WARN] with 'packet loss'"
else
  fail "270: UDP wizard packet loss finding" "exit=$EXITCODE\n$OUT"
fi

# 271. Protocol saved as "udp" loads correctly from config
cfg271="$TESTDIR/cfg-271"
mkdir -p "$cfg271/link-flap"
printf 'IPERF3_PROTOCOL=udp\n' > "$cfg271/link-flap/config"
OUT=''; EXITCODE=0
OUT=$(XDG_CONFIG_HOME="$cfg271" \
      _LINK_FLAP_TEST_INPUT="$FLAP_LOG" \
      _LINK_FLAP_TEST_IPERF3="$IPERF3_UDP" \
      bash "$SCRIPT" -b test-server -w 60 -t 3 2>&1) || EXITCODE=$?
if echo "$OUT" | grep -q "UDP"; then
  pass "271: protocol 'udp' loads from config and shows in output"
else
  fail "271: protocol config load" "exit=$EXITCODE\n$OUT"
fi
