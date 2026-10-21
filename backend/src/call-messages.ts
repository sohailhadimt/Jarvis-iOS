import { dbAll, dbFirst, dbRun, getState, setState } from "./db";
import { apiError, json, newId, nowIso } from "./http";
import { readOwnerMobile } from "./owner-alert";
import { pushNotice } from "./screening";
import { sendSmsResult, type SmsResult } from "./sms-desk";
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
 * Spoken line for one finished inbound call. Up to three short sentences: who rang,
 * what they wanted, and the message. Greetings and filler are left out. A callback
 * number is kept when the caller gave one. The same text is what the app speaks and what the SMS sends.
 */
export function spokenCallMessage(name: string, calledAtIso: string, summary: string): string {
  const who = callerLabel(name);
  const time = londonClock(calledAtIso);
  return butlerLine(who, time, summary);
}

/** A greeting or a filler noise, with no message behind it. */
export function isGreetingOrFiller(sentence: string): boolean {
  let text = sentence.replace(/[.!?]+$/gu, "").replace(/\s+/g, " ").trim();
  text = text.replace(/^(?:um+|uh+|er+|ah+)[, ]+/i, "").trim();
  if (!text) return true;
  if (/^(?:um+|uh+|er+|ah+)$/i.test(text)) return true;
  return /^(?:good\s+(?:morning|afternoon|evening|night|day)|hello|hi|hey|hiya|how are you|how're you|how is it going|how's it going)(?:[, ]+(?:sir|there))*$/i.test(
    text,
  );
}

/** Sentences that carry the message. The "Sir, … rang at …" lead and greetings are dropped. */
export function substantiveSentences(text: string, limit = 2): string[] {
  const kept: string[] = [];
  for (const part of sentences(text)) {
    if (/^sir,/i.test(part) && /\brang at\b/i.test(part)) continue;
    if (isGreetingOrFiller(part)) continue;
    let body = part.replace(/[.!?]+$/gu, "").trim();
    body = body.replace(/^(?:um+|uh+|er+|ah+)[, ]+/i, "").trim();
    if (!body || isGreetingOrFiller(body)) continue;
    const sentence = `${body.charAt(0).toUpperCase()}${body.slice(1)}`;
    kept.push(/[.!?]$/u.test(sentence) ? sentence : `${sentence}.`);
    if (kept.length >= limit) break;
  }
  return kept;
}

/** True when the spoken line is only the lead, or the lead plus a greeting. */
export function callTextIsThin(spoken: string): boolean {
  const rest = sentences(spoken).filter((part) => !(/^sir,/i.test(part) && /\brang at\b/i.test(part)));
  if (rest.length === 0) return true;
  return rest.every((part) => isGreetingOrFiller(part));
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
        await deliverOwnerText(env, callId);
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
    await deliverOwnerText(env, callId);
    return true;
  } catch {
    return inbound;
  }
}

export interface OwnerText {
  call_id: string;
  message_id: string;
  sid: string;
  status: string;
  error_code: string;
  error: string;
  sent: boolean;
}

const SMS_OK = new Set(["queued", "accepted", "sending", "sent", "delivered", "received", "receiving"]);

/**
 * Title and one-line body for the call-message push.
 * The body is the short reason, not the full "Sir, … rang at …" line.
 */
export function callPushCopy(name: string, spoken: string, summary: string): { title: string; body: string } {
  const who = callerLabel(name);
  return {
    title: `JARVIS – Call from ${who}`,
    body: shortCallSummary(spoken, summary),
  };
}

/** The one sentence that belongs in the notification. Greetings are skipped. */
export function shortCallSummary(spoken: string, summary: string): string {
  const fromSpoken = secondSentence(spoken);
  if (fromSpoken) return clipNotice(fromSpoken);
  const fromSummary = secondSentence(summary);
  if (fromSummary) return clipNotice(fromSummary);
  const tidy = summary.replace(/…/g, " ").replace(/\.{3,}/g, " ").replace(/\s+/g, " ").trim();
  if (tidy && !/^sir,/i.test(tidy) && !isPlaceholderSummary(tidy)) {
    const line = /[.!?]$/u.test(tidy) ? tidy : `${tidy}.`;
    return clipNotice(line);
  }
  return clipNotice(spoken);
}

/**
 * Tells the owner a saved call message is waiting.
 * A registered device gets an Apple push. SMS is the fallback when no device token is registered,
 * and also when a token is registered but Apple did not accept the push.
 * A saved row is not treated as proof the text was sent. Opt-out (21610) is not retried.
 */
/**
 * Texts the saved message once per call.
 * A later rewrite of the wording does not send a second text.
 * correction sends one replacement body for a call that was already texted, then stops.
 */
export async function deliverOwnerText(env: Env, callId: string, opts?: { correction?: boolean }): Promise<OwnerText> {
  const empty: OwnerText = { call_id: callId, message_id: "", sid: "", status: "", error_code: "", error: "no_message", sent: false };
  if (!/^call_[A-Za-z0-9]+$/.test(callId)) return { ...empty, error: "bad_call" };
  const message = await dbFirst<{ id: string; call_id: string; caller_name: string; summary: string; spoken: string }>(
    env,
    "SELECT id, call_id, caller_name, summary, spoken FROM call_messages WHERE call_id = ?",
    [callId],
  ).catch(() => null);
  if (!message?.spoken) return empty;
  const prior = await readReceipt(env, message.id);
  const callMark = await readCallMark(env, callId);
  const correction = opts?.correction === true;
  if (!correction && (callMark?.ok || (prior && (prior.ok || prior.errorCode === "21610")))) {
    return {
      call_id: callId,
      message_id: message.id,
      sid: prior?.sid || callMark?.sid || "",
      status: prior?.status || callMark?.status || "",
      error_code: prior?.errorCode || "",
      error: prior?.error || "",
      sent: false,
    };
  }
  if (correction && prior?.ok && prior.spoken === message.spoken) {
    return {
      call_id: callId,
      message_id: message.id,
      sid: prior.sid,
      status: prior.status,
      error_code: prior.errorCode,
      error: prior.error,
      sent: false,
    };
  }
  if (prior || correction) {
    const listed = await listOutboundTexts(env);
    if (!correction && prior && listed == null) {
      return {
        call_id: callId,
        message_id: message.id,
        sid: prior.sid,
        status: prior.status,
        error_code: prior.errorCode,
        error: prior.error || "already_attempted",
        sent: false,
      };
    }
    const hit = listed ? textAlreadySent(listed, message.spoken, correction ? "" : (prior?.spoken ?? ""), correction) : null;
    if (hit) {
      const spoken = hit.body === message.spoken.trim() ? message.spoken : hit.body;
      await writeReceipt(env, message.id, spoken, { ok: true, sid: hit.sid, status: hit.status || "delivered", errorCode: "", error: "" });
      await writeCallMark(env, callId, spoken, hit.sid, hit.status || "delivered");
      return {
        call_id: callId,
        message_id: message.id,
        sid: hit.sid,
        status: hit.status || "delivered",
        error_code: "",
        error: "",
        sent: false,
      };
    }
  }
  if (!correction) {
    const pushed = await pushCallMessage(env, message);
    if (pushed) {
      await writeReceipt(env, message.id, message.spoken, { ok: true, sid: "", status: "pushed", errorCode: "", error: "" });
      await writeCallMark(env, callId, message.spoken, "", "pushed");
      return {
        call_id: callId,
        message_id: message.id,
        sid: "",
        status: "pushed",
        error_code: "",
        error: "",
        sent: false,
      };
    }
  }
  const claimed = await claimSendLock(env, callId);
  if (!claimed) {
    return { ...empty, message_id: message.id, error: "sending", sent: false };
  }
  try {
    const owner = await readOwnerMobile(env);
    if (!owner) {
      const missed: OwnerText = { ...empty, message_id: message.id, error: "owner_number" };
      await writeReceipt(env, message.id, message.spoken, { ok: false, sid: "", status: "", errorCode: "", error: "owner_number" });
      return missed;
    }
    const result = await sendSmsResult(env, owner, message.spoken);
    await writeReceipt(env, message.id, message.spoken, result);
    if (result.ok) await writeCallMark(env, callId, message.spoken, result.sid, result.status);
    return {
      call_id: callId,
      message_id: message.id,
      sid: result.sid,
      status: result.status,
      error_code: result.errorCode,
      error: result.error,
      sent: result.ok,
    };
  } finally {
    await releaseSendLock(env, callId);
  }
}

interface SmsReceipt {
  ok: boolean;
  sid: string;
  status: string;
  errorCode: string;
  error: string;
  spoken: string;
}

async function readReceipt(env: Env, messageId: string): Promise<SmsReceipt | null> {
  const raw = await getState(env, `owner_sms:${messageId}`).catch(() => null);
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw) as Partial<SmsReceipt>;
    const status = typeof parsed.status === "string" ? parsed.status : "";
    return {
      ok: parsed.ok === true || SMS_OK.has(status),
      sid: typeof parsed.sid === "string" ? parsed.sid : "",
      status,
      errorCode: typeof parsed.errorCode === "string" ? parsed.errorCode : "",
      error: typeof parsed.error === "string" ? parsed.error : "",
      spoken: typeof parsed.spoken === "string" ? parsed.spoken : "",
    };
  } catch {
    return null;
  }
}

async function writeReceipt(env: Env, messageId: string, spoken: string, result: SmsResult): Promise<void> {
  const receipt: SmsReceipt = {
    ok: result.ok || SMS_OK.has(result.status),
    sid: result.sid,
    status: result.status,
    errorCode: result.errorCode,
    error: result.error,
    spoken,
  };
  await setState(env, `owner_sms:${messageId}`, JSON.stringify(receipt)).catch(() => undefined);
}

interface CallMark {
  ok: boolean;
  sid: string;
  status: string;
  spoken: string;
}

async function readCallMark(env: Env, callId: string): Promise<CallMark | null> {
  const raw = await getState(env, `owner_sms_call:${callId}`).catch(() => null);
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw) as Partial<CallMark>;
    return {
      ok: parsed.ok === true,
      sid: typeof parsed.sid === "string" ? parsed.sid : "",
      status: typeof parsed.status === "string" ? parsed.status : "",
      spoken: typeof parsed.spoken === "string" ? parsed.spoken : "",
    };
  } catch {
    return null;
  }
}

async function writeCallMark(env: Env, callId: string, spoken: string, sid: string, status: string): Promise<void> {
  const mark: CallMark = { ok: true, sid, status, spoken };
  await setState(env, `owner_sms_call:${callId}`, JSON.stringify(mark)).catch(() => undefined);
}

interface ListedText {
  body: string;
  sid: string;
  status: string;
}

/** Recent outbound texts. Null means the list could not be read, which is not the same as an empty list. */
async function listOutboundTexts(env: Env): Promise<ListedText[] | null> {
  const account = (env.TWILIO_ACCOUNT_SID ?? "").trim();
  const token = (env.TWILIO_AUTH_TOKEN ?? "").trim();
  if (!account || !token) return null;
  try {
    const response = await fetch(
      `https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(account)}/Messages.json?PageSize=100`,
      {
        method: "GET",
        redirect: "follow",
        signal: AbortSignal.timeout(10_000),
        headers: { authorization: `Basic ${btoa(`${account}:${token}`)}` },
      },
    );
    if (!response.ok) return null;
    const parsed = JSON.parse(await response.text()) as { messages?: unknown };
    if (!Array.isArray(parsed.messages)) return null;
    const listed: ListedText[] = [];
    for (const item of parsed.messages) {
      if (!item || typeof item !== "object") continue;
      const record = item as { body?: unknown; sid?: unknown; status?: unknown; direction?: unknown };
      const direction = typeof record.direction === "string" ? record.direction : "";
      if (direction && !direction.startsWith("outbound")) continue;
      const status = typeof record.status === "string" ? record.status : "";
      if (status === "failed" || status === "undelivered") continue;
      const body = typeof record.body === "string" ? record.body.trim() : "";
      if (!body) continue;
      listed.push({ body, sid: typeof record.sid === "string" ? record.sid : "", status });
    }
    return listed;
  } catch {
    return null;
  }
}

function textAlreadySent(listed: ListedText[], spoken: string, priorSpoken: string, correction: boolean): ListedText | null {
  const current = spoken.trim();
  const previous = priorSpoken.trim();
  const lead = sentences(current)[0]?.trim() ?? "";
  for (const item of listed) {
    if (item.body === current || (previous && item.body === previous)) return item;
    if (correction) continue;
    if (lead.length > 12 && item.body.includes(lead)) return item;
  }
  return null;
}

async function claimSendLock(env: Env, callId: string): Promise<boolean> {
  const now = nowIso();
  const stale = new Date(Date.now() - 120_000).toISOString();
  const changes = await dbRun(
    env,
    `INSERT INTO runtime_state (key, value, updated_at) VALUES (?, 'sending', ?)
     ON CONFLICT(key) DO UPDATE SET value = 'sending', updated_at = excluded.updated_at
     WHERE runtime_state.value != 'sending' OR runtime_state.updated_at < ?`,
    [`owner_sms_lock:${callId}`, now, stale],
  ).catch(() => 0);
  return changes === 1;
}

async function releaseSendLock(env: Env, callId: string): Promise<void> {
  await setState(env, `owner_sms_lock:${callId}`, "idle").catch(() => undefined);
}

export async function listCallMessages(env: Env, url: URL): Promise<Response> {
  const unread = url.searchParams.get("unread") === "1";
  try {
    const rows = await dbAll<MessageRow>(env, unread ? UNREAD_SQL : RECENT_SQL);
    const messages = await Promise.all(rows.map((row) => present(env, row)));
    return json({ messages });
  } catch {
    return json({ messages: [] });
  }
}

export async function getCallMessage(env: Env, id: string): Promise<Response> {
  if (!/^cmsg_[A-Za-z0-9]+$/.test(id)) return apiError(400, "bad_request", "Unknown message id.");
  try {
    const row = await dbFirst<MessageRow>(
      env,
      "SELECT id, call_id, caller_name, summary, spoken, called_at, read_at, created_at FROM call_messages WHERE id = ?",
      [id],
    );
    if (!row) return apiError(404, "not_found", "Message not found.");
    return json({ message: await present(env, row) });
  } catch {
    return apiError(503, "call_log_unavailable", "The message could not be read.");
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

async function pushCallMessage(
  env: Env,
  message: { id: string; call_id: string; caller_name: string; summary: string; spoken: string },
): Promise<boolean> {
  let tokens: { token: string }[] = [];
  try {
    tokens = await dbAll<{ token: string }>(env, "SELECT token FROM call_devices ORDER BY updated_at DESC LIMIT 5");
  } catch {
    return false;
  }
  if (tokens.length === 0) return false;
  const copy = callPushCopy(message.caller_name || "", message.spoken, message.summary || "");
  return pushNotice(
    env,
    copy.title,
    copy.body,
    { kind: "call_message", message_id: message.id, call_id: message.call_id },
    "JARVIS_MESSAGE",
  );
}

async function present(env: Env, row: MessageRow): Promise<{
  id: string;
  call_id: string;
  caller_name: string;
  summary: string;
  spoken: string;
  called_at: string;
  created_at: string;
  read: boolean;
  transcript: { role: string; text: string }[];
  recording: boolean;
}> {
  return {
    id: row.id,
    call_id: row.call_id,
    caller_name: row.caller_name,
    summary: row.summary,
    spoken: row.spoken,
    called_at: row.called_at,
    created_at: row.created_at,
    read: Boolean(row.read_at),
    transcript: await messageTranscript(env, row.call_id),
    recording: await messageHasRecording(env, row.call_id),
  };
}

async function messageTranscript(env: Env, callId: string): Promise<{ role: string; text: string }[]> {
  try {
    const call = await dbFirst<{ transcript_json: string | null }>(
      env,
      "SELECT transcript_json FROM outbound_calls WHERE id = ?",
      [callId],
    );
    return parseMessageTranscript(call?.transcript_json ?? "");
  } catch {
    return [];
  }
}

async function messageHasRecording(env: Env, callId: string): Promise<boolean> {
  try {
    const row = await dbFirst<{ recording_sid: string }>(
      env,
      "SELECT recording_sid FROM call_recordings WHERE call_id = ?",
      [callId],
    );
    return Boolean(row?.recording_sid && /^RE[0-9a-fA-F]{32}$/.test(row.recording_sid));
  } catch {
    return false;
  }
}

function parseMessageTranscript(raw: string): { role: string; text: string }[] {
  if (!raw) return [];
  try {
    const parsed = JSON.parse(raw) as unknown;
    if (!Array.isArray(parsed)) return [];
    const lines: { role: string; text: string }[] = [];
    for (const item of parsed) {
      if (!item || typeof item !== "object") continue;
      const record = item as { role?: unknown; text?: unknown };
      if (typeof record.text !== "string") continue;
      const text = record.text.replace(/\+\d[\d\s()-]{5,}/g, " ").replace(/\s+/g, " ").trim().slice(0, 500);
      if (!text) continue;
      lines.push({ role: record.role === "them" || record.role === "user" ? "them" : "assistant", text });
      if (lines.length >= 40) break;
    }
    return lines;
  } catch {
    return [];
  }
}

function clipNotice(text: string): string {
  const clean = text.replace(/…/g, "").replace(/\s+/g, " ").trim();
  if (!clean) return "";
  if (clean.length <= 180) return clean;
  const cut = clean.slice(0, 180);
  const space = cut.lastIndexOf(" ");
  const base = (space > 40 ? cut.slice(0, space) : cut).replace(/[,:;]$/u, "").trim();
  return /[.!?]$/u.test(base) ? base : `${base}.`;
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
  const extra = substantiveSentences(summary, 2);
  const line = [lead, ...extra].join(" ");
  return fitSentences(line, 320);
}

function secondSentence(summary: string): string {
  let text = summary.replace(/…+/g, " ").replace(/\.{3,}/g, " ").replace(/\s+/g, " ").trim();
  if (!text || /^a caller left a message\.?$/i.test(text)) return "";
  if (/\b(typeerror|syntaxerror|referenceerror|network connection|status code)\b/i.test(text)) return "";
  if (/^(the user|the caller|analysis)\b/i.test(text) || /\bidentified as\b/i.test(text)) return "";
  return substantiveSentences(text, 1)[0] ?? "";
}

function sentences(text: string): string[] {
  const bits = text.match(/[^.!?]+[.!?]+|[^.!?]+$/g) ?? [];
  return bits.map((part) => part.replace(/\s+/g, " ").trim()).filter(Boolean);
}

function fitSentences(line: string, max: number): string {
  const parts = sentences(line)
    .slice(0, 3)
    .map((part) => part.replace(/…/g, "").trim())
    .filter(Boolean);
  while (parts.length > 1 && parts.join(" ").length > max) parts.pop();
  let text = parts.join(" ").replace(/\s+/g, " ").trim().replace(/…/g, "");
  if (text && !/[.!?]$/u.test(text)) text += ".";
  if (text.length <= max) return text;
  const cut = text.slice(0, Math.max(0, max - 1));
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
