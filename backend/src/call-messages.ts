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

/** Spoken line for one finished inbound call. No phone numbers. */
export function spokenCallMessage(name: string, calledAtIso: string, summary: string): string {
  const who = callerLabel(name);
  const time = londonClock(calledAtIso);
  const detail = tidyDetail(summary);
  if (!detail) return `Sir, you have a message. ${who} called at ${time}.`;
  const clause = detail.replace(/[.…]+$/u, "");
  if (/^(to|about|asking|for)\b/i.test(clause)) {
    return `Sir, you have a message. ${who} called at ${time} ${clause}.`;
  }
  const sentence = /[.!?…]$/u.test(detail) ? detail : `${detail}.`;
  return `Sir, you have a message. ${who} called at ${time}. ${sentence}`;
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
    const detail = tidyDetail(call.summary || screen.reason || "");
    const spoken = spokenCallMessage(screen.caller_name, call.created_at, detail);
    const who = callerLabel(screen.caller_name);
    const existing = await dbFirst<MessageRow>(
      env,
      "SELECT id, call_id, caller_name, summary, spoken, called_at, read_at, created_at FROM call_messages WHERE call_id = ?",
      [callId],
    );
    if (existing) {
      if (detail && detail !== existing.summary) {
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
  if (!clean || /^(incoming call|someone|caller|unknown)$/i.test(clean)) return "Someone";
  return clean.slice(0, 80);
}

function tidyDetail(summary: string): string {
  let text = summary.replace(/^call summary:\s*/i, "").replace(/^they left a message:\s*/i, "");
  text = text.replace(/\+\d{6,}/g, " ");
  text = text.replace(/\s+/g, " ").trim();
  if (!text) return "";
  if (/\b(typeerror|syntaxerror|referenceerror|network connection|status code)\b/i.test(text)) return "";
  if (text.length > 180) return `${text.slice(0, 179).trimEnd()}…`;
  return text;
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
