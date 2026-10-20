import { dbAll, dbFirst, dbRun } from "./db";
import { apiError, json, newId, nowIso } from "./http";
import { readOwnerMobile } from "./owner-alert";
import { pushNotice } from "./screening";
import { sendSms } from "./sms-desk";
import type { Env } from "./types";

interface ScreenBits {
  direction: string;
  caller_name: string;
  reason: string;
}

interface CallBits {
  status: string;
  summary: string | null;
  created_at: string;
}

interface MessageRow {
  id: string;
  call_id: string;
  caller_name: string;
  summary: string;
  spoken: string;
  called_at: string;
  read_at: string | null;
  created_at: string;
}

const UNREAD_SQL =
  "SELECT id, call_id, caller_name, summary, spoken, called_at, read_at, created_at FROM call_messages WHERE read_at IS NULL ORDER BY created_at ASC LIMIT 20";
const RECENT_SQL =
  "SELECT id, call_id, caller_name, summary, spoken, called_at, read_at, created_at FROM call_messages ORDER BY created_at DESC LIMIT 30";

/** True for the old voicemail placeholder and for a blank summary. */
export function isPlaceholderSummary(text: string): boolean {
  const clean = text.replace(/\s+/g, " ").trim();
  return !clean || /^a caller left a message\.?$/i.test(clean);
}

/** London time used in the spoken line, so the model cannot invent the clock. */
export function messageClock(iso: string): string {
  return londonClock(iso);
}

/**
 * Spoken line for one finished inbound call. Two sentences at most, no phone numbers,
 * and no ellipsis. The same text is what the app speaks and what the SMS sends.
 */
export function spokenCallMessage(name: string, calledAtIso: string, summary: string): string {
  const who = callerLabel(name);
  const time = londonClock(calledAtIso);
  return butlerLine(who, time, summary);
}

/**
 * Stores one unread message when an inbound call has finished, texts it once, and pushes the app.
 * Returns true when this call is inbound, so the caller does not send a second text.
 */
export async function rememberInboundMessage(env: Env, callId: string): Promise<boolean> {
  if (!/^call_[A-Za-z0-9]+$/.test(callId)) return false;
  let inbound = false;
  try {
    const screen = await dbFirst<ScreenBits>(
      env,
      "SELECT direction, caller_name, reason FROM call_screen WHERE call_id = ?",
      [callId],
    );
    if (!screen || screen.direction !== "inbound") return false;
    inbound = true;
    const call = await dbFirst<CallBits>(
      env,
      "SELECT status, summary, created_at FROM outbound_calls WHERE id = ?",
      [callId],
    );
    if (!call || call.status !== "completed") return true;
    const rawDetail = tidyDetail(call.summary || screen.reason || "");
    const detail = isPlaceholderSummary(rawDetail) ? "" : rawDetail;
    const spoken = spokenCallMessage(screen.caller_name, call.created_at, detail);
    const who = callerLabel(screen.caller_name);
    const existing = await dbFirst<MessageRow>(
      env,
      "SELECT id, call_id, caller_name, summary, spoken, called_at, read_at, created_at FROM call_messages WHERE call_id = ?",
      [callId],
    );
    if (existing) {
      const replacing = isPlaceholderSummary(existing.summary) && Boolean(detail);
      if (replacing) {
        const nextSpoken = spokenCallMessage(screen.caller_name, existing.called_at || call.created_at, detail);
        await dbRun(env, "UPDATE call_messages SET caller_name = ?, summary = ?, spoken = ? WHERE id = ?", [
          who,
          detail,
          nextSpoken,
          existing.id,
        ]);
        const owner = await readOwnerMobile(env);
        if (owner) await sendSms(env, owner, nextSpoken);
        await pushNotice(env, "JARVIS", nextSpoken, { kind: "call_message", message_id: existing.id }, "JARVIS_MESSAGE");
      } else if (detail && detail !== existing.summary) {
        const nextSpoken = spokenCallMessage(screen.caller_name, existing.called_at || call.created_at, detail);
        await dbRun(env, "UPDATE call_messages SET summary = ?, spoken = ? WHERE id = ?", [detail, nextSpoken, existing.id]);
      }
      return true;
    }
    const id = newId("cmsg");
    const now = nowIso();
    await dbRun(
      env,
      `INSERT INTO call_messages (id, call_id, caller_name, summary, spoken, called_at, read_at, created_at)
       VALUES (?, ?, ?, ?, ?, ?, NULL, ?)`,
      [id, callId, who, detail, spoken, call.created_at, now],
    );
    const owner = await readOwnerMobile(env);
    if (owner) await sendSms(env, owner, spoken);
    await pushNotice(env, "JARVIS", spoken, { kind: "call_message", message_id: id }, "JARVIS_MESSAGE");
    return true;
  } catch {
    return inbound;
  }
}

export async function listCallMessages(env: Env, url: URL): Promise<Response> {
  const unread = url.searchParams.get("unread") === "1";
  try {
    const rows = await dbAll<MessageRow>(env, unread ? UNREAD_SQL : RECENT_SQL);
    return json({ messages: rows.map(present) });
  } catch {
    return json({ messages: [] });
  }
}

export async function markCallMessageRead(env: Env, id: string): Promise<Response> {
  if (!/^cmsg_[A-Za-z0-9]+$/.test(id)) return apiError(400, "bad_request", "Unknown message id.");
  try {
    const row = await dbFirst<{ id: string }>(env, "SELECT id FROM call_messages WHERE id = ?", [id]);
    if (!row) return apiError(404, "not_found", "Message not found.");
    await dbRun(env, "UPDATE call_messages SET read_at = ? WHERE id = ? AND read_at IS NULL", [nowIso(), id]);
    return json({ ok: true, id });
  } catch {
    return json({ ok: false, id });
  }
}

function present(row: MessageRow): {
  id: string;
  call_id: string;
  caller_name: string;
  summary: string;
  spoken: string;
  called_at: string;
  created_at: string;
  read: boolean;
} {
  return {
    id: row.id,
    call_id: row.call_id,
    caller_name: row.caller_name,
    summary: row.summary,
    spoken: row.spoken,
    called_at: row.called_at,
    created_at: row.created_at,
    read: Boolean(row.read_at),
  };
}

function callerLabel(name: string): string {
  const clean = name.replace(/\+\d{6,}/g, "").replace(/\s+/g, " ").trim();
  if (junkCaller(clean)) return "an unknown caller";
  return clean.slice(0, 40);
}

function junkCaller(name: string): boolean {
  if (!name) return true;
  if (/^(incoming call|someone|caller|unknown|an unknown caller|user|test|test call|a test call|master hadi)$/i.test(name)) {
    return true;
  }
  return /\btest call\b/i.test(name);
}

function tidyDetail(summary: string): string {
  let text = summary.replace(/^call summary:\s*/i, "").replace(/^they left a message:\s*/i, "");
  text = text.replace(/…+/g, " ").replace(/\.{3,}/g, " ");
  text = text.replace(/\+\d{6,}/g, " ");
  text = text.replace(/\s+/g, " ").trim();
  if (!text) return "";
  if (/\b(typeerror|syntaxerror|referenceerror|network connection|status code)\b/i.test(text)) return "";
  if (text.length > 280) {
    const cut = text.slice(0, 280);
    const space = cut.lastIndexOf(" ");
    return (space > 40 ? cut.slice(0, space) : cut).replace(/[,:;]$/u, "").trim();
  }
  return text;
}

function butlerLine(who: string, time: string, summary: string): string {
  const lead = `Sir, ${who} rang at ${time}.`;
  const second = secondSentence(summary);
  const line = second ? `${lead} ${second}` : lead;
  return fitSentences(line, 320);
}

function secondSentence(summary: string): string {
  let text = summary.replace(/…+/g, " ").replace(/\.{3,}/g, " ");
  text = text.replace(/\+\d[\d\s()-]{5,}/g, " ").replace(/\s+/g, " ").trim();
  text = text.replace(/\s+on$/i, "").trim();
  if (!text || /^a caller left a message\.?$/i.test(text)) return "";
  if (/\b(typeerror|syntaxerror|referenceerror|network connection|status code)\b/i.test(text)) return "";
  if (/^(the user|the caller|analysis)\b/i.test(text) || /\bidentified as\b/i.test(text)) return "";
  const parts = sentences(text);
  const body = parts.length >= 2 && /^sir,/i.test(parts[0]) ? parts[1] : /^sir,/i.test(parts[0] ?? "") ? "" : (parts[0] ?? "");
  const clean = body.replace(/[.!?]+$/u, "").trim();
  if (!clean) return "";
  return `${clean.charAt(0).toUpperCase()}${clean.slice(1)}.`;
}

function sentences(text: string): string[] {
  const bits = text.match(/[^.!?]+[.!?]+|[^.!?]+$/g) ?? [];
  return bits.map((part) => part.replace(/\s+/g, " ").trim()).filter(Boolean);
}

function fitSentences(line: string, max: number): string {
  const parts = sentences(line)
    .slice(0, 2)
    .map((part) => part.replace(/…/g, "").trim())
    .filter(Boolean);
  let text = parts.join(" ").replace(/\s+/g, " ").trim().replace(/…/g, "");
  if (text && !/[.!?]$/u.test(text)) text += ".";
  if (text.length <= max) return text;
  const first = parts[0] ?? "";
  if (first && first.length <= max) return /[.!?]$/u.test(first) ? first : `${first}.`;
  const cut = first.slice(0, Math.max(0, max - 1));
  const space = cut.lastIndexOf(" ");
  const base = (space > 20 ? cut.slice(0, space) : cut).replace(/[,:;]$/u, "").trim();
  return /[.!?]$/u.test(base) ? base : `${base}.`;
}

function londonClock(iso: string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "earlier";
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Europe/London",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(date);
  const hour = parts.find((part) => part.type === "hour")?.value ?? "";
  const minute = parts.find((part) => part.type === "minute")?.value ?? "";
  if (!hour || !minute) return "earlier";
  return `${hour}:${minute}`;
}
