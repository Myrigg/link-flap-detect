#!/usr/bin/env bash
# tests/test-fleet.sh
# Automated tests: --fleet mode — Prometheus fleet-wide flap detection.
#
# Tests covered: 70–73
#
# All tests are fully offline — no real Prometheus required.
# Canned Prometheus JSON responses are written to temp files.
#
# Usage (standalone):  bash tests/test-fleet.sh
# Usage (via runner):  sourced by tests/run-tests.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo ""
echo -e "${BOLD}Fleet mode tests — offline Prometheus fleet scan${RESET}"
echo ""

# ── Canned Prometheus API responses ───────────────────────────────────────────

# Two hosts, two devices — both above the default threshold of 3
_FLEET_PROM_FLAPPING=$(cat <<'EOF'
{
  "status": "success",
  "data": {
    "resultType": "vector",
    "result": [
      {
        "metric": {
          "__name__": "node_network_carrier_changes_total",
          "device": "eth0",
          "instance": "server1:9100",
          "job": "node"
        },
        "value": [1709460000, "8"]
      },
      {
        "metric": {
          "__name__": "node_network_carrier_changes_total",
          "device": "ens3",
          "instance": "server2:9100",
          "job": "node"
        },
        "value": [1709460000, "5"]
      }
    ]
  }
}
EOF
)

# Two devices — both below the default threshold of 3
_FLEET_PROM_CLEAN=$(cat <<'EOF'
{
  "status": "success",
  "data": {
    "resultType": "vector",
    "result": [
      {
        "metric": {
          "__name__": "node_network_carrier_changes_total",
          "device": "eth0",
          "instance": "server1:9100",
          "job": "node"
        },
        "value": [1709460000, "1"]
      },
      {
        "metric": {
          "__name__": "node_network_carrier_changes_total",
          "device": "ens3",
          "instance": "server2:9100",
          "job": "node"
        },
        "value": [1709460000, "2"]
      }
    ]
  }
}
EOF
)

# Two devices from different hosts — for filter test
_FLEET_PROM_FILTER=$(cat <<'EOF'
{
  "status": "success",
  "data": {
    "resultType": "vector",
    "result": [
      {
        "metric": {
          "__name__": "node_network_carrier_changes_total",
          "device": "eth0",
          "instance": "server1:9100",
          "job": "node"
        },
        "value": [1709460000, "7"]
      },
      {
        "metric": {
          "__name__": "node_network_carrier_changes_total",
          "device": "ens3",
          "instance": "server2:9100",
          "job": "node"
        },
        "value": [1709460000, "6"]
      }
    ]
  }
}
EOF
)

# Single result from prom_query() for enrichment (state, error rates)
# prom_query() re-uses _LINK_FLAP_TEST_PROM for single-result calls; we provide
# a no-data canned response so enrichment silently omits and doesn't crash.
_FLEET_PROM_ENRICH=$(cat <<'EOF'
{"status":"success","data":{"resultType":"vector","result":[]}}
EOF
)

# Write canned responses to temp files
_f_flapping="$TESTDIR/fleet-prom-flapping.json"
_f_clean="$TESTDIR/fleet-prom-clean.json"
_f_filter="$TESTDIR/fleet-prom-filter.json"
_f_enrich="$TESTDIR/fleet-prom-enrich.json"
printf '%s\n' "$_FLEET_PROM_FLAPPING" > "$_f_flapping"
printf '%s\n' "$_FLEET_PROM_CLEAN"    > "$_f_clean"
printf '%s\n' "$_FLEET_PROM_FILTER"   > "$_f_filter"
printf '%s\n' "$_FLEET_PROM_ENRICH"   > "$_f_enrich"

# ── Tests ──────────────────────────────────────────────────────────────────────

# 70. Fleet scan detects flapping — two hosts above threshold; exit code 1
run_fleet_test "$_f_flapping" \
  _LINK_FLAP_TEST_PROM="$_f_enrich"
# prom_query() for enrichment reuses _LINK_FLAP_TEST_PROM; pass it inline via env
OUT=''; EXITCODE=0
OUT=$(XDG_CONFIG_HOME="$TESTDIR/cfg-fleet" \
      _LINK_FLAP_TEST_PROM_ALL="$_f_flapping" \
      _LINK_FLAP_TEST_PROM="$_f_enrich" \
      bash "$SCRIPT" -m http://fake-prom:9090 --fleet 2>&1) || EXITCODE=$?

ok=1
[[ $EXITCODE -eq 1 ]]                             || ok=0
echo "$OUT" | grep -q "\[FLAPPING\]"              || ok=0
echo "$OUT" | grep -q "server1:9100"              || ok=0
echo "$OUT" | grep -q "server2:9100"              || ok=0
echo "$OUT" | grep -q "fleet mode"                || ok=0
echo "$OUT" | grep -q "WARNING: SYNTHETIC"        || ok=0

if [[ $ok -eq 1 ]]; then
  pass "70: fleet scan — two hosts flapping detected (exit=$EXITCODE)"
else
  fail "70: fleet scan — two hosts flapping detected" "exit=$EXITCODE\n$OUT"
fi

# 71. Fleet scan no flapping — all carrier counts below threshold; exit code 0
OUT=''; EXITCODE=0
OUT=$(XDG_CONFIG_HOME="$TESTDIR/cfg-fleet" \
      _LINK_FLAP_TEST_PROM_ALL="$_f_clean" \
      _LINK_FLAP_TEST_PROM="$_f_enrich" \
      bash "$SCRIPT" -m http://fake-prom:9090 --fleet 2>&1) || EXITCODE=$?

ok=1
[[ $EXITCODE -eq 0 ]]                                               || ok=0
echo "$OUT" | grep -q "No flapping detected across fleet"           || ok=0
echo "$OUT" | grep -qv "\[FLAPPING\]"                               || ok=0

if [[ $ok -eq 1 ]]; then
  pass "71: fleet scan — no flapping (exit=$EXITCODE)"
else
  fail "71: fleet scan — no flapping" "exit=$EXITCODE\n$OUT"
fi

# 72. Fleet scan with -i filter — only the filtered device appears; other is absent
OUT=''; EXITCODE=0
OUT=$(XDG_CONFIG_HOME="$TESTDIR/cfg-fleet" \
      _LINK_FLAP_TEST_PROM_ALL="$_f_filter" \
      _LINK_FLAP_TEST_PROM="$_f_enrich" \
      bash "$SCRIPT" -m http://fake-prom:9090 --fleet -i eth0 2>&1) || EXITCODE=$?

ok=1
echo "$OUT" | grep -q "eth0"                      || ok=0
echo "$OUT" | grep -qv "ens3"                     || ok=0
[[ $EXITCODE -eq 1 ]]                             || ok=0

if [[ $ok -eq 1 ]]; then
  pass "72: fleet scan -i eth0 — filter works, ens3 absent (exit=$EXITCODE)"
else
  fail "72: fleet scan -i eth0 — filter works, ens3 absent" "exit=$EXITCODE\n$OUT"
fi

# 73. --fleet without -m fails with exit code 1 and an error message
# Use a fresh config dir so no PROM_URL saved by tests 70-72 is visible.
OUT=''; EXITCODE=0
OUT=$(XDG_CONFIG_HOME="$TESTDIR/cfg-73" bash "$SCRIPT" --fleet 2>&1) || EXITCODE=$?

ok=1
[[ $EXITCODE -eq 2 ]]                               || ok=0
echo "$OUT" | grep -qi "requires -m"                || ok=0

if [[ $ok -eq 1 ]]; then
  pass "73: --fleet without -m — exits 2 with error message (exit=$EXITCODE)"
else
  fail "73: --fleet without -m — exits 2 with error message" "exit=$EXITCODE\n$OUT"
fi

# 74. Fleet scan with unreachable Prometheus → exit 2 + error message
# Use a non-routable IP to simulate unreachable Prometheus.
OUT=''; EXITCODE=0
OUT=$(XDG_CONFIG_HOME="$TESTDIR/cfg-74" \
      bash "$SCRIPT" -m http://192.0.2.1:9090 --fleet 2>&1) || EXITCODE=$?

ok=1
[[ $EXITCODE -eq 2 ]]                                || ok=0
echo "$OUT" | grep -qi "unreachable"                 || ok=0

if [[ $ok -eq 1 ]]; then
  pass "74: fleet scan — unreachable Prometheus → exit 2 + error (exit=$EXITCODE)"
else
  fail "74: fleet scan — unreachable Prometheus → exit 2 + error" "exit=$EXITCODE\n$OUT"
fi
