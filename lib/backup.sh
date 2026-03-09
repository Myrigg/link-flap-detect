#!/usr/bin/env bash
# lib/backup.sh — Config backup creation, listing, and rollback.
# Sourced by flap; do not execute directly.

_BACKUP_SOURCES=(
  /etc/netplan
  /etc/network/interfaces
  /etc/network/interfaces.d
  /etc/NetworkManager/system-connections
  /etc/sysctl.conf
  /etc/sysctl.d
)

create_backup() {
  local iface="$1"
  local ts; ts=$(date "+%Y%m%d-%H%M%S")
  local backup_id="${ts}-${iface:0:50}"
  local dest="${BACKUP_DIR}/${backup_id}"
  mkdir -p "$dest"
  local manifest=()
  for src in "${_BACKUP_SOURCES[@]}"; do
    [[ -e "$src" ]] || continue
    cp -a "$src" "$dest/" 2>/dev/null && manifest+=("$(basename "$src")")
  done
  printf '%s\n' "iface=$iface" "ts=$ts" "files=${manifest[*]}" > "${dest}/.manifest"
  if [[ ${#manifest[@]} -eq 0 ]]; then
    echo "Warning: no config files found to back up (re-run as root to include /etc/ files)." >&2
  fi
  echo "$backup_id"
}

list_backups() {
  if [[ ! -d "$BACKUP_DIR" ]]; then echo "  No backups found."; return; fi
  local count=0
  for d in "${BACKUP_DIR}"/*/; do
    [[ -d "$d" ]] || continue
    local id; id=$(basename "$d")
    local iface; iface=$(grep "^iface=" "${d}/.manifest" 2>/dev/null | cut -d= -f2 || true)
    printf "  %-30s  iface: %s\n" "$id" "$iface"
    (( count++ )) || true
  done
  [[ $count -eq 0 ]] && echo "  No backups found." || true
}

do_rollback() {
  local backup_id="$1"
  if [[ "$backup_id" == "list" ]]; then
    echo -e "\n${BOLD}Available backups:${RESET}"; list_backups; return
  fi
  local src="${BACKUP_DIR}/${backup_id}"
  if [[ ! -d "$src" ]]; then
    echo "Error: backup '$backup_id' not found in ${BACKUP_DIR}." >&2; exit 1
  fi
  echo -e "${BOLD}Rolling back to:${RESET} ${backup_id}"
  declare -A dest_map=(
    [netplan]=/etc/netplan
    [interfaces]=/etc/network/interfaces
    [interfaces.d]=/etc/network/interfaces.d
    [system-connections]=/etc/NetworkManager/system-connections
    [sysctl.conf]=/etc/sysctl.conf
    [sysctl.d]=/etc/sysctl.d
  )
  local restored=0 failed=0
  for item in "$src"/*/  "$src"/*; do
    [[ -e "$item" ]] || continue
    local name; name=$(basename "$item")
    [[ -v "dest_map[$name]" ]] || continue
    local dst="${dest_map[$name]}"
    if cp -a "$item" "$(dirname "$dst")/" 2>/dev/null; then
      echo "  Restored: $name → $dst"
      (( restored++ )) || true
    else
      echo "  ${YELLOW}Warning: could not restore $name (check permissions or available space)${RESET}" >&2
      (( failed++ )) || true
    fi
  done
  if [[ $failed -gt 0 ]]; then
    echo -e "  ${YELLOW}Partial restore: ${restored} item(s) restored, ${failed} could not be written — re-run with sudo:${RESET}" >&2
    echo -e "  sudo ./flap -r ${backup_id}" >&2
    exit 2
  fi
  echo -e "  ${GREEN}Done. ${restored} item(s) restored.${RESET}"
  echo -e "  ${DIM}(File permissions are preserved from backup time.)${RESET}"
}
