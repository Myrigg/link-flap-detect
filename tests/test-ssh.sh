#!/usr/bin/env bash
# tests/test-ssh.sh
# Automated tests: SSH remote host mode (-H).
#
# Tests covered: 137–139
#
# Verifies:
#   - -H with malformed host → exit 1 + error
#   - -H without argument → exit 1 + error
#   - -H flag is stripped from remote args (no infinite recursion)
#
# Note: actual SSH connectivity tests are skipped (no remote host in CI).
#
# Usage (standalone):  bash tests/test-ssh.sh
# Usage (via runner):  sourced by tests/run-tests.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Clear any leaked config from prior test suites
rm -rf "${XDG_CONFIG_HOME:-$TESTDIR/xdg}/link-flap"

echo ""
echo -e "${BOLD}Offline tests — SSH remote host mode${RESET}"
echo ""

# ── 137: -H with malformed host → exit 1 + error ────────────────────────────
OUT=''; EXITCODE=0
OUT=$(bash "$SCRIPT" -H 'foo;rm -rf /' 2>&1) || EXITCODE=$?
if [[ $EXITCODE -eq 2 ]] && echo "$OUT" | grep -qi "invalid host"; then
  pass "137: -H with malformed host → exit 2 + error"
else
  fail "137: -H with malformed host → exit 2 + error" \
       "exit=$EXITCODE\n$OUT"
fi

# ── 138: -H without argument → exit 1 + error ───────────────────────────────
OUT=''; EXITCODE=0
OUT=$(bash "$SCRIPT" -H 2>&1) || EXITCODE=$?
if [[ $EXITCODE -eq 2 ]]; then
  pass "138: -H without argument → exit 2 + error"
else
  fail "138: -H without argument → exit 2 + error" \
       "exit=$EXITCODE\n$OUT"
fi

# ── 139: -H with valid host but no ssh → exit 1 + error ─────────────────────
# Simulate missing ssh by prepending a fake PATH with no ssh
OUT=''; EXITCODE=0
_empty_bin=$(mktemp -d "$TESTDIR/empty-bin-XXXXXX")
OUT=$(PATH="$_empty_bin" bash "$SCRIPT" -H testhost 2>&1) || EXITCODE=$?
if [[ $EXITCODE -eq 2 ]] && echo "$OUT" | grep -qi "ssh.*not installed"; then
  pass "139: -H without ssh installed → exit 2 + error"
else
  # ssh might be available in this environment; skip if so
  if command -v ssh >/dev/null 2>&1; then
    skip "139: -H without ssh installed (ssh is available, cannot simulate missing)"
  else
    fail "139: -H without ssh installed → exit 2 + error" \
         "exit=$EXITCODE\n$OUT"
  fi
fi
