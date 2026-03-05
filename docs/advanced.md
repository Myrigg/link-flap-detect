# Advanced Features

Back to [README](../README.md)

---

## Fleet mode (`--fleet`)

Fleet mode uses Prometheus as the primary data source to detect link flapping across an
entire fleet of monitored hosts — all in a single command.

**Requirements:** Prometheus scraping
[node_exporter](https://github.com/prometheus/node_exporter) on each host, `curl`
installed locally.

```bash
./flap -m http://prom-server:9090 --fleet
```

For each `node_exporter` instance that Prometheus scrapes, the tool queries carrier-change
metrics across the scan window. Any device with carrier changes >= the flap threshold is
reported as `[FLAPPING]`, with the host:device pair, carrier count, current link state,
and RX/TX error rates.

After the flap report, a `[UNREACHABLE TARGETS]` section lists any scrape targets
currently down.

**Combine with other flags:**

```bash
# Filter by device name across all hosts:
./flap -m http://prom-server:9090 --fleet -i eth0

# Longer window:
./flap -m http://prom-server:9090 --fleet -w 480

# Follow mode — re-poll the fleet every 60 seconds:
./flap -m http://prom-server:9090 --fleet -f 60
```

Virtual interfaces (`lo`, `veth*`, `docker*`, etc.) are filtered by default.

**Example output:**

```
Link Flap Detector -- fleet mode
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
  server3:9100  last scrape: 2026-03-03T10:00:00Z -- context deadline exceeded
```

## JSON output (`-j`)

Emits a single JSON object to stdout instead of human-readable text. Useful for
dashboards, `jq` pipelines, and alerting scripts.

```bash
./flap -j | jq '.summary.flapping_interfaces'
```

**Schema (key fields):**

```json
{
  "version": "...",
  "timestamp": "...",
  "config": { "window_minutes": 60, "flap_threshold": 3, "log_source": "..." },
  "interfaces": [
    { "name": "eth0", "status": "flapping", "transitions": 8,
      "event_count": 9, "span": "10m 0s", "events": [...] }
  ],
  "correlation": { "correlated_groups": [...] },
  "summary": { "flapping_count": 1, "flapping_interfaces": ["eth0"] }
}
```

Validated with `python3 -m json.tool`. Combines with other flags: `-j --fleet`,
`-j -H user@host`, `-j -d eth0`.

## SSH remote host (`-H HOST`)

Run diagnostics on a remote machine. The script is copied over SSH, executed, and output
is streamed back:

```bash
./flap -H user@192.168.1.1 -d eth0
./flap -H admin@switch-mgmt -w 120 -v
```

Host format is validated (rejects shell metacharacters). All other flags are forwarded to
the remote invocation. Requires `ssh` and `scp` to be installed locally.

## Prometheus exporter (`--export FILE`)

Writes Prometheus textfile-format metrics to a file for consumption by
`node_exporter --collector.textfile`:

```bash
./flap --export /var/lib/node_exporter/textfile/flap.prom --quiet
```

**Metrics emitted:**

| Metric | Type | Description |
|---|---|---|
| `link_flap_is_flapping{interface="..."}` | gauge | `1` if flapping, absent if not |
| `link_flap_transitions_total{interface="..."}` | gauge | Transition count in scan window |
| `link_flap_last_scan_timestamp` | gauge | Unix epoch of the scan |

Designed for cron: `*/15 * * * * ./flap --export /path/flap.prom --quiet`.

## Webhook alerts (`-W URL`)

In follow mode (`-f`), send a JSON payload to a webhook endpoint whenever flapping is
detected or clears. Compatible with Slack, Discord, and generic HTTP endpoints.

```bash
./flap -f 30 -W https://hooks.slack.com/services/T.../B.../xxx
```

Webhooks fire **on state changes only** — not on every poll cycle. A `FLAPPING` payload is
sent when an interface starts flapping, and a `CLEARED` payload when it stabilises. The URL
is saved to `~/.config/link-flap/config` for future runs.

### Webhook payload format

**Slack** (any URL not containing `discord.com`):

```json
{"text":"[FLAPPING] eth0 — 8 transitions detected"}
```

```json
{"text":"[CLEARED] eth0 — link has stabilised"}
```

**Discord** (URL containing `discord.com`):

```json
{"content":"[FLAPPING] eth0 — 8 transitions detected","username":"link-flap-detect"}
```

```json
{"content":"[CLEARED] eth0 — link has stabilised","username":"link-flap-detect"}
```

Discord webhooks are auto-detected by checking whether the URL contains `discord.com`. No
configuration flag is needed.

## Alert deduplication in follow mode

When using `-f`, flap tracks per-interface state across rescan cycles:

- **`[FLAPPING]`** — first detection; full enrichment block + webhook
- **`[STILL FLAPPING]`** — continued flapping; compact one-liner with transition count comparison; no webhook
- **`[CLEARED]`** — previously flapping interface has stabilised; webhook fires

This prevents noisy repeated output when a link remains down for many cycles. Without `-f`,
deduplication is disabled — full output is always shown.

## Scheduled / cron mode (`--log-file`, `--quiet`)

Two flags for unattended operation:

- `--log-file FILE` — redirects output to a file (ANSI colours auto-disabled since stdout
  is not a terminal)
- `--quiet` — suppresses all stdout (exit code still reflects flapping)

Combined for cron:

```bash
*/15 * * * * /usr/local/bin/flap --log-file /var/log/link-flap.log --quiet
```

## Persistent event log (`--events`)

Every `[FLAPPING]` and `[CLEARED]` detection appends a tab-separated entry to
`~/.local/share/link-flap/events.log`:

```
2026-03-03T14:23:05+0000	eth0	FLAPPING	transitions=8
2026-03-03T14:38:10+0000	eth0	CLEARED
```

Query the log with `--events`:

```bash
./flap --events          # last 20 entries
./flap --events 50       # last 50 entries
./flap --events all      # everything
./flap --events 2026-03  # filter by date prefix
```

Override the log path with `EVENT_LOG` environment variable.

## Report aggregation (`--reports`)

Lists all saved wizard reports with date, interface, cause count, and warning count:

```bash
./flap --reports
```

```
Saved diagnostic reports:
  Date         Interface  Causes  Warnings
  ---------    ---------  ------  --------
  2026-03-01   eth0       2       1
  2026-03-02   enp3s0     0       1

2 reports total
```

Reports are stored in `~/.local/share/link-flap/reports/` (override via `REPORT_DIR`).

## Bond / LAG member awareness

When a flapping interface is a member of a Linux bond (detected via
`/sys/class/net/<iface>/master`), the `[FLAPPING]` line is annotated:

```
[FLAPPING] eth0  (bond member of bond0)
```

The wizard adds an `[INFO]` finding with bond mode and carrier changes. If the member's
carrier changes vastly exceed the bond's — indicating the member link is the fault, not the
overall bond — the finding is escalated to `[WARN]`.

## tshark / PCAP mode (`-p FILE`)

Requires `tshark` (`apt install tshark`). Analyses two protocol layers:

- **STP TCN BPDUs** — each Topology Change Notification indicates a spanning-tree port
  state change. Consecutive TCNs from the same sender are alternated DOWN/UP. The synthetic
  interface name is `stp-<penultimate-octet><last-octet>` of the source MAC (e.g.
  `stp-aabb`).
- **LACP actor state** — monitors the Synchronisation bit (bit 3, value 8) of the actor
  state field. A transition from set -> clear is reported as DOWN; clear -> set as UP. The
  synthetic interface name is `lacp-<penultimate-octet><last-octet>` (e.g. `lacp-ccdd`).
