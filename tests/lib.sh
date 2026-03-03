#!/usr/bin/env bash
# tests/lib.sh
# Shared helpers for the flap test suite.
# Source this file; do not execute it directly.
#
# Provides:
#   - SCRIPT         absolute path to the flap binary under test
#   - TESTDIR        per-run temp directory (cleaned on EXIT)
#   - PASS/FAIL/SKIP counters
#   - Colour variables
#   - pass(), fail(), skip()          — result reporters
#   - ts(), ts_syslog()               — timestamp generators
#   - run(), run_tshark()             — script runners (offline)
#   - run_with_prom(), run_tshark_with_prom()
#   - run_wizard_test(), run_rollback_test()
#   - run_with_ne(), run_wizard_ne_test()
#   - run_with_iperf3(), run_wizard_iperf3_test()
#   - run_real_wizard_test()          — live-system wizard runner

# Guard: safe to source multiple times
[[ -n "${_LINK_FLAP_LIB_LOADED:-}" ]] && return 0
_LINK_FLAP_LIB_LOADED=1

# ── Script under test ─────────────────────────────────────────────────────────
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/flap"

if [[ ! -f "$SCRIPT" ]]; then
  echo "Error: $SCRIPT not found." >&2; exit 1
fi

# ── Shared counters ───────────────────────────────────────────────────────────
PASS=0; FAIL=0; SKIP=0

# ── Temp directory (cleaned on exit) ─────────────────────────────────────────
TESTDIR=$(mktemp -d /tmp/link-flap-tests-XXXXXX)
trap 'rm -rf "$TESTDIR"' EXIT

# ── Colours (disabled when stdout is not a terminal) ─────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BOLD=''; RESET=''
fi

# ── Result reporters ──────────────────────────────────────────────────────────
pass() { echo -e "  ${GREEN}PASS${RESET}  $1"; (( PASS++ )) || true; }
fail() {
  echo -e "  ${RED}FAIL${RESET}  $1"
  echo -e "        ${YELLOW}$2${RESET}"
  (( FAIL++ )) || true
}
skip() { echo -e "  ${YELLOW}SKIP${RESET}  $1"; (( SKIP++ )) || true; }

# ── Timestamp helpers ─────────────────────────────────────────────────────────
# ts N — ISO 8601 timestamp N seconds ago (always within any reasonable window)
ts() { date -d "@$(( $(date +%s) - $1 ))" "+%Y-%m-%dT%H:%M:%S+0000"; }

# ts_syslog N — syslog-style "Mon DD HH:MM:SS" timestamp N seconds ago
# Tests that the second awk pass correctly uses -F'\t' to parse spaced timestamps
ts_syslog() { date -d "@$(( $(date +%s) - $1 ))" "+%b %e %H:%M:%S"; }

# ── Script runners ────────────────────────────────────────────────────────────
# All runners populate OUT (stdout+stderr) and EXITCODE.

OUT=''; EXITCODE=0

# run INPUT_FILE [SCRIPT_ARGS...]
# Injects synthetic log data via _LINK_FLAP_TEST_INPUT.
run() {
  local f="$1"; shift
  OUT=''; EXITCODE=0
  OUT=$(_LINK_FLAP_TEST_INPUT="$f" bash "$SCRIPT" "$@" 2>&1) || EXITCODE=$?
}

# run_tshark TSHARK_DATA_FILE [SCRIPT_ARGS...]
# Injects pre-canned "epoch iface state" lines via _LINK_FLAP_TEST_TSHARK.
run_tshark() {
  local f="$1"; shift
  OUT=''; EXITCODE=0
  OUT=$(_LINK_FLAP_TEST_TSHARK="$f" bash "$SCRIPT" "$@" 2>&1) || EXITCODE=$?
}

# run_with_prom INPUT_FILE PROM_JSON_FILE [SCRIPT_ARGS...]
run_with_prom() {
  local input_f="$1" prom_f="$2"; shift 2
  OUT=''; EXITCODE=0
  OUT=$(_LINK_FLAP_TEST_INPUT="$input_f" _LINK_FLAP_TEST_PROM="$prom_f" \
        bash "$SCRIPT" "$@" 2>&1) || EXITCODE=$?
}

# run_tshark_with_prom TSHARK_DATA_FILE PROM_JSON_FILE [SCRIPT_ARGS...]
run_tshark_with_prom() {
  local tshark_f="$1" prom_f="$2"; shift 2
  OUT=''; EXITCODE=0
  OUT=$(_LINK_FLAP_TEST_TSHARK="$tshark_f" _LINK_FLAP_TEST_PROM="$prom_f" \
        bash "$SCRIPT" "$@" 2>&1) || EXITCODE=$?
}

# run_wizard_test WIZARD_DIR [SCRIPT_ARGS...]
# Runs the diagnostic wizard with canned sysfs/command output files.
run_wizard_test() {
  local wiz_dir="$1"; shift
  OUT=''; EXITCODE=0
  OUT=$(BACKUP_DIR="$TESTDIR/backups" REPORT_DIR="$TESTDIR/reports" \
        _LINK_FLAP_TEST_WIZARD_DIR="$wiz_dir" \
        bash "$SCRIPT" "$@" 2>&1) || EXITCODE=$?
}

# run_rollback_test BACKUP_ID [SCRIPT_ARGS...]
# Runs rollback/list with BACKUP_DIR redirected to the test directory.
run_rollback_test() {
  local bid="$1"; shift
  OUT=''; EXITCODE=0
  OUT=$(BACKUP_DIR="$TESTDIR/backups" bash "$SCRIPT" -r "$bid" "$@" 2>&1) || EXITCODE=$?
}

# run_with_ne INPUT_FILE NE_METRICS_FILE [SCRIPT_ARGS...]
run_with_ne() {
  local input_f="$1" ne_f="$2"; shift 2
  OUT=''; EXITCODE=0
  OUT=$(_LINK_FLAP_TEST_INPUT="$input_f" _LINK_FLAP_TEST_NODE_EXPORTER="$ne_f" \
        bash "$SCRIPT" "$@" 2>&1) || EXITCODE=$?
}

# run_wizard_ne_test WIZARD_DIR NE_METRICS_FILE [SCRIPT_ARGS...]
run_wizard_ne_test() {
  local wiz_dir="$1" ne_f="$2"; shift 2
  OUT=''; EXITCODE=0
  OUT=$(BACKUP_DIR="$TESTDIR/backups" REPORT_DIR="$TESTDIR/reports" \
        _LINK_FLAP_TEST_WIZARD_DIR="$wiz_dir" \
        _LINK_FLAP_TEST_NODE_EXPORTER="$ne_f" \
        bash "$SCRIPT" "$@" 2>&1) || EXITCODE=$?
}

# run_with_iperf3 INPUT_FILE IPERF3_JSON [SCRIPT_ARGS...]
run_with_iperf3() {
  local input_f="$1" iperf3_f="$2"; shift 2
  OUT=''; EXITCODE=0
  OUT=$(_LINK_FLAP_TEST_INPUT="$input_f" _LINK_FLAP_TEST_IPERF3="$iperf3_f" \
        bash "$SCRIPT" -b test-server.example.com "$@" 2>&1) || EXITCODE=$?
}

# run_wizard_iperf3_test WIZARD_DIR IPERF3_JSON [SCRIPT_ARGS...]
run_wizard_iperf3_test() {
  local wiz_dir="$1" iperf3_f="$2"; shift 2
  OUT=''; EXITCODE=0
  OUT=$(BACKUP_DIR="$TESTDIR/backups" REPORT_DIR="$TESTDIR/reports" \
        _LINK_FLAP_TEST_WIZARD_DIR="$wiz_dir" \
        _LINK_FLAP_TEST_IPERF3="$iperf3_f" \
        bash "$SCRIPT" -b test-server.example.com "$@" 2>&1) || EXITCODE=$?
}

# run_real_wizard_test IFACE [SCRIPT_ARGS...]
# Runs the diagnostic wizard against a real interface — no sysfs/command mocking.
run_real_wizard_test() {
  local iface="$1"; shift
  OUT=''; EXITCODE=0
  OUT=$(BACKUP_DIR="$TESTDIR/real-backups" REPORT_DIR="$TESTDIR/real-reports" \
        bash "$SCRIPT" -d "$iface" "$@" 2>&1) || EXITCODE=$?
}
