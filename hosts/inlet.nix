# nnh-inlet — the ingest edge AND the pipeline brain.
#
# Runs the orchestrator + inlet, plus Kafka (the transient flow buffer). Co-locating
# the orchestrator, the inlet and Kafka makes the ingest edge fully SELF-CONTAINED:
# it receives the probe's NetFlow, buffers to a LOCAL Kafka, and serves config to
# every daemon WITHOUT the store node — so an nnh-outlet outage never loses flows
# (the outlet drains the Kafka backlog when it returns). The store node keeps only
# what is irreplaceable (the ClickHouse flow history); everything here is
# reconstructible — the orchestrator config is baked in nix, Kafka is a ≤1-day buffer.
#
# The orchestrator holds the whole pipeline config (this `settings` block) and serves
# it over :8080 to every daemon — the local inlet AND the remote outlet/console on
# nnh-outlet. Cross-instance addressing uses bare-br names, never localhost.
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

  # Public-vs-private endpoint tests, ADDRESS-based → network-agnostic: the same
  # RFC1918 + link-local + ULA + bogon/multicast exclusions hold on the home LAN AND
  # on the hotspot (where every IP changes, so an AS-based test would break — the Mac
  # gets the carrier's real AS, not our private 65000). These compose into the
  # "internet only" filter AND the direction-oriented filters below: our single
  # no-direction exporter gives akvorado no usable InIf/OutIf boundary to orient by,
  # so "up vs down" can only be decided by which endpoint is private.
  srcPublic = "(SrcAddr !<< 10.0.0.0/8 AND SrcAddr !<< 172.16.0.0/12 AND SrcAddr !<< 192.168.0.0/16 AND SrcAddr !<< 169.254.0.0/16 AND SrcAddr !<< fe80::/10 AND SrcAddr !<< fc00::/7 AND SrcAddr !<< ff00::/8 AND SrcAddr !<< 224.0.0.0/4)";
  dstPublic = "(DstAddr !<< 10.0.0.0/8 AND DstAddr !<< 172.16.0.0/12 AND DstAddr !<< 192.168.0.0/16 AND DstAddr !<< 169.254.0.0/16 AND DstAddr !<< fe80::/10 AND DstAddr !<< fc00::/7 AND DstAddr !<< ff00::/8 AND DstAddr !<< 224.0.0.0/4)";
  srcPrivate = "(SrcAddr << 10.0.0.0/8 OR SrcAddr << 172.16.0.0/12 OR SrcAddr << 192.168.0.0/16 OR SrcAddr << 169.254.0.0/16 OR SrcAddr << fe80::/10 OR SrcAddr << fc00::/7)";
  dstPrivate = "(DstAddr << 10.0.0.0/8 OR DstAddr << 172.16.0.0/12 OR DstAddr << 192.168.0.0/16 OR DstAddr << 169.254.0.0/16 OR DstAddr << fe80::/10 OR DstAddr << fc00::/7)";

  # Reused by the default Visualize view + the saved filters below.
  internetOnlyFilter = "${srcPublic} OR ${dstPublic}"; # at least one public endpoint
  outboundFilter = "${srcPrivate} AND ${dstPublic}"; # you → internet (uploads)
  inboundFilter = "${srcPublic} AND ${dstPrivate}"; # internet → you (downloads)
  lanInternalFilter = "${srcPrivate} AND ${dstPrivate}"; # LAN-internal chatter

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

  networking.hostName = "nnh-inlet"; # → nnh-inlet.nikopol via bare-br dnsmasq

  # ── Kafka (KRaft, single node) — the transient flow buffer, ON the ingest edge ─
  # It must be reachable from the remote outlet on nnh-outlet, so the PLAINTEXT
  # listener binds all interfaces and ADVERTISES this host's bare-br name (a
  # localhost advertised-listener would hand the outlet an unroutable address). The
  # controller stays localhost (single-node quorum). Log dir is on the ephemeral
  # rootfs BY DESIGN: it's a ≤1-day buffer, not state to preserve across a rebuild.
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
      "advertised.listeners" = [ "PLAINTEXT://nnh-inlet.nikopol:9092" ];
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

  # ── Akvorado: orchestrator + inlet (outlet + console run on nnh-outlet) ──────
  # The inlet daemon fetches its config from the LOCAL orchestrator, so the module's
  # default orchestratorUrl (http://127.0.0.1:8080) is correct — left unset here.
  services.akvorado = {
    daemons = [
      "orchestrator"
      "inlet"
    ];

    settings = {
      # Orchestrator's own port: ":8080" binds all interfaces so the local inlet
      # reaches it on 127.0.0.1 AND the remote outlet/console reach it on
      # http://nnh-inlet.nikopol:8080.
      http.listen = ":8080";

      kafka = {
        topic = "flows";
        # Kafka lives HERE on the ingest edge; the local inlet/orchestrator and the
        # remote outlet all address it by this host's bare-br name.
        brokers = [ "nnh-inlet.nikopol:9092" ];
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

      # ClickHouse lives on the STORE node. The orchestrator here provisions its
      # schema REMOTELY (→ nnh-outlet must listen on bare-br, see hosts/outlet.nix);
      # the outlet/console clients on nnh-outlet reach it by the same name (hairpin
      # to self). One shared address for all three, so: nnh-outlet.nikopol:9000.
      clickhousedb.servers = [ "nnh-outlet.nikopol:9000" ];
      clickhouse = {
        # The URL ClickHouse (on nnh-outlet) uses to pull the akvorado dictionaries
        # over HTTP — the orchestrator is HERE, so its bare-br name, not localhost.
        orchestrator-url = "http://nnh-inlet.nikopol:8080";
        prometheus-endpoint = "/metrics";
        # Canonical AS names straight from ndh's catalog asns dict, fed into the
        # `asns` ClickHouse dictionary so the console shows named ASes for our own
        # side instead of the bare "0: ???". Keys are strings (Nix/YAML render them
        # so); akvorado's WeaklyTyped mapstructure decoder coerces to the uint32 key.
        asns = ndhAsns;
      };

      inlet = {
        # The inlet's own metrics/http port (it runs HERE); bound broadly so the
        # console/prometheus on nnh-outlet can scrape it across bare-br.
        http.listen = ":8081";
        # Only the NetFlow v9 input from pmacct (dropped the unused IPFIX/sFlow).
        # ":2055" binds on this ingest edge → nnh-inlet.nikopol:2055.
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
          # user, so the console unit on nnh-outlet is granted CAP_NET_BIND_SERVICE.
          listen = ":80";
          cache = {
            type = "redis";
            # Redis is co-located with the console on nnh-outlet → localhost there.
            server = "localhost:6379";
          };
        };
        # Pre-configured Visualize so the operator lands on a READABLE, on-purpose
        # view without fiddling. Default = the OUTBOUND sense (you → internet), which
        # makes "your side" the readable pivot: each internal host by NAME
        # (SrcNetName, from the ndh catalog) stacked against the destination AS
        # (DstAS, named via the asns dict — GitHub, Amazon, …). The default SrcAS→DstAS
        # would collapse every internal host into the single AS 65000 ("home") — the
        # exact "can't tell my sources apart" problem. Downloads are one click away via
        # the "Inbound" saved filter. limit-type "avg" over the window == ranked by
        # total bytes (there is no "total" rank; avg is equivalent).
        default-visualize-options = {
          graph-type = "stacked";
          start = "24 hours ago";
          end = "now";
          filter = outboundFilter;
          dimensions = [
            "SrcNetName"
            "DstAS"
          ];
          limit = 10;
          limit-type = "avg";
        };
        database = {
          dsn = "/var/lib/akvorado/console.sqlite";
          # One-click presets. Orientation is address-based (see the filter `let`), so
          # they hold on the hotspot too. Pick the sense, then set dimensions to taste
          # (SrcNetName for "which of my hosts", DstAS/Dst2ndAS for "toward whom",
          # Dst{Addr,Port} to drill in) and a graph type (stacked = over time, sankey =
          # who→whom totals).
          saved-filters = [
            {
              description = "Internet only (either endpoint public)";
              content = internetOnlyFilter;
            }
            {
              description = "Outbound — you → internet (uploads)";
              content = outboundFilter;
            }
            {
              description = "Inbound — internet → you (downloads)";
              content = inboundFilter;
            }
            {
              description = "LAN internal only (no internet)";
              content = lanInternalFilter;
            }
          ];
        };
      };
    };
  };
}
