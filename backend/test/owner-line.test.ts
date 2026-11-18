// @ts-nocheck -- uses the Node SQLite helper.
import { afterEach, describe, expect, it, vi } from "vitest";
import { clearElevenLabsTelephonyCache, twilioSignature } from "../src/calls";
import { isOwnerCaller } from "../src/hangup";
import { OWNER_AGENT_VERSION, handleOwnerTool, ownerGreeting, ownerKey, ownerToolConfigs, ownerAgentBody } from "../src/owner-agent";
import { route } from "../src/routes";
import { sqliteD1 } from "./helpers/sqlite-d1";

const signedInbound = "https://jarvis-backend.jarvis-hadi.workers.dev/calls/inbound";
const OWNER = "+447700900555";
const TWIML =
  '<?xml version="1.0" encoding="UTF-8"?><Response><Connect><Stream url="wss://api.elevenlabs.io/v1/convai/conversation?agent_id=x"/></Connect></Response>';

function env(extra = {}) {
  const { db, raw } = sqliteD1();
  return {
    env: {
      DB: db,
      JARVIS_APP_TOKEN: "secret-token",
      TWILIO_ACCOUNT_SID: "ACexampleaccountsid000000000000",
      TWILIO_AUTH_TOKEN: "twilio-auth-token-example",
      TWILIO_FROM_NUMBER: "+447700900000",
      ELEVENLABS_API_KEY: "elevenlabs-key-example-value",
      ELEVENLABS_AGENT_ID: "agent_main",
      ELEVENLABS_FORCE_POLLY: "false",
      OWNER_PHONE: OWNER,
      ...extra,
    },
    raw,
  };
}

function ctx() {
  const jobs = [];
  return {
    ctx: { waitUntil: (p) => jobs.push(Promise.resolve(p).catch(() => undefined)), passThroughOnException() {}, props: {} },
    done: () => Promise.all(jobs),
  };
}

async function ring(e, from: string, wait = true) {
  const params = { CallSid: `CA${Math.random().toString(16).slice(2, 12)}`, From: from, To: "+447700900000", Called: "+447700900000" };
  const signature = await twilioSignature(signedInbound, params, "twilio-auth-token-example");
  const req = new Request("http://internal.local/calls/inbound", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded", "X-Twilio-Signature": signature },
    body: new URLSearchParams(params).toString(),
  });
  const seen = [];
  vi.stubGlobal("fetch", async (input, init) => {
    const url = String(input);
    seen.push({ url, body: String(init?.body ?? "") });
    if (url.includes("register-call")) return new Response(JSON.stringify(TWIML), { status: 200 });
    return new Response("{}", { status: 200 });
  });
  const { ctx: c, done } = ctx();
  const response = await route(req, e, c);
  if (wait) await done();
  const reg = seen.find((s) => s.url.includes("register-call"));
  return { response, payload: reg ? JSON.parse(reg.body) : null, seen };
}

function seedAgent(raw) {
  raw.prepare("INSERT INTO runtime_state (key, value, updated_at) VALUES (?, ?, ?)").run("owner_agent_id", "agent_personal", "2026-11-16T00:00:00Z");
  raw
    .prepare("INSERT INTO runtime_state (key, value, updated_at) VALUES (?, ?, ?)")
    .run("owner_agent_version", `${OWNER_AGENT_VERSION}|https://jarvis-backend.jarvis-hadi.workers.dev`, "2026-11-16T00:00:00Z");
}

afterEach(() => {
  vi.unstubAllGlobals();
  clearElevenLabsTelephonyCache();
});

describe("Sir ringing his own JARVIS line", () => {
  it("matches his number by caller ID in every format, and nothing else", () => {
    for (const form of ["+447700900555", "07700 900555", "447700900555", "0044 7700 900555", "+44 (0)7700 900555", "+4407700900555"]) {
      expect(isOwnerCaller(form, OWNER), form).toBe(true);
    }
    expect(isOwnerCaller("+447700900556", OWNER)).toBe(false);
    expect(isOwnerCaller("anonymous", OWNER)).toBe(false);
    expect(isOwnerCaller("", OWNER)).toBe(false);
  });

  it("greets him by time of day in London", () => {
    expect(ownerGreeting(new Date("2026-11-16T08:00:00Z"))).toBe("Good morning, Sir. What can I do for you?");
    expect(ownerGreeting(new Date("2026-11-16T14:00:00Z"))).toBe("Good afternoon, Sir. What can I do for you?");
    expect(ownerGreeting(new Date("2026-11-16T20:55:00Z"))).toBe("Good evening, Sir. What can I do for you?");
    expect(ownerGreeting(new Date("2026-07-16T22:30:00Z"))).toBe("Good evening, Sir. What can I do for you?");
  });

  it("hands him to the personal agent with the greeting, his context and a call id for tools", async () => {
    const { env: e, raw } = env();
    seedAgent(raw);
    const { response, payload } = await ring(e, "07700 900555");
    expect(response.status).toBe(200);
    expect(await response.text()).toBe(TWIML);
    expect(payload.agent_id).toBe("agent_personal");
    const vars = payload.conversation_initiation_client_data.dynamic_variables;
    expect(vars.opening_line).toMatch(/^Good (morning|afternoon|evening), Sir\. What can I do for you\?$/);
    expect(vars.contact_name).toBe("Master Hadi");
    expect(vars.jarvis_call_id).toMatch(/^call_/);
    expect(typeof vars.owner_context).toBe("string");
    expect(vars.now_london).toBeTruthy();
    expect(payload.conversation_initiation_client_data.conversation_config_override).toBeUndefined();
    const row = raw.prepare("SELECT contact_name FROM outbound_calls WHERE id = ?").get(vars.jarvis_call_id);
    expect(row.contact_name).toBe("Master Hadi");
    expect(raw.prepare("SELECT COUNT(*) AS n FROM call_screen").get().n).toBe(0);
  });

  it("without the personal agent, forces the owner prompt onto the main agent instead of the screening greeting", async () => {
    const { env: e } = env();
    const { payload } = await ring(e, OWNER);
    expect(payload.agent_id).toBe("agent_main");
    const override = payload.conversation_initiation_client_data.conversation_config_override;
    expect(override.agent.first_message).toMatch(/Sir\. What can I do for you\?$/);
    expect(override.agent.prompt.prompt).toContain("caller ID");
    expect(override.agent.prompt.prompt).not.toContain("{{");
  });

  it("a stranger saying it's Sir still gets the desk/screening path, never the personal agent", async () => {
    const { env: e, raw } = env();
    seedAgent(raw);
    const { payload } = await ring(e, "+447700900999", false);
    expect(payload.agent_id).not.toBe("agent_personal");
    const vars = payload.conversation_initiation_client_data.dynamic_variables;
    expect(vars.contact_name).not.toBe("Master Hadi");
    expect(vars.owner_context).toBeUndefined();
  });
});

describe("personal agent tools", () => {
  it("tools point at the public base with the owner key and carry the call id", async () => {
    const configs = ownerToolConfigs("https://jarvis-backend.jarvis-hadi.workers.dev", "k");
    expect(Object.keys(configs).sort()).toEqual(["get_weather", "lookup_contact", "schedule_call_to_owner", "send_camera_link", "send_sms_to_owner", "web_search"]);
    expect((configs.web_search as Record<string, unknown>).disable_interruptions).toBe(true);
    for (const c of Object.values(configs)) {
      expect(() => new URL(c.api_schema.url)).not.toThrow();
      expect(c.api_schema.url.startsWith("https://jarvis-backend.jarvis-hadi.workers.dev/owner/tool/")).toBe(true);
      expect(c.api_schema.request_body_schema.properties.call_id.dynamic_variable).toBe("jarvis_call_id");
    }
    const body = ownerAgentBody(["t1"]);
    expect(body.conversation_config.agent.first_message).toBe("{{opening_line}}");
    expect(body.conversation_config.agent.prompt.tool_ids).toEqual(["t1"]);
  });

  async function callTool(e, name, body, key?) {
    return handleOwnerTool(
      new Request(`https://x/owner/tool/${name}`, {
        method: "POST",
        headers: { "content-type": "application/json", "x-jarvis-owner": key ?? (await ownerKey(e)) },
        body: JSON.stringify(body),
      }),
      e,
      `/owner/tool/${name}`,
    );
  }

  function seedCall(raw, id, number, name = "Master Hadi") {
    raw
      .prepare(
        `INSERT INTO outbound_calls (id, contact_name, to_number, brief, status, twilio_sid, conversation_id, transcript_json, summary, error, created_at, updated_at)
         VALUES (?, ?, ?, 'x', 'in_progress', NULL, NULL, '[]', NULL, NULL, '2026-11-16T20:00:00Z', '2026-11-16T20:00:00Z')`,
      )
      .run(id, name, number);
  }

  it("refuses a wrong key and any call that is not from Sir's mobile", async () => {
    const { env: e, raw } = env();
    seedCall(raw, "call_stranger1", "+447700900999", "Caller");
    expect((await callTool(e, "get_weather", { call_id: "call_x" }, "wrong")).status).toBe(401);
    const res = await (await callTool(e, "lookup_contact", { call_id: "call_stranger1", name: "Mum" })).json();
    expect(res.ok).toBe(false);
  });

  it("answers weather on Sir's call from Open-Meteo", async () => {
    const { env: e, raw } = env();
    seedCall(raw, "call_owner1", OWNER);
    vi.stubGlobal("fetch", async (input) => {
      const url = String(input);
      if (url.includes("geocoding-api")) {
        return Response.json({ results: [{ name: "Ashford", latitude: 51.14, longitude: 0.87, country_code: "GB", country: "United Kingdom", admin1: "England", admin2: "Kent", timezone: "Europe/London", population: 60000 }] });
      }
      if (url.includes("api.open-meteo.com")) {
        return Response.json({
          current: { temperature_2m: 7.2, apparent_temperature: 4.1, weather_code: 3, wind_speed_10m: 11 },
          daily: { time: ["2026-11-16", "2026-11-17"], weather_code: [3, 61], temperature_2m_max: [9, 10], temperature_2m_min: [3, 5], precipitation_probability_max: [20, 80] },
        });
      }
      return new Response("no", { status: 500 });
    });
    const res = await (await callTool(e, "get_weather", { call_id: "call_owner1", place: "Ashford", when: "tomorrow" })).json();
    expect(res.ok).toBe(true);
    expect(res.weather).toContain("Ashford, Kent");
    expect(res.weather).toContain("light rain");
    expect(res.weather).toContain("80% chance of rain");
  });
  it("books a wake-up call to Sir from his call, once, and never for a stranger", async () => {
    const { env: e, raw } = env();
    seedCall(raw, "call_owner2", OWNER);
    seedCall(raw, "call_stranger2", "+447700900998", "Caller");
    const no = await (await callTool(e, "schedule_call_to_owner", { call_id: "call_stranger2", when: "half 12" })).json();
    expect(no.ok).toBe(false);
    const first = await (await callTool(e, "schedule_call_to_owner", { call_id: "call_owner2", when: "in 2 hours" })).json();
    expect(first.ok).toBe(true);
    expect(first.say).toMatch(/^Booked, Sir, I'll ring you at \d{1,2}:\d{2}/);
    await callTool(e, "schedule_call_to_owner", { call_id: "call_owner2", when: "in 2 hours" });
    const rows = raw.prepare("SELECT phone, via, task FROM sms_reminders WHERE status = 'pending'").all();
    expect(rows).toHaveLength(1);
    expect(rows[0].via).toBe("call");
    expect(rows[0].task).toBe("time to wake up");
  });
});

describe("texting Sir from his call", () => {
  function seedOwnerCall(raw, id, number, transcript = "[]") {
    raw
      .prepare(
        `INSERT INTO outbound_calls (id, contact_name, to_number, brief, status, twilio_sid, conversation_id, transcript_json, summary, error, created_at, updated_at)
         VALUES (?, 'Master Hadi', ?, 'Owner on his JARVIS line', 'in_progress', NULL, NULL, ?, NULL, NULL, '2026-11-16T23:00:00Z', '2026-11-16T23:00:00Z')`,
      )
      .run(id, number, transcript);
  }
  function twilio() {
    const sms = [];
    vi.stubGlobal("fetch", async (input, init) => {
      const url = String(input);
      if (url.includes("Messages.json")) {
        sms.push(new URLSearchParams(String(init?.body ?? "")));
        return Response.json({ sid: "SM0123456789abcdef0123456789abcdef", status: "queued" }, { status: 201 });
      }
      if (url.includes("chat/completions")) return Response.json({ choices: [{ message: { role: "assistant", content: "AK-74 build: Muzzle X, Barrel Y." } }] });
      return new Response("{}", { status: 200 });
    });
    return sms;
  }
  async function tool(e, body) {
    return (
      await handleOwnerTool(
        new Request("https://x/owner/tool/send_sms_to_owner", {
          method: "POST",
          headers: { "content-type": "application/json", "x-jarvis-owner": await ownerKey(e) },
          body: JSON.stringify(body),
        }),
        e,
        "/owner/tool/send_sms_to_owner",
      )
    ).json();
  }

  it("is a tool on the personal agent, and the prompt says JARVIS can text", async () => {
    const configs = ownerToolConfigs("https://jarvis-backend.jarvis-hadi.workers.dev", "k");
    expect(configs.send_sms_to_owner.api_schema.request_body_schema.required).toEqual(["call_id", "text"]);
    expect(configs.send_sms_to_owner.api_schema.request_body_schema.properties.to).toBeUndefined();
    const { ownerAgentPrompt, ownerFallbackPrompt } = await import("../src/owner-agent");
    expect(ownerAgentPrompt()).toContain("send_sms_to_owner");
    expect(ownerAgentPrompt()).toContain("Never say you cannot text");
    expect(ownerFallbackPrompt({ now_london: "x", owner_context: "y" })).toContain("texted to his phone automatically");
  });

  it("texts only Sir's number, split into up to three texts, and logs them to his thread", async () => {
    const { env: e, raw } = env();
    seedOwnerCall(raw, "call_owner2", OWNER);
    const sms = twilio();
    const long = Array.from({ length: 12 }, (_, i) => `Line ${i + 1}: attachment choice number ${i + 1} for the build.`).join(" ");
    const res = await tool(e, { call_id: "call_owner2", text: long, to: "+447700900999" });
    expect(res.ok).toBe(true);
    expect(sms.length).toBeGreaterThanOrEqual(2);
    expect(sms.length).toBeLessThanOrEqual(3);
    for (const form of sms) {
      expect(form.get("To")).toBe(OWNER);
      expect(form.get("Body").length).toBeLessThanOrEqual(306);
    }
    const turns = raw.prepare("SELECT COUNT(*) AS n FROM sms_turns WHERE phone = ? AND role = 'assistant'").get(OWNER);
    expect(turns.n).toBe(sms.length);
  });

  it("refuses on a call that is not from Sir's number", async () => {
    const { env: e, raw } = env();
    seedOwnerCall(raw, "call_fake1", "+447700900999");
    const sms = twilio();
    const res = await tool(e, { call_id: "call_fake1", text: "hello" });
    expect(res.ok).toBe(false);
    expect(sms.length).toBe(0);
  });

  it("after the call, texts what he asked for if nothing was texted during it, once", async () => {
    const { env: e, raw } = env({ GROQ_API_KEY: "g" });
    seedOwnerCall(raw, "call_owner3", OWNER, JSON.stringify([
      { role: "assistant", text: "Good evening, Sir." },
      { role: "them", text: "Give me a Modern Warfare gun build and text me the build" },
      { role: "assistant", text: "AK-74 with Muzzle X and Barrel Y." },
    ]));
    const sms = twilio();
    const { ownerCallFollowUp } = await import("../src/owner-agent");
    expect(await ownerCallFollowUp(e, "call_owner3")).toBe("sent");
    expect(sms[0].get("To")).toBe(OWNER);
    expect(sms[0].get("Body")).toContain("AK-74");
    expect(await ownerCallFollowUp(e, "call_owner3")).toBe("skipped");
  });
});
