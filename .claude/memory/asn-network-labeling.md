---
name: asn-network-labeling
description: "How flowlab labels \"your side\" — private ASes (home/rke2-cluster/gateway) + per-host names from ndh's catalog; geoip 10/day download cap"
metadata: 
  node_type: memory
  type: project
  originSessionId: b815b873-be9b-4c32-b955-d58288560a9e
  modified: 2026-08-16T04:54:26.095Z
---

**Goal:** stop the console showing "0: ???" for our own side. Two Akvorado dimensions:
- **AS** (SrcAS/DstAS, named via the `asns` ClickHouse dictionary = `outlet`→`clickhouse.asns`).
- **NetName** (SrcNetName/DstNetName, from the `networks` provider = `outlet.networks.networks`).

**ASN scheme — reuse rke2lab's Cilium BGP numbering** (found in rke2lab
`CiliumAdvancedManifestsUnit.java`: `localASN 65010`, `peerASN 65020`):
- `65000` = **home** (personal machines + any other private address; our umbrella/fallback).
- `65010` = **rke2-cluster** (== Cilium localASN). By-ROLE label: a cluster node's LAN /32 gets it.
- `65020` = **gateway** (== Cilium peerASN, the vmnet gateway `10.80.0.1`). Declarative — nodes
  egress to internet via the **home LAN** (Bbox `192.168.1.254`, route metric 1006 < the vmnet
  `10.80.8.1` metric 1008 backup), so `10.80.x`/65020 only shows up on failover.

**Implementation** (`hosts/collector.nix`, `let` block):
- `selfBase` = broad private ranges (`10/8, 172.16/12, 192.168/16, 100.64/10, 169.254/16, fc00::/7,
  fe80::/10`) → `{asn=65000; name="home"}`. **Network-agnostic** (covers hotspot carrier-private too;
  same rationale as the "internet only" filter). Deliberately NOT from the blueprint — see TODO.
- `hostNetworks` = per-host `/32` from **`ndh.catalog.netplan.lan.hosts`** (flake input
  `ndh = github:seedmatic/ndh/develop`, pure-data attr only, no darwin build). ndh ALREADY merges
  daily-drivers + rke2 cluster nodes (projected from `rke2lab.lib.networkBlueprint`) → 17 hosts. Each
  /32 sets `name`; `kind=="rke2"` also sets `asn=65010`; others inherit `65000` (akvorado merges
  attributes per-prefix, most-specific-wins).
- `gatewayNetworks` = `10.80.0.1/32 → {asn=65020; name="gateway"}` (hardcoded; not in ndh's LAN
  catalog; declarative).
- `clickhouse.asns` names the three: `65000 home`, `65010 rke2-cluster`, `65020 gateway`.

VALIDATED live (2026-08-15): `192.168.1.1(vz)→internet` = SrcAS 65000 / SrcNetName "home";
`nikopol↔bioskop` = per-host NetNames. `SYSTEM RELOAD DICTIONARY asns` applies name changes at once.

**GeoIP source — SWITCHED off IPinfo to a tokenless mirror.** IPinfo's free token capped
*downloads* at **10/DAY** (rolling ~24h, NOT UTC-midnight); repeated `incus rebuild`s re-fetching
(geoip was on ephemeral rootfs) burned it → `429` → asn.mmdb empty → internet dests `DstAS 0`. Fix
(deployed live via manual seed; codified in config, redeploy pending):
- ASN db now from **`https://cdn.jsdelivr.net/npm/@ip-location-db/geolite2-asn-mmdb/geolite2-asn.mmdb`**
  (jsdelivr, tokenless, no rate limit; MaxMind field format — akvorado reads it via its non-ipinfo
  `maxmindDB` path, confirmed in `outlet/geoip/database.go`). IPinfo token plumbing removed end-to-end.
- **2nd persistent volume `akvorado`** at `/var/lib/akvorado` (geoip + `console.sqlite`), separate
  from the ClickHouse `data` volume (different lifecycles). `geoip-fetch.sh` idempotent (skip if
  present & <30d). VALIDATED live: Cloudflare 13335 / Fastly 54113 / Bouygues 5410 / GitHub / Amazon
  all resolve; your own IPv6 side resolves to `5410 Bouygues Telecom ISP`.
- `console.default-visualize-options`: internet-only filter + `limit-type avg` (== ordered by total)
  + Src/Dst AS dims. (Saved filters can't carry sort; the row table has no column-click sort.)

**TODO — consolidate the network blueprint (rke2lab session):** the `selfBase` CIDR list + the
segment→ASN mapping should be a SINGLE source of truth in rke2lab's blueprint (extended with
segments + ASN assignments + pod/service CIDRs + the daily-drivers/home devices), projected by ndh
AND flowlab. The current hardcode is the transitional bridge. Full brief + the mDNS/Bbox-DNS LAN
inventory (vz=.1 nikopol-vzhost, zecoute .5, huematic .6, iPad/iPhone/Pixel…) are in the non-git
`flowlab.d/blueprint-consolidation.handoff`. See [[pcap-capture-direction-macos]] for the probe side.
