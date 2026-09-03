#!/usr/bin/env bash
#
# End-to-end proof that the archive still serves what it claims to: signature,
# index integrity, and a real package out of the pool.
#
#   check-archive-health.sh [base-url]     default https://apt.pkg.haus
#
# Why this exists, and why the keyring check next door does not cover it. The
# Worker serves pool/ and dists/ from an R2 binding, and everything else -- the
# listing tree, /news/, the keyring -- from the asset layer. When the R2 path
# throws, worker.js catches it and falls through to assets, which is the right
# answer for a path the bucket never had. The consequence is that a broken R2
# binding leaves the keyring answering 200 while every package and index 404s.
# worker.js says so itself: "a silent fallthrough and a healthy archive look
# identical from outside". check-key-expiry.sh reads the keyring, so it is
# exactly the probe that cannot see this. This one only touches R2-backed paths.
#
# What is asserted, per suite:
#
#   1. InRelease verifies against the PUBLISHED keyring -- the copy users get,
#      not a secret -- and was signed by the expected subkey. Signed by some
#      other key is a worse failure than unsigned, so the key id is pinned.
#   2. Every Packages index named in Release matches the SHA256 Release gives
#      for it. A mismatch is the shape a partial publish takes.
#   3. The index is not empty. An archive that serves a valid, signed, empty
#      index is broken in a way every other check here would pass.
#   4. The smallest .deb in the index downloads from the pool and matches the
#      index's own SHA256 and Size. Deliberately the smallest package, so the
#      check stays cheap enough to run every few hours.
#   5. A ranged request for one architecture-specific .deb per architecture
#      reaches R2 and agrees with the index about the object's total size.
#
# Why 4 does not subsume 5, which is what this file claimed until 2026-09-03.
# Two separate reasons, and each alone is enough:
#
#   - The smallest .deb in every index is pkghaus-archive-keyring, which is
#     Architecture: all. It is the SAME OBJECT in all six indices, so no
#     architecture-specific pool object was ever fetched.
#   - Pool objects are immutable and the Worker caches them itself
#     (worker.js: `cacheable = immutable && GET && !range`). After the first
#     run, assertion 4 is answered from the edge without R2 being read at all,
#     so a pool-side R2 failure would pass. A query string cannot bust it
#     either: the Worker keys its cache on the path alone.
#
# A range is the probe that cannot be cached, by that same predicate, and it is
# also uncounted -- fetch() only builds a counter row for range-less GETs -- so
# running it every few hours does not pollute the download figures.
#
# Deliberately NOT asserted: freshness of Date. The ingest is event driven, so
# a quiet fleet legitimately leaves Date weeks old, and failing on that would
# train the reader to ignore this check.

set -euo pipefail
# Without this, set -e stops at the edge of a command substitution: a function
# called as x="$(f)" keeps running after a failure instead of aborting.
shopt -s inherit_errexit

BASE="${1:-https://apt.pkg.haus}"
SUITES="${SUITES:-trixie testing unstable}"
ARCHES="${ARCHES:-amd64 arm64}"
SIGNING_KEY_ID="${SIGNING_KEY_ID:-62B67F3EA1FA6DEC}"

fail() { echo "FATAL: $*" >&2; exit 1; }
note() { echo "  $*"; }

fetch() { # url dest
    curl --fail-with-body -sS --max-time 60 -o "$2" "$1" \
        || fail "cannot fetch $1"
}

# The size and sha256 Release records for one index path. Anchored on the
# SHA256 section and stopped by the next field name, because aptly writes
# MD5Sum, SHA1, SHA256 and SHA512 and a path appears in all four.
release_record() { # release-file index-path -> "sha size"
    awk -v p="$2" '
        /^SHA256:/ { insec = 1; next }
        /^[A-Z]/   { insec = 0 }
        insec && $3 == p { print $1, $2; exit }
    ' "$1"
}

# The smallest package in an index, as "size sha path". Smallest so the pool
# assertion below stays cheap enough to run every few hours.
smallest_package() { # packages-file -> "size sha path"
    awk '
        /^Size: /     { size = $2 }
        /^SHA256: /   { sha  = $2 }
        /^Filename: / { path = $2 }
        /^$/ { if (size != "" && path != "") print size, sha, path; size = ""; sha = ""; path = "" }
        END  { if (size != "" && path != "") print size, sha, path }
    ' "$1" | sort -n | head -1
}

# The smallest package in an index that is BUILT for this architecture, i.e.
# not Architecture: all. smallest_package above can only ever return the
# keyring, so on its own it never touches an arch-specific pool object.
smallest_arch_package() { # packages-file arch -> "size sha path"
    awk -v suffix="_$2.deb" '
        /^Size: /     { size = $2 }
        /^SHA256: /   { sha  = $2 }
        /^Filename: / { path = $2 }
        function flush() {
            if (size != "" && path != "" && path ~ (suffix "$")) print size, sha, path
            size = ""; sha = ""; path = ""
        }
        /^$/ { flush() }
        END  { flush() }
    ' "$1" | sort -n | head -1
}

# The object's total size out of a Content-Range header, i.e. the number after
# the slash in "bytes 0-1023/6307948". Parsed rather than trusted as a whole
# string because that total is the assertion: it is R2's view of the object,
# and it has to agree with the index's Size.
content_range_total() { # header-block -> size
    tr -d "\r" | awk 'tolower($1) == "content-range:" { n = split($3, p, "/"); print p[n]; exit }'
}

# Sourced by tests/run.sh to reach the parsers above without a network. The
# return is what stops the checks below from running under the test harness.
# shellcheck disable=SC2317
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    return 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fetch "$BASE/pkghaus-archive-keyring.gpg" "$WORK/keyring.gpg"
[ -s "$WORK/keyring.gpg" ] || fail "the published keyring is empty"

for suite in $SUITES; do
    echo "$suite:"
    fetch "$BASE/dists/$suite/InRelease" "$WORK/InRelease"

    # gpgv rather than gpg: it verifies against a keyring file without needing
    # or creating a GNUPGHOME, which is what apt itself does.
    if ! verify="$(gpgv --keyring "$WORK/keyring.gpg" "$WORK/InRelease" 2>&1)"; then
        printf '%s\n' "$verify" >&2
        fail "$suite: InRelease does not verify against the published keyring"
    fi
    case "$verify" in
        *"$SIGNING_KEY_ID"*) ;;
        *) printf '%s\n' "$verify" >&2
           fail "$suite: InRelease was not signed by $SIGNING_KEY_ID" ;;
    esac
    note "InRelease verifies, signed by $SIGNING_KEY_ID"

    # The signed body, so every hash below is read from verified bytes rather
    # than from the file as fetched.
    gpgv --keyring "$WORK/keyring.gpg" --output "$WORK/Release" "$WORK/InRelease" 2>/dev/null \
        || fail "$suite: cannot extract the signed Release body"

    for arch in $ARCHES; do
        rel_path="main/binary-$arch/Packages"
        # The SHA256 section lists every index; take the plain Packages line.
        read -r want_sha want_size <<<"$(release_record "$WORK/Release" "$rel_path")" || true
        [ -n "${want_sha:-}" ] || fail "$suite/$arch: Release names no $rel_path"

        # Per arch, not one shared file. Reusing a single $WORK/Packages left
        # the pool assertions below reading whichever index the loop happened
        # to fetch last, which was always arm64.
        fetch "$BASE/dists/$suite/$rel_path" "$WORK/Packages.$arch"
        got_sha="$(sha256sum "$WORK/Packages.$arch" | cut -d' ' -f1)"
        got_size="$(stat -c%s "$WORK/Packages.$arch")"
        [ "$got_sha" = "$want_sha" ] \
            || fail "$suite/$arch: $rel_path sha256 $got_sha, Release says $want_sha"
        [ "$got_size" = "$want_size" ] \
            || fail "$suite/$arch: $rel_path is $got_size bytes, Release says $want_size"

        count="$(grep -c '^Package: ' "$WORK/Packages.$arch" || true)"
        [ "${count:-0}" -gt 0 ] \
            || fail "$suite/$arch: index verifies but lists no packages"
        note "$arch index matches Release, $count packages"
    done

    # Integrity: one whole object out of the pool, hashed against the index.
    # Smallest in the index, so this stays cheap. This may legitimately be
    # served from the edge rather than from R2, which is why it is not the only
    # pool assertion.
    first_arch="${ARCHES%% *}"
    read -r pkg_size pkg_sha pkg_path <<<"$(smallest_package "$WORK/Packages.$first_arch")"
    [ -n "${pkg_path:-}" ] || fail "$suite: no package with a Filename in the index"

    fetch "$BASE/$pkg_path" "$WORK/pkg.deb"
    got="$(sha256sum "$WORK/pkg.deb" | cut -d' ' -f1)"
    [ "$got" = "$pkg_sha" ] \
        || fail "$suite: $pkg_path sha256 $got, index says $pkg_sha"
    [ "$(stat -c%s "$WORK/pkg.deb")" = "$pkg_size" ] \
        || fail "$suite: $pkg_path size does not match the index"
    note "pool object $(basename "$pkg_path") ($pkg_size bytes) matches the index"

    # Liveness: a range per architecture, on a package actually built for it.
    # Uncacheable by the Worker's own predicate, so this is the assertion that
    # reaches the bucket every run.
    for arch in $ARCHES; do
        read -r probe_size _ probe_path \
            <<<"$(smallest_arch_package "$WORK/Packages.$arch" "$arch")"
        if [ -z "${probe_path:-}" ]; then
            note "$arch: no architecture-specific package to range-probe"
            continue
        fi

        probe_total="$(curl --fail-with-body -sS --max-time 60 -D - -o /dev/null \
            -H 'Range: bytes=0-1023' "$BASE/$probe_path" 2>/dev/null \
            | content_range_total)" \
            || fail "$suite/$arch: cannot range-fetch $probe_path"

        [ -n "$probe_total" ] \
            || fail "$suite/$arch: $probe_path served no Content-Range; the pool read did not happen"
        [ "$probe_total" = "$probe_size" ] \
            || fail "$suite/$arch: $probe_path is $probe_total bytes in the pool, index says $probe_size"
        note "$arch pool read live: $(basename "$probe_path") is $probe_total bytes in R2"
    done
done

echo "archive healthy: signature, indices and pool verified for: $SUITES"
