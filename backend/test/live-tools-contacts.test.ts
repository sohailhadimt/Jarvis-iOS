// @ts-nocheck -- uses the Node SQLite helper.
import { afterEach, describe, expect, it, vi } from "vitest";
import { currentFactAsk, forecastDays, liveSearch, resetLiveSearchState, stripCitations, weatherAsk } from "../src/live-tools";
import { findContacts, parseUpload, replaceContacts, resolveContact, resetContactsReady, scoreName } from "../src/contacts";
import { numberAsk } from "../src/sms-extras";
import { route } from "../src/routes";
import { sqliteD1 } from "./helpers/sqlite-d1";

afterEach(() => {
  vi.unstubAllGlobals();
  resetLiveSearchState();
  resetContactsReady();
});

describe("weather asks", () => {
  it("pulls the place and the day out of a text", () => {
    expect(weatherAsk("weather in Ashford tomorrow")).toEqual({ place: "Ashford", when: "tomorrow" });
    expect(weatherAsk("What's the weather like in Paris this weekend?")).toEqual({ place: "Paris", when: "this weekend" });
    expect(weatherAsk("Manchester forecast")).toEqual({ place: "Manchester", when: "" });
    expect(weatherAsk("will it rain tomorrow")).toEqual({ place: "", when: "tomorrow" });
    expect(weatherAsk("remind me to check the weather at 6")).toBeNull();
    expect(weatherAsk("how was your day")).toBeNull();
  });

  it("maps days onto the forecast", () => {
    const mon = new Date("2026-11-16T12:00:00Z");
    expect(forecastDays("tomorrow", mon)).toEqual({ start: 1, count: 1, label: "tomorrow" });
    expect(forecastDays("friday", mon).start).toBe(4);
    expect(forecastDays("this weekend", mon)).toEqual({ start: 5, count: 2, label: "this weekend" });
  });
});

describe("live search", () => {
  it("uses Gemini grounding first, then Groq browser search when grounding has no quota", async () => {
    const calls = [];
    vi.stubGlobal("fetch", async (input, init) => {
      const url = String(input);
      calls.push(url);
      if (url.includes("generativelanguage")) return new Response("{}", { status: 429 });
      if (url.includes("api.groq.com")) {
        const body = JSON.parse(String(init.body));
        expect(body.tools).toEqual([{ type: "browser_search" }]);
        return Response.json({ choices: [{ message: { content: "Lando Norris won the São Paulo Grand Prix on 8 November 2026【1†L9-L15】." } }] });
      }
      return new Response("no", { status: 500 });
    });
    const env = { GEMINI_API_KEY: "g", GROQ_API_KEY: "q" };
    const got = await liveSearch(env, "who won the F1 last race");
    expect(got.ok).toBe(true);
    expect(got.provider).toBe("groq");
    expect(got.answer).toBe("Lando Norris won the São Paulo Grand Prix on 8 November 2026.");
    // A 429 parks grounding for a while: the next search goes straight to Groq.
    calls.length = 0;
    await liveSearch(env, "Dominos Ashford number");
    expect(calls.some((u) => u.includes("generativelanguage"))).toBe(false);
  });

  it("takes a grounded Gemini answer when it works", async () => {
    vi.stubGlobal("fetch", async (input) => {
      if (String(input).includes("generativelanguage")) {
        return Response.json({ candidates: [{ content: { parts: [{ text: "Domino's Ashford is on 01233 500008 [1]." }] }, groundingMetadata: { groundingChunks: [{ web: { title: "dominos.co.uk" } }] } }] });
      }
      return new Response("no", { status: 500 });
    });
    const got = await liveSearch({ GEMINI_API_KEY: "g" }, "Dominos Ashford number");
    expect(got).toMatchObject({ ok: true, provider: "gemini", answer: "Domino's Ashford is on 01233 500008.", sources: ["dominos.co.uk"] });
  });

  it("knows a current-facts question from chat", () => {
    expect(currentFactAsk("who won the F1 last race")).toBe(true);
    expect(currentFactAsk("latest Arsenal score")).toBe(true);
    expect(currentFactAsk("how are you")).toBe(false);
    expect(currentFactAsk("what's the latest on my call")).toBe(false);
    expect(stripCitations("**Yes** it is【3†L4】 [2].")).toBe("Yes it is.");
  });
});

describe("contacts", () => {
  const upload = {
    contacts: [
      { name: "Ali Khan", phones: [{ number: "07700 900111", label: "_$!<Mobile>!$_" }, { number: "01233 000111", label: "home" }] },
      { name: "Ali Raza", phones: [{ number: "+44 7700 900222", label: "mobile" }] },
      { name: "Mum", phones: [{ number: "07700900333", label: "iPhone" }] },
      { name: "Bilal", phones: [{ number: "not a number" }] },
      { name: "", phones: ["07700900444"] },
    ],
  };

  it("keeps only names with usable numbers, normalised to E.164", async () => {
    const rows = await parseUpload(upload);
    expect(rows.map((r) => r.phone)).toEqual(["+447700900111", "+441233000111", "+447700900222", "+447700900333"]);
    expect(rows[0].label).toBe("mobile");
  });

  it("scores names fuzzily, including relations", () => {
    expect(scoreName("Ali", "Ali Khan")).toBeGreaterThan(80);
    expect(scoreName("mum", "Mum")).toBe(100);
    expect(scoreName("my mum", "Mum")).toBe(100);
    expect(scoreName("mom", "Mum")).toBeGreaterThan(80);
    expect(scoreName("Alli Khan", "Ali Khan")).toBeGreaterThan(0);
    expect(scoreName("Zed", "Ali Khan")).toBe(0);
  });

  it("returns up to three options for an ambiguous name and one person for a clear one", async () => {
    const { db } = sqliteD1();
    const env = { DB: db };
    await replaceContacts(env, await parseUpload(upload));
    const ali = await resolveContact(env, "Ali");
    expect(ali.kind).toBe("many");
    expect(ali.options.length).toBeLessThanOrEqual(3);
    expect(ali.options.map((o) => o.name)).toContain("Ali Raza");
    const khan = await resolveContact(env, "Ali Khan");
    expect(khan.kind).toBe("one");
    expect(khan.contact.phone).toBe("+447700900111"); // mobile before home
    const mum = await resolveContact(env, "mum");
    expect(mum).toMatchObject({ kind: "one", contact: { name: "Mum" } });
    expect((await findContacts(env, "Nobody")).length).toBe(0);
  });

  it("sync and lookup need the app token", async () => {
    const { db } = sqliteD1();
    const env = { DB: db, JARVIS_APP_TOKEN: "secret-token" };
    const ctx = { waitUntil() {}, passThroughOnException() {}, props: {} };
    const sync = (auth) =>
      route(
        new Request("https://jarvis-backend.jarvis-hadi.workers.dev/contacts/sync", {
          method: "POST",
          headers: { "content-type": "application/json", ...(auth ? { authorization: `Bearer ${auth}` } : {}) },
          body: JSON.stringify(upload),
        }),
        env,
        ctx,
      );
    expect((await sync(null)).status).toBe(401);
    const ok = await sync("secret-token");
    expect(ok.status).toBe(200);
    expect(await ok.json()).toMatchObject({ ok: true, stored: 4, people: 3 });
  });

  it("spots a number request", () => {
    expect(numberAsk("what's Mum's number")).toBe("Mum");
    expect(numberAsk("Dominos Ashford number")).toBe("Dominos Ashford");
    expect(numberAsk("number for Ali")).toBe("Ali");
    expect(numberAsk("what's my number")).toBeNull();
    expect(numberAsk("call 07700900111 and ask")).toBeNull();
  });
});
