# Fetch the Akvorado GeoIP databases. Rendered by pkgs.replaceVars from
# modules/akvorado.nix (token @geoipDir@).
#
# Akvorado has no reverse-DNS, so destinations get org + location from here:
# ASN names from ip-location-db's GeoLite2-ASN mmdb (free, TOKENLESS, no rate
# limit — akvorado reads its MaxMind field format via the maxmindDB path) and
# city/state from the wp-statistics MaxMind GeoLite2-City mirror (free, no license
# key). Both ride jsdelivr. outlet.geoip.optional=true tolerates a not-yet-fetched
# db. (We dropped IPinfo's free asn.mmdb: its shared token caps downloads at
# 10/DAY and 429'd us after a few rebuilds.)
#
# The databases live on the PERSISTENT /var/lib/akvorado volume, so they survive
# `incus rebuild`. We therefore fetch only when a db is MISSING or STALE (>30d):
# re-downloading on every rebuild previously hammered IPinfo's free tier into
# HTTP 429. Each db is independent (one failing doesn't block the other) and a
# failed fetch keeps whatever copy already exists. NOT `set -e`: we handle each
# fetch's exit code explicitly and report overall success/failure via rc.
set -uo pipefail

d="@geoipDir@"
mkdir -p "$d"
rc=0

# Fresh = exists, non-empty, and younger than 30 days.
fresh() { [ -s "$1" ] && [ -z "$(find "$1" -mtime +30 -print 2>/dev/null)" ]; }

# ASN names from ip-location-db's GeoLite2-ASN mmdb (jsdelivr, tokenless, no rate
# limit). MaxMind field format (autonomous_system_number/_organization) that
# akvorado reads via its maxmindDB path. Replaces IPinfo's free asn.mmdb (10
# downloads/DAY on the shared token → 429 after a few rebuilds).
if fresh "$d/asn.mmdb"; then
  echo "[geoip] asn.mmdb present and fresh — skipping" >&2
elif curl -fsSL --retry 5 --retry-delay 5 --retry-connrefused \
  "https://cdn.jsdelivr.net/npm/@ip-location-db/geolite2-asn-mmdb/geolite2-asn.mmdb" -o "$d/asn.mmdb.new"; then
  mv -f "$d/asn.mmdb.new" "$d/asn.mmdb"
  echo "[geoip] asn.mmdb updated" >&2
else
  rm -f "$d/asn.mmdb.new"
  echo "[geoip] asn.mmdb fetch FAILED (keeping any existing copy)" >&2
  rc=1
fi

# City/state from the wp-statistics MaxMind GeoLite2-City mirror (jsdelivr, not
# rate-limited).
if fresh "$d/GeoLite2-City.mmdb"; then
  echo "[geoip] GeoLite2-City.mmdb present and fresh — skipping" >&2
elif curl -fsSL --retry 5 --retry-delay 5 --retry-connrefused \
  "https://cdn.jsdelivr.net/npm/geolite2-city/GeoLite2-City.mmdb.gz" -o "$d/GeoLite2-City.mmdb.gz.tmp"; then
  gzip -dc "$d/GeoLite2-City.mmdb.gz.tmp" >"$d/GeoLite2-City.mmdb.new" \
    && mv -f "$d/GeoLite2-City.mmdb.new" "$d/GeoLite2-City.mmdb"
  rm -f "$d/GeoLite2-City.mmdb.gz.tmp" "$d/GeoLite2-City.mmdb.new"
  echo "[geoip] GeoLite2-City.mmdb updated" >&2
else
  rm -f "$d/GeoLite2-City.mmdb.gz.tmp"
  echo "[geoip] GeoLite2-City.mmdb fetch FAILED (keeping any existing copy)" >&2
  rc=1
fi

exit "$rc"
