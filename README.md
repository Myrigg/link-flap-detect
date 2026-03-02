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
curl -O https://raw.githubusercontent.com/Myrigg/link-flap-detect/main/link-flap-detect.sh
chmod +x link-flap-detect.sh
```

### Requirements

| Dependency | Used for | Notes |
|---|---|---|
| `bash` 4+ | Core | Pre-installed on Ubuntu |
| `journalctl` | Log scanning (default source) | Pre-installed on Ubuntu 20.04+ |
| `awk`, `sort`, `date`, `mktemp` | Core | Pre-installed (coreutils) |
| `curl` | Prometheus enrichment (`-m`) | `apt install curl` |
| `tshark` | PCAP analysis (`-p`) | `apt install tshark` — optional |
| `iperf3` | Active bandwidth probe (`-3`) | `apt install iperf3` — optional |

`curl`, `tshark`, and `iperf3` are only needed for their respective optional features. Everything else is already present on a standard Ubuntu install.

## What it detects

- Kernel NIC driver events (`NIC Link is Up/Down`, `carrier acquired/lost`) — virtio_net, e1000e, igb, tg3, ixgbe, bnxt, and others
- systemd-networkd carrier events (`Gained/Lost carrier`, `Link UP/DOWN`)
- NetworkManager state changes (`link connected/disconnected`, `state change: ... -> activated`)
- STP Topology Change Notifications from a packet capture (via tshark)
- LACP synchronisation state changes from a packet capture (via tshark)

## Usage

```
./link-flap-detect.sh [OPTIONS]
```

### Options

| Option | Description | Default |
|---|---|---|
| `-w MINUTES` | Time window to scan back from now | `60` |
| `-t COUNT` | Number of transitions to consider flapping | `3` |
| `-i IFACE` | Limit output to a specific interface | (all) |
| `-p PCAP_FILE` | Analyse a packet capture file with tshark | (none) |
| `-m URL` | Prometheus base URL for metric enrichment | (none) |
| `-e URL` | node_exporter metrics URL (auto-probed at `http://localhost:9100`; pass `off` to disable) | `http://localhost:9100` |
| `-3 SERVER` | Run iperf3 to SERVER for 5s; show bandwidth and retransmits as enrichment | (none) |
| `-d IFACE` | Run diagnostic wizard for IFACE | (none) |
| `-R BACKUP_ID` | Restore config files from a saved backup | (none) |
| `-f SECONDS` | Follow mode: re-run every N seconds until Ctrl-C | (off) |
| `-v` | Verbose — show every individual up/down event | off |
| `-h` | Show help | |

Options can also be set via environment variables: `WINDOW_MINUTES`, `FLAP_THRESHOLD`, `IFACE_FILTER`.

## Examples

**Scan the last 60 minutes of system logs (default):**
```bash
./link-flap-detect.sh
```

**Scan the last 2 hours, flag after 5 transitions:**
```bash
./link-flap-detect.sh -w 120 -t 5
```

**Check a specific interface only:**
```bash
./link-flap-detect.sh -i eth0
```

**Verbose output — show every UP/DOWN event:**
```bash
./link-flap-detect.sh -v
```

**Analyse a packet capture for STP/LACP flap evidence:**
```bash
./link-flap-detect.sh -p /tmp/capture.pcap
```

**Capture live traffic then analyse it:**
```bash
tshark -w /tmp/capture.pcap -a duration:60 -i eth0
./link-flap-detect.sh -p /tmp/capture.pcap -v
```

**PCAP + interface filter (only report stp-aabb events):**
```bash
./link-flap-detect.sh -p /tmp/capture.pcap -i stp-aabb
```

**Check bandwidth while a link is flapping (iperf3 enrichment):**
```bash
./link-flap-detect.sh -3 iperf3.example.com
```

**Wizard + iperf3 probe together:**
```bash
./link-flap-detect.sh -d eth0 -3 iperf3.example.com
```

**Run the diagnostic wizard on eth0:**
```bash
# Find your interface name first:
ip link show

# Then run the wizard:
./link-flap-detect.sh -d eth0 -w 60
```

**Watch for flapping in real time (re-scan every 30 seconds):**
```bash
./link-flap-detect.sh -f 30
```

**Follow mode with interface filter (Ctrl-C to stop):**
```bash
./link-flap-detect.sh -f 10 -i eth0 -v
```

**List all saved config backups:**
```bash
./link-flap-detect.sh -R list
```

**Restore a backup:**
```bash
# Restoring files in /etc/ requires root:
sudo ./link-flap-detect.sh -R 20260302-143000-eth0
```

## Log sources

The script tries sources in this order:

1. **journald** — used if `journalctl` is available (Ubuntu 20.04+)
2. **PCAP file** — used when `-p` is passed (requires `tshark`)
3. **Syslog files** — `/var/log/syslog` and `/var/log/kern.log` as a fallback

## Prometheus enrichment

Requires a running Prometheus server scraping [node_exporter](https://github.com/prometheus/node_exporter).
Pass the base URL with `-m`:

```bash
./link-flap-detect.sh -m http://localhost:9090
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
./link-flap-detect.sh -e http://localhost:9200

# Disable node_exporter probing entirely
./link-flap-detect.sh -e off
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

Pass the target server hostname or IP with `-3`:

```bash
./link-flap-detect.sh -3 iperf3.example.com
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

If iperf3 is not installed and `-3` is passed the tool exits immediately with an error message.
If the server is unreachable or the test fails the section is silently omitted.

**Example output:**
```
[FLAPPING] eth0
  Transitions : 4  |  Events: 5  |  Span: 10:00:00–10:10:00 (10m 0s)
  [iperf3]  → iperf3.example.com
    Bandwidth     : 943.0 Mbps
    Retransmits   : 0
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
./link-flap-detect.sh -d eth0
```

The wizard:
1. **Snapshots network config files** before you act (netplan, NetworkManager, sysctl, etc.)
2. **Collects interface state** — operstate, carrier changes, speed/duplex, autoneg
3. **Checks for known causes** — EEE, runtime power management, CRC errors, duplex mismatch, no link, kernel errors
4. **Analyses flap patterns** in the log window (regular intervals may indicate STP/LACP/power timers)
5. **Prints colour-coded findings** (`[CAUSE]` / `[WARN]` / `[INFO]`) with `[FIX]` commands
6. **Saves a text report** to `~/.local/share/link-flap/reports/`

Override save locations via environment variables: `BACKUP_DIR`, `REPORT_DIR`.

After applying a `[FIX]` command, re-run `./link-flap-detect.sh -i IFACE -w 10` to confirm the interface has stabilised.

## Backup & Rollback (`-R BACKUP_ID`)

Every wizard run automatically backs up the system network config files
(netplan, interfaces, NetworkManager connections, sysctl) before you apply any fix.
Backups are stored in `~/.local/share/link-flap/backups/` (override via `BACKUP_DIR`).

**List saved backups:**
```bash
./link-flap-detect.sh -R list
```

**Restore a backup:**
```bash
# Files in /etc/ require root to overwrite:
sudo ./link-flap-detect.sh -R 20260302-143000-eth0
```

If restoration fails due to permissions the tool exits with code 1, prints a warning
for each failed file, and shows the exact `sudo` command to retry.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | No flapping detected (or wizard / rollback completed successfully) |
| `1` | One or more interfaces are flapping; or rollback backup not found; or restoration failed (permission denied) |

## Virtual interface filtering

By default, virtual and container interfaces are silently ignored:
`lo`, `veth*`, `virbr*`, `docker*`, `tun*`, `tap*`, `br-*`

Use `-i IFACE` to override and target a specific interface (including virtual ones).

## Running tests

```bash
bash tests/run-tests.sh
```

No root access or external dependencies required. The test suite uses synthetic log data and mocked tshark output — `tshark` does not need to be installed.
