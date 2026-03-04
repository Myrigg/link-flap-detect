#!/usr/bin/env bash
# lib/menu.sh — Interactive wizard-first UX menus.
# Sourced by flap; do not execute directly.

# _interactive_menu — show guided menus when run with no args on a TTY.
# Sets DIAG_IFACE / IFACE_FILTER / WINDOW_MINUTES / SINCE_INPUT / UNTIL_INPUT
# and _INTERACTIVE_ARGS for the "re-run same test" option.
_interactive_menu() {
  # Guard: only run on a real terminal with no user-supplied args
  [[ -t 1 ]] || return 0
  [[ "${#_ORIG_ARGS[@]}" -gt 0 ]] && return 0
  [[ -n "${_FLAP_FOLLOW_CHILD:-}" ]] && return 0
  [[ -n "${_LINK_FLAP_TEST_INPUT:-}" ]]         && return 0
  [[ -n "${_LINK_FLAP_TEST_TSHARK:-}" ]]        && return 0
  [[ -n "${_LINK_FLAP_TEST_PROM:-}" ]]          && return 0
  [[ -n "${_LINK_FLAP_TEST_NODE_EXPORTER:-}" ]] && return 0
  [[ -n "${_LINK_FLAP_TEST_IPERF3:-}" ]]        && return 0
  [[ -n "${_LINK_FLAP_TEST_WIZARD_DIR:-}" ]]    && return 0
  [[ -n "${_LINK_FLAP_TEST_PROM_ALL:-}" ]]      && return 0

  local divider="╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌"
  echo -e "${divider}"
  echo -e "  ${BOLD}flap${RESET} — network link diagnostics"
  echo -e "${divider}"
  echo ""

  # ── Interface selection ──────────────────────────────────────────────────────
  echo "  Interfaces:"
  _list_interfaces
  echo "    a) All interfaces"
  echo ""

  local iface_choice selected_iface=""
  while true; do
    printf "  Select interface [1]: "
    read -r iface_choice 2>/dev/null || iface_choice=""
    [[ -z "$iface_choice" ]] && iface_choice="1"
    if [[ "$iface_choice" == "a" || "$iface_choice" == "A" ]]; then
      selected_iface="all"
      break
    elif [[ "$iface_choice" =~ ^[0-9]+$ ]]; then
      local idx=$(( iface_choice - 1 ))
      if [[ "$idx" -ge 0 && "$idx" -lt "${#_IFACE_LIST[@]}" ]]; then
        selected_iface="${_IFACE_LIST[$idx]}"
        break
      fi
    else
      # Accept a literal interface name
      local n
      for n in "${_IFACE_LIST[@]}"; do
        if [[ "$iface_choice" == "$n" ]]; then
          selected_iface="$n"
          break 2
        fi
      done
    fi
    echo "  Invalid selection — enter a number, interface name, or 'a'."
  done
  echo ""

  # ── Time window ──────────────────────────────────────────────────────────────
  echo "  Time window:"
  echo "    1) Last 60 minutes (default)"
  echo "    2) Custom — enter minutes"
  echo "    3) Historical date range (--since / --until)"
  echo ""

  local time_choice
  printf "  Select [1]: "
  read -r time_choice 2>/dev/null || time_choice=""
  [[ -z "$time_choice" ]] && time_choice="1"
  echo ""

  case "$time_choice" in
    2)
      printf "  Minutes: "
      local mins=""
      read -r mins 2>/dev/null || mins=""
      if [[ "$mins" =~ ^[0-9]+$ ]] && [[ "$mins" -ge 1 ]]; then
        WINDOW_MINUTES="$mins"
      fi
      echo ""
      ;;
    3)
      printf "  From (YYYY-MM-DD or YYYY-MM-DD HH:MM:SS): "
      read -r SINCE_INPUT 2>/dev/null || SINCE_INPUT=""
      printf "  To   [leave blank for now]: "
      read -r UNTIL_INPUT 2>/dev/null || UNTIL_INPUT=""
      echo ""
      # Convert to epochs now so validation runs
      if [[ -n "$SINCE_INPUT" ]]; then
        SINCE_EPOCH=$(_to_epoch "$SINCE_INPUT" "00:00:00")
        if [[ -z "$SINCE_EPOCH" ]]; then
          echo "  Warning: could not parse From date — using default window." >&2
          SINCE_INPUT=""
        fi
      fi
      if [[ -n "$UNTIL_INPUT" ]]; then
        UNTIL_EPOCH=$(_to_epoch "$UNTIL_INPUT" "23:59:59")
        if [[ -z "$UNTIL_EPOCH" ]]; then
          echo "  Warning: could not parse To date — ignoring." >&2
          UNTIL_INPUT=""
          UNTIL_EPOCH=""
        fi
      fi
      ;;
  esac

  # ── Run mode (only for a single interface) ───────────────────────────────────
  local run_mode="detect"
  if [[ "$selected_iface" != "all" ]]; then
    echo "  Run mode:"
    echo "    1) Diagnostic wizard — full report + recommended fixes"
    echo "    2) Flap detection only — count link transitions"
    echo ""
    local mode_choice
    printf "  Select [1]: "
    read -r mode_choice 2>/dev/null || mode_choice=""
    [[ -z "$mode_choice" ]] && mode_choice="1"
    echo ""
    [[ "$mode_choice" == "2" ]] && run_mode="detect" || run_mode="wizard"
  fi

  # ── Apply selections ─────────────────────────────────────────────────────────
  if [[ "$selected_iface" == "all" ]]; then
    IFACE_FILTER=""
    DIAG_IFACE=""
  elif [[ "$run_mode" == "wizard" ]]; then
    DIAG_IFACE="$selected_iface"
    IFACE_FILTER="$selected_iface"
  else
    IFACE_FILTER="$selected_iface"
    DIAG_IFACE=""
  fi

  # ── Build _INTERACTIVE_ARGS for re-run ───────────────────────────────────────
  _INTERACTIVE_ARGS=()
  if [[ "$run_mode" == "wizard" && -n "$DIAG_IFACE" ]]; then
    _INTERACTIVE_ARGS+=(-d "$DIAG_IFACE")
  elif [[ "$selected_iface" != "all" ]]; then
    _INTERACTIVE_ARGS+=(-i "$IFACE_FILTER")
  fi
  _INTERACTIVE_ARGS+=(-w "$WINDOW_MINUTES")
  [[ -n "$SINCE_INPUT" ]]  && _INTERACTIVE_ARGS+=(--since "$SINCE_INPUT")
  [[ -n "$UNTIL_INPUT" ]]  && _INTERACTIVE_ARGS+=(--until "$UNTIL_INPUT")

  echo -e "${divider}"
  echo ""
  _FLAP_INTERACTIVE_MODE=1
}

# _flap_what_next — post-run menu offering re-run, new run, or quit.
# No-op unless _FLAP_INTERACTIVE_MODE=1.
_flap_what_next() {
  [[ "$_FLAP_INTERACTIVE_MODE" -eq 0 ]] && return 0

  local divider="╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌"
  echo ""
  echo -e "${divider}"
  echo "  What next?"
  echo "    1) Re-run same test"
  echo "    2) Run a new test"
  echo "    3) Quit"
  echo ""
  printf "  Select [3]: "
  local choice=""
  read -r -t 10 choice 2>/dev/null || choice=""
  echo ""

  case "$choice" in
    1) exec bash "$0" "${_INTERACTIVE_ARGS[@]}" ;;
    2) exec bash "$0" ;;
    *) return 0 ;;
  esac
}
