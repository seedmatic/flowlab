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
# The probe reaches the collector's inlet BY NAME (nnh-inlet.nikopol:2055),
# resolved via nikopol's bare-br .nikopol DNS (the vz Mac needs a scoped
# /etc/resolver/nikopol → 172.16.6.1, provisioned by ndh). Reaching that address
# on bare-br is ndh's `baremetal-link` (vz aliased at 172.16.6.253, routed by the
# subnet router) — NOT this bundle's concern anymore.
#
# Build-time tokens (@pmacctd@, @label@, @plist@, @log@, @confDir@) are
# substituted by pkgs.replaceVars; interface/collector/version are runtime args.

# launchctl and the BSD file tools live in the macOS system paths, outside the
# writeShellApplication curated PATH.
PATH="/bin:/usr/bin:/sbin:/usr/sbin:$PATH"

collector="${1:-${NETFLOW_COLLECTOR:-}}"
interface="${NETFLOW_INTERFACE:-en0}"
version="${NETFLOW_VERSION:-9}"

if [[ -z "$collector" ]]; then
  echo "usage: nnh-probe-install <collector-host:port>" >&2
  echo "  (or NETFLOW_COLLECTOR=...; NETFLOW_INTERFACE defaults to en0, NETFLOW_VERSION to 9)" >&2
  exit 2
fi
if [[ "$(id -u)" -ne 0 ]]; then
  echo "nnh-probe-install must run as root (BPF capture on $interface + /Library/LaunchDaemons)" >&2
  exit 1
fi

umask 022
mkdir -p "@confDir@"

# pmacct config uses `key: value`; `!` starts a comment.  daemonize:false keeps
# pmacctd in the foreground so launchd KeepAlive can supervise it.
cat > "@confDir@/config.conf" <<CONF
! rendered by nnh-probe-install — do not edit
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

echo "[nnh-probe] loaded: pmacctd nfprobe on ${interface} -> ${collector} (v${version}, unsampled)  (log: @log@)" >&2
