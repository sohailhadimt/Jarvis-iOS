import { FALLBACK_SAY_VOICE, INBOUND_GREETING } from "./calls";
import { INTERCEPTOR_GREETING } from "./interceptor";
import { dbFirst, dbRun } from "./db";
import { nowIso } from "./http";
import { completeChat, type ChatMessage } from "./llm";
import { readPollyTurn } from "./outbound-speech";
import type { Env } from "./types";

/** Caller turns before JARVIS says goodbye. The opening greeting is not one of these. */
export const INBOUND_TURN_LIMIT = 12;

const FAST = { timeoutMs: 1700, maxTokens: 80, budgetMs: 1800 };

interface Turn {
  role: "assistant" | "them";
  text: string;
}

export function converseAction(request: Request, id: string): string {
  const url = new URL(request.url);
  url.protocol = "https:";
  url.pathname = `/calls/converse/${id}`;
  url.search = "";
  return url.toString();
}

/** Say sits inside Gather so the caller can barge in. */
export function converseTwiml(line: string, action: string): string {
  const say = `<Say language="en-GB" voice="${FALLBACK_SAY_VOICE}">${escapeXml(line)}</Say>`;
  return `<?xml version="1.0" encoding="UTF-8"?><Response><Gather input="speech" language="en-GB" speechTimeout="auto" timeout="5" actionOnEmptyResult="true" action="${escapeXml(action)}" method="POST">${say}</Gather><Say language="en-GB" voice="${FALLBACK_SAY_VOICE}">I'll pass that to Master Hadi. Goodbye.</Say><Hangup/></Response>`;
}

export function inboundOpening(): string {
  return INBOUND_GREETING;
}

export function callerSaidGoodbye(speech: string): boolean {
  return /\b(good\s*bye|bye|cheerio|that(?:'s| is) all|hang up|stop there)\b/i.test(speech);
}

/**
 * One spoken turn. Gemini answers, Groq if Gemini misses the budget.
 * Goodbye or the twelfth caller turn ends the call, stores the summary, and texts the owner once.
 */
export async function continueInboundConversation(env: Env, callId: string, speech: string, action: string): Promise<string> {
  if (!/^call_[A-Za-z0-9]+$/.test(callId)) return hangup("I'm sorry, this call is not set up. Goodbye.");
  const row = await dbFirst<{
    status: string;
    summary: string | null;
    transcript_json: string;
  }>(env, "SELECT status, summary, transcript_json FROM outbound_calls WHERE id = ?", [callId]).catch(() => null);
  if (!row) return hangup("I'm sorry, this call is not set up. Goodbye.");
  if (row.status === "completed") return hangup("Goodbye.");
  const lines = readTurns(row.transcript_json);
  const heard = speech.replace(/\s+/g, " ").trim().slice(0, 500);
  if (!heard) {
    const theirs = lines.some((line) => line.role === "them");
    if (!theirs) {
      const again = lines.some((line) => line.text.includes(INTERCEPTOR_GREETING))
        ? "I'm still here. May I take a message?"
        : "I'm still here. Who's calling, and how can I help?";
      return converseTwiml(again, action);
    }
    return finish(env, callId, lines, "They went quiet.");
  }
  lines.push({ role: "them", text: heard });
  const turn = lines.filter((line) => line.role === "them").length;
  if (callerSaidGoodbye(heard) || turn >= INBOUND_TURN_LIMIT) {
    return finish(env, callId, lines, "");
  }
  const reply = await nextLine(env, lines);
  lines.push({ role: "assistant", text: reply.say });
  if (reply.done) return finish(env, callId, lines, reply.summary);
  await store(env, callId, lines, "in_progress", "");
  return converseTwiml(reply.say, action);
}

async function finish(env: Env, callId: string, lines: Turn[], summary: string): Promise<string> {
  const text = summary || (await summarise(env, lines));
  lines.push({ role: "assistant", text: "I'll pass that to Master Hadi. Goodbye." });
  await store(env, callId, lines, "completed", text);
  const { rememberInboundMessage } = await import("./call-messages");
  const owned = await rememberInboundMessage(env, callId).catch(() => false);
  if (!owned) {
    const { readOwnerMobile } = await import("./owner-alert");
    const { sendSms } = await import("./sms-desk");
    const to = await readOwnerMobile(env);
    if (to) await sendSms(env, to, text);
  }
  return hangup("I'll pass that to Master Hadi. Goodbye.");
}

async function nextLine(env: Env, lines: Turn[]): Promise<{ say: string; done: boolean; summary: string }> {
  const messages: ChatMessage[] = [
    { role: "system", content: persona(lines) },
    ...lines.slice(-12).map((line) => ({
      role: line.role === "them" ? ("user" as const) : ("assistant" as const),
      content: line.text,
    })),
  ];
  const result = await completeChat(env, messages, null, FAST);
  if (!result.ok) {
    return { say: "Do go on. I'll make sure Master Hadi hears it.", done: false, summary: "" };
  }
  return readPollyTurn(result.message.content ?? "");
}

async function summarise(env: Env, lines: Turn[]): Promise<string> {
  const heard = lines
    .filter((line) => line.role === "them")
    .map((line) => line.text)
    .join(" ")
    .replace(/\s+/g, " ")
    .trim();
  if (!heard) return "A caller rang and left no message.";
  const result = await completeChat(
    env,
    [
      {
        role: "system",
        content:
          "Summarise this phone call for Master Hadi in one British sentence. Include the message they left. Do not invent facts. Do not include phone numbers.",
      },
      { role: "user", content: clip(heard, 800) },
    ],
    null,
    FAST,
  );
  if (result.ok && result.message.content) {
    const line = result.message.content.replace(/\s+/g, " ").trim();
    const parsed = readPollyTurn(line);
    const summary = parsed.summary || (/^\{/.test(line) ? "" : line);
    if (summary) return clip(summary, 400);
  }
  return clip(heard, 180);
}

function persona(lines: Turn[]): string {
  const opening = lines.find((line) => line.role === "assistant")?.text ?? "";
  if (opening.includes(INTERCEPTOR_GREETING)) {
    return [
      "You are JARVIS, Sohail Hadi's personal assistant, on a forwarded call.",
      "You already asked to take a message. Collect their name and the message.",
      "Keep every reply to one or two short spoken sentences. British English. No lists.",
      "Never claim to be Sohail Hadi. Do not invent his schedule, location, health, or other personal details.",
      "If they say goodbye, or the message is complete, set done to true, say a polite goodbye, and put one sentence in summary.",
      'Reply with JSON only: {"say":"...","done":false,"summary":""}',
    ].join("\n");
  }
  return [
    "You are JARVIS, a warm, witty British butler and Master Hadi's personal assistant, on a live telephone call.",
    "You are happy to chat and to tell a short joke if they ask.",
    "Learn who is calling and take a message for Master Hadi.",
    "Keep every reply to one or two short spoken sentences. British English. No lists.",
    "Never claim to be Master Hadi. Do not invent his schedule, location, health, or other personal details. If they ask, say you will pass that to him.",
    "If they say goodbye, or the message is complete, set done to true, say a polite goodbye, and put one sentence for Master Hadi in summary.",
    'Reply with JSON only: {"say":"...","done":false,"summary":""}',
  ].join("\n");
}

async function store(env: Env, id: string, lines: Turn[], status: string, summary: string): Promise<void> {
  await dbRun(
    env,
    `UPDATE outbound_calls
     SET transcript_json = ?, status = ?, summary = CASE WHEN ? != '' THEN ? ELSE summary END, updated_at = ?
     WHERE id = ?`,
    [JSON.stringify(lines.slice(-80)), status, summary, summary, nowIso(), id],
  ).catch(() => undefined);
}

function readTurns(raw: string | null): Turn[] {
  try {
    const parsed = JSON.parse(raw || "[]") as unknown;
    if (!Array.isArray(parsed)) return [];
    const lines: Turn[] = [];
    for (const item of parsed) {
      if (!item || typeof item !== "object") continue;
      const record = item as { role?: unknown; text?: unknown };
      const text = typeof record.text === "string" ? record.text.trim() : "";
      if (!text) continue;
      lines.push({ role: record.role === "them" ? "them" : "assistant", text: text.slice(0, 2000) });
    }
    return lines;
  } catch {
    return [];
  }
}

function hangup(line: string): string {
  return `<?xml version="1.0" encoding="UTF-8"?><Response><Say language="en-GB" voice="${FALLBACK_SAY_VOICE}">${escapeXml(line)}</Say><Hangup/></Response>`;
}

function escapeXml(value: string): string {
  return value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;");
}

function clip(value: string, max: number): string {
  const text = value.replace(/\s+/g, " ").trim();
  if (text.length <= max) return text;
  return `${text.slice(0, max - 1).trimEnd()}…`;
}
