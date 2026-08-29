#!/usr/bin/env bash
#
# Warn while the archive signing key still has runway. Finds the soonest
# expiry across the primary key and every subkey and emits a GitHub Actions
# annotation. An already-expired key always fails: publishing would produce
# an archive clients reject, so a loud stop with the reason beats a signing
# failure downstream.
#
#   check-key-expiry.sh              key material from $ARCHIVE_SIGNING_KEY
#   check-key-expiry.sh <file>       key material from a file
#
# Two callers, deliberately different in how loud they are:
#
#   ingest.yml    the secret, warn only. An ingest at 89 days must still
#                 publish; the key is valid and refusing would be worse than
#                 the warning.
#   archive-health.yml
#                 the PUBLISHED public keyring, FAIL_ON_WARN=1. The ingest is
#                 event-driven, so a quiet fleet can sit out the whole 90-day
#                 window without ever running the check -- the first signal
#                 would be every apt client rejecting the archive. A daily
#                 scheduled job that goes red is the signal that survives a
#                 quiet fleet, and it blocks nothing by failing. Reading the
#                 public copy needs no secret in a second workflow, and has
#                 the side benefit of checking the key clients actually get.

set -euo pipefail
# Without this, set -e stops at the edge of a command substitution: a function
# called as x="$(f)" keeps running after a failure instead of aborting.
shopt -s inherit_errexit

WARN_DAYS="${WARN_DAYS:-90}"
FAIL_ON_WARN="${FAIL_ON_WARN:-0}"

# Streamed, never slurped into a variable: the published keyring is binary
# OpenPGP and command substitution drops its null bytes, which leaves gpg
# reading a truncated packet and reporting no keys at all.
if [ "$#" -gt 0 ]; then
    KEYFILE="$1"
    [ -s "$KEYFILE" ] || { echo "no key material in $KEYFILE" >&2; exit 1; }
    key_material() { cat "$KEYFILE"; }
else
    : "${ARCHIVE_SIGNING_KEY:?exported signing key material}"
    key_material() { printf '%s' "$ARCHIVE_SIGNING_KEY"; }
fi

now="$(date +%s)"

# --show-keys reads key material from stdin without touching a keyring.
# Colon format: field 1 is the record type (pub/sub for public material,
# sec/ssb for secret material), field 7 the expiry epoch (empty = never).
soonest="$(key_material \
    | gpg --batch --show-keys --with-colons 2>/dev/null \
    | awk -F: '($1 ~ /^(pub|sub|sec|ssb)$/) && $7 != "" {print $7}' \
    | sort -n | head -1)"

if [ -z "$soonest" ]; then
    echo "signing key carries no expiry" >&2
    exit 0
fi

days=$(( (soonest - now) / 86400 ))
when="$(date -u -d "@$soonest" '+%Y-%m-%d %H:%M:%S UTC')"

if [ "$soonest" -le "$now" ]; then
    echo "::error title=Archive signing key expired::expired $when; rotate per the signing runbook before publishing"
    exit 1
elif [ "$days" -lt "$WARN_DAYS" ]; then
    if [ "$FAIL_ON_WARN" = "1" ]; then
        echo "::error title=Archive signing key expires soon::$days days left (expires $when); rotate per the signing runbook"
        exit 1
    fi
    echo "::warning title=Archive signing key expires soon::$days days left (expires $when); rotate per the signing runbook"
else
    echo "signing key expiry $when ($days days away)" >&2
fi
