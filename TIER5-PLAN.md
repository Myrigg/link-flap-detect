# Tier 5 Implementation Plan — Resilience and Reliability

This plan covers porting 6 S2DevTools patterns to link-flap-detect as Bash lib modules.
It was prepared on a Windows machine where the test suite cannot run. All implementation
and testing should happen on Ubuntu where `flap` runs natively.

**Start by reading:** `ROADMAP.md` (Tier 5 section), then this file.

---

## Current state

### Already implemented (code written, needs testing on Ubuntu)

**5.1 — `lib/signals.sh` (Graceful shutdown)**
- Replaces the inline `_graceful_shutdown` in `flap` (line ~466) with hook-based cleanup
- `_shutdown_register "label" callback_fn` registers ordered shutdown hooks
- Idempotent: multiple signals only run cleanup once
- The main `flap` script was updated with a fallback guard (lines 465-470) so standalone
  bundles still work without lib/
- Test file: `tests/test-signals.sh` (5 tests: 200-204) — passed on Git Bash, verify on Ubuntu
- **Integration TODO:** Other modules (webhooks, prometheus) should call `_shutdown_register`
  to flush state during shutdown

**5.2 — `lib/retry.sh` (Exponential backoff)**
- `_retry_backoff [-n retries] [-d base_delay] [-f factor] [-m max_delay] [-j] -- CMD`
- Exponential delay: `base × factor^attempt`, capped at max_delay
- Jitter ±30% by default (disable with `-j`)
- Skips sleep for delays < 0.05s (test mode)
- Test file: `tests/test-retry.sh` (5 tests: 210-214) — NOT fully verified, test 212 hung
  on Windows. Debug on Ubuntu: the file-based counter in a subshell may need adjustment.
- **Integration TODO:** Wire into `_send_webhook` in `lib/webhooks.sh` and `prom_query`/
  `prom_query_at` in `lib/prometheus.sh`

### Not yet implemented

**5.3 — `lib/circuit-breaker.sh`**
**5.4 — `lib/rate-limiter.sh`**
**5.5 — `lib/state-machine.sh`**
**5.6 — `lib/time-window.sh`**

---

## Implementation details for each remaining item

### 5.3 — Circuit breaker (`lib/circuit-breaker.sh`)

**Algorithm** (from S2DevTools `patterns/circuit-breaker.js`):
- Three states: CLOSED (normal) → OPEN (failing) → HALF_OPEN (probing)
- Track failures in a rolling time window (default 60s)
- After N failures (default 5) within the window → transition to OPEN
- In OPEN state: reject all calls immediately (return 1 without executing)
- After reset timeout (default 30s) → transition to HALF_OPEN
- In HALF_OPEN: allow one probe call. Success → CLOSED. Failure → OPEN.

**Bash design:**
- State persisted in `$_CONFIG_DIR/circuit/<name>.state` (one file per circuit)
- File format: `STATE FAILURE_COUNT LAST_FAILURE_EPOCH OPENED_AT_EPOCH`
- Functions:
  - `_circuit_call "name" command [args...]` — wraps a command through the circuit
  - `_circuit_reset "name"` — force-close a circuit
  - `_circuit_status "name"` — print current state (for debugging/JSON output)

**Where to integrate:**
- `lib/prometheus.sh`: wrap `curl` calls in `_circuit_call "prometheus" ...`
  - Currently uses `_PROM_QUERY_FAILURES` counter — circuit breaker replaces this
  - Fleet scan (`fleet_scan_prometheus`) should check circuit before pre-check
- `lib/webhooks.sh`: wrap `curl` in `_circuit_call "webhook" ...`

**Test file:** `tests/test-circuit-breaker.sh`
- 220: CLOSED state allows calls through
- 221: Transitions to OPEN after N failures
- 222: OPEN state rejects calls without executing
- 223: HALF_OPEN allows one probe after timeout
- 224: Successful probe closes the circuit
- 225: Failed probe reopens the circuit
- 226: `_circuit_reset` force-closes an open circuit
- 227: State survives across subshell invocations (file persistence)

---

### 5.4 — Token bucket rate limiter (`lib/rate-limiter.sh`)

**Algorithm** (from S2DevTools `patterns/token-bucket.js`):
- Bucket starts full (capacity tokens, default 10)
- On each call: refill tokens based on elapsed time (`elapsed_secs × refill_rate`)
- Cap tokens at capacity
- `consume(count)` succeeds if tokens >= count, deducts and returns 0
- If insufficient tokens, returns 1 (caller should skip or queue)

**Bash design:**
- State in `$_CONFIG_DIR/ratelimit/<name>.state`
- File format: `TOKENS LAST_REFILL_EPOCH`
- Functions:
  - `_ratelimit_consume "name" [count] [capacity] [refill_per_sec]` — returns 0 if allowed
  - `_ratelimit_reset "name"` — refill to capacity

**Where to integrate:**
- `lib/webhooks.sh`: guard `_send_webhook` with `_ratelimit_consume "webhook" 1 10 0.083`
  (0.083 tokens/sec = 5 per minute, burst of 10)
- Only rate-limit in follow mode (`-f`) where repeated calls are expected
- When rate-limited, log a warning: `"[RATE LIMITED] Webhook throttled — too many alerts"`

**Test file:** `tests/test-rate-limiter.sh`
- 230: Full bucket allows consumption
- 231: Empty bucket rejects consumption
- 232: Tokens refill over time
- 233: Tokens capped at capacity (no overflow)
- 234: Multiple consumers deplete bucket correctly
- 235: Reset restores full capacity

---

### 5.5 — State machine for interface lifecycle (`lib/state-machine.sh`)

**Algorithm** (from S2DevTools `patterns/state-machine.js`):
- Define states and allowed transitions as a map
- `transition(event)` checks validity, runs onExit/onEnter hooks, updates state
- `can(event)` checks if transition is valid without executing
- Maintains history

**Bash design:**
- Interface states: `STABLE`, `FLAPPING`, `STILL_FLAPPING`, `CLEARED`
- Transition map:
  ```
  STABLE          → FLAPPING         (on: detected)
  FLAPPING        → STILL_FLAPPING   (on: still_detected)
  FLAPPING        → CLEARED          (on: resolved)
  STILL_FLAPPING  → STILL_FLAPPING   (on: still_detected)
  STILL_FLAPPING  → CLEARED          (on: resolved)
  CLEARED         → STABLE           (on: cycle_end)
  CLEARED         → FLAPPING         (on: detected)
  ```
- State persisted in `$_CONFIG_DIR/iface-state.dat` (tab-separated: `IFACE STATE SINCE_EPOCH`)
- Functions:
  - `_iface_state_get "iface"` — print current state (default: STABLE)
  - `_iface_state_transition "iface" "event"` — attempt transition, return 1 if invalid
  - `_iface_state_clear` — remove all state (for `--config reset`)

**Where to integrate:**
- Replace the ad-hoc `_FLAP_PREV_FLAPPING` / `_prev_flapping_set` env-var tracking in
  `flap` (lines 800-809, 881-906) with state machine calls
- Follow-mode re-exec (line 965-968): state is in a file now, no need to pass env vars
- Webhook firing logic (lines 881-906): fire on STABLE→FLAPPING and *_FLAPPING→CLEARED
  transitions instead of manual set comparison
- `[STILL FLAPPING]` / `[CLEARED]` output (lines 730-750, 800-809): driven by state

**Test file:** `tests/test-state-machine.sh`
- 240: New interface defaults to STABLE
- 241: STABLE → FLAPPING on "detected"
- 242: FLAPPING → STILL_FLAPPING on "still_detected"
- 243: FLAPPING → CLEARED on "resolved"
- 244: STILL_FLAPPING → CLEARED on "resolved"
- 245: CLEARED → STABLE on "cycle_end"
- 246: Invalid transition rejected (STABLE → CLEARED)
- 247: State persists across subshell calls
- 248: `_iface_state_clear` removes all state
- 249: Multiple interfaces tracked independently

---

### 5.6 — Time window counter (`lib/time-window.sh`)

**Algorithm** (from S2DevTools `patterns/time-window-counter.js`):
- Store event timestamps in an array
- `add(timestamp)` appends
- `count(window_seconds)` prunes old entries, returns count within window
- Binary search for efficiency

**Bash design:**
- In-memory only (associative array keyed by bucket name)
- Functions:
  - `_tw_add "name" [epoch]` — record an event (default: now)
  - `_tw_count "name" window_seconds` — count events within window
  - `_tw_reset "name"` — clear all events
- Used for correlation: replace the hardcoded awk 10-second bucketing

**Where to integrate:**
- Add `--correlation-window SECONDS` flag to `flap` (default: 10)
- Replace the inline awk correlation block (lines 816-834) with:
  ```bash
  # For each event in TMPFILE, add to time-window counter per interface
  # Then check: any window where 2+ interfaces have events?
  ```
- The awk approach is actually more efficient for batch processing, so consider keeping
  awk for the main correlation and using `_tw_count` for follow-mode rate tracking instead

**Test file:** `tests/test-time-window.sh`
- 250: Empty counter returns 0
- 251: Added events are counted within window
- 252: Old events outside window are excluded
- 253: Reset clears all events
- 254: Multiple named counters are independent

---

## Integration sequence (do in this order)

1. **Verify existing code on Ubuntu**
   ```bash
   cd ~/Projects/link-flap-detect
   bash tests/test-signals.sh     # should pass (5 tests)
   bash tests/test-retry.sh       # debug test 212 if it hangs
   bash tests/run-tests.sh        # full suite — ensure no regressions
   ```

2. **Fix test-retry.sh test 212** if needed
   - The file-based counter approach may fail because the subshell `( )` wrapper
     prevents the function from reading its own file updates between retries
   - Fix: remove the subshell wrapper or use a different counter approach

3. **Wire `_retry_backoff` into webhooks.sh**
   - Replace the `curl ... || true` in `_send_webhook` with:
     ```bash
     _retry_backoff -n 2 -d 1 -m 5 -- \
       curl -sf -X POST -H "Content-Type: application/json" \
       -d "$payload" --max-time 5 "$url" >/dev/null 2>&1
     ```
   - Keep the `|| true` fallback after retry exhaustion (don't block flap on webhook failure)
   - Add test in `tests/test-webhook.sh`: verify retry count via test hook log

4. **Implement 5.3 — circuit-breaker.sh** (see spec above)
   - Write lib module, write tests, wire into prometheus.sh and webhooks.sh
   - Remove `_PROM_QUERY_FAILURES` counter in prometheus.sh (circuit breaker replaces it)
   - Update the warning message at flap lines 792-795 to use circuit state

5. **Implement 5.4 — rate-limiter.sh** (see spec above)
   - Write lib module, write tests, wire into webhooks.sh (follow mode only)

6. **Implement 5.5 — state-machine.sh** (see spec above)
   - Write lib module, write tests
   - Refactor follow-mode state tracking in flap main script
   - Refactor webhook state-change logic
   - Remove `_FLAP_PREV_FLAPPING` / `_FLAP_PREV_TRANSITIONS` env var passing from
     the follow-mode re-exec (line 965-968) — state is in a file now

7. **Implement 5.6 — time-window.sh** (see spec above)
   - Write lib module, write tests
   - Add `--correlation-window` flag
   - Decide: replace awk correlation or use alongside it

8. **Final verification**
   ```bash
   bash tests/run-tests.sh        # full suite including new tests
   ```

9. **Update ROADMAP.md** — mark completed items with ~~strikethrough~~ ✓ Done

---

## Key files to read before starting

| File | Why |
|---|---|
| `flap` (lines 460-470) | Signal handler fallback guard (already modified) |
| `flap` (lines 800-810) | Follow-mode cleared detection (state machine replaces this) |
| `flap` (lines 881-906) | Webhook state-change alerts (state machine replaces this) |
| `flap` (lines 953-968) | Follow-mode re-exec with env var state passing |
| `flap` (lines 816-834) | Cross-interface correlation (time window enhances this) |
| `lib/webhooks.sh` | Webhook delivery — needs retry + circuit breaker + rate limiter |
| `lib/prometheus.sh` | Prometheus queries — needs retry + circuit breaker |
| `lib/signals.sh` | Already written — verify and integrate |
| `lib/retry.sh` | Already written — fix tests, then wire in |
| `tests/lib.sh` | Test harness patterns — follow for new test files |

---

## S2DevTools reference patterns

The JavaScript originals are at `~/s2devtools/boilerplates/atoms/patterns/`:
- `circuit-breaker.js` — 78-line class, three-state with rolling failure window
- `retry-backoff.js` — 46-line function, exponential with jitter
- `token-bucket.js` — 51-line class, refill-based rate limiting
- `state-machine.js` — 94-line class, event-driven with guards and hooks
- `graceful-shutdown.js` — 69-line coordinator, ordered hook execution
- `time-window-counter.js` — 51-line class, binary search on timestamp array

Read these for algorithm details, but port to idiomatic Bash (file-based state, awk for
math, associative arrays for in-memory maps).

---

## Testing conventions

- Test file naming: `tests/test-<module>.sh`
- Test IDs: 200-209 signals, 210-219 retry, 220-229 circuit breaker, 230-239 rate limiter,
  240-249 state machine, 250-259 time window
- Use `run()` / `run_with_config()` from `tests/lib.sh` where possible
- For unit tests that only need the lib module, source it directly:
  `source "$(dirname "$SCRIPT")/lib/retry.sh"`
- Use `$TESTDIR` for all temp files (auto-cleaned)
- Pass `-d 0 -j` to `_retry_backoff` in tests to avoid real delays
