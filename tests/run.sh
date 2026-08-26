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

echo "the plan tells an unreachable repo apart from an untagged one"
(
    work="$(mktemp -d)"
    mkdir -p "$work/bin"
    # git that cannot reach the remote: a blip, an outage, a revoked token.
    cat > "$work/bin/git" <<'FAKE'
#!/bin/sh
case "$1 $2" in "ls-remote --tags") echo "fatal: could not read from remote" >&2; exit 128 ;; esac
exec /usr/bin/git "$@"
FAKE
    chmod +x "$work/bin/git"
    printf 'pkghaus/croc-debian\n' > "$work/repos.txt"

    # ls-remote used to head a pipeline, so its failure produced no output,
    # exited 0 through tail, and was reported as "no tags": the package left the
    # plan silently under a message blaming the upstream.
    out="$(PATH="$work/bin:$PATH" REPOS_FILE="$work/repos.txt" \
        "$ROOT/scripts/ingest.sh" plan 2>&1)" && rc=0 || rc=$?
    if [ "${rc:-0}" -eq 0 ]; then
        no "an unreadable repo must not be reported as untagged" "exited 0"
    elif grep -q 'no tags' <<<"${out:-}"; then
        no "an unreadable repo must not be reported as untagged" "blamed the upstream: ${out:-}"
    elif ! grep -q 'cannot read tags' <<<"${out:-}"; then
        no "an unreadable repo must not be reported as untagged" "wrong message: ${out:-}"
    else
        ok "an unreadable repo must not be reported as untagged"
    fi

    rm -rf "$work"
    exit $((fail > 0))
) || fail=$((fail + 1))

echo "the news reader parses JSON and keeps its fields aligned"
(
    work="$(mktemp -d)"
    export ARCHIVE_DIR="$work/public" SUITES="trixie" ARCHES="amd64"
    export BASE_URL="http://127.0.0.1:1"
    unset R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET R2_ENDPOINT
    mkdir -p "$ARCHIVE_DIR/news"

    # Three things this file has got wrong. An escaped quote is ordinary JSON
    # and the old regex reader stopped at it, truncating the sentence. An empty
    # field is ordinary too, and reading the parsed record back over a tab
    # delimiter folded it away, shifting the package list into the detail column
    # and dropping the package links. And a notice writes markup on purpose --
    # the feed strips tags precisely because the page renders them -- so
    # escaping the detail broke a link that had been live for weeks.
    cat > "$ARCHIVE_DIR/news/news.jsonl" <<'NEWS'
{"ts":"2026-08-20T10:00:00Z","type":"notice","title":"T","detail":"He said \"run it\" and <a href='/stats'>linked</a>","pkgs":""}
{"ts":"2026-08-19T10:00:00Z","type":"added","title":"added: vale","detail":"","pkgs":"vale=3.17.1-1"}
NEWS

    "$ROOT/scripts/render-index.sh" >/dev/null 2>&1
    page="$ARCHIVE_DIR/news/index.html"

    eq "an escaped quote does not truncate the sentence" "1" \
        "$(grep -c 'He said "run it" and' "$page")"
    eq "markup in a notice renders as markup" "1" \
        "$(grep -c "<a href='/stats'>linked</a>" "$page")"
    # The row with an empty detail: its packages must still be linked tokens and
    # must still populate the filter attribute.
    eq "an empty field does not shift the ones after it" "1" \
        "$(grep -c 'data-pkg="vale"' "$page")"
    eq "the shifted row still links its package" "1" \
        "$(grep -c '<a href="/pool/main/v/vale/"><code>vale</code></a>' "$page")"
    eq "the raw pkgs string never reaches the detail column" "0" \
        "$(grep -c '<td>vale=3.17.1-1' "$page")"
    # The feed is plain text: tags stripped, then escaped.
    eq "the feed strips the tag rather than rendering it" "1" \
        "$(grep -c '<description>He said "run it" and linked</description>' "$ARCHIVE_DIR/news/feed.xml")"

    # A line that is not JSON is a broken row today and a wrong page tomorrow.
    printf 'not json at all\n' >> "$ARCHIVE_DIR/news/news.jsonl"
    out="$("$ROOT/scripts/render-index.sh" 2>&1)" && rc=0 || rc=$?
    if [ "${rc:-0}" -eq 0 ]; then
        no "a line that is not JSON must fail the render" "exited 0"
    elif ! grep -q 'is not JSON' <<<"${out:-}"; then
        no "a line that is not JSON must fail the render" "wrong message: ${out:-}"
    else
        ok "a line that is not JSON must fail the render"
    fi

    rm -rf "$work"
    exit $((fail > 0))
) || fail=$((fail + 1))

echo "the pool mirror will not read a failed listing as an empty bucket"
(
    work="$(mktemp -d)"
    export R2_ACCESS_KEY_ID=x R2_SECRET_ACCESS_KEY=x R2_ENDPOINT=https://example.invalid
    export R2_BUCKET=pkghaus-apt R2_BACKUP_BUCKET=pkghaus-apt-backup

    # An aws that fails every listing: expired credentials, a bad endpoint, R2
    # down. The counts used to come back 0 because the pipeline swallowed it,
    # and 0 is also what a genuinely empty bucket returns, so the safety check
    # compared two meaningless numbers and passed.
    mkdir -p "$work/bin"
    cat > "$work/bin/aws" <<'FAKE'
#!/bin/sh
for a in "$@"; do
  case "$a" in
    ls) echo "fatal error: Unable to locate credentials" >&2; exit 255 ;;
  esac
done
exit 0
FAKE
    chmod +x "$work/bin/aws"
    PATH="$work/bin:$PATH"

    out="$("$ROOT/scripts/backup-pool.sh" 2>&1)" && rc=0 || rc=$?
    if [ "${rc:-0}" -eq 0 ]; then
        no "a failed listing must not be counted as zero" "exited 0: ${out:-}"
    else
        ok "a failed listing must not be counted as zero"
    fi
    eq "no bogus count is reported" "0" \
        "$(grep -c 'debs live' <<<"${out:-}")"

    rm -rf "$work"
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

# check-key-expiry: the daily watcher reads the PUBLISHED keyring, which is
# binary, and fails rather than warns. Both differ from the ingest's path and
# both are silent when wrong -- a binary key read into a shell variable loses
# its null bytes and gpg reports no keys, which looks exactly like "this key
# never expires".
echo "== check-key-expiry =="
(
    fail=0
    work="$(mktemp -d)"
    export GNUPGHOME="$work/gnupg"; mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"

    gpg --batch --quiet --passphrase '' --quick-generate-key \
        'expiry test <t@example.invalid>' ed25519 sign 2d >/dev/null 2>&1
    gpg --export > "$work/key.gpg"                 # binary, as published
    gpg --armor --export > "$work/key.asc"         # armored, as the secret is

    out="$(FAIL_ON_WARN=0 "$ROOT/scripts/check-key-expiry.sh" "$work/key.gpg" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '::warning'; then
        ok "a binary keyring is parsed, not silently emptied by null stripping"
    else
        no "a binary keyring is parsed" "rc=$rc out=[$out]"
    fi

    out="$(FAIL_ON_WARN=1 "$ROOT/scripts/check-key-expiry.sh" "$work/key.gpg" 2>&1)"; rc=$?
    if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '::error'; then
        ok "FAIL_ON_WARN turns the watcher's warning into a failure"
    else
        no "FAIL_ON_WARN fails the run" "rc=$rc out=[$out]"
    fi

    out="$(ARCHIVE_SIGNING_KEY="$(cat "$work/key.asc")" "$ROOT/scripts/check-key-expiry.sh" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '::warning'; then
        ok "the ingest's env-var path still warns without failing"
    else
        no "the ingest's env-var path warns" "rc=$rc out=[$out]"
    fi

    out="$("$ROOT/scripts/check-key-expiry.sh" "$work/absent.gpg" 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then
        ok "a missing key file fails instead of reporting no expiry"
    else
        no "a missing key file fails" "rc=$rc out=[$out]"
    fi

    rm -rf "$work"
    exit $((fail > 0))
) || fail=$((fail + 1))

echo
if [ "$fail" -eq 0 ]; then
    echo "all tests passed"
else
    echo "$fail failing test group(s)"
fi
exit $((fail > 0))
