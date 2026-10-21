import { dialConfirm, isBlockedNumber, toE164 } from "./calls";
import { dbAll, dbFirst, dbRun, getState, setState } from "./db";
import { apiError, asString, isRecord, json, newId, nowIso } from "./http";
import { londonDay, londonMinutes, readOwnerMobile } from "./owner-alert";
import { pushNotice } from "./screening";
import { webSearch } from "./search";
import { displayNumber, parsePhones, paymentAsk, sendSms } from "./sms-desk";
import type { ApprovalRow, Env } from "./types";

const JOB_CAP = 5;
const DAY_CAP = 10;
const OPEN_MINUTE = 8 * 60;
const CLOSE_MINUTE = 21 * 60;

const QUOTE_ASK =
  "Your price, when you are next free, and your terms. Master Hadi will confirm later. Do not take a booking and do not take a card or a payment.";

export interface QuoteRead {
  price: string;
  availability: string;
  fees: string;
  terms: string;
  summary: string;
  payment: boolean;
}

export interface CompetingOffer {
  business: string;
  price: string;
  availability: string;
  terms: string;
}

export interface HuntTarget {
  business: string;
  phone: string;
}

interface QuoteRow {
  id: string;
  hunt_id: string;
  call_id: string | null;
  business: string;
  phone: string;
  price: string | null;
  availability: string | null;
  fees: string | null;
  terms: string | null;
  summary: string;
  status: string;
  book_call_id: string | null;
  created_at?: string;
}

interface HuntRow {
  id: string;
  goal: string;
  status: string;
  created_at?: string;
  updated_at?: string;
}

type Gate = "open" | "quiet" | "cap" | "down" | "busy" | "placed" | "idle";

let clock: () => Date = () => new Date();
let columnsReady = false;
let tail: Promise<unknown> = Promise.resolve();

export function setHuntClock(next: () => Date): void {
  clock = next;
}

export function resetHuntClock(): void {
  clock = () => new Date();
}

function huntNow(): Date {
  return clock();
}

function exclusive<T>(work: () => Promise<T>): Promise<T> {
  const run = tail.then(work, work);
  tail = run.then(
    () => undefined,
    () => undefined,
  );
  return run;
}

/** Businesses are not rung from 21:00 until 08:00 Europe/London. */
export function businessQuiet(minutes: number): boolean {
  return minutes >= CLOSE_MINUTE || minutes < OPEN_MINUTE;
}

export function bookingAllowed(text: string): boolean {
  return !paymentAsk(text);
}

export function quoteAmount(price: string): number | null {
  const match = /(?:£\s*)?(\d+(?:\.\d{1,2})?)/.exec(price.replace(/,/g, ""));
  if (!match?.[1]) return null;
  const value = Number(match[1]);
  return Number.isFinite(value) ? value : null;
}

export function recommendQuote<T extends { id: string; status: string; price: string }>(quotes: T[]): string | null {
  const quoted = quotes.filter((quote) => quote.status === "quoted");
  if (quoted.length === 0) return null;
  let best = quoted[0];
  let bestAmount = quoteAmount(best?.price ?? "");
  for (const quote of quoted.slice(1)) {
    const amount = quoteAmount(quote.price);
    if (amount == null) continue;
    if (bestAmount == null || amount < bestAmount) {
      best = quote;
      bestAmount = amount;
    }
  }
  return best?.id ?? null;
}

export function extractQuote(text: string): QuoteRead {
  const cleaned = text
    .replace(/do not take a booking[^.?!]*/gi, " ")
    .replace(/do not take a card[^.?!]*/gi, " ")
    .replace(/do not take a payment[^.?!]*/gi, " ")
    .replace(/he will pay you directly[^.?!]*/gi, " ")
    .replace(/(?:master hadi|s?he) will confirm later[^.?!]*/gi, " ")
    .replace(/\s+/g, " ")
    .trim();
  const feeMatch = /(?:call[- ]?out|callout|fee|fees)\s*(?:is|of|:)?\s*(£\s?\d+(?:\.\d{2})?|\d+(?:\.\d{2})?\s*(?:pounds|gbp))/i.exec(cleaned);
  const fees = feeMatch?.[1]?.replace(/\s+/g, "") ?? "";
  const amounts = [...cleaned.matchAll(/£\s?\d+(?:\.\d{2})?|\d+(?:\.\d{2})?\s*(?:pounds|gbp)/gi)].map((match) =>
    (match[0] ?? "").replace(/\s+/g, ""),
  );
  const price = amounts.find((amount) => amount.replace(/\s+/g, "") !== fees.replace(/\s+/g, "")) ?? (fees ? "" : amounts[0] ?? "");
  const when =
    /(?:today|tomorrow|monday|tuesday|wednesday|thursday|friday|saturday|sunday)(?:\s+at\s+\d{1,2}(?::\d{2})?\s*(?:am|pm)?)?|(?:next|this)\s+(?:week|monday|tuesday|wednesday|thursday|friday)|(?:\d{1,2}(?::\d{2})?\s*(?:am|pm))/i.exec(
      cleaned,
    );
  const availability = when?.[0]?.trim() ?? "";
  const termsSaid = /terms(?:\s+are|\s+is|:)\s+([^.]{3,80})/i.exec(cleaned);
  const terms = (termsSaid?.[1] ?? (fees ? `call-out ${fees}` : "")).replace(/\s+/g, " ").trim();
  const payment = paymentAsk(cleaned);
  const bits = [price, availability, terms].filter(Boolean);
  const summary = payment
    ? `Payment was requested. ${bits.join(", ") || "No price was read."}`.trim()
    : bits.join(", ") || "They answered, but I could not read a price.";
  return { price, availability, fees, terms, summary: summary.slice(0, 240), payment };
}

export function quoteBrief(goal: string, offer: CompetingOffer | null): string {
  const job = clip(goal.replace(/[.?!]+$/g, ""), 80) || "this job";
  const ask = `Ask them for a quote on ${job}. ${QUOTE_ASK}`;
  const compete =
    offer?.price
      ? ` The only competing offer so far is ${clip(offer.business, 40)} at ${clip(offer.price, 24)}${
          offer.availability ? `, available ${clip(offer.availability, 40)}` : ""
        }${offer.terms ? `, terms ${clip(offer.terms, 60)}` : ""}. Do not invent any other offer.`
      : " There is no competing offer yet. Do not invent one.";
  return `${ask}${compete}`.replace(/\s+/g, " ").trim();
}

export function bookBrief(business: string, when: string): string {
  const slot = when.trim() ? ` for ${clip(when, 60)}` : "";
  const name = clip(business, 60) || "the business";
  return `I'm calling to make a booking${slot} with ${name} for Master Hadi. Please hold that slot. He will confirm and he will pay you directly. Do not take a card or a payment on this call.`;
}

export function comparisonMessage(
  goal: string,
  quotes: { business: string; price: string; availability: string; terms: string; summary: string; status: string; id: string }[],
  recommendedId: string | null,
): string {
  const lines = [`Quotes for ${clip(goal, 80) || "this job"}. Nothing is booked.`];
  for (const quote of quotes) {
    if (quote.status === "pending" || quote.status === "calling") continue;
    if (quote.status === "failed" || quote.status === "skipped") {
      lines.push(`${quote.business}: no answer.`);
      continue;
    }
    const price = quote.price || "price to confirm";
    const when = quote.availability || "time to confirm";
    const terms = quote.terms || "terms to confirm";
    const notes = quote.summary ? ` Notes: ${clip(quote.summary, 80)}.` : "";
    lines.push(`${quote.business}: ${price}. ${when}. Terms: ${terms}.${notes}`);
  }
  const chosen = quotes.find((quote) => quote.id === recommendedId);
  if (chosen) {
    lines.push(`Recommended: ${chosen.business}${chosen.price ? ` at ${chosen.price}` : ""}.`);
    lines.push("Reply APPROVE to book the recommended one, or tap Approve on your phone. I will not book until you do.");
  } else {
    lines.push("I couldn't read a quote to recommend, Sir. Nothing is booked.");
  }
  return lines.join("\n");
}

export async function startHunt(env: Env, goal: string): Promise<string> {
  const created = await createHunt(env, goal);
  return created.message;
}

export async function createHunt(
  env: Env,
  goal: string,
  supplied?: HuntTarget[],
): Promise<{ id: string; message: string }> {
  return exclusive(() => createHuntInner(env, goal, supplied));
}

export async function confirmDraftHunt(env: Env): Promise<{ message: string; dialed: boolean } | null> {
  return exclusive(async () => {
    await ensureHuntColumns(env);
    const hunt = await dbFirst<{ id: string }>(
      env,
      "SELECT id FROM call_hunts WHERE status = 'draft' ORDER BY updated_at DESC LIMIT 1",
    );
    if (!hunt) return null;
    return beginInner(env, hunt.id);
  });
}

export async function beginHunt(env: Env, huntId: string): Promise<{ message: string; dialed: boolean }> {
  return exclusive(() => beginInner(env, huntId));
}

export async function editDraftHunt(env: Env, text: string): Promise<string | null> {
  const phones = parsePhones(text, JOB_CAP);
  if (phones.length === 0) return null;
  return exclusive(async () => {
    await ensureHuntColumns(env);
    const hunt = await dbFirst<{ id: string }>(
      env,
      "SELECT id FROM call_hunts WHERE status = 'draft' ORDER BY updated_at DESC LIMIT 1",
    );
    if (!hunt) return null;
    const result = await replaceInner(env, hunt.id, targetsFromText(text));
    return result.message;
  });
}

export async function replaceProviders(env: Env, huntId: string, providers: HuntTarget[]): Promise<{ ok: boolean; status: number; message: string }> {
  return exclusive(() => replaceInner(env, huntId, providers));
}

export async function approveRecommended(env: Env): Promise<string | null> {
  return exclusive(async () => {
    await ensureHuntColumns(env);
    const hunt = await dbFirst<HuntRow>(
      env,
      "SELECT id, goal, status FROM call_hunts WHERE status = 'comparing' ORDER BY updated_at DESC LIMIT 1",
    );
    if (!hunt) return null;
    const quotes = await loadQuotes(env, hunt.id);
    const quoteId = recommendQuote(quotes.map(presentQuote));
    if (!quoteId) return "I don't have a quote to approve, Sir. Nothing is booked.";
    return (await approveInner(env, hunt.id, quoteId)).message;
  });
}

export async function listHunts(env: Env): Promise<Response> {
  try {
    await ensureHuntColumns(env);
    const hunts = await dbAll<HuntRow>(
      env,
      `SELECT id, goal, status, updated_at FROM call_hunts
       WHERE status IN ('draft', 'calling', 'queued', 'comparing', 'awaiting_approval', 'booking')
       ORDER BY updated_at DESC LIMIT 8`,
    );
    const ids = hunts.map((hunt) => hunt.id);
    const quotes = ids.length
      ? await dbAll<QuoteRow>(
          env,
          `SELECT id, hunt_id, call_id, business, phone, price, availability, fees, terms, summary, status, book_call_id, created_at
           FROM call_quotes WHERE hunt_id IN (${ids.map(() => "?").join(",")}) ORDER BY created_at ASC`,
          ids,
        )
      : [];
    const callIds = quotes.flatMap((quote) => [quote.call_id, quote.book_call_id].filter((id): id is string => Boolean(id)));
    const transcripts = new Map<string, { role: string; text: string }[]>();
    if (callIds.length > 0) {
      const calls = await dbAll<{ id: string; transcript_json: string | null }>(
        env,
        `SELECT id, transcript_json FROM outbound_calls WHERE id IN (${callIds.map(() => "?").join(",")})`,
        callIds,
      );
      for (const call of calls) transcripts.set(call.id, readTranscript(call.transcript_json));
    }
    return json({
      hunts: hunts.map((hunt) => {
        const rows = quotes.filter((quote) => quote.hunt_id === hunt.id).map(presentQuote);
        const recommended = recommendQuote(rows);
        return {
          id: hunt.id,
          goal: hunt.goal,
          status: hunt.status,
          recommended_id: recommended ?? "",
          quotes: rows.map((quote) => ({
            ...quote,
            recommended: quote.id === recommended,
            transcript: transcripts.get(quote.call_id) ?? [],
          })),
        };
      }),
    });
  } catch {
    return json({ hunts: [] });
  }
}

export async function createHuntRoute(request: Request, env: Env): Promise<Response> {
  const body = await readBody(request);
  if (!body.ok) return body.response;
  const goal = asString(body.value.goal, 300);
  if (!goal) return apiError(400, "bad_request", "goal is required.");
  const supplied = body.value.providers === undefined ? undefined : normaliseProviders(body.value.providers);
  const created = await createHunt(env, goal, supplied);
  return json({ ok: true, hunt_id: created.id || null, message: created.message, external_action_taken: false });
}

export async function replaceHuntRoute(request: Request, env: Env, huntId: string): Promise<Response> {
  const body = await readBody(request);
  if (!body.ok) return body.response;
  if (!Array.isArray(body.value.providers)) return apiError(400, "bad_request", "providers is required.");
  const result = await replaceProviders(env, huntId, normaliseProviders(body.value.providers));
  if (!result.ok) return apiError(result.status, result.status === 404 ? "not_found" : "conflict", result.message);
  return json({ ok: true, message: result.message, external_action_taken: false });
}

export async function startHuntRoute(env: Env, huntId: string): Promise<Response> {
  const started = await beginHunt(env, huntId);
  if (started.message === "That comparison is not on file, Sir.") return apiError(404, "not_found", started.message);
  return json({ ok: true, message: started.message, external_action_taken: started.dialed, paid: false });
}

export async function chooseQuoteRoute(request: Request, env: Env, huntId: string): Promise<Response> {
  const body = await readBody(request);
  if (!body.ok) return body.response;
  const quoteId = asString(body.value.quote_id, 80);
  if (!quoteId) return apiError(400, "bad_request", "quote_id is required.");
  const result = await exclusive(() => approveInner(env, huntId, quoteId));
  if (!result.ok) return apiError(result.status, result.status === 404 ? "not_found" : "conflict", result.message);
  return json({
    ok: true,
    message: result.message,
    approval_id: result.approvalId,
    external_action_taken: result.dialed,
    paid: false,
  });
}

export async function bookApproved(env: Env, approval: ApprovalRow): Promise<{ dialed: boolean; refused: boolean; held: boolean }> {
  if (approval.action !== "book_quote") return { dialed: false, refused: false, held: false };
  return exclusive(() => bookInner(env, approval));
}

export async function noteQuote(env: Env, callId: string): Promise<void> {
  await exclusive(() => noteInner(env, callId)).catch(() => undefined);
}

export async function sweepHunts(env: Env): Promise<void> {
  try {
    await exclusive(async () => {
      await ensureHuntColumns(env);
      const open = await dbAll<{ call_id: string | null; book_call_id: string | null }>(
        env,
        "SELECT call_id, book_call_id FROM call_quotes WHERE status IN ('calling', 'booking') LIMIT 20",
      );
      for (const row of open) {
        if (row.call_id) await noteInner(env, row.call_id);
        if (row.book_call_id) await noteInner(env, row.book_call_id);
      }
      await advance(env);
    });
  } catch {
    console.error("hunt sweep failed");
  }
}

async function createHuntInner(env: Env, goal: string, supplied?: HuntTarget[]): Promise<{ id: string; message: string }> {
  await ensureHuntColumns(env);
  const targets = await gatherTargets(env, goal, supplied);
  if (targets.length === 0) return { id: "", message: "Text me the numbers, Sir, and I will call them. I will not invent one." };
  const now = nowIso();
  const id = newId("hunt");
  await dbRun(env, "INSERT INTO call_hunts (id, goal, status, created_at, updated_at) VALUES (?, ?, 'draft', ?, ?)", [
    id,
    clip(goal, 300),
    now,
    now,
  ]);
  for (const target of targets) await insertQuote(env, id, target, now);
  return { id, message: draftMessage(targets) };
}

async function beginInner(env: Env, huntId: string): Promise<{ message: string; dialed: boolean }> {
  await ensureHuntColumns(env);
  const hunt = await dbFirst<HuntRow>(env, "SELECT id, goal, status FROM call_hunts WHERE id = ?", [huntId]);
  if (!hunt) return { message: "That comparison is not on file, Sir.", dialed: false };
  if (hunt.status === "calling" || hunt.status === "queued" || hunt.status === "booking") {
    return { message: "Those calls are already going, Sir. One at a time. Nothing is booked.", dialed: false };
  }
  if (hunt.status !== "draft") return { message: "That list is closed, Sir.", dialed: false };
  const pending = await dbAll<{ id: string }>(env, "SELECT id FROM call_quotes WHERE hunt_id = ? AND status = 'pending'", [huntId]);
  if (pending.length === 0) return { message: "Text me the numbers, Sir, and I will call them. I will not invent one.", dialed: false };
  if (!callingConfigured(env)) return { message: "Calling isn't set up, Sir. Nothing was booked.", dialed: false };
  const gate = await currentGate(env);
  if (gate === "quiet") {
    await dbRun(env, "UPDATE call_hunts SET status = 'queued', updated_at = ? WHERE id = ?", [nowIso(), huntId]);
    return { message: "I'll call them after 08:00, Sir. Nothing is booked.", dialed: false };
  }
  if (gate === "cap") {
    await dbRun(env, "UPDATE call_hunts SET status = 'queued', updated_at = ? WHERE id = ?", [nowIso(), huntId]);
    return { message: "I've already made 10 shop calls today, Sir. I'll continue tomorrow. Nothing is booked.", dialed: false };
  }
  await dbRun(env, "UPDATE call_hunts SET status = 'calling', updated_at = ? WHERE id = ?", [nowIso(), huntId]);
  if (await inFlight(env)) {
    return { message: "One call is already on the line, Sir. I'll ring the next when it finishes. Nothing is booked.", dialed: false };
  }
  const stepped = await advance(env);
  if (stepped === "placed") return { message: "Calling the first one now, Sir. I'll ring the others one at a time. Nothing is booked.", dialed: true };
  if (stepped === "quiet") return { message: "I'll call them after 08:00, Sir. Nothing is booked.", dialed: false };
  if (stepped === "cap") return { message: "I've already made 10 shop calls today, Sir. I'll continue tomorrow. Nothing is booked.", dialed: false };
  return { message: "Calling isn't set up, Sir. Nothing was booked.", dialed: false };
}

async function replaceInner(
  env: Env,
  huntId: string,
  providers: HuntTarget[],
): Promise<{ ok: boolean; status: number; message: string }> {
  await ensureHuntColumns(env);
  const hunt = await dbFirst<HuntRow>(env, "SELECT id, goal, status FROM call_hunts WHERE id = ?", [huntId]);
  if (!hunt) return { ok: false, status: 404, message: "That comparison is not on file, Sir." };
  if (hunt.status !== "draft") return { ok: false, status: 409, message: "That list is already being called, Sir." };
  const kept = await acceptTargets(env, providers);
  await dbRun(env, "DELETE FROM call_quotes WHERE hunt_id = ? AND status = 'pending'", [huntId]);
  if (kept.length === 0) {
    return { ok: true, status: 200, message: "Text me the numbers, Sir, and I will call them. I will not invent one." };
  }
  const now = nowIso();
  for (const target of kept) await insertQuote(env, huntId, target, now);
  await dbRun(env, "UPDATE call_hunts SET updated_at = ? WHERE id = ?", [now, huntId]);
  return { ok: true, status: 200, message: draftMessage(kept) };
}

async function approveInner(
  env: Env,
  huntId: string,
  quoteId: string,
): Promise<{ ok: boolean; status: number; message: string; dialed: boolean; approvalId: string }> {
  await ensureHuntColumns(env);
  const quote = await dbFirst<QuoteRow>(
    env,
    "SELECT id, hunt_id, call_id, business, phone, price, availability, fees, terms, summary, status, book_call_id FROM call_quotes WHERE id = ? AND hunt_id = ?",
    [quoteId, huntId],
  );
  if (!quote) return { ok: false, status: 404, message: "That quote is not on this comparison.", dialed: false, approvalId: "" };
  const hunt = await dbFirst<HuntRow>(env, "SELECT id, goal, status FROM call_hunts WHERE id = ?", [huntId]);
  if (!hunt || hunt.status === "cancelled" || hunt.status === "booked") {
    return { ok: false, status: 409, message: "That comparison is closed.", dialed: false, approvalId: "" };
  }
  if (hunt.status === "booking" || quote.status === "booking" || quote.status === "booked") {
    return { ok: false, status: 409, message: "A booking call is already in hand, Sir. Nothing is paid.", dialed: false, approvalId: "" };
  }
  if (quote.status !== "quoted") {
    return { ok: false, status: 409, message: "That one does not have a quote yet, Sir.", dialed: false, approvalId: "" };
  }
  const pay = !bookingAllowed(`${hunt.goal} ${quote.summary} ${quote.price ?? ""} ${quote.fees ?? ""} ${quote.terms ?? ""}`);
  const now = nowIso();
  const approvalId = newId("apr");
  const summary = pay
    ? `Payment was asked for ${quote.business}. Nothing will be paid or booked.`
    : `Book ${quote.business}${quote.price ? ` at ${quote.price}` : ""}${quote.availability ? `, ${quote.availability}` : ""}. A confirmation call only. Nothing is paid.`;
  if (pay) {
    await insertApproval(env, approvalId, "rejected", "explicit_authorisation", summary, huntId, quoteId, quote.business, now);
    return {
      ok: true,
      status: 200,
      message: `They asked for payment at ${quote.business}, Sir. I will not book that and I have not paid.`,
      dialed: false,
      approvalId,
    };
  }
  await insertApproval(env, approvalId, "approved", "approval_required", summary, huntId, quoteId, quote.business, now);
  const approval = await dbFirst<ApprovalRow>(env, "SELECT * FROM approvals WHERE id = ?", [approvalId]);
  if (!approval) return { ok: false, status: 500, message: "The approval could not be stored, Sir.", dialed: false, approvalId };
  const booked = await bookInner(env, approval);
  if (booked.refused) {
    return { ok: true, status: 200, message: "They asked for payment, Sir. I will not book that and I have not paid.", dialed: false, approvalId };
  }
  if (booked.held) {
    return {
      ok: true,
      status: 200,
      message: "I'll ring them to book when businesses can be called, Sir. Nothing is paid.",
      dialed: false,
      approvalId,
    };
  }
  if (!booked.dialed) {
    return { ok: true, status: 200, message: "Calling isn't set up, Sir. Nothing was booked.", dialed: false, approvalId };
  }
  return {
    ok: true,
    status: 200,
    message: `I'm ringing ${quote.business} to book, Sir. I'll confirm when they answer. Nothing is paid.`,
    dialed: true,
    approvalId,
  };
}

async function bookInner(env: Env, approval: ApprovalRow): Promise<{ dialed: boolean; refused: boolean; held: boolean }> {
  await ensureHuntColumns(env);
  const payload = readPayload(approval.payload_json);
  const huntId = typeof payload.hunt_id === "string" ? payload.hunt_id : "";
  const quoteId = typeof payload.quote_id === "string" ? payload.quote_id : "";
  const quote = quoteId
    ? await dbFirst<QuoteRow>(
        env,
        "SELECT id, hunt_id, call_id, business, phone, price, availability, fees, terms, summary, status, book_call_id FROM call_quotes WHERE id = ?",
        [quoteId],
      )
    : null;
  const hunt = huntId ? await dbFirst<HuntRow>(env, "SELECT id, goal, status FROM call_hunts WHERE id = ?", [huntId]) : null;
  const blob = `${approval.summary} ${hunt?.goal ?? ""} ${quote?.summary ?? ""} ${quote?.price ?? ""} ${quote?.fees ?? ""} ${quote?.terms ?? ""}`;
  if (!bookingAllowed(blob)) {
    if (huntId && (hunt?.status === "awaiting_approval" || hunt?.status === "comparing")) {
      await dbRun(env, "UPDATE call_hunts SET status = 'comparing', updated_at = ? WHERE id = ?", [nowIso(), huntId]);
    }
    return { dialed: false, refused: true, held: false };
  }
  if (!quote || !toE164(quote.phone) || hunt?.status === "booked" || quote.status === "booked") {
    return { dialed: false, refused: false, held: false };
  }
  if (quote.book_call_id) return { dialed: false, refused: false, held: false };
  const now = nowIso();
  await dbRun(env, "UPDATE call_quotes SET status = 'booking' WHERE id = ?", [quote.id]);
  if (huntId) await dbRun(env, "UPDATE call_hunts SET status = 'booking', updated_at = ? WHERE id = ?", [now, huntId]);
  const gate = await currentGate(env);
  if (gate !== "open" || (await inFlight(env, quote.id))) {
    return { dialed: false, refused: false, held: true };
  }
  const placed = await placeBooking(env, quote);
  return { dialed: placed, refused: false, held: false };
}

async function noteInner(env: Env, callId: string): Promise<void> {
  await ensureHuntColumns(env);
  const quote = await dbFirst<QuoteRow>(
    env,
    "SELECT id, hunt_id, call_id, business, phone, price, availability, fees, terms, summary, status, book_call_id FROM call_quotes WHERE call_id = ? AND status = 'calling'",
    [callId],
  ).catch(() => null);
  if (quote) {
    await settleQuoteCall(env, quote, callId);
    await advance(env);
    return;
  }
  const booking = await dbFirst<QuoteRow>(
    env,
    "SELECT id, hunt_id, call_id, business, phone, price, availability, fees, terms, summary, status, book_call_id FROM call_quotes WHERE book_call_id = ? AND status = 'booking'",
    [callId],
  ).catch(() => null);
  if (!booking) return;
  await settleBookingCall(env, booking, callId);
}

async function settleQuoteCall(env: Env, quote: QuoteRow, callId: string): Promise<void> {
  const call = await loadCall(env, callId);
  if (!call || (call.status !== "completed" && call.status !== "failed")) return;
  if (call.status === "failed") {
    await dbRun(env, "UPDATE call_quotes SET status = 'failed', summary = ? WHERE id = ?", ["The call did not connect.", quote.id]);
    return;
  }
  const read = extractQuote(`${call.summary ?? ""} ${linesOf(call.transcript_json)}`);
  await dbRun(
    env,
    "UPDATE call_quotes SET status = 'quoted', price = ?, availability = ?, fees = ?, terms = ?, summary = ? WHERE id = ?",
    [read.price || null, read.availability || null, read.fees || null, read.terms || null, read.summary, quote.id],
  );
}

async function settleBookingCall(env: Env, quote: QuoteRow, callId: string): Promise<void> {
  const call = await loadCall(env, callId);
  if (!call || (call.status !== "completed" && call.status !== "failed")) return;
  const said = linesOf(call.transcript_json).replace(/\s+/g, " ").trim();
  if (call.status === "failed" || paymentAsk(said)) {
    await dbRun(env, "UPDATE call_quotes SET status = 'quoted', book_call_id = NULL WHERE id = ?", [quote.id]);
    await dbRun(env, "UPDATE call_hunts SET status = 'comparing', updated_at = ? WHERE id = ?", [nowIso(), quote.hunt_id]);
    const line =
      call.status === "failed"
        ? `I couldn't reach ${quote.business} to book, Sir. Nothing was booked.`
        : `${quote.business} asked for a payment, Sir. I did not pay and I did not confirm a booking.`;
    await notifyOwner(env, "JARVIS – Booking", line, quote.hunt_id);
    return;
  }
  const now = nowIso();
  await dbRun(env, "UPDATE call_quotes SET status = 'booked' WHERE id = ?", [quote.id]);
  await dbRun(env, "UPDATE call_hunts SET status = 'booked', updated_at = ? WHERE id = ?", [now, quote.hunt_id]);
  const detail = said ? ` They said: ${clip(said, 140)}.` : "";
  await notifyOwner(env, "JARVIS – Booked", `${quote.business} is held, Sir.${detail} Nothing was paid.`, quote.hunt_id);
}

async function advance(env: Env): Promise<Gate> {
  if (!callingConfigured(env)) return "down";
  if (await inFlight(env)) return "busy";
  const gate = await currentGate(env);
  if (gate !== "open") {
    await holdHunts(env, gate);
    return gate;
  }
  const booking = await dbFirst<QuoteRow>(
    env,
    "SELECT id, hunt_id, call_id, business, phone, price, availability, fees, terms, summary, status, book_call_id FROM call_quotes WHERE status = 'booking' AND book_call_id IS NULL ORDER BY created_at ASC LIMIT 1",
  );
  if (booking) {
    const placed = await placeBooking(env, booking);
    return placed ? "placed" : "down";
  }
  for (let step = 0; step < JOB_CAP; step++) {
    const quote = await nextPending(env);
    if (!quote) {
      await finishReady(env);
      return "idle";
    }
    const dialed = await dbAll<{ id: string }>(
      env,
      "SELECT id FROM call_quotes WHERE hunt_id = ? AND call_id IS NOT NULL",
      [quote.hunt_id],
    );
    if (dialed.length >= JOB_CAP) {
      await dbRun(env, "UPDATE call_quotes SET status = 'skipped', summary = ? WHERE hunt_id = ? AND status = 'pending'", [
        "Not called. This job is capped at 5.",
        quote.hunt_id,
      ]);
      continue;
    }
    const placed = await placeQuote(env, quote);
    return placed ? "placed" : "down";
  }
  await finishReady(env);
  return "idle";
}

async function placeQuote(env: Env, quote: QuoteRow): Promise<boolean> {
  const hunt = await dbFirst<HuntRow>(env, "SELECT id, goal, status FROM call_hunts WHERE id = ?", [quote.hunt_id]);
  if (!hunt) return false;
  const offer = await bestOffer(env, quote.hunt_id);
  const callId = await dialConfirm(env, quote.business, quote.phone, quoteBrief(hunt.goal, offer));
  if (!callId) {
    await dbRun(env, "UPDATE call_quotes SET status = 'failed', summary = ? WHERE id = ?", ["The call could not be placed.", quote.id]);
    return false;
  }
  await noteDial(env);
  await dbRun(env, "UPDATE call_quotes SET status = 'calling', call_id = ? WHERE id = ?", [callId, quote.id]);
  await dbRun(env, "UPDATE call_hunts SET status = 'calling', updated_at = ? WHERE id = ?", [nowIso(), quote.hunt_id]);
  return true;
}

async function placeBooking(env: Env, quote: QuoteRow): Promise<boolean> {
  if (!callingConfigured(env)) return false;
  const callId = await dialConfirm(env, quote.business, quote.phone, bookBrief(quote.business, quote.availability ?? ""));
  if (!callId) {
    await dbRun(env, "UPDATE call_quotes SET status = 'quoted', book_call_id = NULL WHERE id = ?", [quote.id]);
    await dbRun(env, "UPDATE call_hunts SET status = 'comparing', updated_at = ? WHERE id = ?", [nowIso(), quote.hunt_id]);
    return false;
  }
  await noteDial(env);
  await dbRun(env, "UPDATE call_quotes SET status = 'booking', book_call_id = ? WHERE id = ?", [callId, quote.id]);
  await dbRun(env, "UPDATE call_hunts SET status = 'booking', updated_at = ? WHERE id = ?", [nowIso(), quote.hunt_id]);
  return true;
}

async function finishReady(env: Env): Promise<void> {
  const hunts = await dbAll<HuntRow>(
    env,
    "SELECT id, goal, status FROM call_hunts WHERE status IN ('calling', 'queued') ORDER BY created_at ASC LIMIT 10",
  );
  for (const hunt of hunts) {
    const quotes = await loadQuotes(env, hunt.id);
    if (quotes.some((quote) => quote.status === "pending" || quote.status === "calling" || quote.status === "booking")) continue;
    await publishComparison(env, hunt, quotes);
  }
}

async function publishComparison(env: Env, hunt: HuntRow, quotes: QuoteRow[]): Promise<void> {
  const presented = quotes.map(presentQuote);
  const recommended = recommendQuote(presented);
  await dbRun(env, "UPDATE call_hunts SET status = 'comparing', updated_at = ? WHERE id = ?", [nowIso(), hunt.id]);
  const message = comparisonMessage(hunt.goal, presented, recommended);
  await notifyOwner(env, "JARVIS – Quotes", message, hunt.id);
}

async function holdHunts(env: Env, gate: "quiet" | "cap"): Promise<void> {
  const hunts = await dbAll<HuntRow>(
    env,
    "SELECT id, goal, status FROM call_hunts WHERE status = 'calling' ORDER BY created_at ASC LIMIT 10",
  );
  const line =
    gate === "quiet"
      ? "I'll call them after 08:00, Sir. Nothing is booked."
      : "I've already made 10 shop calls today, Sir. I'll continue tomorrow. Nothing is booked.";
  for (const hunt of hunts) {
    const pending = await dbFirst<{ id: string }>(
      env,
      "SELECT id FROM call_quotes WHERE hunt_id = ? AND status = 'pending' LIMIT 1",
      [hunt.id],
    );
    if (!pending) continue;
    await dbRun(env, "UPDATE call_hunts SET status = 'queued', updated_at = ? WHERE id = ?", [nowIso(), hunt.id]);
    await notifyOwner(env, "JARVIS – Quotes", line, hunt.id);
  }
}

async function nextPending(env: Env): Promise<QuoteRow | null> {
  const hunts = await dbAll<HuntRow>(
    env,
    "SELECT id, goal, status, created_at FROM call_hunts WHERE status IN ('calling', 'queued') ORDER BY created_at ASC LIMIT 10",
  );
  for (const hunt of hunts) {
    const quote = await dbFirst<QuoteRow>(
      env,
      "SELECT id, hunt_id, call_id, business, phone, price, availability, fees, terms, summary, status, book_call_id FROM call_quotes WHERE hunt_id = ? AND status = 'pending' ORDER BY created_at ASC LIMIT 1",
      [hunt.id],
    );
    if (quote) return quote;
  }
  return null;
}

async function bestOffer(env: Env, huntId: string): Promise<CompetingOffer | null> {
  const quotes = await loadQuotes(env, huntId);
  const quoted = quotes.filter((quote) => quote.status === "quoted" && quote.price);
  const id = recommendQuote(quoted.map(presentQuote));
  const chosen = quoted.find((quote) => quote.id === id);
  if (!chosen?.price) return null;
  return {
    business: chosen.business,
    price: chosen.price,
    availability: chosen.availability ?? "",
    terms: chosen.terms || (chosen.fees ? `call-out ${chosen.fees}` : ""),
  };
}

async function currentGate(env: Env): Promise<"open" | "quiet" | "cap"> {
  const now = huntNow();
  if (businessQuiet(londonMinutes(now))) return "quiet";
  const count = await dialsToday(env, londonDay(now));
  if (count >= DAY_CAP) return "cap";
  return "open";
}

async function inFlight(env: Env, exceptQuoteId = ""): Promise<boolean> {
  const live = await dbFirst<{ id: string }>(
    env,
    "SELECT id FROM call_quotes WHERE status = 'calling' AND call_id IS NOT NULL LIMIT 1",
  );
  if (live && live.id !== exceptQuoteId) return true;
  const booking = await dbFirst<{ id: string }>(
    env,
    "SELECT id FROM call_quotes WHERE status = 'booking' AND book_call_id IS NOT NULL LIMIT 1",
  );
  return Boolean(booking && booking.id !== exceptQuoteId);
}

async function dialsToday(env: Env, day: string): Promise<number> {
  const raw = await getState(env, `hunt_dials_${day}`).catch(() => null);
  const count = Number(raw ?? "0");
  return Number.isFinite(count) ? count : 0;
}

async function noteDial(env: Env): Promise<void> {
  const day = londonDay(huntNow());
  const count = await dialsToday(env, day);
  await setState(env, `hunt_dials_${day}`, String(count + 1));
}

async function gatherTargets(env: Env, goal: string, supplied?: HuntTarget[]): Promise<HuntTarget[]> {
  const fromText = targetsFromText(goal);
  if (fromText.length > 0) return acceptTargets(env, fromText);
  const seeded = supplied ? await acceptTargets(env, supplied) : [];
  if (seeded.length >= JOB_CAP) return seeded.slice(0, JOB_CAP);
  const found = await phonesFromSearch(env, goal);
  return acceptTargets(env, [...seeded, ...found]);
}

async function acceptTargets(env: Env, targets: HuntTarget[]): Promise<HuntTarget[]> {
  const owner = await readOwnerMobile(env);
  const ours = toE164(env.TWILIO_FROM_NUMBER ?? "");
  const kept: HuntTarget[] = [];
  for (const target of targets) {
    const phone = toE164(target.phone);
    if (!phone || isBlockedNumber(phone) || phone === owner || phone === ours) continue;
    if (kept.some((item) => item.phone === phone)) continue;
    kept.push({ business: clip(target.business, 60) || `Business ${kept.length + 1}`, phone });
    if (kept.length >= JOB_CAP) break;
  }
  return kept;
}

async function phonesFromSearch(env: Env, goal: string): Promise<HuntTarget[]> {
  const found = await webSearch(env, clip(goal, 180));
  if (!found.ok) return [];
  const targets: HuntTarget[] = [];
  for (const hit of found.results) {
    const phones = parsePhones(`${hit.title} ${hit.snippet}`, 2);
    const business = clip(hit.title.split(/[|–—-]/)[0] ?? "Business", 60) || "Business";
    for (const phone of phones) targets.push({ business, phone });
  }
  return targets;
}

const NAME_STOPS = new Set([
  "call",
  "ring",
  "phone",
  "get",
  "me",
  "quotes",
  "quote",
  "for",
  "a",
  "an",
  "the",
  "and",
  "or",
  "on",
  "at",
  "please",
  "shop",
  "around",
  "find",
  "from",
  "text",
  "these",
  "those",
  "numbers",
  "number",
  "want",
  "instead",
  "use",
  "my",
]);

export function targetsFromText(text: string): HuntTarget[] {
  const pattern =
    /\+\d{8,15}|\+\d{1,3}(?:[\s.-]\d{2,4}){2,3}|\b0\d{4}[\s.-]\d{6}\b|\b0\d{3}[\s.-]\d{3}[\s.-]\d{4}\b|\b0\d{2}[\s.-]\d{4}[\s.-]\d{4}\b|\b0\d{9,10}\b/g;
  const targets: HuntTarget[] = [];
  for (const match of text.matchAll(pattern)) {
    const phone = toE164(match[0] ?? "");
    if (!phone || isBlockedNumber(phone) || targets.some((item) => item.phone === phone)) continue;
    const business = businessBefore(text, match.index ?? 0) || `Business ${targets.length + 1}`;
    targets.push({ business, phone });
    if (targets.length >= JOB_CAP) break;
  }
  return targets;
}

function businessBefore(text: string, index: number): string {
  const words = text
    .slice(Math.max(0, index - 48), index)
    .split(/[^A-Za-z']+/)
    .filter(Boolean);
  const kept: string[] = [];
  for (let cursor = words.length - 1; cursor >= 0; cursor--) {
    const word = words[cursor] ?? "";
    if (NAME_STOPS.has(word.toLowerCase())) break;
    kept.unshift(word);
    if (kept.length >= 4) break;
  }
  return kept.join(" ").trim();
}

function draftMessage(targets: HuntTarget[]): string {
  const lines = targets.map((target, index) => `${index + 1}. ${target.business}, ${displayNumber(target.phone)}`);
  return [
    "I can call these for quotes, Sir. Nothing is booked.",
    ...lines,
    "Reply YES to start, or text the numbers you want instead. I call one at a time.",
  ].join("\n");
}

async function insertQuote(env: Env, huntId: string, target: HuntTarget, now: string): Promise<void> {
  await dbRun(
    env,
    `INSERT INTO call_quotes
      (id, hunt_id, call_id, business, phone, price, availability, fees, terms, summary, status, book_call_id, created_at)
     VALUES (?, ?, NULL, ?, ?, NULL, NULL, NULL, NULL, '', 'pending', NULL, ?)`,
    [newId("quote"), huntId, target.business, target.phone, now],
  );
}

async function insertApproval(
  env: Env,
  id: string,
  status: string,
  level: string,
  summary: string,
  huntId: string,
  quoteId: string,
  business: string,
  now: string,
): Promise<void> {
  await dbRun(
    env,
    `INSERT INTO approvals
      (id, task_id, subtask_id, action, level, summary, payload_json, status, reason, created_at, decided_at)
     VALUES (?, NULL, NULL, 'book_quote', ?, ?, ?, ?, ?, ?, ?)`,
    [
      id,
      level,
      summary,
      JSON.stringify({ hunt_id: huntId, quote_id: quoteId, business }).slice(0, 4000),
      status,
      status === "rejected" ? "payment" : null,
      now,
      status === "pending" ? null : now,
    ],
  );
}

async function loadQuotes(env: Env, huntId: string): Promise<QuoteRow[]> {
  return dbAll<QuoteRow>(
    env,
    "SELECT id, hunt_id, call_id, business, phone, price, availability, fees, terms, summary, status, book_call_id, created_at FROM call_quotes WHERE hunt_id = ? ORDER BY created_at ASC",
    [huntId],
  );
}

function presentQuote(quote: QuoteRow): {
  id: string;
  call_id: string;
  business: string;
  phone: string;
  price: string;
  availability: string;
  fees: string;
  terms: string;
  summary: string;
  status: string;
} {
  const fees = quote.fees ?? "";
  return {
    id: quote.id,
    call_id: quote.call_id ?? "",
    business: quote.business,
    phone: quote.phone,
    price: quote.price ?? "",
    availability: quote.availability ?? "",
    fees,
    terms: quote.terms || (fees ? `call-out ${fees}` : ""),
    summary: quote.summary,
    status: quote.status,
  };
}

async function loadCall(
  env: Env,
  callId: string,
): Promise<{ status: string; summary: string | null; transcript_json: string | null } | null> {
  return dbFirst(env, "SELECT status, summary, transcript_json FROM outbound_calls WHERE id = ?", [callId]);
}

async function notifyOwner(env: Env, title: string, message: string, huntId: string): Promise<void> {
  const owner = await readOwnerMobile(env);
  if (owner) {
    for (const part of comparisonParts(message)) {
      await sendSms(env, owner, part).catch(() => false);
    }
  }
  const push = message.split("\n").find((line) => line.startsWith("Recommended:")) ?? clip(message.replace(/\n/g, " "), 180);
  await pushNotice(env, title, clip(push, 180), { hunt_id: huntId }).catch(() => false);
}

export function comparisonParts(text: string): string[] {
  const lines = text
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);
  const tail = lines.filter(
    (line) => line.startsWith("Recommended:") || line.startsWith("Reply APPROVE") || line.startsWith("I couldn't read"),
  );
  const body = lines.filter((line) => !tail.includes(line));
  const parts = packLines(body, 3);
  const ending = tail.join("\n").slice(0, 280);
  if (ending) parts.push(ending);
  return parts.slice(0, 4);
}

export async function deliverHuntText(env: Env, phone: string, text: string): Promise<void> {
  for (const part of comparisonParts(text)) {
    await sendSms(env, phone, part).catch(() => false);
  }
}

function packLines(lines: string[], maxParts: number): string[] {
  const parts: string[] = [];
  let current = "";
  for (const line of lines) {
    const next = current ? `${current}\n${line}` : line;
    if (next.length > 280 && current) {
      parts.push(current);
      current = line.slice(0, 280);
    } else {
      current = next.slice(0, 280);
    }
    if (parts.length >= maxParts) break;
  }
  if (current && parts.length < maxParts) parts.push(current);
  return parts;
}

function callingConfigured(env: Env): boolean {
  return Boolean(toE164(env.TWILIO_FROM_NUMBER ?? "") && (env.TWILIO_ACCOUNT_SID ?? "").trim() && (env.TWILIO_AUTH_TOKEN ?? "").trim());
}

async function ensureHuntColumns(env: Env): Promise<void> {
  if (columnsReady) return;
  const terms = await addColumn(env, "terms TEXT");
  const booking = await addColumn(env, "book_call_id TEXT");
  if (terms && booking) columnsReady = true;
}

async function addColumn(env: Env, spec: string): Promise<boolean> {
  try {
    await env.DB.prepare(`ALTER TABLE call_quotes ADD COLUMN ${spec}`).run();
    return true;
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return /duplicate column|already exists/i.test(message);
  }
}

function linesOf(raw: string | null): string {
  if (!raw) return "";
  try {
    const parsed = JSON.parse(raw) as unknown;
    if (!Array.isArray(parsed)) return "";
    return parsed
      .map((item) => {
        if (!item || typeof item !== "object" || !("text" in item) || typeof item.text !== "string") return "";
        const role = "role" in item ? item.role : "";
        if (role === "assistant") return "";
        return item.text;
      })
      .filter(Boolean)
      .join(" ");
  } catch {
    return "";
  }
}

function readTranscript(raw: string | null): { role: string; text: string }[] {
  if (!raw) return [];
  try {
    const parsed = JSON.parse(raw) as unknown;
    if (!Array.isArray(parsed)) return [];
    const lines: { role: string; text: string }[] = [];
    for (const item of parsed) {
      if (!item || typeof item !== "object" || !("text" in item) || typeof item.text !== "string") continue;
      const role = "role" in item && typeof item.role === "string" ? item.role : "them";
      lines.push({ role, text: item.text.slice(0, 240) });
      if (lines.length >= 40) break;
    }
    return lines;
  } catch {
    return [];
  }
}

function readPayload(raw: string | null): Record<string, unknown> {
  if (!raw) return {};
  try {
    const parsed = JSON.parse(raw) as unknown;
    return isRecord(parsed) ? parsed : {};
  } catch {
    return {};
  }
}

function normaliseProviders(value: unknown): HuntTarget[] {
  if (!Array.isArray(value)) return [];
  const targets: HuntTarget[] = [];
  for (const item of value) {
    if (!isRecord(item)) continue;
    const phone = asString(item.phone, 40);
    const business = asString(item.business, 60) || `Business ${targets.length + 1}`;
    if (!phone) continue;
    targets.push({ business, phone });
  }
  return targets;
}

async function readBody(request: Request): Promise<{ ok: true; value: Record<string, unknown> } | { ok: false; response: Response }> {
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return { ok: false, response: apiError(400, "bad_request", "Request body must be JSON.") };
  }
  if (!isRecord(body)) return { ok: false, response: apiError(400, "bad_request", "JSON body must be an object.") };
  return { ok: true, value: body };
}

function clip(value: string, max: number): string {
  const trimmed = value.trim();
  if (trimmed.length <= max) return trimmed;
  return trimmed.slice(0, max).trim();
}
