# Deploy the NetFlow probe to the bare-metal vz host: push the (small) closure
# over ssh, then render + load the root LaunchDaemon via sudo. Rendered by
# pkgs.replaceVars from flake.nix (token @bundle@ = the nnh-probe closure).
#
# A push needs no reverse connection, so it works from any operator wherever
# `ssh <vz-host>` resolves. Default vz host: vzhost.nikopol.
set -euxo pipefail

vz_host="vzhost.nikopol"
# A leading non-flag arg WITHOUT a colon is the vz host; an arg WITH a colon
# (host:port) is the collector.
if (($# > 0)) && [[ "$1" != --* && "$1" != *:* ]]; then
  vz_host="$1"
  shift
fi

collector="${1:-${NETFLOW_COLLECTOR:-}}"
if [[ -z "$collector" ]]; then
  echo "usage: nnh-probe-deploy [vz-host] <collector-host:port>" >&2
  exit 2
fi

bundle=@bundle@

# --no-check-sigs is honoured because the operator account is a trusted nix user
# on the vz host.
nix copy --no-check-sigs --to "ssh-ng://$vz_host" "$bundle"

# shellcheck disable=SC2029
exec ssh -t "$vz_host" "sudo '$bundle/bin/nnh-probe-install' '$collector'"
