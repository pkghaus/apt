// A D1-shaped shim over node:sqlite, so a test can hand the real Worker a
// real database and exercise the queries the Worker actually contains rather
// than copies of them pasted into a test.
//
// node:sqlite is unflagged on Node 22 but still prints an ExperimentalWarning
// there; Node 24 is silent. The API used here (DatabaseSync, exec, prepare,
// run, all) behaves identically on both, verified before relying on it.

import { DatabaseSync } from "node:sqlite";
import { readFileSync } from "node:fs";

// node:sqlite hands back null-prototype rows, which D1 does not, and which
// deepStrictEqual refuses to match against an object literal. Normalising here
// keeps that detail out of every assertion.
const plain = (rows) => rows.map((r) => ({ ...r }));

export function d1(schemaPath) {
  const db = new DatabaseSync(":memory:");
  db.exec(readFileSync(schemaPath, "utf8"));
  const wrap = (sql, args) => ({
    bind: (...a) => wrap(sql, a),
    run: () => db.prepare(sql).run(...(args ?? [])),
    all: () => ({ results: plain(db.prepare(sql).all(...(args ?? []))) }),
  });
  return {
    binding: { prepare: (sql) => wrap(sql, null) },
    rows: (table) => plain(db.prepare(`SELECT * FROM ${table}`).all()),
    exec: (sql, ...a) => db.prepare(sql).run(...a),
  };
}
