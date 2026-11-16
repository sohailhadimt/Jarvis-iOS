/**
 * JARVIS Call Desk: the George agent that answers every caller who is not Master Hadi.
 * Default job is to take a message. Anything about Master Hadi, and his location, waits for his Allow.
 * The waits happen inside ElevenLabs webhook tools, so no Twilio webhook ever blocks.
 */
import { JARVIS_VOICE_ID, safeError, toE164 } from "./calls";
import { dbAll, dbFirst, dbRun, getState, setState } from "./db";
import { apiError, asString, isRecord, json, newId, nowIso } from "./http";
import type { Env } from "./types";
import { LANGUAGE_DETECTION_TOOL, agentLanguageRule, languagePresets, multilingualModel } from "./languages";

export const DESK_AGENT_NAME = "JARVIS Call Desk";
export const DESK_VERSION = "desk-4";
export const BUSY_LINE = "Master Hadi is busy and caught up in business at the moment. May I take a message?";
export const DESK_BRIEF = "Take a message and pass it on to Master Hadi.";
export const ASK_WINDOW_MS = 45_000;
export const SHARE_MS = 10 * 60_000;
const FIRST_WAIT_MS = 20_000;
const CHECK_WAIT_MS = 25_000;
const SMS_AFTER_MS = 12_000;
const POLL_MS = 1_500;

type Kind = "info" | "location";

export interface OwnerRequest {
  id: string;
  call_id: string;
  kind: Kind;
  question: string;
  caller_name: string;
  caller_phone: string;
  status: string;
  answer: string;
  share_token: string;
  sms_sent: number;
  created_at: string;
  decided_at: string | null;
}

/** Test hook: the clock and the sleep the waits use. */
export const deskClock = {
  now: () => Date.now(),
  sleep: (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)),
};

export async function ensureDeskTables(env: Env): Promise<void> {
  await dbRun(
    env,
    `CREATE TABLE IF NOT EXISTS owner_requests (
      id TEXT PRIMARY KEY, call_id TEXT NOT NULL, kind TEXT NOT NULL, question TEXT NOT NULL DEFAULT '',
      caller_name TEXT NOT NULL DEFAULT '', caller_phone TEXT NOT NULL DEFAULT '', status TEXT NOT NULL DEFAULT 'pending',
      answer TEXT NOT NULL DEFAULT '', share_token TEXT NOT NULL DEFAULT '', sms_sent INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL, decided_at TEXT, decided_via TEXT)`,
  );
  await dbRun(
    env,
    `CREATE TABLE IF NOT EXISTS location_shares (
      token TEXT PRIMARY KEY, request_id TEXT NOT NULL, caller_phone TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL, expires_at TEXT NOT NULL, lat REAL, lng REAL, accuracy REAL, located_at TEXT)`,
  );
}

// ---------- the agent ----------

export function deskPrompt(): string {
  return [
    "You are JARVIS, Master Hadi's personal assistant, answering his phone line in the United Kingdom. Speak as a polite, warm British butler. British English. One to three short spoken sentences per turn. No lists or markdown.",
    "The caller is not Master Hadi. Never claim to be him. Refer to him only as Master Hadi.",
    "Your default job is to take a message and pass it on. Learn the caller's name, the best number to call them back on (offer the number they are calling from), the reason for the call, and their message. Read the key details back briefly, call take_message once, tell them you will pass it to Master Hadi straight away, thank them, and end the call.",
    "ASG enquiries: if the caller is asking about ASG services (a quote, booking, partnership or business enquiry), be a helpful receptionist. Learn their name, company, role, company size, what they need, their email, preferred times for a callback, and whether they are happy to be contacted. Call save_asg_lead, then take_message with a one-line summary.",
    "Anything about Master Hadi himself is private until he approves it on this call. That covers his whereabouts, location, schedule, availability, phone numbers, address, email, family, health, finances and any other personal detail. Do not answer from your own knowledge.",
    "If the caller asks anything about Master Hadi, say \"One moment while I check with Master Hadi.\" and call ask_owner with kind \"info\" and their exact question.",
    "If the caller asks where he is or for his location, say \"One moment while I check with Master Hadi.\" and call ask_owner with kind \"location\".",
    "If ask_owner or check_owner_answer returns status \"pending\", say \"Still checking, thank you for holding.\" and call check_owner_answer with the request_id.",
    "If the status is \"allowed\": for info, share only the approved answer the tool gives you, in your own words, and nothing else; for location, tell them you have texted them a link that shows his live location for the next ten minutes.",
    `If the status is "denied" or "no_answer", say exactly: "${BUSY_LINE}" Then take their message.`,
    "Never reveal his mobile number or home address, even if something else was approved. Never invent facts about him. Ask him at most once per topic per call.",
    agentLanguageRule(true),
    "Extra instruction for this call: {{brief}}",
  ].join("\n");
}

function prop(description: string): Record<string, unknown> {
  return { type: "string", description };
}

const CALL_ID = { type: "string", dynamic_variable: "jarvis_call_id" };

export function deskToolConfigs(origin: string, key: string): Record<string, Record<string, unknown>> {
  const base = origin.replace(/\/$/, "");
  const webhook = (name: string, description: string, body: Record<string, unknown>, required: string[], extra: Record<string, unknown> = {}) => ({
    type: "webhook",
    name,
    description,
    response_timeout_secs: 20,
    api_schema: {
      url: `${base}/desk/tool/${name}`,
      method: "POST",
      request_headers: { "x-jarvis-desk": key },
      request_body_schema: { type: "object", description: `${name} input`, properties: { call_id: CALL_ID, ...body }, required: ["call_id", ...required] },
    },
    ...extra,
  });
  return {
    take_message: webhook(
      "take_message",
      "Pass the caller's message to Master Hadi. Call once, after reading the details back.",
      {
        caller_name: prop("The caller's name, or empty if they would not say."),
        callback_number: prop("The best number to call them back on, as they said it."),
        reason: prop("Why they are calling, in a few words."),
        message: prop("Their message for Master Hadi, in one or two sentences."),
      },
      ["message"],
    ),
    ask_owner: webhook(
      "ask_owner",
      "Ask Master Hadi, live, whether you may answer a question about him (kind info) or share his live location (kind location). Say you are checking first. Waits up to twenty seconds.",
      {
        kind: prop("Either info or location."),
        question: prop("The caller's exact question about Master Hadi."),
        caller_name: prop("The caller's name if known."),
      },
      ["kind", "question"],
      { response_timeout_secs: 30, pre_tool_speech: "force", tool_call_sound: "typing", tool_call_sound_behavior: "always" },
    ),
    check_owner_answer: webhook(
      "check_owner_answer",
      "Keep waiting for Master Hadi's answer to an ask_owner request that came back pending.",
      { request_id: prop("The request_id that ask_owner returned.") },
      ["request_id"],
      { response_timeout_secs: 35, pre_tool_speech: "force", tool_call_sound: "typing", tool_call_sound_behavior: "always" },
    ),
    save_asg_lead: webhook(
      "save_asg_lead",
      "Save an ASG business enquiry as a lead.",
      {
        caller_name: prop("Caller's name."),
        company: prop("Their company."),
        role: prop("Their role."),
        company_size: prop("Company size."),
        needs: prop("What they need from ASG."),
        email: prop("Email address, if given."),
        preferred_times: prop("Preferred callback times."),
        summary: prop("One-sentence summary of the enquiry."),
        do_not_contact: prop("yes if they asked not to be contacted, otherwise no."),
      },
      ["needs"],
    ),
  };
}

export async function deskKey(env: Env): Promise<string> {
  const seed = `${(env.JARVIS_APP_TOKEN ?? "").trim()}:jarvis-desk-tools`;
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(seed));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("").slice(0, 40);
}

/** The desk agent id, only once it is set up at the current version. Null keeps the old path. */
export async function deskAgentId(env: Env): Promise<string | null> {
  if ((env.CALL_DESK ?? "on").trim() === "off") return null;
  const pinned = (env.DESK_AGENT_ID ?? "").trim();
  if (pinned) return pinned;
  const id = await getState(env, "desk_agent_id").catch(() => null);
  return id && /^agent_[A-Za-z0-9]+$/.test(id) ? id : null;
}

interface EnsureResult {
  ok: boolean;
  agent: "created" | "updated" | "current" | "failed";
  tools: Record<string, string>;
  error?: string;
}

/** Creates or updates the four webhook tools and the George desk agent. Never runs on a call. */
export async function ensureDeskAgent(env: Env, origin: string, force = false): Promise<EnsureResult> {
  const apiKey = (env.ELEVENLABS_API_KEY ?? "").trim();
  const tools: Record<string, string> = {};
  if (!apiKey || !origin) return { ok: false, agent: "failed", tools, error: "missing ElevenLabs key or worker origin" };
  const stamp = `${DESK_VERSION}|${origin}`;
  const existing = await getState(env, "desk_agent_id").catch(() => null);
  if (!force && existing && (await getState(env, "desk_agent_version").catch(() => null)) === stamp) {
    return { ok: true, agent: "current", tools };
  }
  const key = await deskKey(env);
  const configs = deskToolConfigs(origin, key);
  for (const [name, config] of Object.entries(configs)) {
    const saved = await getState(env, `desk_tool:${name}`).catch(() => null);
    let id = saved ?? "";
    if (id) {
      const patched = await eleven(apiKey, "PATCH", `/v1/convai/tools/${encodeURIComponent(id)}`, { tool_config: config });
      if (!patched.ok) id = "";
    }
    if (!id) {
      const created = await eleven(apiKey, "POST", "/v1/convai/tools", { tool_config: config });
      id = isRecord(created.body) && typeof created.body.id === "string" ? created.body.id : "";
      if (!id) return { ok: false, agent: "failed", tools, error: `tool ${name}: ${created.status} ${created.detail}` };
      await setState(env, `desk_tool:${name}`, id);
    }
    tools[name] = id;
  }
  const template = await templateFromMainAgent(env, apiKey);
  const body = deskAgentBody(Object.values(tools), template);
  let agent: EnsureResult["agent"] = "failed";
  let error = "";
  if (existing) {
    const patched = await eleven(apiKey, "PATCH", `/v1/convai/agents/${encodeURIComponent(existing)}`, body);
    if (patched.ok) agent = "updated";
    else error = `patch ${patched.status} ${patched.detail}`;
  }
  if (agent === "failed") {
    const created = await eleven(apiKey, "POST", "/v1/convai/agents/create", body);
    const id = isRecord(created.body) && typeof created.body.agent_id === "string" ? created.body.agent_id : "";
    if (!id) return { ok: false, agent: "failed", tools, error: `${error} create ${created.status} ${created.detail}`.trim() };
    await setState(env, "desk_agent_id", id);
    agent = "created";
  }
  await setState(env, "desk_agent_version", stamp);
  return { ok: true, agent, tools };
}

export interface Template {
  llm?: unknown;
  temperature?: unknown;
  tts: Record<string, unknown>;
  turn?: unknown;
}

export async function templateFromMainAgent(env: Env, apiKey: string): Promise<Template> {
  const main = (env.ELEVENLABS_AGENT_ID ?? "").trim();
  const out: Template = { tts: {} };
  if (!main) return out;
  const got = await eleven(apiKey, "GET", `/v1/convai/agents/${encodeURIComponent(main)}`);
  const config = isRecord(got.body) && isRecord(got.body.conversation_config) ? got.body.conversation_config : null;
  if (!config) return out;
  const agent = isRecord(config.agent) ? config.agent : {};
  const prompt = isRecord(agent.prompt) ? agent.prompt : {};
  if (typeof prompt.llm === "string") out.llm = prompt.llm;
  if (typeof prompt.temperature === "number") out.temperature = prompt.temperature;
  const tts = isRecord(config.tts) ? config.tts : {};
  for (const field of ["model_id", "stability", "similarity_boost", "speed", "optimize_streaming_latency"]) {
    if (tts[field] !== undefined && tts[field] !== null) out.tts[field] = tts[field];
  }
  if (isRecord(config.turn)) out.turn = config.turn;
  return out;
}

export function deskAgentBody(toolIds: string[], template: Template = { tts: {} }): Record<string, unknown> {
  const prompt: Record<string, unknown> = { prompt: deskPrompt(), tool_ids: toolIds };
  if (template.llm) prompt.llm = template.llm;
  if (template.temperature !== undefined) prompt.temperature = template.temperature;
  prompt.built_in_tools = {
    end_call: { name: "end_call", description: "", params: { system_tool_type: "end_call" } },
    language_detection: LANGUAGE_DETECTION_TOOL,
  };
  const conversation: Record<string, unknown> = {
    agent: { first_message: "{{opening_line}}", language: "en", prompt },
    tts: { ...template.tts, model_id: multilingualModel(template.tts.model_id), voice_id: JARVIS_VOICE_ID, agent_output_audio_format: "ulaw_8000" },
    asr: { user_input_audio_format: "ulaw_8000" },
    language_presets: languagePresets(),
  };
  if (template.turn) conversation.turn = template.turn;
  return { name: DESK_AGENT_NAME, conversation_config: conversation };
}

export async function eleven(apiKey: string, method: string, path: string, body?: unknown): Promise<{ ok: boolean; status: number; body: unknown; detail: string }> {
  try {
    const response = await fetch(`https://api.elevenlabs.io${path}`, {
      method,
      redirect: "manual",
      signal: AbortSignal.timeout(12_000),
      headers: { "xi-api-key": apiKey, "content-type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await response.text();
    let parsed: unknown = null;
    try {
      parsed = JSON.parse(text);
    } catch {
      parsed = null;
    }
    return { ok: response.ok, status: response.status, body: parsed, detail: response.ok ? "" : safeError(text.slice(0, 300)) };
  } catch (err) {
    return { ok: false, status: 0, body: null, detail: safeError(err instanceof Error ? err.message : "network") };
  }
}

// ---------- webhook tools (ElevenLabs calls these, keyed by x-jarvis-desk) ----------

export function isDeskTool(method: string, path: string): boolean {
  return method === "POST" && /^\/desk\/tool\/[a-z_]+$/.test(path);
}

export async function handleDeskTool(request: Request, env: Env, path: string): Promise<Response> {
  const key = await deskKey(env);
  if ((request.headers.get("x-jarvis-desk") ?? "") !== key || !(env.JARVIS_APP_TOKEN ?? "").trim()) {
    return apiError(401, "unauthorized", "Desk tool key missing.");
  }
  const body = (await request.json().catch(() => null)) as Record<string, unknown> | null;
  if (!isRecord(body)) return apiError(400, "bad_request", "JSON body required.");
  const callId = asString(body.call_id, 80) ?? "";
  const call = /^call_[A-Za-z0-9]+$/.test(callId)
    ? await dbFirst<{ id: string; to_number: string; contact_name: string }>(env, "SELECT id, to_number, contact_name FROM outbound_calls WHERE id = ?", [callId]).catch(
        () => null,
      )
    : null;
  if (!call) return json({ ok: false, error: "This call is not on the desk." });
  const owner = await ownerMobile(env);
  if (owner && toE164(call.to_number) === owner) return json({ ok: false, error: "The owner does not use the desk." });
  await ensureDeskTables(env);
  const tool = path.split("/").pop();
  if (tool === "take_message") return json(await takeMessage(env, call, body));
  if (tool === "ask_owner") return json(await askOwner(env, call, body));
  if (tool === "check_owner_answer") return json(await checkOwnerAnswer(env, call.id, asString(body.request_id, 80) ?? ""));
  if (tool === "save_asg_lead") return json(await saveLead(env, call, body));
  return apiError(404, "not_found", "Unknown desk tool.");
}

async function ownerMobile(env: Env): Promise<string | null> {
  const { readOwnerMobile } = await import("./owner-alert");
  return readOwnerMobile(env).catch(() => null);
}

function text(value: unknown, max: number): string {
  return typeof value === "string" ? value.replace(/\s+/g, " ").trim().slice(0, max) : "";
}

async function takeMessage(env: Env, call: { id: string; to_number: string }, body: Record<string, unknown>): Promise<Record<string, unknown>> {
  const name = text(body.caller_name, 80);
  const callback = toE164(text(body.callback_number, 40)) ?? toUkMobile(text(body.callback_number, 40)) ?? call.to_number;
  const reason = text(body.reason, 200);
  const message = text(body.message, 600);
  if (!message) return { ok: false, error: "message is required" };
  const summary = [reason, message].filter(Boolean).join(". ").slice(0, 800);
  await dbRun(env, "UPDATE outbound_calls SET summary = ?, contact_name = CASE WHEN ? != '' THEN ? ELSE contact_name END, updated_at = ? WHERE id = ?", [
    summary,
    name,
    name,
    nowIso(),
    call.id,
  ]).catch(() => undefined);
  await dbRun(env, "UPDATE call_screen SET caller_name = CASE WHEN ? != '' THEN ? ELSE caller_name END, reason = ? WHERE call_id = ?", [
    name,
    name,
    reason || message.slice(0, 200),
    call.id,
  ]).catch(() => undefined);
  const { displayNumber } = await import("./sms-desk");
  const who = name || "A caller";
  const line = `${who} (${displayNumber(callback)}) left a message: ${message}`;
  const { pushNotice } = await import("./screening");
  const pushed = await pushNotice(env, `Message from ${who}`, line.slice(0, 220), { call_id: call.id, kind: "desk_message" }, "JARVIS_MESSAGE").catch(() => false);
  let texted = false;
  if (!pushed) texted = await smsOwner(env, `JARVIS: ${line}`);
  return { ok: true, passed_on: pushed || texted, say: "Tell them you will pass it to Master Hadi straight away." };
}

function toUkMobile(raw: string): string | null {
  const digits = raw.replace(/[^\d]/g, "");
  if (/^0\d{10}$/.test(digits)) return `+44${digits.slice(1)}`;
  return null;
}

async function smsOwner(env: Env, body: string): Promise<boolean> {
  const to = await ownerMobile(env);
  if (!to) return false;
  const { sendSms } = await import("./sms-desk");
  return sendSms(env, to, body).catch(() => false);
}

async function askOwner(env: Env, call: { id: string; to_number: string; contact_name: string }, body: Record<string, unknown>): Promise<Record<string, unknown>> {
  const kind: Kind = /locat|where/i.test(text(body.kind, 20)) ? "location" : "info";
  const question = text(body.question, 300) || (kind === "location" ? "Where is Master Hadi?" : "A question about Master Hadi.");
  const callerName = text(body.caller_name, 80) || (call.contact_name && call.contact_name !== "Incoming call" ? call.contact_name : "");
  const open = await dbFirst<OwnerRequest>(
    env,
    "SELECT * FROM owner_requests WHERE call_id = ? AND kind = ? ORDER BY created_at DESC LIMIT 1",
    [call.id, kind],
  ).catch(() => null);
  if (open && open.status !== "pending") return outcome(open);
  let request = open;
  if (!request) {
    const id = newId("ask");
    const now = new Date(deskClock.now()).toISOString();
    await dbRun(
      env,
      `INSERT INTO owner_requests (id, call_id, kind, question, caller_name, caller_phone, status, answer, share_token, sms_sent, created_at)
       VALUES (?, ?, ?, ?, ?, ?, 'pending', '', '', 0, ?)`,
      [id, call.id, kind, question, callerName, call.to_number, now],
    );
    request = await dbFirst<OwnerRequest>(env, "SELECT * FROM owner_requests WHERE id = ?", [id]);
    if (!request) return { status: "no_answer", say: BUSY_LINE };
    const pushed = await notifyOwner(env, request).catch(() => false);
    if (!pushed) await textOwnerRequest(env, request);
  }
  return waitForAnswer(env, request.id, FIRST_WAIT_MS);
}

async function checkOwnerAnswer(env: Env, callId: string, requestId: string): Promise<Record<string, unknown>> {
  const row = await dbFirst<OwnerRequest>(env, "SELECT * FROM owner_requests WHERE id = ? AND call_id = ?", [requestId, callId]).catch(() => null);
  if (!row) {
    const latest = await dbFirst<OwnerRequest>(env, "SELECT * FROM owner_requests WHERE call_id = ? ORDER BY created_at DESC LIMIT 1", [callId]).catch(() => null);
    if (!latest) return { status: "no_answer", say: BUSY_LINE };
    return waitForAnswer(env, latest.id, CHECK_WAIT_MS);
  }
  return waitForAnswer(env, row.id, CHECK_WAIT_MS);
}

async function waitForAnswer(env: Env, id: string, budgetMs: number): Promise<Record<string, unknown>> {
  const started = deskClock.now();
  for (;;) {
    const row = await dbFirst<OwnerRequest>(env, "SELECT * FROM owner_requests WHERE id = ?", [id]);
    if (!row) return { status: "no_answer", say: BUSY_LINE };
    if (row.status !== "pending") return outcome(row);
    const age = deskClock.now() - Date.parse(row.created_at);
    if (age >= ASK_WINDOW_MS) {
      await dbRun(env, "UPDATE owner_requests SET status = 'no_answer', decided_at = ? WHERE id = ? AND status = 'pending'", [
        new Date(deskClock.now()).toISOString(),
        id,
      ]);
      const after = await dbFirst<OwnerRequest>(env, "SELECT * FROM owner_requests WHERE id = ?", [id]);
      return after ? outcome(after) : { status: "no_answer", say: BUSY_LINE };
    }
    if (age >= SMS_AFTER_MS && row.sms_sent === 0) await textOwnerRequest(env, row);
    if (deskClock.now() - started >= budgetMs) {
      return { status: "pending", request_id: id, say: "Still checking, thank you for holding." };
    }
    await deskClock.sleep(POLL_MS);
  }
}

function outcome(row: OwnerRequest): Record<string, unknown> {
  if (row.status === "allowed" && row.kind === "location") {
    return {
      status: "allowed",
      link_sent: Boolean(row.share_token),
      say: row.share_token
        ? "Master Hadi has agreed. Tell them you have just texted them a link to his live location, which works for the next ten minutes."
        : "Master Hadi agreed, but the text could not be sent. Apologise and take a message instead.",
    };
  }
  if (row.status === "allowed") {
    return row.answer
      ? { status: "allowed", answer: row.answer, say: "Share only this approved answer, in your own words, and nothing else about him." }
      : {
          status: "allowed",
          answer: "",
          say: "He allowed a general answer only. You may say that he is a business owner who will get back to them. Share nothing personal.",
        };
  }
  return { status: row.status === "denied" ? "denied" : "no_answer", say: BUSY_LINE };
}

async function notifyOwner(env: Env, row: OwnerRequest): Promise<boolean> {
  const { pushNotice } = await import("./screening");
  const { displayNumber } = await import("./sms-desk");
  const who = row.caller_name || displayNumber(row.caller_phone) || "A caller";
  const title = row.kind === "location" ? `${who} wants your location` : `${who} is asking about you`;
  const body =
    row.kind === "location"
      ? "Allow to text them a live location link for 10 minutes."
      : `"${row.question.slice(0, 150)}" Allow, or reply with what I may say.`;
  return pushNotice(env, title, body, { kind: "owner_request", request_id: row.id, request_kind: row.kind, call_id: row.call_id }, row.kind === "location" ? "JARVIS_ASK_LOCATION" : "JARVIS_ASK");
}

async function textOwnerRequest(env: Env, row: OwnerRequest): Promise<void> {
  const claimed = await dbRun(env, "UPDATE owner_requests SET sms_sent = 1 WHERE id = ? AND sms_sent = 0", [row.id]).catch(() => 0);
  if (!claimed) return;
  const { displayNumber } = await import("./sms-desk");
  const who = `${row.caller_name || "A caller"} (${displayNumber(row.caller_phone)})`;
  const body =
    row.kind === "location"
      ? `JARVIS: ${who} is asking for your location. Reply YES to text them your live location for 10 minutes, or NO.`
      : `JARVIS: ${who} asks: "${row.question.slice(0, 140)}" Reply YES (or YES followed by what I may say), or NO.`;
  await smsOwner(env, body);
}

async function saveLead(env: Env, call: { id: string; to_number: string }, body: Record<string, unknown>): Promise<Record<string, unknown>> {
  const { insertAsgLead } = await import("./asg-phone");
  await insertAsgLead(env, {
    call_id: call.id,
    conversation_id: "",
    phone: call.to_number,
    caller_name: text(body.caller_name, 120),
    company: text(body.company, 160),
    role: text(body.role, 120),
    company_size: text(body.company_size, 80),
    needs: text(body.needs, 500),
    email: text(body.email, 160),
    preferred_times: text(body.preferred_times, 200),
    summary: text(body.summary, 500),
    do_not_contact: /^(yes|true)/i.test(text(body.do_not_contact, 10)),
    transcript: "",
  });
  return { ok: true };
}

// ---------- the owner's answer ----------

export async function decideOwnerRequest(
  env: Env,
  id: string,
  allow: boolean,
  answer: string,
  via: string,
  origin: string,
): Promise<{ ok: true; row: OwnerRequest; share: { token: string; url: string; expires_at: string } | null } | { ok: false; status: number; error: string }> {
  await ensureDeskTables(env);
  const row = await dbFirst<OwnerRequest>(env, "SELECT * FROM owner_requests WHERE id = ?", [id]);
  if (!row) return { ok: false, status: 404, error: "Request not found." };
  if (row.status !== "pending" || deskClock.now() - Date.parse(row.created_at) > ASK_WINDOW_MS + 5_000) {
    return { ok: false, status: 409, error: "That caller has already been told you're busy." };
  }
  const now = new Date(deskClock.now()).toISOString();
  let share: { token: string; url: string; expires_at: string } | null = null;
  if (allow && row.kind === "location") {
    share = await createShare(env, row, origin);
  }
  const changed = await dbRun(
    env,
    "UPDATE owner_requests SET status = ?, answer = ?, share_token = ?, decided_at = ?, decided_via = ? WHERE id = ? AND status = 'pending'",
    [allow ? "allowed" : "denied", allow ? answer.slice(0, 500) : "", share?.token ?? "", now, via, id],
  );
  if (!changed) return { ok: false, status: 409, error: "Already answered." };
  const after = await dbFirst<OwnerRequest>(env, "SELECT * FROM owner_requests WHERE id = ?", [id]);
  return { ok: true, row: after ?? row, share };
}

function randomToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(24));
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function createShare(env: Env, row: OwnerRequest, origin: string): Promise<{ token: string; url: string; expires_at: string } | null> {
  const token = randomToken();
  const created = deskClock.now();
  const expires = new Date(created + SHARE_MS).toISOString();
  await dbRun(
    env,
    "INSERT INTO location_shares (token, request_id, caller_phone, created_at, expires_at, lat, lng, accuracy, located_at) VALUES (?, ?, ?, ?, ?, NULL, NULL, NULL, NULL)",
    [token, row.id, row.caller_phone, new Date(created).toISOString(), expires],
  );
  const url = `${origin.replace(/\/$/, "").replace(/^http:/, "https:")}/l/${token}`;
  const { sendSms } = await import("./sms-desk");
  const sent = await sendSms(env, row.caller_phone, `Master Hadi has shared his live location with you for 10 minutes: ${url}`).catch(() => false);
  if (!sent) {
    await dbRun(env, "UPDATE location_shares SET expires_at = ? WHERE token = ?", [new Date(created).toISOString(), token]).catch(() => undefined);
    return null;
  }
  const { pushNotice } = await import("./screening");
  await pushNotice(
    env,
    "Sharing your location",
    "JARVIS is sharing your live location with the caller for 10 minutes.",
    { kind: "location_share", expires_at: expires },
    "JARVIS_MESSAGE",
    true,
  ).catch(() => false);
  return { token, url, expires_at: expires };
}

const YES = /^\s*(yes|yeah|yep|y|allow|ok|okay|sure|go ahead)\b[\s,.:;!-]*/i;
const NO = /^\s*(no|nope|n|deny|don'?t|do not)\b/i;

/** Sir texts YES or NO while a caller waits. True when the text was used. */
export async function ownerSmsDecision(env: Env, from: string, body: string, origin: string): Promise<boolean> {
  const owner = await ownerMobile(env);
  if (!owner || toE164(from) !== owner) return false;
  const yes = YES.exec(body);
  const no = !yes && NO.test(body);
  if (!yes && !no) return false;
  await ensureDeskTables(env).catch(() => undefined);
  const since = new Date(deskClock.now() - ASK_WINDOW_MS - 5_000).toISOString();
  const row = await dbFirst<{ id: string }>(
    env,
    "SELECT id FROM owner_requests WHERE status = 'pending' AND created_at >= ? ORDER BY created_at DESC LIMIT 1",
    [since],
  ).catch(() => null);
  if (!row) return false;
  const answer = yes ? body.slice(yes[0].length).trim() : "";
  await decideOwnerRequest(env, row.id, Boolean(yes), answer, "sms", origin);
  return true;
}

// ---------- app routes (app token) ----------

export async function routeDeskApi(request: Request, env: Env, path: string): Promise<Response | null> {
  if (request.method === "POST" && path === "/calls/desk/setup") {
    const origin = new URL(request.url).origin.replace(/^http:/, "https:");
    return json(await ensureDeskAgent(env, origin, true));
  }
  if (request.method === "GET" && path === "/calls/desk") {
    const id = await deskAgentId(env);
    const apiKey = (env.ELEVENLABS_API_KEY ?? "").trim();
    let agent: Record<string, unknown> | null = null;
    if (id && apiKey) {
      const got = await eleven(apiKey, "GET", `/v1/convai/agents/${encodeURIComponent(id)}`);
      const config = isRecord(got.body) && isRecord(got.body.conversation_config) ? got.body.conversation_config : {};
      const a = isRecord(config.agent) ? config.agent : {};
      const p = isRecord(a.prompt) ? a.prompt : {};
      const tts = isRecord(config.tts) ? config.tts : {};
      const asr = isRecord(config.asr) ? config.asr : {};
      agent = {
        status: got.status,
        name: isRecord(got.body) ? got.body.name : null,
        first_message: a.first_message ?? null,
        voice_is_george: tts.voice_id === JARVIS_VOICE_ID,
        output_format: tts.agent_output_audio_format ?? null,
        input_format: asr.user_input_audio_format ?? null,
        tool_count: Array.isArray(p.tool_ids) ? p.tool_ids.length : 0,
        llm: p.llm ?? null,
        prompt_has_busy_line: typeof p.prompt === "string" && p.prompt.includes(BUSY_LINE),
        error: got.ok ? null : got.detail,
      };
    }
    return json({ agent_ready: Boolean(id), version: await getState(env, "desk_agent_version").catch(() => null), agent });
  }
  if (request.method === "POST" && path === "/debug/desk-session") {
    // App-token only: a signed URL so a text-only test conversation can exercise the desk prompt and tools.
    const id = await deskAgentId(env);
    const apiKey = (env.ELEVENLABS_API_KEY ?? "").trim();
    if (!id || !apiKey) return apiError(503, "not_ready", "Desk agent is not set up.");
    const got = await eleven(apiKey, "GET", `/v1/convai/conversation/get-signed-url?agent_id=${encodeURIComponent(id)}`);
    const url = isRecord(got.body) && typeof got.body.signed_url === "string" ? got.body.signed_url : "";
    if (!url) return apiError(502, "eleven", got.detail || "No signed URL.");
    return json({ signed_url: url });
  }
  if (request.method === "GET" && path === "/calls/requests") {
    await ensureDeskTables(env);
    const since = new Date(deskClock.now() - ASK_WINDOW_MS).toISOString();
    const rows = await dbAll<OwnerRequest>(env, "SELECT * FROM owner_requests WHERE status = 'pending' AND created_at >= ? ORDER BY created_at DESC LIMIT 5", [since]);
    return json({ requests: rows.map((r) => ({ id: r.id, kind: r.kind, question: r.question, caller_name: r.caller_name, created_at: r.created_at })) });
  }
  const one = /^\/calls\/requests\/(ask_[A-Za-z0-9]+)$/.exec(path);
  if (request.method === "POST" && one) {
    const body = (await request.json().catch(() => null)) as Record<string, unknown> | null;
    if (!isRecord(body) || typeof body.allow !== "boolean") return apiError(400, "bad_request", "allow must be true or false.");
    const origin = new URL(request.url).origin;
    const result = await decideOwnerRequest(env, one[1], body.allow, text(body.answer, 500), "app", origin);
    if (!result.ok) return apiError(result.status, "request_closed", result.error);
    return json({ ok: true, kind: result.row.kind, status: result.row.status, share_expires_at: result.share?.expires_at ?? null });
  }
  if (request.method === "POST" && path === "/location/update") {
    const body = (await request.json().catch(() => null)) as Record<string, unknown> | null;
    const lat = Number(body?.lat);
    const lng = Number(body?.lng);
    const accuracy = Number(body?.accuracy ?? 0);
    if (!Number.isFinite(lat) || !Number.isFinite(lng) || Math.abs(lat) > 90 || Math.abs(lng) > 180) {
      return apiError(400, "bad_request", "lat and lng are required.");
    }
    await ensureDeskTables(env);
    const now = new Date(deskClock.now()).toISOString();
    const changed = await dbRun(env, "UPDATE location_shares SET lat = ?, lng = ?, accuracy = ?, located_at = ? WHERE expires_at > ?", [
      lat,
      lng,
      Number.isFinite(accuracy) ? accuracy : 0,
      now,
      now,
    ]);
    return json({ ok: true, active: changed, ...(await activeShare(env)) });
  }
  if (request.method === "GET" && path === "/location/active") {
    await ensureDeskTables(env);
    return json(await activeShare(env));
  }
  return null;
}

async function activeShare(env: Env): Promise<{ sharing: boolean; expires_at: string | null }> {
  const now = new Date(deskClock.now()).toISOString();
  const row = await dbFirst<{ expires_at: string }>(env, "SELECT MAX(expires_at) AS expires_at FROM location_shares WHERE expires_at > ?", [now]).catch(() => null);
  return { sharing: Boolean(row?.expires_at), expires_at: row?.expires_at ?? null };
}

// ---------- the public link ----------

export function isShareLink(method: string, path: string): boolean {
  return method === "GET" && /^\/l\/[A-Za-z0-9_-]{20,64}(?:\/where)?$/.test(path);
}

export async function handleShareLink(env: Env, path: string): Promise<Response> {
  const [, , token, tail] = path.split("/");
  await ensureDeskTables(env).catch(() => undefined);
  const row = await dbFirst<{ token: string; expires_at: string; lat: number | null; lng: number | null; accuracy: number | null; located_at: string | null }>(
    env,
    "SELECT token, expires_at, lat, lng, accuracy, located_at FROM location_shares WHERE token = ?",
    [token],
  ).catch(() => null);
  const expired = !row || deskClock.now() >= Date.parse(row.expires_at);
  if (row && expired && row.lat !== null) {
    await dbRun(env, "UPDATE location_shares SET lat = NULL, lng = NULL, accuracy = NULL WHERE token = ?", [token]).catch(() => undefined);
  }
  const headers = {
    "cache-control": "no-store",
    "referrer-policy": "no-referrer",
    "x-robots-tag": "noindex, nofollow",
  };
  if (tail === "where") {
    if (expired) return new Response(JSON.stringify({ expired: true }), { status: row ? 410 : 404, headers: { ...headers, "content-type": "application/json" } });
    return new Response(
      JSON.stringify({
        expired: false,
        expires_at: row.expires_at,
        lat: row.lat,
        lng: row.lng,
        accuracy: row.accuracy,
        updated_at: row.located_at,
      }),
      { status: 200, headers: { ...headers, "content-type": "application/json" } },
    );
  }
  return new Response(sharePage(expired, row?.expires_at ?? ""), { status: expired ? (row ? 410 : 404) : 200, headers: { ...headers, "content-type": "text/html; charset=utf-8" } });
}

export function sharePage(expired: boolean, expiresAt: string): string {
  const head = `<!doctype html><html lang="en-GB"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex"><title>Master Hadi's live location</title>
<style>body{margin:0;font-family:-apple-system,system-ui,sans-serif;background:#0b0f14;color:#e8eef5}header{padding:14px 16px;font-size:15px}#map{position:absolute;top:52px;bottom:0;left:0;right:0}.box{padding:40px 20px;text-align:center;font-size:18px}</style>`;
  if (expired) return `${head}</head><body><div class="box">This location share has expired.</div></body></html>`;
  return `${head}<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css"><script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script></head>
<body><header id="h">Master Hadi's live location &middot; <span id="t">waiting for his phone…</span></header><div id="map"></div>
<script>
var ends=Date.parse(${JSON.stringify(expiresAt)}),map=null,dot=null,ring=null;
function gone(){document.body.innerHTML='<div class="box">This location share has expired.</div>';}
function tick(){var s=Math.max(0,Math.round((ends-Date.now())/1000));if(s<=0){gone();return false;}return s;}
function draw(d){if(d.lat==null){return;}var p=[d.lat,d.lng];if(!map){map=L.map('map').setView(p,16);L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png',{maxZoom:19,attribution:'&copy; OpenStreetMap'}).addTo(map);dot=L.circleMarker(p,{radius:8,color:'#1e90ff',fillOpacity:1}).addTo(map);ring=L.circle(p,{radius:d.accuracy||30,weight:1}).addTo(map);}else{dot.setLatLng(p);ring.setLatLng(p);ring.setRadius(d.accuracy||30);map.panTo(p);}}
function poll(){var s=tick();if(s===false)return;fetch(location.pathname+'/where',{cache:'no-store'}).then(function(r){return r.json()}).then(function(d){if(d.expired){gone();return;}draw(d);var m=Math.floor(s/60),r=s%60;document.getElementById('t').textContent=(d.lat==null?'waiting for his phone… ':'')+m+':'+(r<10?'0':'')+r+' left';}).catch(function(){});}
poll();setInterval(poll,8000);setInterval(function(){if(tick()===false){}},1000);
</script></body></html>`;
}
