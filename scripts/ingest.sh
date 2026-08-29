#!/usr/bin/env bash
#
# Build-from-source ingest for the pkg.haus APT archive.
#
# The archive is fed from the packages enrolled in packages.txt, which live one
# directory each in pkghaus/packages: for each one, the newest tag under its own
# namespace is the release. Anything that tag should provide and
# the archive does not yet carry gets built with the deb-builder image and
# added to the aptly repo for its suite. Published pool files are never rebuilt
# or replaced -- a version, once in the archive, is immutable.
#
# Subcommands, designed around the CI job split:
#
#   plan             what is missing, as TSV on stdout (runs anywhere)
#   build <plan>     build this host's architecture's share of a plan
#   include <dir>    include built packages into the archive and re-export
#
# Layout: conf/ lives on master. aptly's state (its leveldb and its
# content-addressed pool) lives in $APTLY_ROOT, which CI checks out from the
# `aptly` branch; it is never served, and aptly cannot publish without the pool
# so it has to persist. The published tree goes to R2, not to disk.

set -euo pipefail
# Without this, set -e stops at the edge of a command substitution: a function
# called as x="$(f)" keeps running after a failure instead of aborting.
shopt -s inherit_errexit

# The single repository holding every package, one directory each. Overridable
# so the tests can point at a fixture; anything git clone accepts works.
PACKAGES_REPO="${PACKAGES_REPO:-pkghaus/packages}"
PACKAGES_FILE="${PACKAGES_FILE:-packages.txt}"
# Prefix a repo slug resolves against. Tests point it at a local directory of
# fixture repositories; anything git clone accepts works.
GIT_BASE="${GIT_BASE:-https://github.com/}"
IMAGE="${IMAGE:-ghcr.io/pkghaus/deb-builder}"
ARCHIVE_DIR="${ARCHIVE_DIR:-public}"
SUITES="${SUITES:-trixie testing unstable}"

# shellcheck source=scripts/aptly-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/aptly-lib.sh"

log() { printf '%s\n' "$*" >&2; }

die() {
    log "FATAL: $*"
    exit 1
}

ensure_repo() {
    local repo
    repo="$(repo_of "$1")"
    aptly_ repo show "$repo" >/dev/null 2>&1 && return 0
    aptly_ repo create -distribution="$1" -component=main "$repo" >/dev/null
    log "created aptly repo $repo"
}

# The suite qualifier, mirroring the deb-builder entrypoint. The stable release
# number is read from the stable builder image so plan and build can never
# disagree about it.
qualifier() {
    local suite="$1"

    case "$suite" in
        unstable | sid) ;;
        testing) printf '~testing1' ;;
        *)
            if [ -z "${STABLE_ID:-}" ]; then
                STABLE_ID="$(docker run --rm --entrypoint sh "$IMAGE:$suite" \
                    -c '. /etc/os-release && printf %s "${VERSION_ID:-}"')"
                [ -n "$STABLE_ID" ] || die "no VERSION_ID in $IMAGE:$suite"
            fi
            printf '~haus%s+1' "$STABLE_ID"
            ;;
    esac
}

# Non-zero when the repository could not be read, empty output when it has no
# tags. Those are different answers and the caller treats them differently: the
# listing used to be the head of a pipeline, so a failed ls-remote produced no
# output, exited 0 through tail, and was reported as "no tags" -- a network blip
# silently dropping a package from the plan under a message saying the upstream
# had never tagged anything.
# The newest tag belonging to one package. Tags are namespaced by package
# (croc/v11.3.4-1), so the package's own tags are the ones under its prefix and
# every other package's are noise.
#
# Matched by exact prefix rather than a regex: Debian source names may contain
# "." and "+", both of which mean something else to grep.
#
# Note this cannot use the old awk -F/ '{print $NF}': that takes the last path
# component, which turns refs/tags/croc/v11.3.4-1 into v11.3.4-1 and silently
# discards the package the tag belongs to.
newest_tag() {
    local pkg="$1" refs

    refs="$(git ls-remote --tags "${GIT_BASE}${PACKAGES_REPO}")" || return 1

    printf '%s\n' "$refs" \
        | awk '{print $2}' \
        | grep -v '\^{}$' \
        | sed 's|^refs/tags/||' \
        | awk -v p="$pkg/" 'index($0, p) == 1' \
        | sort -V \
        | tail -1
}

# Package name and version, from the tagged debian/changelog's first line:
#   zola (0.23.3-1) unstable; urgency=medium
changelog_header() {
    sed -n '1s/^\([a-z0-9.+-]\+\) (\([^)]*\)).*/\1 \2/p' "$1/debian/changelog"
}

# Whether every binary stanza in debian/control is Architecture: all. Such a
# package builds once -- one aptly repo add files the single .deb into every
# architecture's index -- so the plan emits one leg with arch "all" instead
# of one per architecture.
arch_all_only() {
    awk '/^Architecture:/ {n++; if ($2 != "all") dep=1} END {exit !(n && !dep)}' \
        "$1/debian/control"
}

# What the archive already carries. An Architecture: all package is filed once
# as _all and satisfies every architecture, which is what reprepro's per-arch
# listing expressed differently.
archived_version() {
    suite_contents "$1" "Name ($2)" \
        | awk -F'\t' -v want="$3" '$3 == want || $3 == "all" { print $2 }' \
        | head -n1
}

plan() {
    local arches="${1:-amd64 arm64}"
    local repo tag clone header pkg version suite arch expected have all_only missing
    # "repo" is the package directory now, kept as the plan row's first field so
    # the workflow that consumes it needs no change: it names what to check out.

    while read -r repo; do
        case "$repo" in ''|\#*) continue ;; esac
        repo="${repo%%[[:space:]]*}"

        tag="$(newest_tag "$repo")" || die "cannot read tags from $PACKAGES_REPO"
        # Not an error. A package with no tag has never been released from this
        # repository, which is exactly the state every package is in the moment
        # the archive is cut over: the archive already holds it, and there is
        # nothing to build until its next release.
        [ -n "$tag" ] || { log "SKIP $repo: no tags"; continue; }

        clone="$(mktemp -d)"
        git clone -q --depth 1 --branch "$tag" -- "${GIT_BASE}${PACKAGES_REPO}" "$clone"

        header="$(changelog_header "$clone/$repo")"
        all_only=0
        if arch_all_only "$clone/$repo"; then
            all_only=1
        fi
        rm -rf "$clone"
        [ -n "$header" ] || { log "SKIP $repo@$tag: unparsable debian/changelog"; continue; }
        pkg="${header% *}"
        version="${header#* }"

        for suite in $SUITES; do
            expected="${version}$(qualifier "$suite")"

            if [ "$all_only" = 1 ]; then
                # One leg; a single includedeb serves every architecture, so
                # the version must already sit in all of their indices to be
                # considered present.
                missing=0
                for arch in $arches; do
                    have="$(archived_version "$suite" "$pkg" "$arch")"
                    if [ "$have" != "$expected" ]; then
                        missing=1
                    fi
                done
                if [ "$missing" = 1 ]; then
                    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                        "$repo" "$tag" "$pkg" "$suite" "all" "$expected"
                fi
                continue
            fi

            for arch in $arches; do
                have="$(archived_version "$suite" "$pkg" "$arch")"

                if [ "$have" = "$expected" ]; then
                    continue
                fi

                printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                    "$repo" "$tag" "$pkg" "$suite" "$arch" "$expected"
            done
        done
    done < "$PACKAGES_FILE"
}

# The suite a package belongs to is recoverable from its version qualifier,
# which is the point of the qualifier scheme.
suite_of() {
    local version="$1"

    case "$version" in
        *~haus*) printf 'trixie' ;;
        *~testing*) printf 'testing' ;;
        *) printf 'unstable' ;;
    esac
}

include() {
    local dir="${1:?usage: ingest.sh include <dir>}"
    local deb version suite included=0 touched=""

    [ -d "$ARCHIVE_DIR" ] || mkdir -p "$ARCHIVE_DIR"

    require_r2

    for deb in "$dir"/*.deb; do
        [ -e "$deb" ] || die "no .deb files in $dir"

        version="$(dpkg-deb -f "$deb" Version)"
        suite="$(suite_of "$version")"

        log "INCLUDE $(basename "$deb") -> $suite"
        ensure_repo "$suite"
        aptly_ repo add "$(repo_of "$suite")" "$deb" >/dev/null
        prune_older "$suite" "$deb"
        touched="$touched$suite\n"
        included=$((included + 1))
    done

    # Publish once per touched suite rather than once per deb. First publish for
    # a suite creates the publish point; later ones update it in place.
    for suite in $(printf '%b' "$touched" | sort -u); do
        publish_suite "$suite"
    done

    log "included $included packages"
}

# One version per package per suite. reprepro enforced this because the trixie
# build has no multiple-version support; aptly keeps every version, so without
# this the archive would grow a version for every release ever made and the pool
# would never shrink. Scoped to the same architecture and to strictly older
# versions, so the amd64 and arm64 legs of one package cannot evict each other
# and the order they arrive in does not matter. -force-replace does not help:
# it resolves same-version conflicts, not older versions.
prune_older() {
    local suite="$1" deb="$2" pkg version arch removed
    pkg="$(dpkg-deb -f "$deb" Package)"
    version="$(dpkg-deb -f "$deb" Version)"
    arch="$(dpkg-deb -f "$deb" Architecture)"

    removed="$(aptly_ repo remove "$(repo_of "$suite")" \
        "Name ($pkg), \$Version (<< $version), \$Architecture ($arch)" 2>&1 \
        | grep -c '^\[-\]' || true)"
    [ "$removed" -gt 0 ] && log "PRUNE $pkg: dropped $removed older $arch version(s) from $suite"
    return 0
}

case "${1:-}" in
    plan)    shift; plan "$@" ;;
    include) shift; include "$@" ;;
    *)
        log "usage: $0 plan [arches] | include <dir>"
        exit 2
        ;;
esac
