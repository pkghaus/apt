// The serving path, exercised end to end against fakes for R2, D1 and the
// Cache API. Nothing here needs a network.
//
// This is the half that had no coverage before the split: parse() and
// resolveRange() were unit-tested, but archive() and the fetch handler that
// wires them together were not, so a missing reference or a wrong header
// would only have surfaced when a real request arrived. The rules being
// checked are the ones that are silent when wrong -- a .deb served with the
// index's cache lifetime, a 304 that stops counting an update check, a
// database failure that takes serving down with it.

import test from "node:test";
import assert from "node:assert/strict";
import worker from "../src/worker.js";

const BODY = "x".repeat(4096);

function r2Object({ body = BODY, size = BODY.length, range } = {}) {
  const o = {
    size,
    httpEtag: '"deadbeef"',
    writeHttpMetadata(h) { h.set("last-modified", "Mon, 25 Aug 2026 08:00:00 GMT"); },
  };
  if (body !== null) o.body = body;
  // Real R2 puts all three keys on the range object with `suffix` always
  // undefined (measured 2026-09-02). A hand-built {offset, length} is a shape
  // R2 never returns, and testing against it is how the NaN in Content-Range
  // reached production and stayed there.
  if (range) o.range = { suffix: undefined, ...range };
  return o;
}

function harness({ object = r2Object(), throwOnGet = false, d1Throws = false } = {}) {
  const writes = [];
  const tasks = [];
  globalThis.caches = { default: { match: async () => undefined, put: async () => {} } };
  globalThis.fetch = async () => new Response("origin", { status: 418 });
  const env = {
    // A distinct sentinel from the origin's 418. These tests have to tell
    // "handed to the asset layer" apart from "handed to whatever is behind the
    // route", and until this binding existed those were one path.
    ASSETS: { fetch: async () => new Response("asset-404", { status: 404 }) },
    ARCHIVE: {
      async get(key, opts) {
        if (throwOnGet) throw new Error("bucket unreachable");
        return object === null ? null : { ...object, key, opts };
      },
    },
    DB: {
      prepare(sql) {
        return {
          bind(...args) {
            return { async run() {
              if (d1Throws) throw new Error("D1 down");
              writes.push({ sql: sql.trim().split("\n")[0], args });
            } };
          },
        };
      },
    },
  };
  const ctx = { waitUntil: (p) => tasks.push(p) };
  return { env, ctx, writes, settle: () => Promise.allSettled(tasks) };
}

const DEB = "/pool/main/c/croc/croc_11.3.0-1~haus13+1_amd64.deb";
const REL = "/dists/trixie/InRelease";

test("a pool .deb is served immutable for a month and counted once", async () => {
  const h = harness();
  const res = await worker.fetch(new Request("https://apt.pkg.haus" + DEB), h.env, h.ctx);
  await h.settle();
  assert.equal(res.status, 200);
  assert.equal(res.headers.get("content-type"), "application/vnd.debian.binary-package");
  assert.equal(res.headers.get("cache-control"), "public, max-age=2592000, immutable");
  assert.equal(res.headers.get("content-length"), String(BODY.length));
  assert.equal(res.headers.get("accept-ranges"), "bytes");
  assert.equal(h.writes.length, 1);
  assert.match(h.writes[0].sql, /INSERT INTO downloads/);
  assert.deepEqual(h.writes[0].args.slice(1),
    ["croc", "11.3.0-1~haus13+1", "trixie", "amd64"],
    "package, version, suite and arch, with the day first");
});

const BUILDINFO = "/buildinfo/c/croc/croc_11.3.0-1~haus13+1_amd64.buildinfo";

// The build records moved to buildinfos.pkg.haus, served by pkghaus-buildinfos
// out of the same bucket under a buildinfos/ prefix. This Worker must not
// answer for them any more: the object it would reach is not even the same key.
test("a buildinfo is no longer this Worker's to serve", async () => {
  const h = harness();
  const res = await worker.fetch(new Request("https://apt.pkg.haus" + BUILDINFO), h.env, h.ctx);
  await h.settle();
  assert.notEqual(res.status, 200,
    "buildinfo/ moved to buildinfos.pkg.haus; this host must not serve it from R2");
  assert.equal(h.writes.length, 0, "and nothing about it reaches the counters");
});

test("an index is never cached, and a fresh one counts as an update check", async () => {
  const h = harness();
  const res = await worker.fetch(new Request("https://apt.pkg.haus" + REL), h.env, h.ctx);
  await h.settle();
  assert.equal(res.status, 200);
  assert.equal(res.headers.get("cache-control"), "no-cache");
  assert.equal(h.writes.length, 1);
  assert.match(h.writes[0].sql, /INSERT INTO heartbeats/);
});

test("a 304 on an index still counts, which is the whole update-check fix", async () => {
  const h = harness({ object: r2Object({ body: null }) });
  const res = await worker.fetch(
    new Request("https://apt.pkg.haus" + REL, { headers: { "if-none-match": '"deadbeef"' } }),
    h.env, h.ctx);
  await h.settle();
  assert.equal(res.status, 304);
  assert.equal(h.writes.length, 1, "a repeat apt update must be counted");
  assert.match(h.writes[0].sql, /INSERT INTO heartbeats/);
});

test("a 304 on a .deb is not a download", async () => {
  const h = harness({ object: r2Object({ body: null }) });
  const res = await worker.fetch(
    new Request("https://apt.pkg.haus" + DEB, { headers: { "if-none-match": '"deadbeef"' } }),
    h.env, h.ctx);
  await h.settle();
  assert.equal(res.status, 304);
  assert.equal(h.writes.length, 0);
});

test("a range request answers 206 with absolute bounds and is not counted", async () => {
  const h = harness({ object: r2Object({ range: { offset: 10, length: 90 } }) });
  const res = await worker.fetch(
    new Request("https://apt.pkg.haus" + DEB, { headers: { range: "bytes=10-99" } }),
    h.env, h.ctx);
  await h.settle();
  assert.equal(res.status, 206);
  assert.equal(res.headers.get("content-range"), `bytes 10-99/${BODY.length}`);
  assert.equal(res.headers.get("content-length"), "90");
  assert.equal(h.writes.length, 0, "a resumed download was already counted by its opening 200");
});

test("HEAD reports the size without a body and without counting", async () => {
  const h = harness();
  const res = await worker.fetch(
    new Request("https://apt.pkg.haus" + DEB, { method: "HEAD" }), h.env, h.ctx);
  await h.settle();
  assert.equal(res.status, 200);
  assert.equal(res.headers.get("content-length"), String(BODY.length));
  assert.equal(await res.text(), "");
  assert.equal(h.writes.length, 0);
});

test("an object the bucket does not have goes to the asset layer", async () => {
  const h = harness({ object: null });
  const res = await worker.fetch(new Request("https://apt.pkg.haus" + DEB), h.env, h.ctx);
  await h.settle();
  assert.equal(res.status, 404, "the asset layer answered, not an origin");
  assert.equal(await res.text(), "asset-404");
  assert.equal(h.writes.length, 0);
});

test("without an ASSETS binding it still falls through to the origin", async () => {
  const h = harness({ object: null });
  delete h.env.ASSETS;
  const res = await worker.fetch(new Request("https://apt.pkg.haus" + DEB), h.env, h.ctx);
  await h.settle();
  assert.equal(res.status, 418, "a Worker without assets keeps whatever is behind its route");
});

test("a path outside pool/ and dists/ is left to the asset layer", async () => {
  const h = harness();
  const res = await worker.fetch(new Request("https://apt.pkg.haus/news/"), h.env, h.ctx);
  await h.settle();
  assert.equal(res.status, 404);
  assert.equal(await res.text(), "asset-404");
  assert.equal(h.writes.length, 0);
});

test("a malformed percent-escape falls through instead of throwing", async () => {
  const h = harness();
  const res = await worker.fetch(new Request("https://apt.pkg.haus/pool/%zz"), h.env, h.ctx);
  await h.settle();
  assert.equal(res.status, 404);
});

test("an unreachable bucket falls through rather than erroring", async () => {
  const h = harness({ throwOnGet: true });
  const res = await worker.fetch(new Request("https://apt.pkg.haus" + DEB), h.env, h.ctx);
  await h.settle();
  assert.equal(res.status, 404, "serving must not turn a bucket failure into a 500");
});

test("a database that will not accept the write does not break serving", async () => {
  const h = harness({ d1Throws: true });
  const res = await worker.fetch(new Request("https://apt.pkg.haus" + DEB), h.env, h.ctx);
  await h.settle();
  assert.equal(res.status, 200, "counting is best-effort; serving is not");
  assert.equal(await res.text(), BODY);
});

test("the percent-encoded spellings apt sends resolve to the same object", async () => {
  const h = harness();
  const encoded = "/pool/main/c/croc/croc_11.3.0-1%7Ehaus13%2B1_amd64.deb";
  const res = await worker.fetch(new Request("https://apt.pkg.haus" + encoded), h.env, h.ctx);
  await h.settle();
  assert.equal(res.status, 200);
  assert.equal(h.writes.length, 1, "an encoded request counts like a literal one");
  assert.ok(h.writes[0].args.includes("11.3.0-1~haus13+1"), "the version is the decoded form");
});
