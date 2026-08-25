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

echo "the signed-commit payload describes every change, deletions included"
(
    work="$(mktemp -d)"
    export GITHUB_TOKEN=fake GITHUB_REPOSITORY=pkghaus/apt

    # A branch with three files, committed, then one of each kind of change.
    repo="$work/repo"; mkdir -p "$repo"; cd "$repo"
    git init -q -b archive .
    printf 'one\n' > keep.txt; printf 'two\n' > change.txt; printf 'three\n' > gone.txt
    git add -A
    git -c user.name=t -c user.email=t@example.invalid commit -qm base
    printf 'changed\n' > change.txt
    rm gone.txt
    printf 'new\n' > added.txt

    # A curl that captures the payload instead of sending it, and answers with
    # what a successful mutation looks like.
    mkdir -p "$work/bin"
    cat > "$work/bin/curl" <<FAKE
#!/bin/sh
for a in "\$@"; do case "\$a" in --data@*) ;; esac; done
prev=""
for a in "\$@"; do
  case "\$prev" in --data) cp "\${a#@}" "$work/payload.json" ;; esac
  prev="\$a"
done
echo '{"data":{"createCommitOnBranch":{"commit":{"oid":"deadbeefdeadbeef","signature":{"isValid":true,"state":"VALID"}}}}}'
FAKE
    chmod +x "$work/bin/curl"

    PATH="$work/bin:$PATH" "$ROOT/scripts/commit-branch.sh" "$repo" archive "test" >/dev/null 2>&1 || true

    if [ ! -f "$work/payload.json" ]; then
        no "the payload is built" "no payload captured"
    else
        adds=$(python3 -c "import json;d=json.load(open('$work/payload.json'));print(' '.join(sorted(a['path'] for a in d['variables']['input']['fileChanges']['additions'])))")
        dels=$(python3 -c "import json;d=json.load(open('$work/payload.json'));print(' '.join(sorted(x['path'] for x in d['variables']['input']['fileChanges']['deletions'])))")
        eq "additions are the new and changed files only" "added.txt change.txt" "$adds"
        eq "the deleted file is listed as a deletion"     "gone.txt"            "$dels"
        body=$(python3 -c "
import json,base64
d=json.load(open('$work/payload.json'))
a={x['path']: base64.b64decode(x['contents']).decode() for x in d['variables']['input']['fileChanges']['additions']}
print(a['change.txt'].strip())")
        eq "the addition carries the NEW contents" "changed" "$body"
    fi
    exit $((fail > 0))
) || fail=$((fail + 1))

echo "a pathspec keeps everything outside it out of the commit"
(
    work="$(mktemp -d)"; export GITHUB_TOKEN=fake GITHUB_REPOSITORY=pkghaus/brand
    repo="$work/repo"; mkdir -p "$repo/png" "$repo/src"; cd "$repo"
    git init -q -b master .
    printf 'svg\n' > src/mark.svg; printf 'old\n' > png/mark-16.png
    git add -A; git -c user.name=t -c user.email=t@example.invalid commit -qm base
    # A build touches png/, and something strays outside it.
    printf 'new\n' > png/mark-16.png
    printf 'regenerated\n' > png/mark-32.png
    printf 'STRAY\n' > oops.txt
    printf 'edited\n' > src/mark.svg

    mkdir -p "$work/bin"
    cat > "$work/bin/curl" <<FAKE
#!/bin/sh
prev=""
for a in "\$@"; do
  case "\$prev" in --data) cp "\${a#@}" "$work/payload.json" ;; esac
  prev="\$a"
done
echo '{"data":{"createCommitOnBranch":{"commit":{"oid":"cafebabecafebabe","signature":{"isValid":true,"state":"VALID"}}}}}'
FAKE
    chmod +x "$work/bin/curl"
    PATH="$work/bin:$PATH" "$ROOT/scripts/commit-branch.sh" "$repo" master "cuts" png/ >/dev/null 2>&1 || true

    if [ ! -f "$work/payload.json" ]; then
        no "a pathspec-scoped commit is built" "no payload captured"
    else
        paths=$(python3 -c "import json;d=json.load(open('$work/payload.json'));c=d['variables']['input']['fileChanges'];print(' '.join(sorted([a['path'] for a in c['additions']] + [x['path'] for x in c['deletions']])))")
        eq "only the pathspec is committed" "png/mark-16.png png/mark-32.png" "$paths"
    fi
    exit $((fail > 0))
) || fail=$((fail + 1))

echo "a tree with no changes makes no commit"
(
    work="$(mktemp -d)"; export GITHUB_TOKEN=fake GITHUB_REPOSITORY=pkghaus/apt
    repo="$work/repo"; mkdir -p "$repo"; cd "$repo"
    git init -q -b archive .
    printf 'x\n' > f.txt; git add -A
    git -c user.name=t -c user.email=t@example.invalid commit -qm base
    mkdir -p "$work/bin"
    printf '#!/bin/sh\ntouch %s/called\n' "$work" > "$work/bin/curl"; chmod +x "$work/bin/curl"
    PATH="$work/bin:$PATH" "$ROOT/scripts/commit-branch.sh" "$repo" archive "test" >/dev/null 2>&1
    if [ -f "$work/called" ]; then no "an unchanged tree must not call the API" "curl was called"
    else ok "an unchanged tree must not call the API"; fi
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
