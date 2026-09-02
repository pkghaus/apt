#!/usr/bin/env bash
#
# Rebuild a published package from its record and compare, using debrebuild.
#
#   verify/rebuild.sh <dir holding one package's .buildinfo, .dsc and tarballs>
#
# Everything it needs is published at the same path on buildinfos.pkg.haus:
#
#   B=https://buildinfos.pkg.haus/buildinfo-pool/m/mandown
#   curl -fsSLO $B/mandown_1.0.5.2-2_amd64.buildinfo
#   curl -fsSLO $B/mandown_1.0.5.2-2.dsc
#   curl -fsSLO $B/mandown_1.0.5.2.orig.tar.gz
#   curl -fsSLO $B/mandown_1.0.5.2-2.debian.tar.xz
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
#  - the dpkg builder installs the record's Installed-Build-Depends at exactly
#    the pinned versions, and apt satisfies that by REMOVING whatever conflicts
#    -- devscripts included, which is the package debrebuild itself came from.
#    It survives because perl already loaded it, but the `dcmd` it shells out to
#    afterwards is gone, and the run dies with "Can't exec dcmd" one step before
#    the checksum comparison that is the whole point. dcmd is a POSIX sh script
#    needing only dirname and sed, so a copy under /usr/local/bin (ahead of
#    /usr/bin on PATH, and not owned by dpkg) outlives the install.

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
        cp /usr/bin/dcmd /usr/local/bin/dcmd
        mkdir -p /srcrepo
        cp /p/*.dsc /p/*.tar.* /srcrepo/
        cd /srcrepo && dpkg-scansources . > Sources && gzip -kf Sources
        echo "deb-src [trusted=yes] file:///srcrepo ./" \
            > /etc/apt/sources.list.d/local-src.list
        cd /p
        debrebuild --builder=dpkg --buildresult=/p/rebuilt "$(basename '"$buildinfo"')"
    '
