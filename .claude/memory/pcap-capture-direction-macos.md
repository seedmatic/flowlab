---
name: pcap-capture-direction-macos
description: macOS pmacct was INBOUND-only (uploads lost); FIXED + VALIDATED via no-direction map + akvorado enricher ifindex-0 patch
metadata: 
  node_type: memory
  type: project
  originSessionId: b815b873-be9b-4c32-b955-d58288560a9e
  modified: 2026-08-15T21:20:13.538Z
---

**✅ FIXED + VALIDATED 2026-08-15.** The two-part fix below is applied, deployed, and proven: a
vz→bioskop transfer now shows the OUTBOUND flow (`SrcAddr=192.168.1.1 DstPort=9999`, 166 KB /
144 pkts, `InIfBoundary=external ExporterName=nikopol-vz`) in ClickHouse — before the fix that
direction was entirely absent. Committed as `install.sh` (single no-direction map) +
`pkgs/akvorado-enricher-ifindex0.patch` (wired via `overrideAttrs` in flake.nix →
`akvoradoBackend`, passed to `hosts/collector.nix` as `akvoradoBackend`). CLAUDE.md learnings
corrected. History below kept for the root cause.

**MAJOR finding (2026-08-15), corrected a false CLAUDE.md learning.** The probe on `vz` captured
**INBOUND only** (downloads); **OUTBOUND (uploads) was NOT captured**. The CLAUDE.md claim that the
two-entry `interfaces.map` gives "complete" capture was WRONG — it was inbound-only. Validated
exhaustively (see [[probe-belongs-to-nnh]]).

**Root cause (macOS + pmacct 1.7.9 + Akvorado):**
- `interfaces.map` `direction=out` → pmacct calls `pcap_setdirection(PCAP_D_OUT)` → macOS: *"Setting
  direction to outgoing only is not supported on this device. Exiting."* (the daemon survives only
  because `pcap_interface_wait: true` makes that handle give up; the `direction=in` handle then runs
  → **inbound only**). pmacct issue #838: two entries (same iface, in+out) mark ALL traffic as the
  first direction anyway.
- `interfaces.map` **without** `direction` → pmacct DOES capture **both directions** (proven: vz's
  outbound `192.168.1.1 → …` appeared in a `print`-plugin CSV) — BUT stamps `in_iface=0,out_iface=0`
  (the map's `ifindex=1` is only applied when a direction is set). `pcap_ifindex: hash`/`sys` give the
  interface a non-zero index in the log but STILL stamp 0,0 on flows.
- Akvorado `outlet/core/enricher.go:83`: `if flow.OutIf == 0 && flow.InIf == 0 { skip }` → drops
  every ifindex-0 flow. And `flowExporterName` is only set inside the `if InIf!=0`/`if OutIf!=0`
  blocks (Metadata.Lookup), so even bypassing line 83, line 86 ("metadata missing") drops it. No
  config knob (unlike sampling-rate just below).
- pmacct does **NOT** support pktap (`pcap_interface: pktap` / `pktap,all` / `all` → "No such device
  exists. Exiting."). tcpdump's `-i pktap,all` DID capture both directions (75087 out + 14481 in for a
  100 MiB transfer) — so libpcap CAN, pmacct can't use it.

**THE FIX (two parts, both in our control — no pmacct C patch, no pktap):**
1. `pkgs/netflow-probe.d/install.sh`: change the interfaces.map to a **single no-direction entry**
   `ifindex=1 ifname=en0` (drop the two `direction=in`/`direction=out` lines) → captures BOTH directions.
2. **Patch Akvorado's `outlet/core/enricher.go`** (via a nix patch on the `akvorado` flake input): when
   `InIf==0 && OutIf==0`, still do `c.d.Metadata.Lookup(t, exporterIP, 0)` and, if Found (our `::/0`
   static provider's `default` interface = en0/external), set `flowExporterName`+interface and DON'T
   skip. ~10 lines. Then rebuild the collector image + redeploy + re-validate.

**Alternatives considered + rejected (2026-08-15):**
- **pktap** (per-packet ifname + direction + pid, like `tcpdump -i pktap,all`): rejected. Our nix
  pmacctd links **nixpkgs libpcap 1.10.6, NOT Apple's `/usr/lib/libpcap`** (`otool -L` confirmed) —
  upstream libpcap has none of Apple's pktap pseudo-device magic (hence "No such device exists").
  So pktap would need TWO C patches (a libpcap that emits `DLT_PKTAP` + a pmacct `DLT_PKTAP` decoder;
  pmacct's `_devices[]` table only knows EN10MB/NULL/RAW/IEEE802/LINUX_SLL), maintained as overlays.
  Its only unique win — per-process attribution — is discarded by Akvorado anyway (no process dim).
  Huge cost, no benefit for byte-per-destination accounting.
- **Forking akvorado** vs the ~25-line patch: rejected for now. A patch stays on the pinned tag,
  rebases trivially, is upstreamable; a fork means owning the whole tree + CI. Switch to a fork only
  if divergence grows to several patches.

**Validation method (bidirectional transfer):** `vz` (192.168.1.1) → `bioskop.local` (192.168.1.129,
Ethernet) over `nc -4`, port 9999, `dd bs=1M count=100`. Query ClickHouse `WHERE SrcPort=9999 OR
DstPort=9999` → BOTH directions must appear (~100 MiB outbound + ACKs). Capture completeness for vz's
OWN traffic is otherwise CONFIRMED (tcpdump en0 during a transfer = 75087 out + 14481 in).

**Separate known gap:** bridged-VM OUTBOUND is invisible (vmnet injects TX below the en0 BPF tap;
their downloads are captured). Different problem; not fixed by the above.

**Diagnostic access/tools (for next session):** `ssh vz.nikopol` works BatchMode + **sudo is NOPASSWD**.
pmacctd binary: `/nix/store/…-pmacct-1.7.9/bin/pmacctd`. Daemon = LaunchDaemon `io.nxmatic.netflow-probe`
(`/etc/pmacctd/{config.conf,interfaces.map}`, log `/var/log/netflow-probe.log`). Editing the plist needs
`launchctl bootout … && bootstrap …` (kickstart does NOT reload the plist). macOS has no `timeout`; use
`/usr/sbin/tcpdump` (full path under sudo). Best debug = a second `pmacctd -f <cfg>` with
`plugins: print, print_output: csv, print_output_file:/tmp/x.csv` (read it with sudo). The daemon
currently runs with `-d` (a manual plist edit on vz; a redeploy of the probe bundle removes it).
