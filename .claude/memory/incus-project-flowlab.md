---
name: incus-project-flowlab
description: "flowlab runs in its OWN separate Incus project on nikopol-nixos, reusing default's bridges without touching rke2lab"
metadata: 
  node_type: memory
  type: project
  originSessionId: b815b873-be9b-4c32-b955-d58288560a9e
  modified: 2026-08-15T17:12:57.125Z
---

flowlab runs in its **own separate Incus project** on the `nikopol-nixos` remote, NOT inside
rke2lab's cluster/project. (Dependency inversion — flowlab moving onto the cluster — comes LATER,
only once rke2lab has grown the `nikopol-wrkld` rke2 cluster. For now: isolated.)

Live state observed 2026-08-15 (remote `nikopol-nixos`, `https://nikopol-nixos:8443`):
- Projects: `default`, `rke2lab`. → create `flowlab`.
- Networks live in the `default` project: `vmnet-br` (managed bridge `10.80.8.1/21`,
  `ipv4.nat=false`, `ipv6.nat=true`, static IPs via `raw.dnsmasq` MAC reservations — master=.10,
  peers=.11-.13, workers=.20/.21; free ranges .2-.9 and .31-.15.254) and `lan-br` (unmanaged
  bridge → the hotspot LAN 192.168.1.x). `podman1/2` bridges are dead relics of the old podman
  collector. rke2 instances are dual-homed: `lan0`→lan-br (internet), `vmnet0`→vmnet-br (stable).

**Project design (no rke2lab resources mutated):**
- `incus project create nikopol-nixos:flowlab` → defaults give `features.networks=false`, so the
  project **reuses `default`'s `lan-br`** — no network duplication, no touch to rke2lab.
- A `flowlab` profile, collector on a **SINGLE NIC** `lan0`→`lan-br` (the shared Wi-Fi L2), with a
  pinned `hwaddr` (stable MAC, flowlab-distinct). No `vmnet0` — `vmnet-br` is internal inter-instance
  and the collector is a standalone appliance that doesn't talk to rke2 nodes.
- The collector instance = flowlab's nix-built LXC image, imported into project `flowlab`.

**Networking (finalized with the transport redesign):** the collector's `lan0` gets hotspot DHCP
(192.168.1.x, outbound only — for the GeoIP fetch) PLUS a **static secondary `172.16.6.2/30`
configured INSIDE the NixOS image** (systemd-networkd, in hosts/collector.nix) — NOT via Incus,
because `lan-br` is unmanaged (the hotspot router owns its DHCP; Incus can't manage the 172.16.6.0/30
overlay). The Akvorado inlet binds :2055 on 172.16.6.2. This is the probe↔collector path — see
[[probe-collector-transport]]. Incus/remote reuse pattern: see [[build-reuse-decisions]].

**Storage (decided 2026-08-15): reuse the existing `default` pool** (driver ZFS, source dataset
`tank/nerd/incus`, provisioned in ndh, shared with rke2lab). No ndh change — Incus creates a ZFS
sub-dataset per volume/instance under `tank/nerd/incus/…`, and project scoping keeps flowlab's data
separate. Rejected a dedicated `tank/nerd/flowlab` dataset/pool (would give own compression/quota/
snapshots for the growing flow history, but costs a cross-repo ndh change) — can revisit later.

**Persistent data volume:** a custom volume `data` on the `default` pool, attached in the
profile as a disk device mounted at `/var/lib/clickhouse` (the accumulated flow history — the
appliance's raison d'être). So image updates are non-destructive: `incus rebuild collector
collector` replaces the rootfs from a new image but KEEPS the volume.

**Full resource model (imperative via `collector-deploy`, no Pulumi):**
1. project `flowlab` (features.networks=false).
2. volume `data` (pool default).
3. profile `flowlab`: root disk (pool default) + NIC `lan0` (bridged, parent lan-br, pinned hwaddr,
   device name MUST be `lan0` to match hosts/collector.nix networking) + the `data` disk
   device at /var/lib/clickhouse.
4. image `collector` (imported from the nix build: metadata + squashfs).
5. instance `collector` (from the image, project flowlab, profile flowlab).

Deployment: a `collector-deploy` flake app (mirrors `netflow-probe-deploy`, darwin, uses the flox
incus client + the remote build) — build the image, ensure project/volume/profile, `incus image
import`, then `launch` (first time) or `rebuild` (update; volume preserved), driven through the
`nikopol-nixos` remote.
