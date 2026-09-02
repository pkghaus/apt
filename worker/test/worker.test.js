// The parts of the archive worker decidable without a network: what a path
// means, what a range answer means, and which answers count. Each is a place
// where being subtly wrong is invisible in production -- a misparsed path
// silently stops counting, a miscomputed Content-Range silently truncates a
// package, a wrong count gate silently undercounts for weeks.

import test from "node:test";
import assert from "node:assert/strict";
import { parse, suiteOf, contentType, resolveRange, shouldCount } from "../src/worker.js";

test("parse reads a pool download", () => {
  assert.deepEqual(
    parse("/pool/main/z/zola/zola_0.23.4-1~haus13+1_amd64.deb"),
    { kind: "download", pkg: "zola", version: "0.23.4-1~haus13+1", arch: "amd64", suite: "trixie" },
  );
});

test("parse reads a package whose binary name differs from its pool directory", () => {
  const hit = parse("/pool/main/s/superfile/superfile_1.6.0-1~testing1_arm64.deb");
  assert.equal(hit.pkg, "superfile");
  assert.equal(hit.suite, "testing");
});

test("parse reads an arch-all package", () => {
  const hit = parse("/pool/main/p/pkghaus-archive-keyring/pkghaus-archive-keyring_2026.08.15_all.deb");
  assert.equal(hit.arch, "all");
  assert.equal(hit.suite, "unstable");
});

test("parse reads a suite heartbeat and rejects an invented suite", () => {
  assert.deepEqual(parse("/dists/trixie/InRelease"), { kind: "heartbeat", suite: "trixie" });
  assert.equal(parse("/dists/bookworm/InRelease"), null);
});

test("parse ignores everything that is not a package or a heartbeat", () => {
  for (const path of [
    "/pool/main/z/zola/",
    "/pool/main/z/zola/index.html",
    "/dists/trixie/main/binary-amd64/Packages.gz",
    "/../etc/passwd",
    "/pool/main/z/zola/zola_0.23.4-1_amd64.deb.sig",
  ]) {
    assert.equal(parse(path), null, path);
  }
});

test("suiteOf reads the suite out of the version qualifier", () => {
  assert.equal(suiteOf("1.2.3-1~haus13+1"), "trixie");
  assert.equal(suiteOf("1.2.3-1~testing1"), "testing");
  assert.equal(suiteOf("1.2.3-1"), "unstable");
});

test("contentType names what the archive publishes", () => {
  assert.equal(contentType("pool/main/d/d2/d2_0.7.1-2_amd64.deb"), "application/vnd.debian.binary-package");
  assert.equal(contentType("dists/trixie/main/binary-amd64/Packages.gz"), "application/gzip");
  assert.equal(contentType("dists/trixie/main/binary-amd64/Packages.bz2"), "application/x-bzip2");
  assert.equal(contentType("dists/trixie/InRelease"), "text/plain; charset=utf-8");
});

test("resolveRange reads R2's values, never its keys", () => {
  // The shape live R2 actually returns, measured 2026-09-02 across all four
  // request forms: offset and length resolved, `suffix` present and undefined.
  // A range object without that third key is one R2 never produces, and it is
  // what the old fixtures asserted against while production served NaN.
  assert.deepEqual(resolveRange({ offset: 100, length: 50, suffix: undefined }, 1000),
    [100, 149]);
  assert.deepEqual(resolveRange({ offset: 900, length: 100, suffix: undefined }, 1000),
    [900, 999]);
  assert.deepEqual(resolveRange({ offset: 0, length: 1000, suffix: undefined }, 1000),
    [0, 999]);

  // Shapes R2 does not return today. Kept because the function must stay total.
  assert.deepEqual(resolveRange({ offset: 900 }, 1000), [900, 999]);
  assert.deepEqual(resolveRange({ suffix: 100 }, 1000), [900, 999]);
  assert.deepEqual(resolveRange({ length: 10 }, 1000), [0, 9]);
});

test("resolveRange covers the whole object when R2 reports no bounds", () => {
  assert.deepEqual(resolveRange({}, 1000), [0, 999]);
});

test("304 counts as an update check but never as a download", () => {
  const dl = { kind: "download" };
  const hb = { kind: "heartbeat" };

  assert.equal(shouldCount(dl, 200), true);
  assert.equal(shouldCount(hb, 200), true);

  assert.equal(shouldCount(hb, 304), true, "a 304 InRelease is an update check");
  assert.equal(shouldCount(dl, 304), false, "a 304 .deb is not a download");

  for (const status of [206, 404, 412, 500]) {
    assert.equal(shouldCount(dl, status), false, `download must not count ${status}`);
    assert.equal(shouldCount(hb, status), false, `heartbeat must not count ${status}`);
  }
});
