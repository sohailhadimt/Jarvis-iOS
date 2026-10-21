import { describe, expect, it } from "vitest";
import { route } from "../src/routes";
import type { Env } from "../src/types";

const SID = "SM1234567890abcdef1234567890abcdef";

function env(): Env {
  return {
    JARVIS_APP_TOKEN: "secret-token",
    TWILIO_ACCOUNT_SID: "ACexampleaccountsid000000000000",
    TWILIO_AUTH_TOKEN: "twilio-auth-token-example",
    TWILIO_FROM_NUMBER: "+447700900000",
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

function ctx(): ExecutionContext {
  return { waitUntil() {}, passThroughOnException() {}, props: {} } as unknown as ExecutionContext;
}

describe("POST /messages/sms", () => {
  it("texts only after the app calls the route, and the reply hides the number", async () => {
    const original = globalThis.fetch;
    let sent = "";
    let calls = 0;
    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      calls += 1;
      sent = String(init?.body ?? "");
      expect(String(input)).toContain("Messages.json");
      return new Response(JSON.stringify({ sid: SID, status: "queued" }), { status: 201 });
    }) as typeof fetch;
    try {
      const response = await route(
        new Request("https://jarvis.test/messages/sms", {
          method: "POST",
          headers: { authorization: "Bearer secret-token", "content-type": "application/json" },
          body: JSON.stringify({ to: "+447700900123", body: "Wake up." }),
        }),
        env(),
        ctx(),
      );
      expect(response.status).toBe(200);
      const text = await response.text();
      expect(text).toContain(SID);
      expect(text).toContain('"ok":true');
      expect(text).not.toContain("7700");
      expect(sent).toContain("%2B447700900123");
      expect(calls).toBe(1);
    } finally {
      globalThis.fetch = original;
    }
  });

  it("does not text an emergency number", async () => {
    const original = globalThis.fetch;
    let calls = 0;
    globalThis.fetch = (async () => {
      calls += 1;
      return new Response("no", { status: 500 });
    }) as typeof fetch;
    try {
      const response = await route(
        new Request("https://jarvis.test/messages/sms", {
          method: "POST",
          headers: { authorization: "Bearer secret-token", "content-type": "application/json" },
          body: JSON.stringify({ to: "999", body: "hello" }),
        }),
        env(),
        ctx(),
      );
      expect(response.status).toBe(400);
      expect(calls).toBe(0);
      expect(await response.text()).not.toContain("999");
    } finally {
      globalThis.fetch = original;
    }
  });
});
