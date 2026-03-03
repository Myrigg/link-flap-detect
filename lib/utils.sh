#!/usr/bin/env bash
# lib/utils.sh — Usage, self-update, date helpers, interface listing.
# Sourced by flap; do not execute directly.

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
  awk '/^[^#]/{exit} /^#!/{next} {sub(/^# ?/,""); print}' "$0"
  exit 0
}

# ── Self-update ────────────────────────────────────────────────────────────────
_GITHUB_RAW="https://raw.githubusercontent.com/Myrigg/link-flap-detect/main"

# _do_update: update the script in-place.
# Git clone installs: git pull from the repo root.
# Standalone script installs: re-download the script over itself via curl.
_do_update() {
  local script_path script_dir
  script_path="$(readlink -f "$0")"
  script_dir="$(dirname "$script_path")"

  echo -e "${BOLD}Updating flap...${RESET}"

  if git -C "$script_dir" rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
    git -C "$script_dir" pull
  else
    if ! command -v curl &>/dev/null; then
      echo "Error: curl is required to update the standalone script." >&2; exit 1
    fi
    local tmp
    tmp=$(mktemp)
    if curl --max-time 30 -sf "${_GITHUB_RAW}/flap" -o "$tmp"; then
      cp "$tmp" "$script_path"
      chmod +x "$script_path"
      rm -f "$tmp"
      echo -e "${GREEN}Updated successfully.${RESET}"
    else
      rm -f "$tmp"
      echo "Update failed — check your internet connection." >&2; exit 1
    fi
  fi
  exit 0
}

# _check_for_update: fetch the remote VERSION file and prompt if newer.
# Skipped automatically in: non-terminal output, follow-mode children, rollback mode.
_check_for_update() {
  [[ ! -t 1 ]] && return 0                        # not interactive
  [[ -n "${_FLAP_FOLLOW_CHILD:-}" ]] && return 0  # follow mode re-exec
  [[ -n "${ROLLBACK_ID:-}" ]] && return 0          # rollback / list mode
  command -v curl &>/dev/null || return 0          # curl unavailable

  local remote_version
  remote_version=$(curl --max-time 3 -sf "${_GITHUB_RAW}/VERSION" 2>/dev/null || true)
  [[ -z "$remote_version" ]] && return 0  # network unavailable or slow

  # YYYY.MM.DD strings compare correctly with standard lexicographic order
  [[ "$remote_version" > "$VERSION" ]] || return 0

  echo -e "${YELLOW}${BOLD}Update available:${RESET} ${remote_version}  (installed: ${VERSION})"
  printf "  Update now? [y/N] "
  local reply=""
  read -r -t 15 reply 2>/dev/null || true
  echo ""
  if [[ "${reply,,}" == "y" ]]; then
    _do_update
  fi
}

# ── Date helpers ──────────────────────────────────────────────────────────────
# Convert a date/datetime string to a Unix epoch.
# Accepts "YYYY-MM-DD HH:MM:SS" or bare "YYYY-MM-DD".
# For bare dates, default_time is appended ("00:00:00" for --since, "23:59:59" for --until).
# Returns empty string on parse failure.
_to_epoch() {
  local input="$1" default_time="${2:-00:00:00}"
  [[ "$input" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && input="${input} ${default_time}"
  date -d "$input" +%s 2>/dev/null || echo ""
}

# _list_interfaces — populate global _IFACE_LIST and print a numbered menu.
_list_interfaces() {
  _IFACE_LIST=()
  local idx=1
  for d in /sys/class/net/*/; do
    local name; name=$(basename "$d")
    [[ "$name" == "lo" ]] && continue
    local state; state=$(cat "$d/operstate" 2>/dev/null || echo "unknown")
    printf "    %d) %-12s %s\n" "$idx" "$name" "${state^^}"
    _IFACE_LIST+=("$name")
    (( idx++ )) || true
  done
}
