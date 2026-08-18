# Renders and loads the pmacct NetFlow LaunchDaemon on the bare-metal vz host
# (nikopol-vz), which lives OUTSIDE the ndh nix-darwin fleet: it has a nix store
# (receives `nix copy`) but no darwin-rebuild activation, so the config +
# interfaces.map + plist are materialised here at deploy time rather than baked
# by a system module.
#
# pmacctd captures en0 with libpcap and exports NetFlow v9 via the `nfprobe`
# plugin.  We account EVERY flow (`sampling_rate: 1` — no renormalisation) so the
# byte totals match a carrier bill.  `pcap_ifindex: map` + interfaces.map assign
# a static ifindex that the Akvorado static metadata provider resolves (no SNMP).
#
# It ALSO aliases a static /30 (NETFLOW_LINK_ADDR, default 172.16.6.1) on the
# uplink: vz cannot join the tailnet and the hotspot DHCP subnet changes, but vz
# and the collector VM share one L2 (the Wi-Fi bridge — tart/vz gives the VM a
# single bridged NIC). A static /30 on that shared L2 gives the probe a
# hotspot-independent address to reach the collector (172.16.6.2:2055). macOS
# flushes aliases on Wi-Fi re-association, so a companion LaunchDaemon re-applies
# it on every network change. See the probe-collector-transport learning.
#
# Build-time tokens (@pmacctd@, @label@, @plist@, @log@, @confDir@) are
# substituted by pkgs.replaceVars; interface/collector/version are runtime args.

# launchctl and the BSD file tools live in the macOS system paths, outside the
# writeShellApplication curated PATH.
PATH="/bin:/usr/bin:/sbin:/usr/sbin:$PATH"

collector="${1:-${NETFLOW_COLLECTOR:-}}"
interface="${NETFLOW_INTERFACE:-en0}"
version="${NETFLOW_VERSION:-9}"
# Static /30 on the shared Wi-Fi L2 — the probe's own address (peer = the
# collector, e.g. 172.16.6.2). Conflict-checked against nikopol's rke2lab netplan
# (10.80.0.0/20 vmnet + 192.168.1.0/24 LAN); 172.16.6.0/30 (in 172.16.0.0/12) is
# clear and unlikely to collide with any phone-hotspot DHCP subnet.
link_addr="${NETFLOW_LINK_ADDR:-172.16.6.1}"
link_mask="${NETFLOW_LINK_MASK:-255.255.255.252}"
link_label="io.nxmatic.netflow-link"
link_plist="/Library/LaunchDaemons/${link_label}.plist"

if [[ -z "$collector" ]]; then
  echo "usage: netflow-probe-install <collector-host:port>" >&2
  echo "  (or NETFLOW_COLLECTOR=...; NETFLOW_INTERFACE defaults to en0, NETFLOW_VERSION to 9)" >&2
  exit 2
fi
if [[ "$(id -u)" -ne 0 ]]; then
  echo "netflow-probe-install must run as root (BPF capture on $interface + /Library/LaunchDaemons)" >&2
  exit 1
fi

umask 022
mkdir -p "@confDir@"

# pmacct config uses `key: value`; `!` starts a comment.  daemonize:false keeps
# pmacctd in the foreground so launchd KeepAlive can supervise it.
cat > "@confDir@/config.conf" <<CONF
! rendered by netflow-probe-install — do not edit
daemonize: false
pcap_interfaces_map: @confDir@/interfaces.map
pcap_ifindex: map
pcap_interface_wait: true
snaplen: 128
aggregate: src_host,dst_host,in_iface,out_iface,src_port,dst_port,proto
plugins: nfprobe
nfprobe_receiver: ${collector}
nfprobe_version: ${version}
nfprobe_timeouts: general=60:maxlife=60
sampling_rate: 1
CONF

# ONE entry, NO `direction=`.  This is the only mode that captures BOTH
# directions on macOS (pmacct issue #838): a `direction=out` entry triggers
# pcap_setdirection(PCAP_D_OUT), unsupported on macOS ("Setting direction to
# outgoing only is not supported"), and `direction=in` triggers PCAP_D_IN whose
# macOS implementation drops most packets — either way capture is INBOUND-ONLY
# (uploads lost), so byte totals can't match a carrier bill.  With no direction,
# libpcap captures every packet promiscuously in both senses — complete accounting.
#
# The trade-off: pmacct only applies the map's `ifindex` when a direction is set,
# so direction-less flows are stamped in_iface=out_iface=0.  We handle that on the
# collector side — our akvorado enricher patch (pkgs/akvorado-enricher-ifindex0.patch)
# resolves ifindex-0 flows via the ::/0 static provider's `default` interface
# instead of dropping them.  (`pcap_ifindex: map` above is thus a no-op today but
# kept as the intended mechanism should macOS ever honor a direction.)
cat > "@confDir@/interfaces.map" <<MAP
ifindex=1 ifname=${interface}
MAP

chown -R root:wheel "@confDir@"
chmod 0644 "@confDir@/config.conf" "@confDir@/interfaces.map"

cat > "@plist@" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>@label@</string>
  <key>ProgramArguments</key>
  <array>
    <string>@pmacctd@/bin/pmacctd</string>
    <string>-f</string><string>@confDir@/config.conf</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>@log@</string>
  <key>StandardErrorPath</key><string>@log@</string>
</dict>
</plist>
PLIST

chown root:wheel "@plist@"
chmod 0644 "@plist@"

launchctl bootout system "@plist@" 2>/dev/null || true
launchctl bootstrap system "@plist@"
launchctl enable "system/@label@"

# ── Static /30 link to the collector ────────────────────────────────────────
# vz cannot join the tailnet and the hotspot DHCP subnet changes, but vz's ${interface}
# and the collector VM share one L2 (the Wi-Fi bridge). A static /30 aliased on
# ${interface} gives the probe a hotspot-independent address to reach the collector.
# macOS flushes interface aliases on Wi-Fi re-association, so a companion
# LaunchDaemon re-applies it at boot (RunAtLoad) and on every network change
# (WatchPaths on the SystemConfiguration store).
cat > "@confDir@/link-up.sh" <<LINK
#!/bin/sh
# rendered by netflow-probe-install — re-applies the static /30 alias.
PATH="/bin:/usr/bin:/sbin:/usr/sbin"
if ! /sbin/ifconfig ${interface} 2>/dev/null | /usr/bin/grep -q "inet ${link_addr} "; then
  /sbin/ifconfig ${interface} inet ${link_addr} netmask ${link_mask} alias 2>/dev/null || true
  echo "[netflow-link] aliased ${link_addr}/${link_mask} on ${interface}" >&2
fi
LINK
chown root:wheel "@confDir@/link-up.sh"
chmod 0755 "@confDir@/link-up.sh"

cat > "$link_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${link_label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>@confDir@/link-up.sh</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>WatchPaths</key>
  <array>
    <string>/Library/Preferences/SystemConfiguration</string>
  </array>
  <key>StandardOutPath</key><string>@log@</string>
  <key>StandardErrorPath</key><string>@log@</string>
</dict>
</plist>
PLIST

chown root:wheel "$link_plist"
chmod 0644 "$link_plist"

launchctl bootout system "$link_plist" 2>/dev/null || true
launchctl bootstrap system "$link_plist"
launchctl enable "system/${link_label}"

echo "[netflow-probe] loaded: pmacctd nfprobe on ${interface} -> ${collector} (v${version}, unsampled)  (log: @log@)" >&2
echo "[netflow-probe] link: ${link_addr}/${link_mask} alias on ${interface} (peer collector)  (${link_label})" >&2
