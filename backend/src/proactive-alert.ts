/**
 * JARVIS proactive alert calls. POST /alert (Bearer ALERT_KEY) places ONE outbound call
 * from the Twilio number to the owner's own mobile (OWNER_PHONE / saved call settings).
 * Voice: Twilio <Say> Polly.Brian-Neural (British male), no ElevenLabs credits used.
 * Guards: ALERT_LINE=off kill switch, ALERT_MAX_PER_DAY (default 3), quiet 22:00-07:30
 * Europe/London unless type=money, dedupe per event (dedupe_key or type+summary).
 * Keys on the call: 1 = text the meeting link, 2 = "tell them I'm on my way", 3 = repeat.
 * After the call (or on key 1) the owner gets an SMS with the link and details.
 */
import { safeError, toE164, twilioRequestSigned } from "./calls";
import { dbFirst, dbRun } from "./db";
import { apiError, isRecord, json, newId, nowIso } from "./http";
import { londonDay, londonMinutes, readOwnerMobile } from "./owner-alert";
import type { Env } from "./types";

export const ALERT_VOICE = "Polly.Brian-Neural";
export const ALERT_TYPES = ["booking", "hot_lead", "money", "test", "other"] as const;
export type AlertType = (typeof ALERT_TYPES)[number];

export interface AlertInput {
  type: AlertType;
  summary: string;
  who: string;
  value: string;
  when: string;
  meet_link: string;
  details: string;
  dedupe_key: string;
}

export function quietNow(minutes: number): boolean {
  return minutes >= 22 * 60 || minutes < 7 * 60 + 30;
}

export function alertDecision(i: { type: AlertType; minutes: number; countToday: number; max: number; off: boolean }):
  | "call"
  | "off"
  | "quiet"
  | "cap" {
  if (i.off) return "off";
  if (i.type !== "money" && quietNow(i.minutes)) return "quiet";
  if (i.countToday >= i.max) return "cap";
  return "call";
}

export function parseAlert(body: unknown): AlertInput | string {
  if (!isRecord(body)) return "JSON body must be an object.";
  const s = (k: string, max: number) => (typeof body[k] === "string" || typeof body[k] === "number" ? String(body[k]).trim().slice(0, max) : "");
  const type = (s("type", 20).toLowerCase() || "other") as AlertType;
  if (!ALERT_TYPES.includes(type)) return `type must be one of ${ALERT_TYPES.join(", ")}.`;
  const summary = s("summary", 300);
  if (!summary) return "summary is required.";
  const link = s("meet_link", 300);
  if (link && !/^https:\/\//.test(link)) return "meet_link must be an https URL.";
  return {
    type,
    summary,
    who: s("who", 80),
    value: s("value", 40),
    when: s("when", 80),
    meet_link: link,
    details: s("details", 600),
    dedupe_key: s("dedupe_key", 160) || `${type}:${summary.toLowerCase().replace(/\s+/g, " ").slice(0, 140)}`,
  };
}

export function spokenAlert(a: Pick<AlertInput, "type" | "summary" | "who" | "value" | "when" | "meet_link">): string {
  if (a.type === "test") return "Good day, Sir. This is a test of your alert line, Sir. Everything is working.";
  const lead = a.type === "money" ? "Payment received." : a.type === "booking" ? "New discovery call booked." : "Urgent business alert.";
  const parts = [`Sir, JARVIS here. ${lead}`, a.summary.replace(/[.!?]?$/, ".")];
  if (a.who) parts.push(`Who: ${a.who}.`);
  if (a.value) parts.push(`Value: ${a.value}.`);
  if (a.when) parts.push(`When: ${a.when}.`);
  return parts.join(" ");
}

export function menuLine(a: Pick<AlertInput, "type" | "meet_link">): string {
  if (a.type === "test") return "Press 1 and I will text you to confirm.";
  const link = a.meet_link ? "Press 1 to text you the meeting link." : "Press 1 to text you the details.";
  return `${link} Press 2 and I will tell them you are on your way. Press 3 to hear it again.`;
}

export function smsBody(a: AlertInput, choice: string): string {
  const lines = [`JARVIS alert${a.type === "test" ? " (TEST)" : ""}: ${a.summary}`];
  if (a.who) lines.push(`Who: ${a.who}`);
  if (a.value) lines.push(`Value: ${a.value}`);
  if (a.when) lines.push(`When: ${a.when}`);
  if (a.meet_link) lines.push(`Meet: ${a.meet_link}`);
  if (a.details) lines.push(a.details);
  if (choice === "2") lines.push("You chose: tell them you're on your way (queued for approval in JARVIS).");
  return lines.join("\n").slice(0, 640);
}

export function readChoice(params: Record<string, string>): string {
  const d = (params.Digits ?? "").trim();
  if (["1", "2", "3"].includes(d)) return d;
  const sp = (params.SpeechResult ?? "").toLowerCase();
  if (/on my way|tell them|yes/.test(sp)) return "2";
  if (/text|link|send|details/.test(sp)) return "1";
  if (/repeat|again/.test(sp)) return "3";
  return "";
}

export function isAlertWebhook(method: string, path: string): boolean {
  return method === "POST" && /^\/alert\/call\/alrt_[A-Za-z0-9]+\/(?:key|status)$/.test(path);
}

async function ensureTable(env: Env): Promise<void> {
  await dbRun(
    env,
    `CREATE TABLE IF NOT EXISTS jarvis_alerts (id TEXT PRIMARY KEY, dedupe_key TEXT UNIQUE NOT NULL, type TEXT NOT NULL,
      payload TEXT NOT NULL, status TEXT NOT NULL, day TEXT NOT NULL, call_sid TEXT, choice TEXT, sms_sent INTEGER DEFAULT 0,
      created_at TEXT NOT NULL)`,
  );
}

function bearer(request: Request): string {
  return (request.headers.get("authorization") ?? "").replace(/^bearer\s+/i, "").trim();
}

function safeEqual(a: string, b: string): boolean {
  if (!a || !b || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/** POST /alert */
export async function alertRoute(request: Request, env: Env): Promise<Response> {
  const key = (env.ALERT_KEY ?? "").trim();
  if (!key) return apiError(503, "alert_not_configured", "ALERT_KEY secret is not set.");
  if (!safeEqual(bearer(request), key)) return apiError(401, "unauthorized", "Bad alert key.");
  const body = await request.json().catch(() => null);
  const input = parseAlert(body);
  if (typeof input === "string") return apiError(400, "bad_request", input);
  const result = await fireAlert(env, input, new URL(request.url).origin);
  return json(result, result.ok ? 200 : 202);
}

export async function fireAlert(env: Env, a: AlertInput, origin: string): Promise<{ ok: boolean; status: string; id?: string }> {
  await ensureTable(env);
  const now = new Date();
  const day = londonDay(now);
  const counted = await dbFirst<{ n: number }>(env, "SELECT COUNT(*) AS n FROM jarvis_alerts WHERE day = ? AND status = 'called'", [day]);
  const max = Number.parseInt(env.ALERT_MAX_PER_DAY ?? "3", 10);
  const decision = alertDecision({
    type: a.type,
    minutes: londonMinutes(now),
    countToday: Number(counted?.n ?? 0),
    max: Number.isFinite(max) ? max : 3,
    off: (env.ALERT_LINE ?? "").trim().toLowerCase() === "off",
  });
  const id = newId("alrt");
  const inserted = await dbRun(
    env,
    `INSERT OR IGNORE INTO jarvis_alerts (id, dedupe_key, type, payload, status, day, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)`,
    [id, a.dedupe_key, a.type, JSON.stringify(a), decision === "call" ? "placing" : `skipped_${decision}`, day, nowIso()],
  );
  if (inserted === 0) return { ok: false, status: "duplicate" };
  if (decision !== "call") {
    // Not calling: still text the owner so nothing is lost (quiet hours / cap). Kill switch sends nothing.
    if (decision !== "off") await sendSms(env, smsBody(a, ""));
    return { ok: false, status: decision, id };
  }
  const sid = await placeCall(env, id, a, origin);
  await dbRun(env, "UPDATE jarvis_alerts SET status = ?, call_sid = ? WHERE id = ?", [sid ? "called" : "call_failed", sid, id]);
  if (!sid) {
    await sendSms(env, smsBody(a, ""));
    return { ok: false, status: "call_failed_sms_sent", id };
  }
  return { ok: true, status: "calling", id };
}

function twiml(id: string, a: AlertInput, origin: string, intro = true): string {
  const action = escapeXml(`${origin}/alert/call/${id}/key`);
  const sayIt = (t: string) => `<Say language="en-GB" voice="${ALERT_VOICE}">${escapeXml(t)}</Say>`;
  return `<Response>${intro ? `<Pause length="1"/>${sayIt(spokenAlert(a))}` : ""}<Gather input="dtmf speech" numDigits="1" timeout="6" speechTimeout="auto" language="en-GB" action="${action}" method="POST">${sayIt(menuLine(a))}</Gather>${sayIt("Very good, Sir. I will text you the details.")}<Hangup/></Response>`;
}

async function placeCall(env: Env, id: string, a: AlertInput, origin: string): Promise<string | null> {
  const to = (await readOwnerMobile(env)) ?? "";
  const from = toE164(env.TWILIO_FROM_NUMBER ?? "") ?? "";
  const account = (env.TWILIO_ACCOUNT_SID ?? "").trim();
  const token = (env.TWILIO_AUTH_TOKEN ?? "").trim();
  if (!to || !from || !account || !token) return null;
  const form = new URLSearchParams({
    To: to,
    From: from,
    Twiml: twiml(id, a, origin),
    TimeLimit: "120",
    Timeout: "25",
    StatusCallback: `${origin}/alert/call/${id}/status`,
    StatusCallbackMethod: "POST",
  });
  try {
    const r = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(account)}/Calls.json`, {
      method: "POST",
      signal: AbortSignal.timeout(20_000),
      headers: { authorization: `Basic ${btoa(`${account}:${token}`)}`, "content-type": "application/x-www-form-urlencoded" },
      body: form.toString(),
    });
    if (!r.ok) {
      console.error("alert call failed", r.status, safeError((await r.text()).slice(0, 200)));
      return null;
    }
    return ((await r.json()) as { sid?: string }).sid ?? null;
  } catch (err) {
    console.error("alert call error", safeError(err instanceof Error ? err.message : "call"));
    return null;
  }
}

/** Twilio webhooks: /alert/call/<id>/key (Gather result) and /alert/call/<id>/status (call ended). */
export async function alertWebhook(request: Request, env: Env, path: string): Promise<Response> {
  const raw = new URLSearchParams(await request.text());
  const params: Record<string, string> = {};
  for (const [k, v] of raw.entries()) params[k] = v;
  if (!(await twilioRequestSigned(request, params, (env.TWILIO_AUTH_TOKEN ?? "").trim()))) return xml("<Response><Hangup/></Response>", 403);
  const [, , , id, leaf] = path.split("/");
  const row = await dbFirst<{ payload: string; choice: string | null; sms_sent: number }>(
    env,
    "SELECT payload, choice, sms_sent FROM jarvis_alerts WHERE id = ?",
    [id],
  );
  if (!row) return xml("<Response><Hangup/></Response>", 404);
  const a = JSON.parse(row.payload) as AlertInput;
  const origin = new URL(request.url).origin;
  if (leaf === "status") {
    if (!row.sms_sent) await smsOnce(env, id, a, row.choice ?? "");
    return xml("<Response/>", 200);
  }
  const choice = readChoice(params);
  if (choice === "3") return xml(twiml(id, a, origin, true), 200);
  if (choice) await dbRun(env, "UPDATE jarvis_alerts SET choice = ? WHERE id = ?", [choice, id]);
  if (choice === "2") {
    await dbRun(
      env,
      `INSERT OR IGNORE INTO approvals (id, task_id, subtask_id, action, level, summary, payload_json, status, reason, created_at)
       VALUES (?, NULL, NULL, 'send_message', 'approval_required', ?, ?, 'pending', NULL, ?)`,
      [newId("appr"), `Tell them Sohail is on his way: ${a.summary}`.slice(0, 300), JSON.stringify({ alert_id: id, who: a.who }), nowIso()],
    ).catch(() => undefined);
  }
  await smsOnce(env, id, a, choice);
  const reply =
    choice === "2"
      ? "Understood, Sir. I have queued the message saying you are on your way, and texted you the link. Goodbye."
      : "Very good, Sir. The details are on their way to your phone. Goodbye.";
  return xml(`<Response><Say language="en-GB" voice="${ALERT_VOICE}">${escapeXml(reply)}</Say><Hangup/></Response>`, 200);
}

async function smsOnce(env: Env, id: string, a: AlertInput, choice: string): Promise<void> {
  const claimed = await dbRun(env, "UPDATE jarvis_alerts SET sms_sent = 1 WHERE id = ? AND sms_sent = 0", [id]);
  if (claimed === 0) return;
  await sendSms(env, smsBody(a, choice));
}

async function sendSms(env: Env, body: string): Promise<boolean> {
  const account = (env.TWILIO_ACCOUNT_SID ?? "").trim();
  const token = (env.TWILIO_AUTH_TOKEN ?? "").trim();
  const from = toE164(env.TWILIO_FROM_NUMBER ?? "");
  const to = await readOwnerMobile(env);
  if (!account || !token || !from || !to) return false;
  try {
    const r = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(account)}/Messages.json`, {
      method: "POST",
      signal: AbortSignal.timeout(15_000),
      headers: { authorization: `Basic ${btoa(`${account}:${token}`)}`, "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ From: from, To: to, Body: body }).toString(),
    });
    return r.ok;
  } catch {
    return false;
  }
}

/** Hot receptionist lead -> alert. Called after an asg_leads row is written. */
export function isHotLead(text: string): boolean {
  return /\b(hot|ready to (buy|sign|start)|wants? to (buy|sign|start)|sign (today|tonight)|asap|urgent|purchase|budget approved)\b/i.test(text);
}

function xml(body: string, status: number): Response {
  return new Response(body, { status, headers: { "content-type": "text/xml; charset=utf-8" } });
}

function escapeXml(v: string): string {
  return v.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;").replaceAll("'", "&apos;");
}
