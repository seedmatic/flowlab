# nnh-outlet — the store/backend instance (the "brain").
#
# Runs the orchestrator + outlet + console, plus ALL the stateful backends
# (Kafka, ClickHouse, Redis) and the GeoIP fetch. The orchestrator holds the
# whole pipeline config (this `settings` block) and serves it over :8080 to every
# daemon — including the inlet on nnh-inlet. Cross-instance addressing uses bare-br
# names (nnh-outlet.nikopol), never localhost, wherever the inlet must reach in.
#
# Attribution ("your side" naming) is derived ENTIRELY from ndh's network catalog
# (segments {cidr,name,asn} + the asns dict) — the single source of truth, no more
# hardcoded selfBase/gatewayNetworks. See flake.nix for the catalog wiring.
{
  config,
  lib,
  pkgs,
  ndhSegments,
  ndhAsns,
  ndhHosts,
  ...
}:
let
  # ── "You" as prefixes, straight from ndh's catalog ──────────────────────────
  # Each segment {cidr,name,asn} → prefix → {name,asn}. akvorado merges attributes
  # per-prefix, most-specific-wins, so broad home fallbacks (10/8 → home) coexist
  # with the finer cluster /27s (→ rke2-cluster) and the gateway /32 (→ gateway).
  segmentNetworks = lib.listToAttrs (
    map (s: lib.nameValuePair s.cidr { inherit (s) name asn; }) ndhSegments
  );

  # Per-host /32 NetNames layered on top: the enclosing segment already supplies
  # asn+name at the CIDR level, so a host /32 refines only the NAME (its asn is
  # inherited from the segment — most-specific-wins is per-attribute). Sourced from
  # BOTH ndh's flat lan inventory (daily-drivers + rke2 nodes) and any off-DHCP
  # hosts pinned inside the segments. Distinct /32 keys, so akvorado sees them all.
  # A host's `ip` may be null — nnh publishes its OWN nnh-inlet/nnh-outlet into ndh's
  # catalog as DHCP tenants (no static IP to reserve), so ndh echoes them back here
  # with ip=null. Skip those: there is no /32 to attribute (the enclosing segment's
  # name already covers them), and `"${null}/32"` would abort eval.
  hasIp = h: (h.ip or null) != null;
  hostNetworks =
    (lib.mapAttrs' (name: h: lib.nameValuePair "${h.ip}/32" { inherit name; }) (
      lib.filterAttrs (_: hasIp) ndhHosts
    ))
    // (lib.listToAttrs (
      lib.concatMap (
        s: map (h: lib.nameValuePair "${h.ip}/32" { name = h.name; }) (lib.filter hasIp (s.hosts or [ ]))
      ) ndhSegments
    ));

  siteNetworks = segmentNetworks // hostNetworks;

  # "Internet only": keep any flow with at least one PUBLIC endpoint (excludes
  # LAN-internal chatter). Address-based, network-agnostic — the same RFC1918 +
  # bogon + multicast exclusions hold on the home LAN and the hotspot. Reused by
  # BOTH the saved filter and the default Visualize filter below. NOT catalog-
  # derived: this is public-vs-private, a different concern from attribution.
  internetOnlyFilter = ''
    (SrcAddr !<< 10.0.0.0/8 AND SrcAddr !<< 172.16.0.0/12 AND SrcAddr !<< 192.168.0.0/16 AND SrcAddr !<< 169.254.0.0/16 AND SrcAddr !<< fe80::/10 AND SrcAddr !<< fc00::/7 AND SrcAddr !<< ff00::/8 AND SrcAddr !<< 224.0.0.0/4)
    OR
    (DstAddr !<< 10.0.0.0/8 AND DstAddr !<< 172.16.0.0/12 AND DstAddr !<< 192.168.0.0/16 AND DstAddr !<< 169.254.0.0/16 AND DstAddr !<< fe80::/10 AND DstAddr !<< fc00::/7 AND DstAddr !<< ff00::/8 AND DstAddr !<< 224.0.0.0/4)'';

  # Kafka KRaft cluster ID derived from the project name, in pure Nix: base64url
  # (no padding) of md5("nnh"). md5 is exactly 16 bytes — the length a Kafka UUID
  # decodes to — so this is a valid, deterministic, reproducible cluster ID.
  kafkaClusterId = builtins.replaceStrings [ "+" "/" "=" ] [ "-" "_" "" ] (
    builtins.convertHash {
      hash = builtins.hashString "md5" "nnh";
      toHashFormat = "base64";
      hashAlgo = "md5";
    }
  );
in
{
  imports = [ ./common.nix ];

  networking.hostName = "nnh-outlet"; # → nnh-outlet.nikopol via bare-br dnsmasq

  # mDNS: publish `nnh-outlet.local` so a browser on the LAN that does NOT resolve
  # the .nikopol split-DNS zone can still reach the console by name. Tailnet peers
  # use nnh-outlet.nikopol (advertised /24) or the tailnet name instead.
  services.avahi = {
    enable = true;
    publish = {
      enable = true;
      addresses = true;
    };
  };

  # ── Reused nixpkgs backends (do not rebuild) — all on the store node ─────────
  services.clickhouse.enable = true;

  services.redis.servers."" = {
    enable = true;
    bind = "127.0.0.1";
    port = 6379;
  };

  # Kafka in KRaft mode (no ZooKeeper), single node. It must be reachable from the
  # inlet on nnh-inlet, so the PLAINTEXT listener binds all interfaces and ADVERTISES
  # its bare-br name (a localhost advertised-listener would hand the inlet an
  # unroutable address). The controller stays localhost (single-node quorum).
  services.apache-kafka = {
    enable = true;
    formatLogDirs = true;
    clusterId = kafkaClusterId;
    settings = {
      "node.id" = 1;
      "process.roles" = [
        "broker"
        "controller"
      ];
      "controller.quorum.voters" = [ "1@localhost:9093" ];
      "listeners" = [
        "PLAINTEXT://0.0.0.0:9092"
        "CONTROLLER://localhost:9093"
      ];
      "advertised.listeners" = [ "PLAINTEXT://nnh-outlet.nikopol:9092" ];
      "controller.listener.names" = [ "CONTROLLER" ];
      "inter.broker.listener.name" = "PLAINTEXT";
      "listener.security.protocol.map" = [
        "CONTROLLER:PLAINTEXT"
        "PLAINTEXT:PLAINTEXT"
      ];
      "log.dirs" = [ "/var/lib/apache-kafka" ];
      "offsets.topic.replication.factor" = 1;
      "transaction.state.log.replication.factor" = 1;
      "transaction.state.log.min.isr" = 1;
    };
  };

  # ── Tailnet (official Tailscale) ────────────────────────────────────────────
  # Only the store node joins the tailnet — it hosts the console (reachable by
  # tailnet name from anywhere) and is the node worth a stable identity. The inlet
  # stays internal, reached via the bare-br /24 advertised by nikopol's subnet
  # router. Enrollment is imperative (collector-deploy pushes the OAuth-minted
  # authkey to authKeyFile); state + key live on the persistent /var/lib/tailscale
  # volume so the identity survives `incus rebuild`. --accept-dns=false keeps the
  # bare-br/DHCP resolver (.nikopol + internet for the GeoIP fetch).
  services.tailscale = {
    enable = true;
    authKeyFile = "/var/lib/tailscale/authkey";
    extraUpFlags = [
      "--advertise-tags=tag:incus"
      # The TAILNET node name (its MagicDNS identity) is `nikopol-netflow` —
      # distinct from the bare-br name `nnh-outlet.nikopol`. Two namespaces: the
      # bare-br dnsmasq zone (.nikopol, for the pipeline) vs the tailnet (console
      # reachability by a stable node name). Kept as nikopol-netflow to preserve
      # the existing tailnet identity across the split.
      "--hostname=nikopol-netflow"
      "--accept-dns=false"
    ];
  };

  # The console binds :80 (privileged, see console.http.listen below) but the
  # akvorado daemons run as the non-root `akvorado` user — grant the console unit
  # the one capability that lets a non-root process bind a low port. Kept in the
  # host (not the generic module) since it's a consequence of THIS host's port choice.
  systemd.services.akvorado-console.serviceConfig.AmbientCapabilities = [
    "CAP_NET_BIND_SERVICE"
  ];

  # ── Akvorado: orchestrator + outlet + console (the inlet runs on nnh-inlet) ──
  services.akvorado = {
    daemons = [
      "orchestrator"
      "outlet"
      "console"
    ];
    geoip.enable = true;

    settings = {
      # Orchestrator's own port: bound broadly so the inlet on nnh-inlet can fetch
      # its config from http://nnh-outlet.nikopol:8080 (a 127.0.0.1 bind would be
      # unreachable across instances). outlet/console fetch it locally.
      http.listen = ":8080";

      kafka = {
        topic = "flows";
        # Kafka lives here on the store node; the inlet (remote) and the local
        # outlet/orchestrator all address it by its bare-br name.
        brokers = [ "nnh-outlet.nikopol:9092" ];
        topic-configuration = {
          num-partitions = 8;
          replication-factor = 1;
          config-entries = {
            "segment.bytes" = 1073741824;
            "retention.ms" = 86400000; # 1 day
            "cleanup.policy" = "delete";
            "compression.type" = "producer";
          };
        };
      };

      # ClickHouse clients (orchestrator schema provisioning, outlet writes, console
      # reads) are ALL co-located here → localhost.
      clickhousedb.servers = [ "localhost:9000" ];
      clickhouse = {
        orchestrator-url = "http://127.0.0.1:8080";
        prometheus-endpoint = "/metrics";
        # Canonical AS names straight from ndh's catalog asns dict, fed into the
        # `asns` ClickHouse dictionary so the console shows named ASes for our own
        # side instead of the bare "0: ???". Keys are strings (Nix/YAML render them
        # so); akvorado's WeaklyTyped mapstructure decoder coerces to the uint32 key.
        asns = ndhAsns;
      };

      inlet = {
        # The inlet's own metrics/http port (it runs on nnh-inlet); bound broadly so
        # the console/prometheus can scrape it across bare-br.
        http.listen = ":8081";
        # Only the NetFlow v9 input from pmacct (dropped the unused IPFIX/sFlow).
        # ":2055" binds on whatever node runs the inlet → nnh-inlet.nikopol:2055.
        flow.inputs = [
          {
            type = "udp";
            decoder = "netflow";
            listen = ":2055";
            workers = 4;
            receive-buffer = 212992;
          }
        ];
      };

      outlet = {
        http.listen = ":8082";
        geoip = {
          optional = true;
          asn-database = [ "/var/lib/akvorado/geoip/asn.mmdb" ];
          geo-database = [ "/var/lib/akvorado/geoip/GeoLite2-City.mmdb" ];
        };
        # No SNMP on the bare-metal probe: pmacct assigns ifindex 1 (interfaces.map)
        # and we resolve it here. The ::/0 catch-all matches the exporter whatever
        # IPv4 its en0 holds (home LAN vs hotspot DHCP).
        metadata.providers = [
          {
            type = "static";
            exporters."::/0" = {
              name = "nikopol-vz";
              # `default` applies to every ifindex, so it already covers pmacct's
              # ifindex 1 — we deliberately omit an explicit `ifindexes` map (Nix
              # renders attr keys as strings but akvorado wants an integer ifindex
              # key, and `default` is identical here), sidestepping the mismatch.
              default = {
                name = "en0";
                description = "WiFi uplink (Android hotspot)";
                speed = 1000;
                boundary = "external";
              };
            };
          }
        ];
        routing.provider = {
          type = "bmp";
          receive-buffer = 212992;
        };
        # "You" as prefixes, derived from ndh's catalog (see the `let` above): the
        # `asn` fills SrcAS/DstAS for our own side, the `name` fills SrcNetName/
        # DstNetName. Segments give CIDR-level asn+name; host /32s refine the name.
        networks.networks = siteNetworks;
        # pmacct exports unsampled (sampling_rate=1); backstop for any flow arriving
        # without a rate.
        core.default-sampling-rate = 1;
      };

      console = {
        http = {
          # Bind the UI on :80 so it's reachable as http://nnh-outlet.nikopol (no
          # port). :80 is privileged and akvorado runs as the non-root `akvorado`
          # user, so the console unit is granted CAP_NET_BIND_SERVICE below.
          listen = ":80";
          cache = {
            type = "redis";
            server = "localhost:6379";
          };
        };
        # Open the Visualize tab on something useful by default: internet-only,
        # ranked by total (limit-type "avg" over the window == ordered by total
        # bytes — there is no "total" rank; avg is equivalent), Src→Dst AS.
        default-visualize-options = {
          graph-type = "stacked";
          start = "24 hours ago";
          end = "now";
          filter = internetOnlyFilter;
          dimensions = [
            "SrcAS"
            "DstAS"
          ];
          limit = 10;
          limit-type = "avg";
        };
        database = {
          dsn = "/var/lib/akvorado/console.sqlite";
          saved-filters = [
            {
              description = "Internet only (excludes LAN-internal)";
              content = internetOnlyFilter;
            }
          ];
        };
      };
    };
  };
}
