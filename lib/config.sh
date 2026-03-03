#!/usr/bin/env bash
# lib/config.sh — Persistent config file helpers.
# Sourced by flap; do not execute directly.

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
  mkdir -p "$_CONFIG_DIR"
  local tmpf; tmpf=$(mktemp)
  [[ -f "$_CONFIG_FILE" ]] && grep -v "^${key}=" "$_CONFIG_FILE" > "$tmpf" 2>/dev/null || true
  printf '%s=%s\n' "$key" "$value" >> "$tmpf"
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
