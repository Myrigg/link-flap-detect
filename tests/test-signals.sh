#!/usr/bin/env bash
# tests/test-signals.sh — Tests for lib/signals.sh (graceful shutdown hooks).

set -euo pipefail
source "$(dirname "$0")/lib.sh"

echo "=== Signals / graceful shutdown ==="

# ── 200: Shutdown hooks run in registration order ─────────────────────────────
hook_log="$TESTDIR/hook-order.log"
(
  source "$(dirname "$SCRIPT")/lib/signals.sh"
  TMPFILE="$TESTDIR/signals-tmp"
  touch "$TMPFILE"
  _hook_first()  { echo "first"  >> "$hook_log"; }
  _hook_second() { echo "second" >> "$hook_log"; }
  _shutdown_register "first"  _hook_first
  _shutdown_register "second" _hook_second
  _graceful_shutdown
)
if [[ -f "$hook_log" ]] && head -1 "$hook_log" | grep -q "first" && tail -1 "$hook_log" | grep -q "second"; then
  pass "200: Shutdown hooks run in registration order"
else
  fail "200: Shutdown hooks run in registration order" "Got: $(cat "$hook_log" 2>/dev/null)"
fi

# ── 201: Shutdown is idempotent — hooks run only once ─────────────────────────
idem_log="$TESTDIR/idem.log"
(
  source "$(dirname "$SCRIPT")/lib/signals.sh"
  TMPFILE="$TESTDIR/idem-tmp"
  touch "$TMPFILE"
  _call_count=0
  _count_hook() { echo "called" >> "$idem_log"; }
  _shutdown_register "counter" _count_hook
  _graceful_shutdown
  _graceful_shutdown  # second call should be no-op
)
count=$(wc -l < "$idem_log" 2>/dev/null || echo "0")
if [[ "$count" -eq 1 ]]; then
  pass "201: Shutdown is idempotent — hooks run only once"
else
  fail "201: Shutdown is idempotent — hooks run only once" "Hook ran $count times"
fi

# ── 202: Temp file is cleaned up on shutdown ──────────────────────────────────
tmp_target="$TESTDIR/cleanup-test-$$"
(
  source "$(dirname "$SCRIPT")/lib/signals.sh"
  TMPFILE="$tmp_target"
  touch "$TMPFILE"
  _graceful_shutdown
)
if [[ ! -f "$tmp_target" ]]; then
  pass "202: Temp file is cleaned up on shutdown"
else
  fail "202: Temp file is cleaned up on shutdown" "File still exists: $tmp_target"
fi

# ── 203: Failed hook does not block subsequent hooks ──────────────────────────
survivor_log="$TESTDIR/survivor.log"
(
  source "$(dirname "$SCRIPT")/lib/signals.sh"
  TMPFILE="$TESTDIR/survivor-tmp"
  touch "$TMPFILE"
  _bad_hook() { return 1; }
  _good_hook() { echo "survived" >> "$survivor_log"; }
  _shutdown_register "failing hook" _bad_hook
  _shutdown_register "survivor"     _good_hook
  _graceful_shutdown
)
if grep -q "survived" "$survivor_log" 2>/dev/null; then
  pass "203: Failed hook does not block subsequent hooks"
else
  fail "203: Failed hook does not block subsequent hooks" "Survivor hook did not run"
fi

# ── 204: _SHUTTING_DOWN flag is set after shutdown ────────────────────────────
flag_log="$TESTDIR/flag.log"
(
  source "$(dirname "$SCRIPT")/lib/signals.sh"
  TMPFILE="$TESTDIR/flag-tmp"
  touch "$TMPFILE"
  _graceful_shutdown
  echo "$_SHUTTING_DOWN" > "$flag_log"
)
if [[ "$(cat "$flag_log" 2>/dev/null)" == "1" ]]; then
  pass "204: _SHUTTING_DOWN flag is set after shutdown"
else
  fail "204: _SHUTTING_DOWN flag is set" "Got: $(cat "$flag_log" 2>/dev/null)"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Signals: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
exit "$FAIL"
