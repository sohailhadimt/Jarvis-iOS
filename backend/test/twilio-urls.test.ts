// @ts-nocheck -- reads source files with Node built-ins.
import { readFileSync, readdirSync } from "node:fs";
import { afterEach, describe, expect, it, vi } from "vitest";
import { placeOutboundCall, outboundForm } from "../src/calls";
import { readCallSettings, rememberOrigin } from "../src/owner-alert";
import {
  PUBLIC_BASE_URL,
  createTwilioCall,
  formUrls,
  invalidFormUrl,
  isValidTwilioUrl,
  normaliseOrigin,
  publicBase,
  twilioUrl,
} from "../src/public-url";
import { callAndPlay } from "../src/voice-notes";
import { dialFailure } from "../src/sms-desk";
import { sqliteD1 } from "./helpers/sqlite-d1";

const SID = "CA0123456789abcdef0123456789abcdef";

function baseEnv(extra = {}) {
  const { db, raw } = sqliteD1();
  const env = {
    DB: db,
    TWILIO_ACCOUNT_SID: "ACtest",
    TWILIO_AUTH_TOKEN: "token",
    TWILIO_FROM_NUMBER: "+447700900001",
    ...extra,
  };
  return { env, raw };
}

/** Captures every Calls.json form and fails the test if any URL in it is not valid for Twilio. */
function twilioStub(replies: Array<{ status: number; body: unknown }> = []) {
  const forms: URLSearchParams[] = [];
  const fetcher = vi.fn(async (url: string, init?: RequestInit) => {
    if (String(url).includes("/Calls.json")) {
      const form = new URLSearchParams(String(init?.body ?? ""));
      forms.push(form);
      for (const u of formUrls(form)) expect(isValidTwilioUrl(u), `invalid Twilio URL ${u}`).toBe(true);
      const next = replies.shift() ?? { status: 201, body: { sid: SID } };
      return new Response(JSON.stringify(next.body), { status: next.status });
    }
    return new Response("{}", { status: 200 });
  });
  vi.stubGlobal("fetch", fetcher);
  return { forms, fetcher };
}

afterEach(() => vi.unstubAllGlobals());

describe("public callback URLs", () => {
  it("rejects internal and malformed origins, including the lane origin that caused 21205", () => {
    for (const bad of ["https://jarvis-lane", "https:", "https://", "", "http://localhost:8787", "https://127.0.0.1", "jarvis-backend", "https://user:pw@x.dev"]) {
      expect(normaliseOrigin(bad), bad).toBe("");
    }
    expect(normaliseOrigin("http://jarvis-backend.jarvis-hadi.workers.dev/")).toBe(PUBLIC_BASE_URL);
    expect(publicBase({}, "https://jarvis-lane")).toBe(PUBLIC_BASE_URL);
    expect(publicBase({ PUBLIC_BASE_URL: "https://jarvis-lane" })).toBe(PUBLIC_BASE_URL);
  });

  it("builds encoded, absolute https URLs and refuses a bad base", () => {
    const url = twilioUrl(PUBLIC_BASE_URL, "/calls/voice/call_1", { mode: "relay & go" });
    expect(url).toBe(`${PUBLIC_BASE_URL}/calls/voice/call_1?mode=relay+%26+go`);
    expect(() => twilioUrl("https://jarvis-lane", "/x")).toThrow();
    expect(() => twilioUrl("https:", "/x")).toThrow();
  });

  it("finds URLs inside inline TwiML so a broken Play or Gather action is caught before sending", () => {
    const form = new URLSearchParams({ Twiml: `<Response><Gather action="https://jarvis-lane/a"/><Play>https://x.example.com/v/a.mp3</Play></Response>` });
    expect(formUrls(form)).toEqual(["https://jarvis-lane/a", "https://x.example.com/v/a.mp3"]);
    expect(invalidFormUrl(form)).not.toBe("");
  });

  it("never saves the lane origin, and reading settings always yields a public base", async () => {
    const { env, raw } = baseEnv();
    await rememberOrigin(env, "https://jarvis-lane");
    expect(raw.prepare("SELECT worker_origin FROM call_settings").all()).toEqual([]);
    raw.prepare("INSERT INTO call_settings (id, mobile_number, worker_origin, updated_at) VALUES ('default', '', 'https://jarvis-lane', '')").run();
    expect((await readCallSettings(env)).worker_origin).toBe(PUBLIC_BASE_URL);
  });
});

describe("every outbound call path sends valid Twilio URLs", () => {
  it("ring X and ask Y / call-back: survives a poisoned saved origin", async () => {
    const { env, raw } = baseEnv();
    raw.prepare("INSERT INTO call_settings (id, mobile_number, worker_origin, updated_at) VALUES ('default', '', 'https://jarvis-lane', '')").run();
    const { forms } = twilioStub();
    const placed = await placeOutboundCall(env, { contact: "Shop", to: "07700 900123", brief: "Ask what time they open tomorrow." });
    expect(placed.ok).toBe(true);
    expect(forms).toHaveLength(1);
    expect(forms[0].get("Url")).toMatch(new RegExp(`^${PUBLIC_BASE_URL}/calls/voice/call_`));
    expect(forms[0].get("StatusCallback")).toMatch(new RegExp(`^${PUBLIC_BASE_URL}/calls/twilio-status/call_`));
  });

  it("retries once on the fixed base when Twilio answers 21205", async () => {
    const { env } = baseEnv({ PUBLIC_BASE_URL: "https://old-host.example.com" });
    const { forms } = twilioStub([{ status: 400, body: { code: 21205, message: "Url is not a valid URL: https://old-host.example.com/calls/voice/x" } }]);
    const placed = await placeOutboundCall(env, { contact: "them", to: "+447700900123", brief: "Ask if they deliver." });
    expect(placed.ok).toBe(true);
    expect(forms).toHaveLength(2);
    expect(forms[0].get("Url")).toContain("old-host.example.com");
    expect(forms[1].get("Url")).toContain(PUBLIC_BASE_URL);
  });

  it("does not retry on a non-URL error, and the text to Sir has no codes or URLs", async () => {
    const { env } = baseEnv();
    const { forms } = twilioStub([{ status: 400, body: { code: 21215, message: "Geo permission https://x" } }]);
    const placed = await placeOutboundCall(env, { contact: "them", to: "+447700900123", brief: "Ask if they deliver." });
    expect(placed.ok).toBe(false);
    expect(forms).toHaveLength(1);
    const text = dialFailure(placed.ok ? "" : placed.error);
    expect(text).toContain("Nothing was dialled");
    expect(text).not.toMatch(/Twilio|\d{5}|https?:|redacted/i);
  });

  it("prank, reminder call and call-me voice note (callAndPlay) send valid TwiML URLs", async () => {
    const { env } = baseEnv();
    const { forms } = twilioStub();
    const play = `<Response><Pause length="1"/><Play>${PUBLIC_BASE_URL}/v/abcdefghijklmnopqrst.mp3</Play></Response>`;
    expect((await callAndPlay(env, "+447700900123", play, 60)).ok).toBe(true);
    expect((await callAndPlay(env, "+447700900123", `<Response><Say>Reminder</Say></Response>`, 90)).ok).toBe(true);
    expect(forms).toHaveLength(2);
  });

  it("refuses to send TwiML that points at an internal host", async () => {
    const { env } = baseEnv();
    const { forms } = twilioStub();
    const r = await callAndPlay(env, "+447700900123", `<Response><Play>https://jarvis-lane/v/a.mp3</Play></Response>`);
    expect(r.ok).toBe(false);
    expect(forms).toHaveLength(0);
  });

  it("outboundForm only ever produces valid URLs", () => {
    const form = outboundForm(PUBLIC_BASE_URL, "call_abc", "+447700900123", "+447700900001");
    expect(invalidFormUrl(form)).toBe("");
    expect(() => outboundForm("https://jarvis-lane", "call_abc", "+447700900123", "+447700900001")).toThrow();
  });

  it("createTwilioCall moves to the next base when the first form is invalid", async () => {
    const { env } = baseEnv();
    const { forms } = twilioStub();
    const r = await createTwilioCall(env, (base) => new URLSearchParams({ Url: base === PUBLIC_BASE_URL ? "https:" : `${base}/x` }), {
      fallbackOrigin: "https://other.example.com",
    });
    expect(r.ok).toBe(true);
    expect(forms[0].get("Url")).toBe("https://other.example.com/x");
  });
});

describe("guard: no code path creates a Twilio call without the URL helper", () => {
  it("only src/public-url.ts posts to Calls.json", () => {
    const dir = new URL("../src/", import.meta.url);
    const offenders = readdirSync(dir)
      .filter((f) => f.endsWith(".ts") && f !== "public-url.ts")
      .filter((f) => /Calls\.json`\s*,\s*\{|Calls\.json",\s*\{|\/Calls\.json`, form/.test(readFileSync(new URL(f, dir), "utf8")));
    expect(offenders).toEqual([]);
  });
});
