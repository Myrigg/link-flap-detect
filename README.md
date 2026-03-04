# flap

Detect network interface link flapping from system logs and packet captures.

[![CI](https://github.com/Myrigg/link-flap-detect/actions/workflows/ci.yml/badge.svg)](https://github.com/Myrigg/link-flap-detect/actions/workflows/ci.yml)
[![Bash 4+](https://img.shields.io/badge/bash-4%2B-green.svg)]()

[Quick Start](#quick-start) · [Install](#install) · [Options](#options) · [Examples](#examples) · [Wizard](docs/wizard.md) · [Enrichment](docs/enrichment.md) · [Advanced](docs/advanced.md)

## Quick Start

```bash
curl -O https://raw.githubusercontent.com/Myrigg/link-flap-detect/main/flap
chmod +x flap

./flap                   # scan the last hour
./flap -d eth0           # diagnose a flapping interface
./flap -f 30             # watch in real time (Ctrl-C to stop)
```

## Install

**Clone:**

```bash
git clone https://github.com/Myrigg/link-flap-detect.git
cd link-flap-detect
```

**Or download the script directly:**

```bash
curl -O https://raw.githubusercontent.com/Myrigg/link-flap-detect/main/flap
chmod +x flap
```

**System install:**

```bash
git clone https://github.com/Myrigg/link-flap-detect.git
cd link-flap-detect
sudo make install
```

**Standalone single-file download:**

```bash
curl -LO https://github.com/Myrigg/link-flap-detect/releases/latest/download/flap-standalone
chmod +x flap-standalone
```

No package manager required. Runs on any Ubuntu 20.04+ system out of the box.

**Self-update:** `./flap --update` — uses `git pull` for clones or re-downloads in-place for standalone installs.

<details>
<summary><strong>Requirements</strong></summary>

| Dependency | Used for | Notes |
|---|---|---|
| `bash` 4+ | Core | Pre-installed on Ubuntu |
| `journalctl` | Log scanning (default source) | Pre-installed on Ubuntu 20.04+ |
| `awk`, `sort`, `date`, `mktemp` | Core | Pre-installed (coreutils) |
| `curl` | Prometheus enrichment (`-m`) | `apt install curl` |
| `tshark` | PCAP analysis (`-p`) | `apt install tshark` — optional |
| `iperf3` | Active bandwidth probe (`-b`) | `apt install iperf3` — optional |
| `ethtool` | SFP DOM optical power in Layer 1 check | Pre-installed; `-m` flag requires driver support |
| `lldpctl` | LLDP neighbour identification | `apt install lldpd` — optional |

`curl`, `tshark`, `iperf3`, and `lldpd` are only needed for their respective optional features. Everything else is already present on a standard Ubuntu install.

</details>

## What it detects

- Kernel NIC driver events (`NIC Link is Up/Down`, `carrier acquired/lost`) — virtio_net, e1000e, igb, tg3, ixgbe, bnxt, and others
- systemd-networkd carrier events (`Gained/Lost carrier`, `Link UP/DOWN`)
- NetworkManager state changes (`link connected/disconnected`, `state change: ... -> activated`)
- STP Topology Change Notifications from a packet capture (via tshark)
- LACP synchronisation state changes from a packet capture (via tshark)
- Correlated flapping across multiple interfaces — events on 2+ interfaces within the same 10-second window are flagged as `[CORRELATED]`

## Options

```
./flap [OPTIONS]
```

| Option | Description | Default |
|---|---|---|
| **Core** | | |
| `-w MINUTES` | Time window to scan back from now | `60` |
| `-t COUNT` | Transitions to consider flapping | `3` |
| `-i IFACE` | Limit to a specific interface | (all) |
| `-v` | Verbose — show every individual up/down event | off |
| `-h` | Show help | |
| **Sources** | | |
| `-p PCAP_FILE` | Analyse a packet capture file with tshark | (none) |
| `-m URL` | Prometheus base URL (saved to config) | (none) |
| `-n URL` | node_exporter URL (`off` to disable) | `localhost:9100` |
| `-b SERVER` | iperf3 server for bandwidth test (saved to config) | (none) |
| **Wizard** | | |
| `-d IFACE` | Run [diagnostic wizard](docs/wizard.md) for IFACE | (none) |
| `--dut IFACE` | [Device-under-test](docs/wizard.md#device-under-test---dut-iface) comparison | (none) |
| `--fix` | [Auto-apply](docs/wizard.md#auto-apply-fixes---fix) safe wizard fixes | off |
| `-r BACKUP_ID` | [Restore](docs/wizard.md#backup--rollback--r-backup_id) config backup (`list` to show all) | (none) |
| **Output** | | |
| `-j` | [JSON output](docs/advanced.md#json-output--j) — single JSON object to stdout | off |
| `--export FILE` | [Prometheus textfile](docs/advanced.md#prometheus-exporter---export-file) metrics | (none) |
| `--log-file FILE` | Append output to file (ANSI auto-disabled) | (none) |
| `--quiet` | Suppress stdout; exit code still reflects flapping | off |
| `--reports` | List saved [wizard reports](docs/advanced.md#report-aggregation---reports) | |
| `--events [N\|all\|DATE]` | Query the [event log](docs/advanced.md#persistent-event-log---events) | |
| **Monitoring** | | |
| `-f SECONDS` | Follow mode — re-run every N seconds until Ctrl-C | (off) |
| `-W URL` | [Webhook](docs/advanced.md#webhook-alerts--w-url) for flap/clear alerts in follow mode | (none) |
| `--fleet` | [Fleet mode](docs/advanced.md#fleet-mode---fleet) — scan all Prometheus targets (requires `-m`) | off |
| **Remote** | | |
| `-H HOST` | Run on a [remote machine](docs/advanced.md#ssh-remote-host--h-host) over SSH | (none) |
| **Time range** | | |
| `--since DATE` | Scan from DATE (overrides `-w`). `YYYY-MM-DD [HH:MM:SS]` | (none) |
| `--until DATE` | Scan up to DATE. Same format as `--since` | now |
| **Other** | | |
| `--update` | Update to the latest version from GitHub | |
| `--version` | Print version and exit | |

Options can also be set via environment variables: `WINDOW_MINUTES`, `FLAP_THRESHOLD`, `IFACE_FILTER`. Flags take precedence.

## Examples

**Basic scanning:**

```bash
./flap                                          # last 60 minutes (default)
./flap -w 120 -t 5                              # last 2 hours, flag after 5 transitions
./flap -i eth0 -v                               # single interface, verbose
```

**Diagnostic wizard:**

```bash
./flap -d eth0                                  # full diagnosis
./flap -d eth0 --fix                            # diagnose + auto-apply safe fixes
./flap -d eth0 --dut eth1                       # compare device-under-test vs host
```

**Monitoring:**

```bash
./flap -f 30                                    # follow mode (re-scan every 30s)
./flap -f 30 -W https://hooks.slack.com/T/B/x  # follow + Slack webhook alerts
./flap -m http://prom:9090 --fleet              # scan entire fleet via Prometheus
```

**Integration:**

```bash
./flap -j | jq '.summary'                      # JSON output for scripting
./flap -H user@192.168.1.1 -d eth0             # remote host over SSH
./flap --export /path/flap.prom --quiet         # Prometheus textfile metrics
./flap --since "2026-02-27" --until "2026-02-28"  # historical time range
```

**Scheduled (cron):**

```bash
*/15 * * * * /usr/local/bin/flap --log-file /var/log/link-flap.log --quiet
*/15 * * * * /usr/local/bin/flap --export /var/lib/node_exporter/textfile/flap.prom --quiet
```

**Packet capture:**

```bash
./flap -p /tmp/capture.pcap                     # analyse STP/LACP from pcap
```

## Features

### Log sources

The script selects a source in this order: **PCAP file** (`-p`) > **journald** (default on Ubuntu 20.04+) > **syslog files** (`/var/log/syslog`, `/var/log/kern.log`).

### Metric enrichment

When flapping is detected, up to four metric sources add context below each `[FLAPPING]` line: **Prometheus** (`-m`), **node_exporter** (auto-probed), **iperf3** (`-b`), and **system load correlation** (historical CPU/memory at flap time). All sources are optional and silently omitted if unavailable. See [docs/enrichment.md](docs/enrichment.md) for details.

### Diagnostic wizard (`-d IFACE`)

Runs a fully automatic, read-only analysis of a specific interface — or automatically on every flapping interface when detected. Produces colour-coded findings (`[CAUSE]` / `[WARN]` / `[INFO]`) with fix commands, six-layer fault localization (Physical, NIC Driver, Switch Port, Gateway, VPN, DNS), and saves a text report. See [docs/wizard.md](docs/wizard.md) for the full reference.

- `--fix` auto-applies safe single-command fixes ([details](docs/wizard.md#auto-apply-fixes---fix))
- `--dut IFACE` compares a device-under-test against the host ([details](docs/wizard.md#device-under-test---dut-iface))
- `-r BACKUP_ID` restores config backups created before fixes ([details](docs/wizard.md#backup--rollback--r-backup_id))
- `--reports` lists all saved wizard reports ([details](docs/advanced.md#report-aggregation---reports))

### Monitoring & alerting

- **Follow mode** (`-f`) — re-scans at a set interval with [alert deduplication](docs/advanced.md#alert-deduplication-in-follow-mode): `[FLAPPING]` on first detection, `[STILL FLAPPING]` for continued, `[CLEARED]` when stabilised
- **Webhooks** (`-W`) — JSON payloads to Slack/Discord/generic endpoints on state changes ([details](docs/advanced.md#webhook-alerts--w-url))
- **Fleet mode** (`--fleet`) — scan all Prometheus-monitored hosts in one command ([details](docs/advanced.md#fleet-mode---fleet))
- **Cron mode** (`--log-file`, `--quiet`) — unattended scheduled monitoring ([details](docs/advanced.md#scheduled--cron-mode---log-file---quiet))
- **Event log** (`--events`) — persistent history of all flap/clear detections ([details](docs/advanced.md#persistent-event-log---events))

### Integrations

- **JSON output** (`-j`) — machine-readable output for dashboards and `jq` ([details](docs/advanced.md#json-output--j))
- **SSH remote** (`-H`) — run diagnostics on remote machines ([details](docs/advanced.md#ssh-remote-host--h-host))
- **Prometheus exporter** (`--export`) — textfile metrics for `node_exporter` ([details](docs/advanced.md#prometheus-exporter---export-file))
- **Bond/LAG awareness** — flapping bond members are annotated with bond context ([details](docs/advanced.md#bond--lag-member-awareness))
- **PCAP analysis** (`-p`) — STP TCN and LACP state change detection via tshark ([details](docs/advanced.md#tshark--pcap-mode--p-file))

## Configuration

`-m`, `-b`, and `-W` values are saved to `~/.config/link-flap/config` (XDG-compliant) on first use. Saved values load silently on subsequent runs. CLI flags always take precedence and update the saved value.

To clear a saved value, edit or delete `~/.config/link-flap/config`. This file is never touched by `--update`.

## Reference

### Exit codes

| Code | Meaning |
|---|---|
| `0` | No flapping detected (or wizard/rollback completed successfully) |
| `1` | One or more interfaces are flapping; or rollback backup not found |
| `2` | Rollback partially failed — some files could not be written (re-run with `sudo`) |

### Virtual interface filtering

By default, virtual and container interfaces are silently ignored: `lo`, `veth*`, `virbr*`, `docker*`, `tun*`, `tap*`, `br-*`. Use `-i IFACE` to override and target a specific interface.

## Testing

```bash
bash tests/run-tests.sh
```

No root access or external dependencies required. The test suite (22 files, 161 tests) injects synthetic log data and mocked tool output — none of the optional tools need to be installed. Individual test files can also be run in isolation: `bash tests/test-detection.sh`, etc.
