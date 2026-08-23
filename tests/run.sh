#!/usr/bin/env bash
#
# The ingest's two decisions that are dangerous to get wrong and invisible
# when they are: which pool URLs a publish invalidates, and what an
# unreadable archive means. Neither needs a network or a real aptly.
#
#   tests/run.sh

# Two habits of this file that shellcheck reads as mistakes, both deliberate.
# Each group runs in a subshell so its environment and its overrides cannot
# leak into the next, hence the subshell-local assignment warnings. And the
# fixtures are reached only through function overrides that replace a library
# function after it is sourced, which static analysis cannot follow, hence the
# unreachable and never-invoked ones.
# shellcheck disable=SC2030,SC2031,SC2317,SC2329

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pass=0
fail=0

ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL %s\n    %s\n' "$1" "$2"; fail=$((fail + 1)); }

eq() { # label expected actual
    if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "got [$3] want [$2]"; fi
}

# A two-package, two-suite index, in the plain form index_text yields.
fake_index() {
    local suite="$1"
    local qual=""
    case "$suite" in
        trixie) qual='~haus13+1' ;;
        testing) qual='~testing1' ;;
    esac
    cat <<EOF
Package: croc
Version: 11.2.4-1$qual
Filename: pool/main/c/croc/croc_11.2.4-1${qual}_amd64.deb

Package: zola
Version: 0.23.4-1$qual
Filename: pool/main/z/zola/zola_0.23.4-1${qual}_amd64.deb
EOF
}

echo "purge scope"
(
    export BUILD_DIR ARCHIVE_DIR SUITES="trixie testing" ARCHES="amd64"
    BUILD_DIR="$(mktemp -d)"
    ARCHIVE_DIR="$(mktemp -d)"
    # shellcheck source=/dev/null
    . "$ROOT/scripts/purge-cache.sh"
    # Replaces the library's network read for the duration of this subshell.
    index_text() { fake_index "$1"; }

    eq "an empty build directory purges no pool URL" "" "$(pool_paths)"

    : > "$BUILD_DIR/croc_11.2.4-1~haus13+1_amd64.deb"
    eq "one built deb purges exactly its own URL" \
        "pool/main/c/croc/croc_11.2.4-1~haus13+1_amd64.deb" \
        "$(pool_paths)"

    : > "$BUILD_DIR/croc_11.2.4-1~testing1_amd64.deb"
    eq "a second suite's build adds only that suite's URL" \
        "pool/main/c/croc/croc_11.2.4-1~haus13+1_amd64.deb pool/main/c/croc/croc_11.2.4-1~testing1_amd64.deb" \
        "$(pool_paths | tr '\n' ' ' | sed 's/ $//')"

    eq "a package the run did not build is never purged" "0" \
        "$(pool_paths | grep -c zola)"
    exit $((fail > 0))
) || fail=$((fail + 1))

echo "news refuses to retire an archive it cannot read"
(
    work="$(mktemp -d)"
    export ARCHIVE_DIR="$work/public" APTLY_ROOT="$work/aptly" BUILD_DIR="$work/build"
    mkdir -p "$ARCHIVE_DIR/news" "$APTLY_ROOT" "$BUILD_DIR"
    printf 'croc\t11.2.4-1\nzola\t0.23.4-1\n' > "$ARCHIVE_DIR/news/known-packages.tsv"
    : > "$ARCHIVE_DIR/news/news.jsonl"

    # An aptly that answers "no such repo" for everything, which is what an
    # unfetched state branch looks like.
    mkdir -p "$work/bin"
    printf '#!/bin/sh\nexit 1\n' > "$work/bin/aptly"
    chmod +x "$work/bin/aptly"

    out="$(PATH="$work/bin:$PATH" "$ROOT/scripts/news.sh" 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        no "an empty read must not be treated as an emptied archive" "news.sh exited 0"
    elif ! grep -q 'empty archive' <<<"$out"; then
        no "the failure must name the cause" "$out"
    else
        ok "an empty read must not be treated as an emptied archive"
    fi
    eq "no retirement events were written" "0" \
        "$(grep -c retired "$ARCHIVE_DIR/news/news.jsonl")"
    exit $((fail > 0))
) || fail=$((fail + 1))

echo "render refuses to replace pool listings with nothing"
(
    work="$(mktemp -d)"
    export ARCHIVE_DIR="$work/public"
    # No credentials, and a base URL that cannot answer, so both index sources
    # come back empty -- an R2 outage or a missing token, from the renderer's side.
    export BASE_URL="http://127.0.0.1:1"
    unset R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET R2_ENDPOINT
    mkdir -p "$ARCHIVE_DIR/pool/main/z/zola" "$ARCHIVE_DIR/news"
    echo '<html>a listing</html>' > "$ARCHIVE_DIR/pool/main/z/zola/index.html"
    : > "$ARCHIVE_DIR/news/news.jsonl"

    out="$("$ROOT/scripts/render-index.sh" 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        no "an unreadable index must not empty the pool tree" "render-index.sh exited 0"
    else
        ok "an unreadable index must not empty the pool tree"
    fi
    eq "the existing listing survived" "<html>a listing</html>" \
        "$(cat "$ARCHIVE_DIR/pool/main/z/zola/index.html" 2>/dev/null)"
    eq "the failure names the cause" "1" \
        "$(grep -c 'Refusing to replace them with nothing' <<<"$out")"
    exit $((fail > 0))
) || fail=$((fail + 1))

echo "the pool mirror refuses the two ways it could lose data"
(
    work="$(mktemp -d)"
    export R2_ACCESS_KEY_ID=x R2_SECRET_ACCESS_KEY=x R2_ENDPOINT=https://example.invalid
    export R2_BUCKET=pkghaus-apt

    # Mirroring a bucket onto itself would sync the pool over the pool. The
    # sync is additive so nothing would be lost today, but the mirror would
    # then be the thing it is supposed to protect.
    export R2_BACKUP_BUCKET=pkghaus-apt
    out="$("$ROOT/scripts/backup-pool.sh" 2>&1)" && rc=0 || rc=$?
    if [ "${rc:-0}" -eq 0 ]; then
        no "mirroring the archive onto itself must fail" "exited 0"
    elif ! grep -q 'backup bucket is the archive bucket' <<<"${out:-}"; then
        no "mirroring the archive onto itself must fail" "wrong message: ${out:-}"
    else
        ok "mirroring the archive onto itself must fail"
    fi

    # A sync that silently copied nothing leaves a mirror smaller than the
    # archive. Additive means it may hold MORE (a pruned version stays);
    # fewer can only mean the copy did not finish.
    mkdir -p "$work/bin"
    cat > "$work/bin/aws" <<'FAKE'
#!/bin/sh
for a in "$@"; do
  case "$a" in
    s3://pkghaus-apt-backup/pool/) echo "2026-01-01 00:00:00 1 a.deb"; exit 0 ;;
    s3://pkghaus-apt/pool/)        echo "2026-01-01 00:00:00 1 a.deb"
                                   echo "2026-01-01 00:00:00 1 b.deb"; exit 0 ;;
  esac
done
exit 0
FAKE
    chmod +x "$work/bin/aws"
    export R2_BACKUP_BUCKET=pkghaus-apt-backup
    out="$(PATH="$work/bin:$PATH" "$ROOT/scripts/backup-pool.sh" 2>&1)" && rc2=0 || rc2=$?
    if [ "${rc2:-0}" -eq 0 ]; then
        no "a short mirror must fail" "exited 0"
    elif ! grep -q 'fewer debs' <<<"${out:-}"; then
        no "a short mirror must fail" "wrong message: ${out:-}"
    else
        ok "a short mirror must fail"
    fi
    exit $((fail > 0))
) || fail=$((fail + 1))

echo
if [ "$fail" -eq 0 ]; then
    echo "all tests passed"
else
    echo "$fail failing test group(s)"
fi
exit $((fail > 0))
