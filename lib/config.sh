#!/usr/bin/env bash
# lib/config.sh — Persistent config file helpers.
# Sourced by flap; do not execute directly.

# _validate_url URL — return 0 if URL looks like a valid http(s) URL.
_validate_url() {
  [[ "$1" =~ ^https?://[a-zA-Z0-9] ]] || return 1
  if [[ "$1" =~ ^https?://(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|127\.|localhost) ]]; then
    echo "Note: URL targets a private/loopback address: $1" >&2
  fi
}

# _config_get KEY — print the stored value for KEY, or empty string.
_config_get() {
  [[ ! -f "$_CONFIG_FILE" ]] && return 0
  grep -m1 "^${1}=" "$_CONFIG_FILE" 2>/dev/null | cut -d= -f2- || true
}

# _save_config KEY VALUE — upsert a key in the config file atomically.
_save_config() {
  local key="$1" value="$2"
  # Never persist config during test runs
  [[ -n "${_LINK_FLAP_TEST_INPUT:-}${_LINK_FLAP_TEST_TSHARK:-}${_LINK_FLAP_TEST_PROM:-}${_LINK_FLAP_TEST_NODE_EXPORTER:-}${_LINK_FLAP_TEST_IPERF3:-}${_LINK_FLAP_TEST_WIZARD_DIR:-}${_LINK_FLAP_TEST_PROM_ALL:-}" ]] && return 0
  [[ -z "$value" ]] && return 0
  # Validate URL-type keys
  case "$key" in
    PROM_URL|WEBHOOK_URL|NODE_EXPORTER_URL)
      if ! _validate_url "$value"; then
        echo "Warning: not saving ${key} — invalid URL '${value}'." >&2
        return 0
      fi ;;
  esac
  mkdir -p "$_CONFIG_DIR"
  local tmpf; tmpf=$(mktemp)
  [[ -f "$_CONFIG_FILE" ]] && grep -v "^${key}=" "$_CONFIG_FILE" > "$tmpf" 2>/dev/null || true
  printf '%s=%s\n' "$key" "$value" >> "$tmpf"
  sync "$tmpf" 2>/dev/null || true
  mv "$tmpf" "$_CONFIG_FILE"
}

# _load_config — populate PROM_URL / IPERF3_SERVER from config (flags always win).
_load_config() {
  [[ "$_PROM_URL_FROM_FLAG"      -eq 0 && -z "$PROM_URL"      ]] && \
    PROM_URL=$(_config_get "PROM_URL")
  [[ "$_IPERF3_SERVER_FROM_FLAG" -eq 0 && -z "$IPERF3_SERVER" ]] && \
    IPERF3_SERVER=$(_config_get "IPERF3_SERVER")
  [[ "$_WEBHOOK_URL_FROM_FLAG"  -eq 0 && -z "$WEBHOOK_URL"   ]] && \
    WEBHOOK_URL=$(_config_get "WEBHOOK_URL")
  [[ "${_WINDOW_MINUTES_FROM_FLAG:-0}" -eq 0 && "$WINDOW_MINUTES" -eq 60 ]] && {
    local _cfg_wm; _cfg_wm=$(_config_get "WINDOW_MINUTES")
    [[ -n "$_cfg_wm" ]] && WINDOW_MINUTES="$_cfg_wm"
  }
  [[ "${_FLAP_THRESHOLD_FROM_FLAG:-0}" -eq 0 && "$FLAP_THRESHOLD" -eq 3 ]] && {
    local _cfg_ft; _cfg_ft=$(_config_get "FLAP_THRESHOLD")
    [[ -n "$_cfg_ft" ]] && FLAP_THRESHOLD="$_cfg_ft"
  }
  [[ "${_NODE_EXPORTER_URL_FROM_FLAG:-0}" -eq 0 && "$NODE_EXPORTER_URL" == "http://localhost:9100" ]] && {
    local _cfg_ne; _cfg_ne=$(_config_get "NODE_EXPORTER_URL")
    [[ -n "$_cfg_ne" ]] && NODE_EXPORTER_URL="$_cfg_ne"
  }
  return 0  # prevent set -e exit when last && condition is false
}

# _prompt_prom_url — ask for Prometheus URL when missing (TTY only).
_prompt_prom_url() {
  [[ -t 1 ]] || return 0
  [[ -n "${_LINK_FLAP_TEST_PROM:-}${_LINK_FLAP_TEST_PROM_ALL:-}" ]] && return 0
  [[ -n "$PROM_URL" ]] && return 0
  printf "Prometheus URL for enrichment (e.g. http://localhost:9090, Enter to skip): "
  local reply=""; read -r reply 2>/dev/null || true; echo ""
  [[ -z "$reply" ]] && return 0
  PROM_URL="$reply"
  _save_config "PROM_URL" "$PROM_URL"
}
