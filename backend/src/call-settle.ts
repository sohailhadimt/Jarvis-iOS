import {
  callTextIsThin,
  deliverOwnerText,
  hasChoiceQuestion,
  isPlaceholderSummary,
  messageClock,
  rememberInboundMessage,
  spokenCallMessage,
  substantiveSentences,
} from "./call-messages";
import { elevenLabsSignatureValid, guessCaller, readConversation, safeError, type CallLine } from "./calls";
import { dbAll, dbFirst, dbRun, getState, setState } from "./db";
import { clip, isRecord, json, parseJsonValue } from "./http";
import { completeChat } from "./llm";
import type { Env } from "./types";

const PUBLIC_POST_CALL_URL = "https://jarvis-backend.jarvis-hadi.workers.dev/calls/elevenlabs/post-call";
const WEBHOOK_ID_KEY = "elevenlabs_post_call_webhook_id";
const WEBHOOK_SECRET_KEY = "elevenlabs_post_call_secret";
const WEBHOOK_ENSURED_KEY = "elevenlabs_post_call_ensured_at";
const OPEN_STATUSES = [
  "screening",
  "listening",
  "handling",
  "message",
  "connecting",
  "ringing",
  "in_progress",
  "wrapping",
  "placing",
];

export interface SettleHit {
  call_id: string;
  message_id: string | null;
  spoken: string | null;
  summary: string | null;
  status: string;
}

export interface WebhookEnsure {
  ok: boolean;
  created: boolean;
  attached: boolean;
  status: number;
  step: string;
  error: string;
}

interface OpenCall {
  id: string;
  contact_name: string;
  conversation_id: string | null;
  status: string;
  summary: string | null;
  transcript_json: string | null;
  created_at: string;
  twilio_sid?: string | null;
}

interface ListedConversation {
  id: string;
  status: string;
  startMs: number;
}

interface Brief {
  name: string;
  reason: string;
  said: string;
  spoken: string;
}

/** ElevenLabs post-call webhook. HMAC is required. Audio events are acknowledged and discarded. */
export async function handleElevenPostCall(request: Request, env: Env): Promise<Response> {
  const raw = await request.text();
  const secrets = await webhookSecrets(env);
  if (secrets.length === 0) return json({ ok: false }, 401);
  let signed = false;
  for (const secret of secrets) {
    if (await elevenLabsSignatureValid(request.headers.get("ElevenLabs-Signature"), raw, secret)) {
      signed = true;
      break;
    }
  }
  if (!signed) return json({ ok: false }, 401);
  const payload = parseJsonValue(raw);
  if (!isRecord(payload)) return json({ ok: true, matched: false });
  const type = typeof payload.type === "string" ? payload.type : "";
  if (type === "post_call_audio" || type === "call_initiation_failure") return json({ ok: true });
  const data = isRecord(payload.data) ? payload.data : payload;
  const hit = await settlePayload(env, data).catch(() => null);
  return json({
    ok: true,
    matched: Boolean(hit?.message_id || hit?.status === "failed"),
    call_id: hit?.call_id ?? null,
    message_id: hit?.message_id ?? null,
  });
}

const BACKFILL_CALL = "call_2fe78971459946b3bd5bdcd82c15b378";
const RESEND_CALL = "call_959c1db561354036a621adcc6ae1dc35";
const POLLY_CALL = "call_f0ce67d2098c49208dacf2c63f719957";
const TERMINAL_TWILIO = new Set(["completed", "busy", "failed", "no-answer", "canceled", "cancelled"]);

/** App route. Registers the workspace webhook, then settles open inbound calls. */
export async function settleOpenCalls(env: Env): Promise<Response> {
  const webhook = await ensurePostCallWebhook(env, 0);
  const correction = await sendSohailCorrection(env).catch(() => ({
    call_id: "",
    sid: "",
    status: "",
    error_code: "",
    error: "correction_failed",
    sent: false,
  }));
  const choice = await sendChoiceWording(env).catch(() => ({
    call_id: "",
    sid: "",
    status: "",
    error_code: "",
    error: "choice_failed",
    sent: false,
  }));
  let note = "";
  let settled: SettleHit[] = [];
  try {
    settled = await deliverInbound(env);
  } catch (err) {
    note = safeError(err instanceof Error ? err.message : "sweep");
  }
  const target = await describeCall(env, BACKFILL_CALL);
  const sms = await deliverOwnerText(env, RESEND_CALL).catch(() => ({
    call_id: RESEND_CALL,
    message_id: "",
    sid: "",
    status: "",
    error_code: "",
    error: "sms_failed",
    sent: false,
  }));
  return json({ ok: true, webhook, settled, note, target, sms, correction, choice });
}

/** Cron backup. Webhook registration is throttled; the conversation sweep runs every tick. */
export async function sweepInboundCalls(env: Env): Promise<SettleHit[]> {
  await ensurePostCallWebhook(env, 6 * 60 * 60 * 1000);
  try {
    await sendSohailCorrection(env).catch(() => undefined);
    await sendChoiceWording(env).catch(() => undefined);
    const settled = await deliverInbound(env);
    await retryFailedTexts(env);
    return settled;
  } catch (err) {
    console.error("inbound call sweep failed", safeError(err instanceof Error ? err.message : "sweep"));
    return [];
  }
}

/** A saved message is not a sent text. Retry the ones Twilio refused, except an opt-out. */
async function retryFailedTexts(env: Env): Promise<void> {
  const rows = await dbAll<{ key: string; value: string }>(
    env,
    "SELECT key, value FROM runtime_state WHERE key LIKE 'owner_sms:%' ORDER BY updated_at DESC LIMIT 20",
  ).catch(() => []);
  for (const row of rows) {
    let failed = false;
    try {
      const parsed = JSON.parse(row.value) as { ok?: boolean; errorCode?: string };
      failed = parsed.ok !== true && parsed.errorCode !== "21610";
    } catch {
      failed = false;
    }
    if (!failed) continue;
    const messageId = row.key.slice("owner_sms:".length);
    const message = await dbFirst<{ call_id: string }>(env, "SELECT call_id FROM call_messages WHERE id = ?", [messageId]).catch(
      () => null,
    );
    if (message?.call_id) await deliverOwnerText(env, message.call_id);
  }
}

const CORRECTION_KEY = "sms_correction:sohail_0241";

interface CorrectionText {
  call_id: string;
  sid: string;
  status: string;
  error_code: string;
  error: string;
  sent: boolean;
}

/**
 * One replacement text for the 02:41 Sohail call, built from the transcript and the summary.
 * The flag blocks every later attempt, including a second cron tick.
 */
async function sendSohailCorrection(env: Env): Promise<CorrectionText> {
  const none = (error: string, callId = ""): CorrectionText => ({
    call_id: callId,
    sid: "",
    status: "",
    error_code: "",
    error,
    sent: false,
  });
  const existing = await getState(env, CORRECTION_KEY).catch(() => null);
  if (existing === "sent") return none("sent");
  const rows = await dbAll<{
    id: string;
    call_id: string;
    caller_name: string;
    summary: string;
    spoken: string;
    called_at: string;
    transcript_json: string | null;
    call_summary: string | null;
    created_at: string;
  }>(
    env,
    `SELECT m.id, m.call_id, m.caller_name, m.summary, m.spoken, m.called_at,
            c.transcript_json, c.summary AS call_summary, c.created_at
     FROM call_messages m
     JOIN outbound_calls c ON c.id = m.call_id
     WHERE m.spoken LIKE '%02:41%'
       AND (
         m.caller_name LIKE '%Sohail%' OR m.caller_name LIKE '%Sohil%'
         OR m.spoken LIKE '%Sohail%' OR m.spoken LIKE '%Sohil%'
         OR IFNULL(c.transcript_json, '') LIKE '%Sohail%' OR IFNULL(c.transcript_json, '') LIKE '%Sohil%'
         OR IFNULL(c.summary, '') LIKE '%Sohail%' OR IFNULL(c.summary, '') LIKE '%Sohil%'
       )
     ORDER BY m.called_at DESC
     LIMIT 1`,
  ).catch(() => []);
  const row = rows[0];
  if (!row?.call_id) return none("not_found");
  const attempt = existing?.startsWith("retry:") ? Number(existing.slice("retry:".length)) || 0 : 0;
  const claimed = await claimCorrection(env);
  if (!claimed) return none("busy", row.call_id);
  try {
    const lines = linesFromJson(row.transcript_json);
    const calledAt = row.called_at || row.created_at;
    const brief = await summariseCall(env, lines, row.call_summary, calledAt);
    const name = brief.name || realName(row.caller_name) || "an unknown caller";
    let spoken = spokenForCaller(brief, name, calledAt, row.summary);
    if (callTextIsThin(spoken)) {
      const callerText = lines
        .filter((line) => line.role === "them")
        .map((line) => line.text.trim())
        .filter(Boolean)
        .join(" ");
      spoken = spokenCallMessage(name, calledAt, substantiveSentences(callerText, 2).join(" ") || row.summary || "");
    }
    if (callTextIsThin(spoken)) {
      await setState(env, CORRECTION_KEY, attempt >= 4 ? "sent" : `retry:${attempt + 1}`);
      return none("thin", row.call_id);
    }
    await dbRun(env, "UPDATE call_messages SET caller_name = ?, summary = ?, spoken = ? WHERE id = ?", [
      name,
      spoken,
      spoken,
      row.id,
    ]);
    await dbRun(env, "UPDATE outbound_calls SET summary = ?, updated_at = ? WHERE id = ?", [
      spoken,
      new Date().toISOString(),
      row.call_id,
    ]).catch(() => undefined);
    const sms = await deliverOwnerText(env, row.call_id, { correction: true });
    const accepted =
      sms.sent || ["queued", "accepted", "sending", "sent", "delivered", "received", "receiving"].includes(sms.status);
    await setState(env, CORRECTION_KEY, accepted || attempt >= 4 ? "sent" : `retry:${attempt + 1}`);
    return {
      call_id: row.call_id,
      sid: sms.sid,
      status: sms.status,
      error_code: sms.error_code,
      error: sms.error,
      sent: sms.sent,
    };
  } catch {
    await setState(env, CORRECTION_KEY, attempt >= 4 ? "sent" : `retry:${attempt + 1}`).catch(() => undefined);
    return none("correction_failed", row.call_id);
  }
}

const CHOICE_KEY = "sms_choice:sohail_0241";

/** One text in the choice wording for the 02:41 call, after the earlier summary used a different shape. */
async function sendChoiceWording(env: Env): Promise<CorrectionText> {
  const none = (error: string, callId = ""): CorrectionText => ({
    call_id: callId,
    sid: "",
    status: "",
    error_code: "",
    error,
    sent: false,
  });
  const existing = await getState(env, CHOICE_KEY).catch(() => null);
  if (existing === "sent" || existing === "sending") return none(existing);
  const rows = await dbAll<{
    id: string;
    call_id: string;
    caller_name: string;
    summary: string;
    spoken: string;
    called_at: string;
    transcript_json: string | null;
    call_summary: string | null;
    created_at: string;
  }>(
    env,
    `SELECT m.id, m.call_id, m.caller_name, m.summary, m.spoken, m.called_at,
            c.transcript_json, c.summary AS call_summary, c.created_at
     FROM call_messages m
     JOIN outbound_calls c ON c.id = m.call_id
     WHERE m.spoken LIKE '%02:41%'
       AND (
         m.caller_name LIKE '%Sohail%' OR m.caller_name LIKE '%Sohil%'
         OR m.spoken LIKE '%Sohail%' OR m.spoken LIKE '%Sohil%'
         OR IFNULL(c.transcript_json, '') LIKE '%Sohail%' OR IFNULL(c.transcript_json, '') LIKE '%Sohil%'
       )
     ORDER BY m.called_at DESC
     LIMIT 1`,
  ).catch(() => []);
  const row = rows[0];
  if (!row?.call_id) return none("not_found");
  if (hasChoiceQuestion(row.spoken) && /called to tell you/i.test(row.spoken) && !callTextIsThin(row.spoken)) {
    await setState(env, CHOICE_KEY, "sent");
    return none("already", row.call_id);
  }
  const claimed = await claimFlag(env, CHOICE_KEY);
  if (!claimed) return none("busy", row.call_id);
  try {
    const lines = linesFromJson(row.transcript_json);
    const calledAt = row.called_at || row.created_at;
    const brief = await summariseCall(env, lines, row.call_summary || row.summary, calledAt);
    const name = brief.name || realName(row.caller_name) || "an unknown caller";
    let spoken = spokenForCaller(brief, name, calledAt, row.summary);
    if (!hasChoiceQuestion(spoken) || callTextIsThin(spoken)) {
      const callerText = lines
        .filter((line) => line.role === "them")
        .map((line) => line.text.trim())
        .filter(Boolean)
        .join(" ");
      spoken = spokenCallMessage(name, calledAt, substantiveSentences(callerText, 2).join(" ") || row.summary || "");
    }
    if (callTextIsThin(spoken) || !hasChoiceQuestion(spoken)) {
      await setState(env, CHOICE_KEY, "retry");
      return none("thin", row.call_id);
    }
    if (spoken === row.spoken) {
      await setState(env, CHOICE_KEY, "sent");
      return none("already", row.call_id);
    }
    await dbRun(env, "UPDATE call_messages SET caller_name = ?, summary = ?, spoken = ? WHERE id = ?", [
      name,
      spoken,
      spoken,
      row.id,
    ]);
    await dbRun(env, "UPDATE outbound_calls SET summary = ?, updated_at = ? WHERE id = ?", [
      spoken,
      new Date().toISOString(),
      row.call_id,
    ]).catch(() => undefined);
    const sms = await deliverOwnerText(env, row.call_id, { correction: true });
    const accepted =
      sms.sent || ["queued", "accepted", "sending", "sent", "delivered", "received", "receiving"].includes(sms.status);
    await setState(env, CHOICE_KEY, accepted ? "sent" : "retry");
    return {
      call_id: row.call_id,
      sid: sms.sid,
      status: sms.status,
      error_code: sms.error_code,
      error: sms.error,
      sent: sms.sent,
    };
  } catch {
    await setState(env, CHOICE_KEY, "retry").catch(() => undefined);
    return none("choice_failed", row.call_id);
  }
}

async function claimFlag(env: Env, key: string): Promise<boolean> {
  const now = new Date().toISOString();
  const stale = new Date(Date.now() - 3 * 60 * 1000).toISOString();
  const changes = await dbRun(
    env,
    `INSERT INTO runtime_state (key, value, updated_at) VALUES (?, 'sending', ?)
     ON CONFLICT(key) DO UPDATE SET value = 'sending', updated_at = excluded.updated_at
     WHERE runtime_state.value NOT IN ('sending', 'sent')
        OR (runtime_state.value = 'sending' AND runtime_state.updated_at < ?)`,
    [key, now, stale],
  ).catch(() => 0);
  return changes === 1;
}

async function claimCorrection(env: Env): Promise<boolean> {
  return claimFlag(env, CORRECTION_KEY);
}

async function deliverInbound(env: Env): Promise<SettleHit[]> {
  const settled = await settleOpenInbound(env);
  const polished = await refreshUnread(env);
  const merged = [...settled];
  for (const hit of polished) {
    const index = merged.findIndex((row) => row.call_id === hit.call_id);
    if (index >= 0) merged[index] = hit;
    else merged.push(hit);
  }
  const backfill = await storedHit(env, BACKFILL_CALL);
  if (backfill && !merged.some((row) => row.call_id === backfill.call_id)) merged.push(backfill);
  return merged;
}

async function settleOpenInbound(env: Env): Promise<SettleHit[]> {
  const hits: SettleHit[] = [];
  const open = await loadOpenCalls(env);
  for (const id of [BACKFILL_CALL, POLLY_CALL]) {
    const extra = await loadOpenRow(env, id);
    if (extra && !open.some((row) => row.id === extra.id)) open.push(extra);
  }
  const closed = await closeDisconnected(env, open);
  hits.push(...closed);
  for (const row of open) {
    if (hits.some((hit) => hit.call_id === row.id)) continue;
    const local = await repairFromStored(env, row);
    if (local) hits.push(local);
  }
  const pending = open.filter((row) => !hits.some((hit) => hit.call_id === row.id));
  const networked = await settleFromElevenLabs(env, pending);
  hits.push(...networked);
  return hits;
}

async function describeCall(env: Env, id: string): Promise<{ found: boolean; status: string; has_conversation: boolean; screen: string }> {
  try {
    const row = await loadOpenRow(env, id);
    if (!row) return { found: false, status: "", has_conversation: false, screen: "" };
    const screen = await dbFirst<{ direction: string }>(env, "SELECT direction FROM call_screen WHERE call_id = ?", [id]);
    return {
      found: true,
      status: row.status,
      has_conversation: Boolean(row.conversation_id),
      screen: screen?.direction ?? "",
    };
  } catch (err) {
    return { found: false, status: "error", has_conversation: false, screen: safeError(err instanceof Error ? err.message : "read") };
  }
}

interface UnreadRow {
  id: string;
  call_id: string;
  caller_name: string;
  summary: string;
  spoken: string;
  called_at: string;
  transcript_json: string | null;
  call_summary: string | null;
  created_at: string;
  screen_name: string | null;
}

async function refreshUnread(env: Env): Promise<SettleHit[]> {
  const rows = await dbAll<UnreadRow>(
    env,
    `SELECT m.id, m.call_id, m.caller_name, m.summary, m.spoken, m.called_at,
            c.transcript_json, c.summary AS call_summary, c.created_at, s.caller_name AS screen_name
     FROM call_messages m
     JOIN outbound_calls c ON c.id = m.call_id
     LEFT JOIN call_screen s ON s.call_id = m.call_id
     WHERE m.read_at IS NULL
     ORDER BY m.created_at DESC
     LIMIT 20`,
  ).catch(() => []);
  const hits: SettleHit[] = [];
  for (const row of rows) {
    if (!needsPolish(row)) continue;
    const lines = linesFromJson(row.transcript_json);
    const calledAt = row.called_at || row.created_at;
    const brief = await summariseCall(env, lines, row.call_summary, calledAt);
    const name = brief.name || realName(row.caller_name) || realName(row.screen_name ?? "") || "an unknown caller";
    const spoken = spokenForCaller(brief, name, calledAt, row.summary);
    if (spoken === row.spoken && name === row.caller_name) continue;
    await dbRun(env, "UPDATE call_messages SET caller_name = ?, summary = ?, spoken = ? WHERE id = ?", [
      name,
      spoken,
      spoken,
      row.id,
    ]);
    await noteCaller(env, row.call_id, { name: brief.name, reason: brief.reason });
    await dbRun(env, "UPDATE outbound_calls SET summary = ?, updated_at = ? WHERE id = ?", [
      spoken,
      new Date().toISOString(),
      row.call_id,
    ]).catch(() => undefined);
    if (spoken !== row.spoken) await deliverOwnerText(env, row.call_id);
    hits.push({ call_id: row.call_id, message_id: row.id, spoken, summary: spoken, status: "completed" });
  }
  return hits;
}

function needsPolish(row: UnreadRow): boolean {
  const blob = `${row.spoken} ${row.summary} ${row.caller_name}`;
  if (/…|\.{3}|they said|you have a message|the user|identified as/i.test(blob)) return true;
  if (callTextIsThin(row.spoken)) return true;
  if (hasChoiceQuestion(row.spoken) && /called to tell you|\bcalled\./i.test(row.spoken)) return false;
  if (!hasChoiceQuestion(row.spoken)) return true;
  if ((row.spoken.match(/[.!?]/g) ?? []).length > 3) return true;
  if (/\btest call\b/i.test(row.caller_name) || /^(someone|caller|unknown|a test call)$/i.test(row.caller_name.trim())) return true;
  return false;
}

async function storedHit(env: Env, callId: string): Promise<SettleHit | null> {
  const message = await dbFirst<{ id: string; spoken: string; summary: string }>(
    env,
    "SELECT id, spoken, summary FROM call_messages WHERE call_id = ?",
    [callId],
  ).catch(() => null);
  if (!message) return null;
  return { call_id: callId, message_id: message.id, spoken: message.spoken, summary: message.summary, status: "completed" };
}

async function loadOpenCalls(env: Env): Promise<OpenCall[]> {
  const since = new Date(Date.now() - 2 * 24 * 60 * 60 * 1000).toISOString();
  const statusList = OPEN_STATUSES.map((status) => `'${status}'`).join(", ");
  const columns = "c.id, c.contact_name, c.conversation_id, c.status, c.summary, c.transcript_json, c.created_at, c.twilio_sid";
  try {
    return await dbAll<OpenCall>(
      env,
      `SELECT ${columns}
       FROM outbound_calls c
       LEFT JOIN call_screen s ON s.call_id = c.id
       WHERE c.created_at >= ?
         AND (s.direction = 'inbound' OR c.contact_name = 'Incoming call')
         AND (
           c.status IN (${statusList})
           OR lower(trim(ifnull(c.summary, ''))) IN ('a caller left a message.', 'a caller left a message')
           OR (
             c.status = 'completed'
             AND NOT EXISTS (SELECT 1 FROM call_messages m WHERE m.call_id = c.id)
           )
           OR EXISTS (
             SELECT 1 FROM call_messages m
             WHERE m.call_id = c.id
               AND lower(trim(m.summary)) IN ('a caller left a message.', 'a caller left a message', '')
           )
         )
       ORDER BY c.created_at DESC
       LIMIT 25`,
      [since],
    );
  } catch (err) {
    console.error("open call query failed", safeError(err instanceof Error ? err.message : "query"));
    const rows = await dbAll<OpenCall>(
      env,
      `SELECT id, contact_name, conversation_id, status, summary, transcript_json, created_at, twilio_sid
       FROM outbound_calls
       WHERE created_at >= ? AND contact_name = 'Incoming call'
       ORDER BY created_at DESC
       LIMIT 25`,
      [since],
    );
    return rows;
  }
}

function explicitPlaceholder(text: string): boolean {
  return /^a caller left a message\.?$/i.test(text.replace(/\s+/g, " ").trim());
}

async function repairFromStored(env: Env, row: OpenCall): Promise<SettleHit | null> {
  const said = storedSaid(row);
  if (!said) return null;
  if (row.status !== "completed" && !explicitPlaceholder(row.summary ?? "")) return null;
  await noteCaller(env, row.id, guessCaller(linesFromJson(row.transcript_json)));
  await dbRun(
    env,
    "UPDATE outbound_calls SET status = 'completed', summary = ?, updated_at = ? WHERE id = ?",
    [said, new Date().toISOString(), row.id],
  );
  return finishMessage(env, row.id, "completed");
}

function storedSaid(row: OpenCall): string {
  const summary = (row.summary ?? "").replace(/\s+/g, " ").trim();
  if (summary && !isPlaceholderSummary(summary)) return clip(summary, 500);
  const them = linesFromJson(row.transcript_json)
    .filter((line) => line.role === "them")
    .map((line) => line.text.trim())
    .filter(Boolean)
    .join(" ");
  return clip(them, 500);
}

async function settleFromElevenLabs(env: Env, rows: OpenCall[]): Promise<SettleHit[]> {
  const key = (env.ELEVENLABS_API_KEY ?? "").trim();
  if (!key || rows.length === 0) return [];
  const hits: SettleHit[] = [];
  const pending = new Map(rows.map((row) => [row.id, row]));
  for (const row of rows) {
    if (!row.conversation_id) continue;
    const detail = await elevenJson(env, `https://api.elevenlabs.io/v1/convai/conversations/${encodeURIComponent(row.conversation_id)}`);
    const hit = await settlePayload(env, detail, row.id);
    if (hit?.message_id || hit?.status === "failed") {
      hits.push(hit);
      pending.delete(row.id);
    }
  }
  const still = [...pending.values()];
  if (still.length === 0) return hits;
  const oldest = Math.min(...still.map((row) => Date.parse(row.created_at) || Date.now()));
  const after = Math.floor(oldest / 1000) - 600;
  const listed = await listRecentConversations(env, after);
  const owned = new Set(await ownedConversationIds(env, listed.map((item) => item.id)));
  const ranked = listed
    .filter((item) => !owned.has(item.id))
    .filter((item) => !item.status || item.status === "done" || item.status === "failed" || item.status === "completed")
    .sort((left, right) => gapToOpen(still, left.startMs) - gapToOpen(still, right.startMs));
  let fetched = 0;
  for (const item of ranked) {
    if (fetched >= 12) break;
    fetched += 1;
    const detail = await elevenJson(env, `https://api.elevenlabs.io/v1/convai/conversations/${encodeURIComponent(item.id)}`);
    if (!detail) continue;
    const userId = userIdFrom(detail);
    let row = userId ? pending.get(userId) : undefined;
    if (userId && userId !== row?.id) continue;
    if (!row) {
      row = closestCall(
        still.filter((candidate) => pending.has(candidate.id) && !candidate.conversation_id && linesFromJson(candidate.transcript_json).length === 0),
        item.startMs,
      );
    }
    if (!row) continue;
    const hit = await settlePayload(env, detail, row.id);
    if (hit?.message_id || hit?.status === "failed") {
      hits.push(hit);
      pending.delete(row.id);
      owned.add(item.id);
    }
  }
  return hits;
}

async function listRecentConversations(env: Env, afterUnix: number): Promise<ListedConversation[]> {
  const agent = (env.ELEVENLABS_AGENT_ID ?? "").trim();
  if (!agent) return [];
  const found: ListedConversation[] = [];
  let cursor = "";
  for (let page = 0; page < 2; page += 1) {
    const url = new URL("https://api.elevenlabs.io/v1/convai/conversations");
    url.searchParams.set("agent_id", agent);
    url.searchParams.set("page_size", "40");
    url.searchParams.set("call_start_after_unix", String(Math.max(0, afterUnix)));
    if (cursor) url.searchParams.set("cursor", cursor);
    const payload = await elevenJson(env, url.toString());
    if (!isRecord(payload) || !Array.isArray(payload.conversations)) break;
    for (const item of payload.conversations) {
      const listed = readListed(item);
      if (listed) found.push(listed);
    }
    cursor = typeof payload.next_cursor === "string" ? payload.next_cursor : "";
    if (!cursor || payload.has_more === false) break;
  }
  return found;
}

function readListed(value: unknown): ListedConversation | null {
  if (!isRecord(value)) return null;
  const id = typeof value.conversation_id === "string" ? value.conversation_id : "";
  if (!id) return null;
  const start = typeof value.start_time_unix_secs === "number" ? value.start_time_unix_secs * 1000 : Number.NaN;
  const status = typeof value.status === "string" ? value.status : "";
  return { id, status, startMs: start };
}

function gapToOpen(rows: OpenCall[], startMs: number): number {
  if (!Number.isFinite(startMs)) return Number.MAX_SAFE_INTEGER;
  let best = Number.MAX_SAFE_INTEGER;
  for (const row of rows) {
    const created = Date.parse(row.created_at);
    if (!Number.isFinite(created)) continue;
    best = Math.min(best, Math.abs(created - startMs));
  }
  return best;
}

function closestCall(rows: OpenCall[], startMs: number): OpenCall | undefined {
  if (!Number.isFinite(startMs)) return undefined;
  let best: OpenCall | undefined;
  let bestGap = 180_000;
  for (const row of rows) {
    const created = Date.parse(row.created_at);
    if (!Number.isFinite(created)) continue;
    const gap = Math.abs(created - startMs);
    if (gap <= bestGap) {
      best = row;
      bestGap = gap;
    }
  }
  return best;
}

async function ownedConversationIds(env: Env, ids: string[]): Promise<string[]> {
  const unique = [...new Set(ids.filter(Boolean))].slice(0, 40);
  if (unique.length === 0) return [];
  const marks = unique.map(() => "?").join(", ");
  const rows = await dbAll<{ conversation_id: string }>(
    env,
    `SELECT conversation_id FROM outbound_calls WHERE conversation_id IN (${marks})`,
    unique,
  ).catch(() => []);
  return rows.map((row) => row.conversation_id);
}

async function settlePayload(env: Env, payload: unknown, preferredId = ""): Promise<SettleHit | null> {
  if (!isRecord(payload)) return null;
  const conversationId = typeof payload.conversation_id === "string" ? payload.conversation_id : "";
  const userId = userIdFrom(payload) || preferredId;
  const row = await findInbound(env, userId, conversationId);
  if (!row) return null;
  const read = readConversation(payload);
  if (!read) return null;
  const done = read.status === "done" || read.status === "completed";
  const failed = read.status === "failed";
  if (!done && !failed) return null;
  if (failed && read.lines.length === 0 && !read.summary) {
    await dbRun(env, "UPDATE outbound_calls SET status = 'failed', error = ?, updated_at = ? WHERE id = ?", [
      "The call failed.",
      new Date().toISOString(),
      row.id,
    ]);
    return { call_id: row.id, message_id: null, spoken: null, summary: null, status: "failed" };
  }
  const brief = await summariseCall(env, read.lines, read.summary, row.created_at);
  const said = brief.spoken || brief.said || brief.reason || stripPhones(read.summary ?? "") || guessCaller(read.lines).reason;
  const clean = spokenCallMessage(brief.name, row.created_at, said);
  if (!clean || isPlaceholderSummary(clean)) {
    if (failed) {
      await dbRun(env, "UPDATE outbound_calls SET status = 'failed', error = ?, updated_at = ? WHERE id = ?", [
        "The call failed.",
        new Date().toISOString(),
        row.id,
      ]);
      return { call_id: row.id, message_id: null, spoken: null, summary: null, status: "failed" };
    }
    return { call_id: row.id, message_id: null, spoken: null, summary: null, status: "unresolved" };
  }
  await ensureInboundScreen(env, row);
  await noteCaller(env, row.id, { name: brief.name || guessCaller(read.lines).name, reason: brief.reason });
  await dbRun(
    env,
    `UPDATE outbound_calls
     SET status = 'completed', summary = ?, transcript_json = ?, conversation_id = COALESCE(?, conversation_id), updated_at = ?
     WHERE id = ?`,
    [clean, JSON.stringify(read.lines.slice(0, 80)), conversationId || null, new Date().toISOString(), row.id],
  );
  return finishMessage(env, row.id, "completed");
}

async function finishMessage(env: Env, callId: string, status: string): Promise<SettleHit> {
  await rememberInboundMessage(env, callId).catch(() => false);
  const message = await dbFirst<{ id: string; spoken: string; summary: string }>(
    env,
    "SELECT id, spoken, summary FROM call_messages WHERE call_id = ?",
    [callId],
  ).catch(() => null);
  return {
    call_id: callId,
    message_id: message?.id ?? null,
    spoken: message?.spoken ?? null,
    summary: message?.summary ?? null,
    status,
  };
}

async function findInbound(env: Env, id: string, conversationId: string): Promise<OpenCall | null> {
  if (/^call_[A-Za-z0-9]+$/.test(id)) {
    const byId = await loadOpenRow(env, id);
    if (byId) return byId;
  }
  if (!conversationId) return null;
  const row = await dbFirst<{ id: string }>(env, "SELECT id FROM outbound_calls WHERE conversation_id = ?", [conversationId]).catch(
    () => null,
  );
  if (!row?.id) return null;
  return loadOpenRow(env, row.id);
}

async function loadOpenRow(env: Env, id: string): Promise<OpenCall | null> {
  return dbFirst<OpenCall>(
    env,
    "SELECT id, contact_name, conversation_id, status, summary, transcript_json, created_at, twilio_sid FROM outbound_calls WHERE id = ?",
    [id],
  ).catch(() => null);
}

/** Polly calls have no ElevenLabs conversation. When Twilio has already hung up, store the message. */
export async function settleDisconnectedCall(env: Env, sid: string, twilioStatus: string): Promise<void> {
  if (!sid || !TERMINAL_TWILIO.has(twilioStatus)) return;
  const found = await dbFirst<{ id: string }>(env, "SELECT id FROM outbound_calls WHERE twilio_sid = ?", [sid]).catch(() => null);
  if (!found?.id) return;
  const row = await loadOpenRow(env, found.id);
  if (!row || row.conversation_id || !OPEN_STATUSES.includes(row.status)) return;
  await finishLocal(env, row, twilioStatus);
}

async function closeDisconnected(env: Env, rows: OpenCall[]): Promise<SettleHit[]> {
  const hits: SettleHit[] = [];
  for (const row of rows) {
    if (row.conversation_id || !OPEN_STATUSES.includes(row.status)) continue;
    const sid = (row.twilio_sid ?? "").trim();
    if (!sid) continue;
    const live = await twilioCallStatus(env, sid);
    if (!TERMINAL_TWILIO.has(live)) continue;
    const hit = await finishLocal(env, row, live);
    if (hit) hits.push(hit);
  }
  return hits;
}

async function finishLocal(env: Env, row: OpenCall, live: string): Promise<SettleHit | null> {
  const lines = linesFromJson(row.transcript_json);
  const said = storedSaid(row);
  if (!said) {
    const status = live === "completed" ? "completed" : "failed";
    await dbRun(env, "UPDATE outbound_calls SET status = ?, error = ?, updated_at = ? WHERE id = ?", [
      status,
      live === "completed" ? null : "The caller hung up.",
      new Date().toISOString(),
      row.id,
    ]);
    return { call_id: row.id, message_id: null, spoken: null, summary: null, status };
  }
  const brief = await summariseCall(env, lines, said, row.created_at);
  const clean = brief.spoken || spokenCallMessage(brief.name, row.created_at, brief.said || said);
  if (!clean) return null;
  await ensureInboundScreen(env, row);
  await noteCaller(env, row.id, { name: brief.name || guessCaller(lines).name, reason: brief.reason });
  await dbRun(env, "UPDATE outbound_calls SET status = 'completed', summary = ?, updated_at = ? WHERE id = ?", [
    clean,
    new Date().toISOString(),
    row.id,
  ]);
  return finishMessage(env, row.id, "completed");
}

async function twilioCallStatus(env: Env, sid: string): Promise<string> {
  const account = (env.TWILIO_ACCOUNT_SID ?? "").trim();
  const token = (env.TWILIO_AUTH_TOKEN ?? "").trim();
  if (!account || !token || !sid) return "";
  try {
    const response = await fetch(
      `https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(account)}/Calls/${encodeURIComponent(sid)}.json`,
      {
        headers: { authorization: `Basic ${btoa(`${account}:${token}`)}` },
        signal: AbortSignal.timeout(10_000),
      },
    );
    if (!response.ok) return "";
    const body = (await response.json()) as { status?: unknown };
    return typeof body.status === "string" ? body.status : "";
  } catch {
    return "";
  }
}

async function ensureInboundScreen(env: Env, row: OpenCall): Promise<void> {
  const screen = await dbFirst<{ direction: string }>(env, "SELECT direction FROM call_screen WHERE call_id = ?", [row.id]).catch(
    () => null,
  );
  if (screen) return;
  if (row.contact_name !== "Incoming call") return;
  await dbRun(
    env,
    `INSERT INTO call_screen
      (call_id, direction, caller_phone, caller_name, reason, personal_allowed, personal_requested, personal_note, conference_name, named_notified)
     VALUES (?, 'inbound', '', '', '', 0, 0, '', ?, 0)`,
    [row.id, `jarvis-${row.id}`],
  ).catch(() => undefined);
}

async function noteCaller(env: Env, callId: string, guess: { name: string; reason: string }): Promise<void> {
  const name = realName(guess.name);
  const reason = clip(stripPhones(guess.reason), 240);
  if (!name && !reason) return;
  await dbRun(
    env,
    `UPDATE call_screen
     SET caller_name = CASE WHEN ? != '' THEN ? ELSE caller_name END,
         reason = CASE WHEN ? != '' THEN ? ELSE reason END
     WHERE call_id = ?`,
    [name, name, reason, reason, callId],
  ).catch(() => undefined);
}

async function summariseCall(env: Env, lines: CallLine[], analysis: string | null, calledAt: string): Promise<Brief> {
  const guessed = guessCaller(lines);
  const name = realName(guessed.name);
  const fallbackBody = callerSentence(lines) || plainAnalysis(analysis);
  const fallbackSpoken = spokenCallMessage(name, calledAt, fallbackBody);
  const fallback: Brief = {
    name,
    reason: stripPhones(guessed.reason).slice(0, 240),
    said: fallbackBody,
    spoken: fallbackSpoken,
  };
  const transcript = lines
    .map((line) => `${line.role === "them" ? "Caller" : "JARVIS"}: ${line.text}`)
    .join("\n")
    .slice(0, 4000);
  if (!transcript && !analysis) return fallback;
  const time = messageClock(calledAt);
  const result = await completeChat(
    env,
    [
      {
        role: "system",
        content: [
          "You are JARVIS, Master Hadi's butler, telling him about a call that just finished.",
          'Reply with JSON only, no markdown: {"name":"","spoken":""}',
          "name is the caller's name if they gave one, otherwise an empty string.",
          "Never use Master Hadi, a test label, or the word caller as the name.",
          "spoken is only what the caller wanted you to pass on, in one or two short sentences.",
          "Do not start with Sir. Do not mention the clock. Skip greetings and filler such as good evening, hello, and um.",
          "Include a callback number only if they gave one. Do not invent a name, a request, or a number.",
          "No ellipsis. Do not analyse the transcript. Do not say the user or identified as.",
        ].join(" "),
      },
      {
        role: "user",
        content: `Time: ${time}\nAnalysis: ${plainAnalysis(analysis)}\n\n${transcript}`,
      },
    ],
    null,
    { timeoutMs: 12_000, maxTokens: 280 },
  );
  if (!result.ok) return fallback;
  const parsed = readBrief(result.message.content ?? "");
  if (!parsed) return fallback;
  const picked = realName(parsed.name) || name;
  const body = usableMessage(parsed.spoken) ? parsed.spoken : usableMessage(parsed.said) ? parsed.said : fallbackBody;
  return {
    name: picked,
    reason: stripPhones(parsed.reason).slice(0, 240),
    said: body,
    spoken: spokenCallMessage(picked, calledAt, body),
  };
}

function plainAnalysis(analysis: string | null): string {
  const text = stripPhones(analysis ?? "");
  if (!text || /\b(the user|identified as)\b/i.test(text)) return "";
  return text;
}

function callerSentence(lines: CallLine[]): string {
  const text = lines
    .filter((line) => line.role === "them")
    .map((line) => line.text.trim())
    .filter(Boolean)
    .join(" ");
  return substantiveSentences(text, 2).join(" ");
}

function usableMessage(text: string): boolean {
  const clean = text.replace(/\s+/g, " ").trim();
  if (!clean) return false;
  if (/…|\.{3}/.test(clean)) return false;
  if (/\b(the user|identified as|they said)\b/i.test(clean)) return false;
  return true;
}

function readBrief(text: string): Brief | null {
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  if (start < 0 || end <= start) return null;
  const parsed = parseJsonValue(text.slice(start, end + 1));
  if (!isRecord(parsed)) return null;
  return {
    name: typeof parsed.name === "string" ? parsed.name : "",
    reason: typeof parsed.reason === "string" ? parsed.reason : "",
    said: typeof parsed.said === "string" ? parsed.said : "",
    spoken: typeof parsed.spoken === "string" ? parsed.spoken : "",
  };
}

function userIdFrom(payload: unknown): string {
  if (!isRecord(payload)) return "";
  if (typeof payload.user_id === "string" && /^call_[A-Za-z0-9]+$/.test(payload.user_id)) return payload.user_id;
  const initiation = isRecord(payload.conversation_initiation_client_data) ? payload.conversation_initiation_client_data : null;
  const nested = initiation && typeof initiation.user_id === "string" ? initiation.user_id : "";
  return /^call_[A-Za-z0-9]+$/.test(nested) ? nested : "";
}

function linesFromJson(raw: string | null): CallLine[] {
  const parsed = parseJsonValue(raw);
  if (!Array.isArray(parsed)) return [];
  const lines: CallLine[] = [];
  for (const item of parsed) {
    if (!isRecord(item)) continue;
    const text = typeof item.text === "string" ? item.text : typeof item.message === "string" ? item.message : "";
    const trimmed = text.trim();
    if (!trimmed) continue;
    const role = item.role === "user" || item.role === "them" ? "them" : "assistant";
    lines.push({ role, text: trimmed.slice(0, 500) });
  }
  return lines;
}

/** Keeps a name we already stored when the summary model did not return one. */
function spokenForCaller(brief: Brief, name: string, calledAt: string, fallback: string): string {
  const body = brief.said || fallback;
  if (brief.name) return brief.spoken || spokenCallMessage(name, calledAt, body);
  return spokenCallMessage(name, calledAt, body);
}

function realName(name: string): string {
  const clean = name.replace(/\+\d+/g, "").replace(/\s+/g, " ").trim();
  if (!clean || /^(someone|caller|unknown|an unknown caller|incoming call|user|test|test call|a test call|master hadi)$/i.test(clean)) return "";
  if (/\btest call\b/i.test(clean)) return "";
  if (!/^[A-Za-z][A-Za-z' .-]{0,60}$/.test(clean)) return "";
  return clean.slice(0, 80);
}

function stripPhones(text: string): string {
  return text
    .replace(/\+\d[\d\s()-]{5,}/g, " ")
    .replace(/\b(?:\d[\s-]?){8,}\d\b/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

async function webhookSecrets(env: Env): Promise<string[]> {
  const secrets: string[] = [];
  const stored = await getState(env, WEBHOOK_SECRET_KEY).catch(() => null);
  if (stored?.trim()) secrets.push(stored.trim());
  const fromEnv = env.ELEVENLABS_WEBHOOK_SECRET?.trim() ?? "";
  if (fromEnv && !secrets.includes(fromEnv)) secrets.push(fromEnv);
  return secrets;
}

async function ensurePostCallWebhook(env: Env, minIntervalMs: number): Promise<WebhookEnsure> {
  const failed = (step: string, status = 0, error = ""): WebhookEnsure => ({
    ok: false,
    created: false,
    attached: false,
    status,
    step,
    error,
  });
  const key = (env.ELEVENLABS_API_KEY ?? "").trim();
  if (!key) return failed("no_key");
  try {
    if (minIntervalMs > 0) {
      const last = await getState(env, WEBHOOK_ENSURED_KEY);
      const stamp = last ? Date.parse(last) : 0;
      if (Number.isFinite(stamp) && Date.now() - stamp < minIntervalMs) {
        return { ok: true, created: false, attached: true, status: 200, step: "cached", error: "" };
      }
    }
    const storedId = (await getState(env, WEBHOOK_ID_KEY))?.trim() ?? "";
    const storedSecret = (await getState(env, WEBHOOK_SECRET_KEY))?.trim() ?? "";
    let webhookId = storedId;
    let created = false;
    if (!webhookId || !storedSecret) {
      const listed = await elevenSend(env, "GET", "https://api.elevenlabs.io/v1/workspace/webhooks");
      const existing = listed.ok ? listedWebhookId(listed.payload) : "";
      if (existing && storedSecret) webhookId = existing;
    }
    if (!webhookId || !(await getState(env, WEBHOOK_SECRET_KEY))?.trim()) {
      const made = await elevenSend(env, "POST", "https://api.elevenlabs.io/v1/workspace/webhooks", {
        settings: { auth_type: "hmac", name: "JARVIS post-call", webhook_url: PUBLIC_POST_CALL_URL },
      });
      if (!made.ok || !isRecord(made.payload)) return failed("create", made.status, made.error);
      const id = typeof made.payload.webhook_id === "string" ? made.payload.webhook_id : "";
      const secret = typeof made.payload.webhook_secret === "string" ? made.payload.webhook_secret : "";
      if (!id || !secret) return failed("create", made.status, "Webhook id or secret was missing.");
      await setState(env, WEBHOOK_ID_KEY, id);
      await setState(env, WEBHOOK_SECRET_KEY, secret);
      webhookId = id;
      created = true;
    }
    const attached = await elevenSend(env, "PATCH", "https://api.elevenlabs.io/v1/convai/settings", {
      webhooks: { post_call_webhook_id: webhookId, events: ["transcript"], transcript_format: "json" },
    });
    if (!attached.ok) return failed("attach", attached.status, attached.error);
    await setState(env, WEBHOOK_ENSURED_KEY, new Date().toISOString());
    return { ok: true, created, attached: true, status: attached.status, step: created ? "created" : "attached", error: "" };
  } catch (err) {
    const error = safeError(err instanceof Error ? err.message : "webhook");
    console.error("elevenlabs post-call webhook ensure failed", error);
    return failed("exception", 0, error);
  }
}

function listedWebhookId(payload: unknown): string {
  const list = isRecord(payload) && Array.isArray(payload.webhooks) ? payload.webhooks : [];
  for (const item of list) {
    if (!isRecord(item)) continue;
    const url = typeof item.webhook_url === "string" ? item.webhook_url : "";
    const id = typeof item.webhook_id === "string" ? item.webhook_id : "";
    if (id && url.replace(/\/$/, "") === PUBLIC_POST_CALL_URL) return id;
  }
  return "";
}

async function elevenJson(env: Env, url: string): Promise<unknown | null> {
  const sent = await elevenSend(env, "GET", url);
  return sent.ok ? sent.payload : null;
}

async function elevenSend(
  env: Env,
  method: "GET" | "POST" | "PATCH",
  url: string,
  body?: unknown,
): Promise<{ ok: boolean; status: number; payload: unknown; error: string }> {
  const key = (env.ELEVENLABS_API_KEY ?? "").trim();
  if (!key) return { ok: false, status: 0, payload: null, error: "no_key" };
  try {
    const headers: Record<string, string> = { "xi-api-key": key };
    const init: RequestInit = { method, redirect: "follow", signal: AbortSignal.timeout(20_000), headers };
    if (body) {
      headers["content-type"] = "application/json";
      init.body = JSON.stringify(body);
    }
    const response = await fetch(url, init);
    const text = await response.text();
    if (!response.ok) {
      console.error("elevenlabs request failed", method, response.status);
      return { ok: false, status: response.status, payload: null, error: `HTTP ${response.status}` };
    }
    return { ok: true, status: response.status, payload: parseJsonValue(text), error: "" };
  } catch (err) {
    const error = safeError(err instanceof Error ? err.message : "network");
    console.error("elevenlabs request failed", method, error);
    return { ok: false, status: 0, payload: null, error };
  }
}
