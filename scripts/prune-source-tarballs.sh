#!/usr/bin/env bash
#
# Delete source tarballs, oldest first, only when the bucket is near its budget.
#
#   prune-source-tarballs.sh [--dry-run]
#
# The archive keeps one version per package per suite -- prune_older() in
# ingest.sh enforces it, because aptly keeps every version and the pool would
# otherwise grow one for every release ever made. Build records do not follow
# that rule: a .buildinfo, .dsc and .source are a few kilobytes each and are
# kept forever, because they are the evidence and the evidence is cheap.
#
# Source tarballs sit between the two. One generation across the fleet is
# 119 MB and the measured cadence (143 upstream releases in twelve months,
# weighted by each package's source size) puts additive growth at 836 MB a
# year, against a 10 GB free tier and a pool flat at 623 MB. That is roughly
# nine years of headroom, or a little over two if the fleet doubles and churns
# twice as fast.
#
# So they are kept for as long as they can be afforded rather than for as long
# as the .deb is served. Deleting on the narrower rule was the first design and
# it was wrong on the facts: a version leaving the pool does not make its
# tarball useless, because the .deb it describes is still installed on machines,
# still in apt caches, still in container layers, and "is what I have what you
# claim" is the question a rebuild answers. It also left the .buildinfo and .dsc
# we keep forever pointing at bytes that no longer exist, which is the same
# readable-but-not-actionable failure that publishing the source was meant to
# end.
#
# What survives from that design is the safety: nothing a published version
# needs is ever deleted, whatever the budget says. If the bucket cannot be
# brought under budget without touching a live tarball, this says so and stops.
#
# The keep set is read out of the .dsc files rather than assembled from
# filenames. Every fleet package currently produces one binary whose name
# matches its source, so "<name>_<version>.orig.tar.gz" would work today and
# would silently delete a live tarball the first time that stops being true.
#
# Deleting is the dangerous direction and skipping is free, so any error at all
# means nothing is deleted this run. The next run retries.

set -euo pipefail
# Without this, set -e stops at the edge of a command substitution.
shopt -s inherit_errexit

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

# shellcheck source=scripts/aptly-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/aptly-lib.sh"

SUITES="${SUITES:-trixie testing unstable}"
PREFIX="${BUILDINFO_PREFIX:-buildinfo}"

# 8 GiB of the free tier's 10, leaving room for the pool to grow and for the
# gap between a publish and this step running.
BUCKET_BUDGET_BYTES="${BUCKET_BUDGET_BYTES:-8589934592}"

require_r2

keep="$(mktemp)"
stored="$(mktemp)"
cand="$(mktemp)"
partial="$(mktemp)"
trap 'rm -f "$keep" "$stored" "$cand" "$partial"' EXIT

# The whole bucket, once. It answers three questions: what the total is, which
# tarballs exist and how old they are, and whether a .dsc that cannot be read is
# genuinely absent or merely unreadable. Without that last distinction one
# timed-out read would delete a live version's tarballs.
aws_ s3 ls "s3://$R2_BUCKET/" --recursive > "$stored"

total="$(awk '{s += $3} END {printf "%d", s}' "$stored")"

printf 'bucket: %s MB of %s MB budget\n' \
    "$((total / 1024 / 1024))" "$((BUCKET_BUDGET_BYTES / 1024 / 1024))" >&2

# --- what every published version needs --------------------------------------
live=0
for suite in $SUITES; do
    while IFS=$'\t' read -r name version _arch; do
        [ -n "$name" ] || continue
        live=$((live + 1))

        key="$PREFIX/${name:0:1}/$name/${name}_${version}.dsc"

        # A version published before source packages shipped has no .dsc, and
        # therefore no tarballs either. Recording the source as incomplete
        # rather than skipping outright, because "this version contributes
        # nothing to keep" and "this version's tarballs are safe to delete" are
        # different claims and only the first one follows.
        if ! awk '{print $4}' "$stored" | grep -qxF "$key"; then
            printf '%s\n' "$PREFIX/${name:0:1}/$name/" >> "$partial"
            continue
        fi

        # Listed but unreadable is a different thing entirely, and the keep set
        # would be silently short by one version's worth of tarballs.
        if ! body="$(aws_ s3 cp "s3://$R2_BUCKET/$key" - 2>/dev/null)"; then
            printf 'FATAL: %s is stored but could not be read; nothing pruned\n' \
                "$key" >&2
            exit 1
        fi

        # Every file the .dsc references, from the checksum block dpkg always
        # writes, recorded with the same key prefix the tarballs live under so
        # the comparison below is over whole keys.
        printf '%s\n' "$body" |
            awk -v p="$PREFIX/${name:0:1}/$name/" \
                '/^Checksums-Sha256:/ {inblock=1; next}
                 inblock && /^ / {print p $3; next}
                 inblock {exit}' >> "$keep"
    done < <(suite_contents "$suite")
done

sort -u -o "$keep" "$keep"
sort -u -o "$partial" "$partial"

# --- under budget is the normal case -----------------------------------------
if [ "$total" -le "$BUCKET_BUDGET_BYTES" ]; then
    printf 'under budget, keeping every source tarball (%s published version(s))\n' \
        "$live" >&2
    exit 0
fi

# Nothing published, but the bucket is over budget. Reachable only if the aptly
# state failed to restore, and acting on it would delete every tarball there is.
if [ "$live" -eq 0 ]; then
    printf 'FATAL: over budget with no published versions found; refusing to\n' >&2
    printf '       treat that as "everything is orphaned"\n' >&2
    exit 1
fi

# --- oldest first, and only what nothing needs -------------------------------
# publish-buildinfo.sh uploads the .dsc before the tarballs it describes, so a
# half-finished publish leaves a .dsc with no tarballs rather than the reverse;
# the $partial check should not fire in normal operation. It exists because the
# reverse would be indistinguishable from "everything here is orphaned".
awk -v p="$PREFIX/" '$4 ~ ("^" p) && $4 ~ /\.tar\.[a-z0-9]+$/ {print $1 "T" $2, $3, $4}' \
    "$stored" | sort > "$cand"

over=$((total - BUCKET_BUDGET_BYTES))
printf 'over budget by %s MB; deleting oldest tarballs no published version needs\n' \
    "$((over / 1024 / 1024))" >&2

deleted=0
freed=0
while read -r _stamp size key; do
    [ "$freed" -lt "$over" ] || break
    [ -n "$key" ] || continue

    grep -qxF "$key" "$keep" && continue
    grep -qF "$(dirname "$key")/" "$partial" && continue

    if [ "$DRY_RUN" = 1 ]; then
        printf 'would delete %s\n' "$key" >&2
    else
        aws_ s3 rm "s3://$R2_BUCKET/$key" --only-show-errors
    fi
    deleted=$((deleted + 1))
    freed=$((freed + size))
done < "$cand"

printf 'freed %s MB across %s tarball(s)%s\n' \
    "$((freed / 1024 / 1024))" "$deleted" \
    "$([ "$DRY_RUN" = 1 ] && echo ' (dry run)' || echo '')" >&2

# Everything left belongs to a published version. Growth has outrun the budget
# rather than orphans accumulating, and only a bigger budget or a smaller fleet
# fixes that.
if [ "$freed" -lt "$over" ]; then
    printf 'FATAL: still %s MB over budget with nothing left that is safe to\n' \
        "$(((over - freed) / 1024 / 1024))" >&2
    printf '       delete. Raise BUCKET_BUDGET_BYTES or move off the free tier.\n' >&2
    exit 1
fi
