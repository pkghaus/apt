# shellcheck shell=bash
#
# Shared aptly access for the ingest scripts. Sourced, never executed.
#
# aptly's state (its leveldb and its content-addressed pool) lives in
# $APTLY_ROOT, which CI checks out from the `aptly` branch. Its config is
# written at run time so no credential is ever committed, and the S3 block is
# written only when R2 credentials are present: reading the local repos needs
# none, publishing needs all four.

APTLY_ROOT="${APTLY_ROOT:-aptly-state}"
APTLY_CONF="${APTLY_CONF:-$APTLY_ROOT/aptly.conf}"
# The empty prefix is load-bearing, not a default, and it now has two reasons
# rather than one.
#
# The original was an aptly bug: it cached published objects under a key that
# omitted the publish prefix, then looked them up under a key that included it,
# so any prefix meant the cache never hit and every package fell back to the
# local pool. FIXED UPSTREAM in aptly 1.6.3 (PR #1480, issue #1475, reported by
# someone else against 1.6.2 with the same diagnosis reached here
# independently), so it is no longer what forces this.
#
# What forces it now is the Worker. worker/src/worker.js derives the R2 object
# key straight from the request path -- `const key = path.slice(1)` -- so the
# archive has to sit at the bucket root for every pool and dists URL to map to
# an object. Publishing under a prefix would require rewriting that mapping and
# relocating every object in the bucket.
#
# The cache hitting is still what lets the pool be thrown away between runs.
PUBLISH_TARGET="${PUBLISH_TARGET:-s3:r2:}"

_aptly_conf_written=0

have_r2() {
    [ -n "${R2_ACCESS_KEY_ID:-}" ] && [ -n "${R2_SECRET_ACCESS_KEY:-}" ] &&
        [ -n "${R2_BUCKET:-}" ] && [ -n "${R2_ENDPOINT:-}" ]
}

require_r2() {
    have_r2 || {
        printf 'FATAL: R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_BUCKET and R2_ENDPOINT are required to publish\n' >&2
        exit 1
    }
}

# Rewritten on first use in every process rather than reused: rootDir is an
# absolute path, so a config carried over from another checkout points aptly at
# a directory that is not there.
write_aptly_conf() {
    [ "$_aptly_conf_written" = 1 ] && return 0
    mkdir -p "$APTLY_ROOT"
    umask 077

    if have_r2; then
        # "acl": "none" because R2 has no ACLs, and the endpoint must be a full
        # URI: aptly 1.6 uses AWS SDK v2, which rejects a bare host:port.
        cat > "$APTLY_CONF" <<CONF
{
  "rootDir": "$(cd "$APTLY_ROOT" && pwd)",
  "S3PublishEndpoints": {
    "r2": {
      "region": "auto",
      "bucket": "$R2_BUCKET",
      "endpoint": "$R2_ENDPOINT",
      "awsAccessKeyID": "$R2_ACCESS_KEY_ID",
      "awsSecretAccessKey": "$R2_SECRET_ACCESS_KEY",
      "acl": "none",
      "s3ForcePathStyle": true
    }
  }
}
CONF
    else
        cat > "$APTLY_CONF" <<CONF
{
  "rootDir": "$(cd "$APTLY_ROOT" && pwd)"
}
CONF
    fi

    _aptly_conf_written=1
}

aptly_() {
    write_aptly_conf
    aptly -config="$APTLY_CONF" "$@"
}

# One local repo per suite. reprepro kept all three in one conf/distributions
# over a shared pool; aptly has no multi-distribution local repo.
repo_of() { printf 'pkghaus-%s' "$1"; }

# Every package in a suite as "<name>\t<version>", one line per name. aptly
# prints <name>_<version>_<arch>; splitting on _ is safe because neither a
# package name nor a version may contain one. Both architecture lines, and an
# Architecture: all package's single line, collapse under sort -u.
#
# Prints nothing when the repo does not exist yet, and nothing when it is
# empty: aptly exits 1 with "ERROR: no results" for the latter, which is an
# ordinary answer here. A caller that can be harmed by an empty answer has to
# distinguish the two itself.
suite_contents() {
    local repo
    repo="$(repo_of "$1")"
    aptly_ repo show "$repo" >/dev/null 2>&1 || return 0
    # An empty query is not the same as no query: aptly rejects the empty
    # string, so the argument is omitted rather than passed blank.
    if [ -n "${2:-}" ]; then
        set -- "$repo" "$2"
    else
        set -- "$repo"
    fi
    aptly_ repo search "$@" 2>/dev/null |
        awk -F_ 'NF>=3 {print $1 "\t" $2 "\t" $3}' || true
}


# Authenticated read of a published object, straight from the bucket. Used
# where a CDN read would race a publish that has just happened.
aws_() {
    require_r2
    AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
    AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
    AWS_DEFAULT_REGION=auto \
        aws --endpoint-url "$R2_ENDPOINT" "$@"
}

# Any published object, as bytes on stdout. Read from the bucket
# rather than over the CDN wherever this runs seconds after the publish that
# wrote it: an edge still holding the previous render would silently drop
# whatever the run just added. Without credentials (a local preview) the CDN is
# the only source there is.
#
# Prints nothing and succeeds when the index cannot be read. Under `set -e`
# with pipefail a failing fetch inside a pipeline kills its caller where it
# stands, with no diagnostic and no chance to react -- and "the index is
# unreadable" is a thing callers must be able to react to, because for some of
# them it is indistinguishable from "the archive is empty" and acting on that
# deletes things. Deciding what empty means is the caller's job.
archive_object() {
    local path="$1"

    if have_r2; then
        aws_ s3 cp "s3://$R2_BUCKET/$path" - --only-show-errors 2>/dev/null || true
    else
        curl -fsSL --max-time 60 "${BASE_URL:-https://apt.pkg.haus}/$path" 2>/dev/null || true
    fi
}

# A published binary index, decompressed.
index_text() {
    archive_object "dists/$1/main/binary-$2/Packages.gz" | gunzip 2>/dev/null || true
}

# Publishing settings. PUBLISH_ARCHES is comma-separated because that is what
# aptly's flag takes, and is deliberately not named ARCHES: the rendering
# scripts iterate a space-separated list of the same name.
ORIGIN="${ORIGIN:-pkg.haus}"
LABEL="${LABEL:-pkg.haus}"
PUBLISH_ARCHES="${PUBLISH_ARCHES:-amd64,arm64}"
# Pinned rather than left to "the only secret key in the keyring".
SIGN_KEY="${SIGN_KEY:-DD34C42E776B591FBFEB72A162B67F3EA1FA6DEC}"

# Origin and Label are set explicitly: left alone aptly derives them from the
# prefix and distribution and emits "Origin: . trixie", where reprepro emitted
# neither. apt pinning can key on those, so they are ours to choose.
publish_suite() {
    local suite="$1" repo
    repo="$(repo_of "$suite")"

    # -skip-bz2: aptly publishes bzipped indexes and reprepro did not. Debian
    # dropped bz2 years ago and apt prefers gz, so they are three dead objects
    # per suite. The flag is persisted on the publish point, and the update's
    # cleanup pass removes the ones already there.
    if aptly_ publish show "$suite" "$PUBLISH_TARGET" >/dev/null 2>&1; then
        printf 'PUBLISH update %s -> %s\n' "$suite" "$PUBLISH_TARGET" >&2
        aptly_ publish update -batch -skip-bz2 -gpg-key="$SIGN_KEY" \
            "$suite" "$PUBLISH_TARGET"
    else
        printf 'PUBLISH create %s -> %s\n' "$suite" "$PUBLISH_TARGET" >&2
        aptly_ publish repo -batch -skip-bz2 -gpg-key="$SIGN_KEY" \
            -distribution="$suite" -component=main \
            -architectures="$PUBLISH_ARCHES" -origin="$ORIGIN" -label="$LABEL" \
            "$repo" "$PUBLISH_TARGET"
    fi
}
