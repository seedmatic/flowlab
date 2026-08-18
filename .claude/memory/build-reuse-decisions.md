---
name: build-reuse-decisions
description: "How flowlab reuses ndh (probe) and rke2lab (incus) — migrate the probe, flox-ref rke2lab's incus-client, build the Incus image directly via nix"
metadata: 
  node_type: memory
  type: project
  originSessionId: b815b873-be9b-4c32-b955-d58288560a9e
  modified: 2026-08-15T15:12:33.053Z
---

Reuse/ownership decisions confirmed 2026-08-15:

- **netflow-probe → MIGRATED into flowlab** (copied, NOT imported as a flake input). flowlab owns
  the probe now; the ndh copy lives on the unmerged `feature/netflow-monitoring` branch and is
  destined to be retired. Rejected importing `inputs.ndh` because it would pin flowlab to an
  unmerged branch and drag ndh's entire input closure (~9 MB lock, Pulumi/darwin/fleet) for a
  ~150-line self-contained package (pmacct = stock nixpkgs). See [[probe-belongs-to-flowlab]].

- **rke2lab incus → reused via flox `.flake` github ref, NOT a nix flake input.** rke2lab surfaces
  `incus-client = pkgs.incus.passthru.client` from its own flake; its flox manifest installs it via
  `incus-client.flake = "github:nxmatic/rke2lab#incus-client"` (github ref, not `path:.`, for a
  portable lock). flowlab's `.flox` does the **same line**, consuming rke2lab's output. No heavy
  nix input, no duplication of the one-liner.

- **Incus remote is shared operator state**, not scripted: one-time
  `incus remote add nikopol https://nikopol-nixos.local:8443` (remote label = cluster name)
  populates `~/.config/incus/config.yml` + `servercerts/`. Same operator, same nikopol host → flowlab
  reads the **same `~/.config/incus`** rke2lab already uses. The collector is just another instance
  in the existing nikopol-nixos Incus daemon.

- **Incus image built DIRECTLY via nix** (user correction 2026-08-15): follow rke2lab's pattern —
  `nixpkgs.lib.nixosSystem` + `${nixpkgs}/nixos/modules/virtualisation/lxc-container.nix` →
  `config.system.build.{squashfs,metadata}` → `incus image import`. **NO distrobuilder, NO
  nixos-generators** (both rejected). Image build needs an aarch64-linux builder.
