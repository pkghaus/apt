#!/usr/bin/env bash
#
# Assert that the R2 archive carries everything a reference archive carries, at
# the same pool path and the same SHA256.
#
#   SOURCE_URL=https://apt.pkg.haus scripts/compare-archives.sh
#
# Paths matter as much as contents: an apt client that ran "update" before the
# cutover holds the old Filename values, and a CDN edge holds objects under
# them. A package that moved would 404 for both even though its bytes are
# there. Extra packages in R2 are not an error -- an ingest may have run since
# the reference archive was read.

set -euo pipefail
# Without this, set -e stops at the edge of a command substitution: a function
# called as x="$(f)" keeps running after a failure instead of aborting.
shopt -s inherit_errexit

SOURCE_URL="${SOURCE_URL:-https://apt.pkg.haus}"
SUITES="${SUITES:-trixie testing unstable}"
ARCHES="${ARCHES:-amd64 arm64}"

# shellcheck source=scripts/aptly-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/aptly-lib.sh"

require_r2

# "<suite>/<arch> <pool-path> <sha256>", one line per published package.
index_triples() {
    local reader="$1" suite arch
    for suite in $SUITES; do
        for arch in $ARCHES; do
            "$reader" "$suite" "$arch" | awk -v k="$suite/$arch" '
                /^Filename: / { f = $2 }
                /^SHA256: /   { h = $2 }
                /^$/          { if (f != "") print k, f, h; f = ""; h = "" }
                END           { if (f != "") print k, f, h }'
        done
    done | LC_ALL=C sort
}

# Tolerant for the same reason index_text is: the emptiness check below is the
# diagnostic, not a pipeline dying mid-read.
source_index() {
    curl -fsSL --max-time 120 "$SOURCE_URL/dists/$1/main/binary-$2/Packages.gz" \
        | gunzip 2>/dev/null || true
}

before="$(mktemp)"; after="$(mktemp)"
index_triples source_index > "$before"
index_triples index_text   > "$after"

[ -s "$before" ] || { printf 'FATAL: %s published no packages to compare against\n' "$SOURCE_URL" >&2; exit 1; }

missing="$(LC_ALL=C comm -23 "$before" "$after")"
extra="$(LC_ALL=C comm -13 "$before" "$after")"

printf 'source: %s lines, R2: %s lines\n' "$(wc -l < "$before")" "$(wc -l < "$after")" >&2
if [ -n "$extra" ]; then
    printf 'only in R2 (newer ingest, not an error):\n%s\n' "$extra" >&2
fi
if [ -n "$missing" ]; then
    printf 'MISSING from R2, or at a different path or hash:\n%s\n' "$missing" >&2
    exit 1
fi
printf 'every published package matched by suite, arch, path and SHA256\n' >&2
