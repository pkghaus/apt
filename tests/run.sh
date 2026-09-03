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

echo "render helpers: the pool prefix follows Debian's lib rule"
(
    ARCHIVE_DIR="$(mktemp -d)"
    export ARCHIVE_DIR
    # shellcheck source=scripts/render-index.sh
    . "$ROOT/scripts/render-index.sh"

    # Debian puts lib* sources in a four-character directory so the thousands
    # of them fan out. Verified against Debian itself: pool/main/libg/libgcrypt20/
    # is 200, pool/main/l/libgcrypt20/ is 404. This built the prefix by hand as
    # ${name:0:1}, so a lib package's news link pointed at a path that does not
    # exist. No fleet package starts with lib, which is why it went unnoticed.
    eq "an ordinary name takes its first letter"  "c"    "$(pool_prefix croc)"
    eq "a lib name takes four characters"         "libg" "$(pool_prefix libgcrypt20)"
    eq "  and not just the l"                     "libf" "$(pool_prefix libfoo)"
    eq "a name that merely contains lib does not" "z"    "$(pool_prefix zlib-tools)"
    eq "a name of exactly lib is stable"          "lib"  "$(pool_prefix lib)"

    # The link the news page emits, end to end.
    eq "a lib package links into its real pool directory" "1" \
       "$(pkg_tokens 'libgcrypt20=1.0-1' | grep -c '/pool/main/libg/libgcrypt20/')"
    eq "  and never into the one-letter path" "0" \
       "$(pkg_tokens 'libgcrypt20=1.0-1' | grep -c '/pool/main/l/libgcrypt20/')"
    eq "an ordinary package is unaffected" "1" \
       "$(pkg_tokens 'croc=11.3.6-1' | grep -c '/pool/main/c/croc/')"
    # A retired package renders unlinked, so there is no path to get wrong.
    eq "a retired package stays unlinked" "0" \
       "$(pkg_tokens 'gone=' | grep -c 'href')"

    # esc()'s comment says it covers the date. It did not: the date was
    # interpolated raw while type and the name list went through it.
    eq "esc quotes what would break an attribute" '&quot;x&quot;' "$(esc '"x"')"
    eq "esc escapes markup" '&lt;b&gt;' "$(esc '<b>')"

    rm -rf "$ARCHIVE_DIR"
    exit $((fail > 0))
) || fail=$((fail + 1))

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

    # One URL per pool path, in the literal spelling.
    #
    # This emitted three spellings per path until 2026-09-03 -- literal,
    # %7e/%2b and %7E/%2B -- from when Pages was the origin and the CDN keyed
    # its cache on the request URL. The Worker keys on the DECODED path, so all
    # three collapse to one entry and the encoded two addressed keys that
    # cannot exist. Asserted here because the count is now load-bearing: adding
    # a spelling back is waste, and dropping the literal one purges nothing.
    eq "each pool path yields exactly one purge URL" "2" \
        "$(purge_urls | wc -l)"
    eq "the URL is the literal spelling, not percent-encoded" \
        "https://apt.pkg.haus/pool/main/c/croc/croc_11.2.4-1~haus13+1_amd64.deb" \
        "$(purge_urls | grep haus13 | head -1)"
    eq "no encoded spelling is emitted" "0" \
        "$(purge_urls | grep -ciE '%7e|%2b')"
    # Emptied first: the assertions above left two debs in it. A run that
    # built nothing must purge nothing, or an empty plan would evict the pool.
    rm -f "$BUILD_DIR"/*.deb
    eq "a run that built nothing purges nothing at all" "" "$(purge_urls)"

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

echo "the plan tells an unreachable source apart from an untagged package"
(
    work="$(mktemp -d)"
    mkdir -p "$work/bin"
    # git that cannot reach the remote: a blip, an outage, a revoked token.
    # Injected at `clone`, which is where the plan reads the fleet since it
    # stopped running one ls-remote and one clone per enrolled package. The
    # stub also keeps this test offline: without it the clone would succeed
    # against the real repository.
    cat > "$work/bin/git" <<'FAKE'
#!/bin/sh
case "$1" in clone) echo "fatal: could not read from remote" >&2; exit 128 ;; esac
exec /usr/bin/git "$@"
FAKE
    chmod +x "$work/bin/git"
    printf 'croc\n' > "$work/packages.txt"

    # The listing used to head a pipeline, so its failure produced no output,
    # exited 0 through tail, and was reported as "no tags": the package left the
    # plan silently under a message blaming the upstream. The shape of that bug
    # is what this asserts against, whatever the read is implemented as.
    out="$(PATH="$work/bin:$PATH" PACKAGES_FILE="$work/packages.txt" \
        "$ROOT/scripts/ingest.sh" plan 2>&1)" && rc=0 || rc=$?
    if [ "${rc:-0}" -eq 0 ]; then
        no "an unreadable source must not be reported as untagged" "exited 0"
    elif grep -q 'no tags' <<<"${out:-}"; then
        no "an unreadable source must not be reported as untagged" "blamed the upstream: ${out:-}"
    elif ! grep -q 'cannot clone' <<<"${out:-}"; then
        no "an unreadable source must not be reported as untagged" "wrong message: ${out:-}"
    else
        ok "an unreadable source must not be reported as untagged"
    fi

    # And an unreadable source must not be mistaken for an empty fleet: the
    # plan has to be empty AND the run has to fail, not one of the two.
    eq "an unreadable source plans nothing at all" "0" \
       "$(printf '%s\n' "$out" | grep -cP '^croc\t')"

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

# --- check-archive-health.sh: the two parsers ---------------------------------
#
# The health check itself needs a network, so what is tested here is the text
# handling, which is where its bugs would be. A Release lists every index four
# times, once per hash algorithm, so reading the wrong section yields a
# plausible-looking hash that never matches.
(
    # shellcheck source=scripts/check-archive-health.sh
    . "$ROOT/scripts/check-archive-health.sh"

    work="$(mktemp -d)"
    cat > "$work/Release" <<'REL'
Origin: pkg.haus
Suite: trixie
MD5Sum:
 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa      100 main/binary-amd64/Packages
SHA1:
 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb      100 main/binary-amd64/Packages
SHA256:
 cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc      100 main/binary-amd64/Packages
 dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd      200 main/binary-arm64/Packages
SHA512:
 eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee      100 main/binary-amd64/Packages
Components: main
REL

    eq "release_record reads the SHA256 section, not MD5Sum above it" \
       "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc 100" \
       "$(release_record "$work/Release" main/binary-amd64/Packages)"

    eq "release_record does not bleed into SHA512 below it" \
       "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd 200" \
       "$(release_record "$work/Release" main/binary-arm64/Packages)"

    eq "release_record is empty for a path Release does not list" \
       "" "$(release_record "$work/Release" main/binary-i386/Packages)"

    cat > "$work/Packages" <<'PKG'
Package: big
Version: 1.0-1
Size: 900000
SHA256: 1111111111111111111111111111111111111111111111111111111111111111
Filename: pool/main/b/big/big_1.0-1_amd64.deb

Package: small
Version: 2.0-1
Size: 2600
SHA256: 2222222222222222222222222222222222222222222222222222222222222222
Filename: pool/main/s/small/small_2.0-1_all.deb

Package: middle
Version: 3.0-1
Size: 50000
SHA256: 3333333333333333333333333333333333333333333333333333333333333333
Filename: pool/main/m/middle/middle_3.0-1_amd64.deb
PKG

    eq "smallest_package picks the smallest by Size, not by order" \
       "2600 2222222222222222222222222222222222222222222222222222222222222222 pool/main/s/small/small_2.0-1_all.deb" \
       "$(smallest_package "$work/Packages")"

    # Numeric sort, not lexicographic: "900000" sorts before "2600" as text.
    eq "smallest_package sorts numerically" \
       "2600" "$(smallest_package "$work/Packages" | cut -d' ' -f1)"

    # A trailing stanza with no blank line after it must still be considered.
    printf 'Package: last\nVersion: 4.0-1\nSize: 10\nSHA256: 4444\nFilename: pool/main/l/last/last.deb\n' \
        >> "$work/Packages"
    eq "smallest_package sees a final stanza with no trailing blank line" \
       "pool/main/l/last/last.deb" "$(smallest_package "$work/Packages" | cut -d' ' -f3)"

    # Its own fixture, deliberately. The file above has had a stanza appended
    # with no blank line before it, which merges it into the previous one --
    # that is what the test above is asserting. Reusing it here would test the
    # arch pick against a fixture that has already lost a package.
    cat > "$work/Arch" <<'PKG'
Package: keyring
Version: 1-1
Size: 2600
SHA256: 2222222222222222222222222222222222222222222222222222222222222222
Filename: pool/main/p/pkghaus-archive-keyring/pkghaus-archive-keyring_1-1_all.deb

Package: middle
Version: 3.0-1
Size: 50000
SHA256: 3333333333333333333333333333333333333333333333333333333333333333
Filename: pool/main/m/middle/middle_3.0-1_amd64.deb

Package: big
Version: 1.0-1
Size: 900000
SHA256: 1111111111111111111111111111111111111111111111111111111111111111
Filename: pool/main/b/big/big_1.0-1_amd64.deb

Package: onlyarm
Version: 1-1
Size: 4000
SHA256: 6666666666666666666666666666666666666666666666666666666666666666
Filename: pool/main/o/onlyarm/onlyarm_1-1_arm64.deb
PKG

    # The whole point: the smallest object here is the Architecture: all
    # keyring at 2600 bytes, which is the same object in every index. The arch
    # pick has to skip it and take the 50000-byte amd64 package.
    eq "smallest_package would pick the Architecture: all keyring" \
       "pool/main/p/pkghaus-archive-keyring/pkghaus-archive-keyring_1-1_all.deb" \
       "$(smallest_package "$work/Arch" | cut -d' ' -f3)"
    eq "smallest_arch_package skips it for a real amd64 package" \
       "pool/main/m/middle/middle_3.0-1_amd64.deb" \
       "$(smallest_arch_package "$work/Arch" amd64 | cut -d' ' -f3)"
    eq "smallest_arch_package reports that package's own size" \
       "50000" "$(smallest_arch_package "$work/Arch" amd64 | cut -d' ' -f1)"
    eq "smallest_arch_package does not confuse one arch for another" \
       "pool/main/o/onlyarm/onlyarm_1-1_arm64.deb" \
       "$(smallest_arch_package "$work/Arch" arm64 | cut -d' ' -f3)"
    eq "smallest_arch_package is empty when nothing is built for the arch" \
       "" "$(smallest_arch_package "$work/Arch" i386 | cut -d' ' -f3)"

    # A final stanza with no trailing blank line: the flush-at-END path is
    # separate code from the flush-at-blank-line one.
    printf '\nPackage: tiny\nVersion: 5-1\nSize: 5\nSHA256: 5555\nFilename: pool/main/t/tiny/tiny_5-1_amd64.deb\n' \
        >> "$work/Arch"
    eq "smallest_arch_package sees a final stanza with no trailing blank line" \
       "pool/main/t/tiny/tiny_5-1_amd64.deb" \
       "$(smallest_arch_package "$work/Arch" amd64 | cut -d' ' -f3)"

    # The total after the slash is the assertion the ranged probe makes: it is
    # R2's view of the object's size, which has to agree with the index.
    eq "content_range_total reads the size after the slash" \
       "6307948" "$(printf 'HTTP/2 206\r\ncontent-range: bytes 0-1023/6307948\r\n\r\n' | content_range_total)"
    eq "content_range_total is case-insensitive about the header name" \
       "4358" "$(printf 'Content-Range: bytes 0-99/4358\r\n' | content_range_total)"
    # A 200 carries no Content-Range. Empty is what makes the probe fail loudly
    # rather than pass on a response that never proved a pool read happened.
    eq "content_range_total is empty when the response is not partial" \
       "" "$(printf 'HTTP/2 200\r\ncontent-length: 4358\r\n' | content_range_total)"

    rm -rf "$work"
    exit $((fail > 0))
) || fail=$((fail + 1))

# --- verify_dsc: the last place two build legs can be caught disagreeing -----
#
# One orig tarball serves all three suites and all six legs produce it, but
# actions/download-artifact merges them into a single file before the publish
# script runs, so a divergence leaves no trace by then. What survives is that
# each suite's .dsc records the checksum it expects, and only one tarball is
# stored -- so a mismatch is detectable here and nowhere else.
(
    work="$(mktemp -d)"
    R2_BUCKET=unused

    # Sourcing the publisher would run it, so lift just the function out. The
    # sed range is the function body, terminated by its closing brace in column
    # one, which is how every function in that file is written.
    sed -n '/^verify_dsc() {$/,/^}$/p' "$ROOT/scripts/publish-buildinfo.sh" > "$work/fn.sh"
    # shellcheck source=/dev/null
    . "$work/fn.sh"

    printf 'upstream source\n' > "$work/demo_1.0.orig.tar.gz"
    good="$(sha256sum "$work/demo_1.0.orig.tar.gz" | cut -d' ' -f1)"
    size="$(stat -c %s "$work/demo_1.0.orig.tar.gz")"

    write_dsc() { # <hash> <size>
        cat > "$work/demo_1.0-1.dsc" <<DSC
Format: 3.0 (quilt)
Source: demo
Version: 1.0-1
Checksums-Sha256:
 $1 $2 demo_1.0.orig.tar.gz
Files:
 00000000000000000000000000000000 $2 demo_1.0.orig.tar.gz
DSC
    }

    write_dsc "$good" "$size"
    if verify_dsc "$work/demo_1.0-1.dsc" 2>/dev/null; then
        ok "verify_dsc accepts a .dsc whose checksums match"
    else
        no "verify_dsc accepts a .dsc whose checksums match" "returned non-zero"
    fi

    # The divergence case: the stored tarball is not the one this .dsc expects.
    write_dsc "$(printf %064d 0)" "$size"
    if verify_dsc "$work/demo_1.0-1.dsc" 2>/dev/null; then
        no "verify_dsc rejects a checksum mismatch" "returned zero"
    else
        ok "verify_dsc rejects a checksum mismatch"
    fi

    # A record with no source beside it. debrebuild reads the .dsc from the
    # record's own directory and falls back to debsnap, which has never heard of
    # this archive -- so such a record cannot be used for anything, and 36 of
    # them were served for a day before being deleted. The guard runs after
    # require_r2 and before the first upload, so fake credentials reach it.
    recs="$(mktemp -d)"
    : > "$recs/demo_1.0-1_amd64.buildinfo"
    out="$(R2_ACCESS_KEY_ID=x R2_SECRET_ACCESS_KEY=x R2_BUCKET=x R2_ENDPOINT=x \
        "$ROOT/scripts/publish-buildinfo.sh" "$recs" 2>&1)" && rc=0 || rc=$?
    if [ "${rc:-0}" -ne 0 ] && printf '%s' "$out" | grep -q 'and no .dsc'; then
        ok "a build record is refused when its source package is absent"
    else
        no "a build record is refused when its source package is absent" \
            "rc=${rc:-0} out=$out"
    fi

    # And accepted with one, so the guard is not simply refusing everything.
    cp "$work/demo_1.0.orig.tar.gz" "$recs/"
    write_dsc "$good" "$size"
    cp "$work/demo_1.0-1.dsc" "$recs/"
    out="$(R2_ACCESS_KEY_ID=x R2_SECRET_ACCESS_KEY=x R2_BUCKET=x R2_ENDPOINT=x \
        "$ROOT/scripts/publish-buildinfo.sh" "$recs" 2>&1)" && rc=0 || rc=$?
    if printf '%s' "$out" | grep -q 'and no .dsc'; then
        no "the guard passes once the source package is beside the record" \
            "still refused: $out"
    else
        ok "the guard passes once the source package is beside the record"
    fi
    rm -rf "$recs"

    # Same bytes, wrong size: catches a .dsc paired with the wrong tarball when
    # a hash collision is not the failure mode -- a truncated upload is.
    write_dsc "$good" 999999
    if verify_dsc "$work/demo_1.0-1.dsc" 2>/dev/null; then
        no "verify_dsc rejects a size mismatch" "returned zero"
    else
        ok "verify_dsc rejects a size mismatch"
    fi

    # A .dsc naming a file the build never produced would publish a source
    # package that cannot be unpacked. Asserted on the message, not just the
    # exit status: an absent file also fails the checksum compare below, so a
    # status-only test passes even with this branch removed entirely, and said
    # nothing about the diagnostic a reader actually gets.
    write_dsc "$good" "$size"
    rm "$work/demo_1.0.orig.tar.gz"
    err="$(verify_dsc "$work/demo_1.0-1.dsc" 2>&1 || true)"
    case "$err" in
        *"which the build did not produce"*)
            ok "verify_dsc names a missing file as missing" ;;
        *)
            no "verify_dsc names a missing file as missing" "got: $err" ;;
    esac

    # The block ends at the next line starting in column one. Without that, the
    # Files: stanza below it would be read as more sha256 entries and its md5
    # hashes compared as though they were sha256 -- failing every valid .dsc.
    printf 'upstream source\n' > "$work/demo_1.0.orig.tar.gz"
    write_dsc "$good" "$size"
    if verify_dsc "$work/demo_1.0-1.dsc" 2>/dev/null; then
        ok "verify_dsc stops at the end of the Checksums-Sha256 block"
    else
        no "verify_dsc stops at the end of the Checksums-Sha256 block" \
           "the Files: stanza leaked into the comparison"
    fi

    rm -rf "$work"
    exit $((fail > 0))
) || fail=$((fail + 1))

# --- prune-source-tarballs: budget, order, and what must never go ------------
#
# Tarballs are kept for as long as the bucket can afford them, so the normal
# case deletes nothing at all. When it does delete, it goes oldest first and
# must not touch anything a published version needs -- deleting one of those
# breaks verification for a package people can still download.
(
    work="$(mktemp -d)"
    mkdir -p "$work/scripts" "$work/objects"
    cp "$ROOT/scripts/prune-source-tarballs.sh" "$work/scripts/"

    # Stands in for aptly and R2. Objects are files under objects/, keyed by
    # their name with slashes replaced -- '%' because a Debian filename can
    # contain '_' but never that.
    cat > "$work/scripts/aptly-lib.sh" <<'LIB'
require_r2() { :; }
R2_BUCKET=testbucket
flat() { printf '%s' "$1" | tr / '%'; }
suite_contents() { cat "$STUB_DIR/contents.$1" 2>/dev/null || true; }
aws_() {
    case "$2" in
        cp) key="${3#s3://testbucket/}"
            # Modelled explicitly rather than with chmod: the suite runs as root
            # in CI, and root reads a 0000 file quite happily.
            grep -qxF "$key" "$STUB_DIR/unreadable" 2>/dev/null && return 1
            cat "$STUB_DIR/objects/$(flat "$key")" 2>/dev/null || return 1 ;;
        ls) for f in "$STUB_DIR"/objects/*; do
                [ -e "$f" ] || continue
                k="$(basename "$f" | tr '%' /)"
                d="$(sed -n "s|^$k \(.*\)|\1|p" "$STUB_DIR/dates" 2>/dev/null)"
                printf '%s %s %s\n' "${d:-2026-09-01 00:00:00}" "$(stat -c%s "$f")" "$k"
            done ;;
        rm) key="${3#s3://testbucket/}"
            printf '%s\n' "$key" >> "$STUB_DIR/deleted"
            rm -f "$STUB_DIR/objects/$(flat "$key")" ;;
    esac
}
LIB

    export STUB_DIR="$work"
    put() { printf '%s' "$2" > "$work/objects/$(printf '%s' "$1" | tr / '%')"; }
    dated() { printf '%s %s\n' "$1" "$2" >> "$work/dates"; }

    # croc 1.0-1 in unstable and 1.0-1~haus13+1 in trixie share one orig
    # tarball, which is the case a per-suite rule would get wrong.
    dsc_body() { printf 'Format: 3.0 (quilt)\nChecksums-Sha256:\n aaa 10 croc_1.0.orig.tar.gz\n bbb 20 croc_%s.debian.tar.xz\nFiles:\n ccc 10 croc_1.0.orig.tar.gz\n' "$1"; }
    put buildinfos/buildinfo-pool/c/croc/croc_1.0-1.dsc                     "$(dsc_body 1.0-1)"
    put buildinfos/buildinfo-pool/c/croc/croc_1.0-1~haus13+1.dsc            "$(dsc_body '1.0-1~haus13+1')"
    put buildinfos/buildinfo-pool/c/croc/croc_1.0.orig.tar.gz               "$(head -c 400 /dev/zero | tr '\0' o)"
    put buildinfos/buildinfo-pool/c/croc/croc_1.0-1.debian.tar.xz           deb-unstable
    put buildinfos/buildinfo-pool/c/croc/croc_1.0-1~haus13+1.debian.tar.xz  deb-trixie
    # Two superseded versions, one clearly older than the other.
    put buildinfos/buildinfo-pool/c/croc/croc_0.9-1.dsc  "$(printf 'Checksums-Sha256:\n ddd 10 croc_0.9.orig.tar.gz\n')"
    put buildinfos/buildinfo-pool/c/croc/croc_0.9.orig.tar.gz "$(head -c 400 /dev/zero | tr '\0' n)"
    put buildinfos/buildinfo-pool/c/croc/croc_0.8-1.dsc  "$(printf 'Checksums-Sha256:\n eee 10 croc_0.8.orig.tar.gz\n')"
    put buildinfos/buildinfo-pool/c/croc/croc_0.8.orig.tar.gz "$(head -c 400 /dev/zero | tr '\0' m)"
    dated buildinfos/buildinfo-pool/c/croc/croc_0.8.orig.tar.gz "2024-01-01 00:00:00"
    dated buildinfos/buildinfo-pool/c/croc/croc_0.9.orig.tar.gz "2025-01-01 00:00:00"

    printf 'croc\t1.0-1\tamd64\n' > "$work/contents.unstable"
    printf 'croc\t1.0-1~haus13+1\tamd64\n' > "$work/contents.trixie"
    : > "$work/contents.testing"

    # --- the normal case: room to spare, so nothing goes ---------------------
    # Asserted on the message as well as the absence of deletions. Without the
    # early exit the overage is negative and the delete loop breaks on its first
    # test anyway, so "nothing was deleted" holds even with the budget check
    # removed entirely, and says nothing about whether it ran.
    out="$(BUCKET_BUDGET_BYTES=100000000 "$work/scripts/prune-source-tarballs.sh" 2>&1)"
    if [ ! -e "$work/deleted" ] && printf '%s' "$out" | grep -q 'under budget, keeping every source tarball'; then
        ok "under budget, nothing is considered for deletion"
    else
        no "under budget, nothing is considered for deletion" \
           "deleted [$(tr '\n' ' ' < "$work/deleted" 2>/dev/null)] out [$out]"
    fi

    # --- over budget: oldest first, and only enough ---------------------------
    # 300 bytes over, and the tarballs are 400 each, so exactly one goes: the
    # loop stops as soon as it has freed enough, which is what keeps a budget
    # overshoot from cascading into a purge.
    rm -f "$work/deleted"
    total="$(cat "$work"/objects/* | wc -c)"
    BUCKET_BUDGET_BYTES=$((total - 300)) "$work/scripts/prune-source-tarballs.sh" >/dev/null 2>&1
    got="$(tr '\n' ' ' < "$work/deleted" 2>/dev/null)"
    eq "over budget deletes the oldest superseded tarball, and only it" \
       "buildinfos/buildinfo-pool/c/croc/croc_0.8.orig.tar.gz " "$got"

    # --- what must never go ---------------------------------------------------
    for f in croc_1.0.orig.tar.gz croc_1.0-1.debian.tar.xz croc_1.0-1~haus13+1.debian.tar.xz; do
        if [ -e "$work/objects/$(printf 'buildinfos/buildinfo-pool/c/croc/%s' "$f" | tr / '%')" ]; then
            ok "a published version's tarball survives the budget: $f"
        else
            no "a published version's tarball survives the budget: $f" "it was deleted"
        fi
    done

    if [ -e "$work/objects/$(printf 'buildinfos/buildinfo-pool/c/croc/croc_0.8-1.dsc' | tr / '%')" ]; then
        ok "the .dsc of a pruned version is kept"
    else
        no "the .dsc of a pruned version is kept" "it was deleted"
    fi

    # --- over budget with nothing safe left is a failure, not a free-for-all --
    rm -f "$work/deleted"
    if BUCKET_BUDGET_BYTES=1 "$work/scripts/prune-source-tarballs.sh" >/dev/null 2>&1; then
        no "unreachable budget fails rather than deleting live tarballs" "exited zero"
    elif ! grep -q '1\.0\.orig' "$work/deleted" 2>/dev/null; then
        ok "unreachable budget fails rather than deleting live tarballs"
    else
        no "unreachable budget fails rather than deleting live tarballs" \
           "deleted $(tr '\n' ' ' < "$work/deleted")"
    fi

    # --- stored but unreadable is not the same as absent ----------------------
    rm -f "$work/deleted"
    printf 'buildinfos/buildinfo-pool/c/croc/croc_1.0-1.dsc\n' > "$work/unreadable"
    if BUCKET_BUDGET_BYTES=1 "$work/scripts/prune-source-tarballs.sh" >/dev/null 2>&1; then
        no "an unreadable .dsc fails the run" "exited zero"
    elif [ ! -e "$work/deleted" ]; then
        ok "an unreadable .dsc fails the run and deletes nothing"
    else
        no "an unreadable .dsc fails the run and deletes nothing" \
           "deleted $(tr '\n' ' ' < "$work/deleted")"
    fi
    rm -f "$work/unreadable"

    # --- over budget with no published versions at all ------------------------
    # Reachable only when the aptly state failed to restore, where "everything
    # is orphaned" is the one reading that must not be acted on.
    rm -f "$work/deleted"
    : > "$work/contents.unstable"
    : > "$work/contents.trixie"
    if BUCKET_BUDGET_BYTES=1 "$work/scripts/prune-source-tarballs.sh" >/dev/null 2>&1; then
        no "no published versions at all fails the run" "exited zero"
    elif [ ! -e "$work/deleted" ]; then
        ok "no published versions at all fails the run and deletes nothing"
    else
        no "no published versions at all fails the run and deletes nothing" \
           "deleted $(tr '\n' ' ' < "$work/deleted")"
    fi

    rm -rf "$work"
    exit $((fail > 0))
) || fail=$((fail + 1))

# --- ingest.sh plan(): what the archive decides to build ----------------------
#
# plan() had no test at all, which is a poor match for its job: it is the
# function that decides what the archive builds and therefore what it ships.
# These drive it against a real git repository with namespaced tags, because
# the tag namespacing and the per-tag file reads are the parts that were
# rewritten to stop cloning once per package.
echo "ingest plan"
(
    work="$(mktemp -d)"
    fleet="$work/fleet"

    # A packages repository shaped like the real one: one directory per
    # package, tags namespaced by package.
    mkdir -p "$fleet"
    git -C "$fleet" init -q
    git -C "$fleet" config user.email t@example.invalid
    git -C "$fleet" config user.name t
    git -C "$fleet" config commit.gpgsign false

    mkpkg() { # name version arch
        mkdir -p "$fleet/$1/debian"
        printf '%s (%s) unstable; urgency=medium\n\n  * x\n' "$1" "$2" \
            > "$fleet/$1/debian/changelog"
        printf 'Source: %s\n\nPackage: %s\nArchitecture: %s\n' "$1" "$1" "$3" \
            > "$fleet/$1/debian/control"
    }

    mkpkg alpha 1.0-1 any
    mkpkg keyring 2026.01.01 all
    mkpkg untagged 9.9-1 any
    printf 'alpha\nkeyring\nuntagged\n' > "$work/packages.txt"
    git -C "$fleet" add -A
    git -C "$fleet" commit -q -m one
    git -C "$fleet" tag alpha/v1.0-1
    git -C "$fleet" tag keyring/v2026.01.01

    # A newer alpha, and a tag for another package that sorts above it. The
    # prefix match is what has to keep them apart.
    mkpkg alpha 1.2-1 any
    git -C "$fleet" add -A
    git -C "$fleet" commit -q -m two
    git -C "$fleet" tag alpha/v1.2-1
    git -C "$fleet" tag zzz/v99.0-1

    # Plain assignments, not a command prefix. `VAR=x . file` makes VAR a
    # temporary that is discarded when the source returns, taking the value
    # ingest.sh's own `GIT_BASE="${GIT_BASE:-...}"` assigned to it with it.
    SUITES=unstable
    PACKAGES_FILE="$work/packages.txt"
    GIT_BASE="$work/"
    PACKAGES_REPO=fleet
    export SUITES PACKAGES_FILE GIT_BASE PACKAGES_REPO
    # shellcheck source=scripts/ingest.sh
    . "$ROOT/scripts/ingest.sh"

    # In the test's own shell, exactly as plan() does it: a clone made inside
    # a command substitution does not outlive it.
    if ensure_packages_mirror; then
        ok "the fleet clones once, into this run's scratch directory"
    else
        no "the fleet clones once, into this run's scratch directory" "clone failed"
    fi
    eq "the clone survives the substitution that made it" \
       "yes" "$([ -d "$MIRROR" ] && echo yes || echo no)"

    eq "newest_tag takes the newest tag for the package" \
       "alpha/v1.2-1" "$(newest_tag alpha)"
    eq "newest_tag ignores another package's higher-sorting tag" \
       "keyring/v2026.01.01" "$(newest_tag keyring)"
    eq "newest_tag is empty for a package that has never been tagged" \
       "" "$(newest_tag untagged)"

    eq "changelog_header reads the version at that tag, not at HEAD" \
       "alpha 1.0-1" "$(changelog_header alpha/v1.0-1 alpha)"
    eq "changelog_header follows the tag forward too" \
       "alpha 1.2-1" "$(changelog_header alpha/v1.2-1 alpha)"

    if arch_all_only keyring/v2026.01.01 keyring; then
        ok "arch_all_only spots an Architecture: all package"
    else
        no "arch_all_only spots an Architecture: all package" "said no"
    fi
    if arch_all_only alpha/v1.2-1 alpha; then
        no "arch_all_only rejects Architecture: any" "said yes"
    else
        ok "arch_all_only rejects Architecture: any"
    fi

    # The whole plan, against an archive that carries nothing. One row per
    # arch for the arch-any package, one "all" row for the arch-all one, and
    # nothing at all for the untagged one.
    plan_out="$(SUITES=unstable plan "amd64 arm64" 2>/dev/null)"
    eq "an untagged package is not planned" \
       "0" "$(printf '%s\n' "$plan_out" | grep -c '^untagged')"
    eq "an arch-any package is planned once per architecture" \
       "2" "$(printf '%s\n' "$plan_out" | grep -c '^alpha')"
    eq "an arch-all package is planned once, as all" \
       "1" "$(printf '%s\n' "$plan_out" | grep -c '^keyring')"
    eq "the arch-all row says all, not an architecture" \
       "all" "$(printf '%s\n' "$plan_out" | awk -F'\t' '$1=="keyring"{print $5}')"
    eq "a planned row carries the newest tag" \
       "alpha/v1.2-1" "$(printf '%s\n' "$plan_out" | awk -F'\t' '$1=="alpha"{print $2; exit}')"
    eq "a planned row carries the version from that tag" \
       "1.2-1" "$(printf '%s\n' "$plan_out" | awk -F'\t' '$1=="alpha"{print $6; exit}')"

    # An unreadable repository is not an empty fleet. This is the direction
    # that matters: reported as "no tags", every package silently leaves the
    # plan under a message saying upstream never tagged anything.
    out="$(GIT_BASE="$work/" PACKAGES_REPO=does-not-exist \
           bash "$ROOT/scripts/ingest.sh" plan 2>&1 || true)"
    case "$out" in
        *"cannot clone"*) ok "an unreadable packages repo fails rather than planning nothing" ;;
        *) no "an unreadable packages repo fails rather than planning nothing" "got [$out]" ;;
    esac

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
