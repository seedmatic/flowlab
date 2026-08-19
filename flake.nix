{
  description = "flowlab — unsampled network-flow observability appliance (pmacct probe + Akvorado collector)";

  inputs = {
    # Shared aggregator — keeps flowlab in lock-step with the rest of the
    # seedmatic family (nix-darwin-home, rke2lab): nixpkgs + everything else we
    # borrow (flox, sops-nix, nixos-generators, disko, …) flow from here rather
    # than pinning our own. We only wire `follows` for the inputs we actually
    # consume today; the rest are pulled from flake-commons when a module needs them.
    flake-commons.url = "github:seedmatic/nix-flake-commons/develop";
    nixpkgs.follows = "flake-commons/nixpkgs";

    # Akvorado is flowlab-specific — referenced DIRECTLY here, deliberately NOT
    # pushed up into flake-commons: flowlab is the only project that consumes it.
    # The upstream flake ships the ready-built backend (Go binary with the pnpm
    # console embedded) as `packages.<system>.backend`, so we do no packaging —
    # only a `services.akvorado` module (see modules/akvorado.nix). Pinned to the
    # PoC's release tag so the config schema matches what we proved.
    #
    # We deliberately do NOT make akvorado follow our nixpkgs: that broke its
    # Go-modules fixed-output hash (vendorHash mismatch — its FOD is calibrated
    # against its own pinned nixpkgs). It builds against its own nixpkgs; we
    # consume only the resulting binary, so a second nixpkgs in the closure is fine.
    akvorado.url = "github:akvorado/akvorado/v2026.8.0";

    # ndh (nix-darwin-home) is the resolved source of truth for the home-LAN host
    # inventory: its catalog PROJECTS rke2lab's cluster blueprint AND adds the
    # daily-driver reservations, so `ndh.catalog.netplan.lan.hosts` is the complete
    # name→IP map (rke2lab alone only carries the cluster nodes). We consume its
    # catalog to label our own side with per-host names in the flow console — no
    # darwin build is realized.
    #
    # This is a MUTUAL (federated) dependency: nnh reads ndh's catalog while ndh
    # reads nnh's `lib.networkBlueprint` (its own `nnh` input). That cycle is broken
    # with `inputs.nnh.follows = ""` — an empty follows resolves to the ROOT flake
    # (this one), a fixpoint that terminates the recursion (see the hub memory
    # flake-mutual-dependency-follows-root). `inputs.flake-commons.follows` dedupes the
    # shared aggregator so ndh and nnh resolve the SAME nixpkgs/flox/… tree instead of
    # locking a second copy.
    ndh = {
      url = "github:seedmatic/ndh/develop";
      inputs.nnh.follows = "";
      inputs.flake-commons.follows = "flake-commons";
    };
  };

  outputs =
    inputs@{ self, nixpkgs, akvorado, ndh, ... }:
    let
      lib = nixpkgs.lib;

      # The probe runs on the bare-metal vz Mac (it MUST capture the host's own
      # physical en0 — see pkgs/nnh-probe.nix); the collector is a NixOS
      # Incus instance on nikopol-nixos (a Linux VM on the same Mac).
      probeSystem = "aarch64-darwin";
      collectorSystem = "aarch64-linux";

      probePkgs = nixpkgs.legacyPackages.${probeSystem};

      # ── Probe (migrated from ndh; flowlab owns it now) ──────────────────────
      probe = probePkgs.callPackage ./pkgs/nnh-probe.nix { };

      # Deploy: push the (small) closure to the vz host over ssh, then render +
      # load the root LaunchDaemon via sudo. A push needs no reverse connection,
      # so it works from any operator wherever `ssh <vz-host>` resolves.
      # Default vz host: vzhost.nikopol.
      probeDeploy = probePkgs.writeShellApplication {
        # Binary lands in PATH (nix profile / devshell) → keep the disambiguating
        # nnh- prefix; `probe-deploy` alone is too generic. (The nix let-binding
        # above stays short — we're already in nnh.)
        name = "nnh-probe-deploy";
        runtimeInputs = [
          probePkgs.nix
          probePkgs.openssh
        ];
        text = builtins.readFile (
          probePkgs.replaceVars ./pkgs/nnh-probe.d/deploy.sh {
            bundle = "${probe}";
          }
        );
      };

      # Akvorado backend, patched for our macOS probe. pmacct on macOS can only
      # capture BOTH directions with NO pcap direction set, and in that mode it
      # cannot stamp an ifindex, so every flow arrives with InIf==OutIf==0 — which
      # upstream's enricher drops ("input and output interfaces missing"). Our
      # patch resolves those flows via a metadata lookup with ifindex 0 (the ::/0
      # static provider's `default` interface = en0/external) instead of dropping.
      # A ~25-line surgical diff kept as a patch (not a fork): we stay on the
      # pinned tag, it rebases trivially, and it's upstreamable as-is. It touches
      # no go.mod/go.sum, so akvorado's vendorHash (its own goModules FOD) is
      # unaffected — overrideAttrs only adds a patchPhase input.
      akvoradoBackend = akvorado.packages.${collectorSystem}.backend.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ./pkgs/akvorado-enricher-ifindex0.patch ];
      });

      # ── Collector image (pure nix — NO distrobuilder, NO nixos-generators) ──
      # A plain nixosSystem importing nixpkgs' lxc-container profile. The build
      # products are `config.system.build.{squashfs,metadata}`, imported into the
      # nikopol-nixos Incus daemon with:
      #   incus image import <metadata>/tarball/*.tar.xz <squashfs> --alias flowlab/collector
      # (Building the aarch64-linux image needs a linux builder.)
      # Attribution data from ndh's catalog — the SINGLE source of truth for
      # "your side" naming, consumed as pure data (no darwin build realized):
      #   segments : [{cidr,name,asn}]  → prefix→{name,asn}, most-specific-wins
      #   asns     : {"<asn>" = name}   → the canonical AS-name dictionary
      #   hosts    : name→{ip,mac,kind} → per-host /32 NetNames (daily-drivers +
      #              rke2 nodes projected from rke2lab)
      # This replaces flowlab's former hardcoded selfBase/gatewayNetworks/asns.
      # nnh keeps `ndh` as a flake input and consumes it LIVE at eval; the mutual
      # dependency (ndh unioning nnh's blueprint) is broken with reciprocal
      # `inputs.<other>.inputs.<self>.follows = ""` — added in lock-step with ndh
      # when/if nnh contributes a span (see the hub memory
      # flake-mutual-dependency-follows-root). Today nnh owns no span (both
      # instances are DHCP tenants of ndh's bare-br /25), so it is a pure consumer.
      ndhHosts = ndh.catalog.netplan.lan.hosts;
      ndhSegments = ndh.catalog.netplan.segments;
      ndhAsns = ndh.catalog.netplan.asns;

      # The pipeline is split across TWO Incus instances, both on bare-br, along a
      # failure-domain line:
      #   nnh-inlet  — ingest edge + brain (orchestrator + inlet + Kafka)
      #   nnh-outlet — store (outlet + console + ClickHouse/Redis + GeoIP)
      # Co-locating orchestrator+Kafka with the inlet makes ingest self-contained: it
      # buffers to a local Kafka and serves its own config, so a store outage loses no
      # flows. Both hosts take the same specialArgs — the inlet's attribution `let`
      # consumes the ndh* attrs (it now holds the `settings`); passing them uniformly
      # keeps the wiring simple (outlet's module ignores the extras via its `...`).
      mkCollectorSystem =
        hostFile:
        lib.nixosSystem {
          system = collectorSystem;
          specialArgs = { inherit inputs akvoradoBackend ndhSegments ndhAsns ndhHosts; };
          modules = [
            "${nixpkgs}/nixos/modules/virtualisation/lxc-container.nix"
            hostFile
          ];
        };
      inletSystem = mkCollectorSystem ./hosts/inlet.nix;
      outletSystem = mkCollectorSystem ./hosts/outlet.nix;

      # What nnh CONTRIBUTES back to ndh's catalog (the "publish" side of the
      # federation). OWNERSHIP boundary: ndh owns the bare /25 AND its carve
      # (dynamic-low 172.16.6.0/27 + static-high); nnh owns exactly ONE static
      # sub-segment inside it — the top /30, 172.16.6.124/30 (usable .125/.126) —
      # which it pins (see mkProfile's ipv4.address) and declares here. nnh publishes
      # ONLY what it owns: this /30 and its two hosts, NOT the enclosing /25 (ndh's).
      # ndh unions this segment in; akvorado's most-specific-prefix match makes the
      # /30 win over ndh's /25 for .124-.127. Self-contained BY DESIGN (it declares
      # only nnh's own /30 and never reads ndh's catalog) — else nnh's contribution
      # would depend on ndh's which depends on nnh's, a real value cycle. The mutual
      # flake dependency is broken with reciprocal
      # `inputs.<other>.inputs.<self>.follows = ""` (see the hub memory
      # flake-mutual-dependency-follows-root).
      networkBlueprint = {
        segments = [
          {
            cidr = "172.16.6.124/30";
            name = "nnh-collector";
            asn = 65000;
            hosts = [
              {
                name = "nnh-inlet";
                ip = "172.16.6.126";
              }
              {
                name = "nnh-outlet";
                ip = "172.16.6.125";
              }
            ];
          }
        ];
        asns = { }; # nnh introduces no new AS numbers
      };

      # ── Collector deploy (darwin operator tool) ─────────────────────────────
      # The Incus client is Linux-only as a daemon, but nixpkgs ships a
      # Darwin-buildable client (`incus.passthru.client`); the operator runs this
      # on the workstation and it drives the nikopol-nixos remote (creds in
      # ~/.config/incus, shared with rke2lab).
      incusClient = probePkgs.incus.passthru.client;

      # Incus profiles, generated from Nix (a heredoc would break on `''` stripping).
      # Single NIC lan0 bridged to `bare-br` — nikopol's ndh-provisioned segment
      # (.nikopol dnsmasq zone + the /24 advertised into the tailnet).
      # `ipv4.address` PINS a STATIC lease: bare-br's /25 is carved dynamic-low
      # (172.16.6.0/27, ndh's dhcp.ranges) / static-high, and the collector takes the
      # top of the static range. This stops a bare-br recreate from re-shuffling the
      # instance IPs — which had wedged akvorado's Kafka clients (advertised by name)
      # and left the probe exporting to a stale IP. Incus records the reservation in
      # bare-br's dnsmasq, and `dns.mode=dynamic` still maps nnh-*.nikopol → the pin.
      # security.nesting eases NixOS's nested systemd mounts in an unprivileged
      # container. Persistent volumes differ by role.
      mkProfile =
        { description, ipv4Address, extraDevices }:
        (probePkgs.formats.yaml { }).generate "flowlab-profile.yaml" {
          config."security.nesting" = "true";
          inherit description;
          devices = {
            root = {
              type = "disk";
              path = "/";
              pool = "default";
            };
            lan0 = {
              type = "nic";
              nictype = "bridged";
              parent = "bare-br";
              name = "lan0";
              "ipv4.address" = ipv4Address;
            };
          }
          // extraDevices;
        };

      # nnh-inlet: no persistent volumes despite running orchestrator + inlet + Kafka —
      # all of it is reconstructible (orchestrator config is baked in nix, Kafka is a
      # ≤1-day buffer that's ephemeral BY DESIGN). Nothing here needs to survive a rebuild.
      inletProfileYaml = mkProfile {
        description = "flowlab nnh-inlet (ingest edge + brain)";
        # Top of the static range: the top /30 of bare-br's /25 is 172.16.6.124/30
        # (usable .125/.126); the inlet takes .126, the outlet .125.
        ipv4Address = "172.16.6.126";
        extraDevices = { };
      };

      # nnh-outlet: the ClickHouse flow history (data) + akvorado runtime state (the
      # GeoIP mmdbs AND console.sqlite — saved filters/users) + the tailscale node
      # identity, each on its OWN project-scoped volume so an `incus rebuild` keeps
      # them (and none has to migrate the others). Without the akvorado volume,
      # /var/lib/akvorado sat on the ephemeral rootfs and every rebuild re-fetched
      # GeoIP from scratch, hammering the free tier into HTTP 429.
      outletProfileYaml = mkProfile {
        description = "flowlab nnh-outlet (store)";
        ipv4Address = "172.16.6.125"; # top /30 (172.16.6.124/30), paired with inlet .126
        extraDevices = {
          data = {
            type = "disk";
            pool = "default";
            source = "data"; # volume names are project-scoped (project nnh)
            path = "/var/lib/clickhouse";
          };
          akvorado = {
            type = "disk";
            pool = "default";
            source = "akvorado";
            path = "/var/lib/akvorado";
          };
          tailscale = {
            type = "disk";
            pool = "default";
            source = "tailscale";
            path = "/var/lib/tailscale";
          };
        };
      };

      # Builds BOTH aarch64-linux images (via the /etc/nix/machines remote builder),
      # then brings the two-instance appliance up in its own `nnh` Incus project:
      # ensures project + the outlet's persistent volumes + both profiles, imports
      # each split image (metadata + squashfs), and launches nnh-inlet + nnh-outlet
      # on bare-br — or, if an instance already exists, `incus rebuild`s it from the
      # new image (keeps the volumes, so the ClickHouse flow history survives).
      collectorDeploy = probePkgs.writeShellApplication {
        name = "collector-deploy";
        # The incus client shells out to `tar` (+ `xz`) to read each split image's
        # metadata .tar.xz on import. writeShellApplication gives a curated PATH, so
        # both must be listed (mirrors the gnutar+xz added to the flox env).
        runtimeInputs = [
          incusClient
          probePkgs.gnutar
          probePkgs.xz
          probePkgs.yq-go # robust YAML parsing of incus list output (exact-name checks)
        ];
        text = builtins.readFile (
          probePkgs.replaceVars ./pkgs/collector-deploy.d/collector-deploy.sh {
            inletMetadata = "${inletSystem.config.system.build.metadata}";
            inletSquashfs = "${inletSystem.config.system.build.squashfs}";
            inletProfile = "${inletProfileYaml}";
            outletMetadata = "${outletSystem.config.system.build.metadata}";
            outletSquashfs = "${outletSystem.config.system.build.squashfs}";
            outletProfile = "${outletProfileYaml}";
            # Chain the upstream probe deploy at the end (collector first, then probe).
            probeDeploy = "${probeDeploy}/bin/nnh-probe-deploy";
          }
        );
      };
    in
    {
      # Output attrs are SHORT — we're already in nnh, so the namespace is implicit
      # (`nix run .#probe-deploy`). Only the PATH binary keeps the nnh- prefix
      # (writeShellApplication name above) — there `probe-deploy` alone is too generic.
      packages.${probeSystem} = {
        probe = probe;
        probe-deploy = probeDeploy;
        collector-deploy = collectorDeploy;
      };

      packages.${collectorSystem} = {
        inlet-squashfs = inletSystem.config.system.build.squashfs;
        inlet-metadata = inletSystem.config.system.build.metadata;
        outlet-squashfs = outletSystem.config.system.build.squashfs;
        outlet-metadata = outletSystem.config.system.build.metadata;
      };

      # One attrset per dynamic system key: Nix can't merge two separate
      # `apps.${probeSystem}.<x>` bindings (dynamic attributes don't combine).
      apps.${probeSystem} = {
        probe-deploy = {
          type = "app";
          program = "${probeDeploy}/bin/nnh-probe-deploy";
          meta.description = "Push the nnh-probe closure to the vz Mac + load its root LaunchDaemon (pmacctd → nnh-inlet.nikopol:2055) — docs: https://github.com/seedmatic/nnh/blob/main/docs/architecture.adoc";
        };
        collector-deploy = {
          type = "app";
          program = "${collectorDeploy}/bin/collector-deploy";
          meta.description = "Build both images + bring up the two-instance appliance (nnh-inlet + nnh-outlet) on bare-br in the nnh Incus project — docs: https://github.com/seedmatic/nnh/blob/main/docs/architecture.adoc";
        };
      };

      nixosConfigurations = {
        inlet = inletSystem;
        outlet = outletSystem;
      };

      # The federation contribution ndh unions into its catalog (see the
      # networkBlueprint `let` above): nnh's two bare-br hosts, names only.
      lib.networkBlueprint = networkBlueprint;
    };
}
