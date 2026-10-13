#!/usr/bin/env bash
#
# Rebuild aptly's state from an already-published archive, and republish it.
#
# Used once to move the archive off reprepro and onto R2, and available after
# that as the recovery path when aptly's database is lost: everything it needs
# is in the published indices, which name every package and where its bytes
# are.
#
# The packages are downloaded, never rebuilt. Rebuilding from upstream tags
# yields different bytes under the same version, which the archive forbids --
# every consumer that already has the old bytes would see a hash mismatch.
#
#   SOURCE_URL=https://apt.pkg.haus scripts/seed-aptly.sh
#
# Idempotent: re-running against the same source adds nothing, because every
# version is already in the database.

set -euo pipefail
# Without this, set -e stops at the edge of a command substitution: a function
# called as x="$(f)" keeps running after a failure instead of aborting.
shopt -s inherit_errexit

SOURCE_URL="${SOURCE_URL:-https://apt.pkg.haus}"
SUITES="${SUITES:-trixie testing unstable}"
ARCHES="${ARCHES:-amd64 arm64}"
SEED_DIR="${SEED_DIR:-seed}"
# "off" rebuilds the database and publishes nothing. That is the recovery drill:
# everything before the publish is read-only against the public archive, so the
# whole path can be exercised with no credentials and no second bucket. Only
# publish_suite writes, which is why require_r2 sits behind this too.
SEED_PUBLISH="${SEED_PUBLISH:-on}"

# shellcheck source=scripts/aptly-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/aptly-lib.sh"

# Plain --retry does not retry a reset connection (curl 56), which is what fails
# here. Every URL comes from the archive's own index, so a 404 is a real fault
# and still fails, after the short budget.
seed_curl() { curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors "$@"; }

# To a file, not a pipe: curl cannot retry once part of a body is on stdout.
source_index() { # suite arch
    local gz="$SEED_DIR/Packages-$1-$2.gz"
    mkdir -p "$SEED_DIR"
    seed_curl --max-time 120 -o "$gz" \
        "$SOURCE_URL/dists/$1/main/binary-$2/Packages.gz"
    gunzip -c "$gz"
}

# Every package in the source archive as "<suite> <pool-path> <sha256>".
# Suite comes from the index the line was found in, not from the version
# qualifier: the source is the authority on which suite carries what.
#
# The reader is an argument for the same reason compare-archives.sh takes one:
# it is the seam the tests reach through. This is the recovery path, and the
# only one since R2 has no object versioning, so the parse deciding which suite
# gets which bytes needs exercising somewhere other than a real rebuild of the
# live archive.
build_manifest() { # reader
    local reader="$1" suite arch
    for suite in $SUITES; do
        for arch in $ARCHES; do
            "$reader" "$suite" "$arch" | index_stanzas "$suite"
        done
    done | LC_ALL=C sort -u
}

# Everything above is definitions, everything below runs. The guard lets the
# tests source this file without seeding anything, and without R2 credentials,
# since require_r2 sits below it.
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    return 0
fi

if [ "$SEED_PUBLISH" = on ]; then
    require_r2
fi

manifest="$(mktemp)"
trap 'rm -f "$manifest"' EXIT
build_manifest source_index > "$manifest"

[ -s "$manifest" ] || die "$SOURCE_URL published no packages"
log "source archive: $(wc -l < "$manifest") suite/package pairs, $(cut -d' ' -f2 "$manifest" | sort -u | wc -l) distinct files"

# Downloaded once per distinct file even when several suites share it, then
# hardlinked into each suite's staging directory: aptly reads the file, and one
# copy of a 25 MB .deb is enough.
cache="$SEED_DIR/cache"
mkdir -p "$cache"
while read -r _ rel sha; do
    dest="$cache/$(basename "$rel")"
    [ -f "$dest" ] && continue
    # Marked as ours: a seed downloads every published .deb, and unmarked that
    # is the single largest block of "downloads" the archive has ever recorded.
    seed_curl --max-time 300 -A "$ARCHIVE_SELF_UA" -o "$dest.part" "$SOURCE_URL/$rel"
    got="$(sha256sum "$dest.part" | cut -d' ' -f1)"
    if [ -n "$sha" ] && [ "$got" != "$sha" ]; then
        die "$rel: index says $sha, download is $got"
    fi
    mv "$dest.part" "$dest"
    log "fetched $(basename "$rel")"
done < "$manifest"

# One aptly repo per suite, filled from that suite's own index.
for suite in $SUITES; do
    stage="$SEED_DIR/$suite"
    rm -rf "$stage"
    mkdir -p "$stage"

    n=0
    while read -r s rel _; do
        [ "$s" = "$suite" ] || continue
        ln -f "$cache/$(basename "$rel")" "$stage/$(basename "$rel")"
        n=$((n + 1))
    done < "$manifest"
    [ "$n" -gt 0 ] || { log "$suite: nothing published, skipping"; continue; }

    repo="$(repo_of "$suite")"
    aptly_ repo show "$repo" >/dev/null 2>&1 \
        || aptly_ repo create -distribution="$suite" -component=main "$repo" >/dev/null
    aptly_ repo add "$repo" "$stage" >/dev/null
    log "$suite: $n packages staged, repo now holds $(suite_contents "$suite" | wc -l)"
done

if [ "$SEED_PUBLISH" != on ]; then
    log "SEED_PUBLISH=off: rebuilt from $SOURCE_URL, published nothing"
    exit 0
fi

for suite in $SUITES; do
    suite_contents "$suite" | grep -q . || continue
    publish_suite "$suite"
done

log "seeded and published from $SOURCE_URL"
