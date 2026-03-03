#!/usr/bin/env bash
# tests/test-cron.sh
# Automated tests: scheduled/cron mode (--log-file, --quiet).
#
# Tests covered: 125–128
#
# Verifies:
#   - --log-file appends output to file, nothing on stdout
#   - --quiet suppresses stdout, exit code still reflects flapping
#   - --log-file + --quiet: output to file, nothing on stdout
#   - --log-file output has no ANSI escape codes
#
# Usage (standalone):  bash tests/test-cron.sh
# Usage (via runner):  sourced by tests/run-tests.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Clear any leaked config from prior test suites
rm -rf "${XDG_CONFIG_HOME:-$TESTDIR/xdg}/link-flap"

echo ""
echo -e "${BOLD}Offline tests — scheduled/cron mode${RESET}"
echo ""

# Reusable flapping log (4 transitions for eth0)
_cron_input=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$_cron_input" <<EOF
$(ts 500) host kernel: eth0: NIC Link is Down
$(ts 400) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 300) host kernel: eth0: NIC Link is Down
$(ts 200) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 100) host kernel: eth0: NIC Link is Down
EOF

# ── 125: --log-file appends output to file, nothing on stdout ────────────────
_log_out="$TESTDIR/cron-125.log"
rm -f "$_log_out"
OUT=''; EXITCODE=0
OUT=$(_LINK_FLAP_TEST_INPUT="$_cron_input" \
      bash "$SCRIPT" -w 60 --log-file "$_log_out" 2>&1) || EXITCODE=$?
if [[ $EXITCODE -eq 1 ]] \
   && [[ -z "$OUT" ]] \
   && [[ -f "$_log_out" ]] \
   && grep -q "FLAPPING" "$_log_out"; then
  pass "125: --log-file appends output to file, nothing on stdout"
else
  fail "125: --log-file appends output to file, nothing on stdout" \
       "exit=$EXITCODE stdout_len=${#OUT} file_exists=$(test -f "$_log_out" && echo yes || echo no)\nstdout=$OUT"
fi

# ── 126: --quiet suppresses stdout, exit code reflects flapping ──────────────
OUT=''; EXITCODE=0
OUT=$(_LINK_FLAP_TEST_INPUT="$_cron_input" \
      bash "$SCRIPT" -w 60 --quiet 2>&1) || EXITCODE=$?
if [[ $EXITCODE -eq 1 ]] && [[ -z "$OUT" ]]; then
  pass "126: --quiet suppresses stdout, exit code still reflects flapping"
else
  fail "126: --quiet suppresses stdout, exit code still reflects flapping" \
       "exit=$EXITCODE stdout_len=${#OUT}\n$OUT"
fi

# ── 127: --log-file + --quiet: output goes to file ──────────────────────────
_log_out2="$TESTDIR/cron-127.log"
rm -f "$_log_out2"
OUT=''; EXITCODE=0
OUT=$(_LINK_FLAP_TEST_INPUT="$_cron_input" \
      bash "$SCRIPT" -w 60 --log-file "$_log_out2" --quiet 2>&1) || EXITCODE=$?
if [[ $EXITCODE -eq 1 ]] \
   && [[ -z "$OUT" ]] \
   && [[ -f "$_log_out2" ]] \
   && grep -q "FLAPPING" "$_log_out2"; then
  pass "127: --log-file + --quiet combined: output to file, silent stdout"
else
  fail "127: --log-file + --quiet combined: output to file, silent stdout" \
       "exit=$EXITCODE stdout_len=${#OUT} file_exists=$(test -f "$_log_out2" && echo yes || echo no)"
fi

# ── 128: --log-file output has no ANSI escape codes ─────────────────────────
if [[ -f "$_log_out" ]] && ! grep -qP '\x1b\[' "$_log_out"; then
  pass "128: --log-file output contains no ANSI escape codes"
else
  fail "128: --log-file output contains no ANSI escape codes" \
       "ANSI codes found in $_log_out"
fi
