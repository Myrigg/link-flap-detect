#!/usr/bin/env bash
# tests/test-sysload.sh
# Automated tests: historical system load correlation via Prometheus.
#
# Tests covered: 74–77
#
# Verifies that when Prometheus is configured (-m URL), the tool queries
# CPU idle %, memory available %, and load average at the time flapping
# began, and surfaces findings in both the enrichment block and wizard report.
#
# All tests are fully offline. prom_query_at() reuses _LINK_FLAP_TEST_PROM
# (same hook as prom_query()), so existing canned JSON files work for both.
#
# Usage (standalone):  bash tests/test-sysload.sh
# Usage (via runner):  sourced by tests/run-tests.sh
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo ""
echo -e "${BOLD}Offline tests — historical system load correlation${RESET}"
echo ""

# ── Shared synthetic log input ─────────────────────────────────────────────────
# 5 transitions on eth0 → [FLAPPING]; provides first_epoch for prom_query_at
_sysload_input=$(mktemp "$TESTDIR/sysload-input-XXXXXX.log")
cat > "$_sysload_input" <<EOF
$(ts 0)   host kernel: eth0: NIC Link is Down
$(ts 60)  host kernel: eth0: NIC Link is Up
$(ts 120) host kernel: eth0: NIC Link is Down
$(ts 180) host kernel: eth0: NIC Link is Up
$(ts 240) host kernel: eth0: NIC Link is Down
EOF

# ── Canned Prometheus responses ───────────────────────────────────────────────

# Non-empty result returning "15" — moderate CPU idle, healthy memory
_prom_data=$(mktemp "$TESTDIR/sysload-prom-data-XXXXXX.json")
cat > "$_prom_data" <<'EOF'
{"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[1709386700,"15"]}]}}
EOF

# Empty result — Prometheus has no data
_prom_empty=$(mktemp "$TESTDIR/sysload-prom-empty-XXXXXX.json")
cat > "$_prom_empty" <<'EOF'
{"status":"success","data":{"resultType":"vector","result":[]}}
EOF

# Low CPU idle: 5% → [CAUSE] threshold
_prom_cpu_low=$(mktemp "$TESTDIR/sysload-prom-cpu-low-XXXXXX.json")
cat > "$_prom_cpu_low" <<'EOF'
{"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[1709386700,"5"]}]}}
EOF

# Low memory: 8% available → [WARN] threshold
_prom_mem_low=$(mktemp "$TESTDIR/sysload-prom-mem-low-XXXXXX.json")
cat > "$_prom_mem_low" <<'EOF'
{"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[1709386700,"8"]}]}}
EOF

# ── Tests ─────────────────────────────────────────────────────────────────────

# 74. [system @ flap time] block shown when Prometheus has data
run_with_prom "$_sysload_input" "$_prom_data" -w 60 -t 3 -m http://fake-prom:9090

ok=1
echo "$OUT" | grep -q "\[FLAPPING\]"    || ok=0
echo "$OUT" | grep -q "\[system @"      || ok=0
echo "$OUT" | grep -q "CPU idle"        || ok=0

if [[ $ok -eq 1 ]]; then
  pass "74: [system @ flap time] shown for flapping interface when Prometheus has data"
else
  fail "74: [system @ flap time] shown for flapping interface when Prometheus has data" "exit=$EXITCODE\n$OUT"
fi

# 75. [system @ flap time] block absent when Prometheus returns empty result
run_with_prom "$_sysload_input" "$_prom_empty" -w 60 -t 3 -m http://fake-prom:9090

ok=1
echo "$OUT" | grep -q "\[FLAPPING\]"     || ok=0
echo "$OUT" | grep -qv "\[system @"      || ok=0

if [[ $ok -eq 1 ]]; then
  pass "75: [system @ flap time] absent when Prometheus returns empty result"
else
  fail "75: [system @ flap time] absent when Prometheus returns empty result" "exit=$EXITCODE\n$OUT"
fi

# 76. Wizard: [CAUSE] when CPU idle was critically low (< 15%) at flap time
wiz_dir=$(mktemp -d "$TESTDIR/wiz-sysload-XXXXXX")
echo "up" > "$wiz_dir/operstate"
OUT=''; EXITCODE=0
OUT=$(XDG_CONFIG_HOME="$TESTDIR/cfg-sysload" \
      BACKUP_DIR="$TESTDIR/backups" REPORT_DIR="$TESTDIR/reports" \
      _LINK_FLAP_TEST_WIZARD_DIR="$wiz_dir" \
      _LINK_FLAP_TEST_PROM="$_prom_cpu_low" \
      _LINK_FLAP_TEST_INPUT="$_sysload_input" \
      bash "$SCRIPT" -d eth0 -m http://fake-prom:9090 -w 60 2>&1) || EXITCODE=$?

ok=1
[[ $EXITCODE -eq 0 ]]                              || ok=0
echo "$OUT" | grep -q "\[CAUSE\]"                  || ok=0
echo "$OUT" | grep -qi "CPU saturation"            || ok=0

if [[ $ok -eq 1 ]]; then
  pass "76: wizard [CAUSE] CPU saturation when idle < 15% at flap time (exit=$EXITCODE)"
else
  fail "76: wizard [CAUSE] CPU saturation when idle < 15% at flap time" "exit=$EXITCODE\n$OUT"
fi

# 77. Wizard: [WARN] when memory available was low (< 10%) at flap time
wiz_dir=$(mktemp -d "$TESTDIR/wiz-sysload-XXXXXX")
echo "up" > "$wiz_dir/operstate"
OUT=''; EXITCODE=0
OUT=$(XDG_CONFIG_HOME="$TESTDIR/cfg-sysload" \
      BACKUP_DIR="$TESTDIR/backups" REPORT_DIR="$TESTDIR/reports" \
      _LINK_FLAP_TEST_WIZARD_DIR="$wiz_dir" \
      _LINK_FLAP_TEST_PROM="$_prom_mem_low" \
      _LINK_FLAP_TEST_INPUT="$_sysload_input" \
      bash "$SCRIPT" -d eth0 -m http://fake-prom:9090 -w 60 2>&1) || EXITCODE=$?

ok=1
[[ $EXITCODE -eq 0 ]]                              || ok=0
echo "$OUT" | grep -q "\[WARN\]"                   || ok=0
echo "$OUT" | grep -qi "memory"                    || ok=0

if [[ $ok -eq 1 ]]; then
  pass "77: wizard [WARN] low memory when available < 10% at flap time (exit=$EXITCODE)"
else
  fail "77: wizard [WARN] low memory when available < 10% at flap time" "exit=$EXITCODE\n$OUT"
fi
