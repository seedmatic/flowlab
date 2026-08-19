---
name: probe-collector-transport
description: "Probe→collector NetFlow export must ride a stable private host↔VM link, not the carrier-DHCP hotspot network"
metadata: 
  node_type: memory
  type: project
  originSessionId: b815b873-be9b-4c32-b955-d58288560a9e
  modified: 2026-08-15T15:46:35.163Z
---

Confirmed topology (2026-08-15): `nikopol` is a **company-provided MacBook** (bare metal =
`vz.nikopol`) that connects to Android hotspots → its physical IP changes per hotspot.
`nikopol-nixos` is a **Linux VM on that same MacBook** (Apple Virtualization / `vz` backend),
running Incus; the collector is an Incus instance inside it.

**The stability tension (the crux):** in rke2lab the node's stable IP comes from being in the
**tailnet**. But the probe MUST run on `vz` (to capture the host's own en0), and **`vz` cannot
join the tailnet** — it's a company machine and the user will NOT run an unauthorized VPN. So the
probe can reach the collector neither via the tailnet (vz excluded) nor via a stable hotspot IP
(it changes). The ONLY stable path is **machine-local**: `vz` and the guest are the same MacBook.

**Hard constraint (2026-08-15):** tart/vz can attach **only ONE** NIC to the VM, and it is
**bridged to the macOS Wi-Fi LAN service (en0)**. So: no second host↔VM link is possible, and
`vmnet-br` (10.80.8.0/21, nat=false) is **internal to the guest** (inter-instance only),
**unreachable from `vz`** — extending it to vz is impossible. BUT `vz`'s en0 and the VM's single
bridged NIC (hence the collector on `lan-br`) sit on the **SAME L2 segment** (the Wi-Fi bridge) —
proven by the probe reaching `192.168.1.34` (no AP client-isolation).

**Decision (FINAL): a static parallel /30 subnet on that shared Wi-Fi L2** — a "poor-man's VLAN"
by static addressing (802.1Q is impossible over Wi-Fi). Only two hosts exchange packets:
- `vz` en0 alias = **`172.16.6.1/30`**
- collector (lan0) = **`172.16.6.2/30`**  (net `172.16.6.0/30`, bcast `.3`, 2 usable hosts)

The probe exports to **`172.16.6.2:2055`** (replaces the DHCP `192.168.1.34`). The Akvorado inlet
binds :2055 **directly** on `172.16.6.2` (NO proxy device — honour the "bind directly, no
netavark/NAT hop" learning). Static on both ends → **independent of hotspot DHCP**, no VPN, no
second NIC, no tailnet. Rejected alt: IPv6 link-local `fe80::` (stable but pmacct handles the
`%en0` scope poorly).

**Subnet chosen 2026-08-15 in `172.16.0.0/12`** (was 10.66.6.0/30): conflict-checked against
nikopol's rke2lab netplan — it uses only `10.80.0.0/20` (vmnet segments) + `192.168.1.0/24` (LAN);
`172.16.x` is used by neither, and a phone hotspot almost never hands out `172.16.x`, so collision
risk is negligible. (rke2's internal k8s CIDRs 10.42/10.43 are cluster-internal, not on this L2.)

**Both ends stay INSIDE nnh (no nix-darwin-home dependency):**
- collector side = nnh's NixOS image (static `10.66.6.2/30` on lan0 + inlet bind).
- `vz` side = folded into the **probe bundle** — a root LaunchDaemon adds the en0 alias
  `10.66.6.1/30` and re-applies it on Wi-Fi re-association (macOS may flush aliases on reassoc).

**Why:** stable export target without tailnet/VPN + isolation of telemetry from the measured
uplink. **How to apply:** TRANSPORT only — `pmacctd` still captures `en0` for the measurement
(see [[probe-belongs-to-nnh]]). Incus project design + reuse of vmnet-br/lan-br: see
[[incus-project-nnh]]. The user's "VLAN" = this machine-local host↔VM link, not 802.1Q
(impossible over a carrier hotspot).
