#!/usr/bin/env bash
#
# Maintains the archive's news log: news/news.jsonl on the archive branch,
# an append-only event stream the renderer turns into /news/ and its RSS
# feed. Events are derived mechanically by diffing the package set against
# the previous publish (news/known-packages.tsv); updates whose changelog
# head says urgency high or above are flagged as security events. Notices
# (rare, human-authored) merge in from scripts/news-notices.jsonl on the
# master checkout, deduplicated by line.
#
# First run: seeds the log from scripts/news-seed.jsonl and snapshots the
# package set without emitting events (the seed narrates prior history).
#
# Event fields are written and parsed in fixed order (ts, type, title,
# detail, pkgs) with no double quotes in any value; the renderer's
# extraction depends on both. pkgs is space-separated name=version pairs
# (version empty for retired packages).

set -euo pipefail

ARCHIVE_DIR="${ARCHIVE_DIR:-public}"
BUILD_DIR="${BUILD_DIR:-build}"
NEWS_DIR="$ARCHIVE_DIR/news"
SEED="${SEED:-scripts/news-seed.jsonl}"
NOTICES="${NOTICES:-scripts/news-notices.jsonl}"

log() { printf '%s\n' "$*" >&2; }

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$NEWS_DIR"

emit() { # type title detail pkgs
    printf '{"ts":"%s","type":"%s","title":"%s","detail":"%s","pkgs":"%s"}\n' \
        "$now" "$1" "$2" "$3" "$4" >> "$NEWS_DIR/news.jsonl"
    log "NEWS $1: $2"
}

# The latest changelog entry's urgency, read out of the built package
# itself (native packages ship changelog.gz, non-native ones
# changelog.Debian.gz). Empty when no deb for the package is in this run.
urgency_of() {
    local pkg="$1" deb entry
    for deb in "$BUILD_DIR/${pkg}_"*.deb; do
        [ -e "$deb" ] || return 0
        for entry in "changelog.Debian.gz" "changelog.gz"; do
            dpkg-deb --fsys-tarfile "$deb" 2>/dev/null \
                | tar -xO "./usr/share/doc/$pkg/$entry" 2>/dev/null \
                | gunzip 2>/dev/null | head -n1 \
                | grep -o 'urgency=[a-z]*' | cut -d= -f2 && return 0
        done
        return 0
    done
}

# Current package set; unstable carries the plain version. Both
# architecture lines collapse under sort -u.
current="$(mktemp)"
if [ -d "$ARCHIVE_DIR/db" ]; then
    reprepro -b "$ARCHIVE_DIR" --confdir ./conf list unstable 2>/dev/null \
        | awk '{print $2 "\t" $3}' | LC_ALL=C sort -u > "$current"
else
    : > "$current"
fi

known="$NEWS_DIR/known-packages.tsv"

if [ ! -f "$NEWS_DIR/news.jsonl" ]; then
    if [ -f "$SEED" ]; then
        cp "$SEED" "$NEWS_DIR/news.jsonl"
        log "seeded news log from $SEED"
    else
        : > "$NEWS_DIR/news.jsonl"
    fi
fi

if [ ! -f "$known" ]; then
    # First run: the seed covers history; snapshot silently.
    cp "$current" "$known"
    log "bootstrapped known-packages.tsv with $(wc -l < "$known") packages, no events emitted"
else
    while IFS="$(printf '\t')" read -r pkg ver; do
        [ -n "$pkg" ] || continue
        old="$(awk -F'\t' -v p="$pkg" '$1==p {print $2}' "$known")"
        if [ -z "$old" ]; then
            emit added "added: $pkg $ver" \
                "Joins the archive in all three suites." "$pkg=$ver"
        elif [ "$old" != "$ver" ]; then
            u="$(urgency_of "$pkg" || true)"
            case "$u" in
                high|critical|emergency)
                    emit security "security: $pkg $ver" \
                        "Updated from $old (urgency=$u)." "$pkg=$ver" ;;
                *)
                    emit updated "updated: $pkg $ver" \
                        "Updated from $old." "$pkg=$ver" ;;
            esac
        fi
    done < "$current"

    while IFS="$(printf '\t')" read -r pkg ver; do
        [ -n "$pkg" ] || continue
        if ! grep -q "^$pkg$(printf '\t')" "$current"; then
            emit retired "retired: $pkg" "Left the archive." "$pkg="
        fi
    done < "$known"

    cp "$current" "$known"
fi

if [ -f "$NOTICES" ]; then
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        if ! grep -qxF "$line" "$NEWS_DIR/news.jsonl"; then
            printf '%s\n' "$line" >> "$NEWS_DIR/news.jsonl"
            log "NEWS notice merged"
        fi
    done < "$NOTICES"
fi

rm -f "$current"
