// @ts-nocheck -- test helper on Node built-ins; the worker tsconfig has no Node types.
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import type { Env } from "../../src/types";

const require = createRequire(import.meta.url);

/** A real SQLite database behind the D1 calls the worker makes, loaded with schema.sql. */
export function sqliteD1(): { db: Env["DB"]; raw: { prepare(sql: string): { all(...a: unknown[]): unknown[]; get(...a: unknown[]): unknown; run(...a: unknown[]): unknown } } } {
  const { DatabaseSync } = require("node:sqlite") as { DatabaseSync: new (path: string) => any };
  const raw = new DatabaseSync(":memory:");
  raw.exec(readFileSync(new URL("../../schema.sql", import.meta.url), "utf8"));
  const clean = (args: unknown[]) => args.map((v) => (v === undefined ? null : typeof v === "boolean" ? (v ? 1 : 0) : v));
  const db = {
    prepare(sql: string) {
      let bound: unknown[] = [];
      const statement = {
        bind(...args: unknown[]) {
          bound = clean(args);
          return statement;
        },
        async first<T>() {
          const row = raw.prepare(sql).get(...bound);
          return (row ? { ...row } : null) as T | null;
        },
        async all<T>() {
          const rows = raw.prepare(sql).all(...bound).map((r: object) => ({ ...r }));
          return { results: rows as T[], success: true, meta: {} };
        },
        async run() {
          const info = raw.prepare(sql).run(...bound) as { changes: number | bigint };
          return { success: true, meta: { changes: Number(info.changes) } };
        },
      };
      return statement;
    },
    async batch() {
      return [];
    },
    async exec(sql: string) {
      raw.exec(sql);
      return { count: 0, duration: 0 };
    },
  } as unknown as Env["DB"];
  return { db, raw };
}
