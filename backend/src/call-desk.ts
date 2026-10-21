import { dbFirst, dbRun } from "./db";
import { isRecord, newId, nowIso } from "./http";
import { GROQ_MODEL } from "./types";
import type { Env } from "./types";

export type CallStage = "dialing" | "live" | "ended";

export interface AwayOrder {
  instruction: string;
  expiresAt: string | null;
}

export interface DelegationRow {
  id: string;
  call_id: string;
  confirm_call_id: string | null;
  contact_name: string;
  to_number: string;
  goal: string;
  status: string;
  summary: string;
  decision: string | null;
}

const DIALING = new Set(["placing", "queued", "initiated", "ringing"]);
const ENDED = new Set(["completed", "failed", "declined", "cancelled", "busy", "no-answer"]);

export function callStage(status: string): CallStage {
  if (DIALING.has(status)) return "dialing";
  if (ENDED.has(status)) return "ended";
  return "live";
}

export function needsDelegation(brief: string): boolean {
  if (brief.startsWith("CONFIRM ")) return false;
  // The owner already tapped Call back. This call delivers the message.
  if (brief.startsWith("I'm calling you back")) return false;
  return /\b(book|reserve|reservation|table|appointment|enquiry|inquire|ask them|find out|check if)\b/i.test(brief);
}

export function wittyFallback(summary: string): string {
  const fact = summary.replace(/\s+/g, " ").replace(/https?:\/\/\S+/gi, "").trim();
  const line = fact.length > 150 ? `${fact.slice(0, 150).trim()}…` : fact;
  if (!line) return "They've answered, Sir. Shall I confirm it?";
  if (line.endsWith("?")) return line;
  return `${line} Shall I confirm that, Sir?`;
}

/** Spoken away order. "Clear" turns interception off. Hours default to eight when unset. */
export function parseAway(text: string): { kind: "clear" } | { kind: "set"; instruction: string; hours: number } | null {
  const cleaned = text.trim().replace(/\s+/g, " ");
  if (!cleaned) return null;
  if (/\b(stop answering my calls|i'm back|i am back|cancel away|turn off interceptor)\b/i.test(cleaned)) {
    return { kind: "clear" };
  }
  const set = /(?:jarvis[, ]+)?(?:please )?answer my calls(?: and (?:say|tell them) )?(.+)?$/i.exec(cleaned);
  if (!set && !/\banswer my calls\b/i.test(cleaned)) return null;
  let instruction = (set?.[1] ?? "").replace(/[.?!]+$/g, "").trim();
  if (!instruction || /^and (say|tell them)$/i.test(instruction)) instruction = "He'll ring you back";
  instruction = instruction.replace(/^(say|tell them)\s+/i, "").replace(/\bfor (?:the next )?(?:\d+|one|two|three|four|five|six|seven|eight) hours?\b/i, "").trim();
  const named = /\bfor (?:the next )?(\d+|one|two|three|four|five|six|seven|eight) hours?\b/i.exec(cleaned);
  const words: Record<string, number> = { one: 1, two: 2, three: 3, four: 4, five: 5, six: 6, seven: 7, eight: 8 };
  const raw = named?.[1]?.toLowerCase() ?? "";
  const hours = raw ? (words[raw] ?? Number(raw)) : 8;
  const span = Number.isFinite(hours) && hours > 0 && hours <= 24 ? Math.round(hours) : 8;
  return { kind: "set", instruction: instruction.slice(0, 240), hours: span };
}

export function awayFirstMessage(instruction: string): string {
  const line = instruction.replace(/\s+/g, " ").trim().slice(0, 180);
  return `Hello, you've reached Master Hadi's phone, this is JARVIS his personal assistant. This call may be handled by AI. Master Hadi asked me to say: ${line}. Who's calling, so I can pass that on?`;
}

export function awayPrompt(instruction: string): string {
  return [
    "You are JARVIS, Master Hadi's personal assistant, answering his phone while he is away.",
    `Your first spoken words are exactly: "${awayFirstMessage(instruction)}"`,
    "Take their name and a short message. Stay polite.",
    "Do not reveal his schedule, location, or any personal information.",
    "When they have left a message, say exactly: \"I'll pass that to Master Hadi and get back to you.\" Then thank them and end the call.",
    "British English. Short turns.",
  ].join("\n");
}

export function ownerReach(input: {
  quiet: boolean;
  busy: boolean;
  driving: boolean;
  countToday: number;
  max: number;
  urgentOnly: boolean;
  urgent: boolean;
}): "call" | "text" | "push" {
  if (input.quiet || input.busy) return "text";
  if (input.driving) {
    if (input.max <= 0 || input.countToday >= input.max) return "text";
    return "call";
  }
  if (input.max <= 0 || input.countToday >= input.max) return "push";
  if (input.urgentOnly && !input.urgent) return "push";
  return "call";
}

export function decisionOf(text: string): { confirm: boolean; detail: string } {
  const cleaned = text.trim().replace(/\s+/g, " ");
  if (/^(no|nope|leave it|don't|do not|stop)$/i.test(cleaned)) return { confirm: false, detail: "" };
  if (/^(yes|yeah|yep|take it|confirm|do it|please|go ahead)$/i.test(cleaned)) return { confirm: true, detail: cleaned };
  return { confirm: true, detail: cleaned.slice(0, 240) };
}

export async function readActiveAway(env: Env, now = new Date()): Promise<AwayOrder | null> {
  try {
    const row = await dbFirst<{ instruction: string; expires_at: string | null; active: number }>(
      env,
      "SELECT instruction, expires_at, active FROM call_away WHERE id = 'current'",
    );
    if (!row || row.active !== 1) return null;
    if (row.expires_at && Date.parse(row.expires_at) <= now.getTime()) return null;
    return { instruction: row.instruction, expiresAt: row.expires_at };
  } catch {
    return null;
  }
}

export async function writeAway(env: Env, order: { instruction: string; hours: number } | null): Promise<AwayOrder | null> {
  const now = nowIso();
  if (!order) {
    await dbRun(env, "UPDATE call_away SET active = 0 WHERE id = 'current'");
    return null;
  }
  const expires = new Date(Date.now() + order.hours * 60 * 60 * 1000).toISOString();
  await dbRun(
    env,
    `INSERT INTO call_away (id, instruction, expires_at, active, created_at)
     VALUES ('current', ?, ?, 1, ?)
     ON CONFLICT(id) DO UPDATE SET instruction = excluded.instruction, expires_at = excluded.expires_at, active = 1, created_at = excluded.created_at`,
    [order.instruction, expires, now],
  );
  return { instruction: order.instruction, expiresAt: expires };
}

export async function savePresence(env: Env, activity: string, busy: boolean): Promise<void> {
  const clean = ["automotive", "walking", "stationary", "unknown"].includes(activity) ? activity : "unknown";
  await dbRun(
    env,
    `INSERT INTO owner_presence (id, activity, busy, updated_at)
     VALUES ('current', ?, ?, ?)
     ON CONFLICT(id) DO UPDATE SET activity = excluded.activity, busy = excluded.busy, updated_at = excluded.updated_at`,
    [clean, busy ? 1 : 0, nowIso()],
  );
}

export async function readPresence(env: Env): Promise<{ activity: string; busy: boolean }> {
  try {
    const row = await dbFirst<{ activity: string; busy: number; updated_at: string }>(
      env,
      "SELECT activity, busy, updated_at FROM owner_presence WHERE id = 'current'",
    );
    if (!row) return { activity: "unknown", busy: false };
    if (Date.now() - Date.parse(row.updated_at) > 10 * 60 * 1000) return { activity: "unknown", busy: false };
    return { activity: row.activity, busy: row.busy === 1 };
  } catch {
    return { activity: "unknown", busy: false };
  }
}

export async function openDelegation(
  env: Env,
  input: { callId: string; contact: string; to: string; goal: string },
): Promise<void> {
  const now = nowIso();
  await dbRun(
    env,
    `INSERT INTO call_delegations
      (id, call_id, confirm_call_id, contact_name, to_number, goal, status, summary, decision, created_at, updated_at)
     VALUES (?, ?, NULL, ?, ?, ?, 'calling', '', NULL, ?, ?)`,
    [newId("del"), input.callId, input.contact, input.to, input.goal, now, now],
  );
}

export async function loadDelegation(env: Env, callId: string): Promise<DelegationRow | null> {
  try {
    return await dbFirst<DelegationRow>(
      env,
      "SELECT * FROM call_delegations WHERE call_id = ? OR confirm_call_id = ? ORDER BY created_at DESC LIMIT 1",
      [callId, callId],
    );
  } catch {
    return null;
  }
}

export async function rememberRecording(env: Env, callId: string, recordingSid: string): Promise<void> {
  if (!/^RE[0-9a-f]{32}$/i.test(recordingSid)) return;
  await dbRun(
    env,
    `INSERT INTO call_recordings (call_id, recording_sid, updated_at)
     VALUES (?, ?, ?)
     ON CONFLICT(call_id) DO UPDATE SET recording_sid = excluded.recording_sid, updated_at = excluded.updated_at`,
    [callId, recordingSid, nowIso()],
  );
}

export async function recordingSid(env: Env, callId: string): Promise<string | null> {
  try {
    const row = await dbFirst<{ recording_sid: string }>(env, "SELECT recording_sid FROM call_recordings WHERE call_id = ?", [callId]);
    return row?.recording_sid ?? null;
  } catch {
    return null;
  }
}

export async function settleDelegation(env: Env, callId: string): Promise<void> {
  const row = await loadDelegation(env, callId);
  if (!row) return;
  const call = await dbFirst<{ status: string; summary: string | null; transcript_json: string; contact_name: string }>(
    env,
    "SELECT status, summary, transcript_json, contact_name FROM outbound_calls WHERE id = ?",
    [callId],
  );
  if (!call || !ENDED.has(call.status)) return;
  if (row.confirm_call_id === callId && row.status === "confirming") {
    await dbRun(env, "UPDATE call_delegations SET status = 'done', updated_at = ? WHERE id = ?", [nowIso(), row.id]);
    return;
  }
  if (row.call_id !== callId || row.status !== "calling") return;
  const summary = await oneLine(env, call.contact_name, call.summary ?? "", call.transcript_json);
  await dbRun(env, "UPDATE call_delegations SET status = 'awaiting_decision', summary = ?, updated_at = ? WHERE id = ?", [
    summary,
    nowIso(),
    row.id,
  ]);
  await dbRun(env, "UPDATE outbound_calls SET summary = ?, updated_at = ? WHERE id = ? AND (summary IS NULL OR summary = '')", [
    summary,
    nowIso(),
    callId,
  ]);
}

export async function markDecision(env: Env, callId: string, text: string): Promise<{ confirm: boolean; detail: string; row: DelegationRow } | null> {
  const row = await loadDelegation(env, callId);
  if (!row || row.status !== "awaiting_decision") return null;
  const choice = decisionOf(text);
  if (!choice.confirm) {
    await dbRun(env, "UPDATE call_delegations SET status = 'done', decision = 'no', updated_at = ? WHERE id = ?", [nowIso(), row.id]);
    return { confirm: false, detail: "", row };
  }
  await dbRun(env, "UPDATE call_delegations SET status = 'confirming', decision = ?, updated_at = ? WHERE id = ?", [
    choice.detail || "yes",
    nowIso(),
    row.id,
  ]);
  return { confirm: true, detail: choice.detail || row.summary, row };
}

export async function attachConfirmCall(env: Env, delegationId: string, callId: string): Promise<void> {
  await dbRun(env, "UPDATE call_delegations SET confirm_call_id = ?, updated_at = ? WHERE id = ?", [callId, nowIso(), delegationId]);
}

export async function noteAwayOnCall(env: Env, callId: string): Promise<void> {
  const away = await readActiveAway(env);
  if (!away) return;
  const summary = `While you were away, I said: ${away.instruction}`;
  await dbRun(
    env,
    "UPDATE outbound_calls SET summary = CASE WHEN summary IS NULL OR summary = '' THEN ? ELSE summary END, updated_at = ? WHERE id = ?",
    [summary.slice(0, 300), nowIso(), callId],
  ).catch(() => undefined);
}

export async function recordVoiceApproval(env: Env, summary: string): Promise<void> {
  const line = summary.replace(/\s+/g, " ").trim().slice(0, 400);
  if (line.length < 8) return;
  const now = nowIso();
  await dbRun(
    env,
    `INSERT INTO approvals
      (id, task_id, subtask_id, action, level, summary, payload_json, status, reason, created_at, decided_at)
     VALUES (?, NULL, NULL, 'owner_voice', 'approval_required', ?, NULL, 'pending', NULL, ?, NULL)`,
    [newId("apr"), line, now],
  );
}

async function oneLine(env: Env, contact: string, summary: string, transcriptJson: string): Promise<string> {
  const transcript = transcriptText(transcriptJson);
  const seed = summary || transcript;
  const fallback = wittyFallback(seed);
  const key = (env.GROQ_API_KEY ?? env.GEMINI_API_KEY ?? "").trim();
  if (!key || !seed.trim()) return fallback;
  const prompt = [
    "Write one witty British butler sentence for Master Hadi.",
    "Use only the call notes below. End with a question he can answer.",
    "Under 180 characters. No URLs.",
    `Contact: ${contact}`,
    `Notes: ${seed.slice(0, 1200)}`,
  ].join("\n");
  try {
    const text = env.GROQ_API_KEY?.trim()
      ? await groqLine(env.GROQ_API_KEY.trim(), prompt)
      : await geminiLine(env.GEMINI_API_KEY?.trim() ?? "", prompt);
    const line = (text ?? "").replace(/\s+/g, " ").replace(/https?:\/\/\S+/gi, "").trim();
    if (!line || line.length > 220 || /i'll search/i.test(line)) return fallback;
    return line.endsWith("?") ? line : `${line} Shall I confirm that, Sir?`;
  } catch {
    return fallback;
  }
}

function transcriptText(raw: string): string {
  try {
    const parsed = JSON.parse(raw) as unknown;
    if (!Array.isArray(parsed)) return "";
    return parsed
      .flatMap((item) => (isRecord(item) && typeof item.text === "string" ? [item.text] : []))
      .join(" ")
      .slice(0, 1200);
  } catch {
    return "";
  }
}

async function groqLine(key: string, prompt: string): Promise<string | null> {
  const response = await fetch("https://api.groq.com/openai/v1/chat/completions", {
    method: "POST",
    signal: AbortSignal.timeout(6_000),
    headers: { authorization: `Bearer ${key}`, "content-type": "application/json" },
    body: JSON.stringify({
      model: GROQ_MODEL,
      messages: [{ role: "user", content: prompt }],
      max_tokens: 80,
    }),
  });
  if (!response.ok) return null;
  const payload = (await response.json()) as { choices?: Array<{ message?: { content?: string } }> };
  return payload.choices?.[0]?.message?.content ?? null;
}

async function geminiLine(key: string, prompt: string): Promise<string | null> {
  const response = await fetch("https://generativelanguage.googleapis.com/v1beta/openai/chat/completions", {
    method: "POST",
    signal: AbortSignal.timeout(6_000),
    headers: { authorization: `Bearer ${key}`, "content-type": "application/json" },
    body: JSON.stringify({
      model: "gemini-3.8-flash",
      messages: [{ role: "user", content: prompt }],
      max_tokens: 80,
    }),
  });
  if (!response.ok) return null;
  const payload = (await response.json()) as { choices?: Array<{ message?: { content?: string } }> };
  return payload.choices?.[0]?.message?.content ?? null;
}
