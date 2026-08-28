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
    try {
      const path = decodeURIComponent(new URL(request.url).pathname);

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
      // Counting is best-effort; serving is not. A throw here leaves the
      // request to the origin below, which is the correct answer for every
      // path the bucket does not carry anyway. Logged rather than swallowed:
      // a silent fallthrough and a healthy archive look identical from
      // outside, and this is the path a broken R2 binding takes.
      console.error("archive path failed, falling through:", e?.message ?? e);
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
// /buildinfo/ holds the .buildinfo for each published package, written by
// scripts/publish-buildinfo.sh rather than by aptly, which cannot ingest one.
// Served like the rest of the archive; treated as immutable the same way pool
// objects are, since it describes bytes that never change.
const ARCHIVE_PREFIXES = ["/pool/", "/dists/", "/buildinfo/"];

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
  // Both pool objects and buildinfos are immutable: a published version is
  // never rebuilt, and a .buildinfo describes bytes that therefore cannot
  // change. dists/ is the opposite and must never be cached.
  const immutable =
    path.startsWith("/pool/") || path.startsWith("/buildinfo/");

  // A response the worker builds itself never reaches the CDN cache the zone's
  // cache rules configure -- those govern origin fetches, and there is no
  // origin here any more. Without this the 30-day pool cache silently became
  // "read R2 on every download". Only plain full GETs are cached: a 206 is a
  // fragment and a conditional answer is not the object.
  const cacheable = immutable && request.method === "GET" && !range;
  const cacheKey = new Request(`https://apt.pkg.haus${path}`);
  const cache = caches.default;
  if (cacheable) {
    const hit = await cache.match(cacheKey);
    if (hit) return hit;
  }

  // onlyIf gives conditional requests (apt sends If-Modified-Since for the
  // indices on every update) and range requests to R2, which answers them
  // against the object rather than after transferring it.
  const object = await env.ARCHIVE.get(key, {
    onlyIf: request.headers,
    range: request.method === "HEAD" ? undefined : request.headers,
  });

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

// R2 reports the range it served in one of three shapes -- {offset, length},
// {offset} to the end, or {suffix} from the end -- and Content-Range needs
// absolute bounds whichever it was.
export function resolveRange(range, size) {
  if ("suffix" in range) return [size - range.suffix, size - 1];
  const start = "offset" in range ? range.offset : 0;
  const end = "length" in range ? start + range.length - 1 : size - 1;
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
