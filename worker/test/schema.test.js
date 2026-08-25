// The Worker's own INSERTs, run against the real schema.sql in a real
// database. Nothing here retypes the SQL: the requests go through
// worker.fetch(), so what is exercised is the statement the Worker contains.
//
// The failure this catches is silent in production. record() is called inside
// waitUntil and its rejection is logged, not surfaced, so a statement that no
// longer matches the schema would stop counting while every response stayed
// 200 and the page just showed a flat line.

import test from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import worker from "../src/worker.js";
import { d1 } from "./d1.js";

const SCHEMA = fileURLToPath(new URL("../schema.sql", import.meta.url));
const DEB = "/pool/main/c/croc/croc_11.3.0-1~haus13+1_amd64.deb";
const REL = "/dists/trixie/InRelease";

function env() {
  const db = d1(SCHEMA);
  const tasks = [];
  globalThis.caches = { default: { match: async () => undefined, put: async () => {} } };
  globalThis.fetch = async () => new Response("origin", { status: 418 });
  return {
    db,
    env: {
      DB: db.binding,
      ARCHIVE: {
        async get() {
          return {
            body: "x", size: 1, httpEtag: '"e"',
            writeHttpMetadata(h) { h.set("last-modified", "Mon, 25 Aug 2026 08:00:00 GMT"); },
          };
        },
      },
    },
    ctx: { waitUntil: (p) => tasks.push(p) },
    settle: () => Promise.allSettled(tasks),
  };
}

test("a download insert matches the schema and lands a row", async () => {
  const h = env();
  await worker.fetch(new Request("https://apt.pkg.haus" + DEB), h.env, h.ctx);
  await h.settle();
  assert.deepEqual(h.db.rows("downloads"), [{
    day: new Date().toISOString().slice(0, 10),
    package: "croc", version: "11.3.0-1~haus13+1", suite: "trixie",
    arch: "amd64", count: 1,
  }]);
});

test("a second download of the same thing upserts rather than duplicating", async () => {
  const h = env();
  for (let i = 0; i < 3; i++) {
    await worker.fetch(new Request("https://apt.pkg.haus" + DEB), h.env, h.ctx);
  }
  await h.settle();
  const rows = h.db.rows("downloads");
  assert.equal(rows.length, 1, "ON CONFLICT must collapse onto the primary key");
  assert.equal(rows[0].count, 3);
});

test("an update check insert matches the schema and upserts too", async () => {
  const h = env();
  for (let i = 0; i < 2; i++) {
    await worker.fetch(new Request("https://apt.pkg.haus" + REL), h.env, h.ctx);
  }
  await h.settle();
  const rows = h.db.rows("heartbeats");
  assert.equal(rows.length, 1);
  assert.equal(rows[0].suite, "trixie");
  assert.equal(rows[0].count, 2);
});

test("two architectures of one version are separate rows, not one", async () => {
  const h = env();
  for (const a of ["amd64", "arm64"]) {
    await worker.fetch(new Request(
      `https://apt.pkg.haus/pool/main/c/croc/croc_11.3.0-1~haus13+1_${a}.deb`), h.env, h.ctx);
  }
  await h.settle();
  assert.equal(h.db.rows("downloads").length, 2, "arch is part of the primary key");
});
