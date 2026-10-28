import { dbAll, dbRun } from "./db";
import { apiError, asString, isRecord, json, newId, nowIso, readJson } from "./http";
import { CHAT_FALLBACK, completeChat, type ChatMessage, type LlmTool } from "./llm";
import { spokenAnswer } from "./live-answer";
import { buildBriefing } from "./briefing";
import { parseToolArgs, toolsForNames } from "./tools";
import type { Env } from "./types";

/** George. The same ElevenLabs voice the phone line and the iPhone use. */
export const GEORGE_VOICE_ID = "JBFqnCBsd6RMkjVDRZzb";

export const BRAIN_REVISION = "brain-1";

/** Shared identity. Call scripts, SMS, and the app all start from this. */
export const BRAIN_IDENTITY = [
  "You are J.A.R.V.I.S., Master Hadi's personal assistant.",
  "Your voice is George, the British voice. British English.",
  "When you speak to him, call him Sir.",
  "On a telephone call to anyone else, refer to him only as Master Hadi. Never call him Sohail.",
].join(" ");

/** Identity plus the one tool set. SMS and the app both use this. */
export const BRAIN_PERSONA = [
  BRAIN_IDENTITY,
  "You can place a call, shop around for quotes, send an SMS, set a reminder, give the briefing, and queue an approval.",
  "Anything that goes out to a third party waits until he approves it.",
  "Never say a call is ringing or a text has been sent until the tool result says it happened.",
  "Do not pay, buy, charge a card, or invent phone numbers.",
].join(" ");

export type BrainSource = "sms" | "call" | "app";
export type BrainRole = "user" | "assistant";

export interface BrainTurn {
  id: string;
  source: BrainSource;
  role: BrainRole;
  body: string;
  ref: string | null;
  created_at: string;
}

export interface BrainAnswer {
  text: string;
  error: string | null;
}

const LIMIT = 40;
let ready = false;

export function brainSystem(channel: "sms" | "app"): string {
  if (channel === "sms") {
    return [
      BRAIN_PERSONA,
      "This reply is an SMS. Write two or three short sentences. Each sentence ends with a full stop and can stand alone as its own text.",
      "You cannot dial from this chat. Never say you are calling now, ringing now, or that a call has been placed. The server places calls.",
      "A message that starts with call, ring, or phone waits until he replies YES. Replying 1, you call, or call him back to a call message is already approved.",
      "Do not include URLs.",
    ].join("\n");
  }
  return [
    BRAIN_PERSONA,
    "This reply is for the iPhone app and is spoken in George's voice. One to three short sentences. No markdown and no URLs.",
  ].join("\n");
}

/** Rewrites a claim that a call is already ringing when no tool placed one. */
export function guardUnplacedCall(text: string): string {
  if (unplacedClaim(text)) return "I have not placed a call, Sir. Nothing was dialled.";
  if (/unable to place|can(?:not|'t) (?:place|make) (?:a )?(?:telephone |phone )?calls?|can(?:not|'t) (?:use the phone|call)\b/i.test(text)) {
    return "Tell me the number and what to say, Sir. Nothing has been dialled yet.";
  }
  return text;
}

export async function ensureBrain(env: Env): Promise<void> {
  if (ready) return;
  await dbRun(
    env,
    `CREATE TABLE IF NOT EXISTS brain_turns (
      id TEXT PRIMARY KEY,
      source TEXT NOT NULL,
      role TEXT NOT NULL,
      body TEXT NOT NULL,
      ref TEXT,
      created_at TEXT NOT NULL
    )`,
  );
  await dbRun(env, "CREATE INDEX IF NOT EXISTS idx_brain_turns_created ON brain_turns (created_at)");
  await dbRun(
    env,
    `CREATE TABLE IF NOT EXISTS brain_reminders (
      id TEXT PRIMARY KEY,
      text TEXT NOT NULL,
      due_at TEXT,
      status TEXT NOT NULL DEFAULT 'open',
      created_at TEXT NOT NULL
    )`,
  );
  ready = true;
}

/** The one memory write. SMS rememberTurn and POST /brain/line both call this. */
export async function rememberLine(
  env: Env,
  line: { source: BrainSource; role: BrainRole; body: string; ref?: string | null },
): Promise<boolean> {
  const body = cleanLine(line.body);
  if (!body) return false;
  await ensureBrain(env);
  const ref = line.ref && /^call_[A-Za-z0-9]+$/.test(line.ref) ? line.ref : null;
  await dbRun(env, "INSERT INTO brain_turns (id, source, role, body, ref, created_at) VALUES (?, ?, ?, ?, ?, ?)", [
    newId("brain"),
    line.source,
    line.role,
    body,
    ref,
    nowIso(),
  ]);
  return true;
}

export async function syncCalls(env: Env): Promise<void> {
  await ensureBrain(env);
  const calls = await dbAll<{ id: string; transcript_json: string | null }>(
    env,
    "SELECT id, transcript_json FROM outbound_calls ORDER BY updated_at DESC LIMIT 20",
  ).catch(() => []);
  for (const call of calls) {
    if (!/^call_[A-Za-z0-9]+$/.test(call.id)) continue;
    const existing = await dbAll<{ body: string }>(
      env,
      "SELECT body FROM brain_turns WHERE source = 'call' AND ref = ?",
      [call.id],
    ).catch(() => []);
    const have = new Set(existing.map((row) => row.body));
    for (const line of readTranscript(call.transcript_json)) {
      const body = cleanLine(line.text);
      if (!body || have.has(body)) continue;
      await rememberLine(env, { source: "call", role: line.role, body, ref: call.id });
      have.add(body);
    }
  }
}

export async function listTurns(env: Env): Promise<BrainTurn[]> {
  await syncCalls(env);
  const rows = await dbAll<BrainTurn>(
    env,
    "SELECT id, source, role, body, ref, created_at FROM brain_turns ORDER BY created_at DESC LIMIT ?",
    [LIMIT],
  ).catch(() => []);
  return [...rows].reverse().filter((row) => row.role === "user" || row.role === "assistant");
}

export async function openReminders(env: Env): Promise<string[]> {
  await ensureBrain(env);
  const rows = await dbAll<{ text: string }>(
    env,
    "SELECT text FROM brain_reminders WHERE status = 'open' ORDER BY created_at DESC LIMIT 12",
  ).catch(() => []);
  return rows.map((row) => row.text).filter((text) => text.length > 0);
}

export async function createReminder(env: Env, text: string, dueAt: string | null, source: BrainSource): Promise<string> {
  const body = cleanLine(text);
  if (!body) return "I need a reminder, Sir. Nothing was saved.";
  await ensureBrain(env);
  const due = dueAt && dueAt.length <= 40 ? dueAt : null;
  await dbRun(env, "INSERT INTO brain_reminders (id, text, due_at, status, created_at) VALUES (?, ?, ?, 'open', ?)", [
    newId("rem"),
    body,
    due,
    nowIso(),
  ]);
  await rememberLine(env, { source, role: "assistant", body: due ? `Reminder set: ${body} (${due})` : `Reminder set: ${body}` });
  return "Reminder saved, Sir. Nothing was sent.";
}

/** Answer from the shared history. The caller stores the user line first. */
export async function brainReply(env: Env, channel: "sms" | "app"): Promise<BrainAnswer> {
  await syncCalls(env);
  const facts = await dbAll<{ detail: string }>(env, "SELECT detail FROM owner_facts ORDER BY created_at DESC LIMIT 12").catch(() => []);
  const reminders = await openReminders(env).catch(() => []);
  const turns = await dbAll<{ role: string; body: string }>(
    env,
    "SELECT role, body FROM brain_turns ORDER BY created_at DESC LIMIT 16",
  ).catch(() => []);
  const messages: ChatMessage[] = [
    {
      role: "system",
      content: [
        brainSystem(channel),
        facts.length ? `Known facts:\n${facts.map((fact) => `- ${fact.detail}`).join("\n")}` : "No saved facts yet.",
        reminders.length ? `Open reminders:\n${reminders.map((item) => `- ${item}`).join("\n")}` : "No open reminders.",
      ].join("\n"),
    },
  ];
  for (const turn of [...turns].reverse()) {
    if (turn.role !== "user" && turn.role !== "assistant") continue;
    if (!turn.body) continue;
    messages.push({ role: turn.role, content: turn.body });
  }
  const tools = brainTools();
  const first = await completeChat(env, messages, tools);
  if (!first.ok) return { text: CHAT_FALLBACK, error: `${first.code}: ${first.message}` };
  const calls = first.message.tool_calls ?? [];
  if (calls.length === 0) {
    return { text: guardUnplacedCall(spokenAnswer(first.message.content ?? "") ?? "I've noted that, Sir."), error: null };
  }
  messages.push(first.message);
  for (const call of calls.slice(0, 3)) {
    const result = await runBrainTool(env, call.function.name, call.function.arguments, channel);
    messages.push({
      role: "tool",
      content: JSON.stringify(result).slice(0, 1500),
      tool_call_id: call.id,
      name: call.function.name,
    });
  }
  const second = await completeChat(env, messages, null);
  if (!second.ok) return { text: "I've noted that, Sir.", error: `${second.code}: ${second.message}` };
  return { text: guardUnplacedCall(spokenAnswer(second.message.content ?? "") ?? "I've noted that, Sir."), error: null };
}

export function brainTools(): LlmTool[] {
  return [
    ...toolsForNames(["web_search", "draft_document", "request_approval"]),
    tool("place_outbound_call", "Ask to place a Twilio call. This does not dial. He must reply YES or tap Approve.", {
      to: { type: "string" },
      contact_name: { type: "string" },
      brief: { type: "string" },
    }, ["to", "brief"]),
    tool("shop_around", "Draft a shop-around comparison. This does not dial.", {
      goal: { type: "string" },
    }, ["goal"]),
    tool("book_quote", "Ask to book a quoted option. This does not dial and does not pay.", {
      hunt_id: { type: "string" },
      quote_id: { type: "string" },
    }, []),
    tool("send_sms", "Ask to send an SMS. This does not send.", {
      to: { type: "string" },
      body: { type: "string" },
    }, ["body"]),
    tool("reminder_create", "Save a reminder both the phone line and the app can see.", {
      title: { type: "string" },
      due: { type: "string" },
    }, ["title"]),
    tool("get_briefing", "Read the briefing and the open reminders.", {}, []),
  ];
}

export async function runBrainTool(env: Env, name: string, raw: string, channel: BrainSource): Promise<unknown> {
  const parsed = parseToolArgs(raw);
  if (!parsed.ok) return { ok: false, error: parsed.error };
  const args = parsed.value;
  if (name === "place_outbound_call" || name === "send_sms" || name === "book_quote") {
    return {
      ok: true,
      placed: false,
      sent: false,
      booked: false,
      dialled: false,
      needs_approval: true,
      message: "Nothing was dialled or sent. This waits for YES by text or Approve in the app.",
    };
  }
  if (name === "shop_around") {
    const goal = typeof args.goal === "string" ? args.goal.trim() : "";
    if (!goal) return { ok: false, placed: false, message: "What should I shop for? Nothing was called." };
    try {
      const { createHunt } = await import("./hunt");
      const created = await createHunt(env, goal);
      return { ok: true, placed: false, dialled: false, hunt_id: created.id, message: `${created.message} Nothing was called.` };
    } catch {
      return { ok: false, placed: false, dialled: false, message: "I could not draft that comparison. Nothing was called." };
    }
  }
  if (name === "reminder_create") {
    const title = typeof args.title === "string" ? args.title : typeof args.text === "string" ? args.text : "";
    const due = typeof args.due === "string" ? args.due : null;
    const message = await createReminder(env, title, due, channel === "call" ? "app" : channel);
    return { ok: true, message };
  }
  if (name === "get_briefing") {
    try {
      const report = await buildBriefing(env);
      const pending = report.facts.pending_approvals.length;
      const reminders = report.reminders.length ? ` Open reminders: ${report.reminders.join("; ")}.` : "";
      return { ok: true, briefing: `Briefing. ${pending} approval${pending === 1 ? "" : "s"} waiting.${reminders}` };
    } catch {
      const reminders = await openReminders(env).catch(() => []);
      const extra = reminders.length ? ` Open reminders: ${reminders.join("; ")}.` : "";
      return { ok: true, briefing: `Briefing is not available just now.${extra}` };
    }
  }
  if (name === "web_search" || name === "draft_document" || name === "request_approval") {
    const desk = await import("./sms-desk");
    return desk.runSmsTool(env, name, raw);
  }
  return { ok: false, error: "That tool is not on this brain." };
}

export function personaResponse(): Response {
  return json({
    revision: BRAIN_REVISION,
    persona: brainSystem("app"),
    voice: "George",
    voice_id: GEORGE_VOICE_ID,
  });
}

export async function historyResponse(env: Env): Promise<Response> {
  const turns = await listTurns(env);
  const reminders = await openReminders(env).catch(() => []);
  return json({
    revision: BRAIN_REVISION,
    voice: "George",
    voice_id: GEORGE_VOICE_ID,
    reminders,
    turns: turns.map((turn) => ({
      id: turn.id,
      source: turn.source,
      role: turn.role,
      body: turn.body,
      created_at: turn.created_at,
    })),
  });
}

export async function lineResponse(request: Request, env: Env): Promise<Response> {
  const body = await readJson(request);
  if (!body.ok) return body.response;
  if (!isRecord(body.value)) return apiError(400, "bad_request", "source, role, and text are required.");
  const source = asString(body.value.source, 8);
  const role = asString(body.value.role, 12);
  const text = asString(body.value.text, 1000);
  if ((source !== "sms" && source !== "call" && source !== "app") || (role !== "user" && role !== "assistant") || !text) {
    return apiError(400, "bad_request", "source, role, and text are required.");
  }
  const stored = await rememberLine(env, { source, role, body: text });
  return json({ ok: true, stored });
}

export async function sayResponse(request: Request, env: Env): Promise<Response> {
  const body = await readJson(request);
  if (!body.ok) return body.response;
  if (!isRecord(body.value)) return apiError(400, "bad_request", "text is required.");
  const text = asString(body.value.text, 1000);
  if (!text) return apiError(400, "bad_request", "text is required.");
  await rememberLine(env, { source: "app", role: "user", body: text });
  const answered = await brainReply(env, "app");
  await rememberLine(env, { source: "app", role: "assistant", body: answered.text });
  const turns = await listTurns(env);
  return json({
    reply: answered.text,
    voice: "George",
    voice_id: GEORGE_VOICE_ID,
    turns: turns.map((turn) => ({
      id: turn.id,
      source: turn.source,
      role: turn.role,
      body: turn.body,
      created_at: turn.created_at,
    })),
  });
}

export async function reminderResponse(request: Request, env: Env): Promise<Response> {
  const body = await readJson(request);
  if (!body.ok) return body.response;
  if (!isRecord(body.value)) return apiError(400, "bad_request", "text is required.");
  const text = asString(body.value.text, 300);
  if (!text) return apiError(400, "bad_request", "text is required.");
  const due = typeof body.value.due_at === "string" ? body.value.due_at.trim().slice(0, 40) : null;
  const message = await createReminder(env, text, due, "app");
  return json({ ok: true, message, voice_id: GEORGE_VOICE_ID });
}

function tool(name: string, description: string, properties: Record<string, unknown>, required: string[]): LlmTool {
  return {
    type: "function",
    function: {
      name,
      description,
      parameters: { type: "object", properties, required },
    },
  };
}

function unplacedClaim(text: string): boolean {
  const lower = text.toLowerCase();
  if (/\b(?:calling|ringing)\b/.test(lower) && /\bnow\b/.test(lower)) return true;
  if (/\bi(?:'m| am) (?:calling|ringing|dialling|dialing)\b/.test(lower)) return true;
  if (/\bi(?:'ve| have) (?:just )?(?:called|rung|dialled|dialed)\b/.test(lower)) return true;
  return false;
}

function cleanLine(text: string): string {
  const collapsed = text.replace(/\s+/g, " ").trim();
  if (!collapsed) return "";
  if (phoneOnly(collapsed)) return "";
  return redactNumbers(collapsed).slice(0, 1000);
}

function phoneOnly(text: string): boolean {
  const stripped = text
    .replace(/\+\d[\d\s().-]*\d/g, "")
    .replace(/\b0\d{9,10}\b/g, "")
    .replace(/[\s.,;:()[\]+-]+/g, "");
  return stripped.length === 0;
}

function redactNumbers(text: string): string {
  return text
    .replace(/\+\d[\d\s().-]*\d/g, "[number]")
    .replace(/\b0\d{4}\s?\d{3}\s?\d{3}\b/g, "[number]")
    .replace(/\b0\d{9,10}\b/g, "[number]");
}

function readTranscript(raw: string | null): { role: BrainRole; text: string }[] {
  if (!raw) return [];
  try {
    const parsed = JSON.parse(raw) as unknown;
    if (!Array.isArray(parsed)) return [];
    const lines: { role: BrainRole; text: string }[] = [];
    for (const item of parsed) {
      if (!isRecord(item)) continue;
      const text = typeof item.text === "string" ? item.text : typeof item.message === "string" ? item.message : "";
      if (!text.trim()) continue;
      const role: BrainRole = item.role === "assistant" ? "assistant" : "user";
      lines.push({ role, text });
    }
    return lines;
  } catch {
    return [];
  }
}
