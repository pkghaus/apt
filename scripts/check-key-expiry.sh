#!/usr/bin/env bash
#
# Warn while the archive signing key still has runway. Reads the exported
# key material from ARCHIVE_SIGNING_KEY, finds the soonest expiry across
# the primary key and every subkey, and emits a GitHub Actions warning
# annotation when fewer than 90 days remain. An already-expired key fails
# the run: publishing would produce an archive clients reject, so a loud
# stop with the reason beats a signing failure downstream.
#
# Runs in the plan job so every ingest surfaces it, dispatch or push alike.

set -euo pipefail

WARN_DAYS=90
: "${ARCHIVE_SIGNING_KEY:?exported signing key material}"

now="$(date +%s)"

# --show-keys reads key material from stdin without touching a keyring.
# Colon format: field 1 is the record type (pub/sub for public material,
# sec/ssb for secret material), field 7 the expiry epoch (empty = never).
soonest="$(printf '%s' "$ARCHIVE_SIGNING_KEY" \
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
    echo "::warning title=Archive signing key expires soon::$days days left (expires $when); rotate per the signing runbook"
else
    echo "signing key expiry $when ($days days away)" >&2
fi
