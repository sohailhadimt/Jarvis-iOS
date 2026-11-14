/**
 * Morning briefing phone call. Opt-in: the owner sets "Call me at" in the app (days + time, Europe/London).
 * The cron sweep (every 5 minutes) rings OWNER_PHONE once per chosen morning from the JARVIS Twilio number,
 * reads the briefing in Polly Brian (no ElevenLabs minutes), then lets him ask follow-ups by voice.
 * The briefing and the follow-ups are saved to brain history, so they show in the app. ALERT_LINE=off stops it.
 */
import { buildBriefing } from "./briefing";
import { brainReply, rememberLine } from "./brain";
import { safeError, toE164, twilioRequestSigned } from "./calls";
import { getState, setState } from "./db";
import { apiError, isRecord, json } from "./http";
import { londonDay, londonMinutes, readCallSettings, readOwnerMobile } from "./owner-alert";
import type { Env } from "./types";

export const BRIEFING_VOICE = "Polly.Brian-Neural";
const SETTINGS_KEY = "briefing_call";
/** The cron runs every five minutes; a call may start up to this long after the chosen time. */
const WINDOW_MINUTES = 9;
const MAX_FOLLOWUPS = 5;

export interface BriefingCallSettings {
  enabled: boolean;
  /** "HH:MM", 24 hour, Europe/London. */
  time: string;
  /** 0 = Sunday ... 6 = Saturday. */
  days: number[];
}

export const DEFAULT_SETTINGS: BriefingCallSettings = { enabled: false, time: "07:30", days: [1, 2, 3, 4, 5] };

export function parseSettings(raw: unknown): BriefingCallSettings | string {
  if (!isRecord(raw)) return "Body must be an object.";
  const time = typeof raw.time === "string" ? raw.time.trim() : "";
  const match = /^([01]\d|2[0-3]):([0-5]\d)$/.exec(time);
  if (!match) return "time must be HH:MM (24 hour).";
  const days = Array.isArray(raw.days)
    ? [...new Set(raw.days.filter((d): d is number => Number.isInteger(d) && d >= 0 && d <= 6))].sort()
    : [];
  return { enabled: raw.enabled === true, time, days };
}

export async function readSettings(env: Env): Promise<BriefingCallSettings> {
  try {
    const stored = JSON.parse((await getState(env, SETTINGS_KEY)) ?? "null") as unknown;
    const parsed = parseSettings(stored);
    return typeof parsed === "string" ? DEFAULT_SETTINGS : parsed;
  } catch {
    return DEFAULT_SETTINGS;
  }
}

export function londonWeekday(date: Date): number {
  const name = new Intl.DateTimeFormat("en-GB", { timeZone: "Europe/London", weekday: "short" }).format(date);
  return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].indexOf(name);
}

/** True when this cron tick is the one that should place today's call. */
export function callDue(s: BriefingCallSettings, now: Date, alreadyCalledToday: boolean): boolean {
  if (!s.enabled || alreadyCalledToday || s.days.length === 0) return false;
  if (!s.days.includes(londonWeekday(now))) return false;
  const [h, m] = s.time.split(":").map(Number);
  const target = h * 60 + m;
  const minutes = londonMinutes(now);
  return minutes >= target && minutes < target + WINDOW_MINUTES;
}

interface SpokenFacts {
  completed: number;
  failed: number;
  approvals: number;
  drafts: number;
  reminders: string[];
}

/** Only stored facts, spoken plainly. Nothing is added that the rows do not say. */
export function spokenBriefing(f: SpokenFacts, now: Date): string {
  const hour = Math.floor(londonMinutes(now) / 60);
  const greeting = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening";
  const parts: string[] = [];
  if (f.completed) parts.push(`${f.completed} task${f.completed === 1 ? "" : "s"} finished in the last day`);
  if (f.failed) parts.push(`${f.failed} failed and need${f.failed === 1 ? "s" : ""} a look`);
  if (f.approvals) parts.push(`${f.approvals} approval${f.approvals === 1 ? " is" : "s are"} waiting for you; nothing has gone out`);
  if (f.drafts) parts.push(`${f.drafts} draft${f.drafts === 1 ? "" : "s"} ready to review`);
  const lines = [`${greeting}, Sir. This is your briefing.`];
  lines.push(parts.length ? `${parts.join(". ")}.` : "Nothing needs your attention.");
  if (f.reminders.length) {
    lines.push(`Open reminders: ${f.reminders.slice(0, 5).join("; ")}.`);
  }
  lines.push("Ask me anything, or say that is all.");
  return lines.join(" ");
}

export async function briefingText(env: Env, now: Date): Promise<string> {
  const b = await buildBriefing(env);
  return spokenBriefing(
    {
      completed: b.facts.completed_tasks.length,
      failed: b.facts.failed_tasks.length,
      approvals: b.facts.pending_approvals.length,
      drafts: b.recommendations.some((r) => r.id === "review-drafts") ? 1 : 0,
      reminders: b.reminders,
    },
    now,
  );
}

export function isDone(speech: string): boolean {
  return /^\s*(no|nope|nothing|that'?s (all|it)|thanks?|thank you|goodbye|bye|all good|i'?m good)\b/i.test(speech);
}

function escapeXml(v: string): string {
  return v.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;").replaceAll("'", "&apos;");
}

function say(text: string): string {
  return `<Say language="en-GB" voice="${BRIEFING_VOICE}">${escapeXml(text)}</Say>`;
}

export function askTwiml(origin: string, turn: number, intro: string | null): string {
  const action = escapeXml(`${origin}/briefing/call/ask?n=${turn}`);
  return `<Response>${intro ? `<Pause length="1"/>${say(intro)}` : ""}<Gather input="speech" timeout="6" speechTimeout="auto" language="en-GB" action="${action}" method="POST"/>${say("Very good, Sir. Goodbye.")}<Hangup/></Response>`;
}

function xml(body: string, status = 200): Response {
  return new Response(body, { status, headers: { "content-type": "text/xml; charset=utf-8" } });
}

/** Cron: rings once per chosen morning. Marks the day first so a slow tick never double-calls. */
export async function sweepBriefingCall(env: Env, origin = "", now = new Date()): Promise<string> {
  if ((env.ALERT_LINE ?? "").trim().toLowerCase() === "off") return "off";
  const day = londonDay(now);
  const done = (await getState(env, `briefing_call_done:${day}`)) !== null;
  const settings = await readSettings(env);
  if (!callDue(settings, now, done)) return "idle";
  const base = origin || ((await readCallSettings(env)).worker_origin ?? "");
  if (!base) return "no_origin";
  await setState(env, `briefing_call_done:${day}`, "placing");
  const text = await briefingText(env, now);
  await rememberLine(env, { source: "call", role: "assistant", body: `Morning briefing call: ${text}` });
  const sid = await placeCall(env, askTwiml(base, 1, text));
  await setState(env, `briefing_call_done:${day}`, sid ? "called" : "failed");
  return sid ? "called" : "failed";
}

async function placeCall(env: Env, twiml: string): Promise<string | null> {
  const to = (await readOwnerMobile(env)) ?? "";
  const from = toE164(env.TWILIO_FROM_NUMBER ?? "") ?? "";
  const account = (env.TWILIO_ACCOUNT_SID ?? "").trim();
  const token = (env.TWILIO_AUTH_TOKEN ?? "").trim();
  if (!to || !from || !account || !token) return null;
  try {
    const r = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(account)}/Calls.json`, {
      method: "POST",
      signal: AbortSignal.timeout(20_000),
      headers: { authorization: `Basic ${btoa(`${account}:${token}`)}`, "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ To: to, From: from, Twiml: twiml, TimeLimit: "300", Timeout: "30" }).toString(),
    });
    if (!r.ok) {
      console.error("briefing call failed", r.status, safeError((await r.text()).slice(0, 200)));
      return null;
    }
    return ((await r.json()) as { sid?: string }).sid ?? null;
  } catch (err) {
    console.error("briefing call error", safeError(err instanceof Error ? err.message : "call"));
    return null;
  }
}

export function isBriefingWebhook(method: string, path: string): boolean {
  return method === "POST" && path === "/briefing/call/ask";
}

/** Twilio webhook: the owner spoke a follow-up. Answer from the one brain, then listen again. */
export async function briefingAsk(request: Request, env: Env): Promise<Response> {
  const raw = new URLSearchParams(await request.text());
  const params: Record<string, string> = {};
  for (const [k, v] of raw.entries()) params[k] = v;
  if (!(await twilioRequestSigned(request, params, (env.TWILIO_AUTH_TOKEN ?? "").trim()))) return xml("<Response><Hangup/></Response>", 403);
  const url = new URL(request.url);
  const turn = Math.max(1, Number.parseInt(url.searchParams.get("n") ?? "1", 10) || 1);
  const speech = (params.SpeechResult ?? "").trim();
  if (!speech || isDone(speech) || turn > MAX_FOLLOWUPS) {
    return xml(`<Response>${say("Very good, Sir. Goodbye.")}<Hangup/></Response>`);
  }
  await rememberLine(env, { source: "call", role: "user", body: speech });
  const answer = await brainReply(env, "app");
  await rememberLine(env, { source: "call", role: "assistant", body: answer.text });
  return xml(askTwiml(url.origin, turn + 1, answer.text));
}

/** GET/POST /briefing/call-settings (app token). */
export async function settingsRoute(request: Request, env: Env): Promise<Response> {
  if (request.method === "GET") return json(await readSettings(env));
  const parsed = parseSettings(await request.json().catch(() => null));
  if (typeof parsed === "string") return apiError(400, "bad_request", parsed);
  await setState(env, SETTINGS_KEY, JSON.stringify(parsed));
  return json(parsed);
}
