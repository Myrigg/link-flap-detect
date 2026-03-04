#!/usr/bin/env bash
# tests/test-config.sh
# Automated tests: --config show|reset and persisted settings.
#
# Tests covered: 230–234
#
# Usage (standalone):  bash tests/test-config.sh
# Usage (via runner):  sourced by tests/run-tests.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo ""
echo -e "${BOLD}Offline tests — config management${RESET}"
echo ""

# ── 230: --config show displays saved values ─────────────────────────────────
_cfg_dir="$TESTDIR/cfg230/link-flap"
mkdir -p "$_cfg_dir"
printf '%s\n' "PROM_URL=http://prom:9090" "WINDOW_MINUTES=30" > "${_cfg_dir}/config"
OUT=''; EXITCODE=0
OUT=$(XDG_CONFIG_HOME="$TESTDIR/cfg230" bash "$SCRIPT" --config show 2>&1) || EXITCODE=$?
if [[ $EXITCODE -eq 0 ]] \
   && echo "$OUT" | grep -q "PROM_URL" \
   && echo "$OUT" | grep -q "http://prom:9090" \
   && echo "$OUT" | grep -q "WINDOW_MINUTES" \
   && echo "$OUT" | grep -q "30"; then
  pass "230: --config show displays saved values"
else
  fail "230: --config show displays saved values" "exit=$EXITCODE\n$OUT"
fi

# ── 231: --config reset removes config file ──────────────────────────────────
_cfg_dir="$TESTDIR/cfg231/link-flap"
mkdir -p "$_cfg_dir"
printf '%s\n' "PROM_URL=http://prom:9090" > "${_cfg_dir}/config"
OUT=''; EXITCODE=0
OUT=$(XDG_CONFIG_HOME="$TESTDIR/cfg231" bash "$SCRIPT" --config reset 2>&1) || EXITCODE=$?
if [[ $EXITCODE -eq 0 ]] && [[ ! -f "${_cfg_dir}/config" ]]; then
  pass "231: --config reset removes config file"
else
  fail "231: --config reset removes config file" \
       "exit=$EXITCODE file_exists=$(test -f "${_cfg_dir}/config" && echo yes || echo no)\n$OUT"
fi

# ── 232: --config invalid → exit 1 + error ──────────────────────────────────
OUT=''; EXITCODE=0
OUT=$(bash "$SCRIPT" --config badarg 2>&1) || EXITCODE=$?
if [[ $EXITCODE -eq 1 ]] && echo "$OUT" | grep -qi "error"; then
  pass "232: --config invalid → exit 1 + error"
else
  fail "232: --config invalid → exit 1 + error" "exit=$EXITCODE\n$OUT"
fi

# ── 233: Persisted WINDOW_MINUTES loads from config ──────────────────────────
t=$(mktemp "$TESTDIR/XXXXXX.log"); : > "$t"
run_with_config "WINDOW_MINUTES=15" "$t"
if echo "$OUT" | grep -q "last 15m"; then
  pass "233: Persisted WINDOW_MINUTES=15 loads from config"
else
  fail "233: Persisted WINDOW_MINUTES=15 loads from config" "exit=$EXITCODE\n$OUT"
fi

# ── 234: Flag -w 10 overrides persisted value ────────────────────────────────
t=$(mktemp "$TESTDIR/XXXXXX.log"); : > "$t"
run_with_config "WINDOW_MINUTES=15" "$t" -w 10
if echo "$OUT" | grep -q "last 10m"; then
  pass "234: Flag -w 10 overrides persisted WINDOW_MINUTES=15"
else
  fail "234: Flag -w 10 overrides persisted WINDOW_MINUTES=15" "exit=$EXITCODE\n$OUT"
fi
