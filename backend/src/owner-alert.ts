import { dbAll, dbFirst, dbRun, getState, setState } from "./db";
import { conversationIdFromTwiml, safeError, toE164, twilioRequestSigned, type CallLine } from "./calls";
import { apiError, isRecord, json, newId, nowIso } from "./http";
import { pushNotice } from "./screening";
import type { Env } from "./types";

export interface CallSettings {
  mobile_number: string;
  quiet_start: string;
  quiet_end: string;
  max_calls_per_day: number;
  urgent_only: number;
  question_timeout_seconds: number;
  worker_origin: string;
}

const DEFAULTS: CallSettings = {
  mobile_number: "",
  quiet_start: "22:00",
  quiet_end: "08:00",
  max_calls_per_day: 3,
  urgent_only: 0,
  question_timeout_seconds: 40,
  worker_origin: "",
};

export function clampTimeout(value: number): number {
  if (!Number.isFinite(value)) return 40;
  return Math.min(45, Math.max(30, Math.round(value)));
}

export function clampDailyCap(value: number): number {
  if (!Number.isFinite(value)) return 3;
  return Math.min(5, Math.max(0, Math.round(value)));
}

export function inQuietHours(nowMinutes: number, start: string, end: string): boolean {
  const startM = clockMinutes(start);
  const endM = clockMinutes(end);
  if (startM === null || endM === null || startM === endM) return false;
  if (startM < endM) return nowMinutes >= startM && nowMinutes < endM;
  return nowMinutes >= startM || nowMinutes < endM;
}

export function londonMinutes(date: Date): number {
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Europe/London",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(date);
  let hour = Number(parts.find((part) => part.type === "hour")?.value ?? "0");
  const minute = Number(parts.find((part) => part.type === "minute")?.value ?? "0");
  if (hour === 24) hour = 0;
  return hour * 60 + minute;
}

export function londonDay(date: Date): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: "Europe/London",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(date);
}

export function ownerSummaryLine(summary: string): string {
  return `Hello, this is JARVIS. ${summary} Say details to hear more, or tell me what you would like me to do.`;
}

export function mayCall(input: { quiet: boolean; countToday: number; max: number; urgentOnly: boolean; urgent: boolean }): "call" | "push" {
  if (input.quiet || input.max <= 0) return "push";
  if (input.urgentOnly && !input.urgent) return "push";
  if (input.countToday >= input.max) return "push";
  return "call";
}

export function isOwnerWebhook(method: string, path: string): boolean {
  return method === "POST" && /^\/calls\/owner\/alert_[A-Za-z0-9]+(?:\/(?:key|speak))?$/.test(path);
}

export async function readOwnerMobile(env: Env): Promise<string | null> {
  const settings = await readCallSettings(env);
  const saved = settings.mobile_number ? toE164(settings.mobile_number) : null;
  return saved || toE164(env.OWNER_PHONE ?? "");
}

export async function readCallSettings(env: Env): Promise<CallSettings> {
  try {
    const row = await dbFirst<CallSettings>(env, "SELECT * FROM call_settings WHERE id = 'default'");
    return row ? { ...DEFAULTS, ...row } : DEFAULTS;
  } catch {
    return DEFAULTS;
  }
}

export async function rememberOrigin(env: Env, origin: string): Promise<void> {
  if (!origin.startsWith("http://") && !origin.startsWith("https://")) return;
  try {
    await dbRun(
      env,
      `INSERT INTO call_settings
        (id, mobile_number, quiet_start, quiet_end, max_calls_per_day, urgent_only, question_timeout_seconds, worker_origin, updated_at)
       VALUES ('default', '', '22:00', '08:00', 3, 0, 40, ?, ?)
       ON CONFLICT(id) DO UPDATE SET worker_origin = excluded.worker_origin, updated_at = excluded.updated_at`,
      [origin, nowIso()],
    );
  } catch {
    // Settings are applied with schema.sql. Missing table does not stop the request.
  }
}

export async function reportProblem(
  env: Env,
  problem: { sourceId: string; kind: string; urgent: boolean; summary: string; detail: string },
): Promise<void> {
  try {
    const settings = await readCallSettings(env);
    const now = new Date();
    const day = londonDay(now);
    const quiet = inQuietHours(londonMinutes(now), settings.quiet_start, settings.quiet_end);
    let count = 0;
    try {
      const rows = await dbAll<{ n: number }>(
        env,
        "SELECT COUNT(*) AS n FROM owner_alerts WHERE channel = 'call' AND day = ?",
        [day],
      );
      count = Number(rows[0]?.n ?? 0);
    } catch {
      count = 0;
    }
    const channel = mayCall({
      quiet,
      countToday: count,
      max: settings.max_calls_per_day,
      urgentOnly: settings.urgent_only === 1,
      urgent: problem.urgent,
    });
    const id = newId("alert");
    const summary = clip(problem.summary, 240);
    const detail = clip(problem.detail, 800);
    const changes = await dbRun(
      env,
      `INSERT OR IGNORE INTO owner_alerts
        (id, source_id, kind, summary, detail, urgent, channel, day, call_id, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, ?)`,
      [id, problem.sourceId, problem.kind, summary, detail, problem.urgent ? 1 : 0, channel, day, nowIso()],
    );
    if (changes === 0) return;
    if (channel === "call") {
      const placed = await placeOwnerCall(env, settings, id, summary);
      if (placed) return;
      await dbRun(env, "UPDATE owner_alerts SET channel = 'push' WHERE id = ?", [id]);
    }
    await pushNotice(env, "JARVIS", summary, { alert_id: id }, "JARVIS_ALERT");
  } catch (err) {
    console.error("owner alert failed", safeError(err instanceof Error ? err.message : "alert"));
  }
}

export async function noteOwnerReply(env: Env, call: { id: string; transcript: CallLine[] }): Promise<void> {
  const said = [...call.transcript].reverse().find((line) => line.role === "them" && line.text.trim());
  const text = said?.text.trim() ?? "";
  const bare = text.replace(/[.!?]/g, "").trim();
  if (text.length < 8 || /^(press )?1$|^(the |more |hear the |tell me the )?details?$/i.test(bare)) return;
  try {
    const alert = await dbFirst<{ id: string }>(env, "SELECT id FROM owner_alerts WHERE call_id = ?", [call.id]);
    if (!alert) return;
    const now = nowIso();
    const id = `task_owner_${call.id}`;
    const goal = `You said on JARVIS's call: ${text.slice(0, 240)}`;
    await dbRun(
      env,
      `INSERT INTO tasks
        (id, goal, status, schedule, scheduled_job_id, error, result_summary, plan_attempts, planner_note, locked_until, created_at, updated_at, completed_at)
       VALUES (?, ?, 'completed', NULL, NULL, NULL, ?, 0, 'owner_reply', NULL, ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET goal = excluded.goal, result_summary = excluded.result_summary, updated_at = excluded.updated_at`,
      [id, goal, "Noted from the call JARVIS placed to you.", now, now, now],
    );
  } catch (err) {
    console.error("owner reply was not stored", safeError(err instanceof Error ? err.message : "reply"));
  }
}

export async function sweepOwner(env: Env): Promise<void> {
  const relay = await import("./relay");
  await relay.sweepQuestions(env);
  await checkBalance(env);
}

export async function handleOwnerWebhook(request: Request, env: Env, path: string): Promise<Response> {
  const token = (env.TWILIO_AUTH_TOKEN ?? "").trim();
  const params = await formParams(request);
  const valid = await twilioRequestSigned(request, params, token);
  if (!valid) return xml("<Response><Hangup/></Response>", 403);
  const parts = path.split("/").filter(Boolean);
  const id = parts[2] ?? "";
  const leaf = parts[3] ?? "";
  const alert = await dbFirst<{ summary: string; detail: string; call_id: string | null }>(
    env,
    "SELECT summary, detail, call_id FROM owner_alerts WHERE id = ?",
    [id],
  );
  if (!alert) return xml(say("Hello, this is JARVIS. This call is not set up. Goodbye."), 404);
  const origin = new URL(request.url).origin;
  if (!leaf) {
    return xml(
      `<Response><Gather input="dtmf speech" numDigits="1" timeout="4" speechTimeout="auto" action="${escapeXml(`${origin}/calls/owner/${id}/key`)}" method="POST"><Say language="en-GB">This is JARVIS. Press 1 for the details, or say details. Or stay on the line.</Say></Gather><Redirect method="POST">${escapeXml(`${origin}/calls/owner/${id}/speak`)}</Redirect></Response>`,
      200,
    );
  }
  const detail = leaf === "key" && (params.Digits === "1" || /detail/i.test(params.SpeechResult ?? ""));
  return speakAlert(env, alert, id, detail);
}

export async function routeOwnerApi(request: Request, env: Env, path: string): Promise<Response | null> {
  if (request.method === "GET" && path === "/calls/settings") return json(await publicSettings(env));
  if (request.method === "POST" && path === "/calls/settings") return saveSettings(request, env);
  if (request.method === "GET" && path === "/calls/alerts") return listAlerts(env);
  return null;
}

async function publicSettings(env: Env): Promise<Record<string, unknown>> {
  const settings = await readCallSettings(env);
  return {
    mobile: settings.mobile_number,
    quiet_start: settings.quiet_start,
    quiet_end: settings.quiet_end,
    max_calls_per_day: settings.max_calls_per_day,
    urgent_only: settings.urgent_only === 1,
    question_timeout_seconds: settings.question_timeout_seconds,
  };
}

async function saveSettings(request: Request, env: Env): Promise<Response> {
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return apiError(400, "bad_request", "Request body must be JSON.");
  }
  if (!isRecord(body)) return apiError(400, "bad_request", "JSON body must be an object.");
  const rawMobile = typeof body.mobile === "string" ? body.mobile.trim() : "";
  const mobile = rawMobile ? toE164(rawMobile) : "";
  if (rawMobile && !mobile) return apiError(400, "bad_request", "That mobile number is not valid.");
  const quietStart = clock(body.quiet_start) ?? "22:00";
  const quietEnd = clock(body.quiet_end) ?? "08:00";
  const max = clampDailyCap(typeof body.max_calls_per_day === "number" ? body.max_calls_per_day : 3);
  const urgent = body.urgent_only === true ? 1 : 0;
  const timeout = clampTimeout(typeof body.question_timeout_seconds === "number" ? body.question_timeout_seconds : 40);
  const origin = new URL(request.url).origin;
  try {
    await dbRun(
      env,
      `INSERT INTO call_settings
        (id, mobile_number, quiet_start, quiet_end, max_calls_per_day, urgent_only, question_timeout_seconds, worker_origin, updated_at)
       VALUES ('default', ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET
         mobile_number = excluded.mobile_number,
         quiet_start = excluded.quiet_start,
         quiet_end = excluded.quiet_end,
         max_calls_per_day = excluded.max_calls_per_day,
         urgent_only = excluded.urgent_only,
         question_timeout_seconds = excluded.question_timeout_seconds,
         worker_origin = excluded.worker_origin,
         updated_at = excluded.updated_at`,
      [mobile ?? "", quietStart, quietEnd, max, urgent, timeout, origin, nowIso()],
    );
  } catch {
    return apiError(503, "call_log_unavailable", "The settings table is not ready. Apply schema.sql on D1.");
  }
  return json({ ok: true });
}

async function listAlerts(env: Env): Promise<Response> {
  try {
    const rows = await dbAll(
      env,
      "SELECT id, kind, summary, detail, urgent, channel, created_at FROM owner_alerts ORDER BY created_at DESC LIMIT 10",
    );
    return json({ alerts: rows });
  } catch {
    return json({ alerts: [] });
  }
}

async function placeOwnerCall(env: Env, settings: CallSettings, alertId: string, summary: string): Promise<boolean> {
  const to = (await readOwnerMobile(env)) ?? "";
  const from = toE164(env.TWILIO_FROM_NUMBER ?? "") ?? "";
  const account = (env.TWILIO_ACCOUNT_SID ?? "").trim();
  const token = (env.TWILIO_AUTH_TOKEN ?? "").trim();
  const origin = settings.worker_origin.replace(/\/$/, "");
  if (!to || !from || !account || !token || !origin) return false;
  const callId = newId("call");
  const now = nowIso();
  try {
    await dbRun(
      env,
      `INSERT INTO outbound_calls
        (id, contact_name, to_number, brief, status, twilio_sid, conversation_id, transcript_json, summary, error, created_at, updated_at)
       VALUES (?, 'You', ?, ?, 'placing', NULL, NULL, '[]', NULL, NULL, ?, ?)`,
      [callId, to, summary, now, now],
    );
    await dbRun(env, "UPDATE owner_alerts SET call_id = ? WHERE id = ?", [callId, alertId]);
  } catch {
    return false;
  }
  const form = new URLSearchParams({
    To: to,
    From: from,
    Url: `${origin}/calls/owner/${alertId}`,
    Method: "POST",
  });
  try {
    const response = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(account)}/Calls.json`, {
      method: "POST",
      redirect: "error",
      signal: AbortSignal.timeout(20_000),
      headers: {
        authorization: `Basic ${btoa(`${account}:${token}`)}`,
        "content-type": "application/x-www-form-urlencoded",
      },
      body: form.toString(),
    });
    if (!response.ok) return false;
    const parsed = (await response.json()) as { sid?: string };
    if (parsed.sid) await dbRun(env, "UPDATE outbound_calls SET twilio_sid = ? WHERE id = ?", [parsed.sid, callId]);
    return true;
  } catch {
    return false;
  }
}

async function speakAlert(
  env: Env,
  alert: { summary: string; detail: string; call_id: string | null },
  alertId: string,
  detailFirst: boolean,
): Promise<Response> {
  const from = toE164(env.TWILIO_FROM_NUMBER ?? "") ?? "";
  const first = detailFirst
    ? `Here is the detail. ${clip(alert.detail, 400)} Tell me what you would like me to do.`
    : ownerSummaryLine(clip(alert.summary, 240));
  const prompt = [
    "You are JARVIS calling Master Hadi on his own mobile.",
    `Your first words are exactly: "${first}"`,
    "If he says details, give this once, briefly, then wait:",
    clip(alert.detail, 800),
    "If he tells you what to do, repeat it in one sentence, say you have noted it, and end the call.",
    "Do not talk about anything else. British English.",
  ].join("\n");
  try {
    const response = await fetch("https://api.elevenlabs.io/v1/convai/twilio/register-call", {
      method: "POST",
      redirect: "error",
      signal: AbortSignal.timeout(20_000),
      headers: {
        "xi-api-key": (env.ELEVENLABS_API_KEY ?? "").trim(),
        "content-type": "application/json",
      },
      body: JSON.stringify({
        agent_id: (env.ELEVENLABS_AGENT_ID ?? "").trim(),
        from_number: from,
        to_number: from,
        direction: "outbound",
        conversation_initiation_client_data: {
          user_id: alert.call_id || alertId,
          dynamic_variables: { opening_line: first },
          conversation_config_override: {
            agent: { first_message: first, language: "en", prompt: { prompt } },
          },
        },
      }),
    });
    const text = await response.text();
    if (!response.ok) return xml(say("Hello, this is JARVIS. I could not finish this call. Goodbye."), 502);
    const conversationId = conversationIdFromTwiml(text);
    if (conversationId && alert.call_id) {
      await dbRun(env, "UPDATE outbound_calls SET conversation_id = ?, status = 'in_progress', updated_at = ? WHERE id = ?", [
        conversationId,
        nowIso(),
        alert.call_id,
      ]).catch(() => undefined);
    }
    return new Response(text, { status: 200, headers: { "content-type": "text/xml; charset=utf-8" } });
  } catch {
    return xml(say("Hello, this is JARVIS. I could not finish this call. Goodbye."), 502);
  }
}

async function checkBalance(env: Env): Promise<void> {
  const account = (env.TWILIO_ACCOUNT_SID ?? "").trim();
  const token = (env.TWILIO_AUTH_TOKEN ?? "").trim();
  if (!account || !token) return;
  const checked = await getState(env, "balance_checked_at").catch(() => null);
  if (checked && Date.now() - Date.parse(checked) < 6 * 60 * 60 * 1000) return;
  const day = londonDay(new Date());
  try {
    const seen = await dbFirst<{ id: string }>(env, "SELECT id FROM owner_alerts WHERE source_id = ?", [`balance:${day}`]);
    if (seen) return;
    const response = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(account)}/Balance.json`, {
      headers: { authorization: `Basic ${btoa(`${account}:${token}`)}` },
      signal: AbortSignal.timeout(15_000),
    });
    if (!response.ok) return;
    await setState(env, "balance_checked_at", nowIso()).catch(() => undefined);
    const payload = (await response.json()) as { balance?: string; currency?: string };
    const amount = Number(payload.balance ?? "");
    if (!Number.isFinite(amount) || amount >= 2) return;
    await reportProblem(env, {
      sourceId: `balance:${day}`,
      kind: "low_balance",
      urgent: true,
      summary: `The Twilio balance is low, about ${amount} ${payload.currency ?? ""}.`.trim(),
      detail: "Top up the Twilio balance before more calls are placed. The daily call cap is there to protect the budget.",
    });
  } catch {
    // A missed balance check waits for the next cron tick.
  }
}

function clock(value: unknown): string | null {
  if (typeof value !== "string" || !/^([01]\d|2[0-3]):[0-5]\d$/.test(value)) return null;
  return value;
}

function clockMinutes(value: string): number | null {
  const match = /^([01]\d|2[0-3]):([0-5]\d)$/.exec(value);
  if (!match) return null;
  return Number(match[1]) * 60 + Number(match[2]);
}

async function formParams(request: Request): Promise<Record<string, string>> {
  const params = new URLSearchParams(await request.text());
  const fields: Record<string, string> = {};
  for (const [key, value] of params.entries()) fields[key] = value;
  return fields;
}

function say(line: string): string {
  return `<?xml version="1.0" encoding="UTF-8"?><Response><Say language="en-GB">${escapeXml(line)}</Say><Hangup/></Response>`;
}

function xml(body: string, status: number): Response {
  return new Response(body, { status, headers: { "content-type": "text/xml; charset=utf-8" } });
}

function escapeXml(value: string): string {
  return value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;");
}

function clip(value: string, max: number): string {
  const trimmed = value.trim();
  if (trimmed.length <= max) return trimmed;
  return `${trimmed.slice(0, max)}…`;
}
