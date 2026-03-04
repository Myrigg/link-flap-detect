# Changelog

## [2026.03.04.3] — 2026-03-04

### Fault localization improvements

- **EEE + power management → L2drv SUSPECT** — EEE enabled or runtime PM
  `auto` now triggers NIC Driver SUSPECT, surfacing root causes that were
  previously invisible to the verdict.

- **MTU mismatch → L2sw SUSPECT** — local MTU vs LLDP peer Maximum Frame Size
  mismatch now marks Switch Port as SUSPECT with evidence detail.

- **Combined L1 + L2sw verdict** — when both Physical and Switch Port are
  SUSPECT, the verdict names both layers and advises addressing switch config
  first.

- **L2drv UNKNOWN accepted in "No fault"** — systems without `ethtool -i`
  no longer fall through to the "ambiguous" catch-all verdict.

- **DUT operstate display fix** — host operstate was always "unknown" in the
  DUT comparison; now resolves correctly.

- **Hoisted peer_mtu extraction** — removes a duplicate `lldpctl` call from
  the findings block.

### Tests

- 7 new fault localization tests (235–241): EEE, PM, operstate, MTU mismatch,
  UNKNOWN verdict, combined L1+L2sw, negative case. Total: 191 tests.

## [2026.03.04.2] — 2026-03-04

### New features

- **5 new wizard diagnostic checks** — MTU mismatch (local vs LLDP peer),
  autonegotiation mismatch, FEC mode on 25G+ links, excessive pause frames,
  and duplex mismatch (local Full / peer Half → [CAUSE]).

- **`--config show|reset`** — `--config show` prints all persisted settings;
  `--config reset` clears the config file.

- **Additional persisted settings** — `WINDOW_MINUTES`, `FLAP_THRESHOLD`, and
  `NODE_EXPORTER_URL` are now saved to config when passed as flags and loaded
  on subsequent runs (flags always override).

- **URL validation** — `_save_config` validates URL-type keys (`PROM_URL`,
  `WEBHOOK_URL`, `NODE_EXPORTER_URL`) before persisting; invalid URLs are
  rejected with a warning.

### Tests

- 16 new tests (177 total): wizard new checks (7), config management (5),
  boundary validation (2), corrupted event log (1), JSON+wizard combined (1).

## [2026.03.04.1] — 2026-03-04

### Code quality

- **Deduplicated JSON output** — extracted `_emit_json()` helper in `lib/utils.sh`;
  both JSON emission paths (no-events and flapping) now share a single function.

- **Webhook JSON escaping** — `_send_webhook()` now escapes backslashes and
  double-quotes in the message before interpolating into JSON payloads.

- **Prometheus reachability flag** — `_PROM_REACHABLE` flag distinguishes
  "Prometheus unreachable" from "connected but no data" without a redundant
  connectivity probe.

- **ShellCheck clean** — added SC2034 suppressions for cross-file globals
  (`DUT_IFACE`, `FIX_MODE`, `SINCE_ARG`, `FLAPPING_FOUND`). `shellcheck -S warning`
  now exits 0.

### Minor improvements

- Large window warning: `-w` values exceeding 1440 (24h) emit a stderr warning.
- `.gitignore` now includes `flap-standalone` build artifact.
- Rollback output notes that file permissions are preserved from backup time.
- Documented syslog year-boundary assumption in `lib/log-collection.sh`.

## [2026.03.04] — 2026-03-04

### Architecture

- **Modularized into `lib/`** — the monolithic `flap` script (~2800 lines) is now a
  ~850-line main script that sources 10 modules from `lib/`: backup, config, iperf3,
  log-collection, menu, node-exporter, prometheus, utils, webhooks, wizard. All 161
  tests pass without changes. `make bundle` produces a single-file `flap-standalone`
  with all modules inlined.

- **Build system** — `Makefile` with `make install` (installs `flap` + `lib/*.sh`),
  `make bundle` (standalone single-file build), and `make uninstall`. Supports
  `DESTDIR`, `BINDIR`, and `LIBDIR` overrides.

- **`--version` flag** — prints version and exits. Bash 4+ guard added to fail
  early on unsupported shells.

### Bug fixes

- **Wizard reliability** — corrected variable scope in `_rpt()` (promoted from nested
  function to module-level), fixed misleading text in EEE findings, and prevented
  unsafe fix suggestions for read-only sysfs attributes.

### Testing

- 18 new tests added (161 total, up from 143). New coverage for wizard contextual
  enrichment, fault localization edge cases, and driver advisories.

---

## [2026.03.03] — 2026-03-03

### New features

- **Findings section redesigned** — the wizard's Findings section now renders as a
  two-part layout: an at-a-glance numbered summary table (`#  Level   Title`) followed
  by numbered detail blocks, each separated by a blank line with a clear
  title / description / `[FIX]` hierarchy. Previously all findings ran together as a
  single wall of text.

- **Layer 1 SFP DOM optical power** — `ethtool -m` is now called during every wizard
  run. RX optical power < −35 dBm raises SUSPECT with "remote SFP or fibre degraded";
  −30 to −35 dBm logs a marginal warning. TX power < −9 dBm raises SUSPECT with "local
  SFP laser degraded". Silently skipped on copper NICs and drivers without DOM support.

- **Layer 1 LLDP neighbour identification** — if `lldpctl` is installed, the wizard
  queries the far-end device name and port. A `Remote:` line is printed in the Layer 1
  block when a neighbour is found. If `lldpctl` is present but returns no neighbour on
  an up link, that absence is itself flagged as evidence. Silently skipped if `lldpd`
  is not installed.

- **Context-aware Layer 1 next-step advice** — when evidence implicates the remote end
  (low RX power, missing LLDP neighbour), the recommended action now reads "Investigate
  remote device/port (peer port); check far-end SFP and fibre connectors" instead of
  the generic local-repair advice.

- **GitHub Actions CI pipeline** — `.github/workflows/ci.yml` with ShellCheck lint,
  full test suite, and VERSION consistency check on PRs. ShellCheck warnings fixed or
  suppressed across `flap` and all test files.

- **Webhook alerts in follow mode (`-W URL`)** — send a JSON payload to a Slack,
  Discord, or generic webhook when flapping is detected or clears in `-f` follow mode.
  Fires on state changes only — not on every poll cycle. URL is saved to config.

- **Alert deduplication in follow mode** — per-interface flap state is tracked across
  `-f` rescan cycles. Three output modes: `[FLAPPING]` for newly-detected flaps (full
  enrichment), `[STILL FLAPPING]` for continued flaps (compact one-liner with previous
  count), and `[CLEARED]` when a previously-flapping interface stabilises. Webhooks fire
  only on new-flap and cleared transitions.

- **JSON output mode (`-j`)** — emits a single JSON object to stdout with version,
  timestamp, config, per-interface data (name, status, transitions, events with
  epoch/state), correlation block, and summary. Human-readable output is suppressed.
  Serialised via `python3` for correct escaping. Combines with `-d`, `--fleet`, `-H`.

- **Persistent event log (`--events`)** — every FLAPPING detection appends a
  tab-separated entry to `~/.local/share/link-flap/events.log`. `--events [N|all|DATE]`
  queries the log: default last 20, `all` dumps everything, a date prefix filters by
  date. `EVENT_LOG` env var overrides the path for test isolation.

- **Bond / LAG member awareness** — when a flapping interface is a bond member
  (`/sys/class/net/<iface>/master`), the `[FLAPPING]` line shows
  `(bond member of bond0)`. The wizard adds an `[INFO]` finding with bond mode and
  carrier changes, or escalates to `[WARN]` when the member's carrier changes vastly
  exceed the bond's.

- **Scheduled / cron mode (`--log-file`, `--quiet`)** — `--log-file FILE` appends
  output to a file (ANSI auto-disabled since stdout is not a terminal). `--quiet`
  suppresses all stdout (exit code still reflects flapping). Combined:
  `*/15 * * * * ./flap --log-file /var/log/link-flap.log --quiet`.

- **Auto-apply fixes (`--fix`)** — when the wizard finds `[CAUSE]` entries with safe
  single-command fixes (EEE off, power control, autoneg), `--fix` offers to apply them.
  Interactive TTY: prompts per fix with `[y/N]`. Non-interactive: prints command only.
  Multi-step instructions are skipped. Failed commands suggest `sudo`.

- **Report aggregation (`--reports`)** — lists all saved wizard reports with date,
  interface, cause count, and warning count. Parses `[CAUSE]` and `[WARN]` markers
  from saved `.txt` report files in `~/.local/share/link-flap/reports/`.

- **SSH remote host mode (`-H HOST`)** — copies the script to the remote via `scp`,
  executes with `ssh`, streams output back, and cleans up. Validates host format
  (rejects shell metacharacters). All flags forwarded to the remote invocation.

- **Prometheus exporter mode (`--export FILE`)** — writes Prometheus textfile-format
  metrics: `link_flap_is_flapping` and `link_flap_transitions_total` (per interface),
  plus `link_flap_last_scan_timestamp`. Designed for cron with
  `node_exporter --collector.textfile`.

### Testing

- 22 test suites, 160+ tests total (up from 12 suites / ~80 tests).
- New test files: `test-webhook.sh`, `test-follow-dedup.sh`, `test-json.sh`,
  `test-event-log.sh`, `test-bond.sh`, `test-cron.sh`, `test-fix.sh`,
  `test-reports.sh`, `test-ssh.sh`, `test-exporter.sh`.

### Documentation

- README: updated fault localization table to list SFP DOM and LLDP in the Physical
  layer row; updated example output to show `Remote:` line and new evidence format;
  added `ethtool` and `lldpctl` to requirements table.
- README: added all new options to the Options table, usage examples, and dedicated
  sections for each new feature.
- README: updated test suite listing with all 22 test files.
- ROADMAP: all Tier 1–3 features marked as ✓ Done with implementation summaries.
- **README restructured for professional polish** — reduced from 934 to ~220 lines.
  Detailed reference material moved to `docs/wizard.md`, `docs/enrichment.md`, and
  `docs/advanced.md`. Added badges (CI, Bash version), quick-start section, navigation
  links, logically grouped options table, and curated examples. No content was lost —
  everything from the original README exists in either the new README or docs/.
