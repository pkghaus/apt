// pkghaus-archive: put the archive on the network, and count what it serves.
//
// pool/ and dists/ are objects in an R2 bucket that only this Worker can
// read, so this is what makes apt.pkg.haus an archive rather than a bucket.
// Counting rides along because it has to: it is the one place every download
// passes through. A bucket exposed on its own hostname would serve the same
// bytes and count none of them, which is why that arrangement was tried and
// removed.
//
// The /stats page is NOT here. It reads the same D1 database and is served by
// pkghaus-stats on a more specific route, so a bad deploy of a page cannot
// take the archive down. Writer here, reader there.
//
// Serving must never break for counting's sake: every read is wrapped, the
// database write happens after the response via waitUntil, and a request the
// bucket has no object for falls through to the origin.
//
// Privacy: aggregate counters only. No IPs, no user agents, nothing
// per-client is stored or forwarded.

export default {
  async fetch(request, env, ctx) {
    let hit = null;
    let path = null;
    try {
      path = decodeURIComponent(new URL(request.url).pathname);

      // Full downloads only: no Range header (apt resume sends one and a
      // resumed download would double-count), GET only.
      if (request.method === "GET" && !request.headers.has("range")) {
        hit = parse(path);
      }

      const served = await archive(request, env, ctx, path);
      if (served) {
        if (hit && shouldCount(hit, served.status)) {
          ctx.waitUntil(
            record(env, hit).catch((e) => {
              console.error("counter write failed:", e?.message ?? e);
            }),
          );
        }
        return served;
      }
    } catch (e) {
      // Counting is best-effort; serving is not. Logged rather than swallowed:
      // a silent fallthrough and a healthy archive look identical from
      // outside, and this is the path a broken R2 binding takes.
      console.error("archive path failed, falling through:", e?.message ?? e);

      // An ABSENT object returns null and falls through by design, because the
      // listing pages share the pool/ path space and the asset layer answers
      // them. A THROW is different: it means R2 failed, and falling through
      // renders that as 404 -- telling apt the package or index does not
      // exist, which is both false and not retryable. 503 is the truthful
      // answer and the one a client will come back from.
      if (path !== null && ARCHIVE_PREFIXES.some((p) => path.startsWith(p))) {
        return new Response("archive temporarily unavailable\n", {
          status: 503,
          headers: {
            "cache-control": "no-store",
            "retry-after": "30",
            "content-type": "text/plain; charset=utf-8",
          },
        });
      }
    }

    // The asset layer, not the origin. It holds the listing tree, /news/ and
    // the keyring, and answers everything else from the archive's own 404.html
    // through not_found_handling. This host therefore has no origin at all: no
    // request reaches past this Worker, which is what lets its DNS record stop
    // naming a GitHub Pages site that serves none of it.
    //
    // Guarded because the binding exists only where [assets] is configured. A
    // Worker deployed without them keeps serving whatever is behind its route
    // instead of throwing on every miss.
    return env.ASSETS ? env.ASSETS.fetch(request) : fetch(request);
  },
};

// Whether an answer the archive gave counts as the event `hit` describes.
// The two metrics need different rules and used to share one, which is how
// update checks came to undercount: a 304 is not a download, but it is the
// ordinary shape of an update check.
export function shouldCount(hit, status) {
  if (status === 200) return true;
  return hit.kind === "heartbeat" && status === 304;
}

// Anything under these prefixes is the archive proper and is answered from the
// bucket. Everything else on the routes -- the listing pages that share the
// pool/ path space -- is left to Pages.
// The build records used to be served here too, under /buildinfo/. They moved
// to buildinfos.pkg.haus, which is a separate script on a separate host: that
// layout is Debian's source pool, which apt never fetches and no Release file
// references, and this Worker is what answers `apt update`.
const ARCHIVE_PREFIXES = ["/pool/", "/dists/"];

// A pool file is immutable by the archive's own rule -- a version, once
// published, is never rebuilt -- so it is cached at the edge for a month. The
// suite indices are the opposite: they change on every publish and apt must
// see the change immediately, so they are only ever revalidated.
const POOL_MAX_AGE = 2592000;

// Content types the archive actually publishes. apt does not care, but a
// browser following a link from a listing page does, and "download the
// Packages file to read it" should not mean "download" literally.

// Content types the archive actually publishes. apt does not care, but a
// browser following a link from a listing page does, and "download the
// Packages file to read it" should not mean "download" literally.
export function contentType(key) {
  if (key.endsWith(".deb")) return "application/vnd.debian.binary-package";
  if (key.endsWith(".gz")) return "application/gzip";
  if (key.endsWith(".bz2")) return "application/x-bzip2";
  if (key.endsWith(".xz")) return "application/x-xz";
  return "text/plain; charset=utf-8";
}

// The bucket's answer for this request, or null to let Pages answer.
//
// The path arrives percent-decoded, which is what R2 keys are: apt asks for
// pool files with '~' and '+' encoded (%7e/%2b), and the object is stored
// under the literal characters.
async function archive(request, env, ctx, path) {
  if (!env.ARCHIVE) return null;
  if (!ARCHIVE_PREFIXES.some((p) => path.startsWith(p))) return null;
  if (request.method !== "GET" && request.method !== "HEAD") return null;

  const key = path.slice(1);
  const range = request.headers.get("range");
  // A pool object is immutable: a published version is never rebuilt. dists/
  // is the opposite and must never be cached.
  const immutable = path.startsWith("/pool/");

  // A response the worker builds itself never reaches the CDN cache the zone's
  // cache rules configure -- those govern origin fetches, and there is no
  // origin here any more. Without this the 30-day pool cache silently became
  // "read R2 on every download". Only plain full GETs are cached: a 206 is a
  // fragment and a conditional answer is not the object.
  // Not just !range. A precondition or a revalidation can only be answered by
  // R2, because only R2 knows the object as it is now, so a cached copy must
  // not intercept either. Without this the cache returned a full 200 to a
  // request carrying If-None-Match -- 6.3 MB of .deb where a 304 was correct
  // -- and a cached 200 to a failed If-Match, which made the 412 below
  // unreachable for any object the cache held.
  //
  // Measured live before the fix: one 304 with no cf-cache-status, then five
  // 200s with cf-cache-status: HIT. pkghaus-buildinfos had the same defect and
  // was fixed first; this is the same shape in the worker that serves apt.
  const conditional =
    range ||
    request.headers.has("if-none-match") ||
    request.headers.has("if-modified-since") ||
    request.headers.has("if-match") ||
    request.headers.has("if-unmodified-since");
  const cacheable = immutable && request.method === "GET" && !conditional;
  const cacheKey = new Request(`https://apt.pkg.haus${path}`);
  const cache = caches.default;
  if (cacheable) {
    const hit = await cache.match(cacheKey);
    if (hit) return hit;
  }

  // onlyIf gives conditional requests (apt sends If-Modified-Since for the
  // indices on every update) and range requests to R2, which answers them
  // against the object rather than after transferring it.
  let object;
  try {
    object = await env.ARCHIVE.get(key, {
      onlyIf: request.headers,
      range: request.method === "HEAD" ? undefined : request.headers,
    });
  } catch (e) {
    // R2 THROWS for a range it cannot satisfy rather than returning null, and
    // the caller's catch treats any throw as "the bucket does not carry this
    // path" -- so a stale partial download was being answered 404. To apt that
    // means the Release file is gone and `apt update` fails outright, when the
    // client's only problem was a resume offset past the current end of file.
    //
    // Measured in production 2026-09-04: 55 of these in six hours against 59
    // dists/ 404s, every one of them from a Debian APT-HTTP user agent, across
    // fifteen countries. Reproducible: `Range: bytes=6066-` on the 6066-byte
    // InRelease returned 404.
    //
    // RFC 9110 says 416 with the object's real length, which is what tells apt
    // to throw its partial away and start again.
    if (!isUnsatisfiableRange(e)) throw e;
    const head = await env.ARCHIVE.head(key);
    if (head === null) return null; // genuinely absent; let the asset layer answer
    return new Response(null, {
      status: 416,
      headers: {
        "content-range": `bytes */${head.size}`,
        "accept-ranges": "bytes",
        // Specific to this request's Range header, so it must never be stored
        // and replayed to a client that asked for something else.
        "cache-control": "no-store",
      },
    });
  }

  if (object === null) return null; // no such object: Pages may have a page here

  const headers = new Headers();
  object.writeHttpMetadata(headers);
  headers.set("etag", object.httpEtag);
  headers.set("content-type", contentType(key));
  headers.set("accept-ranges", "bytes");
  headers.set(
    "cache-control",
    immutable ? `public, max-age=${POOL_MAX_AGE}, immutable` : "no-cache",
  );

  // A conditional that did not match comes back as an object with no body.
  // Which status that is depends on which condition failed: the "has it
  // changed" pair means the client's copy is current, the "only if it is
  // still this" pair means it is not.
  if (!("body" in object)) {
    const fresh =
      request.headers.has("if-none-match") ||
      request.headers.has("if-modified-since");
    return new Response(null, { status: fresh ? 304 : 412, headers });
  }

  if (request.method === "HEAD") {
    headers.set("content-length", String(object.size));
    return new Response(null, { status: 200, headers });
  }

  if (range && object.range) {
    const [start, end] = resolveRange(object.range, object.size);
    headers.set("content-range", `bytes ${start}-${end}/${object.size}`);
    headers.set("content-length", String(end - start + 1));
    return new Response(object.body, { status: 206, headers });
  }

  headers.set("content-length", String(object.size));
  const response = new Response(object.body, { status: 200, headers });
  if (cacheable) ctx.waitUntil(cache.put(cacheKey, response.clone()));
  return response;
}

// R2 signals an unsatisfiable range by throwing. There is no typed error to
// match on, so this matches the message and the code R2 actually emits -- both,
// because either alone is one upstream wording change away from silently
// reverting this to a 404. Captured verbatim from a production log line:
//   archive path failed, falling through: get: The requested range is not
//   satisfiable (10039)
export function isUnsatisfiableRange(e) {
  const msg = String(e?.message ?? e);
  return msg.includes("range is not satisfiable") || msg.includes("10039");
}

// Measured against live R2 on 2026-09-02: the result's range is always
// {offset, length}, both resolved to numbers, whatever the request asked for --
// a suffix range arrives already converted to an offset, an open-ended one with
// its length filled in. There are not three shapes, there is one.
//
// But all three keys are own properties and `suffix` is always undefined, so
// `"suffix" in range` is true on EVERY result. The old key-presence branch
// therefore fired every time and computed `size - undefined`: this Worker has
// answered ranged requests with `content-range: bytes NaN-<size-1>/<size>`
// since the R2 cutover. The bytes were always right, which is why apt never
// complained -- it fetches whole .debs and reads no Content-Range.
export function resolveRange(range, size) {
  // Guarded on the VALUE, not the key. Unreached by live R2, one typeof, and it
  // keeps the function total if R2 ever reports a suffix it has not resolved.
  if (typeof range.offset !== "number" && typeof range.suffix === "number") {
    return [size - range.suffix, size - 1];
  }
  const start = typeof range.offset === "number" ? range.offset : 0;
  const end = typeof range.length === "number" ? start + range.length - 1 : size - 1;
  return [start, end];
}

// The three real suites. Here this list exists only so parse() refuses a
// heartbeat for a suite the archive does not publish; pkghaus-stats keeps
// its own copy for display ordering. Three strings, deliberately
// duplicated rather than shared through a module across two repos.
const SUITES = ["trixie", "testing", "unstable"];

// /pool/main/z/zola/zola_0.23.3-3~haus13+1_amd64.deb -> download row
// /dists/trixie/InRelease                            -> heartbeat row
//
// The path arrives percent-decoded: apt requests pool files with '~' and
// '+' encoded (%7e/%2b), the same spellings purge-cache.sh has to cover.
// Charsets are the Debian-legal ones with length caps, and heartbeats
// accept only the three real suites; the 200-status gate in fetch() is
// the primary defense, these anchors are the belt to its braces.
export function parse(path) {
  const deb = path.match(
    /^\/pool\/main\/[a-z0-9]{1,8}\/[a-z0-9][a-z0-9+.-]{0,63}\/([a-z0-9][a-z0-9+.-]{0,63})_([A-Za-z0-9.+~-]{1,64})_([a-z0-9]{1,16})\.deb$/,
  );
  if (deb) {
    const [, pkg, version, arch] = deb;
    return { kind: "download", pkg, version, arch, suite: suiteOf(version) };
  }
  const rel = path.match(/^\/dists\/([a-z]{1,16})\/InRelease$/);
  if (rel && SUITES.includes(rel[1])) {
    return { kind: "heartbeat", suite: rel[1] };
  }
  return null;
}

// The version qualifier carries the suite; that is the point of the
// qualifier scheme (~haus < ~testing < plain).
export function suiteOf(version) {
  if (version.includes("~haus")) return "trixie";
  if (version.includes("~testing")) return "testing";
  return "unstable";
}

async function record(env, hit) {
  const day = new Date().toISOString().slice(0, 10);
  if (hit.kind === "download") {
    await env.DB.prepare(
      `INSERT INTO downloads (day, package, version, suite, arch, count)
       VALUES (?1, ?2, ?3, ?4, ?5, 1)
       ON CONFLICT (day, package, version, suite, arch)
       DO UPDATE SET count = count + 1`,
    )
      .bind(day, hit.pkg, hit.version, hit.suite, hit.arch)
      .run();
  } else {
    await env.DB.prepare(
      `INSERT INTO heartbeats (day, suite, count)
       VALUES (?1, ?2, 1)
       ON CONFLICT (day, suite) DO UPDATE SET count = count + 1`,
    )
      .bind(day, hit.suite)
      .run();
  }
}
