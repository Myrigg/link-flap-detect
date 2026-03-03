#!/usr/bin/env bash
# tests/run-tests.sh
# Test runner for the flap test suite.
#
# Sources the shared library and each feature-specific test file in order,
# then prints a combined pass/fail/skip summary.
#
# Properties guaranteed:
#   - Offline tests use only synthetic data — no system logs, no root required
#   - Live tests skip gracefully when prerequisites are unavailable
#   - No side effects outside /tmp (temp dir cleaned on exit)
#   - Idempotent — safe to run repeatedly
#
# Individual test files can also be run in isolation:
#   bash tests/test-detection.sh
#   bash tests/test-tshark.sh
#   bash tests/test-prometheus.sh
#   bash tests/test-wizard.sh
#   bash tests/test-node-exporter.sh
#   bash tests/test-iperf3.sh
#   bash tests/test-correlation.sh
#   bash tests/test-live-system.sh
#
# Usage:
#   bash tests/run-tests.sh

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load shared helpers (SCRIPT path, counters, colour vars, runner functions).
# shellcheck source=tests/lib.sh
source "$TESTS_DIR/lib.sh"

echo ""
echo -e "${BOLD}flap — test suite${RESET}"
echo ""

# Source each feature test file. They all share the PASS/FAIL/SKIP counters and
# TESTDIR from lib.sh, so the final summary reflects the full combined run.
# shellcheck source=tests/test-detection.sh
source "$TESTS_DIR/test-detection.sh"
# shellcheck source=tests/test-tshark.sh
source "$TESTS_DIR/test-tshark.sh"
# shellcheck source=tests/test-prometheus.sh
source "$TESTS_DIR/test-prometheus.sh"
# shellcheck source=tests/test-wizard.sh
source "$TESTS_DIR/test-wizard.sh"
# shellcheck source=tests/test-node-exporter.sh
source "$TESTS_DIR/test-node-exporter.sh"
# shellcheck source=tests/test-iperf3.sh
source "$TESTS_DIR/test-iperf3.sh"
# shellcheck source=tests/test-correlation.sh
source "$TESTS_DIR/test-correlation.sh"
# shellcheck source=tests/test-live-system.sh
source "$TESTS_DIR/test-live-system.sh"
# shellcheck source=tests/test-fleet.sh
source "$TESTS_DIR/test-fleet.sh"
# shellcheck source=tests/test-sysload.sh
source "$TESTS_DIR/test-sysload.sh"
# shellcheck source=tests/test-wizard-enrichment.sh
source "$TESTS_DIR/test-wizard-enrichment.sh"
# shellcheck source=tests/test-fault-localization.sh
source "$TESTS_DIR/test-fault-localization.sh"

# ── Summary ───────────────────────────────────────────────────────────────────
TOTAL=$(( PASS + FAIL ))
echo ""
if [[ $FAIL -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}All ${TOTAL} tests passed.${RESET}"
  [[ $SKIP -gt 0 ]] && echo -e "  ${YELLOW}(${SKIP} skipped — prerequisites not available on this system)${RESET}"
  echo ""
  exit 0
else
  echo -e "${RED}${BOLD}${FAIL} of ${TOTAL} tests failed.${RESET}"
  [[ $SKIP -gt 0 ]] && echo -e "  ${YELLOW}(${SKIP} skipped — prerequisites not available on this system)${RESET}"
  echo ""
  exit 1
fi
