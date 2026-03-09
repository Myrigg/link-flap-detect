# Testing guide

## Running the tests

```bash
bash tests/run-tests.sh
```

All tests are self-contained and use synthetic data via environment variable hooks
(see below). No real network interfaces, Prometheus, or iperf3 server is required.

## Test hook environment variables

These variables allow the test suite to inject synthetic data and bypass real
system calls. They are **not documented end-user options** — they exist solely
for offline testing.

| Variable | Type | Used in | Effect |
|---|---|---|---|
| `_LINK_FLAP_TEST_INPUT` | File path | `flap`, `lib/log-collection.sh`, `lib/config.sh` | Bypasses journald/syslog; reads log events from the given file instead. Also suppresses event log writes (unless `EVENT_LOG` contains `test-`). |
| `_LINK_FLAP_TEST_TSHARK` | File path | `flap` | Bypasses `collect_from_tshark()`; reads pre-parsed `epoch iface STATE` lines from the given file directly into TMPFILE. |
| `_LINK_FLAP_TEST_PROM` | File path | `lib/prometheus.sh` | Bypasses curl to Prometheus instant API (`prom_query`, `prom_query_at`); serves the given JSON file as the API response. |
| `_LINK_FLAP_TEST_PROM_ALL` | File path | `lib/prometheus.sh` | Bypasses curl for `prom_query_all()` and the fleet reachability pre-check; serves the given JSON file as the multi-result response. |
| `_LINK_FLAP_TEST_NODE_EXPORTER` | File path | `lib/node-exporter.sh` | Bypasses curl to node_exporter; serves the given Prometheus text-format file as the metrics response. |
| `_LINK_FLAP_TEST_IPERF3` | File path or `"1"` | `lib/iperf3.sh` | Bypasses the real `iperf3` binary; serves the given JSON file as iperf3 output. Set to `"1"` to simulate a successful run with no output (tests that only check iperf3 is invoked). |
| `_LINK_FLAP_TEST_WIZARD_DIR` | Directory path | `lib/wizard.sh` | Replaces all sysfs reads (`_wiz_read`) and ethtool/ip/lldp calls (`_wiz_cmd`) with files from this directory. Filename is the basename of the real path (e.g. `carrier_changes`, `operstate`, `ethtool`, `speed`). |
| `_LINK_FLAP_TEST_DUT_DIR` | Directory path | `lib/wizard.sh` | Same as `_LINK_FLAP_TEST_WIZARD_DIR` but for `--dut` DUT interface reads (`_wiz_read_dut`, `_wiz_cmd_dut`). |
| `_LINK_FLAP_TEST_BOND_MASTERS` | `"eth0=bond0,eth1=bond1"` | `lib/wizard.sh` | Bypasses `/sys/class/net/<iface>/master` symlink check; returns bond master from comma-delimited `iface=master` pairs. |
| `_LINK_FLAP_TEST_FIX_LOG` | File path | `lib/wizard.sh` | Redirects `--fix` command execution to append the command string to this file instead of running it. Allows tests to assert which fixes would be applied. |
| `_LINK_FLAP_TEST_WEBHOOK_LOG` | File path | `lib/webhooks.sh` | Redirects webhook payloads to append to this file instead of making a real HTTP POST. |

## Test helper: `tests/lib.sh`

`tests/lib.sh` provides shared helpers used by all test files:

- `run_flap ARGS...` — runs `./flap` with the given args; captures stdout/stderr
- `run_with_config ARGS...` — same, but redirects `XDG_CONFIG_HOME` to a temp dir so config tests are isolated
- `assert_contains TEXT` — fails test if TEXT not found in last run output
- `assert_not_contains TEXT` — fails test if TEXT found in last run output
- `assert_exit_code N` — fails test if last run exit code != N
- `make_log_file EVENTS...` — creates a temp file with synthetic log events in syslog format
- `make_tshark_file EVENTS...` — creates a temp file with `epoch iface STATE` lines

## Adding a new test

1. Create `tests/test-<feature>.sh`
2. Source `tests/lib.sh` at the top
3. Use `run_flap` or `run_with_config` with appropriate test hooks
4. Use `assert_*` helpers for assertions
5. The test runner (`tests/run-tests.sh`) picks up all `test-*.sh` files automatically
