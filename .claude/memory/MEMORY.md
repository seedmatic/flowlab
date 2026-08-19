# nnh — project memory

**Naming:** the repo/project is referenced as **`nnh`** (github:seedmatic/nnh), NOT
"flowlab". Some code strings still say "flowlab" (flake `description`, the `flowlab
nnh-*` profile descriptions, the docs title) — cosmetic cleanup pending.

Auto-loaded index of nnh-specific working memory (cross-cutting facts live in the
hub, `.claude/hub/memory/`, via `[[hub:name]]`). See `CLAUDE.md` for the architecture and
the hard-won learnings (pmacct/Akvorado, the netavark-UDP pivot to NixOS-native, the
enricher gates, macOS pcap direction, ASN/GeoIP enrichment).

## Active

- **Collector LIVE — two-instance failure-domain split (deployed 2026-08-18)** — the appliance
  runs on nikopol-nixos in the **`nnh`** Incus project (`nix run "path:$PWD#collector-deploy"`),
  as TWO instances named `inlet`/`outlet` (bare-br `.nikopol` names `nnh-inlet`/`nnh-outlet` via
  dns.mode=dynamic). Split by failure domain, not workload weight: **`inlet` = orchestrator +
  akvorado-inlet + Kafka** (self-contained ingest edge — buffers to a local Kafka + serves its own
  config, so a store outage loses no flows); **`outlet` = akvorado-outlet + console + ClickHouse +
  Redis + GeoIP** (the only irreplaceable state → the sole node with persistent volumes). Arbitration:
  ClickHouse = the key store (reconstruct-from); Kafka = ≤1-day buffer, ephemeral on the edge.
  Cross-instance by NAME: kafka `nnh-inlet.nikopol:9092`, CH `nnh-outlet.nikopol:9000` (CH
  `listen_host=0.0.0.0` so the remote orchestrator provisions it), orchestrator `nnh-inlet.nikopol:8080`.
  **Full topology + rationale + all C4 diagrams live in `docs/architecture.adoc`** (the source of truth).
- **pcap completeness — FIXED + VALIDATED** — the probe was INBOUND-ONLY (uploads lost); fixed
  2026-08-15 via a single no-direction `interfaces.map` + the akvorado enricher ifindex-0 patch
  (`pkgs/akvorado-enricher-ifindex0.patch`, wired via `overrideAttrs`). Proven: OUTBOUND flow now
  in ClickHouse. See [pcap-capture-direction-macos](pcap-capture-direction-macos.md) (also records
  why pktap + forking akvorado were rejected). Separate open item: `nc`/python bulk vz↔bioskop
  stalls ~146 KB (Wi-Fi/bridge path), irrelevant to hotspot-uplink accounting.

- **ASN/NetName labeling + GeoIP — DEPLOYED & VERIFIED (2026-08-19)** — "your side" named from
  `ndh.catalog` (private ASes `65000 home` / `65010 rke2-cluster` / `65020 gateway` + per-host
  NetNames, incl. cross-segment like `vzhost.bioskop`). GeoIP now WORKS (bare-br egress fixed → the
  `akvorado-geoip` fetch lands asn+City mmdbs, idempotent "present and fresh" skip): internet dests
  resolve real ASes (Amazon 14618, Cloudflare 13335, GitHub 36459, Bouygues 5410). See
  [asn-network-labeling](asn-network-labeling.md). Reading the flows: console default = Outbound,
  `Src NetName → Dst AS` (see docs/architecture.adoc "Reading the flows").
- **Instance IPs are PINNED (static /30) — do NOT let them go DHCP** — see
  [bare-br-addressing-pin](bare-br-addressing-pin.md). An ndh bare-br recreate churned the unpinned
  instances and broke the pipeline twice (akvorado name-advertised Kafka wedged + probe on stale IP).
  Now inlet=172.16.6.126 / outlet=172.16.6.125, pinned via Incus `ipv4.address`, out of ndh's new
  dynamic `/27` pool. This is the day's key hardening.
- **flake.lock is bloated (~12k nodes) — root cause = flake-commons, DEFERRED fix** — the whole
  family (nnh/ndh/rke2lab locks ~identical) inherits ~1990 duplicate nixpkgs from the shared
  aggregator `flake-commons` (13 of its 28 inputs keep their own nixpkgs). ndh/rke2lab are ALREADY
  clean (they follow flake-commons); a downstream `follows` from nnh is useless (tried: −8 nodes). The
  fix belongs in flake-commons and is DEFERRED (nothing broken; hygiene only) — full recipe + the
  flox/nix/determinate exclusions in [flake-commons-lock-dedup](flake-commons-lock-dedup.md).

## Design decisions

- [bare-br-addressing-pin](bare-br-addressing-pin.md) — bare-br /25 carve (ndh dynamic-low /27 /
  nnh static /30 `172.16.6.124/30` pinned via Incus `ipv4.address`) + the IP-churn incident. **Key hardening.**
- [probe-collector-transport](probe-collector-transport.md) — probe↔collector export rides a
  static /30 (172.16.6.1/2) on the shared Wi-Fi L2 (one-NIC-bridged constraint), not hotspot DHCP.
- [incus-project-flowlab](incus-project-flowlab.md) — flowlab runs in its own Incus project on
  nikopol-nixos, reusing default's bridges, without mutating rke2lab resources.
- [akvorado-proven-config](akvorado-proven-config.md) — the proven PoC Akvorado config (from the
  podman clone) + native-systemd porting deltas; source of truth for modules/akvorado.nix.
- [pcap-capture-direction-macos](pcap-capture-direction-macos.md) — macOS probe is inbound-only
  (uploads lost); root cause + the two-part fix (no-direction map + akvorado enricher.go patch). NEXT.
- [build-reuse-decisions](build-reuse-decisions.md) — migrate the probe into flowlab; flox-ref
  rke2lab's `incus-client`; shared `~/.config/incus` remote; Incus image built directly via nix
  (lxc-container.nix, no distrobuilder / no nixos-generators).
- [probe-belongs-to-flowlab](probe-belongs-to-flowlab.md) — the pmacct nfprobe bundle is
  flowlab-owned; the load-bearing macOS details (two-entry interfaces.map, sampling_rate 1, etc.).
