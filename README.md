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

### Updating

```bash
./flap --update
```

Updates via `git pull` if installed as a clone, or re-downloads the script in-place if installed standalone. On each startup, flap also checks for a newer version and prompts you to update (requires curl; skipped automatically in non-interactive and scripted contexts).

### Requirements

| Dependency | Used for | Notes |
|---|---|---|
| `bash` 4+ | Core | Pre-installed on Ubuntu |
| `journalctl` | Log scanning (default source) | Pre-installed on Ubuntu 20.04+ |
| `awk`, `sort`, `date`, `mktemp` | Core | Pre-installed (coreutils) |
| `curl` | Prometheus enrichment (`-m`) | `apt install curl` |
| `tshark` | PCAP analysis (`-p`) | `apt install tshark` — optional |
| `iperf3` | Active bandwidth probe (`-b`) | `apt install iperf3` — optional |
| `ethtool` | SFP DOM optical power in Layer 1 check | Pre-installed on Ubuntu; `-m` flag requires driver support |
| `lldpctl` | LLDP neighbour identification in Layer 1 check | `apt install lldpd` — optional |

`curl`, `tshark`, `iperf3`, and `lldpd` are only needed for their respective optional features. Everything else is already present on a standard Ubuntu install. `ethtool` is pre-installed but SFP DOM (`-m`) requires a compatible NIC driver — it is silently skipped on copper or unsupported NICs.

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
| `-m URL` | Prometheus base URL for metric enrichment (saved to `~/.config/link-flap/config` for future runs) | (none) |
| `-n URL` | node_exporter metrics URL (auto-probed at `http://localhost:9100`; pass `off` to disable) | `http://localhost:9100` |
| `-b SERVER` | iperf3 server for 5s bandwidth+retransmit test (saved to `~/.config/link-flap/config` for future runs) | (none) |
| `-d IFACE` | Run diagnostic wizard for IFACE | (none) |
| `-r BACKUP_ID` | Restore config files from a saved backup | (none) |
| `-f SECONDS` | Follow mode: re-run every N seconds until Ctrl-C | (off) |
| `-v` | Verbose — show every individual up/down event | off |
| `-h` | Show help | |
| `--fleet` | Fleet mode: query Prometheus for flapping across all monitored hosts (requires `-m`) | off |
| `--dut IFACE` | Compare a device-under-test interface against the primary — the wizard identifies whether the fault is in the DUT or the host | (none) |
| `--update` | Update flap to the latest version from GitHub and exit | |
| `--since DATE` | Scan from DATE instead of using `-w`. Accepts `YYYY-MM-DD` or `YYYY-MM-DD HH:MM:SS`. Date-only defaults to `00:00:00`. | (none) |
| `--until DATE` | Scan up to DATE (default: now). Same format as `--since`. Date-only defaults to `23:59:59`. | now |

Options can also be set via environment variables: `WINDOW_MINUTES`, `FLAP_THRESHOLD`, `IFACE_FILTER`.
Command-line flags take precedence over environment variables when both are set.

## Configuration

`-m URL` and `-b SERVER` values are saved automatically to `~/.config/link-flap/config` (XDG-compliant). Saved values are used silently on subsequent runs.

For `-m` (Prometheus): on the first interactive run without a saved URL, flap prompts for it.

For `-b` (iperf3): if no server is set via flag or config, the wizard (`-d IFACE`) auto-discovers
one from the diagnosed interface — LLDP management IP (`lldpctl`) first, then the default
gateway. Auto-discovered IPs are not saved to config. If neither is available, iperf3 is
silently skipped.

**Precedence (iperf3):** `-b` flag > config file > LLDP MgmtIP > default gateway > skipped

Passing a flag always wins and updates the saved value for next time. To clear a saved value, edit or delete `~/.config/link-flap/config`. This file is never touched by `--update`.

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

**Wizard with device-under-test comparison (for network hardware developers):**
```bash
# eth0 is the host uplink; eth1 is the device being tested:
./flap -d eth0 --dut eth1
```

**Update to the latest version:**
```bash
./flap --update
```

**Analyse a specific historical time window:**
```bash
# Exact datetime range:
./flap -i eno6 --since "2026-02-27 13:21:28" --until "2026-02-28 21:16:03"

# Full days (date-only; --since defaults to 00:00:00, --until to 23:59:59):
./flap -i eno6 --since "2026-02-27" --until "2026-02-28"

# From a date until now (no --until):
./flap -i eno6 --since "2026-02-27"
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

In wizard mode (`-d IFACE`), if no server is set via `-b` or config, flap auto-discovers one:
LLDP management IP of the directly connected device first (requires `lldpctl`), then the
default gateway for the interface. Auto-discovered IPs are not saved to config.

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

### Fault Localization

Runs automatically as part of every `-d IFACE` wizard invocation — no extra flag needed.
After collecting interface state and raising findings, the wizard checks six layers in order:

| Layer | What is checked |
|---|---|
| Physical (cable / SFP) | Carrier changes, unknown speed, autoneg failures, SFP DOM optical power (RX/TX dBm), LLDP neighbour |
| NIC Driver | ethtool driver version, firmware, dmesg NIC resets |
| Switch Port | LLDP availability, STP topology changes, duplex mismatch |
| Gateway / Router | Live ping to default gateway and 8.8.8.8 |
| VPN | Presence of tun/tap/wg/tailscale interfaces |
| DNS | resolv.conf resolver + live DNS query |

Each layer reports **OK** / **SUSPECT** / **UNKNOWN**. A **VERDICT** sentence names the
most likely fault layer. Gateway and DNS checks are skipped if no default route is found.
Layer 3 checks involve a brief live ping and DNS query (~2–3s total).

**Example output:**
```
════════════════════════════════════════════════════════════
  Fault Localization — eth0
════════════════════════════════════════════════════════════

  Layer 1 — Physical (cable / connector / SFP)
    Status   : SUSPECT
    Remote   : switch1.example.com port GigabitEthernet0/5
    Evidence : Unknown speed (autoneg failed); 53792 carrier changes (severe); RX optical power -38.5 dBm — remote SFP or fibre degraded
    Next step: Investigate remote device/port (switch1.example.com port GigabitEthernet0/5); check far-end SFP and fibre connectors

  Layer 2 — NIC Driver
    Status   : OK
    Driver   : e1000e  v3.8.7-NAPI  fw 3.25.0

  Layer 2 — Switch Port
    Status   : UNKNOWN
    Note     : LLDP not available; no STP topology changes seen
    Next step: Check switch port error counters; try a different port

  Layer 3 — Gateway / Router
    Status   : OK
    Gateway  : 192.168.1.1  (reachable)
    Internet : reachable (8.8.8.8)

  VPN
    Status   : Not detected

  DNS
    Status   : OK
    Resolver : 8.8.8.8  (resolved google.com)

  ──────────────────────────────────────────────────────────
  VERDICT: Fault is most likely in the PHYSICAL LAYER
           (cable, SFP, or switch port).
  ──────────────────────────────────────────────────────────
```

### Device Under Test (`--dut IFACE`)

Intended for developers testing network hardware (NICs, adapters, embedded devices).
Pass `--dut IFACE` alongside `-d` to add a **DUT comparison block** to the fault
localization report:

```bash
# eth0 is the host uplink; eth1 is the device being tested:
./flap -d eth0 --dut eth1
```

The wizard compares DUT vs. host across carrier_changes, speed, and link state. If the DUT
is unstable while the host uplink is stable, VERDICT identifies the DUT or DUT-host cable
as the fault rather than anything upstream.

**Example DUT block:**
```
  DUT Interface (eth1 — device under test)
    Carrier changes: 5000  [SEVERE]   vs host eth0: 2  [normal]
    Speed          : Unknown!          vs host eth0: 1000Mb/s
    Link state     : unknown           vs host eth0: up

  ──────────────────────────────────────────────────────────
  VERDICT: Fault is likely in the DUT or DUT-host cable.
           Host uplink (eth0) is stable — the issue is not
           upstream of this computer.
  ──────────────────────────────────────────────────────────
```

### Wizard findings reference

| Condition | Level | Finding |
|---|---|---|
| `carrier_changes` > 500 | `[CAUSE]` | Severe carrier instability |
| `carrier_changes` > 20 | `[WARN]` | High carrier changes since boot |
| Speed = `Unknown!` | `[CAUSE]` | Link speed unreadable — auto-negotiation failure |
| TX drop rate > 1% of total TX packets | `[CAUSE]` | Severe TX packet loss |
| TX drop rate > 0.1% of total TX packets | `[WARN]` | Elevated TX packet loss |
| RX drop rate > 1% of total RX packets | `[CAUSE]` | Severe RX packet loss |
| RX drop rate > 0.1% of total RX packets | `[WARN]` | Elevated RX packet loss |
| ≥ 2 of: Unknown speed + carrier > 500 + TX packet loss at CAUSE level | `[CAUSE]` | Physical layer failure signature |
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

> Drop thresholds are **rate-based** when node_exporter provides
> `node_network_transmit_packets_total` / `node_network_receive_packets_total`
> (loss as a percentage of total traffic since boot). Absolute-count fallbacks
> (> 5000 / > 100) are used only when packet totals are unavailable, with a note
> in the finding.

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
bash tests/test-fault-localization.sh  # fault localization, layer analysis, --dut
```
