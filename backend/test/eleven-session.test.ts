import { describe, expect, it } from "vitest";
import { elevenSessionResponse, elevenUsageResponse, londonDay } from "../src/eleven-session";
import type { Env } from "../src/types";

function env(state: Map<string, string>, extra: Partial<Env> = {}): Env {
  return {
    JARVIS_APP_TOKEN: "t",
    ELEVENLABS_API_KEY: "xi-key-example",
    ELEVENLABS_APP_AGENT_ID: "agent_app",
    DB: {
      prepare(sql: string) {
        let args: unknown[] = [];
        const s = {
          bind(...a: unknown[]) { args = a; return s; },
          async first() { return sql.startsWith("SELECT") ? (state.has(String(args[0])) ? { value: state.get(String(args[0])) } : null) : null; },
          async all() { return { results: [], success: true, meta: {} }; },
          async run() { if (sql.includes("INSERT INTO runtime_state")) state.set(String(args[0]), String(args[1])); return { success: true, meta: { changes: 1 } }; },
        };
        return s;
      },
    } as unknown as D1Database,
    ...extra,
  };
}

describe("ElevenLabs app voice session", () => {
  it("returns a signed url and never the key or agent id", async () => {
    const original = globalThis.fetch;
    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      expect(String(input)).toContain("agent_id=agent_app");
      expect(new Headers(init?.headers).get("xi-api-key")).toBe("xi-key-example");
      return new Response(JSON.stringify({ signed_url: "wss://api.elevenlabs.io/v1/convai/conversation?agent_id=agent_app&conversation_signature=sig" }));
    }) as typeof fetch;
    try {
      const res = await elevenSessionResponse(env(new Map()));
      const body = (await res.json()) as { signed_url: string; remaining_seconds: number };
      expect(res.status).toBe(200);
      expect(body.signed_url.startsWith("wss://")).toBe(true);
      expect(body.remaining_seconds).toBe(900);
    } finally { globalThis.fetch = original; }
  });

  it("retries once when ElevenLabs answers 5xx", async () => {
    const original = globalThis.fetch;
    let calls = 0;
    globalThis.fetch = (async () => {
      calls += 1;
      if (calls === 1) return new Response("busy", { status: 503 });
      return new Response(JSON.stringify({ signed_url: "wss://api.elevenlabs.io/v1/convai/conversation?agent_id=agent_app&conversation_signature=sig" }));
    }) as typeof fetch;
    try {
      const res = await elevenSessionResponse(env(new Map()));
      expect(res.status).toBe(200);
      expect(calls).toBe(2);
    } finally { globalThis.fetch = original; }
  });

  it("is 503 when not configured and 429 once the day's seconds are used", async () => {
    expect((await elevenSessionResponse(env(new Map(), { ELEVENLABS_APP_AGENT_ID: "" }))).status).toBe(503);
    const state = new Map([[`eleven_app:${londonDay()}`, "900"]]);
    expect((await elevenSessionResponse(env(state))).status).toBe(429);
  });

  it("adds reported seconds and clamps a bad report", async () => {
    const state = new Map<string, string>();
    const post = (seconds: unknown) => elevenUsageResponse(new Request("https://x/", { method: "POST", body: JSON.stringify({ seconds }) }), env(state));
    expect(((await (await post(100)).json()) as { used_seconds: number }).used_seconds).toBe(100);
    expect(((await (await post(99999)).json()) as { used_seconds: number }).used_seconds).toBe(700);
    expect((await post("x")).status).toBe(400);
  });
});
