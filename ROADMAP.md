# Roadmap

Features are grouped by priority. Items within each tier are roughly ordered by implementation effort (lowest first).

---

## Tier 1 — Production monitoring

These turn `flap` from a run-once diagnostic into something you can leave running.

### ~~Fault localization — layer-by-layer fault report~~ ✓ Done
The wizard appends a `[FAULT LOCALIZATION]` section to every diagnostic report. Six layers
are checked: Physical (cable/SFP/carrier), NIC Driver (ethtool -i, dmesg resets), Switch
Port (duplex mismatch), Gateway/Router (live ping), VPN (tun/tap/wg interface detection),
and DNS (resolv.conf + dig). Each layer reports OK / SUSPECT / UNKNOWN. A synthesised
VERDICT names the most likely fault layer. TX/RX drop thresholds are rate-based (>1% loss
= CAUSE, >0.1% = WARN), grounded in Prometheus community standards and TCP performance
research. The Physical layer check now includes SFP DOM optical power (`ethtool -m`) to
detect weak RX signal from the remote end and degraded local TX laser, plus LLDP neighbour
identification (`lldpctl`) to name the far-end device and port. Next-step advice is
tailored: remote-end evidence produces a different recommendation than local cable/SFP faults.

### ~~Device Under Test (`--dut IFACE`)~~ ✓ Done
`--dut IFACE` adds a DUT comparison block to the fault localization report. The wizard
compares DUT carrier_changes, speed, and link state against the host interface. If the DUT
is unstable while the host is stable, VERDICT names the DUT or DUT-host cable as the fault.
Intended for developers building or testing network hardware.

### ~~Historical date range (`--since` / `--until`)~~ ✓ Done
`--since DATE` and `--until DATE` allow scanning a specific historical window instead of
`-w` (last N minutes from now). Accepts `YYYY-MM-DD HH:MM:SS` or bare `YYYY-MM-DD`; date-only
`--since` defaults to `00:00:00` and `--until` to `23:59:59`. journalctl is passed matching
`--since`/`--until` args for efficiency. A post-parse epoch filter applied to the event
buffer handles all log sources (journald, syslog, tshark) uniformly. Not supported with
`--fleet`.

### ~~Self-update (`--update`) and startup version check~~ ✓ Done
`./flap --update` updates the script in-place: `git pull` for clone installs, `curl`
re-download for standalone installs. On each interactive startup, flap silently checks the
`VERSION` file on GitHub (3s timeout) and prompts the user if a newer version is available.
Skipped automatically in non-interactive contexts and follow-mode re-execs.

### ~~Historical system load correlation~~ ✓ Done
When `-m URL` is set and flapping is detected, the tool queries Prometheus for CPU idle %,
memory available %, and load average **at the exact time flapping began** (not current values).
Shown as a `[system @ HH:MM:SS]` enrichment block. The wizard raises `[CAUSE]` for CPU
saturation (< 15% idle) and `[WARN]` for low memory (< 10% available) at flap time.

### ~~Wizard enrichment — contextual interpretation~~ ✓ Done
Severity tiers for carrier_changes (>20 WARN, >500 CAUSE), TX/RX drop counts (>100 WARN,
>5000 CAUSE), Unknown speed/duplex CAUSE finding, and a combined physical-layer failure
synthesis CAUSE when ≥ 2 indicators are present. Interface State display annotates raw
values with inline context hints.

### Webhook alerts in follow mode
Add `-W URL` to send a JSON payload to a Slack, Discord, or generic webhook when flapping is detected or clears in `-f` follow mode. Fires on state changes only — not on every poll cycle.

### ~~Alert deduplication in follow mode~~ ✓ Done
Per-interface flap state is tracked across `-f` rescans via `_FLAP_PREV_FLAPPING`
(interface list) and `_FLAP_PREV_TRANSITIONS` (comma-delimited `iface=count` pairs).
Three output modes per cycle: `[FLAPPING]` for newly-detected flaps (full enrichment
block), `[STILL FLAPPING]` for continued flaps (compact one-liner with previous count),
and `[CLEARED]` when a previously-flapping interface stabilises. Webhooks fire only on
new-flap and cleared transitions. Without `-f`, deduplication is disabled — full output
is always shown.

### ~~JSON output mode~~ ✓ Done
`-j` flag emits a single JSON object to stdout: version, timestamp, config
(window, threshold, source, date range), per-interface data (name, status,
transitions, event count, span, and individual events with epoch/state), a
correlation block, and a summary with flapping count and interface names.
Human-readable output is suppressed. JSON is serialised via python3 for
correct escaping. Valid on both the no-events and flapping code paths.

### ~~Persistent event log~~ ✓ Done
Every FLAPPING detection appends a tab-separated entry to
`~/.local/share/link-flap/events.log` (ISO 8601 timestamp, interface, state,
transitions count). `--events [N|all|DATE]` queries the log: default last 20,
`all` dumps everything, a `YYYY-MM-DD` prefix filters by date. Graceful message
when no log file exists. `EVENT_LOG` env var overrides the path for test isolation.

---

## Tier 2 — Workflow and usability

### ~~Persistent config + interactive prompts~~ ✓ Done
`-m URL` and `-b SERVER` values are saved to `~/.config/link-flap/config` (XDG_CONFIG_HOME
respected) on first use. On subsequent runs the saved values are loaded silently — no need
to re-type server addresses. For `-m`, flap prompts on the first interactive TTY run if not
set. For `-b`, the interactive prompt was replaced with auto-discovery (see below). CLI flags
always win and are written back to config. `--update` never touches the config dir. Test
helper `run_with_config()` in `tests/lib.sh` redirects `XDG_CONFIG_HOME` to the temp dir so
config tests are isolated.

### ~~iperf3 server auto-discovery (LLDP / gateway)~~ ✓ Done
Removed the interactive iperf3 server prompts (`_prompt_iperf3`, `_prompt_iperf3_run`). In
wizard mode, if no server is configured via `-b` or config file, the wizard auto-discovers the
remote peer: LLDP management IP (`lldpctl $IFACE`) first, then the default gateway
(`ip route show dev $IFACE`). Auto-discovered IPs are not saved to config. iperf3 is silently
skipped if neither source yields an address. Explicit `-b SERVER` and saved config values
continue to work as before and take precedence over auto-discovery.

### ~~Auto-apply fixes~~ ✓ Done
`--fix` auto-applies safe single-command wizard fixes (EEE off, power control,
autoneg). Interactive TTY: prompts per fix with `[y/N]`. Non-interactive: prints
the command only. Multi-step instructions (numbered lists) are skipped. Failed
commands suggest `sudo`. Test hook: `_LINK_FLAP_TEST_FIX_LOG`.

### ~~Bond / LAG member awareness~~ ✓ Done
When a flapping interface is a bond member (`/sys/class/net/<iface>/master`),
the `[FLAPPING]` line shows `(bond member of bond0)`. The wizard adds an `[INFO]`
finding with bond mode and carrier changes, or escalates to `[WARN]` when the
member's carrier changes vastly exceed the bond's — indicating the member link is
the fault, not the overall bond. Test hook: `_LINK_FLAP_TEST_BOND_MASTERS`.

### ~~Scheduled / cron mode~~ ✓ Done
`--log-file FILE` appends output to a file (ANSI auto-disabled since stdout is not
a terminal). `--quiet` suppresses all stdout (exit code still reflects flapping).
Combined: `*/15 * * * * ./flap --log-file /var/log/link-flap.log --quiet`.

---

## Tier 3 — Multi-host and integration

### ~~Prometheus fleet scan~~ ✓ Done
`--fleet` mode added. Pass `-m URL --fleet` to query Prometheus for carrier-change metrics
across every `node_exporter` target. Detects flapping on all monitored hosts in one command.
Also surfaces unreachable scrape targets.

### SSH / remote host mode
Add `-H user@host` to run against a remote machine over SSH. Copies the script to a temp path on the remote host, executes it there, and streams the output back. Most link flapping happens on servers you're not sitting at.

### Report aggregation
Add `./flap --reports` to list and summarise all saved wizard reports in `~/.local/share/link-flap/reports/` — interface name, date, cause count, warn count — without opening each file individually.

### Prometheus exporter mode
Add `--export PORT` to expose a `/metrics` endpoint. Emits gauge metrics for currently-flapping interfaces, transition counts, and wizard finding counts. Allows long-term trending in Grafana without an external scraper.
