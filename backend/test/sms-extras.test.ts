import { afterEach, describe, expect, it } from "vitest";
import { handleInboundSms } from "../src/sms-desk";
import {
  agentAsk,
  atLondon,
  fireDueReminders,
  helpAsk,
  helpTexts,
  morningText,
  nearbyAsk,
  nearbyLine,
  openNow,
  parseReminder,
  personalContact,
  prankAsk,
  prankUnsafe,
  ringByName,
  sweepMorningText,
  sweepPriceWatches,
  watchAsk,
} from "../src/sms-extras";
import type { Env } from "../src/types";
import { dissUnsafe, voiceAsk } from "../src/voice-notes";
import { sqliteD1 } from "./helpers/sqlite-d1";

const OWNER = "+447911123456";
const original = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = original;
});

interface Seen {
  texts: { to: string; body: string }[];
  calls: URLSearchParams[];
  posts: { url: string; body: string }[];
}

function extrasEnv(opts: { stooq?: number; webhook?: boolean } = {}): { env: Env; seen: Seen } {
  const { db } = sqliteD1();
  const seen: Seen = { texts: [], calls: [], posts: [] };
  const audio = new Uint8Array(6_000).map((_, i) => (i * 7) % 251);
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    if (url.includes("groq.com") || url.includes("generativelanguage")) {
      const body = String(init?.body ?? "");
      const content = body.includes("image_url")
        ? "A parking fine, Sir: £70, halved to £35 if paid by 30 Nov."
        : "Good afternoon. You have won the coveted Golden Kettle award for outstanding tea.";
      return new Response(JSON.stringify({ choices: [{ message: { role: "assistant", content } }] }), { status: 200 });
    }
    if (url.includes("example.org/fine.jpg")) {
      return new Response(new Uint8Array(4_000), { status: 200, headers: { "content-type": "image/jpeg" } });
    }
    if (url.includes("api.twilio.com") && url.includes("/Media/")) {
      return new Response(new Uint8Array(4_000), { status: 200, headers: { "content-type": "image/png" } });
    }
    if (url.includes("api.open-meteo.com")) {
      return new Response(
        JSON.stringify({
          current: { temperature_2m: 8.4, weather_code: 61 },
          daily: { temperature_2m_max: [11.2], temperature_2m_min: [4.6], precipitation_probability_max: [70] },
        }),
        { status: 200 },
      );
    }
    if (url.includes("stooq.com")) {
      return new Response(`Symbol,Date,Time,Open,High,Low,Close,Volume\nTSLA.US,2026-11-13,22:00:00,1,1,1,${opts.stooq ?? 250},1\n`, { status: 200 });
    }
    if (url.includes("overpass")) {
      return new Response(
        JSON.stringify({
          elements: [
            { lat: 51.15, lon: 0.88, tags: { name: "Far Chemist", opening_hours: "24/7" } },
            { lat: 51.147, lon: 0.876, tags: { name: "Boots", opening_hours: "Mo-Su 00:00-00:01" } },
          ],
        }),
        { status: 200 },
      );
    }
    if (url.includes("/v1/user/subscription")) {
      return new Response(JSON.stringify({ character_count: 10_000, character_limit: 30_000 }), { status: 200 });
    }
    if (url.includes("/v1/text-to-speech/")) return new Response(audio, { status: 200, headers: { "content-type": "audio/mpeg" } });
    if (url.includes("/Calls.json")) {
      seen.calls.push(new URLSearchParams(String(init?.body)));
      return new Response(JSON.stringify({ sid: "CA1234567890abcdef1234567890abcdef" }), { status: 201 });
    }
    if (url.includes("/Messages.json") && (init?.method ?? "GET") === "POST") {
      const form = new URLSearchParams(String(init?.body ?? ""));
      seen.texts.push({ to: form.get("To") ?? "", body: form.get("Body") ?? "" });
      return new Response(JSON.stringify({ sid: "SM1234567890abcdef1234567890abcdef", status: "queued" }), { status: 201 });
    }
    if (url.includes("hooks.example")) {
      seen.posts.push({ url, body: String(init?.body ?? "") });
      return new Response("{}", { status: 200 });
    }
    return new Response("{}", { status: 404 });
  }) as typeof fetch;
  const env = {
    DB: db,
    GROQ_API_KEY: "groq-test-key",
    ELEVENLABS_API_KEY: "eleven-test-key",
    TWILIO_ACCOUNT_SID: "ACtest",
    TWILIO_AUTH_TOKEN: "twilio-token",
    TWILIO_FROM_NUMBER: "+447700900999",
    OWNER_PHONE: OWNER,
    ...(opts.webhook ? { JARVIS_WEBHOOK_URL: "https://hooks.example/agent", JARVIS_WEBHOOK_KEY: "k" } : {}),
  } as unknown as Env;
  return { env, seen };
}

const all = (seen: Seen) => seen.texts.map((t) => t.body).join(" | ");

describe("reminder parsing (Europe/London)", () => {
  const now = new Date("2026-11-16T14:30:00Z"); // 14:30 GMT
  it("reads in N minutes and at times", () => {
    const a = parseReminder("remind me in 20 mins to stretch", now);
    expect(a).toMatchObject({ task: "stretch", byCall: false });
    expect((a as { dueAt: Date }).dueAt.toISOString()).toBe("2026-11-16T14:50:00.000Z");
    const b = parseReminder("remind me at 6 to call mum", now) as { dueAt: Date; task: string };
    expect(b.dueAt.toISOString()).toBe("2026-11-16T18:00:00.000Z");
    expect(b.task).toBe("call mum");
    const c = parseReminder("Remind me tomorrow at 9am to ring the garage, call me", now) as { dueAt: Date; byCall: boolean; task: string };
    expect(c.dueAt.toISOString()).toBe("2026-11-17T09:00:00.000Z");
    expect(c.byCall).toBe(true);
    expect(c.task).toBe("ring the garage");
    const d = parseReminder("remind me at 10am to take the bins out", now) as { dueAt: Date };
    expect(d.dueAt.toISOString()).toBe("2026-11-17T10:00:00.000Z");
    const e = parseReminder("remind me in an hour to check the oven", now) as { dueAt: Date };
    expect(e.dueAt.toISOString()).toBe("2026-11-16T15:30:00.000Z");
  });
  it("handles BST", () => {
    const summer = new Date("2026-07-01T10:00:00Z");
    const r = parseReminder("remind me at 6pm to water the plants", summer) as { dueAt: Date };
    expect(r.dueAt.toISOString()).toBe("2026-07-01T17:00:00.000Z");
    expect(atLondon("2026-07-01", 8, 0).toISOString()).toBe("2026-07-01T07:00:00.000Z");
  });
  it("asks when the time is missing and ignores chat", () => {
    expect(parseReminder("remind me to call mum", now)).toBe("unclear");
    expect(parseReminder("remind me what you said yesterday", now)).toBeNull();
    expect(parseReminder("what's the weather", now)).toBeNull();
  });
});

describe("reminders fire from the minute cron", () => {
  it("texts the owner when due and never twice", async () => {
    const { env, seen } = extrasEnv();
    await handleInboundSms(env, OWNER, "remind me in 5 mins to stretch");
    expect(all(seen)).toContain("I'll text you at");
    seen.texts.length = 0;
    expect(await fireDueReminders(env, new Date(Date.now() + 2 * 60_000))).toBe(0);
    expect(await fireDueReminders(env, new Date(Date.now() + 6 * 60_000))).toBe(1);
    expect(await fireDueReminders(env, new Date(Date.now() + 7 * 60_000))).toBe(0);
    expect(seen.texts).toEqual([{ to: OWNER, body: "Reminder, Sir: Stretch." }]);
  });
  it("rings the owner when he asked for a call", async () => {
    const { env, seen } = extrasEnv();
    await handleInboundSms(env, OWNER, "remind me in 10 minutes to call mum, call me");
    expect(all(seen)).toContain("I'll ring you at");
    await fireDueReminders(env, new Date(Date.now() + 11 * 60_000));
    expect(seen.calls).toHaveLength(1);
    expect(seen.calls[0]?.get("To")).toBe(OWNER);
    expect(seen.calls[0]?.get("Twiml")).toContain("/v/");
  });
  it("lists and cancels", async () => {
    const { env, seen } = extrasEnv();
    await handleInboundSms(env, OWNER, "remind me at 6pm to call mum");
    await handleInboundSms(env, OWNER, "my reminders");
    expect(all(seen)).toContain("call mum");
    await handleInboundSms(env, OWNER, "cancel my reminders");
    expect(all(seen)).toContain("Cancelled 1 reminder");
  });
});

describe("morning text", () => {
  it("sends weather and the day once at 8am unless stopped", async () => {
    const { env, seen } = extrasEnv();
    const eight = new Date("2026-11-17T08:00:30Z");
    const text = await morningText(env, OWNER, eight);
    expect(text).toContain("Ashford 8C, light rain, high 11C low 5C, 70% rain");
    expect(text.length).toBeLessThan(300);
    expect(await sweepMorningText(env, eight)).toBe(true);
    expect(await sweepMorningText(env, new Date("2026-11-17T08:01:30Z"))).toBe(false);
    expect(seen.texts).toHaveLength(1);
    await handleInboundSms(env, OWNER, "stop morning");
    expect(all(seen)).toContain("Morning texts paused");
    expect(await sweepMorningText(env, new Date("2026-11-18T08:00:30Z"))).toBe(false);
    await handleInboundSms(env, OWNER, "start morning");
    expect(await sweepMorningText(env, new Date("2026-11-18T08:00:30Z"))).toBe(true);
  });
});

describe("nearby", () => {
  it("parses asks and reads opening hours", () => {
    expect(nearbyAsk("nearest open pharmacy")).toMatchObject({ label: "pharmacy", openOnly: true, place: "" });
    expect(nearbyAsk("closest petrol station near Folkestone")).toMatchObject({ label: "petrol station", place: "Folkestone" });
    expect(nearbyAsk("how are you")).toBeNull();
    const monNoon = new Date("2026-11-16T12:00:00Z");
    expect(openNow("Mo-Fr 09:00-18:00; Sa 09:00-13:00; Su off", monNoon)).toEqual({ open: true, until: "18:00" });
    expect(openNow("Mo-Fr 09:00-11:00", monNoon)).toEqual({ open: false, until: "" });
    expect(openNow("Sa-Su 10:00-16:00", monNoon)).toBeNull();
    expect(openNow("24/7", monNoon)?.open).toBe(true);
    expect(openNow("sunrise-sunset", monNoon)).toBeNull();
  });
  it("replies with the nearest open place and a maps link", async () => {
    const { env, seen } = extrasEnv();
    await handleInboundSms(env, OWNER, "nearest open pharmacy");
    const text = all(seen);
    expect(text).toContain("Nearest open pharmacy, Sir: Far Chemist");
    expect(text).toContain("https://maps.google.com/?q=51.15000,0.88000");
    const line = nearbyLine(
      { label: "cafe", filter: "", openOnly: false, place: "" },
      { centre: "Ashford, Kent", spots: [] },
    );
    expect(line).toContain("couldn't find a cafe");
  });
});

describe("price watch", () => {
  it("parses stocks and products", () => {
    expect(watchAsk("watch tesla stock and text me when it's under $200")).toMatchObject({ symbol: "TSLA", currency: "$", threshold: 200 });
    expect(watchAsk("watch PS5 and text me when under £400")).toMatchObject({ item: "PS5", symbol: "", currency: "£", threshold: 400 });
    expect(watchAsk("watch $NVDA below 120")).toMatchObject({ symbol: "NVDA", threshold: 120 });
    expect(watchAsk("watch the match tonight")).toBeNull();
  });
  it("adds, lists, alerts once on a hit and stops", async () => {
    const { env, seen } = extrasEnv({ stooq: 250 });
    await handleInboundSms(env, OWNER, "watch tesla stock and text me when it's under $200");
    expect(all(seen)).toContain("Watching TSLA");
    expect(all(seen)).toContain("$250 now");
    await handleInboundSms(env, OWNER, "my watches");
    expect(all(seen)).toContain("TSLA under $200");
    seen.texts.length = 0;
    const { env: env2, seen: seen2 } = { env, seen };
    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (url.includes("stooq.com")) return new Response("Symbol,Date,Time,Open,High,Low,Close,Volume\nTSLA.US,d,t,1,1,1,190.5,1\n", { status: 200 });
      if (url.includes("/Messages.json")) {
        const form = new URLSearchParams(String(init?.body ?? ""));
        seen2.texts.push({ to: form.get("To") ?? "", body: form.get("Body") ?? "" });
        return new Response(JSON.stringify({ sid: "SM1", status: "queued" }), { status: 201 });
      }
      return new Response("{}", { status: 404 });
    }) as typeof fetch;
    expect(await sweepPriceWatches(env2, new Date("2026-11-17T09:00:00Z"))).toBe(1);
    expect(await sweepPriceWatches(env2, new Date("2026-11-17T09:01:00Z"))).toBe(0);
    expect(seen2.texts[0]?.body).toContain("TSLA is $190.50");
    await handleInboundSms(env2, OWNER, "stop watching PS5");
    expect(all(seen2)).toContain("not watching anything called PS5");
  });
});

describe("photos", () => {
  it("reads an MMS photo for the owner", async () => {
    const { env, seen } = extrasEnv();
    await handleInboundSms(env, OWNER, "", ["https://api.twilio.com/2010-04-01/Accounts/ACtest/Messages/MM1/Media/ME1"]);
    expect(all(seen)).toContain("parking fine");
  });
  it("reads a picture link", async () => {
    const { env, seen } = extrasEnv();
    await handleInboundSms(env, OWNER, "what's this? https://example.org/fine.jpg");
    expect(all(seen)).toContain("£35");
  });
  it("strangers' photos are ignored", async () => {
    const { env, seen } = extrasEnv();
    await handleInboundSms(env, "+447911000111", "", ["https://api.twilio.com/2010-04-01/Accounts/ACtest/Messages/MM1/Media/ME1"]);
    expect(seen.texts).toHaveLength(0);
  });
});

describe("agents", () => {
  it("parses agent names", () => {
    expect(agentAsk("tell Project Money to find 5 leads in Ashford")).toEqual({ agent: "Project Money", task: "find 5 leads in Ashford" });
    expect(agentAsk("Tell F.R.I.D.A.Y. to check my calendar")).toEqual({ agent: "FRIDAY", task: "check my calendar" });
    expect(agentAsk("tell mum I'm late")).toBeNull();
  });
  it("queues when the bridge is not set and passes when it is", async () => {
    const queued = extrasEnv();
    await handleInboundSms(queued.env, OWNER, "tell ULTRON to draft the launch post");
    expect(all(queued.seen)).toContain("Queued for ULTRON");
    const passed = extrasEnv({ webhook: true });
    await handleInboundSms(passed.env, OWNER, "tell EDITH to summarise the inbox");
    expect(all(passed.seen)).toContain("Passed to EDITH");
    expect(passed.seen.posts[0]?.body).toContain("summarise the inbox");
  });
});

describe("prank calls", () => {
  it("parses and refuses unsafe bits", () => {
    expect(prankAsk("prank 07700 900123 with a fake award for best kettle")).toEqual({ phone: "07700900123", bit: "with a fake award for best kettle" });
    expect(prankUnsafe("pretend you're from customs and they owe a fee")).toBe(true);
    expect(prankUnsafe("tell them they won best kettle in Kent")).toBe(false);
  });
  it("refuses the customs bit politely and dials nothing", async () => {
    const { env, seen } = extrasEnv();
    await handleInboundSms(env, OWNER, "prank call 07911 222333 and say it's customs and their parcel is held");
    expect(all(seen)).toContain("I'll pass on that one");
    expect(seen.calls).toHaveLength(0);
  });
  it("offers, then YES rings once with a 60s cap and the reveal", async () => {
    const { env, seen } = extrasEnv();
    await handleInboundSms(env, OWNER, "prank 07911 222333 with a fake award for best kettle in Kent");
    expect(all(seen)).toContain("Reply YES to ring");
    expect(all(seen)).toContain("prank from Sohail's AI assistant");
    expect(seen.calls).toHaveLength(0);
    await handleInboundSms(env, OWNER, "YES");
    expect(seen.calls).toHaveLength(1);
    expect(seen.calls[0]?.get("To")).toBe("+447911222333");
    expect(seen.calls[0]?.get("TimeLimit")).toBe("60");
    await handleInboundSms(env, OWNER, "YES");
    expect(seen.calls).toHaveLength(1);
  });
});

describe("ring a business by name", () => {
  it("parses and keeps personal contacts to typed numbers", () => {
    expect(ringByName("ring Dominos in Ashford and ask if they deliver to TN24")).toMatchObject({ name: "Dominos", place: "Ashford", verb: "ask" });
    expect(ringByName("call the number and tell them hello")).toBeNull();
    expect(ringByName("call 07911 222333 and ask")).toBeNull();
    expect(personalContact("my mum")).toBe(true);
    expect(personalContact("Dominos")).toBe(false);
  });
});

describe("voice styles and help", () => {
  it("routes roast, hype, diss and rap", () => {
    expect(voiceAsk("roast me")).toMatchObject({ kind: "speech", style: "roast" });
    expect(voiceAsk("hype me up")).toMatchObject({ kind: "speech", style: "hype" });
    expect(voiceAsk("make a diss track about my cousin's cooking")).toMatchObject({ kind: "sing", style: "diss", prompt: "my cousin's cooking" });
    expect(voiceAsk("rap for me")).toMatchObject({ kind: "sing", style: "rap" });
    expect(dissUnsafe("diss track about how fat he is")).toBe(true);
    expect(dissUnsafe("diss track about his football team")).toBe(false);
  });
  it("answers help with the command list", async () => {
    expect(helpAsk("help")).toBe(true);
    expect(helpAsk("what can you do?")).toBe(true);
    for (const line of helpTexts()) expect(line.length).toBeLessThanOrEqual(306);
    const { env, seen } = extrasEnv();
    await handleInboundSms(env, OWNER, "help");
    expect(all(seen)).toContain("remind me in 20 mins");
  });
});
