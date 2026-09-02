#!/usr/bin/env bash
#
# Rebuild a published package from its record and compare, using debrebuild.
#
#   verify/rebuild.sh <dir holding one package's .buildinfo, .dsc and tarballs>
#
# Everything it needs is published at the same path under buildinfo/:
#
#   curl -fsSLO https://apt.pkg.haus/buildinfo/c/croc/croc_11.3.6-1_amd64.buildinfo
#   curl -fsSLO https://apt.pkg.haus/buildinfo/c/croc/croc_11.3.6-1.dsc
#   curl -fsSLO https://apt.pkg.haus/buildinfo/c/croc/croc_11.3.6.orig.tar.gz
#   curl -fsSLO https://apt.pkg.haus/buildinfo/c/croc/croc_11.3.6-1.debian.tar.xz
#
# debrebuild resolves every build dependency from snapshot.debian.org at the
# versions the record names, unpacks the .dsc, rebuilds, and checks all four
# checksums against the .buildinfo. It prints "all OK" or names what differed.
#
# Two things this works around, both debrebuild's:
#
#  - `apt-get source` is required to succeed even though the very next line
#    extracts the local .dsc and discards what was downloaded. A source archive
#    built from the files you already have satisfies it.
#  - the mmdebstrap builder cannot run nested inside a container; the dpkg
#    builder is used instead, which is why this runs in a throwaway one.

set -euo pipefail

IN="${1:?usage: $0 <dir holding .buildinfo, .dsc and tarballs>}"
IN="$(cd "$IN" && pwd)"
IMAGE="${VERIFY_IMAGE:-pkghaus-verify}"

buildinfo="$(find "$IN" -maxdepth 1 -name '*.buildinfo' -print -quit)"
[ -n "$buildinfo" ] || { echo "FATAL: no .buildinfo in $IN" >&2; exit 1; }

docker build --quiet --tag "$IMAGE" "$(dirname "$0")" >/dev/null

out="$IN/rebuilt"
mkdir -p "$out"

# --privileged because the dpkg builder installs an exact set of packages and
# then builds; the container is the throwaway system it is allowed to change.
docker run --rm --privileged \
    --volume "$IN:/p" \
    "$IMAGE" sh -c '
        set -e
        mkdir -p /srcrepo
        cp /p/*.dsc /p/*.tar.* /srcrepo/
        cd /srcrepo && dpkg-scansources . > Sources && gzip -kf Sources
        echo "deb-src [trusted=yes] file:///srcrepo ./" \
            > /etc/apt/sources.list.d/local-src.list
        cd /p
        debrebuild --builder=dpkg --buildresult=/p/rebuilt "$(basename '"$buildinfo"')"
    '
