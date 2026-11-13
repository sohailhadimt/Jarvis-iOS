import { describe, expect, it } from "vitest";
import { twilioSignature } from "../src/calls";
import { route } from "../src/routes";
import type { Env } from "../src/types";

function env(): Env {
  const statement = {
    bind() { return statement; },
    async all() { return { results: [], success: true, meta: {} }; },
    async first() { return null; },
    async run() { return { success: true, meta: { changes: 1 } }; },
  };
  return {
    JARVIS_APP_TOKEN: "secret-token",
    DB: { prepare: () => statement } as unknown as D1Database,
    TWILIO_ACCOUNT_SID: "ACexampleaccountsid000000000000",
    TWILIO_AUTH_TOKEN: "twilio-auth-token-example",
    TWILIO_FROM_NUMBER: "+447700900000",
    ELEVENLABS_API_KEY: "elevenlabs-key-example-value",
    ELEVENLABS_AGENT_ID: "agent_jarvis",
    ASG_AGENT_ID: "agent_asg",
    OWNER_PHONE: "+447700900999",
  };
}

const ctx = { waitUntil: (p: Promise<unknown>) => void p.catch(() => undefined), passThroughOnException() {}, props: {} } as ExecutionContext;

async function ring(e: Env, from: string): Promise<string[]> {
  const params = { CallSid: "CA1", From: from, To: "+447700900000" };
  const url = "https://jarvis-backend.jarvis-hadi.workers.dev/calls/inbound";
  const sig = await twilioSignature(url, params, "twilio-auth-token-example");
  const agents: string[] = [];
  const original = globalThis.fetch;
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    if (String(input).includes("register-call")) {
      agents.push(String((JSON.parse(String(init?.body ?? "{}")) as { agent_id?: string }).agent_id));
      return new Response("<Response><Connect/></Response>", { status: 200 });
    }
    return new Response("{}", { status: 200 });
  }) as typeof fetch;
  try {
    const req = new Request("http://internal.local/calls/inbound", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded", "X-Twilio-Signature": sig },
      body: new URLSearchParams(params).toString(),
    });
    const res = await route(req, e, ctx);
    expect(res.status).toBe(200);
  } finally {
    globalThis.fetch = original;
  }
  return agents;
}

describe("ASG line", () => {
  it("sends a stranger to the ASG receptionist agent", async () => {
    expect(await ring(env(), "+447700900123")).toEqual(["agent_asg"]);
  });
  it("keeps the owner on JARVIS", async () => {
    const agents = await ring(env(), "+447700900999");
    expect(agents).not.toContain("agent_asg");
  });
  it("sends everyone to JARVIS when ASG_LINE is off", async () => {
    const e = env();
    e.ASG_LINE = "off";
    expect(await ring(e, "+447700900123")).not.toContain("agent_asg");
  });
  it("refuses a callback without consent", async () => {
    const res = await route(
      new Request("https://jarvis.test/asg/callback", {
        method: "POST",
        headers: { authorization: "Bearer secret-token", "content-type": "application/json" },
        body: JSON.stringify({ to: "+447700900123" }),
      }),
      env(),
      ctx,
    );
    expect(res.status).toBe(400);
  });
});
