#!/usr/bin/env bash
# lib/node-exporter.sh — node_exporter metrics fetch and display.
# Sourced by flap; do not execute directly.

_NE_METRICS_CACHE=""

fetch_node_exporter() {
  # Fetch /metrics from node_exporter; cache result in _NE_METRICS_CACHE.
  # Returns 0 if data was fetched, 1 otherwise.
  # _LINK_FLAP_TEST_NODE_EXPORTER: path to canned metrics file (test hook).
  [[ "$NODE_EXPORTER_URL" == "off" ]] && return 1
  if [[ -n "${_LINK_FLAP_TEST_NODE_EXPORTER:-}" ]]; then
    _NE_METRICS_CACHE=$(cat "$_LINK_FLAP_TEST_NODE_EXPORTER" 2>/dev/null || true)
  else
    _NE_METRICS_CACHE=$(curl -sf --max-time 1 "${NODE_EXPORTER_URL}/metrics" 2>/dev/null || true)
  fi
  [[ -n "$_NE_METRICS_CACHE" ]]
}

_ne_val() {
  # Extract a scalar metric value for a specific device from _NE_METRICS_CACHE.
  local metric="$1" iface="$2"
  echo "$_NE_METRICS_CACHE" | awk -v m="$metric" -v d="$iface" '
    /^#/ { next }
    index($0, m "{") == 1 && index($0, "device=\"" d "\"") { print $NF; exit }
  ' 2>/dev/null || true
}

show_node_exporter_context() {
  # Print a [node_exporter] enrichment block for the given interface.
  # Skips if NE data is not cached, iface is synthetic (stp-*/lacp-*), or no data found.
  local iface="$1"
  [[ -z "$_NE_METRICS_CACHE" ]] && return
  [[ "$iface" =~ ^(stp|lacp)- ]] && return

  local up carrier rx_err tx_err rx_drop tx_drop
  up=$(_ne_val node_network_up "$iface")
  carrier=$(_ne_val node_network_carrier_changes_total "$iface")
  rx_err=$(_ne_val node_network_receive_errs_total "$iface")
  tx_err=$(_ne_val node_network_transmit_errs_total "$iface")
  rx_drop=$(_ne_val node_network_receive_drop_total "$iface")
  tx_drop=$(_ne_val node_network_transmit_drop_total "$iface")

  [[ -z "$up" && -z "$carrier" ]] && return

  echo -e "  ${CYAN}[node_exporter]${RESET}"
  if [[ -n "$up" ]]; then
    local s; [[ "$up" == "1" ]] && s="${GREEN}UP${RESET}" || s="${RED}DOWN${RESET}"
    echo -e "    Current state   : $s"
  fi
  [[ -n "$carrier" ]] && printf "    Carrier changes : %s total since boot\n" "$carrier"
  [[ -n "$rx_err"  ]] && printf "    RX errors       : %s total\n" "$rx_err"
  [[ -n "$tx_err"  ]] && printf "    TX errors       : %s total\n" "$tx_err"
  [[ -n "$rx_drop" ]] && printf "    RX drops        : %s total\n" "$rx_drop"
  [[ -n "$tx_drop" ]] && printf "    TX drops        : %s total\n" "$tx_drop"
}
