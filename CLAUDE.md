# flowlab

Uplink network-flow observability appliance. **Goal:** understand and verify what this
MacBook actually consumes toward the internet over its uplink — the Android hotspot today —
with **exact, UNSAMPLED byte accounting per destination over time**, to explain surprises
(e.g. 60 GB in a week) and confirm that future carrier bills match reality. Sampling is
banned: sampled flows only estimate bytes.

## Architecture

```
Probe (bare metal, macOS)  ──NetFlow v9──▶  Collector appliance (NixOS/Incus)  ──▶  UI
  pmacctd on en0 (uplink)                     Akvorado (interchangeable)
```

- **Probe** — `pmacctd` (pmacct `nfprobe` plugin, `sampling_rate: 1` = unsampled) captures the
  bare-metal Wi-Fi `en0` and exports NetFlow v9. It **must** run on the bare metal: the MacBook's
  own unicast to the gateway only exists on the host's physical interface; a bridged guest never
  sees it (switched L2). Packaged as a nix bundle + root LaunchDaemon (migrated from `ndh`).
- **Collector** — Akvorado (`inlet` → Kafka/KRaft → `outlet` → ClickHouse; `console`). The
  collector is **interchangeable** — hence `flowlab`, not `akvorado`. Runs **native on a NixOS
  Incus instance** (systemd services, **no Docker/podman** — see learnings). Reachable via a
  dedicated bridged IP or an Incus `proxy` device for UDP :2055.
- **Target** — eventual move to the `nikopol-wrkld` rke2 cluster (WIP in `rke2lab`).

## Hard-won learnings — READ before touching networking or the pipeline

- **Never run the collector under podman/netavark.** The netavark hostport **UDP** DNAT is
  unreliable (delivered 2042 flows, then 4 bytes after a network recreate) and was the root cause
  of a long "capture-loss" red herring. Native systemd (inlet binds `:2055` directly) — or real
  Docker — avoids it. This is *the* reason for the NixOS-native design.
- **Akvorado enricher gates** (`outlet/core/enricher.go`): a flow is dropped unless it has
  (1) `InIf` **or** `OutIf` ≠ 0, (2) exporter metadata, (3) a sampling rate. With no SNMP on the
  probe, satisfy them with:
  - pmacct `pcap_ifindex: map` + an `interfaces.map` assigning ifindex 1 to `en0`;
  - Akvorado `outlet.metadata.providers: [{type: static, exporters: {"::/0": {name, ifindexes,
    boundary: external}}}]` — **`::/0` catch-all** because the exporter IP changes with the network;
  - `outlet.core.default-sampling-rate: 1`.
- **pmacct `interfaces.map` on macOS**: use **TWO** entries (`direction=in` **and** `direction=out`).
  A single `direction=in` entry triggers `pcap_setdirection()`, whose macOS implementation drops
  most packets. On macOS the 2nd (out) handle "gives up" → one handle captures everything
  promiscuously with `in_iface` set → complete + no double-count.
  ⚠️ **pcap capture completeness on macOS is still UNVERIFIED** — validate it once the collector
  endpoint is reliably native (a clean 20 MB download must show ~20 MB captured).
- **Addressing is network-dependent** (hotspot = carrier DHCP, every IP changes): keep the
  exporter key `::/0`; the "internet only" view excludes RFC1918 + bogons (network-agnostic).
- **Enrichment / names**: Akvorado has **no reverse-DNS**. Use ASN + GeoIP instead —
  IPinfo free (`country asn`, shared token baked in the compose overlay) for AS names
  (`13335: Cloudflare`…), and the **wp-statistics GeoLite2-City** mirror (MaxMind mmdb, free, no
  key: `cdn.jsdelivr.net/npm/geolite2-city/GeoLite2-City.mmdb.gz`) for city/state. Read downloads
  by **Src AS** (your side shows as your ISP's AS = "you").

## Layout (planned)

- `flake.nix` — inputs: `nixpkgs` + `akvorado` (upstream flake, pinned; provides `packages.<sys>.backend`)
- `modules/akvorado.nix` — a `services.akvorado` module: 4 systemd units (orchestrator/inlet/outlet/console)
- `hosts/<node>.nix` — NixOS config: akvorado + `services.clickhouse` + `services.apache-kafka` (KRaft) + `services.redis`
- `config/akvorado.yaml` — rendered from nix (the proven config)
- `pkgs/netflow-probe*` — the pmacct probe bundle + deploy (migrated from `ndh`)
- image — Incus NixOS image (`nixos-generators`)

## What nixpkgs already provides (reuse, don't rebuild)

`services.clickhouse`, `services.apache-kafka` (v4, KRaft via `clusterId`/`formatLogDirs`),
`services.redis`/`valkey`. Missing (we write): the `akvorado` **package** is solved by the
upstream flake's `backend`; only a `services.akvorado` **module** must be authored (nobody
has one — see akvorado discussions #1740).

## Conventions

- **External-worktree operating model** (rke2lab is the reference): bare at
  `git-bare-store/seedmatic/flowlab.git`, worktrees at
  `git-worktree-store/seedmatic/flowlab.d/<namespace>/<branch>`, **relative paths**. Each
  conversation gets its own worktree; treat `main` as read-only reference. Creating/removing a
  worktree + its `.code-workspace` (and Bedrock backend selection) is the **`worktree` skill**.
- **Handoffs are non-git**, named `<worktree>.handoff`, living beside the worktree in the
  `flowlab.d/` container — never committed.

# Common instructions (shared via the claude-hub subtree)

@.claude/hub/instructions.md
