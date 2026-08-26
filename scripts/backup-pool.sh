#!/usr/bin/env bash
#
# Copy every published .deb into a second R2 bucket.
#
# R2 has no object versioning -- it is a standing feature request, not a
# setting -- so a mis-scoped delete against the archive bucket is unrecoverable
# from R2 alone. seed-aptly.sh rebuilds the database from the published
# archive, but it cannot rebuild the archive, and a rebuild from upstream tags
# produces different bytes under versions that are already published.
#
# The copy is additive on purpose: no --delete. A published version's bytes
# never change, so an append-only mirror is a complete record of every version
# the archive has ever carried -- strictly more than object versioning would
# give, and it survives the archive bucket losing an object to a prune, a
# retirement, or a mistake.
#
# Only the pool is copied. The indices are regenerable from the database and
# the pool; the .debs are not regenerable at all.
#
# Runs after a publish, which is the only moment new pool objects exist.

set -euo pipefail
# Without this, set -e does not reach inside a command substitution, so a
# function called as x="$(f)" runs to completion after a failure instead of
# aborting. count_debs below is called exactly that way.
shopt -s inherit_errexit

# The AWS CLI switches to a multipart copy above 8 MB, and its multipart path
# calls GetObjectTagging, which R2 does not implement -- so every .deb over
# 8 MB fails while the small ones succeed. Raising the threshold past anything
# the archive will ever hold keeps every object on the single-part CopyObject
# path, which R2 does support. 5 GB is R2's own single-object limit; the
# largest deb here is about 30 MB.
AWS_CONFIG_FILE="$(mktemp)"
export AWS_CONFIG_FILE
trap 'rm -f "$AWS_CONFIG_FILE"' EXIT
cat > "$AWS_CONFIG_FILE" <<'CONF'
[default]
s3 =
    multipart_threshold = 5GB
CONF

# shellcheck source=scripts/aptly-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/aptly-lib.sh"

: "${R2_BACKUP_BUCKET:?the bucket to mirror the pool into}"
require_r2

if [ "$R2_BACKUP_BUCKET" = "$R2_BUCKET" ]; then
    printf 'FATAL: the backup bucket is the archive bucket\n' >&2
    exit 1
fi

# Two steps on purpose. `grep -c` exits 1 when it matches nothing, so the count
# needs `|| true`; run as one pipeline that also discarded stderr, a listing that
# could not be read was indistinguishable from an empty bucket, and the safety
# check below compares two numbers that both quietly meant "no idea". The
# listing is its own command so set -e still sees it fail.
count_debs() {
    local listing
    listing="$(aws_ s3 ls "$1" --recursive)"
    printf '%s' "$listing" | grep -c '\.deb$' || true
}

before="$(count_debs "s3://$R2_BACKUP_BUCKET/pool/")"

# Server-side copy: both buckets are in the same account, so no bytes traverse
# the runner and nothing is billed for egress.
aws_ s3 sync "s3://$R2_BUCKET/pool/" "s3://$R2_BACKUP_BUCKET/pool/" --only-show-errors

after="$(count_debs "s3://$R2_BACKUP_BUCKET/pool/")"
live="$(count_debs "s3://$R2_BUCKET/pool/")"

printf 'pool backup: %s debs live, %s in the mirror (+%s this run)\n' \
    "$live" "$after" "$((after - before))" >&2

# The mirror is append-only, so it may legitimately hold more than the archive
# does -- a pruned version stays. Fewer means the copy did not complete.
if [ "$after" -lt "$live" ]; then
    printf 'FATAL: the mirror holds fewer debs (%s) than the archive (%s)\n' "$after" "$live" >&2
    exit 1
fi
