# Roadmap

Features are grouped by priority. Items within each tier are roughly ordered by implementation effort (lowest first).

---

## Tier 1 — Production monitoring

These turn `flap` from a run-once diagnostic into something you can leave running.

### ~~Historical system load correlation~~ ✓ Done
When `-m URL` is set and flapping is detected, the tool queries Prometheus for CPU idle %,
memory available %, and load average **at the exact time flapping began** (not current values).
Shown as a `[system @ HH:MM:SS]` enrichment block. The wizard raises `[CAUSE]` for CPU
saturation (< 15% idle) and `[WARN]` for low memory (< 10% available) at flap time.

### Webhook alerts in follow mode
Add `-W URL` to send a JSON payload to a Slack, Discord, or generic webhook when flapping is detected or clears in `-f` follow mode. Fires on state changes only — not on every poll cycle.

### Alert deduplication in follow mode
Track per-interface flap state across `-f` rescans. Only report when an interface transitions from stable → flapping or flapping → stable. Currently the full report is reprinted on every interval regardless of whether anything changed.

### JSON output mode
Add `-j` flag for machine-readable output. Emits a JSON object with detected interfaces, transition counts, event timestamps, enrichment data, and wizard findings. Makes `flap` pipeable into dashboards, alerting scripts, and log aggregators.

### Persistent event log
Append all detected flap events to `~/.local/share/link-flap/events.log` with ISO 8601 timestamps. Survives terminal sessions, enabling "when did this start?" queries and long-term trend analysis without re-scanning old log files.

---

## Tier 2 — Workflow and usability

### Auto-apply fixes
Add `--fix` flag to the wizard. When a `[CAUSE]` finding has a known, safe, single-command fix (EEE off, power control, autoneg), prompt for confirmation and apply it immediately rather than printing a command for the user to copy. Requires root for some fixes; print a clear `sudo` escalation if not already running as root.

### Bond / LAG member awareness
Detect when a flapping interface is a member of a bond or team (`bond0`, `team0`, `lacp*`). Cross-reference with the bond's own state and carrier changes. Currently produces per-member output that can be confusing without bond context.

### Scheduled / cron mode
Add `--log-file FILE` to append timestamped output to a file instead of printing to stdout, and `--quiet` to suppress all output except errors. Makes `flap` cron-safe for periodic checks: `*/15 * * * * ./flap --log-file /var/log/link-flap.log --quiet`.

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
