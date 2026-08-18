# nnh-outlet — the store instance.
#
# Runs the outlet + console daemons and the ONE irreplaceable backend: ClickHouse
# (the flow history — the only thing that cannot be reconstructed), plus Redis (the
# console cache, rebuildable from ClickHouse) and the periodic GeoIP fetch. It holds
# NO orchestrator and NO Kafka — those live on nnh-inlet so the ingest edge is fully
# self-contained (see hosts/inlet.nix). This host carries NO `settings`: outlet +
# console fetch their entire config from the orchestrator on nnh-inlet over
# `orchestratorUrl`. Cross-instance addressing uses bare-br names, never localhost.
#
# The orchestrator (on nnh-inlet) provisions the ClickHouse schema REMOTELY, so
# ClickHouse must accept connections on bare-br (listen_host below), not just
# localhost.
{
  config,
  lib,
  pkgs,
  ...
}:
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

  # ── Reused nixpkgs backends (do not rebuild) ─────────────────────────────────
  services.clickhouse = {
    enable = true;
    # The orchestrator runs on nnh-inlet and applies the schema migrations over the
    # network, and the ClickHouse dictionaries pull from it too — so ClickHouse must
    # accept connections beyond localhost. Bind all interfaces: bare-br is a trusted,
    # egress-less segment with the firewall disabled, so exposing :9000/:8123 on it
    # is safe. (The shipped default binds loopback only.) The local outlet/console
    # clients hairpin in via nnh-outlet.nikopol, which 0.0.0.0 also covers.
    serverConfig.listen_host = [ "0.0.0.0" ];
  };

  services.redis.servers."" = {
    enable = true;
    bind = "127.0.0.1"; # only the co-located console uses it
    port = 6379;
  };

  # ── Tailnet (official Tailscale) ────────────────────────────────────────────
  # Only the store node joins the tailnet — it hosts the console (reachable by
  # tailnet name from anywhere) and is the node worth a stable identity. The inlet
  # stays internal, reached via the bare-br /24 advertised by nikopol's subnet
  # router. Enrollment is imperative (collector-deploy pushes the OAuth-minted
  # authkey to authKeyFile); state + key live on the persistent /var/lib/tailscale
  # volume so the identity survives `incus rebuild`. --accept-dns=false keeps the
  # bare-br/DHCP resolver (.nikopol + internet for the GeoIP fetch) — so the pipeline
  # names never resolve to tailnet 100.x addresses.
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

  # The console binds :80 (privileged; see console.http.listen in hosts/inlet.nix's
  # settings) but the akvorado daemons run as the non-root `akvorado` user — grant
  # the console unit the one capability that lets a non-root process bind a low port.
  # Kept in the host (not the generic module) since it's a consequence of the port
  # choice for the console, which runs HERE.
  systemd.services.akvorado-console.serviceConfig.AmbientCapabilities = [
    "CAP_NET_BIND_SERVICE"
  ];

  # ── Akvorado: outlet + console (orchestrator + inlet run on nnh-inlet) ───────
  # Both fetch their config from the orchestrator on the ingest edge, by its bare-br
  # name. geoip.enable turns on the periodic mmdb fetch HERE — the outlet daemon does
  # the enrichment and reads the databases off the persistent /var/lib/akvorado volume.
  services.akvorado = {
    daemons = [
      "outlet"
      "console"
    ];
    geoip.enable = true;
    orchestratorUrl = "http://nnh-inlet.nikopol:8080";
  };
}
