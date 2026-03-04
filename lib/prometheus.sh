#!/usr/bin/env bash
# lib/prometheus.sh — Prometheus query helpers, fleet scanning, and enrichment.
# Sourced by flap; do not execute directly.

_PROM_REACHED=0
_PROM_REACHABLE=0   # 1 once any curl to Prometheus succeeds (even with no data)

prom_query() {
  # Query Prometheus instant API; return first result value or empty string.
  # _LINK_FLAP_TEST_PROM: path to a canned JSON response file (test hook).
  local query="$1"
  local response
  if [[ -n "${_LINK_FLAP_TEST_PROM:-}" ]]; then
    response=$(cat "$_LINK_FLAP_TEST_PROM")
  else
    response=$(curl -sf -G "${PROM_URL}/api/v1/query" \
      --data-urlencode "query=$query" \
      --max-time 5 2>/dev/null) || return 0
  fi
  if command -v jq &>/dev/null; then
    echo "$response" | jq -r '.data.result[0].value[1] // empty' 2>/dev/null
  else
    python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
r=d.get('data',{}).get('result',[])
if r: print(r[0]['value'][1])
" <<< "$response" 2>/dev/null
  fi
}

prom_query_at() {
  # Query Prometheus instant API at a specific Unix epoch timestamp.
  # Returns the first result value, or empty string if no data.
  # Uses _LINK_FLAP_TEST_PROM for offline testing (same hook as prom_query).
  local query="$1" epoch="$2"
  local response
  if [[ -n "${_LINK_FLAP_TEST_PROM:-}" ]]; then
    response=$(cat "$_LINK_FLAP_TEST_PROM")
  else
    response=$(curl -sf -G "${PROM_URL}/api/v1/query" \
      --data-urlencode "query=$query" \
      --data-urlencode "time=$epoch" \
      --max-time 5 2>/dev/null) || return 0
  fi
  if command -v jq &>/dev/null; then
    echo "$response" | jq -r '.data.result[0].value[1] // empty' 2>/dev/null
  else
    python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
r=d.get('data',{}).get('result',[])
if r: print(r[0]['value'][1])
" <<< "$response" 2>/dev/null
  fi
}

prom_query_all() {
  # Query Prometheus instant API; return all results as "instance:device VALUE" lines.
  # Used by fleet mode to get metrics across every monitored host.
  # _LINK_FLAP_TEST_PROM_ALL: path to a canned JSON response file (test hook).
  local query="$1"
  local response
  if [[ -n "${_LINK_FLAP_TEST_PROM_ALL:-}" ]]; then
    response=$(cat "$_LINK_FLAP_TEST_PROM_ALL")
  else
    response=$(curl -sf -G "${PROM_URL}/api/v1/query" \
      --data-urlencode "query=$query" \
      --max-time 5 2>/dev/null) || return 0
  fi
  if command -v jq &>/dev/null; then
    echo "$response" | jq -r '
      .data.result[] |
      ((.metric.instance // "unknown") + ":" + (.metric.device // "unknown")) + " " + .value[1]
    ' 2>/dev/null
  else
    python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
for r in d.get('data', {}).get('result', []):
  inst = r['metric'].get('instance', 'unknown')
  dev  = r['metric'].get('device',   'unknown')
  val  = r['value'][1]
  print(inst + ':' + dev + ' ' + val)
" <<< "$response" 2>/dev/null
  fi
}

prom_targets_health() {
  # Return "down" scrape targets as "INSTANCE LAST_SCRAPE ERROR" lines (space-separated).
  # Silently returns nothing if Prometheus is unreachable or no targets are down.
  # No test hook — fails silently if Prom is absent.
  [[ -z "$PROM_URL" ]] && return 0
  local response
  response=$(curl -sf "${PROM_URL}/api/v1/targets" --max-time 5 2>/dev/null) || return 0
  if command -v jq &>/dev/null; then
    echo "$response" | jq -r '
      .data.activeTargets[] |
      select(.health == "down") |
      [.labels.instance, .lastScrape, (.lastError // "unknown error")] | join("\t")
    ' 2>/dev/null
  else
    python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
for t in d.get('data', {}).get('activeTargets', []):
  if t.get('health') == 'down':
    inst   = t.get('labels', {}).get('instance', 'unknown')
    scrape = t.get('lastScrape', '')
    err    = t.get('lastError', 'unknown error')
    print(inst + '\t' + scrape + '\t' + err)
" <<< "$response" 2>/dev/null
  fi
}

_fleet_print_targets() {
  local data="$1"
  [[ -z "$data" ]] && return
  echo -e "${YELLOW}${BOLD}[UNREACHABLE TARGETS]${RESET}"
  while IFS=$'\t' read -r inst scrape err; do
    [[ -z "$inst" ]] && continue
    local scrape_disp; [[ -z "$scrape" ]] && scrape_disp="never" || scrape_disp="$scrape"
    echo -e "  ${CYAN}${inst}${RESET}  last scrape: ${scrape_disp}  —  ${err}"
  done <<< "$data"
  echo ""
}

fleet_scan_prometheus() {
  local query="increase(node_network_carrier_changes_total[${WINDOW_MINUTES}m])"
  local results
  results=$(prom_query_all "$query") || true

  local flapping_found=0

  while IFS=' ' read -r inst_dev val; do
    [[ -z "$inst_dev" || -z "$val" ]] && continue
    # inst_dev format: "hostname:9100:eth0" — split on last colon to get device name
    local iface="${inst_dev##*:}"
    local inst="${inst_dev%:*}"   # strip last colon+iface → "hostname:9100"
    # Filter virtual interfaces unless -i is set
    if [[ -z "$IFACE_FILTER" ]]; then
      [[ "$iface" =~ ^(lo|veth|virbr|docker|tun|tap|br-) ]] && continue
    else
      [[ "$iface" != "$IFACE_FILTER" ]] && continue
    fi
    # val is a float; compare to threshold
    local above
    above=$(awk -v v="$val" -v t="$FLAP_THRESHOLD" 'BEGIN { print (v+0 >= t+0) ? "yes" : "no" }')
    [[ "$above" != "yes" ]] && continue

    # Enrich: current state and error rates
    local up_val rx_err tx_err
    up_val=$(prom_query "node_network_up{instance=\"${inst}\",device=\"${iface}\"}")
    rx_err=$(prom_query "rate(node_network_receive_errs_total{instance=\"${inst}\",device=\"${iface}\"}[5m])*60")
    tx_err=$(prom_query "rate(node_network_transmit_errs_total{instance=\"${inst}\",device=\"${iface}\"}[5m])*60")

    local state_str="${DIM}unknown${RESET}"
    [[ "$up_val" == "1" ]] && state_str="${GREEN}UP${RESET}"
    [[ "$up_val" == "0" ]] && state_str="${RED}DOWN${RESET}"

    local trans_display
    trans_display=$(printf "%.0f" "$val")

    echo -e "${RED}${BOLD}[FLAPPING]${RESET}  ${BOLD}${inst}${RESET}:${BOLD}${iface}${RESET}"
    echo -e "  Carrier changes : ${RED}${trans_display}${RESET} in last ${WINDOW_MINUTES}m"
    echo -e "  Current state   : ${state_str}"
    [[ -n "$rx_err" ]] && printf "  RX errors       : %.2f/min\n" "$rx_err"
    [[ -n "$tx_err" ]] && printf "  TX errors       : %.2f/min\n" "$tx_err"
    echo ""
    flapping_found=1
    # shellcheck disable=SC2034  # FLAPPING_FOUND is read in flap main script
    FLAPPING_FOUND=1
  done <<< "$results"

  if [[ "$flapping_found" -eq 0 ]]; then
    echo -e "${GREEN}No flapping detected across fleet in the last ${WINDOW_MINUTES}m.${RESET}"
    echo ""
  fi

  local down_targets
  down_targets=$(prom_targets_health) || true
  _fleet_print_targets "$down_targets"
}

show_prometheus_context() {
  # Print a [Prometheus] enrichment block for the given interface.
  # Skips silently if no Prometheus source is configured, the interface is
  # a synthetic tshark name (stp-*/lacp-*), or no data is returned.
  local iface="$1"
  [[ -z "$PROM_URL" && -z "${_LINK_FLAP_TEST_PROM:-}" ]] && return
  [[ "$iface" =~ ^(stp|lacp)- ]] && return

  # One-time reachability probe (runs outside subshell so the flag persists)
  if [[ "$_PROM_REACHABLE" -eq 0 ]]; then
    if [[ -n "${_LINK_FLAP_TEST_PROM:-}" ]]; then
      _PROM_REACHABLE=1
    elif curl -sf --max-time 3 "${PROM_URL}/api/v1/query?query=1" >/dev/null 2>&1; then
      _PROM_REACHABLE=1
    fi
  fi

  local up carrier rx_err tx_err rx_drop tx_drop
  up=$(prom_query "node_network_up{device=\"$iface\"}")
  carrier=$(prom_query "increase(node_network_carrier_changes_total{device=\"$iface\"}[${WINDOW_MINUTES}m])")
  rx_err=$(prom_query "rate(node_network_receive_errs_total{device=\"$iface\"}[5m])*60")
  tx_err=$(prom_query "rate(node_network_transmit_errs_total{device=\"$iface\"}[5m])*60")
  rx_drop=$(prom_query "rate(node_network_receive_drop_total{device=\"$iface\"}[5m])*60")
  tx_drop=$(prom_query "rate(node_network_transmit_drop_total{device=\"$iface\"}[5m])*60")

  [[ -z "$up" && -z "$carrier" ]] && return

  _PROM_REACHED=1
  echo -e "  ${CYAN}[Prometheus]${RESET}"
  if [[ -n "$up" ]]; then
    local s; [[ "$up" == "1" ]] && s="${GREEN}UP${RESET}" || s="${RED}DOWN${RESET}"
    echo -e "    Current state   : $s"
  fi
  [[ -n "$carrier" ]] && printf "    Carrier changes : %.0f in last %sm\n" "$carrier" "$WINDOW_MINUTES"
  [[ -n "$rx_err"  ]] && printf "    RX errors       : %.2f/min\n" "$rx_err"
  [[ -n "$tx_err"  ]] && printf "    TX errors       : %.2f/min\n" "$tx_err"
  [[ -n "$rx_drop" ]] && printf "    RX drops        : %.2f/min\n" "$rx_drop"
  [[ -n "$tx_drop" ]] && printf "    TX drops        : %.2f/min\n" "$tx_drop"
}

show_system_load_at_flap() {
  # Print a [system @ flap time] block showing CPU idle %, memory available %,
  # and load average at the moment flapping began (first_epoch).
  # Requires Prometheus with node_exporter data. Silently skips if unavailable.
  local iface="$1" epoch="$2"
  [[ -z "$PROM_URL" && -z "${_LINK_FLAP_TEST_PROM:-}" ]] && return
  [[ "$iface" =~ ^(stp|lacp)- ]] && return

  local cpu_idle mem_avail load1
  cpu_idle=$(prom_query_at \
    'avg(rate(node_cpu_seconds_total{mode="idle"}[5m]))*100' "$epoch")
  mem_avail=$(prom_query_at \
    'node_memory_MemAvailable_bytes/node_memory_MemTotal_bytes*100' "$epoch")
  load1=$(prom_query_at "node_load1" "$epoch")

  [[ -z "$cpu_idle" && -z "$mem_avail" && -z "$load1" ]] && return

  local flap_ts
  flap_ts=$(date -d "@$epoch" "+%H:%M:%S" 2>/dev/null || echo "unknown")
  echo -e "  ${CYAN}[system @ ${flap_ts}]${RESET}"

  if [[ -n "$cpu_idle" ]]; then
    local cpu_col="$GREEN"
    awk -v v="$cpu_idle" 'BEGIN{exit !(v+0 < 15)}'  && cpu_col="$RED"    || true
    awk -v v="$cpu_idle" 'BEGIN{exit !(v+0>=15 && v+0<30)}' && cpu_col="$YELLOW" || true
    printf "    CPU idle        : ${cpu_col}%.1f%%${RESET}\n" "$cpu_idle"
  fi
  if [[ -n "$mem_avail" ]]; then
    local mem_col="$GREEN"
    awk -v v="$mem_avail" 'BEGIN{exit !(v+0 < 10)}' && mem_col="$YELLOW" || true
    printf "    Memory available: ${mem_col}%.1f%%${RESET}\n" "$mem_avail"
  fi
  [[ -n "$load1" ]] && printf "    Load avg (1m)   : %.2f\n" "$load1"
}
