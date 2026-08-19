---
name: akvorado-proven-config
description: The proven Akvorado PoC config (from the podman clone) + the deltas to port it to native systemd — source of truth for modules/akvorado.nix
metadata: 
  node_type: memory
  type: reference
  originSessionId: b815b873-be9b-4c32-b955-d58288560a9e
  modified: 2026-08-15T15:59:46.376Z
---

The proven Akvorado config was extracted 2026-08-15 from the disposable podman PoC clone at
`/Volumes/git-worktree-store/akvorado/akvorado` (an akvorado repo clone, tag **v2026.8.0**,
`v2026.8.0-18-g8a8ba9fe`). It is an **untracked/uncommitted** clone (fragile). The PoC deltas vs
upstream: `config/outlet.yaml`, `config/console.yaml`, `.env` (modified) + `override-net.yml`
(added, podman-only — irrelevant to native). This memory preserves the essentials so
`modules/akvorado.nix` can render them natively. (nnh's flake pins akvorado at rev `767ee0f` —
reconcile the schema with v2026.8.0.)

**4-process model** (orchestrator serves config over HTTP; the others fetch it and run their own
HTTP for metrics/UI). Docker commands → native ExecStart:
- orchestrator: `akvorado orchestrator /etc/akvorado/akvorado.yaml` (HTTP :8080)
- inlet: `akvorado inlet http://127.0.0.1:8080` (listens UDP :2055; own HTTP for metrics)
- outlet: `akvorado outlet http://127.0.0.1:8080` (Kafka→ClickHouse + enrichment)
- console: `akvorado console http://127.0.0.1:8080` (the UI)

**NATIVE PORTING DELTAS (the important part):**
- **Per-process HTTP listen must differ** — in docker each container binds :8080; natively they
  collide. Set distinct `http.listen` per section: orchestrator :8080, inlet 127.0.0.1:8081,
  outlet 127.0.0.1:8082, console :8083 (or 172.16.6.2:8083 so vz reaches the UI over the /30).
- Backends → localhost: kafka `kafka:9092`→`localhost:9092`, clickhouse `clickhouse:9000`→
  `localhost:9000`, redis (console cache) `redis:6379`→`localhost:6379`.
- console DB: docker set `AKVORADO_CFG_CONSOLE_DATABASE_DSN=/run/akvorado/console.sqlite` → native
  a path under `/var/lib/akvorado` (sqlite for saved filters/users).
- geoip dir: docker mounted `akvorado-geoip:/usr/share/GeoIP:ro` → native `/var/lib/akvorado/geoip`
  (or keep /usr/share/GeoIP) populated by a fetch timer; outlet geoip paths point there.
- **console auth caveat**: the PoC ran the console behind traefik forward-auth (injects
  `Remote-User` header). Native has no proxy → configure console auth (default user / no-auth) or
  a tiny local reverse proxy. OPEN item for the module.

**akvorado.yaml (orchestrator aggregate):**
- `kafka`: topic `flows`, brokers `[localhost:9092]`, topic-configuration: 8 partitions, RF 1,
  segment.bytes 1073741824, retention.ms 86400000 (1d), cleanup.policy delete, compression producer.
- `clickhousedb.servers`: `[localhost:9000]`.
- `clickhouse`: orchestrator-url `http://127.0.0.1:8080`, prometheus-endpoint `/metrics` (drop the
  example `asns: {64501: ACME}`).
- `inlet: !include inlet.yaml`, `outlet: !include outlet.yaml`, `console: !include console.yaml`.

**inlet.yaml:** `flow.inputs` — keep only the NetFlow UDP `:2055` input (workers 4, receive-buffer
212992); drop the unused IPFIX :4739 and sFlow :6343.

**outlet.yaml (enrichment — THE core, satisfies the enricher gates):**
- `geoip.optional: true`; `asn-database: [.../asn.mmdb]` (IPinfo); `geo-database:
  [.../GeoLite2-City.mmdb]` (wp-statistics mirror).
- `metadata.providers: [{ type: static, exporters: { "::/0": { name: nikopol-vz, default: {name:
  en0, description: "WiFi uplink (Android hotspot)", speed: 1000, boundary: external}, ifindexes:
  {1: {name: en0, description: ..., speed: 1000, boundary: external}} } } }]` — the `::/0` catch-all
  matches the exporter whatever IPv4 its en0 holds.
- `routing.provider: {type: bmp, receive-buffer: 212992}` (idle without a BMP source; ASN comes
  from geoip — kept as proven).
- `core.default-sampling-rate: 1` (unsampled backstop — exact bytes).
- `networks`: upstream examples only (192.0.2.0/24 …) → drop / leave empty (not load-bearing; the
  "internet only" view is the console filter below).

**console.yaml:**
- `http.cache: {type: redis, server: localhost:6379}`.
- `database.saved-filters` — the key custom one, network-agnostic (RFC1918 + bogons on BOTH
  Src/Dst, matches any flow with a public endpoint): **"Internet only (excludes LAN-internal)"**
  `(SrcAddr !<< 10/8 AND !<< 172.16/12 AND !<< 192.168/16 AND !<< 169.254/16 AND !<< fe80::/10 AND
  !<< fc00::/7 AND !<< ff00::/8 AND !<< 224/4) OR (same for DstAddr)`. (upstream examples "From
  Netflix"/"From GAFAM" optional.)

**GeoIP fetch** (native systemd oneshot + timer, ~48h):
- IPinfo asn.mmdb: token **`a2632ea59736c7`** (shared, from docker-compose-ipinfo.yml;
  IPINFO_DATABASES `country asn`). Direct: `https://ipinfo.io/data/free/asn.mmdb?token=<token>`.
- GeoLite2-City.mmdb: wp-statistics mirror `https://cdn.jsdelivr.net/npm/geolite2-city/GeoLite2-City.mmdb.gz`
  (free, no key) → gunzip. See CLAUDE.md enrichment learning. Read downloads by **Src AS**.

Inlet binds :2055 on 172.16.6.2 — see [[probe-collector-transport]]. Backends are reused nixpkgs
services (clickhouse/kafka-KRaft/redis) — see [[incus-project-nnh]].
