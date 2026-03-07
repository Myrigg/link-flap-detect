#!/usr/bin/env bash
# tests/test-retry.sh — Tests for lib/retry.sh (exponential backoff).

set -euo pipefail
source "$(dirname "$0")/lib.sh"

echo "=== Retry with exponential backoff ==="

LIB_DIR="$(dirname "$SCRIPT")/lib"

# ── 210: Succeeds on first attempt — no retries ──────────────────────────────
(
  source "$LIB_DIR/retry.sh"
  _retry_backoff -n 3 -d 0 -- true
) && pass "210: Succeeds on first attempt" \
  || fail "210: Succeeds on first attempt" "Returned non-zero"

# ── 211: Fails after max retries exhausted ────────────────────────────────────
attempt_log="$TESTDIR/retry-attempts.log"
(
  source "$LIB_DIR/retry.sh"
  _test_always_fail() { echo "attempt" >> "$attempt_log"; return 1; }
  _retry_backoff -n 2 -d 0 -j -- _test_always_fail
) && fail "211: Fails after max retries" "Should have returned non-zero" \
  || {
    count=$(wc -l < "$attempt_log" 2>/dev/null || echo "0")
    if [[ "$count" -eq 3 ]]; then
      pass "211: Fails after max retries (3 attempts = 1 initial + 2 retries)"
    else
      fail "211: Fails after max retries" "Expected 3 attempts, got $count"
    fi
  }

# ── 212: Succeeds on Nth attempt ──────────────────────────────────────────────
counter_file="$TESTDIR/retry-counter"
echo "0" > "$counter_file"
(
  source "$LIB_DIR/retry.sh"
  _test_fail_twice() {
    local c; c=$(cat "$counter_file")
    echo $(( c + 1 )) > "$counter_file"
    [[ $(( c + 1 )) -ge 3 ]]  # succeed on 3rd attempt
  }
  _retry_backoff -n 3 -d 0 -j -- _test_fail_twice
)
final_count=$(cat "$counter_file")
if [[ "$final_count" -eq 3 ]]; then
  pass "212: Succeeds on 3rd attempt after 2 failures"
else
  fail "212: Succeeds on 3rd attempt" "Expected 3 attempts, got $final_count"
fi

# ── 213: Zero retries means single attempt ────────────────────────────────────
zero_log="$TESTDIR/zero-retry.log"
(
  source "$LIB_DIR/retry.sh"
  _test_zero() { echo "try" >> "$zero_log"; return 1; }
  _retry_backoff -n 0 -d 0 -j -- _test_zero
) || true
zero_count=$(wc -l < "$zero_log" 2>/dev/null || echo "0")
if [[ "$zero_count" -eq 1 ]]; then
  pass "213: Zero retries means single attempt"
else
  fail "213: Zero retries means single attempt" "Expected 1 attempt, got $zero_count"
fi

# ── 214: Preserves command exit code ──────────────────────────────────────────
(
  source "$LIB_DIR/retry.sh"
  _test_exit42() { return 42; }
  _retry_backoff -n 0 -d 0 -j -- _test_exit42
)
rc=$?
if [[ "$rc" -eq 42 ]]; then
  pass "214: Preserves command exit code (42)"
else
  fail "214: Preserves command exit code" "Expected 42, got $rc"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Retry: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
exit "$FAIL"
