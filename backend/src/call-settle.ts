import { isPlaceholderSummary, rememberInboundMessage } from "./call-messages";
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

/** App route. Registers the workspace webhook, then settles open inbound calls. */
export async function settleOpenCalls(env: Env): Promise<Response> {
  const webhook = await ensurePostCallWebhook(env, 0);
  let note = "";
  let settled: SettleHit[] = [];
  try {
    settled = await settleOpenInbound(env);
  } catch (err) {
    note = safeError(err instanceof Error ? err.message : "sweep");
  }
  const target = await describeCall(env, BACKFILL_CALL);
  return json({ ok: true, webhook, settled, note, target });
}

/** Cron backup. Webhook registration is throttled; the conversation sweep runs every tick. */
export async function sweepInboundCalls(env: Env): Promise<SettleHit[]> {
  await ensurePostCallWebhook(env, 6 * 60 * 60 * 1000);
  try {
    return await settleOpenInbound(env);
  } catch (err) {
    console.error("inbound call sweep failed", safeError(err instanceof Error ? err.message : "sweep"));
    return [];
  }
}

async function settleOpenInbound(env: Env): Promise<SettleHit[]> {
  const hits: SettleHit[] = [];
  const open = await loadOpenCalls(env);
  const target = await loadOpenRow(env, BACKFILL_CALL);
  if (target && !open.some((row) => row.id === target.id)) open.push(target);
  for (const row of open) {
    const local = await repairFromStored(env, row);
    if (local) hits.push(local);
  }
  const pending = open.filter((row) => !hits.some((hit) => hit.call_id === row.id && hit.message_id));
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

async function loadOpenCalls(env: Env): Promise<OpenCall[]> {
  const since = new Date(Date.now() - 2 * 24 * 60 * 60 * 1000).toISOString();
  const statusList = OPEN_STATUSES.map((status) => `'${status}'`).join(", ");
  const columns = "c.id, c.contact_name, c.conversation_id, c.status, c.summary, c.transcript_json, c.created_at";
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
      `SELECT id, contact_name, conversation_id, status, summary, transcript_json, created_at
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
  return clip(stripPhones(them), 500);
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
  const brief = await summariseCall(env, read.lines, read.summary);
  const said = brief.said || brief.reason || stripPhones(read.summary ?? "") || guessCaller(read.lines).reason;
  const clean = clip(stripPhones(said), 500);
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
    "SELECT id, contact_name, conversation_id, status, summary, transcript_json, created_at FROM outbound_calls WHERE id = ?",
    [id],
  ).catch(() => null);
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

async function summariseCall(env: Env, lines: CallLine[], analysis: string | null): Promise<Brief> {
  const guessed = guessCaller(lines);
  const fallback: Brief = {
    name: realName(guessed.name),
    reason: clip(stripPhones(guessed.reason), 240),
    said: clip(stripPhones(analysis ?? ""), 500),
  };
  const transcript = lines
    .map((line) => `${line.role === "them" ? "Caller" : "JARVIS"}: ${line.text}`)
    .join("\n")
    .slice(0, 4000);
  if (!transcript && !analysis) return fallback;
  const result = await completeChat(
    env,
    [
      {
        role: "system",
        content: [
          "You write a phone message for a British butler.",
          'Reply with JSON only, no markdown: {"name":"","reason":"","said":""}',
          "name is the caller's name if they gave one, otherwise an empty string.",
          "reason is a few words on why they called.",
          "said is one sentence of what to pass on. Do not include phone numbers.",
          "Do not invent a name or a message.",
        ].join(" "),
      },
      {
        role: "user",
        content: `Analysis: ${analysis ?? ""}\n\n${transcript}`,
      },
    ],
    null,
    { timeoutMs: 12_000, maxTokens: 180 },
  );
  if (!result.ok) return fallback;
  const parsed = readBrief(result.message.content ?? "");
  if (!parsed) return fallback;
  return {
    name: realName(parsed.name) || fallback.name,
    reason: clip(stripPhones(parsed.reason), 240) || fallback.reason,
    said: clip(stripPhones(parsed.said), 500) || fallback.said,
  };
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

function realName(name: string): string {
  const clean = name.replace(/\+\d+/g, "").replace(/\s+/g, " ").trim();
  if (!clean || /^(someone|caller|unknown|incoming call|user|master hadi)$/i.test(clean)) return "";
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
