import { JARVIS_VOICE_ID, toE164 } from "./calls";
import { dbFirst, getState, setState } from "./db";
import { eleven, templateFromMainAgent, type Template } from "./desk";
import { apiError, asString, isRecord, json } from "./http";
import { publicBase } from "./public-url";
import type { Env } from "./types";

/**
 * Sir's own ElevenLabs agent. When his mobile rings the JARVIS line (matched by caller ID only),
 * he gets this agent: a greeting by name, his context, and live tools (weather, web search, contacts).
 * Strangers never reach it; they stay on the desk agent.
 */

export const OWNER_AGENT_NAME = "JARVIS Personal";
export const OWNER_AGENT_VERSION = "owner-1";

export function ownerGreeting(now = new Date()): string {
  const hour = Number(new Intl.DateTimeFormat("en-GB", { timeZone: "Europe/London", hour: "2-digit", hourCycle: "h23" }).format(now));
  const part = hour >= 5 && hour < 12 ? "Good morning" : hour >= 12 && hour < 18 ? "Good afternoon" : "Good evening";
  return `${part}, Sir. What can I do for you?`;
}

export function londonNow(now = new Date()): string {
  return new Intl.DateTimeFormat("en-GB", {
    timeZone: "Europe/London",
    weekday: "long",
    day: "numeric",
    month: "long",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  }).format(now);
}

export function ownerAgentPrompt(): string {
  return [
    "You are J.A.R.V.I.S., the personal assistant of Master Hadi (Sohail). The person on this call is Sir himself: the line matched his own mobile by caller ID before you answered, so never ask who is calling, never screen him, and never take a message for him.",
    "Speak as a calm British butler with a dry wit. Address him as Sir. Keep each spoken answer to one to three short sentences unless he asks for more. No lists, markdown, URLs or emoji.",
    "Have a full, natural conversation. Follow on from what he says. If he wants to chat, chat.",
    "The time in London is {{now_london}}.",
    "What you know about his day and recent conversations: {{owner_context}}",
    "Tools: get_weather for any place and day (Ashford, Kent if he does not say). web_search for anything current: sport, news, opening hours, prices, phone numbers of businesses. lookup_contact for a name in his own phone contacts. Always use a tool for current facts; never guess a score, a price, a date or a number. Say a few words such as 'One moment, Sir' while a tool runs.",
    "Read phone numbers back in groups. Never read out a number from his contacts unless he asked for it.",
    "You cannot dial anyone, text anyone, buy or book from this call. If he wants you to ring or text someone, tell him to text the JARVIS line, for example 'ring Ali and ask if he is free', and it will wait for his YES.",
    "Never claim anything has been sent, called, booked or paid unless a tool result says so. When he says goodbye, say goodbye briefly and end the call.",
  ].join("\n");
}

const CALL_ID = { type: "string", dynamic_variable: "jarvis_call_id" };

function prop(description: string): Record<string, unknown> {
  return { type: "string", description };
}

export function ownerToolConfigs(origin: string, key: string): Record<string, Record<string, unknown>> {
  const base = origin.replace(/\/$/, "");
  const webhook = (name: string, description: string, body: Record<string, unknown>, required: string[], timeout: number) => ({
    type: "webhook",
    name,
    description,
    response_timeout_secs: timeout,
    pre_tool_speech: "auto",
    api_schema: {
      url: `${base}/owner/tool/${name}`,
      method: "POST",
      request_headers: { "x-jarvis-owner": key },
      request_body_schema: { type: "object", description: `${name} input`, properties: { call_id: CALL_ID, ...body }, required: ["call_id", ...required] },
    },
  });
  return {
    get_weather: webhook(
      "get_weather",
      "Live weather for any place: current conditions and the forecast. Use for weather, rain, temperature, or what to wear.",
      {
        place: prop("Town or city, e.g. 'Ashford, Kent' or 'Paris'. Empty means Ashford, Kent."),
        when: prop("today, tomorrow, a weekday name, this weekend, or this week. Empty means today."),
      },
      [],
      15,
    ),
    web_search: webhook(
      "web_search",
      "Search the live web and get a short answer. Use for anything current or factual you are not sure of: sport results, news, opening hours, prices, a business's phone number.",
      { query: prop("The question to search, in plain words, with the place if it matters.") },
      ["query"],
      30,
    ),
    lookup_contact: webhook(
      "lookup_contact",
      "Look up a person in Sir's own phone contacts by name or relation (e.g. 'Ali', 'Mum'). Returns up to three matches.",
      { name: prop("The name or relation he said.") },
      ["name"],
      10,
    ),
  };
}

export async function ownerKey(env: Env): Promise<string> {
  const seed = `${(env.JARVIS_APP_TOKEN ?? "").trim()}:jarvis-owner-tools`;
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(seed));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("").slice(0, 40);
}

/** The personal agent id once it is set up at the current version. Null keeps the override path. */
export async function ownerAgentId(env: Env): Promise<string | null> {
  if ((env.OWNER_AGENT ?? "on").trim() === "off") return null;
  const id = await getState(env, "owner_agent_id").catch(() => null);
  if (!id || !/^agent_[A-Za-z0-9]+$/.test(id)) return null;
  const stamp = await getState(env, "owner_agent_version").catch(() => null);
  return stamp && stamp.startsWith(`${OWNER_AGENT_VERSION}|`) ? id : null;
}

export interface OwnerEnsureResult {
  ok: boolean;
  agent: "created" | "updated" | "current" | "failed";
  tools: Record<string, string>;
  error?: string;
}

export function ownerAgentBody(toolIds: string[], template: Template = { tts: {} }): Record<string, unknown> {
  const prompt: Record<string, unknown> = { prompt: ownerAgentPrompt(), tool_ids: toolIds };
  if (template.llm) prompt.llm = template.llm;
  if (template.temperature !== undefined) prompt.temperature = template.temperature;
  prompt.built_in_tools = { end_call: { name: "end_call", description: "", params: { system_tool_type: "end_call" } } };
  const conversation: Record<string, unknown> = {
    agent: {
      first_message: "{{opening_line}}",
      language: "en",
      prompt,
      dynamic_variables: {
        dynamic_variable_placeholders: {
          opening_line: "Good evening, Sir. What can I do for you?",
          owner_context: "No recent notes.",
          now_london: "unknown",
          jarvis_call_id: "",
          contact_name: "Master Hadi",
          brief: "",
        },
      },
    },
    tts: { ...template.tts, voice_id: JARVIS_VOICE_ID, agent_output_audio_format: "ulaw_8000" },
    asr: { user_input_audio_format: "ulaw_8000" },
  };
  if (template.turn) conversation.turn = template.turn;
  return { name: OWNER_AGENT_NAME, conversation_config: conversation };
}

/** Creates or updates the three webhook tools and the personal agent. Never runs on a call. */
export async function ensureOwnerAgent(env: Env, force = false): Promise<OwnerEnsureResult> {
  const apiKey = (env.ELEVENLABS_API_KEY ?? "").trim();
  const tools: Record<string, string> = {};
  const origin = publicBase(env);
  if (!apiKey) return { ok: false, agent: "failed", tools, error: "missing ElevenLabs key" };
  const stamp = `${OWNER_AGENT_VERSION}|${origin}`;
  const existing = await getState(env, "owner_agent_id").catch(() => null);
  if (!force && existing && (await getState(env, "owner_agent_version").catch(() => null)) === stamp) {
    return { ok: true, agent: "current", tools };
  }
  const key = await ownerKey(env);
  for (const [name, config] of Object.entries(ownerToolConfigs(origin, key))) {
    const saved = await getState(env, `owner_tool:${name}`).catch(() => null);
    let id = saved ?? "";
    if (id) {
      const patched = await eleven(apiKey, "PATCH", `/v1/convai/tools/${encodeURIComponent(id)}`, { tool_config: config });
      if (!patched.ok) id = "";
    }
    if (!id) {
      const created = await eleven(apiKey, "POST", "/v1/convai/tools", { tool_config: config });
      id = isRecord(created.body) && typeof created.body.id === "string" ? created.body.id : "";
      if (!id) return { ok: false, agent: "failed", tools, error: `tool ${name}: ${created.status} ${created.detail}` };
      await setState(env, `owner_tool:${name}`, id);
    }
    tools[name] = id;
  }
  const template = await templateFromMainAgent(env, apiKey);
  const body = ownerAgentBody(Object.values(tools), template);
  let agent: OwnerEnsureResult["agent"] = "failed";
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
    await setState(env, "owner_agent_id", id);
    agent = "created";
  }
  await setState(env, "owner_agent_version", stamp);
  return { ok: true, agent, tools };
}

/** A short, private summary for the agent: open reminders and the last few lines between Sir and JARVIS. */
export async function ownerContext(env: Env): Promise<string> {
  const parts: string[] = [];
  try {
    const { openReminders, listTurns } = await import("./brain");
    const reminders = await openReminders(env).catch(() => [] as string[]);
    if (reminders.length) parts.push(`Open reminders: ${reminders.slice(0, 6).join("; ")}.`);
    const turns = await listTurns(env).catch(() => []);
    const recent = turns.slice(-8).map((t) => `${t.role === "user" ? "Sir" : "JARVIS"}: ${t.body.replace(/\s+/g, " ").slice(0, 160)}`);
    if (recent.length) parts.push(`Recent: ${recent.join(" | ")}`);
  } catch {
    // Context is a nicety; the call goes ahead without it.
  }
  const text = parts.join(" ").replace(/\{\{|\}\}/g, "");
  return text.slice(0, 1800) || "No recent notes.";
}

/** Dynamic variables every personal-agent call must carry (the prompt uses each one). */
export async function ownerVariables(env: Env, callId: string, now = new Date()): Promise<Record<string, string>> {
  // The call is ringing: context gets 2 seconds at most.
  const context = await Promise.race([
    ownerContext(env),
    new Promise<string>((resolve) => setTimeout(() => resolve("No recent notes."), 2_000)),
  ]);
  return { jarvis_call_id: callId, owner_context: context, now_london: londonNow(now) };
}

/** The override prompt for when the personal agent is not set up yet: same persona, context inline, no tools. */
export function ownerFallbackPrompt(vars: Record<string, string>): string {
  return ownerAgentPrompt()
    .replace("{{now_london}}", vars.now_london ?? "")
    .replace("{{owner_context}}", vars.owner_context ?? "")
    .replace(/^Tools:.*$/m, "You have no live tools on this call. If he asks for weather, news or a number, say you'll text it and suggest he texts the JARVIS line.");
}

// ---------------------------------------------------------------- webhook tools

export function isOwnerTool(method: string, path: string): boolean {
  return method === "POST" && /^\/owner\/tool\/[a-z_]+$/.test(path);
}

export async function handleOwnerTool(request: Request, env: Env, path: string): Promise<Response> {
  const key = await ownerKey(env);
  if ((request.headers.get("x-jarvis-owner") ?? "") !== key || !(env.JARVIS_APP_TOKEN ?? "").trim()) {
    return apiError(401, "unauthorized", "Owner tool key missing.");
  }
  const body = (await request.json().catch(() => null)) as Record<string, unknown> | null;
  if (!isRecord(body)) return apiError(400, "bad_request", "JSON body required.");
  const callId = asString(body.call_id, 80) ?? "";
  const call = /^call_[A-Za-z0-9]+$/.test(callId)
    ? await dbFirst<{ id: string; to_number: string; contact_name: string }>(env, "SELECT id, to_number, contact_name FROM outbound_calls WHERE id = ?", [callId]).catch(() => null)
    : null;
  const { readOwnerMobile } = await import("./owner-alert");
  const owner = await readOwnerMobile(env).catch(() => null);
  // Only a call that came from Sir's own mobile can use these tools.
  if (!call || !owner || toE164(call.to_number) !== owner) return json({ ok: false, error: "This call is not Sir's." });
  return json(await runOwnerTool(env, path.split("/").pop() ?? "", body));
}

export async function runOwnerTool(env: Env, tool: string, body: Record<string, unknown>): Promise<Record<string, unknown>> {
  if (tool === "get_weather") {
    const { weatherFor } = await import("./live-tools");
    const got = await weatherFor(asString(body.place, 80) ?? "", asString(body.when, 40) ?? "");
    return { ok: got.ok, weather: got.text };
  }
  if (tool === "web_search") {
    const query = asString(body.query, 300) ?? "";
    if (!query) return { ok: false, error: "query is required" };
    const { liveSearch } = await import("./live-tools");
    const got = await liveSearch(env, query);
    return got.ok ? { ok: true, answer: got.answer } : { ok: false, answer: "I couldn't reach the web just now." };
  }
  if (tool === "lookup_contact") {
    const name = asString(body.name, 80) ?? "";
    if (!name) return { ok: false, error: "name is required" };
    const { findContacts } = await import("./contacts");
    const found = await findContacts(env, name, 3).catch(() => []);
    if (!found.length) return { ok: true, matches: [], message: `No one called ${name} in your contacts, Sir. Tap Sync contacts in the app if they're new.` };
    return { ok: true, matches: found.map((f) => ({ name: f.name, number: f.phone.replace(/^\+44/, "0"), label: f.label })) };
  }
  return { ok: false, error: "Unknown tool." };
}

/** App-token route: set up (or force-refresh) the agent, or try a tool without a call. */
export async function ownerAgentRoute(request: Request, env: Env, path: string): Promise<Response | null> {
  if (request.method === "POST" && path === "/owner/agent/ensure") {
    const raw = (await request.json().catch(() => ({}))) as Record<string, unknown>;
    return json(await ensureOwnerAgent(env, raw?.force === true));
  }
  if (request.method === "GET" && path === "/owner/agent") {
    return json({ ok: true, agent_id: await ownerAgentId(env), version: await getState(env, "owner_agent_version").catch(() => null), greeting: ownerGreeting() });
  }
  if (request.method === "POST" && path === "/debug/owner-tool") {
    const raw = (await request.json().catch(() => null)) as Record<string, unknown> | null;
    if (!isRecord(raw)) return apiError(400, "bad_request", "JSON body required.");
    return json(await runOwnerTool(env, asString(raw.tool, 40) ?? "", raw));
  }
  return null;
}
