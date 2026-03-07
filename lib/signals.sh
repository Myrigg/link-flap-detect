#!/usr/bin/env bash
# lib/signals.sh — Graceful shutdown with ordered cleanup hooks.
# Sourced by flap; do not execute directly.
#
# Replaces the minimal _graceful_shutdown in flap with hook-based cleanup
# that runs registered handlers in order on SIGINT, SIGTERM, EXIT, or SIGHUP.
#
# Usage from other modules:
#   _shutdown_register "description" callback_function
#   # callback_function is called with no arguments during shutdown.

declare -a _SHUTDOWN_HOOKS=()       # function names, executed in registration order
declare -a _SHUTDOWN_LABELS=()      # human-readable labels for debugging
_SHUTTING_DOWN=0

_shutdown_register() {
  # Register a cleanup function to run during shutdown.
  # Args: label callback_fn
  local label="$1" fn="$2"
  _SHUTDOWN_HOOKS+=("$fn")
  _SHUTDOWN_LABELS+=("$label")
}

_graceful_shutdown() {
  # Idempotent: multiple signals only run cleanup once.
  [[ "$_SHUTTING_DOWN" -eq 1 ]] && return 0
  _SHUTTING_DOWN=1

  # Run all registered hooks in order
  local i
  for i in "${!_SHUTDOWN_HOOKS[@]}"; do
    # Best-effort: don't let one failed hook block the rest
    "${_SHUTDOWN_HOOKS[$i]}" 2>/dev/null || true
  done

  # Always clean up temp file last
  rm -f "${TMPFILE:-}" 2>/dev/null || true
}

trap '_graceful_shutdown' EXIT INT TERM HUP
