// @ts-nocheck -- uses the Node SQLite helper.
import { afterEach, describe, expect, it, vi } from "vitest";
import { createLookLink, handleLook, isLookRoute, lookPage, wantsToShow } from "../src/look";
import { ownerAgentPrompt, ownerToolConfigs } from "../src/owner-agent";
import { VISION_MODELS } from "../src/sms-extras";
import { sqliteD1 } from "./helpers/sqlite-d1";

const PHONE = "+447700900555";

function env() {
  const { db, raw } = sqliteD1();
  raw.exec("CREATE TABLE IF NOT EXISTS sms_turns (id TEXT PRIMARY KEY, phone TEXT, role TEXT, body TEXT, created_at TEXT)");
  return { env: { DB: db, GEMINI_API_KEY: "g-key", GROQ_API_KEY: "q-key", ELEVENLABS_API_KEY: "e-key" }, raw };
}

afterEach(() => vi.unstubAllGlobals());

describe("let me show you: the camera link", () => {
  it("spots when he wants to show something, and nothing else", () => {
    for (const t of ["let me show you", "Lemme show u something", "can you see this?", "look at this", "send me the camera link", "can I share my screen"]) {
      expect(wantsToShow(t), t).toBe(true);
    }
    for (const t of ["show me the weather", "look at the time", "what camera should I buy", "remind me to show Ali the car"]) {
      expect(wantsToShow(t), t).toBe(false);
    }
  });

  it("makes an expiring private link and refuses anything else", async () => {
    const { env: e } = env();
    const now = new Date();
    const link = await createLookLink(e, PHONE, "https://jarvis.example/", now);
    expect(link.url).toMatch(/^https:\/\/jarvis\.example\/look\/[0-9a-f]{36}$/);
    expect(isLookRoute("GET", `/look/${link.token}`)).toBe(true);
    expect(isLookRoute("POST", `/look/${link.token}/ask`)).toBe(true);
    expect(isLookRoute("GET", "/look/abc")).toBe(false);
    const ok = await handleLook(new Request(link.url), e, `/look/${link.token}`);
    expect(ok.status).toBe(200);
    expect(ok.headers.get("cache-control")).toBe("no-store");
    const html = await ok.text();
    expect(html).toContain("getUserMedia");
    expect(html).toContain("getDisplayMedia");
    expect(html).toContain("iPhone Safari can't share your screen");
    const fake = await handleLook(new Request("https://jarvis.example/look/x"), e, `/look/${"0".repeat(36)}`);
    expect(fake.status).toBe(410);
    const old = await createLookLink(e, PHONE, "https://jarvis.example", new Date(now.getTime() - 31 * 60_000));
    expect((await handleLook(new Request(old.url), e, `/look/${old.token}`)).status).toBe(410);
  });

  it("answers what the camera sees, out loud, and remembers it in his text thread", async () => {
    const { env: e, raw } = env();
    const calls = [];
    vi.stubGlobal("fetch", async (url, init) => {
      calls.push([String(url), init]);
      if (String(url).includes("elevenlabs")) return new Response(new Uint8Array(4000), { status: 200 });
      if (String(url).includes("generativelanguage")) return new Response("{}", { status: 429 });
      return Response.json({ choices: [{ message: { content: "<think>hmm</think>That's a **red** kettle, Sir." } }] });
    });
    const link = await createLookLink(e, PHONE, "https://jarvis.example");
    const image = "data:image/jpeg;base64," + "A".repeat(400);
    const res = await handleLook(
      new Request(`${link.url}/ask`, { method: "POST", body: JSON.stringify({ question: "what's this?", image }) }),
      e,
      `/look/${link.token}/ask`,
    );
    const body = await res.json();
    expect(body.answer).toBe("That's a red kettle, Sir.");
    expect(typeof body.audio).toBe("string");
    const groq = calls.find(([u]) => u.includes("groq"));
    const sent = JSON.parse(groq[1].body);
    expect(sent.model).toBe("qwen/qwen3.8-27b");
    expect(JSON.stringify(sent.messages)).toContain(image);
    const turns = raw.prepare("SELECT role, body FROM sms_turns WHERE phone = ? ORDER BY created_at").all(PHONE);
    expect(turns.map((t) => t.body)).toEqual(["[camera] what's this?", "That's a red kettle, Sir."]);
  });

  it("uses only vision models that are still served", () => {
    const names = VISION_MODELS.map(([, m]) => m);
    expect(names).not.toContain("gemini-2.5-flash");
    expect(names).not.toContain("meta-llama/llama-4-scout-17b-16e-instruct");
  });

  it("the call agent can text the camera link and is honest about iPhone screen share", () => {
    expect(Object.keys(ownerToolConfigs("https://x", "k"))).toContain("send_camera_link");
    expect(ownerAgentPrompt()).toMatch(/send_camera_link/);
    expect(ownerAgentPrompt()).toMatch(/can't share its screen/);
    expect(lookPage("a".repeat(36))).toContain("Screenshot");
  });
});
