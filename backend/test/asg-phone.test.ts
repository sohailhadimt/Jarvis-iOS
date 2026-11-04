import { describe, expect, it } from "vitest";
import { route } from "../src/routes";
import { twilioSignature } from "../src/calls";
import type { Env } from "../src/types";

const OWNER = "+447700900111";
function env(): Env {
  const db = {
    prepare(sql: string) {
      const s = {
        bind: () => s,
        all: async () => ({ results: [], success: true, meta: {} }),
        first: async () => (sql.includes("call_settings") ? { mobile_number: OWNER } : null),
        run: async () => ({ success: true, meta: { changes: 1 } }),
      };
      return s;
    },
  };
  return {
    DB: db,
    TWILIO_ACCOUNT_SID: "ACexampleaccountsid000000000000",
    TWILIO_AUTH_TOKEN: "tok",
    TWILIO_FROM_NUMBER: "+447700900000",
    OWNER_PHONE: OWNER,
    ELEVENLABS_API_KEY: "k",
    ELEVENLABS_AGENT_ID: "agent_jarvis",
  } as unknown as Env;
}
const ctx = { waitUntil: (p: Promise<unknown>) => p.catch(() => undefined), passThroughOnException() {} } as unknown as ExecutionContext;

async function call(from: string, agents: string[]): Promise<void> {
  const url = "http://internal.local/calls/inbound";
  const params = { CallSid: "CA1", From: from, To: "+447700900000" };
  const sig = await twilioSignature(url, params, "tok");
  const original = globalThis.fetch;
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const u = String(input);
    if (u.includes("/convai/agents?")) return new Response(JSON.stringify({ agents: [{ agent_id: "agent_asg", name: "ASG Receptionist" }] }));
    if (u.includes("register-call")) {
      agents.push((JSON.parse(String(init?.body)) as { agent_id: string }).agent_id);
      return new Response("<Response><Connect/></Response>");
    }
    return new Response("{}");
  }) as typeof fetch;
  try {
    const res = await route(
      new Request(url, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded", "X-Twilio-Signature": sig }, body: new URLSearchParams(params).toString() }),
      env(),
      ctx,
    );
    expect(res.status).toBe(200);
  } finally {
    globalThis.fetch = original;
  }
}

describe("ASG line", () => {
  it("sends a stranger to the ASG agent", async () => {
    const agents: string[] = [];
    await call("+447700900222", agents);
    expect(agents[0]).toBe("agent_asg");
  });
  it("keeps JARVIS for the owner", async () => {
    const agents: string[] = [];
    await call(OWNER, agents);
    expect(agents).not.toContain("agent_asg");
    expect(agents[0]).toBe("agent_jarvis");
  });
});
