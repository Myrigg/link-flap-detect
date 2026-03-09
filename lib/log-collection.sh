#!/usr/bin/env bash
# lib/log-collection.sh — Log collection from journald/syslog/tshark and event parsing.
# Sourced by flap; do not execute directly.

collect_from_journald() {
  # journalctl --output=short-iso gives lines like:
  #   2024-11-01T14:23:05+0000 hostname kernel: eth0: NIC Link is Down
  local -a jctl_args=(--no-pager --output=short-iso)
  if [[ -n "$SINCE_EPOCH" ]]; then
    jctl_args+=("--since=$(date -d "@$SINCE_EPOCH" "+%Y-%m-%d %H:%M:%S")")
  else
    jctl_args+=("--since=$SINCE_ARG")
  fi
  [[ -n "$UNTIL_EPOCH" ]] && \
    jctl_args+=("--until=$(date -d "@$UNTIL_EPOCH" "+%Y-%m-%d %H:%M:%S")")
  journalctl "${jctl_args[@]}" 2>/dev/null
}

collect_from_syslog() {
  local logfile="$1"
  # syslog/kern.log lines: "Nov  1 14:23:05 hostname kernel: eth0: NIC Link is Down"
  # We only have current-year timestamps — good enough for flap detection
  if [[ -r "$logfile" ]]; then
    if [[ -n "$SINCE_EPOCH" ]]; then
      # Date range specified — read the whole file; the epoch filter handles trimming
      cat "$logfile"
    else
      # Heuristic: ~200 log lines per minute is generous for most systems.
      # On very busy servers this may miss old events; use --since/--until
      # or journald (the default) for precise time-bounded queries.
      local lines=$(( WINDOW_MINUTES * 200 ))
      tail -n "$lines" "$logfile"
    fi
  fi
}

collect_from_tshark() {
  local pcap="$1"
  if ! command -v tshark &>/dev/null; then
    echo "Error: tshark is not installed (required for -p)." >&2; exit 2
  fi

  # ── STP Topology Change Notifications ─────────────────────────────────────
  # Each TCN BPDU signals a spanning-tree port state change. Consecutive TCNs
  # from the same sender alternate DOWN/UP (first event = something went down,
  # second = recovery, etc.). We name the synthetic iface "stp-<last2octets>".
  timeout 30 tshark -r "$pcap" -q -Y "stp.flags.tc == 1" \
    -T fields -e frame.time_epoch -e eth.src \
    2>/dev/null \
  | awk -v iface_filter="$IFACE_FILTER" '
    NF < 2 { next }
    {
      epoch = int($1)
      mac   = $2
      n     = split(mac, m, ":")
      iface = "stp-" m[n-1] m[n]
      if (iface_filter != "" && iface != iface_filter) next
      state = (last_state[iface] == "DOWN") ? "UP" : "DOWN"
      last_state[iface] = state
      print epoch " " iface " " state
    }'

  # ── LACP synchronisation state changes ────────────────────────────────────
  # Bit 3 of actor_state is the Synchronisation flag (value 8). When it falls
  # to 0 the bond member is no longer in sync → DOWN; when it rises → UP.
  # Emit a record only when the state transitions, to avoid duplicates.
  timeout 30 tshark -r "$pcap" -q -Y "lacp" \
    -T fields -e frame.time_epoch -e eth.src -e lacp.actor_state \
    2>/dev/null \
  | awk -v iface_filter="$IFACE_FILTER" '
    NF < 3 { next }
    {
      epoch = int($1)
      mac   = $2
      n     = split(mac, m, ":")
      iface = "lacp-" m[n-1] m[n]
      if (iface_filter != "" && iface != iface_filter) next
      actor_state = int($3)
      state = (int(actor_state / 8) % 2 == 1) ? "UP" : "DOWN"
      if (state != last_state[iface]) {
        print epoch " " iface " " state
        last_state[iface] = state
      }
    }'
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
  BEGIN { now = systime() }
  {
    ts  = $1
    iface = $2
    state = $3

    if (!(ts in epoch_cache)) {
      ts_safe = ts
      gsub(/[^A-Za-z0-9 :+TZ-]/, "", ts_safe)
      cmd = "date -d \047" ts_safe "\047 +%s 2>/dev/null || echo 0"
      if ((cmd | getline result) <= 0) result = 0
      close(cmd)
      # Guard against syslog timestamps without a year (e.g. "Dec 31 14:00:00").
      # date(1) picks the current year, producing a future epoch when the log entry
      # is from December and the tool runs in January. Pull it back one year.
      # Use a 7-day grace window (not 1 day) so that DST transitions and NTP clock
      # slew of a few hours do not incorrectly trigger the year rollback.
      # Assumption: syslog entries are at most ~1 year old. Logs >2 years old may
      # silently misparse — this is an inherent syslog limitation (no year field).
      if ((result + 0) > (now + 604800))
        result = result - 31536000
      epoch_cache[ts] = result
    }
    ep = epoch_cache[ts]
    if (ep != "0" && ep != "") print ep " " iface " " state
  }
  '
}
