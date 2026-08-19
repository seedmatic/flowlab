---
name: flake-commons-lock-dedup
description: DEFERRED family-wide fix — the ~12k-node lock bloat originates in flake-commons; how to cut it
metadata: 
  node_type: memory
  type: project
  originSessionId: 96092e5f-45fc-4c00-9f0c-15ff0123198b
  modified: 2026-08-19T15:16:33.290Z
---

**The whole seedmatic family carries a ~12k-node / ~1990-duplicate-nixpkgs flake.lock,
and the root cause is `flake-commons` (the shared aggregator) — NOT nnh/ndh/rke2lab.**
DEFERRED to a dedicated flake-commons session (nothing is broken; it's lock hygiene +
eval speed). Keep this recipe.

**Diagnosis (verified 2026-08-19):** nnh, ndh, rke2lab locks are ~identical (12131
nodes). ndh and rke2lab are ALREADY clean — every direct input does
`follows = "flake-commons/<X>"`. But that dedupes only their DIRECT use; it does NOT
reach into flake-commons's OWN inputs. Of flake-commons's 28 inputs, **13 keep their
own nixpkgs**: `bird, cachix, chromium-bin, determinate, flox, impermanence,
maven-mvnd, nix, nixos-hardware, nvfetcher, treefmt-nix, zen-browser` (→ nixpkgs_2…_1944).
A downstream `follows` can't fix it (it's one level; and consumers are already correct).

**The fix — in `flake-commons` ONLY** (`github:seedmatic/nix-flake-commons/develop`,
NOT checked out locally → clone + worktree its develop). For each SAFE under-deduped
input add:
```nix
inputs.<X>.inputs.nixpkgs.follows = "nixpkgs";   # (+ .inputs.flake-utils/systems.follows where duped)
```
SAFE to dedup: `cachix, chromium-bin, impermanence, maven-mvnd, nixos-hardware,
nvfetcher, treefmt-nix, zen-browser, bird`.
**EXCLUDE — pin nixpkgs deliberately (bootstrap-sensitive; forcing follows breaks their
build):** `flox, nix, lix-module, determinate`. (flox danger confirmed by the operator.)

**Then:** relock flake-commons + eval-check the family still builds (esp. flox resolves
its OWN nixpkgs); then `nix flake update flake-commons` in ndh/rke2lab/nnh → all inherit
the slim tree, **zero new follows downstream**.

Cross-cutting (whole family) → candidate to promote to the hub alongside
[[flake-mutual-dependency-follows-root]]. See also [[bare-br-addressing-pin]] (the day's
other flake-federation work).
