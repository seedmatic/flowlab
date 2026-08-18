# Unloads and removes the pmacct NetFlow LaunchDaemon on the bare-metal vz host.
# @label@ / @plist@ / @confDir@ are substituted at build time by pkgs.replaceVars.

PATH="/bin:/usr/bin:/sbin:/usr/sbin:$PATH"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "netflow-probe-uninstall must run as root" >&2
  exit 1
fi

launchctl bootout system "@plist@" 2>/dev/null || true
rm -f "@plist@"

# The companion /30-link LaunchDaemon (link-up.sh itself lives under @confDir@).
# The alias it applied is not torn down explicitly — it clears on the next Wi-Fi
# re-association / reboot once the daemon is gone.
link_plist="/Library/LaunchDaemons/io.nxmatic.netflow-link.plist"
launchctl bootout system "$link_plist" 2>/dev/null || true
rm -f "$link_plist"

rm -rf "@confDir@"

echo "[netflow-probe] removed (@label@ + io.nxmatic.netflow-link)" >&2
