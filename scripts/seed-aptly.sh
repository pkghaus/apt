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

# shellcheck source=scripts/aptly-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/aptly-lib.sh"

log() { printf '%s\n' "$*" >&2; }

require_r2

# Every package in the source archive as "<suite> <pool-path> <sha256>".
# Suite comes from the index the line was found in, not from the version
# qualifier: the source is the authority on which suite carries what.
manifest="$(mktemp)"
for suite in $SUITES; do
    for arch in $ARCHES; do
        curl -fsSL --max-time 120 \
            "$SOURCE_URL/dists/$suite/main/binary-$arch/Packages.gz" \
            | gunzip \
            | awk -v s="$suite" '
                /^Filename: /   { f = $2 }
                /^SHA256: /     { h = $2 }
                /^$/            { if (f != "") print s, f, h; f = ""; h = "" }
                END             { if (f != "") print s, f, h }'
    done
done | LC_ALL=C sort -u > "$manifest"

[ -s "$manifest" ] || { log "FATAL: $SOURCE_URL published no packages"; exit 1; }
log "source archive: $(wc -l < "$manifest") suite/package pairs, $(cut -d' ' -f2 "$manifest" | sort -u | wc -l) distinct files"

# Downloaded once per distinct file even when several suites share it, then
# hardlinked into each suite's staging directory: aptly reads the file, and one
# copy of a 25 MB .deb is enough.
cache="$SEED_DIR/cache"
mkdir -p "$cache"
while read -r _ rel sha; do
    dest="$cache/$(basename "$rel")"
    [ -f "$dest" ] && continue
    curl -fsSL --max-time 300 -o "$dest.part" "$SOURCE_URL/$rel"
    got="$(sha256sum "$dest.part" | cut -d' ' -f1)"
    if [ -n "$sha" ] && [ "$got" != "$sha" ]; then
        log "FATAL: $rel: index says $sha, download is $got"
        exit 1
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

for suite in $SUITES; do
    suite_contents "$suite" | grep -q . || continue
    publish_suite "$suite"
done

log "seeded and published from $SOURCE_URL"
