#!/usr/bin/env bash
#
#   sync-package-inventory.sh [tsv]
#
# Mirrors the archive's package set into the `packages` table of the D1
# database that backs apt.pkg.haus/stats.
#
# WHY THIS EXISTS. The stats page's "downloads by package" table is built from
# `downloads`, which gains a row only when a .deb is actually served. A package
# the archive carries but nobody has installed yet therefore has no row at all,
# and no query can invent one -- so it was missing from the page entirely,
# which reads as "not in the archive" rather than "not yet downloaded". The
# reader unions this table with `downloads`; this is what supplies the names.
#
# Source is news/known-packages.tsv, rewritten by news.sh from the aptly
# database on every publish, so it already IS the published set. news.sh runs
# before this in the ingest, so the file is current here.
#
# Writes are an upsert plus a prune, not a DELETE-then-INSERT: there is never a
# moment when the table is empty, and a package that leaves the fleet leaves
# the table with it. The counters are all-time and the reader unions the two
# sets, so a retired package keeps its download history on the page even after
# this drops it from the inventory.
#
# This never creates the table. Creating it is a deliberate act performed once
# by a human, exactly like the database itself -- see worker/schema.sql.

set -euo pipefail
shopt -s inherit_errexit

ARCHIVE_DIR="${ARCHIVE_DIR:-public}"
TSV="${1:-$ARCHIVE_DIR/news/known-packages.tsv}"
DB_NAME="${D1_DATABASE_NAME:-pkghaus-stats}"

# Build the statements. Kept as a function so tests can read the SQL without a
# database, a network, or credentials.
inventory_sql() {
    local tsv="$1"
    python3 - "$tsv" <<'PY'
import sys

def q(value):
    return "'" + value.replace("'", "''") + "'"

rows = []
for number, line in enumerate(open(sys.argv[1], encoding="utf-8"), 1):
    line = line.rstrip("\n")
    if not line.strip():
        continue
    parts = line.split("\t")
    if len(parts) < 2 or not parts[0]:
        sys.exit(f"FATAL: {sys.argv[1]} line {number} is not <name>\\t<version>")
    # A retirement leaves the name with an empty version until the next
    # publish drops the line. It is not in the archive, so it is not in the
    # inventory -- and the reader keeps its downloads regardless.
    if not parts[1]:
        continue
    rows.append((parts[0], parts[1]))

if not rows:
    sys.exit("FATAL: no packages parsed; refusing to prune the inventory to nothing")

for name, version in rows:
    print(
        "INSERT INTO packages (package, version) VALUES "
        f"({q(name)}, {q(version)}) "
        "ON CONFLICT(package) DO UPDATE SET version = excluded.version;"
    )
keep = ", ".join(q(name) for name, _ in rows)
print(f"DELETE FROM packages WHERE package NOT IN ({keep});")
PY
}

# Sourced by the tests; everything below runs only when executed.
# shellcheck disable=SC2317
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    return 0
fi

[ -s "$TSV" ] || {
    echo "FATAL: $TSV is missing or empty; refusing to touch the inventory" >&2
    exit 1
}

sql="$(mktemp)"
trap 'rm -f "$sql"' EXIT
inventory_sql "$TSV" > "$sql"

echo "syncing $(grep -c '^INSERT INTO packages' "$sql") packages into $DB_NAME" >&2
npx wrangler d1 execute "$DB_NAME" --remote --yes --file "$sql"
