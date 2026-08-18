# Bring the nnh netflow collector up as TWO Incus instances in its own `nnh`
# project on the nikopol-nixos remote, both attached to nikopol's `bare-br`
# segment (DHCP + a .nikopol dnsmasq name, the /24 advertised into the tailnet):
#
#   nnh-inlet  — ingest edge  (akvorado inlet only; receives the probe's NetFlow)
#   nnh-outlet — store/backend (orchestrator+outlet+console + Kafka/ClickHouse/Redis)
#
# Rendered by pkgs.replaceVars from flake.nix (tokens @inletMetadata@/@inletSquashfs@/
# @inletProfile@ + @outletMetadata@/@outletSquashfs@/@outletProfile@ = the two
# nix-built images + profile yamls; @probeDeploy@ = the probe deploy tool).
#
# Ensures project + the outlet's persistent volumes + both profiles, imports each
# split image (metadata + squashfs), then launches — or, if an instance already
# exists, `incus rebuild`s it from the new image (which keeps the volumes, so the
# ClickHouse flow history survives updates). The two instances address each other
# BY NAME (nnh-outlet.nikopol) via the bare-br dnsmasq — no static IPs.
set -euxo pipefail

remote="${1:-nikopol-nixos}"
vz_host="${2:-vz.nikopol}"
project=nnh
pool=default
# The probe exports to the inlet BY NAME (resolved via the bare-br .nikopol zone /
# the vz Mac's scoped resolver) — no static IP, per the DHCP + DNS design.
inlet_addr=nnh-inlet.nikopol

inlet_metatar=$(echo @inletMetadata@/tarball/*.tar.xz)
inlet_rootfs=$(echo @inletSquashfs@/*.squashfs)
outlet_metatar=$(echo @outletMetadata@/tarball/*.tar.xz)
outlet_rootfs=$(echo @outletSquashfs@/*.squashfs)

# Existence checks parse YAML with yq (robust): the CSV `name` column decorates the
# CURRENT project as "nnh (current)", so a plain grep misses it and a create then
# fails "already exists". `yq -e … select(.name == …)` exits 0 only on exact match.

# 1. Project (features.networks=false by default → reuses default's bridges incl. bare-br).
if ! incus project list "$remote": --format yaml \
     | yq -e ".[] | select(.name == \"$project\")" >/dev/null 2>&1; then
  incus project create "$remote":"$project"
fi

# 2. Persistent volumes — the STORE node only (ClickHouse history + akvorado state
#    + tailnet identity), so its rebuilds are non-destructive. The inlet is
#    stateless and needs none.
volumes=(data akvorado tailscale)
for volume in "${volumes[@]}"; do
  if ! incus storage volume list "$remote":"$pool" --project "$project" --format yaml \
       | yq -e ".[] | select(.name == \"$volume\" and .type == \"custom\")" >/dev/null 2>&1; then
    incus storage volume create "$remote":"$pool" "$volume" --project "$project"
  fi
done

# 3. Profiles (one per role): create if absent (yq exact-name check), then edit —
#    `incus profile edit` replaces wholesale, so the edit is idempotent.
ensure_profile() {
  local name=$1 yaml=$2
  if ! incus profile list "$remote": --project "$project" --format yaml \
       | yq -e ".[] | select(.name == \"$name\")" >/dev/null 2>&1; then
    incus profile create "$remote":"$name" --project "$project"
  fi
  incus profile edit "$remote":"$name" --project "$project" <"$yaml"
}
ensure_profile inlet @inletProfile@
ensure_profile outlet @outletProfile@

# Import an image only when the built image actually changed, then launch the
# instance on first run — otherwise rebuild only when it isn't already on the
# current image. incus computes its own fingerprint (not a sha256 of our
# artifacts) and rejects a duplicate, so re-uploading ~1 GB for an identical build
# is wasteful AND an error; we tag each image with our nix build id (the squashfs
# store path) and skip the import when unchanged. The rebuild signal is the alias
# fingerprint vs the instance's volatile.base_image — robust even if a previous
# rebuild was interrupted. rebuild requires the instance stopped; volumes are
# separate devices, so they stay attached and the history survives the rootfs swap.
deploy_instance() {
  local name=$1 alias=$2 metatar=$3 rootfs=$4 profile=$5
  local build_id
  build_id=$(basename "$(dirname "$rootfs")")

  if [ "$(incus image get-property "$remote":"$alias" user.flowlab.build --project "$project" 2>/dev/null || true)" = "$build_id" ]; then
    : "[collector-deploy] image $alias unchanged ($build_id) — skipping import"
  else
    incus image delete "$remote":"$alias" --project "$project" 2>/dev/null || true
    incus image import "$metatar" "$rootfs" "$remote": --alias "$alias" --project "$project"
    incus image set-property "$remote":"$alias" user.flowlab.build "$build_id" --project "$project"
  fi

  if ! incus list "$remote": --project "$project" --format yaml \
       | yq -e ".[] | select(.name == \"$name\")" >/dev/null 2>&1; then
    incus launch "$alias" "$remote":"$name" --project "$project" --profile "$profile"
  elif [ "$(incus image list "$remote":"$alias" --project "$project" --format yaml | yq '.[0].fingerprint')" \
       != "$(incus config get "$remote":"$name" volatile.base_image --project "$project" 2>/dev/null || true)" ]; then
    incus stop "$remote":"$name" --project "$project" || true
    incus rebuild "$alias" "$remote":"$name" --project "$project"
    incus start "$remote":"$name" --project "$project"
  else
    : "[collector-deploy] instance $name already on the current image — no rebuild"
  fi
}

# Store node first (it runs the orchestrator the inlet fetches its config from),
# then the ingest edge.
deploy_instance nnh-outlet outlet "$outlet_metatar" "$outlet_rootfs" outlet
deploy_instance nnh-inlet inlet "$inlet_metatar" "$inlet_rootfs" inlet

# Deploy the UPSTREAM probe on vz, pointed at the inlet BY NAME. Ordered AFTER the
# launch on purpose: the inlet must be listening on :2055 (after it has fetched its
# config from the orchestrator) before the probe starts exporting (UDP is
# fire-and-forget). Interactive — the probe deploy runs `ssh -t vz sudo …`.
@probeDeploy@ "$vz_host" "$inlet_addr":2055

: "[collector-deploy] done — console http://nnh-outlet.nikopol:8083 , NetFlow $inlet_addr:2055/udp"
