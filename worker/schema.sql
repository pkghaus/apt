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
