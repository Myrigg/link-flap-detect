# link-flap-detect

Detects network interface link flapping by parsing system logs and/or packet captures.

## Install

```bash
git clone https://github.com/Myrigg/link-flap-detect.git
cd link-flap-detect
```

No build step, no package manager. The script runs on any Ubuntu 20.04+ system out of the box.

**Or download just the script:**
```bash
curl -O https://raw.githubusercontent.com/Myrigg/link-flap-detect/main/flap
chmod +x flap
```

### Requirements

| Dependency | Used for | Notes |
|---|---|---|
| `bash` 4+ | Core | Pre-installed on Ubuntu |
| `journalctl` | Log scanning (default source) | Pre-installed on Ubuntu 20.04+ |
| `awk`, `sort`, `date`, `mktemp` | Core | Pre-installed (coreutils) |
| `curl` | Prometheus enrichment (`-m`) | `apt install curl` |
| `tshark` | PCAP analysis (`-p`) | `apt install tshark` — optional |
| `iperf3` | Active bandwidth probe (`-b`) | `apt install iperf3` — optional |

`curl`, `tshark`, and `iperf3` are only needed for their respective optional features. Everything else is already present on a standard Ubuntu install.

## What it detects

- Kernel NIC driver events (`NIC Link is Up/Down`, `carrier acquired/lost`) — virtio_net, e1000e, igb, tg3, ixgbe, bnxt, and others
- systemd-networkd carrier events (`Gained/Lost carrier`, `Link UP/DOWN`)
- NetworkManager state changes (`link connected/disconnected`, `state change: ... -> activated`)
- STP Topology Change Notifications from a packet capture (via tshark)
- LACP synchronisation state changes from a packet capture (via tshark)
- Correlated flapping across multiple interfaces — events on 2+ interfaces within the same 10-second window are flagged as `[CORRELATED]`, indicating a shared upstream cause (switch reboot, power event, broadcast storm)

## Usage

```
./flap [OPTIONS]
```

### Options

| Option | Description | Default |
|---|---|---|
| `-w MINUTES` | Time window to scan back from now | `60` |
| `-t COUNT` | Number of transitions to consider flapping | `3` |
| `-i IFACE` | Limit output to a specific interface | (all) |
| `-p PCAP_FILE` | Analyse a packet capture file with tshark | (none) |
| `-m URL` | Prometheus base URL for metric enrichment | (none) |
| `-n URL` | node_exporter metrics URL (auto-probed at `http://localhost:9100`; pass `off` to disable) | `http://localhost:9100` |
| `-b SERVER` | Run iperf3 to SERVER for 5s; show bandwidth and retransmits as enrichment | (none) |
| `-d IFACE` | Run diagnostic wizard for IFACE | (none) |
| `-r BACKUP_ID` | Restore config files from a saved backup | (none) |
| `-f SECONDS` | Follow mode: re-run every N seconds until Ctrl-C | (off) |
| `-v` | Verbose — show every individual up/down event | off |
| `-h` | Show help | |
| `--fleet` | Fleet mode: query Prometheus for flapping across all monitored hosts (requires `-m`) | off |

Options can also be set via environment variables: `WINDOW_MINUTES`, `FLAP_THRESHOLD`, `IFACE_FILTER`.
Command-line flags take precedence over environment variables when both are set.

## Examples

**Scan the last 60 minutes of system logs (default):**
```bash
./flap
```

**Scan the last 2 hours, flag after 5 transitions:**
```bash
./flap -w 120 -t 5
```

**Check a specific interface only:**
```bash
./flap -i eth0
```

**Verbose output — show every UP/DOWN event:**
```bash
./flap -v
```

**Analyse a packet capture for STP/LACP flap evidence:**
```bash
./flap -p /tmp/capture.pcap
```

**Capture live traffic then analyse it:**
```bash
tshark -w /tmp/capture.pcap -a duration:60 -i eth0
./flap -p /tmp/capture.pcap -v
```

**PCAP + interface filter (only report stp-aabb events):**
```bash
./flap -p /tmp/capture.pcap -i stp-aabb
```

**Check bandwidth while a link is flapping (iperf3 enrichment):**
```bash
./flap -b iperf3.example.com
```

**Wizard + iperf3 probe together:**
```bash
./flap -d eth0 -b iperf3.example.com
```

**Run the diagnostic wizard on eth0:**
```bash
# Find your interface name first:
ip link show

# Then run the wizard:
./flap -d eth0 -w 60
```

**Watch for flapping in real time (re-scan every 30 seconds):**
```bash
./flap -f 30
```

**Follow mode with interface filter (Ctrl-C to stop):**
```bash
./flap -f 10 -i eth0 -v
```

**List all saved config backups:**
```bash
./flap -r list
```

**Restore a backup:**
```bash
# Restoring files in /etc/ requires root:
sudo ./flap -r 20260302-143000-eth0
```

## Log sources

The script selects a source in this order:

1. **PCAP file** — used when `-p` is passed (requires `tshark`); takes priority over live log sources
2. **journald** — default when `journalctl` is available (Ubuntu 20.04+)
3. **Syslog files** — `/var/log/syslog` and `/var/log/kern.log` as a fallback when journald is absent

## Prometheus enrichment

Requires a running Prometheus server scraping [node_exporter](https://github.com/prometheus/node_exporter).
Pass the base URL with `-m`:

```bash
./flap -m http://localhost:9090
```

For each flapping interface the tool queries these metrics and displays them below
the `[FLAPPING]` line:

| Metric | Display |
|---|---|
| `node_network_up` | Current link state (UP / DOWN) |
| `node_network_carrier_changes_total` | Carrier changes over the scan window |
| `node_network_receive_errs_total` | RX errors/min (5-minute rate) |
| `node_network_transmit_errs_total` | TX errors/min (5-minute rate) |
| `node_network_receive_drop_total` | RX drops/min (5-minute rate) |
| `node_network_transmit_drop_total` | TX drops/min (5-minute rate) |

In verbose mode (`-v`), enrichment is also shown for interfaces that are below the
flapping threshold but have state change events.

Synthetic tshark interfaces (`stp-*`, `lacp-*`) are not looked up in Prometheus —
node_exporter has no matching device for them.

If Prometheus is unreachable or has no data for an interface the section is silently
omitted; the tool still runs and reports from its log/pcap sources.

**Example output:**
```
[FLAPPING] eth0
  Transitions : 4  |  Events: 5  |  Span: 10:00:00–10:10:00 (10m 0s)
  [Prometheus]
    Current state   : UP
    Carrier changes : 12 in last 60m
    RX errors       : 0.30/min
    TX errors       : 0.00/min
    RX drops        : 2.10/min
    TX drops        : 0.00/min
```

## node_exporter enrichment

When `node_exporter` is running on the machine (typically at `http://localhost:9100`), the tool
automatically probes it and shows live interface counters alongside flap detection output — no
configuration needed.

To override the URL or disable probing:

```bash
# Use a non-default port
./flap -n http://localhost:9200

# Disable node_exporter probing entirely
./flap -n off
```

Metrics shown (raw totals since boot, from the Prometheus text format):

| Metric | Display |
|---|---|
| `node_network_up` | Current link state (UP / DOWN) |
| `node_network_carrier_changes_total` | Carrier changes since boot |
| `node_network_receive_errs_total` | RX errors total |
| `node_network_transmit_errs_total` | TX errors total |
| `node_network_receive_drop_total` | RX drops total |
| `node_network_transmit_drop_total` | TX drops total |

The `[node_exporter]` block appears below `[FLAPPING]` lines (and below `[ACTIVE]` lines in verbose
mode). Synthetic tshark interfaces (`stp-*`, `lacp-*`) are skipped — node_exporter has no matching
device for them.

The diagnostic wizard (`-d IFACE`) also reads node_exporter metrics: they appear in the Interface
State section of the report, and RX/TX error totals above zero are flagged as `[WARN]` findings.

If node_exporter is unreachable the tool runs normally and the enrichment block is silently omitted.

**Example output:**
```
[FLAPPING] eth0
  Transitions : 4  |  Events: 5  |  Span: 10:00:00–10:10:00 (10m 0s)
  [node_exporter]
    Current state   : UP
    Carrier changes : 12 total since boot
    RX errors       : 0 total
    TX errors       : 0 total
    RX drops        : 3 total
    TX drops        : 0 total
```

## iperf3 enrichment

When a link is flapping the key question is "is it degraded when it IS up?" — iperf3 answers this
with real bandwidth and TCP retransmit data from an active 5-second TCP test.

**Prerequisite:** `apt install iperf3`

Pass the target server hostname or IP with `-b`:

```bash
./flap -b iperf3.example.com
```

For each flapping interface the tool runs the probe once (result cached) and shows a `[iperf3]`
block below the `[FLAPPING]` line:

- **Bandwidth** — measured throughput in Mbps
- **Retransmits** — TCP retransmit count; highlighted yellow if > 0

In verbose mode (`-v`), the block also appears for `[ACTIVE]` interfaces below threshold.

The diagnostic wizard (`-d IFACE`) includes iperf3 results in the report and flags retransmits > 0
as a `[WARN]` finding with a recommendation to test longer and check switch port buffers.

Synthetic tshark interfaces (`stp-*`, `lacp-*`) are skipped — they have no corresponding
network path to test.

If iperf3 is not installed and `-b` is passed the tool exits immediately with an error message.
If the server is unreachable or the test fails the section is silently omitted.

**Example output:**
```
[FLAPPING] eth0
  Transitions : 4  |  Events: 5  |  Span: 10:00:00–10:10:00 (10m 0s)
  [iperf3]  → iperf3.example.com
    Bandwidth     : 943.0 Mbps
    Retransmits   : 0
```

## System load correlation

When a flapping interface is detected and `-m URL` is configured, the tool queries Prometheus
for system resource metrics **at the exact moment flapping began** — not current values, but
historical data from when the event occurred. This answers the question: *"Was the system
overloaded when this link dropped?"*

Requires Prometheus scraping `node_exporter` on the monitored machine. Three metrics are
queried at `first_epoch` (the timestamp of the first flap event):

| Metric | PromQL | Threshold |
|---|---|---|
| CPU idle % | `avg(rate(node_cpu_seconds_total{mode="idle"}[5m]))*100` | Red if < 15%, yellow if < 30% |
| Memory available % | `node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes * 100` | Yellow if < 10% |
| Load average (1m) | `node_load1` | Shown for reference |

The `[system @ HH:MM:SS]` block appears below each `[FLAPPING]` line:

```
[FLAPPING] eth0
  Transitions : 6  |  Events: 7  |  Span: 02:47:12–02:52:48 (5m 36s)
  [Prometheus]
    Current state   : UP
    Carrier changes : 6 in last 60m
  [system @ 02:47:12]
    CPU idle        : 4.2%
    Memory available: 87.3%
    Load avg (1m)   : 0.42
```

The **diagnostic wizard** (`-d IFACE`) also checks these metrics and raises findings:

- `[CAUSE]` if CPU idle was < 15% at flap time — system was CPU-saturated
- `[WARN]` if CPU idle was 15–30% — elevated load may have delayed NIC interrupt processing
- `[WARN]` if memory available was < 10% — memory pressure can cause driver buffer exhaustion

If Prometheus is unreachable or has no data for these metrics the block is silently omitted.

## Fleet mode (`--fleet`)

Fleet mode uses Prometheus as the primary data source to detect link flapping across an entire
fleet of monitored hosts — all in a single command.

**Requirements:**
- A running Prometheus server scraping [node_exporter](https://github.com/prometheus/node_exporter) on each host
- `curl` installed locally
- Pass the Prometheus base URL with `-m`

```bash
./flap -m http://prom-server:9090 --fleet
```

For each `node_exporter` instance that Prometheus scrapes, the tool queries carrier-change
metrics across the scan window. Any device with carrier changes ≥ the flap threshold is
reported as `[FLAPPING]`, with the host:device pair, carrier count, current link state, and
RX/TX error rates.

After the flap report, a `[UNREACHABLE TARGETS]` section lists any scrape targets currently
down — hosts that Prometheus can no longer reach.

**Combine with other flags:**

```bash
# Only report on a specific device name across all hosts
./flap -m http://prom-server:9090 --fleet -i eth0

# Longer window — useful for overnight flapping
./flap -m http://prom-server:9090 --fleet -w 480

# Follow mode — re-poll the fleet every 60 seconds (Ctrl-C to stop)
./flap -m http://prom-server:9090 --fleet -f 60
```

Virtual interfaces (`lo`, `veth*`, `docker*`, etc.) are filtered from fleet results by default,
just as they are in local scan mode.

**Example output:**

```
Link Flap Detector — fleet mode
Prometheus: http://prom-server:9090
Window: last 60m  |  Flap threshold: 3 transitions

[FLAPPING]  server1:9100:eth0
  Carrier changes : 8 in last 60m
  Current state   : DOWN
  RX errors       : 1.20/min
  TX errors       : 0.00/min

[FLAPPING]  server2:9100:ens3
  Carrier changes : 5 in last 60m
  Current state   : UP
  RX errors       : 0.00/min
  TX errors       : 0.00/min

[UNREACHABLE TARGETS]
  server3:9100  last scrape: 2026-03-03T10:00:00Z  —  context deadline exceeded
```

## tshark / PCAP mode

Requires `tshark` (`apt install tshark`). Analyses two protocol layers:

- **STP TCN BPDUs** — each Topology Change Notification indicates a spanning-tree port state change. Consecutive TCNs from the same sender are alternated DOWN/UP. The synthetic interface name is `stp-<penultimate-octet><last-octet>` of the source MAC (e.g. `stp-aabb`).
- **LACP actor state** — monitors the Synchronisation bit (bit 3, value 8) of the actor state field. A transition from set → clear is reported as DOWN; clear → set as UP. The synthetic interface name is `lacp-<penultimate-octet><last-octet>` (e.g. `lacp-ccdd`).

## Diagnostic Wizard (`-d IFACE`)

Runs a fully automatic, read-only analysis of a specific interface and produces a
structured report of likely flap causes and recommended fixes:

```bash
# Find your interface name:
ip link show

# Run the wizard (no root needed — it only reads, never writes to /etc/):
./flap -d eth0
```

The wizard also runs **automatically** whenever flapping is detected — you do not need to
pass `-d` explicitly. After reporting `[FLAPPING]` on any interface, the tool immediately
runs the wizard on each affected interface in the same invocation.

The wizard:
1. **Snapshots network config files** before you act (netplan, NetworkManager, sysctl, etc.)
2. **Collects interface state** — operstate, carrier changes, speed/duplex, autoneg
3. **Checks for known causes** — EEE, runtime power management, CRC errors, duplex mismatch, no link, kernel errors
4. **Interprets counters with severity tiers** — raw numbers are annotated and thresholded
5. **Synthesises multi-indicator findings** — when several symptoms align, names the fault class directly
6. **Analyses flap patterns** in the log window (regular intervals may indicate STP/LACP/power timers)
7. **Prints colour-coded findings** (`[CAUSE]` / `[WARN]` / `[INFO]`) with `[FIX]` commands
8. **Saves a text report** to `~/.local/share/link-flap/reports/`

### Wizard findings reference

| Condition | Level | Finding |
|---|---|---|
| `carrier_changes` > 500 | `[CAUSE]` | Severe carrier instability |
| `carrier_changes` > 20 | `[WARN]` | High carrier changes since boot |
| Speed = `Unknown!` | `[CAUSE]` | Link speed unreadable — auto-negotiation failure |
| TX drops > 5000 | `[CAUSE]` | Severe TX drop count |
| TX drops > 100 | `[WARN]` | Elevated TX drop count |
| RX drops > 5000 | `[CAUSE]` | Severe RX drop count |
| RX drops > 100 | `[WARN]` | Elevated RX drop count |
| ≥ 2 of: Unknown speed + carrier > 500 + TX drops > 1000 | `[CAUSE]` | Physical layer failure signature |
| EEE enabled | `[CAUSE]` | Energy-Efficient Ethernet enabled |
| `power/control` = auto | `[CAUSE]` | NIC power management enabled |
| RX CRC errors > 0 | `[CAUSE]` | RX CRC errors detected |
| No physical link | `[CAUSE]` | No physical link detected |
| Hardware error in dmesg | `[CAUSE]` | Hardware error in kernel log |
| CPU idle < 15% at flap time (`-m`) | `[CAUSE]` | CPU saturation at flap time |
| Half-duplex | `[WARN]` | Half-duplex detected |
| NIC reset/reinit in dmesg | `[WARN]` | NIC reset/reinit events |
| RX/TX errors > 0 | `[WARN]` | RX/TX errors (node_exporter) |
| Memory < 10% at flap time (`-m`) | `[WARN]` | Low memory at flap time |

The Interface State section also annotates raw values with context hints:

```
Interface State
  operstate      : unknown
  carrier_changes: 53792  [SEVERE — each change = 1 link drop+restore]
  speed          : Unknown!  [unreadable — autoneg failed or link down]
  duplex         : Unknown  [unreadable — same cause as unknown speed]
  autoneg        : unknown
  power/control  : unknown
```

Override save locations via environment variables: `BACKUP_DIR`, `REPORT_DIR`.

After applying a `[FIX]` command, re-run `./flap -i IFACE -w 10` to confirm the interface has stabilised.

## Backup & Rollback (`-r BACKUP_ID`)

Every wizard run automatically backs up the system network config files
(netplan, interfaces, NetworkManager connections, sysctl) before you apply any fix.
Backups are stored in `~/.local/share/link-flap/backups/` (override via `BACKUP_DIR`).

**List saved backups:**
```bash
./flap -r list
```

**Restore a backup:**
```bash
# Files in /etc/ require root to overwrite:
sudo ./flap -r 20260302-143000-eth0
```

If restoration fails due to permissions the tool exits with code 2, prints a warning
for each failed file, and shows the exact `sudo` command to retry.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | No flapping detected (or wizard / rollback completed successfully) |
| `1` | One or more interfaces are flapping; or rollback backup not found |
| `2` | Rollback partially failed — some files could not be written (re-run with `sudo`) |

## Virtual interface filtering

By default, virtual and container interfaces are silently ignored:
`lo`, `veth*`, `virbr*`, `docker*`, `tun*`, `tap*`, `br-*`

Use `-i IFACE` to override and target a specific interface (including virtual ones).

## Running the test suite

```bash
bash tests/run-tests.sh
```

No root access or external dependencies required. The test suite injects synthetic log data
and mocked tshark/Prometheus/node_exporter/iperf3 output — none of those tools need to be
installed for the offline tests to pass.

When the test suite runs, `flap` prints a `WARNING: SYNTHETIC TEST DATA` banner so it is
immediately obvious the results reflect injected data, not your real system.

Individual feature suites can also be run in isolation:

```bash
bash tests/test-detection.sh      # log parsing, thresholds, flag validation
bash tests/test-tshark.sh         # STP / LACP packet-capture analysis
bash tests/test-prometheus.sh     # Prometheus metric enrichment
bash tests/test-wizard.sh         # diagnostic wizard and backup / rollback
bash tests/test-node-exporter.sh  # node_exporter metric enrichment
bash tests/test-iperf3.sh         # iperf3 bandwidth enrichment
bash tests/test-correlation.sh    # cross-interface correlation
bash tests/test-live-system.sh    # live journald / syslog / sysfs reads
bash tests/test-fleet.sh              # --fleet Prometheus fleet scan
bash tests/test-sysload.sh            # historical system load correlation
bash tests/test-wizard-enrichment.sh  # wizard severity tiers and synthesis
```
