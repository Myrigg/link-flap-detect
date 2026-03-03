# Metric Enrichment

Back to [README](../README.md)

---

When flapping is detected, flap queries up to four metric sources to add context below
each `[FLAPPING]` line. All sources are optional — if unavailable, the enrichment block
is silently omitted and detection continues normally.

## Prometheus (`-m URL`)

Requires a running Prometheus server scraping
[node_exporter](https://github.com/prometheus/node_exporter). Pass the base URL with `-m`:

```bash
./flap -m http://localhost:9090
```

The URL is saved to `~/.config/link-flap/config` for future runs.

**Metrics queried:**

| Metric | Display |
|---|---|
| `node_network_up` | Current link state (UP / DOWN) |
| `node_network_carrier_changes_total` | Carrier changes over the scan window |
| `node_network_receive_errs_total` | RX errors/min (5-minute rate) |
| `node_network_transmit_errs_total` | TX errors/min (5-minute rate) |
| `node_network_receive_drop_total` | RX drops/min (5-minute rate) |
| `node_network_transmit_drop_total` | TX drops/min (5-minute rate) |

In verbose mode (`-v`), enrichment is also shown for interfaces below the flapping
threshold. Synthetic tshark interfaces (`stp-*`, `lacp-*`) are skipped.

**Example output:**

```
[FLAPPING] eth0
  Transitions : 4  |  Events: 5  |  Span: 10:00:00-10:10:00 (10m 0s)
  [Prometheus]
    Current state   : UP
    Carrier changes : 12 in last 60m
    RX errors       : 0.30/min
    TX errors       : 0.00/min
    RX drops        : 2.10/min
    TX drops        : 0.00/min
```

## node_exporter (`-n URL`)

When `node_exporter` is running locally (typically at `http://localhost:9100`), the tool
automatically probes it — no configuration needed.

```bash
# Use a non-default port:
./flap -n http://localhost:9200

# Disable probing entirely:
./flap -n off
```

**Metrics shown** (raw totals since boot):

| Metric | Display |
|---|---|
| `node_network_up` | Current link state (UP / DOWN) |
| `node_network_carrier_changes_total` | Carrier changes since boot |
| `node_network_receive_errs_total` | RX errors total |
| `node_network_transmit_errs_total` | TX errors total |
| `node_network_receive_drop_total` | RX drops total |
| `node_network_transmit_drop_total` | TX drops total |

The diagnostic wizard (`-d IFACE`) also reads node_exporter metrics: they appear in the
Interface State section of the report, and RX/TX error totals above zero are flagged as
`[WARN]` findings.

**Example output:**

```
[FLAPPING] eth0
  Transitions : 4  |  Events: 5  |  Span: 10:00:00-10:10:00 (10m 0s)
  [node_exporter]
    Current state   : UP
    Carrier changes : 12 total since boot
    RX errors       : 0 total
    TX errors       : 0 total
    RX drops        : 3 total
    TX drops        : 0 total
```

## iperf3 (`-b SERVER`)

Answers "is the link degraded when it IS up?" with real bandwidth and TCP retransmit data
from an active 5-second TCP test. Requires `apt install iperf3`.

```bash
./flap -b iperf3.example.com
```

In wizard mode (`-d IFACE`), if no server is set via `-b` or config, flap auto-discovers
one: LLDP management IP first (requires `lldpctl`), then the default gateway. Auto-discovered
IPs are not saved to config.

**Precedence:** `-b` flag > config file > LLDP MgmtIP > default gateway > skipped

The wizard flags retransmits > 0 as a `[WARN]` finding with a recommendation to test
longer and check switch port buffers.

**Example output:**

```
[FLAPPING] eth0
  Transitions : 4  |  Events: 5  |  Span: 10:00:00-10:10:00 (10m 0s)
  [iperf3]  -> iperf3.example.com
    Bandwidth     : 943.0 Mbps
    Retransmits   : 0
```

## System load correlation (`-m URL`)

When flapping is detected and `-m URL` is configured, flap queries Prometheus for system
resource metrics **at the exact moment flapping began** — not current values, but historical
data from when the event occurred.

Three metrics are queried at `first_epoch` (timestamp of the first flap event):

| Metric | PromQL | Threshold |
|---|---|---|
| CPU idle % | `avg(rate(node_cpu_seconds_total{mode="idle"}[5m]))*100` | Red if < 15%, yellow if < 30% |
| Memory available % | `node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes * 100` | Yellow if < 10% |
| Load average (1m) | `node_load1` | Shown for reference |

The diagnostic wizard raises findings based on these values:

- `[CAUSE]` if CPU idle < 15% — system was CPU-saturated
- `[WARN]` if CPU idle 15-30% — elevated load may have delayed NIC interrupt processing
- `[WARN]` if memory available < 10% — memory pressure can cause driver buffer exhaustion

**Example output:**

```
[FLAPPING] eth0
  Transitions : 6  |  Events: 7  |  Span: 02:47:12-02:52:48 (5m 36s)
  [Prometheus]
    Current state   : UP
    Carrier changes : 6 in last 60m
  [system @ 02:47:12]
    CPU idle        : 4.2%
    Memory available: 87.3%
    Load avg (1m)   : 0.42
```
