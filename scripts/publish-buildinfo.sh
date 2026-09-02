#!/usr/bin/env bash
#
# Publish the build records and source packages a build produced, to their own
# R2 prefix.
#
#   publish-buildinfo.sh <dir>       a directory holding *.buildinfo
#
# A .buildinfo records the exact environment a package was built in -- every
# installed build dependency with its version, the architecture, the toolchain
# dpkg could see. It is what makes "built from source" checkable by someone
# else, and it is the input a rebuilder needs. dpkg-buildpackage emits one
# beside every .deb; until now it expired with the build runner.
#
# The source package ships with it, and that is what makes the record
# actionable rather than merely readable. Given a .buildinfo alone, debrebuild
# resolves the whole environment from snapshot.debian.org and then stops,
# because our source was never in Debian and debsnap cannot find it. It looks
# for the .dsc in the same directory as the record FIRST and only falls back to
# debsnap when it is absent, so putting the two together is the entire fix.
#
# Why a prefix of its own rather than beside the .deb in the pool. aptly cannot
# ingest a .buildinfo: its extension registry is exactly .changes, .deb, .dsc
# and .udeb, and `repo add` on one exits 0 having added nothing. Worse, a file
# dropped into pool/ by hand does not survive -- aptly's cleanup removes pool
# objects no published index references, and no index will ever reference this.
# Measured both ways on 1.6.3: a file at pool/main/d/demo/demo_1.0-1.buildinfo
# was gone after the next `publish update`, while one under buildinfo/ survived.
# On S3 the same cleanup is `RemoveDirs`, which lists a path and deletes
# everything under it with no filter on extension or ownership.
#
# So this writes beside aptly, not through it, which is also how Debian does it:
# buildinfos.debian.net is separate from the archive, sharded by source initial,
# and its own README calls itself a stopgap because ftp-master does not publish
# them either.
#
# Layout mirrors the pool's sharding so a reader can guess it, and debrebuild
# requires the source to sit beside the record it belongs to:
#   buildinfos/buildinfo-pool/<initial>/<source>/<name>_<version>_<arch>.buildinfo
#   buildinfos/buildinfo-pool/<initial>/<source>/<name>_<version>.dsc
#   buildinfos/buildinfo-pool/<initial>/<source>/<name>_<upstream>.orig.tar.gz
#
# The prefix is buildinfos/ and the pool sits inside it, which is what
# buildinfos.pkg.haus serves: shards at the root would make the root namespace
# the alphabet, leaving nowhere for the flat index and colliding with any
# source package whose name starts with a digit.
#
# Uploads are additive. A .buildinfo describes bytes that are themselves
# immutable, so re-uploading the same name is either identical or a bug
# elsewhere; nothing here deletes.
#
# One orig tarball serves all three suites -- the qualifier lands on the Debian
# revision, so 11.3.6-1 and 11.3.6-1~haus13+1 share an upstream version -- and
# all six legs of a version produce it byte-identically. The artifact download
# merges them into one file before this script sees them, so divergence would be
# invisible here; verify_dsc below catches it instead, because a .dsc records
# the checksum of the tarball it expects.

set -euo pipefail
# Without this, set -e stops at the edge of a command substitution.
shopt -s inherit_errexit

SRC="${1:?usage: $0 <dir holding *.buildinfo>}"

# Where buildinfos.pkg.haus serves from. Kept in one place because the prune
# script and the worker both have to agree with it.
PREFIX="${BUILDINFO_PREFIX:-buildinfos/buildinfo-pool}"

# shellcheck source=scripts/aptly-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/aptly-lib.sh"

require_r2

shopt -s nullglob
files=("$SRC"/*.buildinfo)
shopt -u nullglob

# Not an error. An empty-plan ingest builds nothing, and a suite whose packages
# were all already present produces no buildinfo either.
if [ "${#files[@]}" -eq 0 ]; then
    printf 'no .buildinfo files in %s, nothing to publish\n' "$SRC" >&2
    exit 0
fi

# A .dsc lists the sha256 of every file in its source package. Checking that
# before upload is the only place divergence between legs can still be caught:
# if two suites disagreed about the shared orig tarball, one of their .dsc files
# would name a checksum the stored tarball does not have, and a verifier would
# hit it instead of us.
verify_dsc() {
    local dsc="$1" dir want size file got

    # The Checksums-Sha256 block runs until the next line that starts in column
    # one. Fields are: hash, size, filename.
    dir="$(dirname "$dsc")"
    while read -r want size file; do
        [ -n "$file" ] || continue

        [ -e "$dir/$file" ] || {
            printf 'FATAL: %s names %s, which the build did not produce\n' \
                "$(basename "$dsc")" "$file" >&2
            return 1
        }

        got="$(sha256sum "$dir/$file" | cut -d' ' -f1)"
        [ "$got" = "$want" ] || {
            printf 'FATAL: %s does not match the checksum in %s\n' \
                "$file" "$(basename "$dsc")" >&2
            printf '       expected %s\n       got      %s\n' "$want" "$got" >&2
            printf '       Two build legs disagree about a shared source file.\n' >&2
            return 1
        }

        [ "$(stat -c %s "$dir/$file")" = "$size" ] || {
            printf 'FATAL: %s has the wrong size for %s\n' "$file" \
                "$(basename "$dsc")" >&2
            return 1
        }
    done < <(awk '/^Checksums-Sha256:/ {inblock=1; next}
                  inblock && /^ / {print $1, $2, $3; next}
                  inblock {exit}' "$dsc")
}

# Everything the builder collected that belongs beside the record. *.tar.*
# rather than the two quilt names, because a native package's source is a single
# <source>_<version>.tar.xz and a .dsc published without it cannot be unpacked.
shopt -s nullglob
extras=("$SRC"/*.source "$SRC"/*.dsc "$SRC"/*.tar.*)
shopt -u nullglob

# A record with no source beside it is not actionable. debrebuild looks for the
# .dsc in the record's own directory first and, not finding one, falls back to
# debsnap -- which has never heard of this archive, so the rebuild cannot even
# start. Publishing it anyway puts a file on a host whose entire claim is "check
# our builds" that cannot be used to check anything.
#
# This is not hypothetical: 36 such records, from builds made before the builder
# emitted source packages, were served for a day and then deleted. The invariant
# is enforced here rather than left to the builder so that a future change to
# what gets collected fails loudly instead of quietly halving the value of every
# record it publishes.
dscs=("$SRC"/*.dsc)
if [ "${#files[@]}" -gt 0 ] && [ ! -e "${dscs[0]}" ]; then
    printf 'FATAL: %s holds %s build record(s) and no .dsc. A record is only\n' \
        "$SRC" "${#files[@]}" >&2
    printf '       publishable beside the source package it describes.\n' >&2
    exit 1
fi

for dsc in "$SRC"/*.dsc; do
    [ -e "$dsc" ] || continue
    verify_dsc "$dsc"
done

published=0
for f in "${files[@]}" "${extras[@]}"; do
    name="$(basename "$f")"

    # <source>_<version>_<arch>.buildinfo, and the same leading field on every
    # other name here. The source name is everything before the first
    # underscore; a Debian package name may not contain one.
    source="${name%%_*}"
    if [ -z "$source" ] || [ "$source" = "$name" ]; then
        printf 'FATAL: cannot read a source name from %s\n' "$name" >&2
        exit 1
    fi

    # Same sharding as the pool: first character of the source name. Debian
    # additionally folds lib* into lib<initial>; no fleet package starts with
    # lib, so that case is deliberately not handled rather than guessed at.
    initial="${source:0:1}"

    aws_ s3 cp "$f" "s3://$R2_BUCKET/$PREFIX/$initial/$source/$name" \
        --only-show-errors
    published=$((published + 1))
done

printf 'published %s file(s) under %s/\n' "$published" "$PREFIX" >&2
