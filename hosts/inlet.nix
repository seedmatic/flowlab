# nnh-inlet — the ingest edge instance.
#
# Runs ONLY the akvorado inlet: it receives the probe's NetFlow v9 on :2055 and
# produces the raw flows to Kafka on the store node. It holds NO backend and NO
# `settings` — the inlet fetches its ENTIRE config (the :2055 listener, the Kafka
# target, the sampling rate, …) from the orchestrator over HTTP, so this host is a
# thin, stateless forwarder. All the pipeline config lives in hosts/outlet.nix.
{ ... }:
{
  imports = [ ./common.nix ];

  networking.hostName = "nnh-inlet"; # → nnh-inlet.nikopol via bare-br dnsmasq

  services.akvorado = {
    daemons = [ "inlet" ];
    # The orchestrator runs on the store node; reach it by its bare-br name.
    orchestratorUrl = "http://nnh-outlet.nikopol:8080";
  };
}
