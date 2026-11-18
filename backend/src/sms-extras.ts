import { dbAll, dbFirst, dbRun, getState, setState } from "./db";
import { GEMINI_MODEL, GEMINI_URL, GROQ_URL } from "./types";
import type { Env } from "./types";

/**
 * Extra text-line powers for Sir's own number: photos, reminders, ring-and-ask by name,
 * the 08:00 text, nearby places, price watches, harmless prank calls, and passing work to his agents.
 * Strangers never reach this file; sms-desk only calls it for the owner.
 */

export interface ExtrasCtx {
  /** Simulation: nothing is sent, dialled or posted. */
  sim: boolean;
  send: (line: string) => Promise<void>;
}

const ASHFORD = { lat: 51.1465, lon: 0.875, label: "Ashford, Kent" };
const UA = "JARVIS-backend/1.0 (personal assistant; jarvis-hadi.workers.dev)";

// ---------------------------------------------------------------- London time

export function londonParts(at: Date): { ymd: string; hour: number; minute: number; weekday: number } {
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Europe/London",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    weekday: "short",
    hourCycle: "h23",
  }).formatToParts(at);
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? "";
  const days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  return {
    ymd: `${get("year")}-${get("month")}-${get("day")}`,
    hour: Number(get("hour")) % 24,
    minute: Number(get("minute")),
    weekday: days.indexOf(get("weekday")),
  };
}

function offsetMinutes(at: Date): number {
  const name =
    new Intl.DateTimeFormat("en-GB", { timeZone: "Europe/London", timeZoneName: "shortOffset" })
      .formatToParts(at)
      .find((p) => p.type === "timeZoneName")?.value ?? "GMT";
  const m = /GMT([+-]\d{1,2})(?::(\d{2}))?/.exec(name);
  if (!m) return 0;
  const sign = m[1]!.startsWith("-") ? -1 : 1;
  return Number(m[1]) * 60 + sign * Number(m[2] ?? 0);
}

/** A London wall-clock time as a real instant. */
export function atLondon(ymd: string, hour: number, minute: number): Date {
  const [y, mo, d] = ymd.split("-").map(Number) as [number, number, number];
  const guess = Date.UTC(y, mo - 1, d, hour, minute);
  const first = guess - offsetMinutes(new Date(guess)) * 60_000;
  return new Date(guess - offsetMinutes(new Date(first)) * 60_000);
}

function addDays(ymd: string, days: number): string {
  const [y, mo, d] = ymd.split("-").map(Number) as [number, number, number];
  return new Date(Date.UTC(y, mo - 1, d + days)).toISOString().slice(0, 10);
}

export function clockLabel(at: Date, now = new Date()): string {
  const p = londonParts(at);
  const today = londonParts(now).ymd;
  const h12 = p.hour % 12 || 12;
  const time = `${h12}${p.minute ? `:${String(p.minute).padStart(2, "0")}` : ""}${p.hour < 12 ? "am" : "pm"}`;
  if (p.ymd === today) return time;
  if (p.ymd === addDays(today, 1)) return `${time} tomorrow`;
  return `${time} on ${new Intl.DateTimeFormat("en-GB", { timeZone: "Europe/London", weekday: "short", day: "numeric", month: "short" }).format(at)}`;
}

// ---------------------------------------------------------------- reminders

export interface ParsedReminder {
  task: string;
  dueAt: Date;
  byCall: boolean;
}

const NUMBER_WORDS: Record<string, number> = {
  a: 1, an: 1, one: 1, two: 2, three: 3, four: 4, five: 5, six: 6, seven: 7, eight: 8, nine: 9, ten: 10,
  fifteen: 15, twenty: 20, thirty: 30, forty: 40, "forty five": 45, half: 30,
};

const AT_TIME = /\b(?:at|for|by)\s+(\d{1,2})(?:[:.](\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?(?=\W|$)|\b(\d{1,2})(?:[:.](\d{2}))?\s*(am|pm)\b|\b(noon|midday|midnight)\b/i;

const HOUR_WORDS: Record<string, number> = {
  one: 1, two: 2, three: 3, four: 4, five: 5, six: 6, seven: 7, eight: 8, nine: 9, ten: 10, eleven: 11, twelve: 12,
};
const H = "(\\d{1,2}|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)";

/** British clock talk to digits: "half 12" and "half past 12" are 12:30, "quarter to 8" is 7:45, "2 and a half hours" is 150 mins. */
export function normaliseClockWords(text: string): string {
  const hourOf = (raw: string) => (/^\d+$/.test(raw) ? Number(raw) : HOUR_WORDS[raw.toLowerCase()] ?? NaN);
  const qty = (raw: string) => (/^\d+$/.test(raw) ? Number(raw) : NUMBER_WORDS[raw.toLowerCase()] ?? NaN);
  const clock = (suffix: string, shift = 0) => (m: string, h: string, mer?: string) => {
    let v = hourOf(h);
    if (!(v >= 1 && v <= 12)) return m;
    v = v + shift;
    if (v < 1) v = 12;
    return `${v}:${suffix}${mer ?? ""}`;
  };
  return text
    .replace(/\bin (?:about|around|roughly|like|approx(?:imately)?)\s+/gi, "in ")
    .replace(/\b(?:in\s+)?an hour and a half\b/gi, "in 90 mins")
    .replace(/\b(?:in\s+)?(\d{1,2}|a|an|one|two|three|four|five|six|seven|eight|nine|ten)\s+and a half\s+(?:hours?|hrs?)\b/gi, (m: string, n: string) => {
      const v = qty(n);
      return Number.isFinite(v) ? `in ${v * 60 + 30} mins` : m;
    })
    .replace(/\bin half an hour\b/gi, "in 30 mins")
    .replace(new RegExp(`\\bhalf(?:\\s+past)?\\s+${H}(?:\\s*o'?clock)?(?:\\s*(am|pm)\\b)?`, "gi"), clock("30"))
    .replace(new RegExp(`\\bquarter\\s+past\\s+${H}(?:\\s*(am|pm)\\b)?`, "gi"), clock("15"))
    .replace(new RegExp(`\\bquarter\\s+to\\s+${H}(?:\\s*(am|pm)\\b)?`, "gi"), clock("45", -1))
    .replace(new RegExp(`\\b${H}\\s*o'?clock\\b`, "gi"), (m: string, h: string) => {
      const v = hourOf(h);
      return v >= 1 && v <= 12 ? `${v}` : m;
    });
}

export function parseReminder(text: string, now = new Date()): ParsedReminder | "unclear" | null {
  const clean = normaliseClockWords(text.replace(/\s+/g, " ").trim().replace(/[.!]+$/, ""));
  const m = /^(?:jarvis,?\s+)?(?:please\s+|can you\s+|could you\s+)?(?:remind me|set (?:a|me a) reminder|reminder)\b\s*(.*)$/i.exec(clean);
  if (!m) return null;
  let rest = ` ${m[1] ?? ""} `;
  const byCall = /\b(?:call|ring|phone) me\b/i.test(rest);
  rest = rest.replace(/\s*(?:,|\band\b|\bby\b|\bwith a\b)?\s*(?:call|ring|phone) me(?: about it| with it)?\b/gi, " ").replace(/\bby (?:text|sms)\b/gi, " ");
  let due: Date | null = null;
  const today = londonParts(now).ymd;

  const rel = /\bin\s+(an?|one|two|three|four|five|six|seven|eight|nine|ten|fifteen|twenty|thirty|forty five|forty|half an?|\d{1,4})\s*(hours?|hrs?|h|minutes?|mins?|m)\b/i.exec(rest);
  // When he gives both ("at half 12, so in about 2 and a half hours"), the first one he said wins.
  const clockFirst = AT_TIME.exec(rest);
  if (rel && !(clockFirst && clockFirst.index < rel.index)) {
    const raw = rel[1]!.toLowerCase();
    let qty = /^\d+$/.test(raw) ? Number(raw) : NUMBER_WORDS[raw.replace(/ an?$/, "")] ?? 1;
    let unit = rel[2]!.toLowerCase().startsWith("h") ? 60 : 1;
    if (raw.startsWith("half")) {
      qty = 30;
      unit = rel[2]!.toLowerCase().startsWith("h") ? 1 : 1;
    }
    due = new Date(now.getTime() + qty * unit * 60_000);
    rest = rest.replace(rel[0], " ");
  } else {
    const tomorrow = /\btomorrow\b/i.test(rest);
    const tonight = /\b(?:tonight|this evening)\b/i.test(rest);
    const morning = /\b(?:in the morning|this morning)\b/i.test(rest);
    const at = AT_TIME.exec(rest);
    if (at || tomorrow) {
      let hour = 9;
      let minute = 0;
      let meridiem = "";
      if (at?.[7]) {
        hour = at[7].toLowerCase() === "midnight" ? 0 : 12;
        meridiem = "fixed";
      } else if (at) {
        hour = Number(at[1] ?? at[4]);
        minute = Number(at[2] ?? at[5] ?? 0);
        meridiem = (at[3] ?? at[6] ?? "").replace(/\./g, "").toLowerCase();
      }
      if (hour > 23 || minute > 59) return "unclear";
      if (meridiem === "pm" && hour < 12) hour += 12;
      if (meridiem === "am" && hour === 12) hour = 0;
      if (!meridiem && tonight && hour < 12) hour += 12;
      const day = tomorrow ? addDays(today, 1) : today;
      let candidate = atLondon(day, hour, minute);
      if (!meridiem && !morning && hour >= 1 && hour < 12 && !tonight) {
        // "at 6" means the next 6 o'clock; tomorrow, small hours mean the evening.
        const pm = atLondon(day, hour + 12, minute);
        if (tomorrow) candidate = hour <= 6 ? pm : candidate;
        else if (candidate.getTime() <= now.getTime()) candidate = pm;
      }
      if (candidate.getTime() <= now.getTime()) candidate = new Date(candidate.getTime() + 86_400_000);
      due = candidate;
      if (at) rest = rest.replace(at[0], " ");
      rest = rest.replace(/\b(?:tomorrow|tonight|this evening|in the morning|this morning|today)\b/gi, " ");
    }
  }
  if (!due) return /^\s*(?:to|that|about|at|in|on|tomorrow)\b/i.test(rest) ? "unclear" : null;
  const task = rest
    .replace(/\s+/g, " ")
    .trim()
    .replace(/^(?:to|that|about|i need to|i have to|i've got to)\s+/i, "")
    .replace(/\s+(?:to|and|please)$/i, "")
    .replace(/[,.\s]+$/, "")
    .trim();
  if (due.getTime() - now.getTime() > 366 * 86_400_000) return "unclear";
  return { task: task || "your reminder", dueAt: due, byCall };
}

export const WAKE_TASK = "time to wake up";
/** A reminder task starting with this is spoken word for word on the call. */
export const SAY_PREFIX = "say:";

/**
 * "Call me at half 12 to wake me up", "ring me in 2 hours", "wake me up at 7". A timed call to Sir himself.
 * Only his own number is ever rung, so this books straight away, like a reminder by call.
 */
export function parseTimedCall(text: string, now = new Date()): ParsedReminder | null {
  const clean = text.replace(/\s+/g, " ").trim().replace(/^(?:hey\s+|ok(?:ay)?\s+)?jarvis[,!.]?\s*/i, "");
  if (/^(?:please\s+|can you\s+|could you\s+)?(?:remind me|set (?:a|me a) reminder|reminder)\b/i.test(clean)) return null;
  const wake = /\bwake\s*(?:me\s*)?up\b|\bwake me\b|\bwake[- ]?up call\b|\balarm call\b/i.test(clean);
  const callMe = wake || /\b(?:call|ring|phone|bell) me\b|\bgive me a (?:call|ring|bell)\b/i.test(clean);
  if (!callMe) return null;
  const parsed = parseReminder(`remind me ${clean} call me`, now);
  if (!parsed || parsed === "unclear") return null;
  let task = parsed.task
    .split(/[,.;!?]|\b(?:so|okay|ok|make sure|because|cos|cuz|i've got|ive got|i have)\b/i)[0]!
    .replace(/\b(?:give me a (?:call|ring|bell)|wake\s*(?:me\s*)?up(?: call)?|wake me|alarm call)\b/gi, " ")
    .replace(/\s+/g, " ")
    .trim()
    .replace(/^(?:to|and|for|please)\s+/i, "")
    .replace(/\s+(?:to|and|please)$/i, "")
    .trim();
  if (wake) task = WAKE_TASK;
  else if (!task || task.length < 3 || /^(?:me|it|up|to)$/i.test(task)) task = "you asked me to ring";
  return { task: task.slice(0, 120), dueAt: parsed.dueAt, byCall: true };
}

export function bookedCallLine(dueAt: Date, now = new Date()): string {
  const p = londonParts(dueAt);
  const time = `${p.hour % 12 || 12}:${String(p.minute).padStart(2, "0")}`;
  const label = clockLabel(dueAt, now);
  const day = /tomorrow|\bon\b/.test(label) ? label.replace(/^\S+/, "").trim() : "";
  return `Booked, Sir, I'll ring you at ${time}${day ? ` ${day}` : ""}.`;
}

/** Books a timed call to Sir. One pending call in the same minute is enough, so a repeat or a YES does not double it. */
export async function bookTimedCall(env: Env, phone: string, call: ParsedReminder, now = new Date()): Promise<string> {
  await ensureExtrasTables(env);
  const minute = new Date(Math.floor(call.dueAt.getTime() / 60_000) * 60_000);
  const existing = await dbFirst<{ id: number }>(
    env,
    "SELECT id FROM sms_reminders WHERE phone = ? AND via = 'call' AND status = 'pending' AND due_at >= ? AND due_at < ?",
    [phone, minute.toISOString(), new Date(minute.getTime() + 60_000).toISOString()],
  ).catch(() => null);
  if (!existing) await addReminder(env, phone, call);
  return bookedCallLine(call.dueAt, now);
}

/**
 * YES with nothing else waiting: if one of his texts in the last 30 minutes asked for a timed call
 * (and the chat offered it instead of booking it), book that call now.
 */
export async function bookTimedCallFromRecent(env: Env, phone: string, now = new Date()): Promise<string | null> {
  const since = new Date(now.getTime() - 30 * 60_000).toISOString();
  const rows = await dbAll<{ body: string; created_at: string }>(
    env,
    "SELECT body, created_at FROM sms_turns WHERE phone = ? AND role = 'user' AND created_at >= ? ORDER BY created_at DESC LIMIT 6",
    [phone, since],
  ).catch(() => [] as { body: string; created_at: string }[]);
  for (const row of rows) {
    const asked = new Date(row.created_at);
    const call = parseTimedCall(row.body, Number.isNaN(asked.getTime()) ? now : asked);
    if (call && call.dueAt.getTime() > now.getTime()) return bookTimedCall(env, phone, call, now);
  }
  return null;
}

const readyDbs = new WeakSet<object>();
async function ensureExtrasTables(env: Env): Promise<void> {
  if (readyDbs.has(env.DB as object)) return;
  await dbRun(
    env,
    `CREATE TABLE IF NOT EXISTS sms_reminders (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      phone TEXT NOT NULL,
      task TEXT NOT NULL,
      due_at TEXT NOT NULL,
      via TEXT NOT NULL DEFAULT 'sms',
      status TEXT NOT NULL DEFAULT 'pending',
      created_at TEXT NOT NULL,
      fired_at TEXT
    )`,
  );
  await dbRun(env, "CREATE INDEX IF NOT EXISTS idx_sms_reminders_due ON sms_reminders (status, due_at)").catch(() => 0);
  await dbRun(
    env,
    `CREATE TABLE IF NOT EXISTS price_watches (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      phone TEXT NOT NULL,
      item TEXT NOT NULL,
      symbol TEXT NOT NULL DEFAULT '',
      currency TEXT NOT NULL DEFAULT '£',
      threshold REAL NOT NULL,
      last_price REAL,
      last_source TEXT NOT NULL DEFAULT '',
      status TEXT NOT NULL DEFAULT 'active',
      created_at TEXT NOT NULL,
      checked_at TEXT
    )`,
  );
  await dbRun(
    env,
    `CREATE TABLE IF NOT EXISTS sms_agent_tasks (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      agent TEXT NOT NULL,
      task TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'queued',
      created_at TEXT NOT NULL
    )`,
  );
  readyDbs.add(env.DB as object);
}

async function addReminder(env: Env, phone: string, r: ParsedReminder): Promise<void> {
  await ensureExtrasTables(env);
  await dbRun(env, "INSERT INTO sms_reminders (phone, task, due_at, via, status, created_at) VALUES (?, ?, ?, ?, 'pending', ?)", [
    phone,
    r.task.slice(0, 200),
    r.dueAt.toISOString(),
    r.byCall ? "call" : "sms",
    new Date().toISOString(),
  ]);
}

function sentenceCase(text: string): string {
  return text ? `${text.charAt(0).toUpperCase()}${text.slice(1)}` : text;
}

function reminderSpeech(task: string): string {
  if (task.startsWith(SAY_PREFIX)) return task.slice(SAY_PREFIX.length).trim();
  if (task === WAKE_TASK) return "Good day, Sir. JARVIS here with your wake-up call. Time to get up. Goodbye.";
  return `Good day, Sir. JARVIS here with your reminder: ${task.replace(/\bmy\b/gi, "your").replace(/\bI\b/g, "you")}. That's all. Goodbye.`;
}

/** Every minute: due reminders go out by text, or by George on a call when he asked for a call. */
export async function fireDueReminders(env: Env, now = new Date()): Promise<number> {
  await ensureExtrasTables(env);
  const due = await dbAll<{ id: number; phone: string; task: string; via: string }>(
    env,
    "SELECT id, phone, task, via FROM sms_reminders WHERE status = 'pending' AND due_at <= ? ORDER BY due_at LIMIT 10",
    [now.toISOString()],
  );
  let fired = 0;
  for (const row of due) {
    const claimed = await dbRun(env, "UPDATE sms_reminders SET status = 'firing' WHERE id = ? AND status = 'pending'", [row.id]);
    if (!claimed) continue;
    const { readOwnerMobile } = await import("./owner-alert");
    const { sendSms, simulatedPhone } = await import("./sms-desk");
    let status = "sent";
    if (simulatedPhone(row.phone)) {
      status = "simulated";
    } else {
      const owner = await readOwnerMobile(env);
      if (!owner || owner !== row.phone) {
        status = "skipped";
      } else if (row.via === "call") {
        const call = await reminderCall(env, owner, row.task);
        if (!call.ok) await sendSms(env, owner, `Reminder, Sir: ${spokenTask(row.task)}. (I couldn't ring, so here it is by text.)`);
        else await queueAnswerCheck(env, row.phone, 1, call.sid, row.task, now);
        status = call.ok ? "called" : "sent";
      } else if (row.via === "call-check") {
        status = await answerCheck(env, owner, row.task, now);
      } else {
        await sendSms(env, owner, `Reminder, Sir: ${sentenceCase(row.task)}.`);
      }
    }
    await dbRun(env, "UPDATE sms_reminders SET status = ?, fired_at = ? WHERE id = ?", [status, now.toISOString(), row.id]);
    fired++;
  }
  return fired;
}

function spokenTask(task: string): string {
  if (task.startsWith(SAY_PREFIX)) return "your call";
  return task === WAKE_TASK ? "your wake-up call" : task;
}

/** Four minutes after a timed call, see whether he picked up. Attempt 1 unanswered rings once more; attempt 2 texts. */
async function queueAnswerCheck(env: Env, phone: string, attempt: number, sid: string, task: string, now: Date): Promise<void> {
  if (!/^CA[0-9a-f]{32}$/i.test(sid)) return;
  await dbRun(env, "INSERT INTO sms_reminders (phone, task, due_at, via, status, created_at) VALUES (?, ?, ?, 'call-check', 'pending', ?)", [
    phone,
    `${attempt}|${sid}|${task}`.slice(0, 600),
    new Date(now.getTime() + 4 * 60_000).toISOString(),
    now.toISOString(),
  ]);
}

export const UNANSWERED = ["no-answer", "busy", "failed", "canceled"];

async function twilioCallStatus(env: Env, sid: string): Promise<string> {
  const account = (env.TWILIO_ACCOUNT_SID ?? "").trim();
  const token = (env.TWILIO_AUTH_TOKEN ?? "").trim();
  if (!account || !token) return "";
  try {
    const response = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${account}/Calls/${sid}.json`, {
      headers: { authorization: `Basic ${btoa(`${account}:${token}`)}` },
      signal: AbortSignal.timeout(10_000),
    });
    if (!response.ok) return "";
    const body = (await response.json()) as { status?: string };
    return body.status ?? "";
  } catch {
    return "";
  }
}

async function answerCheck(env: Env, owner: string, raw: string, now: Date): Promise<string> {
  const [attemptText, sid, ...rest] = raw.split("|");
  const task = rest.join("|");
  const attempt = Number(attemptText) || 1;
  if (!sid) return "skipped";
  const state = await twilioCallStatus(env, sid);
  if (!UNANSWERED.includes(state)) return `answered:${state || "unknown"}`;
  const { sendSms } = await import("./sms-desk");
  if (attempt >= 2) {
    await sendSms(env, owner, `Sir, I rang twice for ${spokenTask(task)} and couldn't reach you.`);
    return "texted";
  }
  const again = await reminderCall(env, owner, task);
  if (again.ok) await queueAnswerCheck(env, owner, 2, again.sid, task, now);
  else await sendSms(env, owner, `Sir, you didn't pick up for ${spokenTask(task)}, and I couldn't ring again.`);
  return again.ok ? "retried" : "texted";
}

async function reminderCall(env: Env, owner: string, task: string): Promise<{ ok: boolean; sid: string }> {
  const { callAndPlay, escapeXml, speak, storeNote, elevenCredits } = await import("./voice-notes");
  const words = reminderSpeech(task);
  let twiml = `<Response><Pause length="1"/><Say voice="Polly.Brian" language="en-GB">${escapeXml(words)}</Say></Response>`;
  const credits = await elevenCredits(env);
  if (credits && credits.limit - credits.used >= 2_500) {
    const spoken = await speak(env, words, false);
    if (spoken.ok) {
      const note = await storeNote(env, "speech", spoken.bytes, spoken.chars, words);
      twiml = `<Response><Pause length="1"/><Play>${escapeXml(`${note.url}.mp3`)}</Play></Response>`;
    }
  }
  const call = await callAndPlay(env, owner, twiml, 90);
  return { ok: call.ok, sid: call.sid };
}

async function listReminders(env: Env, phone: string): Promise<string> {
  await ensureExtrasTables(env);
  const rows = await dbAll<{ task: string; due_at: string; via: string }>(
    env,
    "SELECT task, due_at, via FROM sms_reminders WHERE phone = ? AND status = 'pending' AND via IN ('sms', 'call') ORDER BY due_at LIMIT 6",
    [phone],
  );
  if (!rows.length) return "No reminders waiting, Sir. Text 'remind me in 20 mins to stretch' to set one.";
  return `Your reminders, Sir: ${rows.map((r) => `${clockLabel(new Date(r.due_at))} ${spokenTask(r.task)}${r.via === "call" ? " (call)" : ""}`).join("; ")}.`;
}

// ---------------------------------------------------------------- morning text

const WEATHER: Record<number, string> = {
  0: "clear", 1: "mostly clear", 2: "partly cloudy", 3: "overcast", 45: "foggy", 48: "foggy",
  51: "light drizzle", 53: "drizzle", 55: "heavy drizzle", 61: "light rain", 63: "rain", 65: "heavy rain",
  71: "light snow", 73: "snow", 75: "heavy snow", 80: "showers", 81: "showers", 82: "heavy showers",
  95: "thunderstorms", 96: "thunderstorms", 99: "thunderstorms",
};

export async function ashfordWeather(): Promise<string> {
  try {
    const url =
      `https://api.open-meteo.com/v1/forecast?latitude=${ASHFORD.lat}&longitude=${ASHFORD.lon}` +
      "&current=temperature_2m,weather_code&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max&timezone=Europe%2FLondon&forecast_days=1";
    const response = await fetch(url, { headers: { "user-agent": UA }, signal: AbortSignal.timeout(6_000) });
    if (!response.ok) return "";
    const body = (await response.json()) as {
      current?: { temperature_2m?: number; weather_code?: number };
      daily?: { temperature_2m_max?: number[]; temperature_2m_min?: number[]; precipitation_probability_max?: number[] };
    };
    const now = Math.round(Number(body.current?.temperature_2m));
    const hi = Math.round(Number(body.daily?.temperature_2m_max?.[0]));
    const lo = Math.round(Number(body.daily?.temperature_2m_min?.[0]));
    const rain = Number(body.daily?.precipitation_probability_max?.[0]);
    const sky = WEATHER[Number(body.current?.weather_code)] ?? "mixed";
    if (!Number.isFinite(now)) return "";
    return `Ashford ${now}C, ${sky}, high ${hi}C low ${lo}C${Number.isFinite(rain) ? `, ${Math.round(rain)}% rain` : ""}.`;
  } catch {
    return "";
  }
}

export async function morningText(env: Env, phone: string, now = new Date()): Promise<string> {
  await ensureExtrasTables(env);
  const weather = await ashfordWeather();
  const today = londonParts(now).ymd;
  const end = atLondon(addDays(today, 1), 0, 0).toISOString();
  const rows = await dbAll<{ task: string; due_at: string }>(
    env,
    "SELECT task, due_at FROM sms_reminders WHERE phone = ? AND status = 'pending' AND via IN ('sms', 'call') AND due_at < ? ORDER BY due_at LIMIT 4",
    [phone, end],
  ).catch(() => []);
  const reminders = rows.length ? `Today: ${rows.map((r) => `${clockLabel(new Date(r.due_at), now)} ${r.task}`).join("; ")}.` : "No reminders today.";
  const paper = ((await getState(env, "morning:paper_line").catch(() => null)) ?? "").trim().slice(0, 120);
  const parts = ["Morning, Sir.", weather || "Weather is unavailable just now.", reminders];
  if (paper) parts.push(paper);
  parts.push("('stop morning' to pause)");
  return parts.join(" ").slice(0, 450);
}

/** Once a day at 08:00 London, unless he said stop morning. */
export async function sweepMorningText(env: Env, now = new Date()): Promise<boolean> {
  const p = londonParts(now);
  if (p.hour !== 8 || p.minute > 9) return false;
  if (((await getState(env, "morning:off").catch(() => null)) ?? "") === "1") return false;
  if (((await getState(env, "morning:last").catch(() => null)) ?? "") === p.ymd) return false;
  const { readOwnerMobile } = await import("./owner-alert");
  const owner = await readOwnerMobile(env);
  if (!owner) return false;
  await setState(env, "morning:last", p.ymd);
  const { sendSms } = await import("./sms-desk");
  return sendSms(env, owner, await morningText(env, owner, now));
}

// ---------------------------------------------------------------- nearby

/** [what he says, label, Nominatim search words, cuisine filter]. */
const PLACE_TAGS: [RegExp, string, string[], RegExp?][] = [
  [/\b(?:pharmac(?:y|ies)|chemists?)\b/i, "pharmacy", ["pharmacy"]],
  [/\b(?:petrol|fuel|gas station|petrol station)\b/i, "petrol station", ["fuel"]],
  [/\b(?:cafes?|coffee(?: shops?)?)\b/i, "cafe", ["cafe"]],
  [/\b(?:chippy|fish and chips?)\b/i, "chippy", ["fast food", "restaurant"], /fish_and_chips|fish|chip/i],
  [/\b(?:chinese)\b/i, "Chinese", ["restaurant", "fast food"], /chinese/i],
  [/\b(?:indian|curry)\b/i, "Indian", ["restaurant", "fast food"], /indian|curry|bangladeshi|nepal/i],
  [/\b(?:pizza)\b/i, "pizza place", ["fast food", "restaurant"], /pizza/i],
  [/\b(?:kebab)\b/i, "kebab shop", ["fast food"], /kebab|turkish/i],
  [/\b(?:takeaways?|fast food)\b/i, "takeaway", ["fast food"]],
  [/\b(?:restaurants?)\b/i, "restaurant", ["restaurant"]],
  [/\b(?:pubs?|bars?)\b/i, "pub", ["pub"]],
  [/\b(?:supermarkets?|groceries|grocery|food shop)\b/i, "supermarket", ["supermarket"]],
  [/\b(?:corner shop|convenience|off licen[cs]e)\b/i, "shop", ["convenience store"]],
  [/\b(?:atms?|cash ?machines?|cashpoints?)\b/i, "cash machine", ["atm"]],
  [/\b(?:a ?& ?e|hospitals?)\b/i, "hospital", ["hospital"]],
  [/\b(?:gp|doctors?|surgery)\b/i, "GP", ["doctors"]],
  [/\b(?:dentists?)\b/i, "dentist", ["dentist"]],
  [/\b(?:gyms?)\b/i, "gym", ["gym"]],
  [/\b(?:banks?)\b/i, "bank", ["bank"]],
  [/\b(?:post office)\b/i, "post office", ["post office"]],
  [/\b(?:car wash)\b/i, "car wash", ["car wash"]],
  [/\b(?:barbers?|hairdressers?)\b/i, "barber", ["hairdresser"]],
  [/\b(?:vets?)\b/i, "vet", ["veterinary"]],
  [/\b(?:toilets?|loos?)\b/i, "toilet", ["toilets"]],
  [/\b(?:parking|car park)\b/i, "car park", ["parking"]],
  [/\b(?:ev charg\w*|charging point|charger)\b/i, "EV charger", ["charging station"]],
];

export interface NearbyAsk {
  label: string;
  terms: string[];
  cuisine?: RegExp;
  openOnly: boolean;
  place: string;
}

export function nearbyAsk(text: string): NearbyAsk | null {
  const clean = text.replace(/\s+/g, " ").trim().replace(/[?.!]+$/, "");
  const asks =
    /\b(?:nearest|closest|nearby|near me|near here|close by|around here)\b/i.test(clean) ||
    /^(?:where(?:'s| is| can i find)|find me|any)\b.*\b(?:open|near|around)\b/i.test(clean);
  if (!asks) return null;
  const found = PLACE_TAGS.find(([re]) => re.test(clean));
  let label = "";
  let terms: string[] = [];
  let cuisine: RegExp | undefined;
  if (found) {
    label = found[1];
    terms = found[2];
    cuisine = found[3];
  } else {
    const what = /\b(?:nearest|closest)\s+(?:open\s+)?([a-z][a-z' -]{2,30}?)(?:\s+(?:near|in|to|around|that)\b|$)/i.exec(clean)?.[1];
    if (!what) return null;
    label = what.trim();
    terms = [label];
  }
  const where = /\b(?:near|in|around)\s+(?!me\b|here\b)([A-Z][\w' -]{2,40})$/.exec(clean)?.[1]?.trim() ?? "";
  return { label, terms, ...(cuisine ? { cuisine } : {}), openOnly: /\bopen\b/i.test(clean), place: where };
}

const DAY_KEYS = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"];

/** Common OSM opening_hours forms: 24/7, "Mo-Fr 09:00-18:00; Sa 09:00-13:00; Su off". Null when unknown. */
export function openNow(hours: string, at: Date): { open: boolean; until: string } | null {
  const spec = hours.trim();
  if (!spec) return null;
  if (/^24\/7$/.test(spec)) return { open: true, until: "24 hours" };
  const p = londonParts(at);
  const mins = p.hour * 60 + p.minute;
  let result: { open: boolean; until: string } | null = null;
  let understood = false;
  for (const raw of spec.replace(/(\d{2}:\d{2}),\s*(?=(?:Mo|Tu|We|Th|Fr|Sa|Su|PH)\b)/g, "$1;").split(";")) {
    const rule = raw.trim();
    if (!rule || /^PH\b/.test(rule)) continue;
    const m = /^((?:(?:Mo|Tu|We|Th|Fr|Sa|Su)(?:-(?:Mo|Tu|We|Th|Fr|Sa|Su))?,?\s*)+)?\s*(off|closed|24\/7|(?:\d{1,2}:\d{2}-\d{1,2}:\d{2}\+?,?\s*)+)$/.exec(rule);
    if (!m) return understood ? result : null;
    understood = true;
    const days = new Set<number>();
    if (m[1]) {
      for (const chunk of m[1].replace(/\s/g, "").split(",").filter(Boolean)) {
        const [a, b] = chunk.split("-") as [string, string | undefined];
        const from = DAY_KEYS.indexOf(a);
        const to = b ? DAY_KEYS.indexOf(b) : from;
        if (from < 0 || to < 0) return null;
        for (let d = from; ; d = (d + 1) % 7) {
          days.add(d);
          if (d === to) break;
        }
      }
    } else {
      for (let d = 0; d < 7; d++) days.add(d);
    }
    if (!days.has(p.weekday)) continue;
    const times = m[2]!;
    if (/^(?:off|closed)$/.test(times)) {
      result = { open: false, until: "" };
      continue;
    }
    if (times === "24/7") {
      result = { open: true, until: "24 hours" };
      continue;
    }
    result = { open: false, until: "" };
    for (const span of times.split(",")) {
      const t = /(\d{1,2}):(\d{2})-(\d{1,2}):(\d{2})/.exec(span);
      if (!t) continue;
      const start = Number(t[1]) * 60 + Number(t[2]);
      let end = Number(t[3]) * 60 + Number(t[4]);
      if (end <= start) end += 24 * 60;
      if (mins >= start && mins < end) result = { open: true, until: `${t[3]}:${t[4]}` };
    }
  }
  return result;
}

function distanceKm(a: { lat: number; lon: number }, b: { lat: number; lon: number }): number {
  const rad = Math.PI / 180;
  const dLat = (b.lat - a.lat) * rad;
  const dLon = (b.lon - a.lon) * rad;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(a.lat * rad) * Math.cos(b.lat * rad) * Math.sin(dLon / 2) ** 2;
  return 12_742 * Math.asin(Math.sqrt(h));
}

interface Spot {
  name: string;
  lat: number;
  lon: number;
  km: number;
  status: { open: boolean; until: string } | null;
}

async function nominatim(query: string, limit: number): Promise<{ lat: string; lon: string; name?: string; type?: string; extratags?: Record<string, string> | null }[] | null> {
  try {
    const url = `https://nominatim.openstreetmap.org/search?format=jsonv2&extratags=1&countrycodes=gb&limit=${limit}&q=${encodeURIComponent(query)}`;
    const response = await fetch(url, { headers: { "user-agent": UA, accept: "application/json", "accept-language": "en-GB" }, signal: AbortSignal.timeout(8_000) });
    if (!response.ok) return null;
    return (await response.json()) as { lat: string; lon: string; name?: string; type?: string; extratags?: Record<string, string> | null }[];
  } catch {
    return null;
  }
}

/** OpenStreetMap via Nominatim: no key, opening hours when the map has them. */
export async function findNearby(ask: NearbyAsk, now = new Date()): Promise<{ centre: string; spots: Spot[] } | null> {
  const placeName = ask.place ? `${ask.place}` : ASHFORD.label;
  let centre: { lat: number; lon: number } = { lat: ASHFORD.lat, lon: ASHFORD.lon };
  if (ask.place) {
    const hit = (await nominatim(`${ask.place}, UK`, 1))?.[0];
    if (!hit) return null;
    centre = { lat: Number(hit.lat), lon: Number(hit.lon) };
  }
  const spots: Spot[] = [];
  const seen = new Set<string>();
  let answered = false;
  for (const term of ask.terms.slice(0, 2)) {
    const rows = await nominatim(`${term} near ${placeName}`, ask.cuisine ? 40 : 15);
    if (!rows) continue;
    answered = true;
    for (const row of rows) {
      const tags = row.extratags ?? {};
      if (ask.cuisine && !ask.cuisine.test(`${tags.cuisine ?? ""} ${row.name ?? ""}`)) continue;
      const lat = Number(row.lat);
      const lon = Number(row.lon);
      const name = row.name || tags.brand || tags.operator || sentenceCase(ask.label);
      const key = `${name}|${lat.toFixed(4)}|${lon.toFixed(4)}`;
      if (!Number.isFinite(lat) || seen.has(key)) continue;
      seen.add(key);
      spots.push({ name, lat, lon, km: distanceKm(centre, { lat, lon }), status: openNow(tags.opening_hours ?? "", now) });
    }
  }
  if (!answered) return null;
  spots.sort((a, b) => a.km - b.km);
  return { centre: placeName, spots: spots.filter((s) => s.km <= 15) };
}

export function nearbyLine(ask: NearbyAsk, found: { centre: string; spots: Spot[] }): string {
  const mapLink = (s: Spot) => `https://maps.google.com/?q=${s.lat.toFixed(5)},${s.lon.toFixed(5)}`;
  const status = (s: Spot) => (s.status ? (s.status.open ? `open${s.status.until && s.status.until !== "24 hours" ? ` till ${s.status.until}` : " 24h"}` : "closed now") : "hours unknown");
  const where = found.centre === ASHFORD.label ? "" : ` near ${found.centre}`;
  if (!found.spots.length) return `I couldn't find a ${ask.label}${where} within 8 km, Sir.`;
  const open = found.spots.filter((s) => s.status?.open);
  const pick = ask.openOnly ? (open[0] ?? found.spots.find((s) => s.status?.open !== false) ?? found.spots[0]!) : found.spots[0]!;
  const lead =
    ask.openOnly && !open.length
      ? `I can't confirm opening hours${where}, Sir. Nearest ${ask.label}:`
      : `Nearest ${ask.openOnly ? "open " : ""}${ask.label}${where}, Sir:`;
  const second = found.spots.find((s) => s !== pick && (!ask.openOnly || s.status?.open !== false));
  const extra = second ? ` Next: ${second.name}, ${second.km.toFixed(1)} km, ${status(second)}.` : "";
  return `${lead} ${pick.name}, ${pick.km.toFixed(1)} km, ${status(pick)}. ${mapLink(pick)}${extra}`.slice(0, 300);
}

// ---------------------------------------------------------------- price watch

const TICKERS: Record<string, string> = {
  tesla: "TSLA", apple: "AAPL", nvidia: "NVDA", amazon: "AMZN", microsoft: "MSFT", google: "GOOGL", alphabet: "GOOGL",
  meta: "META", facebook: "META", netflix: "NFLX", gamestop: "GME", palantir: "PLTR", amd: "AMD", intel: "INTC",
  coinbase: "COIN", disney: "DIS", nike: "NKE", uber: "UBER", spotify: "SPOT", shopify: "SHOP",
};

export interface WatchAsk {
  item: string;
  symbol: string;
  currency: string;
  threshold: number;
}

export function watchAsk(text: string): WatchAsk | null {
  const clean = text.replace(/\s+/g, " ").trim().replace(/[.!]+$/, "");
  const m =
    /^(?:please\s+)?(?:watch|track|monitor|keep an eye on)\s+(?:the price of\s+)?(.{2,80}?)\s*(?:,|\band\b)?\s*(?:text|tell|ping|let) me(?: know)?\s+(?:when|if|once)\s+(?:it(?:'s| is| goes| gets| drops| falls)?|they(?:'re| are| go| drop)?|the price (?:is|goes|drops))?\s*(?:under|below|less than|beneath|to|down to)\s*([£$€])?\s*(\d[\d,]*(?:\.\d+)?)\s*(k|p)?/i.exec(clean) ??
    /^(?:please\s+)?(?:watch|track|alert me (?:about|on))\s+(.{2,80}?)\s+(?:under|below|less than)\s*([£$€])?\s*(\d[\d,]*(?:\.\d+)?)\s*(k|p)?$/i.exec(clean);
  if (!m) return null;
  let item = m[1]!.replace(/\s+(?:for me|price|prices)$/i, "").trim();
  let threshold = Number(m[3]!.replace(/,/g, ""));
  if (m[4]?.toLowerCase() === "k") threshold *= 1000;
  if (m[4]?.toLowerCase() === "p") threshold /= 100;
  if (!Number.isFinite(threshold) || threshold <= 0) return null;
  let symbol = "";
  const dollar = /\$([A-Za-z]{1,5})\b/.exec(item);
  const stockWord = /\b([A-Za-z]{1,12})\s+(?:stock|shares?)\b/i.exec(item);
  if (dollar) symbol = dollar[1]!.toUpperCase();
  else if (stockWord) symbol = TICKERS[stockWord[1]!.toLowerCase()] ?? (/^[A-Z]{1,5}$/.test(stockWord[1]!) ? stockWord[1]! : "");
  else if (/^[A-Z]{2,5}$/.test(item)) symbol = item;
  else if (TICKERS[item.toLowerCase()]) symbol = TICKERS[item.toLowerCase()]!;
  item = item.replace(/^\$/, "");
  const currency = m[2] ?? (symbol ? "$" : "£");
  return { item, symbol, currency, threshold };
}

export async function stockQuote(symbol: string): Promise<number | null> {
  for (const host of ["query1", "query2"]) {
    try {
      const url = `https://${host}.finance.yahoo.com/v8/finance/chart/${encodeURIComponent(symbol.toUpperCase())}?range=1d&interval=1d`;
      const response = await fetch(url, { headers: { "user-agent": "Mozilla/5.0 (JARVIS price watch)" }, signal: AbortSignal.timeout(6_000) });
      if (!response.ok) continue;
      const body = (await response.json()) as { chart?: { result?: { meta?: { regularMarketPrice?: number } }[] } };
      const price = Number(body.chart?.result?.[0]?.meta?.regularMarketPrice);
      if (Number.isFinite(price) && price > 0) return price;
    } catch {
      // next host
    }
  }
  return null;
}

/** Search hits as text blobs: snippets first, then the top pages read in full when snippets say nothing. */
async function searchBlobs(env: Env, query: string, wanted: RegExp): Promise<{ text: string; host: string }[]> {
  const { webSearch, fetchPublicPage } = await import("./search");
  const { liveSearch } = await import("./live-tools");
  // A grounded answer first (Gemini Search grounding, then Groq browser search): it reads live pages.
  const live = await liveSearch(env, query).catch(() => null);
  const hostOf = (url: string) => {
    try {
      return new URL(url).hostname.replace(/^www\./, "");
    } catch {
      return url.slice(0, 40);
    }
  };
  const liveBlob = live && live.ok && live.provider !== "search" ? [{ text: live.answer, host: live.sources[0] ? hostOf(live.sources[0]) : "web search" }] : [];
  if (liveBlob.length && new RegExp(wanted.source, wanted.flags.replace("g", "")).test(liveBlob[0]!.text)) return liveBlob;
  const found = await webSearch(env, query);
  if (!found.ok) return liveBlob;
  const host = (url: string) => {
    try {
      return new URL(url).hostname.replace(/^www\./, "");
    } catch {
      return "";
    }
  };
  const blobs = [...liveBlob, ...found.results.slice(0, 8).map((r) => ({ text: `${r.title ?? ""} ${r.snippet ?? ""}`, host: host(r.url) }))];
  if (blobs.some((b) => new RegExp(wanted.source, wanted.flags.replace("g", "")).test(b.text))) return blobs;
  const pages = await Promise.all(
    found.results.slice(0, 3).map(async (r) => {
      const page = await fetchPublicPage(r.url).catch(() => null);
      return page && page.ok ? { text: page.text.slice(0, 60_000), host: host(r.url) } : null;
    }),
  );
  return [...blobs, ...pages.filter((p): p is { text: string; host: string } => Boolean(p))];
}

/** Best effort: the lowest believable £ price for the item in search results. */
export async function productPrice(env: Env, item: string, threshold: number): Promise<{ price: number; source: string } | null> {
  const pricePattern = /£\s?(\d{1,3}(?:,\d{3})*(?:\.\d{2})?|\d+(?:\.\d{2})?)/g;
  const blobs = await searchBlobs(env, `${item} price UK`, pricePattern);
  let best: { price: number; source: string } | null = null;
  for (const blob of blobs) {
    for (const m of blob.text.matchAll(pricePattern)) {
      const price = Number(m[1]!.replace(/,/g, ""));
      if (!Number.isFinite(price) || price < threshold * 0.35 || price > threshold * 6) continue;
      if (!best || price < best.price) best = { price, source: blob.host };
    }
  }
  return best;
}

async function checkWatch(env: Env, w: { item: string; symbol: string; threshold: number }): Promise<{ price: number; source: string } | null> {
  if (w.symbol) {
    const price = await stockQuote(w.symbol);
    return price === null ? null : { price, source: "Yahoo Finance" };
  }
  return productPrice(env, w.item, w.threshold);
}

function money(currency: string, value: number): string {
  return `${currency}${value >= 100 ? value.toFixed(0) : value.toFixed(2)}`;
}

async function addWatch(env: Env, phone: string, w: WatchAsk): Promise<string> {
  await ensureExtrasTables(env);
  const active = await dbFirst<{ n: number }>(env, "SELECT count(*) AS n FROM price_watches WHERE phone = ? AND status = 'active'", [phone]);
  if (Number(active?.n ?? 0) >= 15) return "You have 15 watches running, Sir. Text 'stop watching X' to free one first.";
  const now = await checkWatch(env, w).catch(() => null);
  await dbRun(
    env,
    "INSERT INTO price_watches (phone, item, symbol, currency, threshold, last_price, last_source, status, created_at, checked_at) VALUES (?, ?, ?, ?, ?, ?, ?, 'active', ?, ?)",
    [phone, w.item.slice(0, 80), w.symbol, w.currency, w.threshold, now?.price ?? null, now?.source ?? "", new Date().toISOString(), new Date().toISOString()],
  );
  const name = w.symbol ? `${w.symbol} (US$)` : w.item;
  const current = now ? ` It's ${money(w.symbol ? "$" : w.currency, now.price)} now${now.source && !w.symbol ? ` (${now.source})` : ""}.` : " I couldn't read a price yet; I'll keep checking.";
  const hit = now && now.price < w.threshold ? " That's already under, Sir." : "";
  return `Watching ${name}, Sir. I'll text you when it's under ${money(w.currency, w.threshold)}, checked daily at 9am.${current}${hit}`;
}

async function listWatches(env: Env, phone: string): Promise<string> {
  await ensureExtrasTables(env);
  const rows = await dbAll<{ item: string; symbol: string; currency: string; threshold: number; last_price: number | null }>(
    env,
    "SELECT item, symbol, currency, threshold, last_price FROM price_watches WHERE phone = ? AND status = 'active' ORDER BY id LIMIT 8",
    [phone],
  );
  if (!rows.length) return "No price watches running, Sir. Try 'watch PS5 and text me when under £400'.";
  return `Your watches, Sir: ${rows
    .map((r) => `${r.symbol || r.item} under ${money(r.currency, r.threshold)}${r.last_price ? ` (last ${money(r.symbol ? "$" : r.currency, r.last_price)})` : ""}`)
    .join("; ")}.`;
}

async function stopWatch(env: Env, phone: string, what: string): Promise<string> {
  await ensureExtrasTables(env);
  const term = what.trim().replace(/^(?:the|my)\s+/i, "");
  const all = /^(?:all|everything|them all|all of them)$/i.test(term);
  const changed = all
    ? await dbRun(env, "UPDATE price_watches SET status = 'stopped' WHERE phone = ? AND status = 'active'", [phone])
    : await dbRun(
        env,
        "UPDATE price_watches SET status = 'stopped' WHERE phone = ? AND status = 'active' AND (lower(item) LIKE ? OR lower(symbol) = ?)",
        [phone, `%${term.toLowerCase()}%`, term.toLowerCase()],
      );
  if (!changed) return `I'm not watching anything called ${term}, Sir. Text 'my watches' to see the list.`;
  return all ? "All price watches stopped, Sir." : `Stopped watching ${term}, Sir.`;
}

/** Once a day at 09:00 London. A hit texts Sir once and ends that watch. */
export async function sweepPriceWatches(env: Env, now = new Date(), force = false): Promise<number> {
  const p = londonParts(now);
  if (!force) {
    if (p.hour !== 9) return 0;
    if (((await getState(env, "watch:last").catch(() => null)) ?? "") === p.ymd) return 0;
    await setState(env, "watch:last", p.ymd);
  }
  await ensureExtrasTables(env);
  const rows = await dbAll<{ id: number; phone: string; item: string; symbol: string; currency: string; threshold: number }>(
    env,
    "SELECT id, phone, item, symbol, currency, threshold FROM price_watches WHERE status = 'active' ORDER BY id LIMIT 15",
  );
  let hits = 0;
  const { readOwnerMobile } = await import("./owner-alert");
  const { sendSms, simulatedPhone } = await import("./sms-desk");
  const owner = await readOwnerMobile(env);
  for (const w of rows) {
    const found = await checkWatch(env, w).catch(() => null);
    if (!found) continue;
    await dbRun(env, "UPDATE price_watches SET last_price = ?, last_source = ?, checked_at = ? WHERE id = ?", [found.price, found.source, now.toISOString(), w.id]);
    if (found.price >= w.threshold) continue;
    hits++;
    await dbRun(env, "UPDATE price_watches SET status = 'hit' WHERE id = ?", [w.id]);
    if (simulatedPhone(w.phone) || !owner || owner !== w.phone) continue;
    const label = w.symbol ? `${w.symbol} is $${found.price.toFixed(2)}` : `${w.item} is ${money(w.currency, found.price)}${found.source ? ` at ${found.source}` : ""}`;
    await sendSms(env, owner, `Price alert, Sir: ${label}, under your ${money(w.currency, w.threshold)}. Watch closed.`);
  }
  return hits;
}

// ---------------------------------------------------------------- photos

export function imageLink(text: string): string | null {
  const url = /https?:\/\/\S+/i.exec(text)?.[0]?.replace(/[)>.,]+$/, "");
  return url ?? null;
}

async function fetchImage(env: Env, url: string): Promise<{ mime: string; b64: string } | null> {
  const twilio = /^https:\/\/api\.twilio\.com\//.test(url);
  const headers: Record<string, string> = { "user-agent": UA };
  if (twilio) {
    const account = (env.TWILIO_ACCOUNT_SID ?? "").trim();
    const token = (env.TWILIO_AUTH_TOKEN ?? "").trim();
    headers.authorization = `Basic ${btoa(`${account}:${token}`)}`;
  } else {
    const { parsePublicHttpUrl } = await import("./sources");
    if (!parsePublicHttpUrl(url).ok) return null;
  }
  try {
    const response = await fetch(url, { headers, redirect: "follow", signal: AbortSignal.timeout(10_000) });
    const mime = (response.headers.get("content-type") ?? "").split(";")[0]!.trim().toLowerCase();
    if (!response.ok || !/^image\/(?:jpeg|jpg|png|webp|gif|heic|heif)$/.test(mime)) return null;
    const bytes = new Uint8Array(await response.arrayBuffer());
    if (bytes.length < 200 || bytes.length > 6_000_000) return null;
    let binary = "";
    for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    return { mime: mime === "image/jpg" ? "image/jpeg" : mime, b64: btoa(binary) };
  } catch {
    return null;
  }
}

const VISION_PROMPT =
  "You are J.A.R.V.I.S., Sir's British assistant, answering by text message. Look at the photo and reply with what matters: what it is, any key facts, numbers, dates, deadlines, amounts due, or what he should do next. If he asked a question, answer it directly. Plain text, no markdown, under 300 characters, call him Sir once.";

export async function describeImage(env: Env, image: { mime: string; b64: string }, question: string): Promise<string | null> {
  const user = [
    { type: "text", text: question.trim() || "What's in this photo, and what matters?" },
    { type: "image_url", image_url: { url: `data:${image.mime};base64,${image.b64}` } },
  ];
  const providers: [string, string | undefined, string][] = [
    [GEMINI_URL, env.GEMINI_API_KEY, GEMINI_MODEL],
    [GEMINI_URL, env.GEMINI_API_KEY, "gemini-2.5-flash"],
    [GROQ_URL, env.GROQ_API_KEY, "meta-llama/llama-4-scout-17b-16e-instruct"],
  ];
  for (const [url, key, model] of providers) {
    if (!key) continue;
    try {
      const response = await fetch(url, {
        method: "POST",
        headers: { authorization: `Bearer ${key}`, "content-type": "application/json" },
        body: JSON.stringify({ model, max_tokens: 400, messages: [{ role: "system", content: VISION_PROMPT }, { role: "user", content: user }] }),
        signal: AbortSignal.timeout(12_000),
      });
      if (!response.ok) continue;
      const body = (await response.json()) as { choices?: { message?: { content?: string } }[] };
      const text = (body.choices?.[0]?.message?.content ?? "").replace(/[*_#`]+/g, "").replace(/\s+/g, " ").trim();
      if (text) return text.slice(0, 300);
    } catch {
      // next provider
    }
  }
  return null;
}

// ---------------------------------------------------------------- agents

const AGENTS: [RegExp, string][] = [
  [/^project\s*money$/i, "Project Money"],
  [/^ultron$/i, "ULTRON"],
  [/^friday$/i, "FRIDAY"],
  [/^edith$/i, "EDITH"],
  [/^jarvis$/i, "JARVIS"],
];

export function agentAsk(text: string): { agent: string; task: string } | null {
  const clean = text.replace(/\s+/g, " ").trim();
  const m = /^(?:please\s+)?(?:tell|ask|get|have)\s+(project\s*money|u\.?l\.?t\.?r\.?o\.?n\.?|f\.?r\.?i\.?d\.?a\.?y\.?|e\.?d\.?i\.?t\.?h\.?|j\.?a\.?r\.?v\.?i\.?s\.?)\s*,?\s+(?:to\s+)?(.{3,600})$/i.exec(clean);
  if (!m) return null;
  const name = m[1]!.replace(/\./g, "");
  const agent = AGENTS.find(([re]) => re.test(name))?.[1];
  if (!agent) return null;
  return { agent, task: m[2]!.trim() };
}

async function passToAgent(env: Env, ask: { agent: string; task: string }, sim: boolean): Promise<string> {
  await ensureExtrasTables(env);
  const { assistantWebhookReady } = await import("./agent-chat");
  const task = `[From Sohail by text, for ${ask.agent}] ${ask.task}`;
  if (!sim && assistantWebhookReady(env)) {
    try {
      const response = await fetch((env.JARVIS_WEBHOOK_URL ?? "").trim(), {
        method: "POST",
        redirect: "manual",
        signal: AbortSignal.timeout(8_000),
        headers: { authorization: (env.JARVIS_WEBHOOK_KEY ?? "").trim(), "content-type": "application/json" },
        body: JSON.stringify({ task, conversationId: `sms-${ask.agent.toLowerCase().replace(/\s+/g, "-")}`, replyTo: "sms" }),
      });
      await response.text().catch(() => "");
      if (response.status >= 200 && response.status < 300) {
        await dbRun(env, "INSERT INTO sms_agent_tasks (agent, task, status, created_at) VALUES (?, ?, 'passed', ?)", [ask.agent, ask.task, new Date().toISOString()]);
        return `Passed to ${ask.agent}, Sir.`;
      }
    } catch {
      // fall through to the queue
    }
  }
  await dbRun(env, "INSERT INTO sms_agent_tasks (agent, task, status, created_at) VALUES (?, ?, ?, ?)", [
    ask.agent,
    ask.task,
    sim ? "simulated" : "queued",
    new Date().toISOString(),
  ]);
  return `Queued for ${ask.agent}, Sir. It's saved in the agent queue and goes over when the bridge picks it up.`;
}

export async function agentQueue(env: Env): Promise<{ id: number; agent: string; task: string; status: string; created_at: string }[]> {
  await ensureExtrasTables(env);
  return dbAll(env, "SELECT id, agent, task, status, created_at FROM sms_agent_tasks ORDER BY id DESC LIMIT 20");
}

// ---------------------------------------------------------------- prank calls

const PRANK_BANNED =
  /\b(?:police|officer|detective|arrest\w*|warrant|court|bailiffs?|hmrc|tax(?:man)?|customs|border force|immigration|home office|council|government|dvla|nhs|doctor|hospital|ambulance|accident|emergency|injur\w*|dead|died|death|kidnap\w*|hostage|bomb|threat\w*|kill|hurt|attack|courier|parcel|delivery fee|royal mail|dpd|evri|hermes|ups|fedex|amazon|bank|fraud|scam|account|card|pin|password|security code|otp|verification|pay|payment|money|transfer|fine|debt|owe|refund|bitcoin|crypto|gift card|date of birth|address|national insurance|passport|personal details?|bank details)\b/i;

export interface PrankAsk {
  phone: string;
  bit: string;
}

export function prankAsk(text: string): PrankAsk | null {
  const clean = text.replace(/\s+/g, " ").trim();
  const m = /^(?:please\s+)?(?:prank(?:\s*call)?|do a prank (?:call )?(?:on|to)|prank ring)\s+((?:\+|\b0)\d[\d\s-]{8,}\d)\b[\s,:-]*(?:and\s+)?(.*)$/i.exec(clean);
  if (!m) return null;
  return { phone: m[1]!.replace(/[\s-]/g, ""), bit: (m[2] ?? "").replace(/^(?:tell (?:them|him|her)|say|pretend|saying)\s+/i, "").trim() };
}

export function prankUnsafe(bit: string): boolean {
  return PRANK_BANNED.test(bit);
}

export const PRANK_REVEAL = "This was a harmless prank from Sohail's AI assistant, JARVIS. Have a brilliant day!";

async function prankScript(env: Env, bit: string): Promise<string> {
  const { completeChat } = await import("./llm");
  const theme = bit || "a very serious survey about their favourite biscuit";
  const result = await completeChat(
    env,
    [
      {
        role: "system",
        content:
          "Write the words for a 30-second harmless, silly prank phone message, spoken by a posh British butler voice. It must be obviously light-hearted: a ridiculous survey, a fake award, a singing telegram or a daft announcement. Never claim to be police, a courier, a bank, a doctor, a council, a government body or any official; never mention emergencies, injuries, money, payments, fines, debts or personal details; never ask them to do anything. No names except Sohail. Under 380 characters. Plain text only. Do not include any ending; the reveal is added separately.",
      },
      { role: "user", content: `The bit: ${theme}` },
    ],
    null,
    { timeoutMs: 8_000, budgetMs: 12_000, maxTokens: 500 },
  );
  let script = result.ok ? (result.message.content ?? "").replace(/[*_#`"]+/g, "").replace(/\s+/g, " ").trim() : "";
  if (!script || prankUnsafe(script)) {
    script = "Good afternoon. This is a very important call from the Ministry of Silly Walks Appreciation Society. You have been selected as this week's most likely person to own a fabulous teapot. Please celebrate accordingly with a biscuit.";
  }
  return script.slice(0, 380);
}

async function offerPrank(env: Env, owner: string, p: PrankAsk, sim: boolean): Promise<string> {
  const { toE164, isBlockedNumber } = await import("./calls");
  const to = toE164(p.phone);
  if (!to || isBlockedNumber(to)) return "I can't ring that number for a prank, Sir.";
  if (to === owner && !sim) {
    // He may prank himself to test; still fine.
  }
  if (prankUnsafe(p.bit)) {
    return "I'll pass on that one, Sir: no pretending to be police, customs, couriers, banks or officials, and nothing about money, emergencies or personal details. Try 'prank 07... with a fake award for best kettle in Kent' and I'll reveal it's you at the end.";
  }
  const script = await prankScript(env, p.bit);
  await setState(env, `prank:${owner}`, JSON.stringify({ to, script, expires: Date.now() + 15 * 60_000 }));
  const preview = script.length > 140 ? `${script.slice(0, 137)}...` : script;
  return `Prank ready for ${to}, Sir: "${preview}" Ends with: ${PRANK_REVEAL} Max 60s. Reply YES to ring.`;
}

/** YES after a prank offer places it. Returns null when no prank is waiting. */
export async function placePendingPrank(env: Env, owner: string, sim: boolean): Promise<string | null> {
  const raw = await getState(env, `prank:${owner}`).catch(() => null);
  if (!raw) return null;
  await setState(env, `prank:${owner}`, "").catch(() => undefined);
  let pending: { to?: string; script?: string; expires?: number } = {};
  try {
    pending = JSON.parse(raw) as typeof pending;
  } catch {
    return null;
  }
  if (!pending.to || !pending.script) return null;
  if ((pending.expires ?? 0) < Date.now()) return "That prank expired, Sir. Send it again if you still want it.";
  if (sim) return `Simulation: I would ring ${pending.to} now with the prank (max 60s, reveal at the end). Nothing was dialled.`;
  const { callAndPlay, escapeXml, speak, storeNote } = await import("./voice-notes");
  const spoken = await speak(env, `${pending.script} ... ${PRANK_REVEAL}`, false);
  let twiml: string;
  if (spoken.ok) {
    const note = await storeNote(env, "speech", spoken.bytes, spoken.chars, `[prank] ${pending.script}`);
    twiml = `<Response><Pause length="1"/><Play>${escapeXml(`${note.url}.mp3`)}</Play><Hangup/></Response>`;
  } else {
    twiml = `<Response><Pause length="1"/><Say voice="Polly.Brian" language="en-GB">${escapeXml(`${pending.script} ${PRANK_REVEAL}`)}</Say><Hangup/></Response>`;
  }
  const call = await callAndPlay(env, pending.to, twiml, 60);
  return call.ok ? `Ringing ${pending.to} now, Sir. 60 seconds max, and it reveals it's you at the end.` : (console.error("prank call not placed", call.error), "The prank call didn't go through on my side, Sir. Nothing was dialled. Text it again in a minute and I'll retry.");
}

// ---------------------------------------------------------------- ring a business by name

export function ringByName(text: string): { name: string; place: string; verb: "ask" | "tell"; purpose: string } | null {
  const clean = text.replace(/\s+/g, " ").trim().replace(/[.!]+$/, "");
  if (/\d{6,}/.test(clean.replace(/[\s-]/g, ""))) return null;
  const m = /^(?:please\s+)?(?:ring|call|phone)\s+(?!me\b|him\b|her\b|them\b|back\b|us\b|you\b|it\b|(?:the|that|this|my) (?:number|one|caller|person)\b)(.{2,60}?)\s+(?:and|to)\s+(ask|tell|find out|check|see)\s+(?:them\s+)?(.{3,300})$/i.exec(clean);
  if (!m) return null;
  let name = m[1]!.trim();
  let place = "";
  const at = /^(.+?)\s+(?:in|at)\s+([A-Z][\w' -]{2,40})$/.exec(name);
  if (at) {
    name = at[1]!.trim();
    place = at[2]!.trim();
  }
  const verb = /^tell$/i.test(m[2]!) ? "tell" : "ask";
  const rest = m[3]!.trim();
  const purpose = /^(?:find out|check|see)$/i.test(m[2]!) && !/^(?:if|whether|what|when|how|who|where|why)\b/i.test(rest) ? `whether ${rest}` : rest;
  return { name, place, verb, purpose };
}

/** "what's Mum's number", "Dominos Ashford number", "number for Ali". Null otherwise. */
export function numberAsk(text: string): string | null {
  const clean = text.replace(/\s+/g, " ").trim().replace(/[?!.]+$/, "");
  if (clean.length > 80 || /^(?:call|ring|phone|text|remind|watch|prank)\b/i.test(clean)) return null;
  if (/\b(?:my|your|jarvis'?s?) (?:own )?number\b|\bwrong number\b|\bnumber is\b|\bthe number\b/i.test(clean)) return null;
  let m = /^(?:what(?:'s| is)|whats|give me|send me|get me|find(?: me)?|i need|do you have)?\s*(?:the\s+)?(?:phone |contact |telephone )?number (?:for|of) (.{2,50})$/i.exec(clean);
  if (m) return m[1]!.trim();
  m = /^(?:what(?:'s| is)|whats|give me|send me|get me|find(?: me)?|i need|do you have)?\s*(?:the\s+)?(.{2,50}?)(?:'s|s')? (?:phone |contact |telephone |mobile )?(?:number|no\.?)$/i.exec(clean);
  if (m) return m[1]!.trim();
  return null;
}

function clipSms(text: string): string {
  const flat = text.replace(/\s+/g, " ").trim();
  if (flat.length <= 320) return flat;
  const cut = flat.slice(0, 320);
  const stop = cut.lastIndexOf(". ");
  return stop > 120 ? cut.slice(0, stop + 1) : `${cut.replace(/\s+\S*$/, "")}…`;
}

/** Contacts first (Sir's phone book), then a business search. */
export async function numberLine(env: Env, who: string): Promise<string> {
  const { resolveContact, maskPhone, optionsLine } = await import("./contacts");
  const found = await resolveContact(env, who).catch(() => ({ kind: "none" as const }));
  if (found.kind === "one") return `${found.contact.name}: ${maskPhone(found.contact.phone)}${found.contact.label ? ` (${found.contact.label})` : ""}, Sir.`;
  if (found.kind === "many") return `A few matches, Sir: ${optionsLine(found.options)}`;
  if (personalContact(who)) return `${who} isn't in the contacts I have, Sir. Open the JARVIS app and tap Sync contacts, then ask again.`;
  const at = /^(.+?)\s+(?:in|at)\s+([A-Z][\w' -]{2,40})$/.exec(who);
  const name = at ? at[1]!.trim() : who;
  const place = at ? at[2]!.trim() : "";
  const business = await findBusinessPhone(env, name, place).catch(() => null);
  if (business) return `${who}: ${maskPhone(business.phone)}${business.source ? ` (${business.source})` : ""}. Text 'ring ${who} and ask …' and I'll offer the call.`;
  return `I couldn't find a number for ${who}, Sir.`;
}

export function personalContact(name: string): boolean {
  return /\b(?:mum|mom|mam|dad|mother|father|bro|brother|sis|sister|cousin|nan|nana|gran|grandma|grandad|wife|husband|girlfriend|boyfriend|missus|mate|friend|uncle|auntie|aunt|my|his|her)\b/i.test(name);
}

const UK_PHONE = /(?:\+44\s?\(?0?\)?\s?|\(0|\b0)(?:\d[\s)-]{0,2}){9,10}(?!\d)/g;

export async function findBusinessPhone(env: Env, name: string, place: string): Promise<{ phone: string; source: string } | null> {
  const { toE164, isBlockedNumber } = await import("./calls");
  const where = place || "Ashford Kent";
  for (const query of [`${name} ${where} phone number`, `"${name}" ${where} contact telephone`]) {
    const blobs = await searchBlobs(env, query, UK_PHONE);
    for (const blob of blobs) {
      for (const m of blob.text.matchAll(UK_PHONE)) {
        const e164 = toE164(m[0].replace(/[\s()-]/g, ""));
        if (!e164 || isBlockedNumber(e164) || /^\+44(?:9|87|84|70)/.test(e164)) continue;
        return { phone: e164, source: blob.host };
      }
    }
  }
  return null;
}

// ---------------------------------------------------------------- help

export function helpAsk(text: string): boolean {
  return /^(?:help|commands|menu|\?|what can you do|what else can you do|what can jarvis do|what do you do|list commands)[\s?!.]*$/i.test(text.trim()) ||
    /\bwhat (?:else )?can you do\b|\bwhat can jarvis do\b/i.test(text);
}

export function helpTexts(): string[] {
  return [
    "Text me, Sir: remind me in 20 mins to stretch | remind me at 6 to call mum, call me | ring Dominos Ashford and ask if they deliver | nearest open pharmacy | watch PS5 and text me under £400 | my reminders | my watches",
    "Or: roast me | hype me up | diss track about my cousin's cooking | beatbox | prank 07... with a fake award (reveals it's you) | tell Project Money to find 5 leads | send a photo link | stop morning / start morning. Or just chat.",
  ];
}

// ---------------------------------------------------------------- router

/** True when the text was handled here. */
export async function smsExtras(env: Env, phone: string, text: string, media: string[], ctx: ExtrasCtx): Promise<boolean> {
  const clean = text.replace(/\s+/g, " ").trim();

  // Photos: an MMS attachment, or a picture link in the text.
  const link = media[0] ?? (clean ? imageLink(clean) : null);
  if (link) {
    const image = await fetchImage(env, link);
    if (image) {
      const question = clean.replace(/https?:\/\/\S+/gi, " ").trim();
      const seen = await describeImage(env, image, question);
      await ctx.send(seen ?? "I got the photo, Sir, but couldn't read it just now. Try again in a minute.");
      return true;
    }
    if (media.length) {
      await ctx.send("I couldn't open that photo, Sir. Try sending it again, or as a link.");
      return true;
    }
  }
  if (!clean) return false;

  if (helpAsk(clean)) {
    for (const line of helpTexts()) await ctx.send(line);
    return true;
  }

  if (/^(?:stop|pause|no more|cancel) (?:the )?morning(?: texts?| briefing| message)?s?$/i.test(clean)) {
    await setState(env, "morning:off", "1");
    await ctx.send("Morning texts paused, Sir. Text 'start morning' to bring them back.");
    return true;
  }
  if (/^(?:start|resume|turn on) (?:the )?morning(?: texts?| briefing| message)?s?$/i.test(clean)) {
    await setState(env, "morning:off", "0");
    await ctx.send("Morning texts on, Sir: weather and your day at 8am.");
    return true;
  }
  if (/^(?:morning (?:text|briefing)|preview morning|what'?s my morning)\??$/i.test(clean)) {
    await ctx.send(await morningText(env, phone));
    return true;
  }

  if (/^(?:my reminders|reminders|list reminders|what are my reminders)\??$/i.test(clean)) {
    await ctx.send(await listReminders(env, phone));
    return true;
  }
  if (/^(?:cancel|clear|delete) (?:all )?(?:my )?reminders?$/i.test(clean)) {
    await ensureExtrasTables(env);
    const n = await dbRun(env, "UPDATE sms_reminders SET status = 'cancelled' WHERE phone = ? AND status = 'pending'", [phone]);
    await ctx.send(n ? `Cancelled ${n} reminder${n === 1 ? "" : "s"}, Sir.` : "No reminders to cancel, Sir.");
    return true;
  }
  const timedCall = parseTimedCall(clean);
  if (timedCall) {
    await ctx.send(await bookTimedCall(env, phone, timedCall));
    return true;
  }
  const reminder = parseReminder(clean);
  if (reminder === "unclear") {
    await ctx.send("When should I remind you, Sir? Try 'remind me at 6 to call mum' or 'remind me in 20 mins to stretch'.");
    return true;
  }
  if (reminder) {
    await addReminder(env, phone, reminder);
    await ctx.send(`Done, Sir. I'll ${reminder.byCall ? "ring" : "text"} you at ${clockLabel(reminder.dueAt)}: ${reminder.task}.`);
    return true;
  }

  if (/^(?:my watches|watches|price watches|what am i watching)\??$/i.test(clean)) {
    await ctx.send(await listWatches(env, phone));
    return true;
  }
  const stop = /^(?:stop|cancel|end) (?:watching|tracking)\s+(.{1,60})$/i.exec(clean);
  if (stop) {
    await ctx.send(await stopWatch(env, phone, stop[1]!.replace(/[.!]+$/, "")));
    return true;
  }
  const watch = watchAsk(clean);
  if (watch) {
    await ctx.send(await addWatch(env, phone, watch));
    return true;
  }

  const agent = agentAsk(clean);
  if (agent) {
    await ctx.send(await passToAgent(env, agent, ctx.sim));
    return true;
  }

  const prank = prankAsk(clean);
  if (prank) {
    await ctx.send(await offerPrank(env, phone, prank, ctx.sim));
    return true;
  }
  if (/^prank\b/i.test(clean)) {
    await ctx.send("Send the number with it, Sir: 'prank 07... with a fake award for best kettle in Kent'. I only ring numbers you type, and it reveals it's you at the end.");
    return true;
  }

  const weather = (await import("./live-tools")).weatherAsk(clean);
  if (weather) {
    const { weatherFor } = await import("./live-tools");
    await ctx.send((await weatherFor(weather.place, weather.when)).text);
    return true;
  }

  const numberOf = numberAsk(clean);
  if (numberOf) {
    await ctx.send(await numberLine(env, numberOf));
    return true;
  }

  const live = await import("./live-tools");
  if (live.currentFactAsk(clean) && !nearbyAsk(clean)) {
    const found = await live.liveSearch(env, clean);
    if (found.ok) {
      await ctx.send(clipSms(found.answer));
      return true;
    }
    // No live answer: fall through to the chat brain, which says it is unsure.
  }

  const near = nearbyAsk(clean);
  if (near) {
    const found = await findNearby(near);
    await ctx.send(found ? nearbyLine(near, found) : "The map service didn't answer, Sir. Try again in a minute.");
    return true;
  }
  return false;
}

// ---------------------------------------------------------------- live checks

/**
 * /debug/extras (auth). Read-only actions by default. Actions that text or ring Sir run once per nonce,
 * and only ever to his own number.
 */
export async function extrasDebugRoute(request: Request, env: Env): Promise<Response> {
  const { readJson, isRecord, asString, json, apiError } = await import("./http");
  const body = await readJson(request);
  if (!body.ok) return body.response;
  if (!isRecord(body.value)) return apiError(400, "bad_request", "action is required.");
  const action = asString(body.value.action, 30) ?? "";
  const nonce = asString(body.value.nonce, 40) ?? "";
  await ensureExtrasTables(env);
  const mask = (phone: string) => phone.replace(/^(\+\d{3})\d+(\d{3})$/, "$1…$2");
  if (action === "state") {
    const reminders = await dbAll<{ id: number; phone: string; task: string; due_at: string; via: string; status: string; fired_at: string | null }>(
      env,
      "SELECT id, phone, task, due_at, via, status, fired_at FROM sms_reminders ORDER BY id DESC LIMIT 12",
    );
    const watches = await dbAll<{ id: number; phone: string; item: string; symbol: string; threshold: number; last_price: number | null; last_source: string; status: string }>(
      env,
      "SELECT id, phone, item, symbol, threshold, last_price, last_source, status FROM price_watches ORDER BY id DESC LIMIT 12",
    );
    const { elevenCredits } = await import("./voice-notes");
    return json({
      ok: true,
      reminders: reminders.map((r) => ({ ...r, phone: mask(r.phone) })),
      watches: watches.map((w) => ({ ...w, phone: mask(w.phone) })),
      agent_tasks: await agentQueue(env),
      morning_off: (await getState(env, "morning:off").catch(() => null)) ?? "",
      morning_last: (await getState(env, "morning:last").catch(() => null)) ?? "",
      rap_beat: Boolean(await getState(env, "voice:rap_beat").catch(() => null)),
      credits: await elevenCredits(env),
    });
  }
  if (action === "fire") return json({ ok: true, fired: await fireDueReminders(env) });
  if (action === "morning") {
    const { readOwnerMobile } = await import("./owner-alert");
    const owner = (await readOwnerMobile(env)) ?? "";
    return json({ ok: true, text: await morningText(env, owner), sent: false });
  }
  if (action === "quote") {
    const symbol = (asString(body.value.symbol, 8) ?? "").toUpperCase();
    const item = asString(body.value.item, 80) ?? "";
    const threshold = Number(body.value.threshold ?? 0) || 100;
    const found = await checkWatch(env, { item, symbol, threshold }).catch(() => null);
    return json({ ok: Boolean(found), found });
  }
  if (action === "search") {
    const { webSearch } = await import("./search");
    const found = await webSearch(env, asString(body.value.q, 200) ?? "");
    return json({
      ok: found.ok,
      provider: found.ok ? found.provider : "",
      error: found.ok ? "" : found.error,
      attempted: found.ok ? [] : found.attempted.map((a) => a.slice(0, 160)),
      results: found.ok ? found.results.slice(0, 6).map((r) => ({ url: r.url.slice(0, 100), text: `${r.title} ${r.snippet}`.slice(0, 220) })) : [],
    });
  }
  if (action === "find-phone") {
    const name = asString(body.value.name, 60) ?? "";
    return json({ ok: true, found: await findBusinessPhone(env, name, asString(body.value.place, 40) ?? "") });
  }
  if (!nonce || !/^[A-Za-z0-9_-]+$/.test(nonce)) return apiError(400, "bad_request", "nonce is required for this action.");
  const key = `extras_debug:${action}:${nonce}`;
  const prior = await getState(env, key).catch(() => null);
  if (prior) return json({ ok: true, already: true, ...(JSON.parse(prior) as object) });
  const { readOwnerMobile } = await import("./owner-alert");
  const owner = await readOwnerMobile(env);
  if (!owner) return apiError(409, "not_ready", "No owner mobile.");
  if (action === "call-reminder") {
    const task = (asString(body.value.task, 120) ?? "").trim() || "this is your reminder call test";
    await setState(env, key, JSON.stringify({ queued: true, at: new Date().toISOString() }));
    await addReminder(env, owner, { task, dueAt: new Date(Date.now() + 30_000), byCall: true });
    return json({ ok: true, queued: true, fires: "next minute cron" });
  }
  if (action === "book-call") {
    // A timed call to Sir from his own line, booked by the operator on his say-so. Nothing dials now.
    const at = new Date(asString(body.value.at, 40) ?? "");
    const say = (asString(body.value.say, 400) ?? "").trim();
    const confirm = (asString(body.value.confirm, 300) ?? "").trim();
    if (Number.isNaN(at.getTime()) || at.getTime() <= Date.now() + 60_000) return apiError(400, "bad_request", "at must be a future time.");
    const call = { task: say ? `${SAY_PREFIX} ${say}` : WAKE_TASK, dueAt: at, byCall: true };
    const line = await bookTimedCall(env, owner, call);
    let texted = false;
    if (confirm) {
      const { textOwnerLong } = await import("./sms-desk");
      texted = (await textOwnerLong(env, owner, confirm, "booked-call")).ok;
    }
    const saved = { booked: true, due_at: at.toISOString(), line, texted };
    await setState(env, key, JSON.stringify(saved));
    return json({ ok: true, ...saved });
  }
  if (action === "summary") {
    const text = (asString(body.value.text, 900) ?? "").trim();
    if (!text) return apiError(400, "bad_request", "text is required.");
    await setState(env, key, JSON.stringify({ pending: true, at: new Date().toISOString() }));
    const { sendSmsResult } = await import("./sms-desk");
    const result = await sendSmsResult(env, owner, text);
    const record = { sid: result.sid, status: result.status, error: result.error, chars: text.length, at: new Date().toISOString() };
    await setState(env, key, JSON.stringify(record));
    return json({ ok: result.ok, ...record });
  }
  return apiError(400, "bad_request", "unknown action.");
}
