#!/usr/bin/env bash
# lib/iperf3.sh — iperf3 active bandwidth/retransmit probing.
# Sourced by flap; do not execute directly.

_IPERF3_RESULT_CACHE=""
_IPERF3_BIND_IP=""     # IP used for -B binding (empty = unbound)

run_iperf3() {
  local iface="${1:-}"    # interface being diagnosed (empty in non-wizard mode)
  local local_ip="${2:-}" # IP to bind to (IPv4 or global IPv6; empty = unbound)
  [[ -z "$IPERF3_SERVER" ]] && return 1
  if [[ -n "${_LINK_FLAP_TEST_IPERF3:-}" ]]; then
    _IPERF3_RESULT_CACHE=$(cat "$_LINK_FLAP_TEST_IPERF3" 2>/dev/null || true)
  else
    local bind_args=()
    [[ -n "$local_ip" ]] && bind_args=(-B "$local_ip")
    _IPERF3_RESULT_CACHE=$(iperf3 -c "$IPERF3_SERVER" "${bind_args[@]}" -t 5 --json \
                           2>/dev/null || true)
  fi
  _IPERF3_BIND_IP="$local_ip"
  [[ -n "$_IPERF3_RESULT_CACHE" ]]
}

_iperf3_val() {
  local field="$1"
  [[ -z "$_IPERF3_RESULT_CACHE" ]] && return
  python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    v = d
    for p in sys.argv[1].split('.'):
        v = v[p]
    print(v)
except Exception:
    pass
" "$field" <<< "$_IPERF3_RESULT_CACHE" 2>/dev/null || true
}

show_iperf3_context() {
  local iface="$1"
  [[ -z "$_IPERF3_RESULT_CACHE" ]] && return
  [[ "$iface" =~ ^(stp|lacp)- ]] && return

  local bps retransmits
  bps=$(_iperf3_val "end.sum_sent.bits_per_second")
  retransmits=$(_iperf3_val "end.sum_sent.retransmits")

  [[ -z "$bps" && -z "$retransmits" ]] && return

  if [[ -n "$_IPERF3_BIND_IP" ]]; then
    echo -e "  ${CYAN}[iperf3]${RESET}  → ${IPERF3_SERVER}  (via ${iface} ${_IPERF3_BIND_IP})"
  else
    echo -e "  ${CYAN}[iperf3]${RESET}  → ${IPERF3_SERVER}"
  fi
  if [[ -n "$bps" ]]; then
    local mbps
    mbps=$(python3 -c "import sys; print(f'{float(sys.argv[1])/1e6:.1f}')" "$bps" 2>/dev/null || echo "?")
    printf "    Bandwidth       : %s Mbps\n" "$mbps"
  fi
  if [[ -n "$retransmits" ]]; then
    if [[ "$retransmits" =~ ^[0-9]+$ ]] && [[ "$retransmits" -gt 0 ]]; then
      echo -e "    Retransmits     : ${YELLOW}${retransmits}${RESET}"
    else
      echo    "    Retransmits     : ${retransmits}"
    fi
  fi
}
