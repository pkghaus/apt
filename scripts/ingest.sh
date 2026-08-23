#!/usr/bin/env bash
#
# Build-from-source ingest for the pkg.haus APT archive.
#
# The archive is fed from the packaging repositories listed in repos.txt: for
# each one, the newest tag is the release. Anything that tag should provide and
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

REPOS_FILE="${REPOS_FILE:-repos.txt}"
# Prefix a repo slug resolves against. Tests point it at a local directory of
# fixture repositories; anything git clone accepts works.
GIT_BASE="${GIT_BASE:-https://github.com/}"
IMAGE="${IMAGE:-ghcr.io/pkghaus/deb-builder}"
ARCHIVE_DIR="${ARCHIVE_DIR:-public}"
BUILD_DIR="${BUILD_DIR:-build}"
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

newest_tag() {
    local repo="$1"

    git ls-remote --tags "${GIT_BASE}${repo}" \
        | awk -F/ '{print $NF}' \
        | grep -v '\^{}$' \
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

    while read -r repo; do
        case "$repo" in ''|\#*) continue ;; esac

        tag="$(newest_tag "$repo")"
        [ -n "$tag" ] || { log "SKIP $repo: no tags"; continue; }

        clone="$(mktemp -d)"
        git clone -q --depth 1 --branch "$tag" -- "${GIT_BASE}${repo}" "$clone"

        header="$(changelog_header "$clone")"
        all_only=0
        if arch_all_only "$clone"; then
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
    done < "$REPOS_FILE"
}

build() {
    local plan_file="${1:?usage: ingest.sh build <plan.tsv> [suite] [repo]}"
    local only_suite="${2:-}"
    local only_repo="${3:-}"
    local host_arch repo tag suite clone built
    host_arch="$(dpkg --print-architecture)"

    mkdir -p "$BUILD_DIR"

    # One build covers one (repo, tag, suite) on this host's architecture; the
    # plan's arch column just decides whether this host owes it. Rows planned
    # as "all" build on whichever host picks them up (in CI that is the row's
    # single leg). Optional suite and repo arguments narrow the share further,
    # so CI can fan the plan out across a package x suite x arch matrix;
    # without them, all suites build serially.
    awk -F'\t' -v arch="$host_arch" -v only="$only_suite" -v ronly="$only_repo" \
        '($5 == arch || $5 == "all") && (only == "" || $4 == only) && (ronly == "" || $1 == ronly) {print $1 "\t" $2 "\t" $4}' \
        "$plan_file" | sort -u \
        | while IFS="$(printf '\t')" read -r repo tag suite; do
            log "BUILD $repo@$tag for $suite/$host_arch"

            clone="$(mktemp -d)"
            git clone -q --depth 1 --branch "$tag" -- "${GIT_BASE}${repo}" "$clone"

            docker run --rm \
                --volume "$clone:/target" \
                --workdir /target \
                "$IMAGE:$suite"

            built=0
            for deb in "$clone"/debs/*.deb; do
                [ -e "$deb" ] || break
                install -m 0644 "$deb" "$BUILD_DIR/"
                built=$((built + 1))
            done
            [ "$built" -gt 0 ] || die "$repo@$tag produced no packages for $suite"

            rm -rf "$clone"
        done

    log "built artifacts:"
    ls -l "$BUILD_DIR" >&2
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
    build)   shift; build "$@" ;;
    include) shift; include "$@" ;;
    *)
        log "usage: $0 plan [arches] | build <plan.tsv> [suite] [repo] | include <dir>"
        exit 2
        ;;
esac
