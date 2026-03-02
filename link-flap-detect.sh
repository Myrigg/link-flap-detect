#!/usr/bin/env bash
# link-flap-detect.sh
# Detect network interface link flapping by parsing system logs.
# Supports: journald (primary), /var/log/syslog, /var/log/kern.log
# Covers:   kernel NIC drivers (virtio_net, e1000e, igb, tg3, ixgbe, bnxt, ...),
#           systemd-networkd, NetworkManager
# Platform: Ubuntu 24.04 (systemd), also works on 20.04 / 22.04
#
# Usage:
#   ./link-flap-detect.sh [OPTIONS]
#
# Options:
#   -w MINUTES    Time window to scan back from now (default: 60)
#   -t COUNT      Number of transitions to consider flapping (default: 3)
#   -i IFACE      Limit output to a specific interface (e.g. eth0, ens18)
#   -v            Verbose — show every individual up/down event
#   -h            Show this help
#
# Environment overrides (same as flags):
#   WINDOW_MINUTES, FLAP_THRESHOLD, IFACE_FILTER

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
WINDOW_MINUTES=${WINDOW_MINUTES:-60}
FLAP_THRESHOLD=${FLAP_THRESHOLD:-3}
IFACE_FILTER=${IFACE_FILTER:-""}
VERBOSE=0

# ── Colours (disabled when not a terminal) ────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
else
  RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; DIM=''; RESET=''
fi

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
  awk '/^[^#]/{exit} /^#!/{next} {sub(/^# ?/,""); print}' "$0"
  exit 0
}

# ── Argument parsing ──────────────────────────────────────────────────────────
while getopts ":w:t:i:vh" opt; do
  case $opt in
    w) WINDOW_MINUTES="$OPTARG" ;;
    t) FLAP_THRESHOLD="$OPTARG" ;;
    i) IFACE_FILTER="$OPTARG"   ;;
    v) VERBOSE=1                ;;
    h) usage                    ;;
    :) echo "Option -$OPTARG requires an argument." >&2; exit 1 ;;
    \?) echo "Unknown option: -$OPTARG" >&2; exit 1 ;;
  esac
done

# ── Validate numerics ─────────────────────────────────────────────────────────
if ! [[ "$WINDOW_MINUTES" =~ ^[0-9]+$ ]] || [[ "$WINDOW_MINUTES" -lt 1 ]]; then
  echo "Error: -w must be a positive integer (minutes)." >&2; exit 1
fi
if ! [[ "$FLAP_THRESHOLD" =~ ^[0-9]+$ ]] || [[ "$FLAP_THRESHOLD" -lt 2 ]]; then
  echo "Error: -t must be >= 2." >&2; exit 1
fi

# ── Temp file — cleaned up on exit ───────────────────────────────────────────
TMPFILE=$(mktemp /tmp/link-flap-XXXXXX)
trap 'rm -f "$TMPFILE"' EXIT

# ── Step 1: Collect raw log lines ─────────────────────────────────────────────
# Format we aim to emit into TMPFILE for each event:
#   <epoch_seconds> <iface> <UP|DOWN>
#
# We try journald first (Ubuntu 24.04 default). Fall back to flat log files.

SINCE_ARG="${WINDOW_MINUTES} minutes ago"

collect_from_journald() {
  # journalctl --output=short-iso gives lines like:
  #   2024-11-01T14:23:05+0000 hostname kernel: eth0: NIC Link is Down
  journalctl --no-pager --output=short-iso --since="$SINCE_ARG" 2>/dev/null
}

collect_from_syslog() {
  local logfile="$1"
  # syslog/kern.log lines: "Nov  1 14:23:05 hostname kernel: eth0: NIC Link is Down"
  # We only have current-year timestamps — good enough for flap detection
  if [[ -r "$logfile" ]]; then
    # Filter roughly by recency using the last N lines proportional to window
    local lines=$(( WINDOW_MINUTES * 200 ))   # ~200 log lines per minute — generous
    tail -n "$lines" "$logfile"
  fi
}

parse_events() {
  # Reads raw log lines from stdin, writes "epoch iface STATE" to stdout.
  # Implemented entirely in awk — no subshell spawning per line.
  # Timestamp conversion is handled by calling date(1) once per unique ts string
  # via a small shell wrapper piped back in; but for speed we pass the raw ts
  # through and convert in a post-processing step with a single date invocation.
  #
  # Actually: awk cannot call date(), so we emit "ts_raw iface STATE" lines and
  # convert timestamps in a second awk+date pass.  This keeps it to two fast
  # passes rather than N subshell spawns.

  awk -v iface_filter="$IFACE_FILTER" '
  {
    line = $0
    iface = ""
    state = ""

    # ── Timestamp: first field ──────────────────────────────────────────────
    ts_raw = $1

    # Reconstruct syslog-style "Mon DD HH:MM:SS" timestamps (fields 1-3)
    # ISO 8601 timestamps start with a digit
    if (ts_raw !~ /^[0-9]{4}/) {
      ts_raw = $1 " " $2 " " $3
    }

    # ── Pattern matching (case-insensitive via tolower) ─────────────────────
    lower = tolower(line)

    # Kernel: "<iface>: NIC Link is Up/Down"
    if (match(lower, /[a-z][a-z0-9_-]+: nic link is (up|down)/)) {
      seg = substr(lower, RSTART, RLENGTH)
      split(seg, a, ": nic link is ")
      iface = a[1]
      state = (a[2] ~ /^up/) ? "UP" : "DOWN"

    # Kernel: "<iface>: Link is Up/Down"  (avoid matching "NIC Link")
    } else if (match(lower, /[a-z][a-z0-9_-]+: link is (up|down)/) &&
               lower !~ /nic link/) {
      seg = substr(lower, RSTART, RLENGTH)
      split(seg, a, ": link is ")
      iface = a[1]
      state = (a[2] ~ /^up/) ? "UP" : "DOWN"

    # Kernel: "<iface>: carrier acquired/lost"
    } else if (match(lower, /[a-z][a-z0-9_-]+: carrier (acquired|lost)/)) {
      seg = substr(lower, RSTART, RLENGTH)
      split(seg, a, ": carrier ")
      iface = a[1]
      state = (a[2] ~ /^acq/) ? "UP" : "DOWN"

    # systemd-networkd: "<iface>: Gained/Lost carrier"
    } else if (match(lower, /[a-z][a-z0-9_-]+: (gained|lost) carrier/)) {
      seg = substr(lower, RSTART, RLENGTH)
      n = split(seg, a, ": ")
      iface = a[1]
      state = (a[2] ~ /^gained/) ? "UP" : "DOWN"

    # systemd-networkd: "<iface>: Link UP/DOWN"
    } else if (match(lower, /[a-z][a-z0-9_-]+: link (up|down)/) &&
               lower !~ /nic link/ && lower !~ /link is/) {
      seg = substr(lower, RSTART, RLENGTH)
      split(seg, a, ": link ")
      iface = a[1]
      state = (a[2] ~ /^up/) ? "UP" : "DOWN"

    # NetworkManager: "device (<iface>): link connected/disconnected"
    } else if (match(lower, /device \([a-z][a-z0-9_-]+\): link (connected|disconnected)/)) {
      seg = substr(lower, RSTART, RLENGTH)
      if (match(seg, /\([a-z][a-z0-9_-]+\)/)) {
        iface = substr(seg, RSTART+1, RLENGTH-2)
      }
      state = (seg ~ /link connected$/) ? "UP" : "DOWN"

    # NetworkManager: "device (<iface>): state change: ... -> <new_state>"
    } else if (lower ~ /device \([a-z][a-z0-9_-]+\): state change:/) {
      if (match(lower, /\([a-z][a-z0-9_-]+\)/)) {
        iface = substr(lower, RSTART+1, RLENGTH-2)
      }
      # Extract last "-> word"
      arrow = ""
      tmp = lower
      while (match(tmp, /-> [a-z]+/)) {
        arrow = substr(tmp, RSTART, RLENGTH)
        tmp = substr(tmp, RSTART + RLENGTH)
      }
      sub(/^-> /, "", arrow)
      if (arrow ~ /^(activated|connected)$/)                        state = "UP"
      else if (arrow ~ /^(unavailable|unmanaged|disconnected|deactivating|failed)$/) state = "DOWN"
    }

    if (iface == "" || state == "") next

    # Skip virtual / container interfaces unless a specific filter is set
    if (iface_filter == "") {
      if (iface ~ /^(lo|veth|virbr|docker|tun|tap)/ || iface ~ /^br-/) next
    } else {
      if (iface != iface_filter) next
    }

    print ts_raw "\t" iface "\t" state
  }
  ' | \
  # Second pass: convert ts_raw → epoch using date(1) once per unique timestamp
  awk -F'\t' '
  {
    ts  = $1
    iface = $2
    state = $3

    if (!(ts in epoch_cache)) {
      cmd = "date -d \047" ts "\047 +%s 2>/dev/null || echo 0"
      cmd | getline result
      close(cmd)
      epoch_cache[ts] = result
    }
    ep = epoch_cache[ts]
    if (ep != "0" && ep != "") print ep " " iface " " state
  }
  '
}

# ── Step 2: Populate TMPFILE ──────────────────────────────────────────────────
LOG_SOURCE="journald"

if [[ -n "${_LINK_FLAP_TEST_INPUT:-}" ]]; then
  # Test hook: bypass journald/syslog and read from a supplied file.
  # Set by the test suite only — not a documented end-user option.
  LOG_SOURCE="test-input"
  collect_from_syslog "$_LINK_FLAP_TEST_INPUT" | parse_events >> "$TMPFILE"
elif command -v journalctl &>/dev/null; then
  collect_from_journald | parse_events >> "$TMPFILE"
else
  LOG_SOURCE="syslog files"
  for f in /var/log/syslog /var/log/kern.log; do
    collect_from_syslog "$f" | parse_events >> "$TMPFILE"
  done
fi

# Remove duplicate lines (same epoch + iface + state from multiple sources)
sort -u "$TMPFILE" -o "$TMPFILE"

# ── Step 3: Analyse for flapping ─────────────────────────────────────────────
# For each interface: count state transitions, report if >= FLAP_THRESHOLD

FLAPPING_FOUND=0

# Get unique interfaces from TMPFILE
mapfile -t IFACES < <(awk '{print $2}' "$TMPFILE" | sort -u)

echo ""
echo -e "${BOLD}Link Flap Detector${RESET} — source: ${LOG_SOURCE}"
echo -e "Window: last ${WINDOW_MINUTES}m  |  Flap threshold: ${FLAP_THRESHOLD} transitions"
[[ -n "$IFACE_FILTER" ]] && echo -e "Interface filter: ${CYAN}${IFACE_FILTER}${RESET}"
echo ""

if [[ ${#IFACES[@]} -eq 0 ]]; then
  echo -e "${GREEN}No link state events found in the log window.${RESET}"
  echo ""
  exit 0
fi

for iface in "${IFACES[@]}"; do
  # Extract events for this interface, sorted by time
  mapfile -t EVENTS < <(grep -F -- " $iface " "$TMPFILE" | sort -n)

  count=${#EVENTS[@]}
  [[ "$count" -lt 2 ]] && continue   # Need at least 2 events to detect flapping

  # Count transitions (state changes between consecutive events)
  transitions=0
  prev_state=""
  declare -a event_lines=()

  for evt in "${EVENTS[@]}"; do
    epoch=$(echo "$evt" | awk '{print $1}')
    state=$(echo "$evt" | awk '{print $3}')
    ts_human=$(date -d "@$epoch" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "unknown")

    event_lines+=("  ${DIM}${ts_human}${RESET}  ${state}")

    if [[ -n "$prev_state" && "$state" != "$prev_state" ]]; then
      (( transitions++ )) || true
    fi
    prev_state="$state"
  done

  # First and last event timestamps
  first_epoch=$(echo "${EVENTS[0]}"  | awk '{print $1}')
  last_epoch=$(echo  "${EVENTS[-1]}" | awk '{print $1}')
  first_ts=$(date -d "@$first_epoch" "+%H:%M:%S" 2>/dev/null || echo "?")
  last_ts=$(date -d  "@$last_epoch"  "+%H:%M:%S" 2>/dev/null || echo "?")
  span=$(( last_epoch - first_epoch ))
  span_str="${span}s"
  [[ "$span" -ge 60 ]] && span_str="$(( span / 60 ))m $(( span % 60 ))s"

  if [[ "$transitions" -ge "$FLAP_THRESHOLD" ]]; then
    FLAPPING_FOUND=1
    echo -e "${RED}${BOLD}[FLAPPING]${RESET} ${BOLD}${iface}${RESET}"
    echo -e "  Transitions : ${RED}${transitions}${RESET}  |  Events: ${count}  |  Span: ${first_ts}–${last_ts} (${span_str})"
    if [[ "$VERBOSE" -eq 1 ]]; then
      for el in "${event_lines[@]}"; do
        echo -e "$el"
      done
    fi
    echo ""
  else
    if [[ "$VERBOSE" -eq 1 ]]; then
      echo -e "${YELLOW}[ACTIVE]${RESET}  ${BOLD}${iface}${RESET} — ${transitions} transition(s) in window (below threshold)"
      for el in "${event_lines[@]}"; do
        echo -e "$el"
      done
      echo ""
    fi
  fi
done

if [[ "$FLAPPING_FOUND" -eq 0 ]]; then
  echo -e "${GREEN}No flapping detected${RESET} in the last ${WINDOW_MINUTES} minutes (threshold: ${FLAP_THRESHOLD} transitions)."
  echo ""
fi

exit $(( FLAPPING_FOUND ))
