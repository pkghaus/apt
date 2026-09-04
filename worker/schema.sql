-- Aggregate counters only; nothing per-client is ever stored.
CREATE TABLE IF NOT EXISTS downloads (
    day TEXT NOT NULL,     -- YYYY-MM-DD, UTC
    package TEXT NOT NULL,
    version TEXT NOT NULL, -- full Debian version incl. suite qualifier
    suite TEXT NOT NULL,   -- trixie | testing | unstable, from the qualifier
    arch TEXT NOT NULL,
    count INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (day, package, version, suite, arch)
);

CREATE TABLE IF NOT EXISTS heartbeats (
    day TEXT NOT NULL,   -- YYYY-MM-DD, UTC
    suite TEXT NOT NULL, -- dists/<suite>/InRelease as requested
    count INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (day, suite)
);

-- Every package the archive currently serves, mirrored from
-- news/known-packages.tsv by scripts/sync-package-inventory.sh on each publish.
--
-- Exists because `downloads` gains a row only when a .deb is served, so the
-- stats page could never mention a package nobody had installed yet. The
-- reader (pkghaus/stats) UNIONs the two, which is also why pruning a retired
-- package from here does not remove its download history.
CREATE TABLE IF NOT EXISTS packages (
    package TEXT PRIMARY KEY,
    version TEXT NOT NULL  -- as published to unstable, the unqualified version
);
