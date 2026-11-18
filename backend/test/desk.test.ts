import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { clearElevenLabsTelephonyCache, twilioSignature } from "../src/calls";
import { ASK_WINDOW_MS, BUSY_LINE, SHARE_MS, deskAgentBody, deskClock, deskKey, deskPrompt, deskToolConfigs } from "../src/desk";
import { route } from "../src/routes";
import type { Env } from "../src/types";
import { sqliteD1 } from "./helpers/sqlite-d1";

const OWNER = "+15557654321";
const LINE = "+447700900000";
const CALLER = "+447700900123";
const ORIGIN = "https://jarvis.test";
const bearer = { authorization: "Bearer secret-token", "content-type": "application/json" };

type Seen = { url: string; body: string };

function ctx(): ExecutionContext {
  return { waitUntil() {}, passThroughOnException() {}, props: {} } as unknown as ExecutionContext;
}

let clock = 0;
let onSleep: (() => Promise<void> | void) | null = null;
const realClock = { ...deskClock };
let seen: Seen[] = [];
const originalFetch = globalThis.fetch;

function setup(): { env: Env; raw: ReturnType<typeof sqliteD1>["raw"] } {
  const { db, raw } = sqliteD1();
  const env: Env = {
    JARVIS_APP_TOKEN: "secret-token",
    TWILIO_ACCOUNT_SID: "ACexampleaccountsid000000000000",
    TWILIO_AUTH_TOKEN: "twilio-auth-token-example",
    TWILIO_FROM_NUMBER: LINE,
    ELEVENLABS_API_KEY: "elevenlabs-key-example-value",
    ELEVENLABS_AGENT_ID: "agent_example",
    ELEVENLABS_FORCE_POLLY: "false",
    OWNER_PHONE: OWNER,
    DB: db,
  } as Env;
  return { env, raw };
}

function twiml(): string {
  return '<?xml version="1.0" encoding="UTF-8"?><Response><Connect><Stream url="wss://api.elevenlabs.io/v1/convai/conversation"><Parameter name="conversation_id" value="conv_1"/></Stream></Connect></Response>';
}

beforeEach(() => {
  clearElevenLabsTelephonyCache();
  clock = Date.parse("2026-11-15T18:00:00.000Z");
  onSleep = null;
  seen = [];
  deskClock.now = () => clock;
  deskClock.sleep = async (ms: number) => {
    clock += ms;
    if (onSleep) await onSleep();
  };
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    seen.push({ url, body: String(init?.body ?? "") });
    if (url.includes("register-call")) return new Response(JSON.stringify(twiml()), { status: 200 });
    if (url.includes("/Messages.json")) return new Response(JSON.stringify({ sid: "SM1", status: "queued" }), { status: 201 });
    if (url.includes("api.elevenlabs.io/v1/convai/agents/agent_example")) return new Response(JSON.stringify({ conversation_config: {} }), { status: 200 });
    return new Response("{}", { status: 404 });
  }) as typeof fetch;
});

afterEach(() => {
  globalThis.fetch = originalFetch;
  deskClock.now = realClock.now;
  deskClock.sleep = realClock.sleep;
});

async function inbound(env: Env, from: string): Promise<Response> {
  const params = { CallSid: "CA" + from.replace(/\D/g, ""), From: from, To: LINE, Called: LINE };
  const url = `${ORIGIN}/calls/inbound`;
  const signature = await twilioSignature(url, params, "twilio-auth-token-example");
  return route(
    new Request(url, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded", "X-Twilio-Signature": signature },
      body: new URLSearchParams(params).toString(),
    }),
    env,
    ctx(),
  );
}

function registered(): { agent_id: string; conversation_initiation_client_data: { dynamic_variables: Record<string, string> } } {
  const hit = seen.find((s) => s.url.includes("register-call"));
  return JSON.parse(hit?.body ?? "{}");
}

function smsTo(number: string): string[] {
  return seen
    .filter((s) => s.url.includes("/Messages.json"))
    .map((s) => new URLSearchParams(s.body))
    .filter((p) => p.get("To") === number)
    .map((p) => p.get("Body") ?? "");
}

function seedCall(raw: ReturnType<typeof sqliteD1>["raw"], id = "call_desk1"): string {
  raw.prepare(
    `INSERT INTO outbound_calls (id, contact_name, to_number, brief, status, twilio_sid, conversation_id, transcript_json, summary, error, created_at, updated_at)
     VALUES (?, 'Incoming call', ?, 'Screen this call', 'screening', 'CA1', NULL, '[]', NULL, NULL, ?, ?)`,
  ).run(id, CALLER, new Date(clock).toISOString(), new Date(clock).toISOString());
  return id;
}

async function tool(env: Env, name: string, body: Record<string, unknown>): Promise<Record<string, unknown>> {
  const response = await route(
    new Request(`${ORIGIN}/desk/tool/${name}`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-jarvis-desk": await deskKey(env) },
      body: JSON.stringify(body),
    }),
    env,
    ctx(),
  );
  expect(response.status).toBe(200);
  return (await response.json()) as Record<string, unknown>;
}

async function decideInApp(env: Env, raw: ReturnType<typeof sqliteD1>["raw"], allow: boolean, answer = ""): Promise<Response> {
  const row = raw.prepare("SELECT id FROM owner_requests ORDER BY created_at DESC LIMIT 1").get() as { id: string };
  return route(
    new Request(`${ORIGIN}/calls/requests/${row.id}`, { method: "POST", headers: bearer, body: JSON.stringify({ allow, answer }) }),
    env,
    ctx(),
  );
}

describe("call desk routing", () => {
  it("keeps the owner bypass: Sir still gets the main George agent and no screening card", async () => {
    const { env, raw } = setup();
    raw.prepare("INSERT INTO runtime_state (key, value, updated_at) VALUES ('desk_agent_id', 'agent_desk', 'now')").run();
    const response = await inbound(env, OWNER);
    expect(response.status).toBe(200);
    expect(await response.text()).toBe(twiml());
    expect(registered().agent_id).toBe("agent_example");
    expect(raw.prepare("SELECT COUNT(*) AS n FROM call_screen").get()).toEqual({ n: 0 });
  });

  it("sends every other caller to the desk agent with the call id for its tools, and keeps the card", async () => {
    const { env, raw } = setup();
    raw.prepare("INSERT INTO runtime_state (key, value, updated_at) VALUES ('desk_agent_id', 'agent_desk', 'now')").run();
    const response = await inbound(env, CALLER);
    const body = await response.text();
    expect(body).toBe(twiml());
    expect(body).not.toContain("<Say");
    const payload = registered();
    expect(payload.agent_id).toBe("agent_desk");
    const card = raw.prepare("SELECT call_id FROM call_screen").get() as { call_id: string };
    expect(payload.conversation_initiation_client_data.dynamic_variables.jarvis_call_id).toBe(card.call_id);
  });

  it("builds a George agent on μ-law with the four tools and the busy line", () => {
    const tools = deskToolConfigs(ORIGIN, "k");
    expect(Object.keys(tools).sort()).toEqual(["ask_owner", "check_owner_answer", "save_asg_lead", "take_message"]);
    const ask = tools.ask_owner as { api_schema: { url: string; request_body_schema: { properties: Record<string, { dynamic_variable?: string }> } }; response_timeout_secs: number };
    expect(ask.api_schema.url).toBe(`${ORIGIN}/desk/tool/ask_owner`);
    expect(ask.api_schema.request_body_schema.properties.call_id.dynamic_variable).toBe("jarvis_call_id");
    expect(ask.response_timeout_secs).toBeGreaterThan(20);
    const agent = deskAgentBody(["t1"]) as { conversation_config: { tts: Record<string, string>; asr: Record<string, string>; agent: { first_message: string } } };
    expect(agent.conversation_config.tts.agent_output_audio_format).toBe("ulaw_8000");
    expect(agent.conversation_config.tts.voice_id).toBe("JBFqnCBsd6RMkjVDRZzb");
    expect(agent.conversation_config.asr.user_input_audio_format).toBe("ulaw_8000");
    expect(agent.conversation_config.agent.first_message).toBe("{{opening_line}}");
    expect(deskPrompt()).toContain(BUSY_LINE);
    expect(deskPrompt()).toContain("{{brief}}");
  });

  it("refuses a tool call without the desk key", async () => {
    const { env } = setup();
    const response = await route(
      new Request(`${ORIGIN}/desk/tool/ask_owner`, { method: "POST", headers: { "content-type": "application/json" }, body: "{}" }),
      env,
      ctx(),
    );
    expect(response.status).toBe(401);
  });
});

describe("asking Sir first", () => {
  it("blocks a question about him until he answers, then gives the busy line", async () => {
    const { env, raw } = setup();
    const call = seedCall(raw);
    const first = await tool(env, "ask_owner", { call_id: call, kind: "info", question: "Is he married?", caller_name: "Dan" });
    expect(first.status).toBe("pending");
    expect(first.answer).toBeUndefined();
    const ownerTexts = smsTo(OWNER);
    expect(ownerTexts.length).toBe(1);
    expect(ownerTexts[0]).toContain("Is he married?");
    const second = await tool(env, "check_owner_answer", { call_id: call, request_id: first.request_id });
    expect(second.status).toBe("no_answer");
    expect(second.say).toBe(BUSY_LINE);
    expect(second.answer).toBeUndefined();
    expect(clock - Date.parse("2026-11-15T18:00:00.000Z")).toBeLessThanOrEqual(ASK_WINDOW_MS + 2_000);
    expect(smsTo(CALLER)).toEqual([]);
    const late = await decideInApp(env, raw, true, "Yes");
    expect(late.status).toBe(409);
  });

  it("shares only what Sir texts back with YES", async () => {
    const { env, raw } = setup();
    const call = seedCall(raw);
    onSleep = async () => {
      if (clock - Date.parse("2026-11-15T18:00:00.000Z") < 5_000) return;
      onSleep = null;
      const params = { From: OWNER, To: LINE, Body: "YES tell him I'm in a meeting until five", MessageSid: "SM9" };
      const url = `${ORIGIN}/calls/sms`;
      const signature = await twilioSignature(url, params, "twilio-auth-token-example");
      await route(
        new Request(url, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded", "X-Twilio-Signature": signature }, body: new URLSearchParams(params).toString() }),
        env,
        ctx(),
      );
    };
    const result = await tool(env, "ask_owner", { call_id: call, kind: "info", question: "Is he free today?" });
    expect(result.status).toBe("allowed");
    expect(result.answer).toBe("tell him I'm in a meeting until five");
  });

  it("location deny: busy line, no link, nothing texted to the caller", async () => {
    const { env, raw } = setup();
    const call = seedCall(raw);
    onSleep = async () => {
      onSleep = null;
      const response = await decideInApp(env, raw, false);
      expect(response.status).toBe(200);
    };
    const result = await tool(env, "ask_owner", { call_id: call, kind: "location", question: "Where is he?" });
    expect(result.status).toBe("denied");
    expect(result.say).toBe(BUSY_LINE);
    expect(raw.prepare("SELECT COUNT(*) AS n FROM location_shares").get()).toEqual({ n: 0 });
    expect(smsTo(CALLER)).toEqual([]);
  });

  it("location allow: texts the caller a link that shows his live position, then expires after 10 minutes", async () => {
    const { env, raw } = setup();
    const call = seedCall(raw);
    let decided: Record<string, unknown> = {};
    onSleep = async () => {
      onSleep = null;
      const response = await decideInApp(env, raw, true);
      decided = (await response.json()) as Record<string, unknown>;
    };
    const result = await tool(env, "ask_owner", { call_id: call, kind: "location", question: "Where is he?" });
    expect(result.status).toBe("allowed");
    expect(result.link_sent).toBe(true);
    expect(decided.share_expires_at).toBeTruthy();
    const texts = smsTo(CALLER);
    expect(texts.length).toBe(1);
    const link = /https:\/\/jarvis\.test\/l\/([A-Za-z0-9_-]{30,})/.exec(texts[0]);
    expect(link).not.toBeNull();
    const token = link![1];
    const share = raw.prepare("SELECT created_at, expires_at FROM location_shares WHERE token = ?").get(token) as { created_at: string; expires_at: string };
    expect(Date.parse(share.expires_at) - Date.parse(share.created_at)).toBe(SHARE_MS);

    const update = await route(
      new Request(`${ORIGIN}/location/update`, { method: "POST", headers: bearer, body: JSON.stringify({ lat: 51.5045, lng: -0.0865, accuracy: 12 }) }),
      env,
      ctx(),
    );
    expect(((await update.json()) as { active: number }).active).toBe(1);
    const page = await route(new Request(`${ORIGIN}/l/${token}`), env, ctx());
    expect(page.status).toBe(200);
    expect(await page.text()).toContain("live location");
    const where = await route(new Request(`${ORIGIN}/l/${token}/where`), env, ctx());
    expect(await where.json()).toMatchObject({ expired: false, lat: 51.5045, lng: -0.0865 });
    const guess = await route(new Request(`${ORIGIN}/l/${"x".repeat(32)}/where`), env, ctx());
    expect(guess.status).toBe(404);

    clock = Date.parse(share.created_at) + SHARE_MS + 1_000;
    const after = await route(new Request(`${ORIGIN}/l/${token}/where`), env, ctx());
    expect(after.status).toBe(410);
    expect(await after.json()).toEqual({ expired: true });
    const expiredPage = await route(new Request(`${ORIGIN}/l/${token}`), env, ctx());
    expect(await expiredPage.text()).toContain("expired");
    const cleared = raw.prepare("SELECT lat, lng FROM location_shares WHERE token = ?").get(token);
    expect(cleared).toEqual({ lat: null, lng: null });
    const lateUpdate = await route(
      new Request(`${ORIGIN}/location/update`, { method: "POST", headers: bearer, body: JSON.stringify({ lat: 51.5, lng: -0.1 }) }),
      env,
      ctx(),
    );
    expect(((await lateUpdate.json()) as { active: number }).active).toBe(0);
  });

  it("takes a message and passes it to Sir by text when no push device is set", async () => {
    const { env, raw } = setup();
    const call = seedCall(raw);
    const result = await tool(env, "take_message", { call_id: call, caller_name: "Dan", callback_number: "07700 900123", reason: "Invoice", message: "Please call back about the invoice." });
    expect(result.ok).toBe(true);
    expect(smsTo(OWNER)[0]).toContain("Please call back about the invoice.");
    const row = raw.prepare("SELECT summary, contact_name FROM outbound_calls WHERE id = ?").get(call) as { summary: string; contact_name: string };
    expect(row.contact_name).toBe("Dan");
  });

  it("saves an ASG enquiry as a lead", async () => {
    const { env, raw } = setup();
    const call = seedCall(raw);
    const result = await tool(env, "save_asg_lead", { call_id: call, caller_name: "Amy", company: "Acme", needs: "Office cleaning quote", do_not_contact: "no" });
    expect(result.ok).toBe(true);
    expect(raw.prepare("SELECT caller_name, company, phone FROM asg_leads").get()).toEqual({ caller_name: "Amy", company: "Acme", phone: CALLER });
  });

  it("will not run desk tools on Sir's own call", async () => {
    const { env, raw } = setup();
    raw.prepare(
      `INSERT INTO outbound_calls (id, contact_name, to_number, brief, status, twilio_sid, conversation_id, transcript_json, summary, error, created_at, updated_at)
       VALUES ('call_own', 'Master Hadi', ?, 'Owner', 'in_progress', 'CA2', NULL, '[]', NULL, NULL, 'x', 'x')`,
    ).run(OWNER);
    const result = await tool(env, "ask_owner", { call_id: "call_own", kind: "info", question: "?" });
    expect(result.ok).toBe(false);
  });
});
