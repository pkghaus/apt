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

function harness({ object = r2Object(), throwOnGet = false, d1Throws = false,
                   rangeError = false, headObject = undefined } = {}) {
  const writes = [];
  const reads = [];
  const tasks = [];
  // A cache that actually stores. It was a pair of no-ops, which made the warm
  // cache unrepresentable -- and a cache that never hits cannot demonstrate the
  // one thing worth asserting here, that a conditional request is not answered
  // from it.
  const cacheStore = new Map();
  globalThis.caches = {
    default: {
      async match(req) { const h = cacheStore.get(req.url); return h ? h.clone() : undefined; },
      async put(req, res) { cacheStore.set(req.url, res.clone()); },
    },
  };
  globalThis.fetch = async () => new Response("origin", { status: 418 });
  const env = {
    // A distinct sentinel from the origin's 418. These tests have to tell
    // "handed to the asset layer" apart from "handed to whatever is behind the
    // route", and until this binding existed those were one path.
    ASSETS: { fetch: async () => new Response("asset-404", { status: 404 }) },
    ARCHIVE: {
      // R2 does not return null for a range it cannot satisfy -- it THROWS,
      // with this exact wording. Copied from a production log line rather than
      // invented, because a fake that throws something else would let the
      // matcher rot without any test noticing.
      async head(key) {
        if (headObject !== undefined) return headObject;
        return object === null ? null : { size: object.size, key };
      },
      async get(key, opts) {
        if (rangeError) {
          throw new Error("get: The requested range is not satisfiable (10039)");
        }
        if (throwOnGet) throw new Error("bucket unreachable");
        reads.push(key);
        if (object === null) return null;
        const o = { ...object, key, opts };

        // Honour onlyIf, the way R2 does: a satisfied "has it changed" or a
        // FAILED "only if it is still this" both come back with no body, and
        // it is the Worker's job to turn that into 304 or 412. Modelled here
        // so a conditional request can be tested against a WARM cache -- with
        // a fixed object the cache could always be the thing answering, which
        // is exactly the bug this hid.
        const h = opts?.onlyIf instanceof Headers ? opts.onlyIf : null;
        if (h) {
          const inm = h.get("if-none-match");
          const im = h.get("if-match");
          if (inm === o.httpEtag || (im && im !== o.httpEtag)) delete o.body;
        }
        return o;
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
  return { env, ctx, writes, reads, cacheStore, settle: () => Promise.allSettled(tasks) };
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

// Was asserting 404. That satisfied the letter of "do not turn a bucket failure
// into a 500" and broke the spirit: 404 tells apt the package does not exist,
// which is false, is not retryable, and is exactly what a failing R2 looked
// like from outside. An ABSENT object still falls through -- that is a
// different path, and the two tests below hold it.
test("an unreachable bucket says so, retryably, instead of denying the file", async () => {
  const h = harness({ throwOnGet: true });
  const res = await worker.fetch(new Request("https://apt.pkg.haus" + DEB), h.env, h.ctx);
  await h.settle();
  assert.equal(res.status, 503, "a bucket failure is not the same as a missing file");
  assert.equal(res.headers.get("retry-after"), "30");
  assert.equal(res.headers.get("cache-control"), "no-store");
});

test("an absent object still falls through to the asset layer", async () => {
  const h = harness({ object: null });
  const res = await worker.fetch(new Request("https://apt.pkg.haus/pool/main/c/croc/"), h.env, h.ctx);
  await h.settle();
  assert.equal(res.status, 404, "the listing pages share the pool/ path space");
});

test("a failure outside the archive prefixes still falls through", async () => {
  const h = harness({ throwOnGet: true });
  const res = await worker.fetch(new Request("https://apt.pkg.haus/news/"), h.env, h.ctx);
  await h.settle();
  assert.equal(res.status, 404, "only pool/ and dists/ are the archive's to claim");
});

// The bug this file exists to prevent recurring. apt sends a Range when it
// resumes a partial download; if the file changed size the offset can land past
// the end, R2 throws, and the worker used to answer 404 -- which told apt the
// Release file was gone and failed `apt update` outright. Measured in
// production 2026-09-04: 55 range errors against 59 dists/ 404s in six hours,
// every one from a Debian APT-HTTP agent.
test("a range past the end is 416 with the real length, not 404", async () => {
  const h = harness({ rangeError: true, headObject: { size: 6066 } });
  const res = await worker.fetch(
    new Request("https://apt.pkg.haus" + REL, { headers: { range: "bytes=6066-" } }),
    h.env, h.ctx);
  await h.settle();
  assert.equal(res.status, 416, "404 here breaks apt update for a stale partial");
  assert.equal(res.headers.get("content-range"), "bytes */6066",
    "apt needs the real length to know where to restart");
  assert.equal(res.headers.get("accept-ranges"), "bytes");
});

test("the 416 is never stored, since it answers one specific Range", async () => {
  const h = harness({ rangeError: true, headObject: { size: 6066 } });
  const res = await worker.fetch(
    new Request("https://apt.pkg.haus" + DEB, { headers: { range: "bytes=999999-" } }),
    h.env, h.ctx);
  await h.settle();
  assert.equal(res.status, 416);
  assert.equal(res.headers.get("cache-control"), "no-store");
  assert.equal(h.cacheStore.size, 0, "a 416 must not enter the cache");
});

test("a bad range on an object that is genuinely gone still falls through", async () => {
  const h = harness({ rangeError: true, headObject: null });
  const res = await worker.fetch(
    new Request("https://apt.pkg.haus" + REL, { headers: { range: "bytes=10-" } }),
    h.env, h.ctx);
  await h.settle();
  assert.equal(res.status, 404, "no object means the asset layer answers, as before");
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

// The cache must not answer anything only R2 can answer. Every conditional
// test above starts cold, so none of them could see the cache intercepting --
// which is how a cached 200 came to be returned for a request carrying
// If-None-Match, 6.3 MB of .deb where a 304 was correct.
const warm = async (h, path = DEB) => {
  const first = await worker.fetch(new Request("https://apt.pkg.haus" + path), h.env, h.ctx);
  await h.settle();
  assert.equal(first.status, 200);
  assert.ok(h.cacheStore.size > 0, "the object has to be cached for this to mean anything");
};

test("a warm cache still serves a plain GET without reading R2", async () => {
  const h = harness();
  await warm(h);
  const before = h.reads.length;
  const res = await worker.fetch(new Request("https://apt.pkg.haus" + DEB), h.env, h.ctx);
  await h.settle();
  assert.equal(res.status, 200);
  assert.equal(await res.text(), BODY);
  assert.equal(h.reads.length, before, "a plain GET must come from the cache");
});

test("If-None-Match is answered by R2, not the warm cache", async () => {
  const h = harness();
  await warm(h);
  const before = h.reads.length;
  const res = await worker.fetch(
    new Request("https://apt.pkg.haus" + DEB, { headers: { "if-none-match": '"deadbeef"' } }),
    h.env, h.ctx);
  await h.settle();
  assert.equal(res.status, 304, "a cached 200 here re-sends the whole .deb");
  assert.equal(h.reads.length, before + 1, "the conditional must reach the bucket");
});

test("a failed If-Match is a 412 even when the object is cached", async () => {
  const h = harness();
  await warm(h);
  const res = await worker.fetch(
    new Request("https://apt.pkg.haus" + DEB, { headers: { "if-match": '"stale"' } }),
    h.env, h.ctx);
  await h.settle();
  assert.equal(res.status, 412);
});

test("If-Modified-Since is answered by R2, not the warm cache", async () => {
  const h = harness();
  await warm(h);
  const before = h.reads.length;
  await worker.fetch(
    new Request("https://apt.pkg.haus" + DEB,
      { headers: { "if-modified-since": "Mon, 25 Aug 2026 08:00:00 GMT" } }),
    h.env, h.ctx);
  await h.settle();
  assert.equal(h.reads.length, before + 1);
});

test("If-Unmodified-Since is answered by R2, not the warm cache", async () => {
  const h = harness();
  await warm(h);
  const before = h.reads.length;
  await worker.fetch(
    new Request("https://apt.pkg.haus" + DEB,
      { headers: { "if-unmodified-since": "Mon, 25 Aug 2026 08:00:00 GMT" } }),
    h.env, h.ctx);
  await h.settle();
  assert.equal(h.reads.length, before + 1);
});

test("a conditional request is never stored under the plain GET's key", async () => {
  const h = harness();
  await worker.fetch(
    new Request("https://apt.pkg.haus" + DEB, { headers: { "if-none-match": '"deadbeef"' } }),
    h.env, h.ctx);
  await h.settle();
  assert.equal(h.cacheStore.size, 0, "a 304 is not the object");
});
