#!/usr/bin/env bash
#
# Reports which enrolled packages have fallen behind their upstream.
# Needs bash and curl; uses gh or jq when present. No state, no writes.
# Output is a markdown table on stdout.
#
# Exit status: 0 all current, 1 drift, 2 a lookup failed. A failed lookup
# is never reported as current -- a false all-clear is worse than no
# watcher.
#
# Enrollment (repos.txt) is the source of truth, so retired packages
# leave the report on their own.
#
# Versions compare as STRINGS: package.conf's VERSION is the upstream tag
# verbatim, and the fleet carries 2.13.c.5, 1.0.5.2 and a date-shaped
# 2026.08.15, which no ordering scheme survives intact.

set -euo pipefail
# Without this, set -e stops at the edge of a command substitution: a function
# called as x="$(f)" keeps running after a failure instead of aborting.
shopt -s inherit_errexit

REPOS_FILE="${REPOS_FILE:-repos.txt}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com}"
API_BASE="${API_BASE:-https://api.github.com}"

# gh first (it carries its own auth), then a token from the environment,
# then anonymous. Anonymous works but shares a 60-requests-per-hour pool,
# which one full run very nearly exhausts.
api() {
    local path="$1"
    if command -v gh >/dev/null 2>&1; then
        gh api "$path" 2>/dev/null
    elif [ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]; then
        curl -fsS -H "Authorization: Bearer ${GH_TOKEN:-$GITHUB_TOKEN}" \
            -H "Accept: application/vnd.github+json" "$API_BASE/$path" 2>/dev/null
    else
        curl -fsS -H "Accept: application/vnd.github+json" \
            "$API_BASE/$path" 2>/dev/null
    fi
}

# One field out of a JSON body, without requiring jq to be installed.
json_field() {
    if command -v jq >/dev/null 2>&1; then
        jq -r "$2 // empty"
    else
        sed -n "s/.*\"${1}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n1
    fi
}

# The newest upstream tag. releases/latest is authoritative where it
# exists: it already excludes prereleases (lychee publishes a rolling
# "nightly" that would otherwise win) and it follows a project's own
# notion of a release, including workspace-prefixed schemes like
# lychee-v0.24.2. Projects that publish no releases at all (gotypist)
# fall back to the tag list, sorted properly rather than trusting the
# API's unspecified ordering.
latest_tag() {
    local repo="$1" body tag
    if body="$(api "repos/$repo/releases/latest")" && [ -n "$body" ]; then
        tag="$(printf '%s' "$body" | json_field tag_name '.tag_name')"
        if [ -n "$tag" ]; then
            printf '%s\n' "$tag"
            return 0
        fi
    fi
    if body="$(api "repos/$repo/tags?per_page=100")" && [ -n "$body" ]; then
        if command -v jq >/dev/null 2>&1; then
            tag="$(printf '%s' "$body" | jq -r '.[].name' | sort -V | tail -n1)"
        else
            tag="$(printf '%s' "$body" | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sort -V | tail -n1)"
        fi
        [ -n "$tag" ] && { printf '%s\n' "$tag"; return 0; }
    fi
    return 1
}

drift=0
failed=0
rows=""
checked=0

while read -r repo; do
    case "$repo" in ''|\#*) continue ;; esac
    repo="${repo%%[[:space:]]*}"
    checked=$((checked + 1))

    conf="$(curl -fsS "$RAW_BASE/$repo/HEAD/package.conf" 2>/dev/null || true)"
    if [ -z "$conf" ]; then
        rows="$rows| \`${repo##*/}\` | ? | ? | no package.conf on the default branch |"$'\n'
        failed=1
        continue
    fi

    ours="$(printf '%s' "$conf" | sed -n 's/^VERSION=//p' | head -n1)"
    upstream_url="$(printf '%s' "$conf" | sed -n 's/^UPSTREAM=//p' | head -n1)"
    slug="${upstream_url#https://github.com/}"
    slug="${slug%.git}"

    if [ -z "$ours" ] || [ -z "$slug" ]; then
        rows="$rows| \`${repo##*/}\` | ${ours:-?} | ? | package.conf is missing UPSTREAM or VERSION |"$'\n'
        failed=1
        continue
    fi

    if ! newest="$(latest_tag "$slug")"; then
        rows="$rows| \`${repo##*/}\` | \`$ours\` | ? | no release or tag found for \`$slug\` |"$'\n'
        failed=1
        continue
    fi

    if [ "$ours" != "$newest" ]; then
        rows="$rows| \`${repo##*/}\` | \`$ours\` | \`$newest\` | [$slug](https://github.com/$slug/releases) |"$'\n'
        drift=$((drift + 1))
    fi
done < "$REPOS_FILE"

if [ -n "$rows" ]; then
    printf '| package | packaged | upstream | |\n|---|---|---|---|\n%s' "$rows"
    printf '\n%s of %s enrolled packages need attention.\n' \
        "$(printf '%s' "$rows" | grep -c '^|')" "$checked"
else
    printf 'All %s enrolled packages match their newest upstream release.\n' "$checked"
fi

[ "$failed" -eq 1 ] && exit 2
[ "$drift" -gt 0 ] && exit 1
exit 0
