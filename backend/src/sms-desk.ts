import { isBlockedNumber, safeError, toE164 } from "./calls";
import { dbAll, dbFirst, dbRun } from "./db";
import { isRecord, json, newId, nowIso, apiError, asString } from "./http";
import { CHAT_FALLBACK, completeChat, type ChatMessage } from "./llm";
import { spokenAnswer } from "./live-answer";
import { inQuietHours, londonDay, londonMinutes, readCallSettings, readOwnerMobile } from "./owner-alert";
import { webSearch } from "./search";
import { parseToolArgs, toolsForNames } from "./tools";
import type { Env } from "./types";

export interface LearnedFact {
  kind: "birthday" | "like" | "preference";
  subject: string;
  detail: string;
  whenMd: string | null;
}

export interface BusyWindow {
  startsAt: string;
  endsAt: string;
}

export interface ProposedSlot {
  startsAt: string;
  endsAt: string;
  label: string;
}

const MONTHS: Record<string, string> = {
  january: "01",
  jan: "01",
  february: "02",
  feb: "02",
  march: "03",
  mar: "03",
  april: "04",
  apr: "04",
  may: "05",
  june: "06",
  jun: "06",
  july: "07",
  jul: "07",
  august: "08",
  aug: "08",
  september: "09",
  sep: "09",
  sept: "09",
  october: "10",
  oct: "10",
  november: "11",
  nov: "11",
  december: "12",
  dec: "12",
};

const PAYMENT = /\b(pay|payment|invoice|charge|purchase|checkout|buy|card|mint)\b/i;

export function paymentAsk(text: string): boolean {
  return PAYMENT.test(text);
}

export function screenStranger(): string {
  return "Hello, this is JARVIS, Master Hadi's assistant. I'll pass that to him.";
}

export function wantsHunt(text: string): boolean {
  const folded = text.toLowerCase();
  if (/\b(call around|ring around|get quotes|compare quotes|find me a)\b/.test(folded)) return true;
  return /\b(find|call|ring|get)\b.{0,48}\b(plumber|electrician|dentist|restaurant|garage|locksmith|cleaner|builder|doctor|hotel|taxi|quote|quotes)\b/.test(
    folded,
  );
}

export function wantsSchedule(text: string): boolean {
  return /\b(schedule|propose (?:a |some )?times?|find a time|draft (?:an |the )?emails?|set up a meeting|book a meeting)\b/i.test(text);
}

export function learnFacts(text: string): LearnedFact[] {
  const facts: LearnedFact[] = [];
  const birthday = readBirthday(text);
  if (birthday) facts.push(birthday);
  for (const sentence of text.split(/[.!\n]/)) {
    const preference = readPreference(sentence);
    if (preference) facts.push(preference);
    else {
      const like = readLike(sentence);
      if (like) facts.push(like);
    }
    if (facts.length >= 4) break;
  }
  return facts;
}

export function birthdayNudge(input: {
  subject: string;
  whenMd: string;
  now: Date;
  quiet: boolean;
  nudgedFor: string | null;
}): { text: string; occurrence: string } | null {
  if (input.quiet) return null;
  const when = /^(\d{2})-(\d{2})$/.exec(input.whenMd);
  if (!when) return null;
  const today = londonDay(input.now);
  const year = Number(today.slice(0, 4));
  let occurrence = `${year}-${input.whenMd}`;
  if (occurrence < today) occurrence = `${year + 1}-${input.whenMd}`;
  const ahead = daySpan(today, occurrence);
  if (ahead < 0 || ahead > 6) return null;
  if (input.nudgedFor === occurrence) return null;
  const whenLabel = ahead === 0 ? "today" : ahead === 1 ? "tomorrow" : weekdayName(occurrence);
  return { text: birthdayLine(input.subject, whenLabel), occurrence };
}

export function birthdayLine(subject: string, whenLabel: string): string {
  if (/^(mum|mom|mother)$/i.test(subject.trim())) {
    return `Your mum's birthday is ${whenLabel}, Sir. Shall I find something?`;
  }
  const name = titleCase(subject.trim() || "someone");
  return `${name}'s birthday is ${whenLabel}, Sir. Shall I find something?`;
}

export function parsePhones(text: string, max = 5): string[] {
  const pattern =
    /\+\d{8,15}|\+\d{1,3}(?:[\s.-]\d{2,4}){2,3}|\b0\d{4}[\s.-]\d{6}\b|\b0\d{3}[\s.-]\d{3}[\s.-]\d{4}\b|\b0\d{2}[\s.-]\d{4}[\s.-]\d{4}\b|\b0\d{9,10}\b/g;
  const found: string[] = [];
  for (const match of text.matchAll(pattern)) {
    const phone = toE164(match[0] ?? "");
    if (!phone || isBlockedNumber(phone) || found.includes(phone)) continue;
    found.push(phone);
    if (found.length >= max) break;
  }
  return found;
}

export function proposeSlots(now: Date, busy: BusyWindow[], limit = 3): ProposedSlot[] {
  const slots: ProposedSlot[] = [];
  const today = londonDay(now);
  for (let offset = 0; offset < 14 && slots.length < limit; offset++) {
    const ymd = addDays(today, offset);
    const midday = atLondon(ymd, 12, 0);
    const day = new Intl.DateTimeFormat("en-US", { timeZone: "Europe/London", weekday: "short" }).format(midday);
    if (day === "Sat" || day === "Sun") continue;
    for (const hour of [9, 11, 14, 16]) {
      if (slots.length >= limit) break;
      const start = atLondon(ymd, hour, 0);
      const end = new Date(start.getTime() + 30 * 60 * 1000);
      if (start.getTime() <= now.getTime()) continue;
      if (overlaps(start, end, busy)) continue;
      slots.push({ startsAt: start.toISOString(), endsAt: end.toISOString(), label: slotLabel(start) });
    }
  }
  return slots;
}

export function scheduleEmail(goal: string, slots: { label: string }[]): { subject: string; body: string } {
  const times = slots.map((slot) => `- ${slot.label}`).join("\n");
  const subject = "A time that suits";
  const body = [
    "Hello,",
    "",
    "Master Hadi asked me to find a time. Would one of these suit?",
    "",
    times || "- A time you prefer",
    "",
    clip(goal, 400),
    "",
    "Kind regards,",
    "JARVIS",
  ].join("\n");
  return { subject, body };
}

export async function handleInboundSms(env: Env, from: string, body: string): Promise<void> {
  const text = body.replace(/\s+/g, " ").trim();
  if (!text) return;
  const sender = toE164(from);
  const ours = toE164(env.TWILIO_FROM_NUMBER ?? "");
  if (!sender || (ours && sender === ours)) return;
  try {
    const owner = await readOwnerMobile(env);
    if (owner && sender === owner) {
      await answerOwner(env, sender, text);
      return;
    }
    await sendSms(env, sender, screenStranger());
    if (owner) await sendSms(env, owner, `Text from ${sender}: ${clip(text, 240)}`);
  } catch (err) {
    const detail = safeError(err instanceof Error ? err.message : "sms").replace(/\+\d{8,15}/g, "[redacted]");
    console.error("sms desk failed", detail);
  }
}

export async function sweepMemoryNudges(env: Env): Promise<void> {
  try {
    const settings = await readCallSettings(env);
    const now = new Date();
    const quiet = inQuietHours(londonMinutes(now), settings.quiet_start, settings.quiet_end);
    const rows = await dbAll<{ id: string; subject: string; when_md: string | null; nudged_for: string | null }>(
      env,
      "SELECT id, subject, when_md, nudged_for FROM owner_facts WHERE kind = 'birthday' AND when_md IS NOT NULL",
    );
    const owner = await readOwnerMobile(env);
    if (!owner) return;
    for (const row of rows) {
      const nudge = birthdayNudge({
        subject: row.subject,
        whenMd: row.when_md ?? "",
        now,
        quiet,
        nudgedFor: row.nudged_for,
      });
      if (!nudge) continue;
      const sent = await sendSms(env, owner, nudge.text);
      if (!sent) continue;
      await dbRun(env, "UPDATE owner_facts SET nudged_for = ? WHERE id = ?", [nudge.occurrence, row.id]);
    }
  } catch {
    console.error("memory nudge failed");
  }
}

export async function saveBusy(request: Request, env: Env): Promise<Response> {
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return apiError(400, "bad_request", "Request body must be JSON.");
  }
  if (!isRecord(body) || !Array.isArray(body.blocks)) return apiError(400, "bad_request", "blocks must be an array.");
  if (body.blocks.length > 60) return apiError(400, "bad_request", "At most 60 busy blocks.");
  const rows: { starts: string; ends: string; title: string }[] = [];
  for (const item of body.blocks) {
    if (!isRecord(item)) return apiError(400, "bad_request", "Each block must be an object.");
    const starts = asString(item.starts_at, 40);
    const ends = asString(item.ends_at, 40);
    if (!starts || !ends || !Number.isFinite(Date.parse(starts)) || !Number.isFinite(Date.parse(ends))) {
      return apiError(400, "bad_request", "starts_at and ends_at must be dates.");
    }
    const title = typeof item.title === "string" ? item.title.trim().slice(0, 80) : "";
    rows.push({ starts, ends, title });
  }
  await dbRun(env, "DELETE FROM calendar_busy");
  const now = nowIso();
  for (const row of rows) {
    await dbRun(env, "INSERT INTO calendar_busy (id, starts_at, ends_at, title, updated_at) VALUES (?, ?, ?, ?, ?)", [
      newId("busy"),
      row.starts,
      row.ends,
      row.title,
      now,
    ]);
  }
  return json({ ok: true, blocks: rows.length });
}

export async function sendSms(env: Env, to: string, body: string): Promise<boolean> {
  const account = (env.TWILIO_ACCOUNT_SID ?? "").trim();
  const token = (env.TWILIO_AUTH_TOKEN ?? "").trim();
  const from = toE164(env.TWILIO_FROM_NUMBER ?? "");
  const dest = toE164(to);
  const message = clip(body, 320);
  if (!account || !token || !from || !dest || !message) return false;
  const form = new URLSearchParams({ From: from, To: dest, Body: message });
  try {
    const response = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(account)}/Messages.json`, {
      method: "POST",
      redirect: "error",
      signal: AbortSignal.timeout(15_000),
      headers: {
        authorization: `Basic ${btoa(`${account}:${token}`)}`,
        "content-type": "application/x-www-form-urlencoded",
      },
      body: form.toString(),
    });
    return response.ok;
  } catch {
    return false;
  }
}

async function answerOwner(env: Env, phone: string, text: string): Promise<void> {
  await rememberFacts(env, text);
  await rememberTurn(env, phone, "user", text);
  if (paymentAsk(text)) {
    await queueApproval(env, "payment", explicitSummary(text), "explicit_authorisation", { kind: "payment" });
    await reply(env, phone, "That needs your approval, Sir. I have not paid anything or minted a card.");
    return;
  }
  if (wantsHunt(text)) {
    const { startHunt } = await import("./hunt");
    const line = await startHunt(env, text);
    await reply(env, phone, line);
    return;
  }
  if (wantsSchedule(text)) {
    await reply(env, phone, await draftSchedule(env, text));
    return;
  }
  await reply(env, phone, await chatReply(env, phone));
}

async function reply(env: Env, phone: string, text: string): Promise<void> {
  const line = clip(text.replace(/https?:\/\/\S+/gi, "").replace(/\s+/g, " ").trim(), 320);
  const spoken = line || "I'm here, Sir.";
  await rememberTurn(env, phone, "assistant", spoken);
  await sendSms(env, phone, spoken);
}

async function draftSchedule(env: Env, goal: string): Promise<string> {
  const rows = await dbAll<{ starts_at: string; ends_at: string }>(env, "SELECT starts_at, ends_at FROM calendar_busy").catch(() => []);
  const slots = proposeSlots(
    new Date(),
    rows.map((row) => ({ startsAt: row.starts_at, endsAt: row.ends_at })),
    3,
  );
  if (slots.length === 0) return "I couldn't find a free time in the next fortnight, Sir.";
  const email = scheduleEmail(goal, slots);
  const now = nowIso();
  await dbRun(
    env,
    `INSERT INTO documents (id, task_id, subtask_id, kind, title, body, source_urls, created_at)
     VALUES (?, 'task_sms', NULL, 'outreach_email', ?, ?, '[]', ?)`,
    [newId("doc"), email.subject, email.body, now],
  );
  await queueApproval(env, "send_email", `Draft email: ${email.subject}. Nothing has been sent.`, "approval_required", {
    subject: email.subject,
  });
  return `I've drafted the email for your approval, Sir. Nothing has been sent. ${slots.map((slot) => slot.label).join("; ")}.`;
}

async function chatReply(env: Env, phone: string): Promise<string> {
  const facts = await dbAll<{ detail: string }>(env, "SELECT detail FROM owner_facts ORDER BY created_at DESC LIMIT 12").catch(() => []);
  const turns = await dbAll<{ role: string; body: string }>(
    env,
    "SELECT role, body FROM sms_turns WHERE phone = ? ORDER BY created_at DESC LIMIT 12",
    [phone],
  ).catch(() => []);
  const messages: ChatMessage[] = [
    {
      role: "system",
      content: [
        "You are JARVIS, Master Hadi's personal assistant, replying by SMS.",
        "British English. Call him Sir. One or two short sentences, under 280 characters.",
        "Do not include URLs. Do not invent phone numbers.",
        "Do not pay, buy, charge a card, or mint a card. Do not send email. A draft waits for his approval.",
        facts.length ? `Known facts:\n${facts.map((fact) => `- ${fact.detail}`).join("\n")}` : "No saved facts yet.",
      ].join("\n"),
    },
  ];
  for (const turn of [...turns].reverse()) {
    if (turn.role !== "user" && turn.role !== "assistant") continue;
    messages.push({ role: turn.role, content: turn.body });
  }
  const tools = toolsForNames(["web_search", "draft_document", "request_approval"]);
  const first = await completeChat(env, messages, tools);
  if (!first.ok) return CHAT_FALLBACK;
  const calls = first.message.tool_calls ?? [];
  if (calls.length === 0) return spokenAnswer(first.message.content ?? "") ?? "I've noted that, Sir.";
  messages.push(first.message);
  for (const call of calls.slice(0, 3)) {
    const result = await runSmsTool(env, call.function.name, call.function.arguments);
    messages.push({ role: "tool", content: JSON.stringify(result).slice(0, 1500), tool_call_id: call.id, name: call.function.name });
  }
  const second = await completeChat(env, messages, null);
  if (!second.ok) return "I've noted that, Sir.";
  return spokenAnswer(second.message.content ?? "") ?? "I've noted that, Sir.";
}

async function runSmsTool(env: Env, name: string, raw: string): Promise<unknown> {
  const parsed = parseToolArgs(raw);
  if (!parsed.ok) return { ok: false, error: parsed.error };
  if (name === "web_search") {
    const found = await webSearch(env, typeof parsed.value.query === "string" ? parsed.value.query : "");
    if (!found.ok) return { ok: false, error: found.error };
    const blob = found.results.map((hit) => `${hit.title} ${hit.snippet}`).join("\n");
    return {
      ok: true,
      phones: parsePhones(blob, 5),
      results: found.results.slice(0, 4).map((hit) => ({ title: hit.title, snippet: clip(hit.snippet, 180) })),
    };
  }
  if (name === "draft_document") {
    const title = clip(typeof parsed.value.title === "string" ? parsed.value.title : "Draft", 120);
    const draft = clip(typeof parsed.value.body === "string" ? parsed.value.body : "", 4000);
    if (!draft) return { ok: false, error: "body is required" };
    const now = nowIso();
    await dbRun(
      env,
      `INSERT INTO documents (id, task_id, subtask_id, kind, title, body, source_urls, created_at)
       VALUES (?, 'task_sms', NULL, 'other', ?, ?, '[]', ?)`,
      [newId("doc"), title, draft, now],
    );
    await queueApproval(env, "send_draft", `Draft saved: ${title}. Nothing has been sent.`, "approval_required", { title });
    return { ok: true, sent: false };
  }
  if (name === "request_approval") {
    const action = clip(typeof parsed.value.action === "string" ? parsed.value.action : "review", 80);
    const summary = clip(typeof parsed.value.summary === "string" ? parsed.value.summary : "", 500);
    if (!summary) return { ok: false, error: "summary is required" };
    const level = paymentAsk(`${action} ${summary}`) ? "explicit_authorisation" : "approval_required";
    await queueApproval(env, action, summary, level, {});
    return { ok: true, sent: false, paid: false };
  }
  return { ok: false, error: "That tool is not available by text." };
}

async function rememberFacts(env: Env, text: string): Promise<void> {
  for (const fact of learnFacts(text)) {
    const existing = await dbFirst<{ id: string }>(
      env,
      "SELECT id FROM owner_facts WHERE kind = ? AND lower(subject) = lower(?) AND ifnull(when_md, '') = ?",
      [fact.kind, fact.subject, fact.whenMd ?? ""],
    );
    if (existing) continue;
    const now = nowIso();
    await dbRun(
      env,
      "INSERT INTO owner_facts (id, kind, subject, detail, when_md, nudged_for, created_at) VALUES (?, ?, ?, ?, ?, NULL, ?)",
      [newId("fact"), fact.kind, fact.subject, fact.detail, fact.whenMd, now],
    );
    await dbRun(
      env,
      "INSERT INTO memory (id, key, content, tags, source_urls, created_at, updated_at) VALUES (?, ?, ?, ?, '[]', ?, ?)",
      [newId("mem"), `${fact.kind}:${fact.subject}`.slice(0, 120), fact.detail, JSON.stringify(["personal", fact.kind]), now, now],
    );
  }
}

async function rememberTurn(env: Env, phone: string, role: "user" | "assistant", body: string): Promise<void> {
  await dbRun(env, "INSERT INTO sms_turns (id, phone, role, body, created_at) VALUES (?, ?, ?, ?, ?)", [
    newId("sms"),
    phone,
    role,
    clip(body, 1000),
    nowIso(),
  ]);
}

async function queueApproval(
  env: Env,
  action: string,
  summary: string,
  level: "approval_required" | "explicit_authorisation",
  payload: Record<string, unknown>,
): Promise<void> {
  await dbRun(
    env,
    `INSERT INTO approvals
      (id, task_id, subtask_id, action, level, summary, payload_json, status, reason, created_at, decided_at)
     VALUES (?, NULL, NULL, ?, ?, ?, ?, 'pending', NULL, ?, NULL)`,
    [newId("apr"), clip(action, 80), level, clip(summary, 500), JSON.stringify(payload).slice(0, 4000), nowIso()],
  );
}

function explicitSummary(text: string): string {
  return `He asked by text: ${clip(text, 240)} Nothing has been paid.`;
}

function readBirthday(text: string): LearnedFact | null {
  const lead = "(?:my\\s+)?([a-z][a-z' -]{1,40}?)(?:'s)?\\s+birthday\\s+is(?:\\s+on)?(?:\\s+the)?\\s+";
  const dayFirst = new RegExp(`${lead}(\\d{1,2})(?:st|nd|rd|th)?(?:\\s+of)?\\s+([a-z]+)`, "i").exec(text);
  const monthFirst = new RegExp(`${lead}([a-z]+)\\s+(\\d{1,2})(?:st|nd|rd|th)?`, "i").exec(text);
  const parsed = dayFirst
    ? { subject: cleanSubject(dayFirst[1] ?? ""), day: dayFirst[2] ?? "", month: dayFirst[3] ?? "" }
    : monthFirst
      ? { subject: cleanSubject(monthFirst[1] ?? ""), day: monthFirst[3] ?? "", month: monthFirst[2] ?? "" }
      : null;
  if (!parsed) return null;
  const month = MONTHS[parsed.month.toLowerCase()];
  const day = Number(parsed.day);
  if (!month || !parsed.subject || day < 1 || day > 31) return null;
  const whenMd = `${month}-${String(day).padStart(2, "0")}`;
  const prettyMonth = parsed.month.charAt(0).toUpperCase() + parsed.month.slice(1).toLowerCase();
  return {
    kind: "birthday",
    subject: parsed.subject,
    detail: `${titleCase(parsed.subject)}'s birthday is ${day} ${prettyMonth}.`,
    whenMd,
  };
}

function readLike(sentence: string): LearnedFact | null {
  const match = /\b(?:i|we)\s+(?:really\s+)?(?:like|love|enjoy)\s+(.{2,80})/i.exec(sentence);
  if (!match?.[1]) return null;
  const detail = clip(match[1], 80);
  return { kind: "like", subject: detail.toLowerCase(), detail: `Likes ${detail}.`, whenMd: null };
}

function readPreference(sentence: string): LearnedFact | null {
  const match = /\b(?:i prefer|i'd prefer|i would prefer|please always|i always want you to|i want you to)\s+(.{2,140})/i.exec(
    sentence,
  );
  if (!match?.[1]) return null;
  const detail = clip(match[1], 140);
  return { kind: "preference", subject: detail.toLowerCase(), detail: `Preference: ${detail}.`, whenMd: null };
}

function cleanSubject(raw: string): string {
  return raw
    .replace(/^(my|the)\s+/i, "")
    .replace(/'s$/i, "")
    .trim()
    .toLowerCase();
}

function titleCase(value: string): string {
  return value
    .split(/\s+/)
    .filter(Boolean)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ");
}

function daySpan(from: string, to: string): number {
  const start = Date.parse(`${from}T00:00:00Z`);
  const end = Date.parse(`${to}T00:00:00Z`);
  if (!Number.isFinite(start) || !Number.isFinite(end)) return 99;
  return Math.round((end - start) / 86_400_000);
}

function addDays(ymd: string, days: number): string {
  const parsed = /^(\d{4})-(\d{2})-(\d{2})$/.exec(ymd);
  if (!parsed) return ymd;
  const date = new Date(Date.UTC(Number(parsed[1]), Number(parsed[2]) - 1, Number(parsed[3]) + days));
  return date.toISOString().slice(0, 10);
}

function weekdayName(ymd: string): string {
  const instant = atLondon(ymd, 12, 0);
  return new Intl.DateTimeFormat("en-GB", { timeZone: "Europe/London", weekday: "long" }).format(instant);
}

function slotLabel(start: Date): string {
  return new Intl.DateTimeFormat("en-GB", {
    timeZone: "Europe/London",
    weekday: "long",
    day: "numeric",
    month: "long",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).format(start);
}

function atLondon(ymd: string, hour: number, minute: number): Date {
  const parsed = /^(\d{4})-(\d{2})-(\d{2})$/.exec(ymd);
  if (!parsed) return new Date(ymd);
  const guess = new Date(Date.UTC(Number(parsed[1]), Number(parsed[2]) - 1, Number(parsed[3]), hour, minute));
  const offset = londonOffset(guess);
  let instant = new Date(guess.getTime() - offset);
  const again = londonOffset(instant);
  if (again !== offset) instant = new Date(guess.getTime() - again);
  return instant;
}

function londonOffset(instant: Date): number {
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Europe/London",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
  }).formatToParts(instant);
  const pick = (type: string) => Number(parts.find((part) => part.type === type)?.value ?? "0");
  let hour = pick("hour");
  if (hour === 24) hour = 0;
  const asUtc = Date.UTC(pick("year"), pick("month") - 1, pick("day"), hour, pick("minute"), pick("second"));
  return asUtc - instant.getTime();
}

function overlaps(start: Date, end: Date, busy: BusyWindow[]): boolean {
  const open = start.getTime();
  const close = end.getTime();
  return busy.some((block) => {
    const begins = Date.parse(block.startsAt);
    const finishes = Date.parse(block.endsAt);
    if (!Number.isFinite(begins) || !Number.isFinite(finishes)) return false;
    return open < finishes && close > begins;
  });
}

function clip(value: string, max: number): string {
  const trimmed = value.trim();
  if (trimmed.length <= max) return trimmed;
  return trimmed.slice(0, max).trim();
}
