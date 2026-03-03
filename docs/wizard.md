# Diagnostic Wizard

Back to [README](../README.md)

---

The wizard (`-d IFACE`) runs a fully automatic, read-only analysis of a specific interface
and produces a structured report of likely flap causes and recommended fixes.

```bash
# Find your interface name:
ip link show

# Run the wizard (no root needed — it only reads, never writes to /etc/):
./flap -d eth0
```

The wizard also runs **automatically** whenever flapping is detected — you do not need to
pass `-d` explicitly. After reporting `[FLAPPING]` on any interface, the tool immediately
runs the wizard on each affected interface in the same invocation.

## What the wizard does

1. **Snapshots network config files** before you act (netplan, NetworkManager, sysctl, etc.)
2. **Collects interface state** — operstate, carrier changes, speed/duplex, autoneg
3. **Checks for known causes** — EEE, runtime power management, CRC errors, duplex mismatch, no link, kernel errors
4. **Interprets counters with severity tiers** — raw numbers are annotated and thresholded
5. **Synthesises multi-indicator findings** — when several symptoms align, names the fault class directly
6. **Analyses flap patterns** in the log window (regular intervals may indicate STP/LACP/power timers)
7. **Prints colour-coded findings** — an at-a-glance summary table followed by numbered detail blocks (`[CAUSE]` / `[WARN]` / `[INFO]`), each with a `[FIX]` command
8. **Saves a text report** to `~/.local/share/link-flap/reports/`

## Findings output

```
Findings

  #  Level   Title
  -  ------  -----------------------------------------------------------
  1  CAUSE   Severe carrier instability
  2  WARN    High carrier changes since boot

  -- Details --------------------------------------------------------

  [1] [CAUSE] Severe carrier instability
      542 link state transitions since boot (cumulative). A healthy,
      stable link has 1-5 total changes across its entire lifetime
      (initial autoneg + planned reboots). 500+ transitions indicates
      sustained physical instability: faulty cable, degraded SFP,
      switch port fault, or NIC hardware failure.
      [FIX]  Replace cable or SFP; try a different switch port; run: ethtool -d eth0

  [2] [WARN] High carrier changes since boot
      50 link state transitions since boot. Elevated but not severe.
      Could be a marginal cable, intermittent SFP, or switch port issue.
      [FIX]  Log in to switch and inspect port statistics
```

## Interface State annotations

Raw values are annotated with context hints:

```
Interface State
  operstate      : unknown
  carrier_changes: 53792  [SEVERE -- each change = 1 link drop+restore]
  speed          : Unknown!  [unreadable -- autoneg failed or link down]
  duplex         : Unknown  [unreadable -- same cause as unknown speed]
  autoneg        : unknown
  power/control  : unknown
```

## Findings reference

| Condition | Level | Finding |
|---|---|---|
| `carrier_changes` > 500 | `[CAUSE]` | Severe carrier instability |
| `carrier_changes` > 20 | `[WARN]` | High carrier changes since boot |
| Speed = `Unknown!` | `[CAUSE]` | Link speed unreadable — auto-negotiation failure |
| TX drop rate > 1% of total TX packets | `[CAUSE]` | Severe TX packet loss |
| TX drop rate > 0.1% of total TX packets | `[WARN]` | Elevated TX packet loss |
| RX drop rate > 1% of total RX packets | `[CAUSE]` | Severe RX packet loss |
| RX drop rate > 0.1% of total RX packets | `[WARN]` | Elevated RX packet loss |
| 2+ of: Unknown speed + carrier > 500 + TX loss at CAUSE level | `[CAUSE]` | Physical layer failure signature |
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
| Bond member with carrier changes >> bond's | `[WARN]` | Bond member link instability |
| Interface is a bond member | `[INFO]` | Bond/LAG membership context |

> Drop thresholds are **rate-based** when node_exporter provides
> `node_network_transmit_packets_total` / `node_network_receive_packets_total`
> (loss as a percentage of total traffic since boot). Absolute-count fallbacks
> (> 5000 / > 100) are used only when packet totals are unavailable, with a note
> in the finding.

## Fault localization

Runs automatically as part of every wizard invocation — no extra flag needed. After
collecting interface state and raising findings, the wizard checks six layers in order:

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
Layer 3 checks involve a brief live ping and DNS query (~2-3s total).

**Example output:**

```
================================================================
  Fault Localization -- eth0
================================================================

  Layer 1 -- Physical (cable / connector / SFP)
    Status   : SUSPECT
    Remote   : switch1.example.com port GigabitEthernet0/5
    Evidence : Unknown speed (autoneg failed); 53792 carrier changes (severe);
               RX optical power -38.5 dBm -- remote SFP or fibre degraded
    Next step: Investigate remote device/port (switch1.example.com port
               GigabitEthernet0/5); check far-end SFP and fibre connectors

  Layer 2 -- NIC Driver
    Status   : OK
    Driver   : e1000e  v3.8.7-NAPI  fw 3.25.0

  Layer 2 -- Switch Port
    Status   : UNKNOWN
    Note     : LLDP not available; no STP topology changes seen
    Next step: Check switch port error counters; try a different port

  Layer 3 -- Gateway / Router
    Status   : OK
    Gateway  : 192.168.1.1  (reachable)
    Internet : reachable (8.8.8.8)

  VPN
    Status   : Not detected

  DNS
    Status   : OK
    Resolver : 8.8.8.8  (resolved google.com)

  ----------------------------------------------------------
  VERDICT: Fault is most likely in the PHYSICAL LAYER
           (cable, SFP, or switch port).
  ----------------------------------------------------------
```

## Device Under Test (`--dut IFACE`)

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
  DUT Interface (eth1 -- device under test)
    Carrier changes: 5000  [SEVERE]   vs host eth0: 2  [normal]
    Speed          : Unknown!          vs host eth0: 1000Mb/s
    Link state     : unknown           vs host eth0: up

  ----------------------------------------------------------
  VERDICT: Fault is likely in the DUT or DUT-host cable.
           Host uplink (eth0) is stable -- the issue is not
           upstream of this computer.
  ----------------------------------------------------------
```

## Auto-apply fixes (`--fix`)

When the wizard finds `[CAUSE]` entries with safe single-command fixes, `--fix` offers to
apply them:

- **Interactive TTY** — prompts `Apply this fix now? [y/N]` per fix; escalates with `sudo` if needed
- **Non-interactive** — prints the fix command only, never auto-applies
- **Multi-step instructions** (numbered lists) are skipped — only single commands are applied

Each fix reports `[APPLIED]` or `[FAILED]` with a summary at the end.

```bash
./flap -d eth0 --fix
```

After applying a `[FIX]` command, re-run `./flap -i IFACE -w 10` to confirm the interface
has stabilised.

## Backup & rollback (`-r BACKUP_ID`)

Every wizard run automatically backs up the system network config files (netplan,
interfaces, NetworkManager connections, sysctl) before you apply any fix. Backups are
stored in `~/.local/share/link-flap/backups/` (override via `BACKUP_DIR`).

**List saved backups:**

```bash
./flap -r list
```

**Restore a backup:**

```bash
# Files in /etc/ require root to overwrite:
sudo ./flap -r 20260302-143000-eth0
```

If restoration fails due to permissions the tool exits with code 2, prints a warning for
each failed file, and shows the exact `sudo` command to retry.

Override save locations via environment variables: `BACKUP_DIR`, `REPORT_DIR`.
