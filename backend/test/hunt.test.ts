import { afterEach, describe, expect, it } from "vitest";
import { outboundOpening } from "../src/calls";
import { londonMinutes } from "../src/owner-alert";
import {
  approveRecommended,
  beginHunt,
  bookBrief,
  businessQuiet,
  comparisonMessage,
  confirmDraftHunt,
  createHunt,
  editDraftHunt,
  noteQuote,
  quoteBrief,
  recommendQuote,
  resetHuntClock,
  setHuntClock,
  sweepHunts,
  targetsFromText,
} from "../src/hunt";
import { handleInboundSms, wantsHunt } from "../src/sms-desk";
import { route } from "../src/routes";
import type { Env } from "../src/types";

const OPEN = new Date("2026-10-21T10:00:00.000Z");
const AT_2100 = new Date("2026-10-21T20:00:00.000Z");
const AT_2059 = new Date("2026-10-21T19:59:00.000Z");
const AT_0800 = new Date("2026-10-21T07:00:00.000Z");
const AT_0759 = new Date("2026-10-21T06:59:00.000Z");

describe("shop around", () => {
  afterEach(() => {
    resetHuntClock();
  });

  it("speaks as J.A.R.V.I.S. for Sohail and only cites a real offer", () => {
    const first = outboundOpening(quoteBrief("a boiler service", null));
    expect(first).toContain("Hello, this is J.A.R.V.I.S., calling on behalf of Sohail.");
    expect(first).toContain("I'm calling to ask:");
    expect(first.toLowerCase()).toContain("sohail will confirm");
    expect(first.toLowerCase()).toContain("do not invent");
    expect(first).not.toContain("£");
    expect(first.toLowerCase()).not.toContain("who's calling");

    const second = outboundOpening(
      quoteBrief("a boiler service", {
        business: "Acme",
        price: "£80",
        availability: "Tuesday at 2pm",
        terms: "cash on the day",
      }),
    );
    expect(second).toContain("£80");
    expect(second).toContain("Acme");
    expect(second).toContain("Tuesday at 2pm");
    expect(second).toContain("cash on the day");
    expect(second).not.toContain("£9999");
    expect(second.toLowerCase()).toContain("do not invent any other offer");

    const booking = outboundOpening(bookBrief("Acme", "Tuesday at 2pm"));
    expect(booking).toContain("J.A.R.V.I.S.");
    expect(booking).toContain("Sohail");
    expect(booking.toLowerCase()).toContain("make a booking");
    expect(booking.toLowerCase()).not.toContain("master hadi");
    expect(booking.toLowerCase()).toContain("do not take a card");
  });

  it("keeps business hours closed from 21:00 until 08:00 London", () => {
    expect(businessQuiet(21 * 60)).toBe(true);
    expect(businessQuiet(8 * 60)).toBe(false);
    expect(businessQuiet(8 * 60 - 1)).toBe(true);
    expect(businessQuiet(21 * 60 - 1)).toBe(false);
    expect(londonMinutes(AT_2100)).toBe(21 * 60);
    expect(londonMinutes(AT_0800)).toBe(8 * 60);
    expect(londonMinutes(AT_0759)).toBe(8 * 60 - 1);
    expect(londonMinutes(AT_2059)).toBe(21 * 60 - 1);
    expect(businessQuiet(londonMinutes(OPEN))).toBe(false);
  });

  it("names providers from the message and stops at five", () => {
    const targets = targetsFromText(
      "get me quotes from Acme Heating 07700 900201 and Beta 07700 900202 07700 900203 07700 900204 07700 900205 07700 900206 999",
    );
    expect(targets).toHaveLength(5);
    expect(targets[0]).toMatchObject({ business: "Acme Heating", phone: "+447700900201" });
    expect(targets[1]?.business).toBe("Beta");
    expect(targets.map((target) => target.phone)).not.toContain("+44999");
  });

  it("recommends the lowest real price", () => {
    const id = recommendQuote([
      { id: "high", status: "quoted", price: "£120" },
      { id: "low", status: "quoted", price: "£80" },
      { id: "wait", status: "pending", price: "£10" },
    ]);
    expect(id).toBe("low");
    const message = comparisonMessage(
      "a boiler service",
      [
        { id: "low", business: "Acme", price: "£80", availability: "Tuesday at 2pm", terms: "cash on the day", summary: "Can do the boiler.", status: "quoted" },
        { id: "high", business: "Beta", price: "£120", availability: "tomorrow", terms: "bank transfer", summary: "Needs a morning.", status: "quoted" },
      ],
      "low",
    );
    expect(message).toContain("£80");
    expect(message).toContain("£120");
    expect(message).toContain("Tuesday at 2pm");
    expect(message).toContain("Terms: cash on the day");
    expect(message).toContain("Terms: bank transfer");
    expect(message).toContain("Recommended: Acme at £80");
    expect(message).toContain("APPROVE");
    expect(message).not.toContain("£9999");
  });

  it("stores a draft and rings one provider at a time", async () => {
    const calls: string[] = [];
    const texts: string[] = [];
    const env = shopEnv();
    const restore = mockFetch(calls, texts);
    setHuntClock(() => OPEN);
    try {
      const created = await createHunt(env, "a boiler service", [
        { business: "Acme", phone: "+447700900201" },
        { business: "Beta", phone: "+447700900202" },
      ]);
      expect(created.id).toMatch(/^hunt_/);
      expect(created.message).toContain("Acme");
      expect(created.message).toContain("YES");
      expect(calls).toHaveLength(0);

      const started = await beginHunt(env, created.id);
      expect(started.dialed).toBe(true);
      expect(calls).toHaveLength(1);
      expect(new URLSearchParams(calls[0]).get("To")).toBe("+447700900201");
      expect(new URLSearchParams(calls[0]).get("Url") ?? "").not.toContain("/calls/inbound");

      const first = await quotes(env);
      expect(first.map((quote) => quote.status).sort()).toEqual(["calling", "pending"]);
      const live = first.find((quote) => quote.status === "calling");
      expect(live?.business).toBe("Acme");
      const briefs = await column(env, "outbound_calls", "brief");
      expect(briefs[0]).toContain("no competing offer");
      expect(briefs[0]).not.toContain("£80");

      await finishCall(env, live?.call_id ?? "", "The price is £80. We can come Tuesday at 2pm. The call-out fee is £20. Terms are cash on the day.");
      await noteQuote(env, live?.call_id ?? "");
      expect(calls).toHaveLength(2);
      expect(new URLSearchParams(calls[1]).get("To")).toBe("+447700900202");
      const secondBrief = (await column(env, "outbound_calls", "brief")).at(-1) ?? "";
      expect(secondBrief).toContain("£80");
      expect(secondBrief).toContain("Acme");
      expect(secondBrief).toContain("cash on the day");
      expect(secondBrief).not.toContain("£9999");

      const beta = (await quotes(env)).find((quote) => quote.business === "Beta");
      await finishCall(env, beta?.call_id ?? "", "The price is £120. We can come tomorrow. Terms are bank transfer.");
      await noteQuote(env, beta?.call_id ?? "");
      expect(calls).toHaveLength(2);
      const compared = texts.join("\n");
      expect(compared).toContain("£80");
      expect(compared).toContain("£120");
      expect(compared).toContain("Tuesday");
      expect(compared).toContain("Terms: cash on the day");
      expect(compared).toContain("Recommended: Acme at £80");
      expect(compared).toContain("APPROVE");

      const acme = (await quotes(env)).find((quote) => quote.business === "Acme");
      const response = await route(
        new Request(`http://internal.local/calls/hunts/${created.id}/choose`, {
          method: "POST",
          headers: { authorization: "Bearer secret-token", "content-type": "application/json" },
          body: JSON.stringify({ quote_id: acme?.id }),
        }),
        env,
        ctx(),
      );
      expect(response.status).toBe(200);
      const body = (await response.json()) as { message: string; paid: boolean; external_action_taken: boolean };
      expect(body.paid).toBe(false);
      expect(body.external_action_taken).toBe(true);
      expect(body.message).toContain("Nothing is paid");
      expect(calls).toHaveLength(3);
      const hunt = await one(env, "SELECT status FROM call_hunts WHERE id = ?", created.id);
      expect(hunt?.status).toBe("booking");
      const bookingBrief = (await column(env, "outbound_calls", "brief")).at(-1) ?? "";
      expect(bookingBrief.toLowerCase()).toContain("make a booking");
      expect(bookingBrief).toContain("Sohail");
      expect(bookingBrief.toLowerCase()).not.toContain("master hadi");

      const booked = (await quotes(env)).find((quote) => quote.business === "Acme");
      await finishCall(env, booked?.book_call_id ?? "", "Tuesday at 9 is held for Sohail.");
      await noteQuote(env, booked?.book_call_id ?? "");
      const done = await one(env, "SELECT status FROM call_hunts WHERE id = ?", created.id);
      expect(done?.status).toBe("booked");
      expect(texts.join("\n")).toContain("is held");
      expect(texts.join("\n")).toContain("Nothing was paid");
      expect(calls).toHaveLength(3);
    } finally {
      restore();
    }
  });

  it("does not dial a draft until YES, and a text can replace the list", async () => {
    const calls: string[] = [];
    const texts: string[] = [];
    const env = shopEnv();
    const restore = mockFetch(calls, texts);
    setHuntClock(() => OPEN);
    try {
      await handleInboundSms(env, "+447700900999", "get me quotes from Acme 07700 900201 and Beta 07700 900202");
      expect(wantsHunt("get me quotes from Acme 07700 900201 and Beta 07700 900202")).toBe(true);
      expect(calls).toHaveLength(0);
      expect(texts.join("\n")).toContain("Acme");
      expect(texts.join("\n")).toContain("YES");
      await handleInboundSms(env, "+447700900999", "07700 900203");
      expect(calls).toHaveLength(0);
      expect(texts.join("\n")).toContain("07700 900203");
      await handleInboundSms(env, "+447700900999", "YES");
      expect(calls).toHaveLength(1);
      expect(new URLSearchParams(calls[0]).get("To")).toBe("+447700900203");
    } finally {
      restore();
    }
  });

  it("holds calls outside business hours and places the next one at 08:00", async () => {
    const calls: string[] = [];
    const env = shopEnv();
    const restore = mockFetch(calls, []);
    try {
      setHuntClock(() => AT_2100);
      const created = await createHunt(env, "a boiler service", [{ business: "Acme", phone: "+447700900201" }]);
      const started = await beginHunt(env, created.id);
      expect(started.dialed).toBe(false);
      expect(started.message).toContain("08:00");
      expect(calls).toHaveLength(0);
      const queued = await one(env, "SELECT status FROM call_hunts WHERE id = ?", created.id);
      expect(queued?.status).toBe("queued");

      setHuntClock(() => AT_0759);
      await sweepHunts(env);
      expect(calls).toHaveLength(0);

      setHuntClock(() => AT_0800);
      await sweepHunts(env);
      expect(calls).toHaveLength(1);
      expect(new URLSearchParams(calls[0]).get("To")).toBe("+447700900201");
    } finally {
      restore();
    }
  });

  it("stops at ten shop calls in a London day and five in one job", async () => {
    const calls: string[] = [];
    const env = shopEnv();
    const restore = mockFetch(calls, []);
    setHuntClock(() => OPEN);
    try {
      await env.DB.prepare("INSERT INTO runtime_state (key, value, updated_at) VALUES (?, ?, ?)").bind("hunt_dials_2026-10-21", "10", OPEN.toISOString()).run();
      const capped = await createHunt(env, "a boiler service", [{ business: "Acme", phone: "+447700900201" }]);
      const started = await beginHunt(env, capped.id);
      expect(started.dialed).toBe(false);
      expect(started.message).toContain("10");
      expect(calls).toHaveLength(0);
      await env.DB.prepare("UPDATE call_hunts SET status = ? WHERE id = ?").bind("cancelled", capped.id).run();
      await env.DB.prepare("UPDATE runtime_state SET value = ? WHERE key = ?").bind("0", "hunt_dials_2026-10-21").run();

      const now = OPEN.toISOString();
      await env.DB.prepare("INSERT INTO call_hunts (id, goal, status, created_at, updated_at) VALUES (?, ?, 'calling', ?, ?)").bind("hunt_job", "job cap", now, now).run();
      for (let index = 0; index < 5; index += 1) {
        await env.DB.prepare(
          `INSERT INTO call_quotes
            (id, hunt_id, call_id, business, phone, price, availability, fees, terms, summary, status, book_call_id, created_at)
           VALUES (?, ?, ?, ?, ?, '£10', NULL, NULL, NULL, '', 'quoted', NULL, ?)`,
        )
          .bind(`quote_done_${index}`, "hunt_job", `call_done_${index}`, `Done ${index}`, `+44770090021${index}`, now)
          .run();
      }
      await env.DB.prepare(
        `INSERT INTO call_quotes
          (id, hunt_id, call_id, business, phone, price, availability, fees, terms, summary, status, book_call_id, created_at)
         VALUES (?, ?, NULL, ?, ?, NULL, NULL, NULL, NULL, '', 'pending', NULL, ?)`,
      )
        .bind("quote_sixth", "hunt_job", "Sixth", "+447700900250", now)
        .run();
      await sweepHunts(env);
      expect(calls).toHaveLength(0);
      const sixth = await one(env, "SELECT status FROM call_quotes WHERE id = ?", "quote_sixth");
      expect(sixth?.status).toBe("skipped");
    } finally {
      restore();
    }
  });

  it("will not start a second shop call while one is already on the line", async () => {
    const calls: string[] = [];
    const env = shopEnv();
    const restore = mockFetch(calls, []);
    setHuntClock(() => AT_2059);
    try {
      expect(businessQuiet(londonMinutes(AT_2059))).toBe(false);
      const now = OPEN.toISOString();
      await env.DB.prepare("INSERT INTO call_hunts (id, goal, status, created_at, updated_at) VALUES (?, ?, 'calling', ?, ?)").bind("hunt_live", "live", now, now).run();
      await env.DB.prepare(
        `INSERT INTO call_quotes
          (id, hunt_id, call_id, business, phone, price, availability, fees, terms, summary, status, book_call_id, created_at)
         VALUES (?, ?, ?, ?, ?, NULL, NULL, NULL, NULL, '', 'calling', NULL, ?)`,
      )
        .bind("quote_live", "hunt_live", "call_live", "Live", "+447700900201", now)
        .run();
      await env.DB.prepare("INSERT INTO call_hunts (id, goal, status, created_at, updated_at) VALUES (?, ?, 'calling', ?, ?)").bind("hunt_wait", "wait", now, now).run();
      await env.DB.prepare(
        `INSERT INTO call_quotes
          (id, hunt_id, call_id, business, phone, price, availability, fees, terms, summary, status, book_call_id, created_at)
         VALUES (?, ?, NULL, ?, ?, NULL, NULL, NULL, NULL, '', 'pending', NULL, ?)`,
      )
        .bind("quote_wait", "hunt_wait", "Wait", "+447700900202", now)
        .run();
      await sweepHunts(env);
      expect(calls).toHaveLength(0);
      const waiting = await one(env, "SELECT status FROM call_quotes WHERE id = ?", "quote_wait");
      expect(waiting?.status).toBe("pending");
    } finally {
      restore();
    }
  });

  it("refuses to book a quote that asked for payment", async () => {
    const calls: string[] = [];
    const env = shopEnv();
    const restore = mockFetch(calls, []);
    setHuntClock(() => OPEN);
    try {
      const created = await createHunt(env, "a boiler service", [{ business: "Acme", phone: "+447700900201" }]);
      await beginHunt(env, created.id);
      const quote = (await quotes(env))[0];
      await finishCall(env, quote?.call_id ?? "", "Please pay by card now. The price is £50.");
      await noteQuote(env, quote?.call_id ?? "");
      expect(calls).toHaveLength(1);
      const line = await approveRecommended(env);
      expect(line?.toLowerCase()).toContain("payment");
      expect(calls).toHaveLength(1);
      const hunt = await one(env, "SELECT status FROM call_hunts WHERE id = ?", created.id);
      expect(hunt?.status).not.toBe("booked");
    } finally {
      restore();
    }
  });

  it("exposes the draft on the hunt route before any call", async () => {
    const calls: string[] = [];
    const env = shopEnv();
    const restore = mockFetch(calls, []);
    setHuntClock(() => OPEN);
    try {
      const response = await route(
        new Request("http://internal.local/calls/hunts", {
          method: "POST",
          headers: { authorization: "Bearer secret-token", "content-type": "application/json" },
          body: JSON.stringify({ goal: "a boiler service", providers: [{ business: "Acme", phone: "07700 900201" }] }),
        }),
        env,
        ctx(),
      );
      expect(response.status).toBe(200);
      const created = (await response.json()) as { hunt_id: string; external_action_taken: boolean; message: string };
      expect(created.external_action_taken).toBe(false);
      expect(created.message).toContain("Acme");
      expect(calls).toHaveLength(0);
      const listed = await route(
        new Request("http://internal.local/calls/hunts", { headers: { authorization: "Bearer secret-token" } }),
        env,
        ctx(),
      );
      const body = (await listed.json()) as { hunts: { status: string; quotes: { business: string; transcript: unknown[] }[] }[] };
      expect(body.hunts[0]?.status).toBe("draft");
      expect(body.hunts[0]?.quotes[0]?.business).toBe("Acme");
      expect(body.hunts[0]?.quotes[0]?.transcript).toEqual([]);
      const started = await confirmDraftHunt(env);
      expect(started?.dialed).toBe(true);
      expect(calls).toHaveLength(1);
      expect(await editDraftHunt(env, "07700 900204")).toBeNull();
    } finally {
      restore();
    }
  });
});

function ctx(): ExecutionContext {
  return { waitUntil() {}, passThroughOnException() {}, props: {} } as unknown as ExecutionContext;
}

function shopEnv(): Env {
  return {
    JARVIS_APP_TOKEN: "secret-token",
    OWNER_PHONE: "+447700900999",
    TWILIO_ACCOUNT_SID: "AC123",
    TWILIO_AUTH_TOKEN: "twilio-token",
    TWILIO_FROM_NUMBER: "+447700900000",
    DB: memoryDatabase() as unknown as D1Database,
  };
}

function mockFetch(calls: string[], texts: string[]): () => void {
  const original = globalThis.fetch;
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    const method = init?.method ?? "GET";
    if (url.includes("api.twilio.com") && url.includes("/Calls.json") && method === "POST") {
      calls.push(String(init?.body ?? ""));
      return new Response(JSON.stringify({ sid: "CA1234567890abcdef1234567890abcd" }), { status: 201 });
    }
    if (url.includes("/Messages.json") && method === "POST") {
      texts.push(new URLSearchParams(String(init?.body ?? "")).get("Body") ?? "");
      return new Response(JSON.stringify({ sid: "SM123", status: "queued" }), { status: 201 });
    }
    return new Response("not found", { status: 404 });
  }) as typeof fetch;
  return () => {
    globalThis.fetch = original;
  };
}

async function quotes(env: Env): Promise<{ id: string; business: string; status: string; call_id: string | null; book_call_id: string | null; price: string | null }[]> {
  const result = await env.DB.prepare(
    "SELECT id, business, status, call_id, book_call_id, price FROM call_quotes ORDER BY created_at ASC",
  ).all();
  return (result.results ?? []) as {
    id: string;
    business: string;
    status: string;
    call_id: string | null;
    book_call_id: string | null;
    price: string | null;
  }[];
}

async function column(env: Env, table: string, name: string): Promise<string[]> {
  const result = await env.DB.prepare(`SELECT ${name} FROM ${table} ORDER BY created_at ASC`).all();
  return ((result.results ?? []) as Record<string, string | null>[]).map((row) => row[name] ?? "");
}

async function one(env: Env, sql: string, ...params: string[]): Promise<Record<string, string> | null> {
  let statement = env.DB.prepare(sql);
  if (params.length) statement = statement.bind(...params);
  return statement.first<Record<string, string>>();
}

async function finishCall(env: Env, callId: string, text: string): Promise<void> {
  await env.DB.prepare("UPDATE outbound_calls SET status = ?, summary = ?, transcript_json = ? WHERE id = ?")
    .bind("completed", text, JSON.stringify([{ role: "them", text }]), callId)
    .run();
}

type Val = string | number | null;
type Row = Record<string, Val>;

function memoryDatabase(): D1Database {
  const tables = new Map<string, Row[]>();
  const table = (name: string): Row[] => {
    const key = name.toLowerCase();
    let rows = tables.get(key);
    if (!rows) {
      rows = [];
      tables.set(key, rows);
    }
    return rows;
  };
  return {
    prepare(sql: string) {
      let bound: unknown[] = [];
      const statement = {
        bind(...args: unknown[]) {
          bound = args;
          return statement;
        },
        async first() {
          return query(sql, bound, table)[0] ?? null;
        },
        async all() {
          return { results: query(sql, bound, table), success: true, meta: {} };
        },
        async run() {
          mutate(sql, bound, table);
          return { success: true, meta: { changes: 1 } };
        },
      };
      return statement;
    },
  } as unknown as D1Database;
}

function query(sql: string, bound: unknown[], table: (name: string) => Row[]): Row[] {
  const flat = sql.replace(/\s+/g, " ").trim();
  const select = /^SELECT (.+) FROM (\w+)(?: WHERE (.+?))?(?: ORDER BY (\w+) (ASC|DESC))?(?: LIMIT (\d+))?$/i.exec(flat);
  if (!select) throw new Error(`unhandled sql: ${flat}`);
  const index = { i: 0 };
  const where = select[3] ? compileWhere(select[3], bound, index) : () => true;
  let rows = table(select[2] ?? "").filter(where);
  if (select[4]) {
    const columnName = select[4];
    const desc = (select[5] ?? "").toUpperCase() === "DESC";
    rows = [...rows].sort((left, right) => {
      const compared = String(left[columnName] ?? "").localeCompare(String(right[columnName] ?? ""));
      return desc ? -compared : compared;
    });
  }
  if (select[6]) rows = rows.slice(0, Number(select[6]));
  const list = (select[1] ?? "").trim();
  if (list === "*") return rows;
  return rows.map((row) => {
    const projected: Row = {};
    for (const part of splitArgs(list)) {
      const alias = /^(?:\w+\.)?(\w+)$/.exec(part);
      if (!alias?.[1]) continue;
      projected[alias[1]] = row[alias[1]] ?? null;
    }
    return projected;
  });
}

function mutate(sql: string, bound: unknown[], table: (name: string) => Row[]): void {
  const flat = sql.replace(/\s+/g, " ").trim();
  if (/^ALTER /i.test(flat)) return;
  const insert =
    /^INSERT INTO (\w+) \(([^)]+)\) VALUES \(([^)]+)\)(?: ON CONFLICT\((\w+)\) DO UPDATE SET (.+))?$/i.exec(flat);
  if (insert) {
    const cols = splitArgs(insert[2] ?? "");
    const raw = splitArgs(insert[3] ?? "");
    const index = { i: 0 };
    const row: Row = {};
    cols.forEach((col, position) => {
      row[col] = parseBound(raw[position] ?? "NULL", bound, index);
    });
    const rows = table(insert[1] ?? "");
    const conflict = insert[4];
    if (conflict) {
      const existing = rows.find((item) => String(item[conflict] ?? "") === String(row[conflict] ?? ""));
      if (existing) {
        for (const set of splitArgs(insert[5] ?? "")) {
          const match = /(\w+)\s*=\s*excluded\.(\w+)/i.exec(set);
          if (match?.[1] && match[2]) existing[match[1]] = row[match[2]] ?? null;
        }
        return;
      }
    }
    rows.push(row);
    return;
  }
  const update = /^UPDATE (\w+) SET (.+) WHERE (.+)$/i.exec(flat);
  if (update) {
    const index = { i: 0 };
    const changes: { col: string; val: Val }[] = [];
    for (const assign of splitArgs(update[2] ?? "")) {
      const match = /^(\w+)\s*=\s*(.+)$/.exec(assign);
      if (!match?.[1]) continue;
      changes.push({ col: match[1], val: parseBound(match[2] ?? "NULL", bound, index) });
    }
    const where = compileWhere(update[3] ?? "1 = 1", bound, index);
    for (const row of table(update[1] ?? "").filter(where)) {
      for (const change of changes) row[change.col] = change.val;
    }
    return;
  }
  const remove = /^DELETE FROM (\w+) WHERE (.+)$/i.exec(flat);
  if (remove) {
    const rows = table(remove[1] ?? "");
    const where = compileWhere(remove[2] ?? "", bound, { i: 0 });
    for (let cursor = rows.length - 1; cursor >= 0; cursor -= 1) {
      if (where(rows[cursor] ?? {})) rows.splice(cursor, 1);
    }
    return;
  }
  throw new Error(`unhandled sql: ${flat}`);
}

function compileWhere(where: string, bound: unknown[], index: { i: number }): (row: Row) => boolean {
  const checks: ((row: Row) => boolean)[] = [];
  for (const part of where.split(/\s+AND\s+/i)) {
    const member = /^(\w+)\s+IN\s*\((.+)\)$/i.exec(part.trim());
    if (member) {
      const items = splitArgs(member[2] ?? "").map((token) => String(parseBound(token, bound, index) ?? ""));
      const columnName = member[1] ?? "";
      checks.push((row) => items.includes(String(row[columnName] ?? "")));
      continue;
    }
    const present = /^(\w+)\s+IS\s+NOT\s+NULL$/i.exec(part.trim());
    if (present?.[1]) {
      const columnName = present[1];
      checks.push((row) => row[columnName] != null && row[columnName] !== "");
      continue;
    }
    const absent = /^(\w+)\s+IS\s+NULL$/i.exec(part.trim());
    if (absent?.[1]) {
      const columnName = absent[1];
      checks.push((row) => row[columnName] == null || row[columnName] === "");
      continue;
    }
    const eq = /^(\w+)\s*=\s*(.+)$/i.exec(part.trim());
    if (eq?.[1]) {
      const expected = String(parseBound(eq[2] ?? "NULL", bound, index) ?? "");
      const columnName = eq[1];
      checks.push((row) => String(row[columnName] ?? "") === expected);
      continue;
    }
    throw new Error(`unhandled where: ${part}`);
  }
  return (row) => checks.every((check) => check(row));
}

function parseBound(token: string, bound: unknown[], index: { i: number }): Val {
  const trimmed = token.trim();
  if (trimmed === "?") {
    const value = bound[index.i++];
    if (typeof value === "number") return value;
    if (value == null) return null;
    return String(value);
  }
  if (/^null$/i.test(trimmed)) return null;
  if ((trimmed.startsWith("'") && trimmed.endsWith("'")) || (trimmed.startsWith('"') && trimmed.endsWith('"'))) {
    return trimmed.slice(1, -1).replace(/''/g, "'");
  }
  if (/^-?\d+(?:\.\d+)?$/.test(trimmed)) return Number(trimmed);
  return trimmed;
}

function splitArgs(input: string): string[] {
  const out: string[] = [];
  let current = "";
  let quote = "";
  for (const char of input) {
    if (quote) {
      current += char;
      if (char === quote) quote = "";
      continue;
    }
    if (char === "'" || char === '"') {
      quote = char;
      current += char;
      continue;
    }
    if (char === ",") {
      out.push(current.trim());
      current = "";
      continue;
    }
    current += char;
  }
  if (current.trim()) out.push(current.trim());
  return out;
}
