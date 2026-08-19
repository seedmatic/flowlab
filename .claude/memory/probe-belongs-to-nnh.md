---
name: probe-belongs-to-nnh
description: The netflow-probe (pmacct nfprobe bundle) is owned by nnh; the load-bearing macOS details
metadata: 
  node_type: memory
  type: project
  originSessionId: b815b873-be9b-4c32-b955-d58288560a9e
  modified: 2026-08-15T15:12:45.336Z
---

The `netflow-probe` (pmacct `pmacctd` + `nfprobe` plugin, packaged as a nix bundle + root
LaunchDaemon installer for the bare-metal `vz` Mac host) **belongs to nnh**, not ndh. It
was prototyped on ndh `feature/netflow-monitoring` and migrated verbatim into `pkgs/netflow-probe*`.
See [[build-reuse-decisions]].

Load-bearing details that MUST be preserved (verified empirically 2026-08-15):

- **TWO-entry `interfaces.map`** (`direction=in` AND `direction=out` for the one NIC). On macOS
  pmacct opens one BPF handle per NIC; the 2nd (out) handle "gives up", leaving a single handle
  capturing both directions promiscuously with `in_iface` tagged. A single `direction=in` entry
  triggers `pcap_setdirection(PCAP_D_IN)` which drops ~95% of packets on macOS (2-entry captured
  9–27 MB/10min; 1-entry lost ~95% of a controlled 20 MB test).
- `sampling_rate: 1` (unsampled — bytes must match the carrier bill), `nfprobe_version: 9`.
- pmacct from **stock nixpkgs** with `.override { withNflog/withMysql/withPgSQL/withKafka/withSQLite
  = false; }` (drops Linux-only backends so it builds on Darwin; nfprobe needs only libpcap).
- Deploy: `nix copy --no-check-sigs --to ssh-ng://<vz-host>` then `ssh -t sudo .../netflow-probe-install
  <collector:port>`. Default vz host `vz.nikopol`. Runtime knobs: `NETFLOW_COLLECTOR`,
  `NETFLOW_INTERFACE` (default en0), `NETFLOW_VERSION` (default 9).
- Exposed only for `aarch64-darwin`. pcap capture COMPLETENESS on macOS still to be validated once
  the native collector endpoint is reliable (a clean 20 MB download must show ~20 MB captured).
