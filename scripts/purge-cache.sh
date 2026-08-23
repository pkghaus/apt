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
BUILD_DIR="${BUILD_DIR:-build}"
BASE_URL="${BASE_URL:-https://apt.pkg.haus}"

# shellcheck source=scripts/aptly-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/aptly-lib.sh"
SUITES="${SUITES:-trixie testing unstable}"
ARCHES="${ARCHES:-amd64 arm64}"

# The pool paths this run replaced, and only those.
#
# A published version's bytes never change, so its URL never needs purging --
# except on the rebuild flows (archive wipe, retirement) that put different
# bytes under an existing version. Those bytes arrive as a .deb in $BUILD_DIR,
# which is the whole of what this run wrote, so that directory is the purge
# list.
#
# Purging the entire pool instead, as this did until 2026-08-23, empties the
# 30-day pool cache on every publish. That was merely wasteful while Pages was
# the origin; now that the worker builds these responses from R2, every purged
# URL is an R2 read on its next request.
#
# Paths come from the indices rather than from the filename, so the pool
# layout stays aptly's business: Filename is the archive-root-relative path,
# e.g. pool/main/c/croc/croc_...deb.
pool_paths() {
    local suite arch built
    built="$(mktemp)"
    find "$BUILD_DIR" -maxdepth 1 -name '*.deb' -printf '%f\n' 2>/dev/null \
        | LC_ALL=C sort -u > "$built"
    if [ ! -s "$built" ]; then
        rm -f "$built"
        return 0
    fi

    for suite in $SUITES; do
        for arch in $ARCHES; do
            index_text "$suite" "$arch" \
                | awk -v list="$built" '
                    BEGIN { while ((getline l < list) > 0) want[l] = 1 }
                    /^Filename: / {
                        n = split($2, part, "/")
                        if (part[n] in want) print $2
                    }'
        done
    done | LC_ALL=C sort -u
    rm -f "$built"
}

# The Pages deployment reports success before every origin node serves
# it. Purging inside that window lets the edge re-cache the PREVIOUS
# render for the listings' full TTL (observed live 2026-08-16: a green
# publish left a stale root listing until the next purge). Every render
# stamps the footer with a fresh <time datetime>; wait until the origin
# serves this render's stamp before purging. Cache-busting query strings
# read through our edge straight to the origin.
verify_origin_fresh() {
    local stamp attempt
    stamp="$(grep -o 'datetime="[^"]*"' "$ARCHIVE_DIR/index.html" 2>/dev/null | head -n1 || true)"
    if [ -z "$stamp" ]; then
        echo "no render stamp found; skipping origin verification" >&2
        return 0
    fi
    for attempt in $(seq 1 24); do
        if curl -fsS "$BASE_URL/?verify=${attempt}-$$" 2>/dev/null | grep -q "$stamp"; then
            echo "origin serves this render (attempt $attempt)" >&2
            return 0
        fi
        sleep 5
    done
    echo "WARNING: origin still serving a previous render after 120s; purging anyway" >&2
}

# Sourced rather than run: the tests exercise the URL selection above without
# purging anything, and without needing a token.
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    return 0
fi

: "${CLOUDFLARE_PURGE_TOKEN:?token with Zone - Cache Purge - Edit on pkg.haus}"
: "${CLOUDFLARE_ZONE_ID:?the pkg.haus zone id}"

verify_origin_fresh

mapfile -t urls < <(
    {
        find "$ARCHIVE_DIR" -name index.html \
            -not -path "$ARCHIVE_DIR/dists/*" -not -path '*/.git/*' \
            | while read -r page; do
                rel="${page#"$ARCHIVE_DIR"}"
                printf '%s%s\n' "$BASE_URL" "$rel"
                printf '%s%s\n' "$BASE_URL" "${rel%index.html}"
            done
        # A POP still holding the pre-rebuild bytes breaks apt with hash
        # mismatches against the fresh, never-cached dists metadata. apt
        # requests these URLs with '~' and '+' percent-encoded (observed
        # live: %7e / %2b, lowercase), so the cached key can exist under an
        # encoded spelling the literal URL would not match. Purge every
        # spelling; the duplicates collapse in sort -u.
        pool_paths \
            | while read -r rel; do
                printf '%s/%s\n' "$BASE_URL" "$rel"
                printf '%s/%s\n' "$BASE_URL" "$(printf '%s' "$rel" | sed 's/~/%7e/g; s/+/%2b/g')"
                printf '%s/%s\n' "$BASE_URL" "$(printf '%s' "$rel" | sed 's/~/%7E/g; s/+/%2B/g')"
            done
        # The news feed rides the same publish cadence as the listings.
        if [ -f "$ARCHIVE_DIR/news/feed.xml" ]; then
            printf '%s/news/feed.xml\n' "$BASE_URL"
        fi
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

echo "purged ${#urls[@]} URLs" >&2
