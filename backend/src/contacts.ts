import { dbAll, dbFirst, dbRun, type SqlParam } from "./db";
import { apiError, asString, isRecord, json, nowIso, readJson } from "./http";
import type { Env } from "./types";

/**
 * Sir's phone contacts: names and numbers only, synced from the iPhone app into a private D1 table.
 * Only the app token can write or read them. Nothing here is ever logged in full or committed.
 */

export interface ContactRow {
  name: string;
  phone: string;
  label: string;
}

export interface ContactMatch extends ContactRow {
  score: number;
}

const MAX_CONTACTS = 5000;
const MAX_ROWS = 10000;
let ready = false;

export async function ensureContactsTable(env: Env): Promise<void> {
  if (ready) return;
  await dbRun(
    env,
    `CREATE TABLE IF NOT EXISTS owner_contacts (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       name TEXT NOT NULL,
       name_key TEXT NOT NULL,
       phone TEXT NOT NULL,
       label TEXT NOT NULL DEFAULT '',
       synced_at TEXT NOT NULL
     )`,
  );
  await dbRun(env, "CREATE INDEX IF NOT EXISTS owner_contacts_key ON owner_contacts (name_key)");
  ready = true;
}

/** Tests only. */
export function resetContactsReady(): void {
  ready = false;
}

export function nameKey(raw: string): string {
  return raw
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9 ]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function cleanLabel(raw: unknown): string {
  if (typeof raw !== "string") return "";
  return raw.replace(/_\$!<|>!\$_/g, "").replace(/[^A-Za-z0-9 ]+/g, " ").trim().toLowerCase().slice(0, 20);
}

/** Parse and normalise an app upload. Drops contacts with no usable number. */
export async function parseUpload(raw: unknown): Promise<ContactRow[]> {
  const { toE164 } = await import("./calls");
  if (!isRecord(raw) || !Array.isArray(raw.contacts)) return [];
  const rows: ContactRow[] = [];
  const seen = new Set<string>();
  for (const item of raw.contacts.slice(0, MAX_CONTACTS)) {
    if (!isRecord(item)) continue;
    const name = (asString(item.name, 120) ?? "").replace(/\s+/g, " ");
    if (!name || !nameKey(name)) continue;
    const phones = Array.isArray(item.phones) ? item.phones : [];
    for (const p of phones.slice(0, 8)) {
      const number = typeof p === "string" ? p : isRecord(p) ? p.number : null;
      const e164 = typeof number === "string" ? toE164(number) : null;
      if (!e164) continue;
      const key = `${nameKey(name)}|${e164}`;
      if (seen.has(key)) continue;
      seen.add(key);
      rows.push({ name, phone: e164, label: isRecord(p) ? cleanLabel(p.label) : "" });
      if (rows.length >= MAX_ROWS) return rows;
    }
  }
  return rows;
}

/** Replace the stored list with this upload. An empty upload never wipes the table. */
export async function replaceContacts(env: Env, rows: ContactRow[]): Promise<number> {
  await ensureContactsTable(env);
  if (!rows.length) return 0;
  const stamp = nowIso();
  await dbRun(env, "DELETE FROM owner_contacts");
  const per = 16; // 5 params each, under D1's 100 bound-parameter limit.
  for (let i = 0; i < rows.length; i += per) {
    const chunk = rows.slice(i, i + per);
    const params: SqlParam[] = [];
    for (const r of chunk) params.push(r.name, nameKey(r.name), r.phone, r.label, stamp);
    await dbRun(
      env,
      `INSERT INTO owner_contacts (name, name_key, phone, label, synced_at) VALUES ${chunk.map(() => "(?, ?, ?, ?, ?)").join(", ")}`,
      params,
    );
  }
  return rows.length;
}

export async function contactsStatus(env: Env): Promise<{ count: number; people: number; synced_at: string | null }> {
  await ensureContactsTable(env);
  const row = await dbFirst<{ n: number; people: number; at: string | null }>(
    env,
    "SELECT COUNT(*) AS n, COUNT(DISTINCT name_key) AS people, MAX(synced_at) AS at FROM owner_contacts",
  );
  return { count: Number(row?.n ?? 0), people: Number(row?.people ?? 0), synced_at: row?.at ?? null };
}

// ---------------------------------------------------------------- fuzzy lookup

const FAMILY: Record<string, string[]> = {
  mum: ["mum", "mom", "mother", "mummy", "ammi", "amma", "mama", "maa"],
  dad: ["dad", "father", "daddy", "abbu", "abba", "papa", "baba"],
  wife: ["wife", "wifey", "hubby"],
  bro: ["bro", "brother", "bhai"],
  sis: ["sis", "sister", "behen"],
};

function aliases(word: string): string[] {
  for (const list of Object.values(FAMILY)) if (list.includes(word)) return list;
  return [word];
}

function edits(a: string, b: string): number {
  if (a === b) return 0;
  if (Math.abs(a.length - b.length) > 2) return 3;
  const prev = Array.from({ length: b.length + 1 }, (_, i) => i);
  for (let i = 1; i <= a.length; i++) {
    let diag = prev[0]!;
    prev[0] = i;
    for (let j = 1; j <= b.length; j++) {
      const up = prev[j]!;
      prev[j] = Math.min(prev[j]! + 1, prev[j - 1]! + 1, diag + (a[i - 1] === b[j - 1] ? 0 : 1));
      diag = up;
    }
  }
  return prev[b.length]!;
}

/** How well a stored name answers what Sir said. 0 means no match. */
export function scoreName(query: string, name: string): number {
  const q = nameKey(query).replace(/^(?:my|our)\s+/, "");
  const n = nameKey(name);
  if (!q || !n) return 0;
  if (q === n) return 100;
  const qWords = q.split(" ");
  const nWords = n.split(" ");
  if (qWords.length === 1) {
    const word = qWords[0]!;
    const forms = aliases(word);
    if (nWords.some((w) => forms.includes(w))) return nWords[0] === word ? 92 : forms.includes(nWords[0]!) ? 90 : 85;
    if (nWords[0]!.startsWith(word) && word.length >= 3) return 75;
    if (nWords.some((w) => w.startsWith(word)) && word.length >= 3) return 65;
    if (word.length >= 4 && nWords.some((w) => edits(w, word) <= (word.length >= 6 ? 2 : 1))) return 55;
    return 0;
  }
  if (n.startsWith(q)) return 88;
  const hit = qWords.filter((w) => nWords.some((x) => x === w || aliases(w).includes(x) || (w.length >= 4 && edits(x, w) <= 1))).length;
  if (hit === qWords.length) return 80;
  if (hit > 0 && hit >= qWords.length - 1) return 50;
  return 0;
}

/** The best matches for a spoken or texted name, one row per person and number, best first. */
export async function findContacts(env: Env, query: string, limit = 3): Promise<ContactMatch[]> {
  const q = nameKey(query);
  if (!q) return [];
  await ensureContactsTable(env);
  const rows = await dbAll<ContactRow>(env, "SELECT name, phone, label FROM owner_contacts LIMIT ?", [MAX_ROWS]).catch(() => []);
  const scored = rows
    .map((r) => ({ ...r, score: scoreName(q, r.name) }))
    .filter((r) => r.score > 0)
    .sort((a, b) => b.score - a.score || labelRank(a.label) - labelRank(b.label) || a.name.localeCompare(b.name));
  if (!scored.length) return [];
  const top = scored[0]!.score;
  // A clearly better match stands alone; close scores are offered as options.
  const close = scored.filter((r) => r.score >= top - 5);
  const out: ContactMatch[] = [];
  const seen = new Set<string>();
  for (const r of close) {
    const key = `${nameKey(r.name)}|${r.phone}`;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(r);
    if (out.length >= limit) break;
  }
  return out;
}

function labelRank(label: string): number {
  if (/mobile|iphone|cell/.test(label)) return 0;
  if (!label) return 1;
  if (/home/.test(label)) return 2;
  return 3;
}

/** One resolved person, or a short list to choose from. People with one number count once. */
export type ContactResolution =
  | { kind: "none" }
  | { kind: "one"; contact: ContactMatch }
  | { kind: "many"; options: ContactMatch[] };

export async function resolveContact(env: Env, query: string): Promise<ContactResolution> {
  const found = await findContacts(env, query, 3);
  if (!found.length) return { kind: "none" };
  if (found.length === 1) return { kind: "one", contact: found[0]! };
  const people = new Set(found.map((f) => nameKey(f.name)));
  // Same person, several numbers: take the mobile.
  if (people.size === 1) return { kind: "one", contact: found[0]! };
  return { kind: "many", options: found };
}

export function maskPhone(e164: string): string {
  return e164.replace(/^\+44(\d{4})(\d{3})(\d{3})$/, "0$1 $2 $3");
}

/** "1) Ali Khan 07700 900123 2) ..." for an SMS that asks Sir to pick. */
export function optionsLine(options: ContactMatch[]): string {
  return options.map((o, i) => `${i + 1}) ${o.name}${o.label ? ` (${o.label})` : ""} ${maskPhone(o.phone)}`).join(" ");
}

// ---------------------------------------------------------------- routes (app token only)

export async function contactsRoute(request: Request, env: Env, path: string): Promise<Response | null> {
  if (path === "/contacts/sync" && request.method === "POST") {
    const body = await readJson(request);
    if (!body.ok) return body.response;
    const rows = await parseUpload(body.value);
    if (!rows.length) return apiError(400, "bad_request", "No contacts with a usable phone number.");
    const stored = await replaceContacts(env, rows);
    const status = await contactsStatus(env);
    console.log("contacts synced", JSON.stringify({ numbers: stored, people: status.people }));
    return json({ ok: true, stored, people: status.people, synced_at: status.synced_at });
  }
  if (path === "/contacts/status" && request.method === "GET") return json({ ok: true, ...(await contactsStatus(env)) });
  if (path === "/contacts/lookup" && request.method === "POST") {
    const body = await readJson(request);
    if (!body.ok) return body.response;
    const q = isRecord(body.value) ? asString(body.value.name, 80) ?? "" : "";
    if (!q) return apiError(400, "bad_request", "name is required.");
    return json({ ok: true, matches: await findContacts(env, q, 3) });
  }
  return null;
}
