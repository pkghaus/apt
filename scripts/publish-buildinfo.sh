#!/usr/bin/env bash
#
# Publish the .buildinfo files a build produced, to their own R2 prefix.
#
#   publish-buildinfo.sh <dir>       a directory holding *.buildinfo
#
# A .buildinfo records the exact environment a package was built in -- every
# installed build dependency with its version, the architecture, the toolchain
# dpkg could see. It is what makes "built from source" checkable by someone
# else, and it is the input a rebuilder needs. dpkg-buildpackage emits one
# beside every .deb; until now it expired with the build runner.
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
# Layout mirrors the pool's sharding so a reader can guess it:
#   buildinfo/<initial>/<source>/<name>_<version>_<arch>.buildinfo
#
# Uploads are additive. A .buildinfo describes bytes that are themselves
# immutable, so re-uploading the same name is either identical or a bug
# elsewhere; nothing here deletes.

set -euo pipefail
# Without this, set -e stops at the edge of a command substitution.
shopt -s inherit_errexit

SRC="${1:?usage: $0 <dir holding *.buildinfo>}"

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

published=0
for f in "${files[@]}"; do
    name="$(basename "$f")"

    # <source>_<version>_<arch>.buildinfo. The source name is everything before
    # the first underscore; a Debian package name may not contain one.
    source="${name%%_*}"
    if [ -z "$source" ] || [ "$source" = "$name" ]; then
        printf 'FATAL: cannot read a source name from %s\n' "$name" >&2
        exit 1
    fi

    # Same sharding as the pool: first character of the source name. Debian
    # additionally folds lib* into lib<initial>; no fleet package starts with
    # lib, so that case is deliberately not handled rather than guessed at.
    initial="${source:0:1}"

    aws_ s3 cp "$f" "s3://$R2_BUCKET/buildinfo/$initial/$source/$name" \
        --only-show-errors
    published=$((published + 1))
done

printf 'published %s .buildinfo file(s) under buildinfo/\n' "$published" >&2
