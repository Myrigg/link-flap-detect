#!/usr/bin/env bash
# tests/test-exit-codes.sh
# Automated tests: exit code contract.
#
# Tests covered: 250–257
#
# Verifies the three-way exit code contract:
#   exit 0 — no flapping detected
#   exit 1 — flapping detected
#   exit 2 — tool/environment error
#
# Usage (standalone):  bash tests/test-exit-codes.sh
# Usage (via runner):  sourced by tests/run-tests.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo ""
echo -e "${BOLD}Exit code contract tests${RESET}"
echo ""

# ── 250: No flapping → exit 0 ────────────────────────────────────────────────
t=$(mktemp "$TESTDIR/XXXXXX.log"); : > "$t"
run "$t" -w 60
if [[ $EXITCODE -eq 0 ]]; then
  pass "250: no flapping → exit 0"
else
  fail "250: no flapping → exit 0" "exit=$EXITCODE\n$OUT"
fi

# ── 251: Flapping detected → exit 1 ──────────────────────────────────────────
t=$(mktemp "$TESTDIR/XXXXXX.log")
cat > "$t" <<EOF
$(ts 500) host kernel: eth0: NIC Link is Down
$(ts 400) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 300) host kernel: eth0: NIC Link is Down
$(ts 200) host kernel: eth0: NIC Link is Up 1000 Mbps Full Duplex
$(ts 100) host kernel: eth0: NIC Link is Down
EOF
run "$t" -w 60 -t 3
if [[ $EXITCODE -eq 1 ]]; then
  pass "251: flapping detected → exit 1"
else
  fail "251: flapping detected → exit 1" "exit=$EXITCODE\n$OUT"
fi

# ── 252: Bad -w argument → exit 2 ────────────────────────────────────────────
t=$(mktemp "$TESTDIR/XXXXXX.log"); : > "$t"
run "$t" -w 0
if [[ $EXITCODE -eq 2 ]]; then
  pass "252: bad -w 0 → exit 2"
else
  fail "252: bad -w 0 → exit 2" "exit=$EXITCODE\n$OUT"
fi

# ── 253: Bad -t argument → exit 2 ────────────────────────────────────────────
t=$(mktemp "$TESTDIR/XXXXXX.log"); : > "$t"
run "$t" -t 1
if [[ $EXITCODE -eq 2 ]]; then
  pass "253: bad -t 1 → exit 2"
else
  fail "253: bad -t 1 → exit 2" "exit=$EXITCODE\n$OUT"
fi

# ── 254: Bad -p argument → exit 2 ────────────────────────────────────────────
run /dev/null -p /tmp/this-file-does-not-exist-link-flap-test.pcap
if [[ $EXITCODE -eq 2 ]]; then
  pass "254: bad -p /nonexistent → exit 2"
else
  fail "254: bad -p /nonexistent → exit 2" "exit=$EXITCODE\n$OUT"
fi

# ── 255: --fleet without -m → exit 2 ─────────────────────────────────────────
OUT=''; EXITCODE=0
OUT=$(XDG_CONFIG_HOME="$TESTDIR/cfg-255" bash "$SCRIPT" --fleet 2>&1) || EXITCODE=$?
if [[ $EXITCODE -eq 2 ]]; then
  pass "255: --fleet without -m → exit 2"
else
  fail "255: --fleet without -m → exit 2" "exit=$EXITCODE\n$OUT"
fi

# ── 256: --since invalid date → exit 2 ───────────────────────────────────────
OUT=''; EXITCODE=0
run /dev/null --since "not-a-date"
if [[ $EXITCODE -eq 2 ]]; then
  pass "256: --since invalid date → exit 2"
else
  fail "256: --since invalid date → exit 2" "exit=$EXITCODE\n$OUT"
fi

# ── 257: Unknown option → exit 2 ─────────────────────────────────────────────
OUT=''; EXITCODE=0
OUT=$(bash "$SCRIPT" -Z 2>&1) || EXITCODE=$?
if [[ $EXITCODE -eq 2 ]]; then
  pass "257: unknown option -Z → exit 2"
else
  fail "257: unknown option -Z → exit 2" "exit=$EXITCODE\n$OUT"
fi
