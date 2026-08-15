#!/usr/bin/env bash
#
# Purge the archive's listing pages from the Cloudflare edge cache. Runs
# after the Pages deployment, so the edge refills with the fresh render.
# The listing cache rule holds pages for a day (pkghaus/infrastructure,
# waf/pkg.haus.yaml); this purge is what keeps them current the moment a
# publish lands.
#
# Free-plan purging is by exact URL, 30 per call. Every directory page is
# purged in both request forms (trailing slash and explicit index.html).
# dists/ pages are never edge-cached, so they are not purged.

set -euo pipefail

ARCHIVE_DIR="${ARCHIVE_DIR:-public}"
BASE_URL="${BASE_URL:-https://apt.pkg.haus}"

: "${CLOUDFLARE_PURGE_TOKEN:?token with Zone - Cache Purge - Edit on pkg.haus}"
: "${CLOUDFLARE_ZONE_ID:?the pkg.haus zone id}"

mapfile -t urls < <(
    {
        find "$ARCHIVE_DIR" -name index.html \
            -not -path "$ARCHIVE_DIR/dists/*" -not -path '*/.git/*' \
            | while read -r page; do
                rel="${page#"$ARCHIVE_DIR"}"
                printf '%s%s\n' "$BASE_URL" "$rel"
                printf '%s%s\n' "$BASE_URL" "${rel%index.html}"
            done
        # Pool files too: normally immutable, but rebuild flows (archive
        # wipe, retirement) replace bytes under existing URLs, and a POP
        # still holding the old bytes breaks apt with hash mismatches
        # against the fresh, never-cached dists metadata. apt requests
        # these URLs with '~' and '+' percent-encoded (observed live:
        # %7e / %2b, lowercase), so the cached key can exist under an
        # encoded spelling the literal URL would not match. Purge every
        # spelling; the duplicates collapse in sort -u.
        find "$ARCHIVE_DIR/pool" -name '*.deb' -not -path '*/.git/*' 2>/dev/null \
            | while read -r deb; do
                rel="${deb#"$ARCHIVE_DIR"}"
                printf '%s%s\n' "$BASE_URL" "$rel"
                printf '%s%s\n' "$BASE_URL" "$(printf '%s' "$rel" | sed 's/~/%7e/g; s/+/%2b/g')"
                printf '%s%s\n' "$BASE_URL" "$(printf '%s' "$rel" | sed 's/~/%7E/g; s/+/%2B/g')"
            done
    } | LC_ALL=C sort -u
)

for ((i = 0; i < ${#urls[@]}; i += 30)); do
    printf '%s\n' "${urls[@]:i:30}" \
        | jq -R . | jq -s '{files: .}' \
        | curl -sS --fail-with-body -X POST \
            "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/purge_cache" \
            -H "Authorization: Bearer ${CLOUDFLARE_PURGE_TOKEN}" \
            -H 'Content-Type: application/json' \
            --data @- >/dev/null
done

echo "purged ${#urls[@]} listing URLs" >&2
