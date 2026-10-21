import { describe, expect, it } from "vitest";
import { mintGeminiLiveToken } from "../src/live-token";
import { route } from "../src/routes";
import type { Env } from "../src/types";

function env(): Env {
  return {
    JARVIS_APP_TOKEN: "secret-token",
    GEMINI_API_KEY: "gemini-key-example-value",
    DB: {
      prepare() {
        const statement = {
          bind() {
            return statement;
          },
          async all() {
            return { results: [], success: true, meta: {} };
          },
          async first() {
            return null;
          },
          async run() {
            return { success: true, meta: { changes: 1 } };
          },
        };
        return statement;
      },
    } as unknown as D1Database,
  };
}

describe("Gemini Live token", () => {
  it("mints a one-use token and never returns the API key", async () => {
    const original = globalThis.fetch;
    let sent = "";
    globalThis.fetch = (async (_input: RequestInfo | URL, init?: RequestInit) => {
      sent = String(init?.body ?? "");
      const headers = new Headers(init?.headers);
      expect(headers.get("x-goog-api-key")).toBe("gemini-key-example-value");
      return new Response(JSON.stringify({ name: "ephemeral-token-value" }), { status: 200 });
    }) as typeof fetch;
    try {
      const ticket = await mintGeminiLiveToken(env(), Date.parse("2026-10-21T16:00:00.000Z"));
      expect(ticket.ok).toBe(true);
      if (!ticket.ok) return;
      expect(ticket.model).toBe("gemini-3.8-live");
      expect(ticket.token).toBe("ephemeral-token-value");
      expect(ticket.websocket_url).toContain("BidiGenerateContentConstrained");
      expect(ticket.websocket_url).toContain("access_token=ephemeral-token-value");
      expect(ticket.expires_at).toBe("2026-10-21T16:30:00.000Z");
      expect(sent).toContain('"uses":1');
      expect(sent).not.toContain("gemini-key-example-value");
      expect(JSON.stringify(ticket)).not.toContain("gemini-key-example-value");
    } finally {
      globalThis.fetch = original;
    }
  });

  it("reports quota without the API key", async () => {
    const original = globalThis.fetch;
    globalThis.fetch = (async () =>
      new Response(JSON.stringify({ error: { message: "quota gemini-key-example-value" } }), { status: 429 })) as typeof fetch;
    try {
      const response = await route(
        new Request("https://jarvis.test/voice/live-token", {
          method: "POST",
          headers: { authorization: "Bearer secret-token" },
        }),
        env(),
        { waitUntil() {}, passThroughOnException() {}, props: {} } as unknown as ExecutionContext,
      );
      expect(response.status).toBe(429);
      const text = await response.text();
      expect(text).toContain("quota");
      expect(text).not.toContain("gemini-key-example-value");
    } finally {
      globalThis.fetch = original;
    }
  });
});
