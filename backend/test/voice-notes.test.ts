import { afterEach, describe, expect, it } from "vitest";
import { guardUnplacedCall } from "../src/brain";
import { handleInboundSms, simulateSmsRoute } from "../src/sms-desk";
import type { Env } from "../src/types";
import { explicitWords, isVoiceNotePath, noteId, refusal, serveVoiceNote, stripTags, voiceAsk } from "../src/voice-notes";
import { sqliteD1 } from "./helpers/sqlite-d1";

const OWNER = "+447700900555";
const original = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = original;
});

interface Seen {
  texts: { to: string; body: string }[];
  calls: URLSearchParams[];
  tts: { url: string; body: Record<string, unknown> }[];
  sfx: Record<string, unknown>[];
}

function voiceEnv(opts: { v3Fails?: boolean; credits?: number } = {}): { env: Env; seen: Seen } {
  const { db } = sqliteD1();
  const seen: Seen = { texts: [], calls: [], tts: [], sfx: [] };
  const audio = new Uint8Array(6_000).map((_, i) => (i * 7) % 251);
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    if (url.includes("groq.com") || url.includes("generativelanguage")) {
      return new Response(JSON.stringify({ choices: [{ message: { role: "assistant", content: "Good evening, Sir. [laughs] JARVIS here." } }] }), { status: 200 });
    }
    if (url.includes("/v1/user/subscription")) {
      return new Response(JSON.stringify({ character_count: 30_000 - (opts.credits ?? 17_000), character_limit: 30_000 }), { status: 200 });
    }
    if (url.includes("/v1/text-to-speech/")) {
      const body = JSON.parse(String(init?.body)) as Record<string, unknown>;
      seen.tts.push({ url, body });
      if (opts.v3Fails && body.model_id === "eleven_v3") return new Response("{}", { status: 400 });
      return new Response(audio, { status: 200, headers: { "content-type": "audio/mpeg" } });
    }
    if (url.includes("/v1/sound-generation")) {
      seen.sfx.push(JSON.parse(String(init?.body)) as Record<string, unknown>);
      return new Response(audio, { status: 200, headers: { "content-type": "audio/mpeg" } });
    }
    if (url.includes("/Calls.json")) {
      seen.calls.push(new URLSearchParams(String(init?.body)));
      return new Response(JSON.stringify({ sid: "CA1234567890abcdef1234567890abcdef" }), { status: 201 });
    }
    if (url.includes("/Messages.json") && (init?.method ?? "GET") === "POST") {
      const form = new URLSearchParams(String(init?.body ?? ""));
      seen.texts.push({ to: form.get("To") ?? "", body: form.get("Body") ?? "" });
      return new Response(JSON.stringify({ sid: "SM1234567890abcdef1234567890abcdef", status: "queued" }), { status: 201 });
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
  } as unknown as Env;
  return { env, seen };
}

const linkOf = (text: string): string => /https:\/\/\S+\/v\/[A-Za-z0-9]{20}/.exec(text)?.[0] ?? "";

describe("voice notes by link", () => {
  it("spots voice requests and leaves chat about music alone", () => {
    expect(voiceAsk("Send me a voice message of u beatboxing")).toMatchObject({ kind: "beatbox", byCall: false });
    expect(voiceAsk("send me a voice note saying good night")).toMatchObject({ kind: "speech" });
    expect(voiceAsk("can you rap for me")).toMatchObject({ kind: "sing" });
    expect(voiceAsk("sing me happy birthday")).toMatchObject({ kind: "sing" });
    expect(voiceAsk("call me and say it")).toMatchObject({ kind: "speech", byCall: true });
    expect(voiceAsk("make the sound of a lion roaring")).toMatchObject({ kind: "sound", prompt: "a lion roaring" });
    expect(voiceAsk("do you like rap?")).toBeNull();
    expect(voiceAsk("what's your favourite song")).toBeNull();
    expect(voiceAsk("Call 07700 900123 and say hello")).toBeNull();
    expect(voiceAsk("how are you")).toBeNull();
  });

  it("makes a real beatbox clip, stores it, and texts one line plus a link that plays", async () => {
    const { env, seen } = voiceEnv();
    await handleInboundSms(env, OWNER, "Send me a voice message of u beatboxing");
    expect(seen.sfx).toHaveLength(1);
    expect(String(seen.sfx[0]?.text)).toMatch(/beatbox/i);
    expect(seen.tts).toHaveLength(0);
    expect(seen.texts).toHaveLength(1);
    expect(seen.texts[0]?.to).toBe(OWNER);
    const link = linkOf(seen.texts[0]?.body ?? "");
    expect(seen.texts[0]?.body).toMatch(/^Beatbox, as requested, Sir\. Tap to play: https:/);
    expect(seen.texts[0]!.body.length).toBeLessThan(160);
    const path = new URL(link).pathname;
    expect(isVoiceNotePath("GET", path)).toBe(true);
    const html = await serveVoiceNote(new Request(`https://w.test${path}`), env, path);
    expect(html.status).toBe(200);
    expect(await html.text()).toContain(`${path}.mp3`);
    const mp3 = await serveVoiceNote(new Request(`https://w.test${path}.mp3`), env, `${path}.mp3`);
    expect(mp3.headers.get("content-type")).toBe("audio/mpeg");
    expect((await mp3.arrayBuffer()).byteLength).toBe(6_000);
    const part = await serveVoiceNote(new Request(`https://w.test${path}.mp3`, { headers: { range: "bytes=0-99" } }), env, `${path}.mp3`);
    expect(part.status).toBe(206);
    expect(part.headers.get("content-range")).toBe("bytes 0-99/6000");
    expect(seen.calls).toHaveLength(0);
  });

  it("speaks in George's voice with v3, and falls back to v2 without the tags", async () => {
    const { env, seen } = voiceEnv({ v3Fails: true });
    await handleInboundSms(env, OWNER, "send me a voice note saying good night");
    expect(seen.tts.map((t) => t.body.model_id)).toEqual(["eleven_v3", "eleven_multilingual_v2"]);
    expect(seen.tts[0]?.url).toContain("JBFqnCBsd6RMkjVDRZzb");
    expect(String(seen.tts[1]?.body.text)).not.toContain("[laughs]");
    expect(String(seen.tts[0]?.body.text).length).toBeLessThanOrEqual(400);
    expect(seen.texts[0]?.body).toMatch(/^Voice note for you, Sir\. Tap to play: https:/);
  });

  it("rings only Sir's own number when he asks to be called", async () => {
    const { env, seen } = voiceEnv();
    await handleInboundSms(env, OWNER, "call me and sing me something");
    expect(seen.calls).toHaveLength(1);
    expect(seen.calls[0]?.get("To")).toBe(OWNER);
    expect(seen.calls[0]?.get("Twiml")).toMatch(/<Play>https:\/\/\S+\/v\/[A-Za-z0-9]{20}\.mp3<\/Play>/);
    expect(seen.texts[0]?.body).toContain("Ringing you now");
  });

  it("does not make notes for strangers", async () => {
    const { env, seen } = voiceEnv();
    await handleInboundSms(env, "+447700900321", "send me a voice note of you beatboxing");
    expect(seen.sfx).toHaveLength(0);
    expect(seen.tts).toHaveLength(0);
    expect(seen.texts.filter((t) => t.to === "+447700900321").map((t) => t.body)).toEqual([
      "Hello, this is JARVIS, Master Hadi's assistant. I'll pass that to him.",
    ]);
  });

  it("stops when the monthly allowance is nearly used", async () => {
    const { env, seen } = voiceEnv({ credits: 1_000 });
    await handleInboundSms(env, OWNER, "send me a voice note");
    expect(seen.tts).toHaveLength(0);
    expect(seen.texts[0]?.body).toContain("allowance");
  });

  it("simulates without sending or dialling", async () => {
    const { env, seen } = voiceEnv();
    const response = await simulateSmsRoute(
      new Request("https://w.test/debug/sms-simulate", { method: "POST", body: JSON.stringify({ text: "call me and beatbox", thread: "9" }) }),
      env,
    );
    const body = (await response.json()) as { reply: string; sent: boolean };
    expect(body.reply).toContain("Nothing was dialled");
    expect(linkOf(body.reply)).not.toBe("");
    expect(seen.calls).toHaveLength(0);
    expect(seen.texts).toHaveLength(0);
  });

  it("unknown or expired links do not play, and ids are long", async () => {
    const { env } = voiceEnv();
    const missing = await serveVoiceNote(new Request("https://w.test/v/AAAAAAAAAAAAAAAAAAAA"), env, "/v/AAAAAAAAAAAAAAAAAAAA");
    expect(missing.status).toBe(404);
    expect(noteId()).toMatch(/^[A-Za-z0-9]{20}$/);
    expect(isVoiceNotePath("GET", "/v/short")).toBe(false);
    expect(stripTags("[sings] la la [laughs] la")).toBe("la la la");
  });

  it("does not record a refusal as the voice note", async () => {
    expect(refusal("I'm sorry sir, but I can't comply with that.")).toBe(true);
    expect(explicitWords("Send me a voice note saying good night")).toBe("Good night, Sir.");
    expect(explicitWords("say it")).toBeNull();
    const { env, seen } = voiceEnv();
    const real = globalThis.fetch;
    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      if (String(input).includes("groq.com")) {
        return new Response(JSON.stringify({ choices: [{ message: { role: "assistant", content: "I'm sorry, but I can't comply with that." } }] }), { status: 200 });
      }
      return real(input, init);
    }) as typeof fetch;
    await handleInboundSms(env, OWNER, "Send me a voice note saying good night");
    expect(seen.tts[0]?.body.text).toBe("Good night, Sir.");
  });

  it("never tells Sir it cannot send voice messages", () => {
    expect(guardUnplacedCall("I'm afraid I can't send voice messages, Sir.")).toContain("voice note");
    expect(guardUnplacedCall("Good evening, Sir.")).toBe("Good evening, Sir.");
  });
});
