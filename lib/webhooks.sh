#!/usr/bin/env bash
# lib/webhooks.sh — Webhook alert delivery (Slack, Discord, generic).
# Sourced by flap; do not execute directly.

# _send_webhook — POST a JSON alert to a Slack, Discord, or generic webhook.
# Args: url event(flapping|cleared) iface [transitions]
_send_webhook() {
  local url="$1" event="$2" iface="$3" transitions="${4:-}"
  local message payload

  if [[ "$event" == "flapping" ]]; then
    message="[FLAPPING] ${iface} — ${transitions} transitions detected"
  else
    message="[CLEARED] ${iface} — link has stabilised"
  fi

  # Test hook: write to log file instead of calling curl
  if [[ -n "${_LINK_FLAP_TEST_WEBHOOK_LOG:-}" ]]; then
    echo "${event}:${iface}:${transitions:-}" >> "$_LINK_FLAP_TEST_WEBHOOK_LOG"
    return 0
  fi

  if [[ "$url" == *"discord.com"* ]]; then
    payload="{\"content\":\"${message}\",\"username\":\"link-flap-detect\"}"
  else
    payload="{\"text\":\"${message}\"}"
  fi

  curl -sf -X POST -H "Content-Type: application/json" \
    -d "$payload" --max-time 5 "$url" >/dev/null 2>&1 || true
}
