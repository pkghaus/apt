#!/usr/bin/env bash
#
# Assert that a rebuilt aptly database holds exactly what a reference archive
# publishes.
#
#   SOURCE_URL=https://apt.pkg.haus scripts/verify-rebuild.sh
#
# The other half of the recovery drill. seed-aptly.sh with SEED_PUBLISH=off
# rebuilds the database from a published archive without writing anything; this
# says whether what came out is the archive. Without it the drill only proves
# the script exits 0, which it would also do having seeded half the fleet.
#
# Compared on suite, name and version, deliberately not on architecture. An
# arch-all package appears in every arch index of the reference but once in
# aptly, so folding the architecture out is what lets the two sets be equal.
# That is a real difference in shape, not a looser test: seed-aptly stages by
# suite, and whether a given .deb reached the right suite is the question.
#
# Read-only, and needs no credentials: the reference is fetched over HTTPS from
# the published archive rather than from the bucket.

set -euo pipefail
shopt -s inherit_errexit

# shellcheck source=scripts/aptly-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/aptly-lib.sh"

SOURCE_URL="${SOURCE_URL:-https://apt.pkg.haus}"
SUITES="${SUITES:-trixie testing unstable}"
ARCHES="${ARCHES:-amd64 arm64}"

# Overridden in the tests, which have no network.
reference_index() { # suite arch
    curl -fsSL --max-time 120 "$SOURCE_URL/dists/$1/main/binary-$2/Packages.gz" | gunzip
}

# "<suite> <name> <version>", one line per published binary.
reference_set() { # reader
    local reader="$1" suite arch
    for suite in $SUITES; do
        for arch in $ARCHES; do
            "$reader" "$suite" "$arch" \
                | awk -v s="$suite" '/^Package: /{p=$2} /^Version: /{if(p!=""){print s, p, $2; p=""}}'
        done
    done | LC_ALL=C sort -u
}

# The same, out of the local aptly database.
rebuilt_set() {
    local suite
    for suite in $SUITES; do
        suite_contents "$suite" | awk -v s="$suite" -F'\t' '{print s, $1, $2}'
    done | LC_ALL=C sort -u
}

# shellcheck disable=SC2317
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    return 0
fi

want="$(mktemp)"; got="$(mktemp)"
trap 'rm -f "$want" "$got"' EXIT

reference_set reference_index > "$want"
rebuilt_set > "$got"

# An empty reference is a broken fetch, not an empty archive. Reporting "they
# match" for two empty sets is the failure this guards.
[ -s "$want" ] || { printf 'FATAL: %s published nothing to compare against\n' "$SOURCE_URL" >&2; exit 1; }

printf 'reference: %s published, rebuilt: %s\n' "$(wc -l < "$want")" "$(wc -l < "$got")" >&2

missing="$(LC_ALL=C comm -23 "$want" "$got")"
extra="$(LC_ALL=C comm -13 "$want" "$got")"

if [ -n "$missing" ]; then
    printf 'MISSING from the rebuild:\n%s\n' "$missing" >&2
fi
if [ -n "$extra" ]; then
    printf 'in the rebuild but not the reference:\n%s\n' "$extra" >&2
fi
[ -z "$missing" ] && [ -z "$extra" ] || exit 1

printf 'the rebuild reproduces the archive exactly\n' >&2
