import { dialConfirm, toE164 } from "./calls";
import { dbAll, dbFirst, dbRun } from "./db";
import { apiError, asString, isRecord, json, newId, nowIso } from "./http";
import { readOwnerMobile } from "./owner-alert";
import { webSearch } from "./search";
import { parsePhones, paymentAsk, sendSms } from "./sms-desk";
import type { ApprovalRow, Env } from "./types";

const QUOTE_BRIEF =
  "Please tell me your price, when you are next free, and any call-out fee. Do not take a booking and do not take a card.";

const BOOK_BRIEF =
  "Please hold a slot for Master Hadi. He will pay you directly. Do not take a card or a payment on this call.";

export interface QuoteRead {
  price: string;
  availability: string;
  fees: string;
  summary: string;
  payment: boolean;
}

export function bookingAllowed(text: string): boolean {
  return !paymentAsk(text);
}

export function extractQuote(text: string): QuoteRead {
  const cleaned = text
    .replace(/do not take a card or a payment on this call/gi, " ")
    .replace(/do not take a booking and do not take a card/gi, " ")
    .replace(/he will pay you directly/gi, " ")
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
  const payment = paymentAsk(cleaned);
  const bits = [price, availability, fees ? `call-out ${fees}` : ""].filter(Boolean);
  const summary = payment
    ? `Payment was requested. ${bits.join(", ") || "No price was read."}`.trim()
    : bits.join(", ") || "They answered, but I could not read a price.";
  return { price, availability, fees, summary: summary.slice(0, 240), payment };
}

export async function startHunt(env: Env, goal: string): Promise<string> {
  const targets = await findTargets(env, goal);
  if (targets.length === 0) return "Text me the numbers, Sir, and I will call them. I will not invent one.";
  const now = nowIso();
  const id = newId("hunt");
  await dbRun(env, "INSERT INTO call_hunts (id, goal, status, created_at, updated_at) VALUES (?, ?, 'calling', ?, ?)", [
    id,
    clip(goal, 300),
    now,
    now,
  ]);
  const placed = await Promise.all(
    targets.map(async (target) => {
      const callId = await dialConfirm(env, target.business, target.phone, QUOTE_BRIEF);
      await dbRun(
        env,
        `INSERT INTO call_quotes
          (id, hunt_id, call_id, business, phone, price, availability, fees, summary, status, created_at)
         VALUES (?, ?, ?, ?, ?, NULL, NULL, NULL, '', ?, ?)`,
        [newId("quote"), id, callId, target.business, target.phone, callId ? "calling" : "failed", now],
      );
      return Boolean(callId);
    }),
  );
  const called = placed.filter(Boolean).length;
  if (called === 0) {
    await dbRun(env, "UPDATE call_hunts SET status = 'cancelled', updated_at = ? WHERE id = ?", [nowIso(), id]);
    return "Calling isn't set up, Sir. Nothing was booked.";
  }
  return `Calling ${called} now, Sir. I'll put the comparison on your phone. Nothing is booked.`;
}

export async function listHunts(env: Env): Promise<Response> {
  const hunts = await dbAll<{ id: string; goal: string; status: string; updated_at: string }>(
    env,
    `SELECT id, goal, status, updated_at FROM call_hunts
     WHERE status IN ('calling', 'comparing', 'awaiting_approval')
     ORDER BY updated_at DESC LIMIT 5`,
  );
  const ids = hunts.map((hunt) => hunt.id);
  const quotes = ids.length
    ? await dbAll<QuoteRow>(
        env,
        `SELECT id, hunt_id, business, phone, price, availability, fees, summary, status
         FROM call_quotes WHERE hunt_id IN (${ids.map(() => "?").join(",")}) ORDER BY created_at ASC`,
        ids,
      )
    : [];
  return json({
    hunts: hunts.map((hunt) => ({
      id: hunt.id,
      goal: hunt.goal,
      status: hunt.status,
      quotes: quotes
        .filter((quote) => quote.hunt_id === hunt.id)
        .map((quote) => ({
          id: quote.id,
          business: quote.business,
          phone: quote.phone,
          price: quote.price ?? "",
          availability: quote.availability ?? "",
          fees: quote.fees ?? "",
          summary: quote.summary,
          status: quote.status,
        })),
    })),
  });
}

export async function chooseQuoteRoute(request: Request, env: Env, huntId: string): Promise<Response> {
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return apiError(400, "bad_request", "Request body must be JSON.");
  }
  if (!isRecord(body)) return apiError(400, "bad_request", "JSON body must be an object.");
  const quoteId = asString(body.quote_id, 80);
  if (!quoteId) return apiError(400, "bad_request", "quote_id is required.");
  const quote = await dbFirst<QuoteRow>(
    env,
    "SELECT id, hunt_id, business, phone, price, availability, fees, summary, status FROM call_quotes WHERE id = ? AND hunt_id = ?",
    [quoteId, huntId],
  );
  if (!quote) return apiError(404, "not_found", "That quote is not on this comparison.");
  const hunt = await dbFirst<{ goal: string; status: string }>(env, "SELECT goal, status FROM call_hunts WHERE id = ?", [huntId]);
  if (!hunt || hunt.status === "cancelled" || hunt.status === "booked") {
    return apiError(409, "conflict", "That comparison is closed.");
  }
  const pay = !bookingAllowed(`${hunt.goal} ${quote.summary} ${quote.price ?? ""} ${quote.fees ?? ""}`);
  const summary = pay
    ? `Payment was asked for ${quote.business}. Nothing will be paid or booked.`
    : `Book ${quote.business}${quote.price ? ` at ${quote.price}` : ""}${quote.availability ? `, ${quote.availability}` : ""}. A confirmation call only. Nothing is paid.`;
  const now = nowIso();
  const approvalId = newId("apr");
  await dbRun(
    env,
    `INSERT INTO approvals
      (id, task_id, subtask_id, action, level, summary, payload_json, status, reason, created_at, decided_at)
     VALUES (?, NULL, NULL, 'book_quote', ?, ?, ?, 'pending', NULL, ?, NULL)`,
    [
      approvalId,
      pay ? "explicit_authorisation" : "approval_required",
      summary,
      JSON.stringify({ hunt_id: huntId, quote_id: quoteId, business: quote.business }).slice(0, 4000),
      now,
    ],
  );
  await dbRun(env, "UPDATE call_hunts SET status = 'awaiting_approval', updated_at = ? WHERE id = ?", [now, huntId]);
  return json({ ok: true, approval_id: approvalId, external_action_taken: false, paid: false });
}

export async function bookApproved(env: Env, approval: ApprovalRow): Promise<{ dialed: boolean; refused: boolean }> {
  if (approval.action !== "book_quote") return { dialed: false, refused: false };
  const payload = readPayload(approval.payload_json);
  const huntId = typeof payload.hunt_id === "string" ? payload.hunt_id : "";
  const quoteId = typeof payload.quote_id === "string" ? payload.quote_id : "";
  const quote = quoteId
    ? await dbFirst<QuoteRow>(
        env,
        "SELECT id, hunt_id, business, phone, price, availability, fees, summary, status FROM call_quotes WHERE id = ?",
        [quoteId],
      )
    : null;
  const hunt = huntId ? await dbFirst<{ goal: string; status: string }>(env, "SELECT goal, status FROM call_hunts WHERE id = ?", [huntId]) : null;
  const blob = `${approval.summary} ${hunt?.goal ?? ""} ${quote?.summary ?? ""} ${quote?.price ?? ""} ${quote?.fees ?? ""}`;
  if (!bookingAllowed(blob)) {
    if (huntId && hunt?.status === "awaiting_approval") {
      await dbRun(env, "UPDATE call_hunts SET status = 'comparing', updated_at = ? WHERE id = ?", [nowIso(), huntId]);
    }
    return { dialed: false, refused: true };
  }
  if (!quote || !toE164(quote.phone) || hunt?.status === "booked") return { dialed: false, refused: false };
  const callId = await dialConfirm(env, quote.business, quote.phone, BOOK_BRIEF);
  if (!callId) {
    if (huntId) await dbRun(env, "UPDATE call_hunts SET status = 'comparing', updated_at = ? WHERE id = ?", [nowIso(), huntId]);
    return { dialed: false, refused: false };
  }
  const now = nowIso();
  await dbRun(env, "UPDATE call_quotes SET status = 'booked' WHERE id = ?", [quote.id]);
  if (huntId) await dbRun(env, "UPDATE call_hunts SET status = 'booked', updated_at = ? WHERE id = ?", [now, huntId]);
  return { dialed: true, refused: false };
}

export async function noteQuote(env: Env, callId: string): Promise<void> {
  const quote = await dbFirst<{ id: string; hunt_id: string }>(
    env,
    "SELECT id, hunt_id FROM call_quotes WHERE call_id = ? AND status = 'calling'",
    [callId],
  );
  if (!quote) return;
  const call = await dbFirst<{ status: string; summary: string | null; transcript_json: string | null }>(
    env,
    "SELECT status, summary, transcript_json FROM outbound_calls WHERE id = ?",
    [callId],
  );
  if (!call || (call.status !== "completed" && call.status !== "failed")) return;
  if (call.status === "failed") {
    await dbRun(env, "UPDATE call_quotes SET status = 'failed', summary = ? WHERE id = ?", ["The call did not connect.", quote.id]);
  } else {
    const read = extractQuote(`${call.summary ?? ""} ${linesOf(call.transcript_json)}`);
    await dbRun(
      env,
      "UPDATE call_quotes SET status = 'quoted', price = ?, availability = ?, fees = ?, summary = ? WHERE id = ?",
      [read.price || null, read.availability || null, read.fees || null, read.summary, quote.id],
    );
  }
  await refreshHunt(env, quote.hunt_id);
}

export async function sweepHunts(env: Env): Promise<void> {
  try {
    const open = await dbAll<{ call_id: string }>(
      env,
      "SELECT call_id FROM call_quotes WHERE status = 'calling' AND call_id IS NOT NULL LIMIT 20",
    );
    for (const row of open) {
      if (row.call_id) await noteQuote(env, row.call_id);
    }
  } catch {
    console.error("hunt sweep failed");
  }
}

async function refreshHunt(env: Env, huntId: string): Promise<void> {
  const quotes = await dbAll<{ status: string }>(env, "SELECT status FROM call_quotes WHERE hunt_id = ?", [huntId]);
  if (quotes.length === 0 || quotes.some((quote) => quote.status === "calling")) return;
  const hunt = await dbFirst<{ status: string }>(env, "SELECT status FROM call_hunts WHERE id = ?", [huntId]);
  if (!hunt || hunt.status !== "calling") return;
  await dbRun(env, "UPDATE call_hunts SET status = 'comparing', updated_at = ? WHERE id = ?", [nowIso(), huntId]);
  const owner = await readOwnerMobile(env);
  if (owner) await sendSms(env, owner, "The quotes are ready, Sir. They're on your phone. Nothing is booked.");
}

async function findTargets(env: Env, goal: string): Promise<{ business: string; phone: string }[]> {
  const direct = parsePhones(goal, 5).map((phone, index) => ({ business: `Business ${index + 1}`, phone }));
  const seeded = direct.length > 0 ? direct : await phonesFromSearch(env, goal);
  const owner = await readOwnerMobile(env);
  const ours = toE164(env.TWILIO_FROM_NUMBER ?? "");
  const kept: { business: string; phone: string }[] = [];
  for (const target of seeded) {
    if (target.phone === owner || target.phone === ours) continue;
    if (kept.some((item) => item.phone === target.phone)) continue;
    kept.push(target);
    if (kept.length >= 5) break;
  }
  return kept;
}

async function phonesFromSearch(env: Env, goal: string): Promise<{ business: string; phone: string }[]> {
  const found = await webSearch(env, clip(goal, 180));
  if (!found.ok) return [];
  const targets: { business: string; phone: string }[] = [];
  for (const hit of found.results) {
    const phones = parsePhones(`${hit.title} ${hit.snippet}`, 2);
    const business = clip(hit.title.split(/[|–—-]/)[0] ?? "Business", 60) || "Business";
    for (const phone of phones) targets.push({ business, phone });
  }
  return targets;
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

function readPayload(raw: string | null): Record<string, unknown> {
  if (!raw) return {};
  try {
    const parsed = JSON.parse(raw) as unknown;
    return isRecord(parsed) ? parsed : {};
  } catch {
    return {};
  }
}

function clip(value: string, max: number): string {
  const trimmed = value.trim();
  if (trimmed.length <= max) return trimmed;
  return trimmed.slice(0, max).trim();
}

interface QuoteRow {
  id: string;
  hunt_id: string;
  business: string;
  phone: string;
  price: string | null;
  availability: string | null;
  fees: string | null;
  summary: string;
  status: string;
}
