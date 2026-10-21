import { describe, expect, it } from "vitest";
import { route } from "../src/routes";
import { GROQ_MODEL, type Env } from "../src/types";

function contractEnv(receipts: string[] = []): Env {
  const db = {
    prepare(sql: string) {
      const statement = {
        args: [] as unknown[],
        bind(...args: unknown[]) {
          this.args = args;
          return this;
        },
        async first() {
          return null;
        },
        async all() {
          if (sql.includes("runtime_state")) {
            return { results: receipts.map((value) => ({ value })), success: true, meta: {} };
          }
          return { results: [], success: true, meta: {} };
        },
        async run() {
          return { success: true, meta: { changes: 0 } };
        },
      };
      return statement;
    },
  };
  return {
    JARVIS_APP_TOKEN: "secret-token",
    TWILIO_ACCOUNT_SID: "ACexampleaccountsid000000000000",
    TWILIO_AUTH_TOKEN: "twilio-auth-token-example",
    TWILIO_FROM_NUMBER: "+15551230001",
    ELEVENLABS_API_KEY: "elevenlabs-key-example-value",
    ELEVENLABS_AGENT_ID: "agent_example",
    DB: db as unknown as D1Database,
  };
}

const bearer = { authorization: "Bearer secret-token", "content-type": "application/json" };

function ctx(): ExecutionContext {
  return {
    waitUntil() {
      return undefined;
    },
    passThroughOnException() {
      return undefined;
    },
    props: {},
  } as unknown as ExecutionContext;
}

describe("release contract", () => {
  it("rejects an unapproved outbound call before Twilio is contacted", async () => {
    const calls: string[] = [];
    const original = globalThis.fetch;
    globalThis.fetch = (async (input: RequestInfo | URL) => {
      calls.push(String(input));
      return new Response("should not dial", { status: 500 });
    }) as typeof fetch;
    try {
      const response = await route(
        new Request("https://jarvis.example/calls/outbound", {
          method: "POST",
          headers: bearer,
          body: JSON.stringify({
            to: "+15557654321",
            purpose: "A release check",
            contact_name: "QA",
            approved: false,
          }),
        }),
        contractEnv(),
        ctx(),
      );
      expect(response.status).toBe(403);
      const body = (await response.json()) as { error: { code: string } };
      expect(body.error.code).toBe("not_approved");
      expect(calls).toEqual([]);
    } finally {
      globalThis.fetch = original;
    }
  });

  it("reports push, the Grok webhook, and blocked texts without a phone number", async () => {
    const response = await route(
      new Request("https://jarvis.example/calls/config", { headers: bearer }),
      contractEnv([JSON.stringify({ ok: false, errorCode: "20003", spoken: "Sir, a caller rang at 11:06." })]),
      ctx(),
    );
    expect(response.status).toBe(200);
    const body = (await response.json()) as {
      assistant_webhook: boolean;
      texts: string;
      screening: { push: boolean };
      from_number: string;
    };
    expect(body.assistant_webhook).toBe(false);
    expect(body.texts).toBe("blocked");
    expect(body.screening.push).toBe(false);
    expect(body.from_number).toBe("+15551230001");
    const text = JSON.stringify(body);
    expect(text).not.toContain("twilio-auth-token-example");
    expect(text).not.toContain("elevenlabs-key");
  });

  it("keeps call messages, device registration, and the assistant chat behind the app token", async () => {
    const paths = [
      ["GET", "/calls/messages?unread=1"],
      ["GET", "/calls/messages/cmsg_example"],
      ["POST", "/calls/device"],
      ["POST", "/agent/chat"],
      ["POST", "/calls/settle"],
    ] as const;
    for (const [method, path] of paths) {
      const open = await route(new Request(`https://jarvis.example${path}`, { method }), contractEnv(), ctx());
      expect(open.status, path).toBe(401);
    }
  });

  it("uses a Groq model that still exists", () => {
    expect(GROQ_MODEL).toBe("openai/gpt-oss-120b");
    expect(GROQ_MODEL).not.toContain("llama-3.3-70b");
  });

  it("refuses home chat when the Grok webhook is not set", async () => {
    const response = await route(
      new Request("https://jarvis.example/agent/chat", {
        method: "POST",
        headers: bearer,
        body: JSON.stringify({ message: "Good evening", conversationId: "conv_home" }),
      }),
      contractEnv(),
      ctx(),
    );
    expect(response.status).toBe(503);
    const body = (await response.json()) as { error: { code: string } };
    expect(body.error.code).toBe("webhook_not_configured");
  });
});
