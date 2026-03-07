#!/usr/bin/env bash
# lib/retry.sh — Retry with exponential backoff and jitter.
# Sourced by flap; do not execute directly.
#
# Usage:
#   _retry_backoff [OPTIONS] -- COMMAND [ARGS...]
#
# Options:
#   -n MAX_RETRIES   Number of retries after first failure (default: 3)
#   -d BASE_DELAY    Base delay in seconds (default: 1)
#   -f FACTOR        Exponential factor (default: 2)
#   -m MAX_DELAY     Maximum delay cap in seconds (default: 30)
#   -j               Disable jitter (enabled by default, ±30%)
#
# Returns the exit code of the last attempt.

_retry_backoff() {
  local max_retries=3 base_delay=1 factor=2 max_delay=30 jitter=1
  local OPTIND opt
  while getopts "n:d:f:m:j" opt; do
    case "$opt" in
      n) max_retries="$OPTARG" ;;
      d) base_delay="$OPTARG" ;;
      f) factor="$OPTARG" ;;
      m) max_delay="$OPTARG" ;;
      j) jitter=0 ;;
      *) ;;
    esac
  done
  shift $((OPTIND - 1))
  # Skip the -- separator if present
  [[ "${1:-}" == "--" ]] && shift

  local attempt=0 rc=0
  while true; do
    "$@" && return 0
    rc=$?
    (( attempt++ ))
    if [[ "$attempt" -gt "$max_retries" ]]; then
      return "$rc"
    fi

    # delay = base_delay × factor^attempt, capped at max_delay
    local delay
    delay=$(awk -v b="$base_delay" -v f="$factor" -v a="$attempt" -v m="$max_delay" \
      'BEGIN { d = b * (f ^ a); if (d > m) d = m; printf "%.1f", d }')

    # Add ±30% jitter to prevent thundering herd
    if [[ "$jitter" -eq 1 ]]; then
      delay=$(awk -v d="$delay" 'BEGIN {
        srand()
        jitter = 0.7 + (rand() * 0.6)
        printf "%.1f", d * jitter
      }')
    fi

    # Skip sleep for zero/near-zero delays (test mode)
    if awk -v d="$delay" 'BEGIN { exit !(d+0 > 0.05) }'; then
      sleep "$delay"
    fi
  done
}
