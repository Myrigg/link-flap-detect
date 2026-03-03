# Changelog

## [Unreleased] — 2026-03-03

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

### Documentation

- README: updated fault localization table to list SFP DOM and LLDP in the Physical
  layer row; updated example output to show `Remote:` line and new evidence format;
  added `ethtool` and `lldpctl` to requirements table.
- ROADMAP: extended Fault Localization ✓ Done description to cover the new Layer 1
  remote-end checks.
