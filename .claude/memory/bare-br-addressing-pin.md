---
name: bare-br-addressing-pin
description: bare-br /25 carve (ndh dynamic-low / nnh static /30 pin) + the IP-churn incident that motivated it
metadata: 
  node_type: memory
  type: project
  originSessionId: 96092e5f-45fc-4c00-9f0c-15ff0123198b
  modified: 2026-08-19T15:05:15.551Z
---

**The bare-br /25 is carved dynamic-low + static-high, and nnh's two instances are
PINNED to a static /30 — because an unpinned DHCP lease churned the whole pipeline.**

Ownership (federated via [[flake-mutual-dependency-follows-root]]):
- **ndh owns** the `172.16.6.0/25` bare-br segment AND its carve: dynamic pool =
  bottom `/27` (`172.16.6.0/27`, dnsmasq `ipv4.dhcp.ranges=172.16.6.2-172.16.6.30`),
  static reservations = the high half, filled top-down. Declared in ndh
  `catalog/default.nix` (baremetal.nikopol `dynamicCidr`/`dhcpRange` +
  a `${domain}-baremetal-dynamic` segment) and applied to the live Incus network by
  `modules/nixos/baremetal-segment.nix` `bareBrConfig`.
- **nnh owns ONE static /30** at the top: `172.16.6.124/30` = `nnh-collector`
  (inlet **172.16.6.126**, outlet **172.16.6.125**). Pinned via Incus
  `ipv4.address` on the `lan0` NIC in `mkProfile` (validated: Incus honours it on a
  `parent: bare-br` bridged NIC, cross-project) AND published in
  `lib.networkBlueprint` (nnh publishes only its own /30, never ndh's /25).

**Why (the incident, 2026-08-19):** an ndh redeploy recreated bare-br → the two
instances (then plain DHCP tenants) got NEW dynamic IPs. That churn broke the
pipeline twice: akvorado advertises Kafka by NAME (`nnh-inlet.nikopol:9092`) and
wedged its clients when the name re-resolved / DNS blipped, and pmacct resolves its
`nfprobe_receiver` ONCE at start so the probe kept exporting to the stale IP. Pinning
the statics OUT of the dynamic pool makes the appliance stable across recreates.

**Recovery drill if IPs ever churn again:** pin (`collector-deploy`, or hotfix
`incus profile device set inlet|outlet lan0 ipv4.address=…`) → restart instances →
re-point probe (`nix run .#probe-deploy`, or kick `sudo launchctl kickstart -k
system/io.nxmatic.nnh-probe` on vzhost.nikopol) → akvorado restarts with the instances.
Verify end-to-end by ClickHouse freshness (`max(TimeReceived)` ≈ now) + exporter =
`172.16.6.253` (vzhost.nikopol).

**ndh reconcile mechanism:** `bareBrConfig` → JSON manifest → `incus-bare-br.sh` applies
it with a single structured `incus network edit` (+ ETag retry). The old per-key
`incus network set <k> <v>` loop was deprecated-syntax AND ETag-racy (failed mid-loop).
