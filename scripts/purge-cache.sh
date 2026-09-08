#!/usr/bin/env bash
#
# Purge the pool objects this run rebuilt from the Cloudflare edge cache.
#
# Only the pool. A rebuild replaces the bytes under a URL that is already
# published and already cached as immutable, and a POP still holding the old
# bytes breaks apt with a hash mismatch. Nothing else here needs purging: the
# listing pages, /news/ and the keyring are Worker static assets, and a Worker
# deployment swaps them atomically, so there is no window in which the edge can
# serve a previous render.
#
# Free-plan purging is by exact URL, 30 per call.

set -euo pipefail
# Without this, set -e stops at the edge of a command substitution: a function
# called as x="$(f)" keeps running after a failure instead of aborting.
shopt -s inherit_errexit

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
# Purging the entire pool instead would empty the 30-day pool cache on every
# publish, and behind a worker that builds these responses from R2 each purged
# URL costs an R2 read on its next request.
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


# The URLs to purge, one per pool path.
#
# One spelling, the literal one. apt requests pool files percent-encoded
# (%7e/%2b), but worker.js keys its cache on the DECODED path, so every
# spelling collapses to one entry and purging the encoded forms would address
# keys that cannot exist.
#
# Measured two ways, because each colo has its own cache and the naive test
# cannot tell "different spelling" from "different POP":
#
#   1. Connection reuse pins the colo -- one curl invocation, several URLs.
#      Fill through either spelling and the other HITs the same entry.
#   2. Warm several colos through the ENCODED spelling only, purge just the
#      literal URL, and every warm colo flips HIT to MISS. Repeated on typst,
#      croc and difftastic.
#
# The second also answers a question Cloudflare's docs hedge on: purge-by-URL
# does reach an entry a Worker created under its own cache key.
purge_urls() {
    pool_paths | while read -r rel; do
        printf '%s/%s\n' "$BASE_URL" "$rel"
    done
}

# Sourced rather than run: the tests exercise the URL selection above without
# purging anything, and without needing a token.
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    return 0
fi

: "${CLOUDFLARE_PURGE_TOKEN:?token with Zone - Cache Purge - Edit on pkg.haus}"
: "${CLOUDFLARE_ZONE_ID:?the pkg.haus zone id}"

mapfile -t urls < <(purge_urls | LC_ALL=C sort -u)

# 30 URLs per call, so this is several requests and any one can fail. Failing
# is right here (purging is the whole job), but the message has to say how far
# it got or a re-run is a guess about what is already done.
for ((i = 0; i < ${#urls[@]}; i += 30)); do
    batch_end=$(( i + 30 > ${#urls[@]} ? ${#urls[@]} : i + 30 ))
    if ! printf '%s\n' "${urls[@]:i:30}" \
        | jq -R . | jq -s '{files: .}' \
        | cf_purge_post >/dev/null; then
        printf 'FATAL: purge failed on URLs %s-%s of %s; the first %s are purged\n' \
            "$((i + 1))" "$batch_end" "${#urls[@]}" "$i" >&2
        printf '  a re-run repeats the whole list from the start\n' >&2
        exit 1
    fi
done

echo "purged ${#urls[@]} URLs" >&2
