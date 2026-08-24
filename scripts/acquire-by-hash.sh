#!/usr/bin/env bash
#
# Turn Acquire-By-Hash on or off for published suites.
#
#   acquire-by-hash.sh <on|off> [suite ...]
#
# Acquire-By-Hash lets apt fetch an index at a content-addressed URL
# (by-hash/SHA256/<hash>) instead of a mutable one. A client that has read
# InRelease and then fetches Packages.gz after a publish rewrote it gets a hash
# mismatch; with by-hash the file it asks for cannot change under it.
#
# aptly exposes -acquire-by-hash only on `publish repo`, never on `publish
# update`, which reads as "you must drop and recreate the publish point". It is
# in fact a persisted field, and the API sets it on an existing one. That
# matters because `publish drop` has no -skip-cleanup, and three suites share
# one pool prefix.
#
# The publish is re-signed, so this needs the archive key and therefore runs in
# CI. Afterwards the flag lives in the database, and ordinary CLI publishes
# keep it -- verified, including a publish that adds a package.

set -euo pipefail

STATE="${1:?usage: acquire-by-hash.sh <on|off> [suite ...]}"
shift
SUITES_ARG=("$@")

case "$STATE" in
    on)  WANT=true ;;
    off) WANT=false ;;
    *)   printf 'FATAL: first argument must be on or off\n' >&2; exit 1 ;;
esac

# shellcheck source=scripts/aptly-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/aptly-lib.sh"

require_r2
if [ "${#SUITES_ARG[@]}" -eq 0 ]; then
    read -r -a SUITES_ARG <<< "${SUITES:-trixie testing unstable}"
fi

log() { printf '%s\n' "$*" >&2; }

PORT="${APTLY_API_PORT:-8080}"
BASE="http://127.0.0.1:$PORT"

write_aptly_conf
aptly -config="$APTLY_CONF" api serve -listen="127.0.0.1:$PORT" >/tmp/aptly-api.log 2>&1 &
API=$!
cleanup() {
    kill "$API" 2>/dev/null || true
    wait "$API" 2>/dev/null || true
}
trap cleanup EXIT

for _ in $(seq 1 60); do
    curl -fsS "$BASE/api/version" >/dev/null 2>&1 && break
    sleep 0.5
done
curl -fsS "$BASE/api/version" >/dev/null 2>&1 || { log "FATAL: aptly api did not start"; cat /tmp/aptly-api.log >&2; exit 1; }

published_flag() {  # suite -> true/false/absent
    curl -fsS "$BASE/api/publish" 2>/dev/null | python3 -c "
import json,sys
want = sys.argv[1]
for p in json.load(sys.stdin):
    if p.get('Distribution') == want:
        print(str(p.get('AcquireByHash')).lower()); break
else:
    print('absent')" "$1"
}

# The API addresses a publish point by <storage>:<prefix> with slashes written
# as colons, and an empty prefix written as a dot. Read both from the API
# rather than deriving them from PUBLISH_TARGET, which renders the root prefix
# differently depending on who is printing it.
publish_path() {  # suite -> e.g. s3:r2:. or s3:r2:abhtest
    curl -fsS "$BASE/api/publish" 2>/dev/null | python3 -c "
import json,sys
want = sys.argv[1]
for p in json.load(sys.stdin):
    if p.get('Distribution') == want:
        storage = p.get('Storage') or ''
        prefix = p.get('Prefix') or ''
        prefix = prefix.replace('/', ':') or '.'
        print(f'{storage}:{prefix}' if storage else prefix)
        break" "$1"
}

for suite in "${SUITES_ARG[@]}"; do
    before="$(published_flag "$suite")"
    if [ "$before" = absent ]; then
        log "FATAL: $suite is not published to $PUBLISH_TARGET"
        exit 1
    fi
    if [ "$before" = "$WANT" ]; then
        log "$suite: already $STATE"
        continue
    fi

    log "$suite: $before -> $WANT"
    curl -sS --fail-with-body -X PUT \
        -H 'Content-Type: application/json' \
        --data "{\"AcquireByHash\": $WANT, \"Signing\": {\"GpgKey\": \"$SIGN_KEY\", \"Batch\": true}}" \
        "$BASE/api/publish/$(publish_path "$suite")/$suite" >/dev/null

    # The PUT queues the publish as a background task, so the database write
    # lands after the response. Shutting the server down in between loses the
    # flag and reads exactly like aptly refusing to persist it -- that cost two
    # false negatives while this was being worked out. Poll the server's own
    # view before moving on.
    for _ in $(seq 1 120); do
        [ "$(published_flag "$suite")" = "$WANT" ] && break
        sleep 1
    done
    got="$(published_flag "$suite")"
    [ "$got" = "$WANT" ] || { log "FATAL: $suite still reports AcquireByHash=$got"; exit 1; }
    log "$suite: confirmed $got"
done
