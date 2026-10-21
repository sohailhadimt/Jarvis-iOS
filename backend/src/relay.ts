import { dbAll, dbFirst, dbRun } from "./db";
import { apiError, asString, isRecord, json, newId, nowIso } from "./http";
import type { CallLine } from "./calls";
import { pushNotice } from "./screening";
import type { Env } from "./types";
import { clampTimeout, readCallSettings } from "./owner-alert";

/** Spoken on the later call. The owner already approved it by tapping Call back. */
export function callbackBrief(question: string): string {
  const asked = question
    .replace(/\+\d{8,15}/g, "")
    .replace(/…/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 180);
  if (!asked) return "I'm calling you back, as promised.";
  const sentence = /[.!?]$/.test(asked) ? asked : `${asked}.`;
  return `I'm calling you back, as promised. You said: ${sentence}`;
}

/** A caller was told he would be rung back, and that call has not been replaced. */
export async function openCallback(env: Env, callId: string): Promise<string | null> {
  try {
    const row = await dbFirst<{ question: string }>(
      env,
      "SELECT question FROM call_questions WHERE call_id = ? AND status = 'timed_out' ORDER BY resolved_at DESC LIMIT 1",
      [callId],
    );
    const question = row?.question?.trim() ?? "";
    return question || null;
  } catch {
    return null;
  }
}

export function questionFromTranscript(lines: CallLine[]): string | null {
  const last = lines[lines.length - 1];
  if (!last || last.role !== "assistant") return null;
  if (!last.text.toLowerCase().includes("one moment please")) return null;
  const asked = [...lines].reverse().find((line) => line.role === "them" && line.text.trim());
  return asked?.text.trim() || "They asked something outside the brief.";
}

export async function noteQuestion(env: Env, call: { id: string; transcript: CallLine[] }, origin: string): Promise<void> {
  const question = questionFromTranscript(call.transcript);
  if (!question) return;
  try {
    const existing = await dbFirst<{ id: string }>(
      env,
      "SELECT id FROM call_questions WHERE call_id = ? AND status = 'pending' LIMIT 1",
      [call.id],
    );
    if (existing) return;
    const settings = await readCallSettings(env);
    const timeout = clampTimeout(settings.question_timeout_seconds);
    const asked = nowIso();
    const expires = new Date(Date.now() + timeout * 1000).toISOString();
    const id = newId("q");
    await dbRun(
      env,
      `INSERT INTO call_questions
        (id, call_id, question, status, answer, timeout_seconds, asked_at, expires_at, resolved_at, origin, notified, follow_up_id)
       VALUES (?, ?, ?, 'pending', '', ?, ?, ?, NULL, ?, 1, NULL)`,
      [id, call.id, question.slice(0, 500), timeout, asked, expires, origin],
    );
    await pushNotice(env, "They asked", question.slice(0, 180), { call_id: call.id, question_id: id }, "JARVIS_QUESTION");
  } catch (err) {
    console.error("question relay was not stored", err instanceof Error ? err.message : "question");
  }
}

export async function sweepQuestions(env: Env): Promise<void> {
  let due: { id: string; call_id: string; question: string; origin: string }[] = [];
  try {
    due = await dbAll(
      env,
      "SELECT id, call_id, question, origin FROM call_questions WHERE status = 'pending' AND expires_at <= ? LIMIT 10",
      [nowIso()],
    );
  } catch {
    return;
  }
  for (const row of due) {
    const now = nowIso();
    const changes = await dbRun(
      env,
      "UPDATE call_questions SET status = 'timed_out', resolved_at = ? WHERE id = ? AND status = 'pending'",
      [now, row.id],
    );
    if (changes === 0) continue;
    const call = await dbFirst<{ twilio_sid: string | null }>(env, "SELECT twilio_sid FROM outbound_calls WHERE id = ?", [row.call_id]);
    if (call?.twilio_sid && row.origin) {
      await redirectCall(env, call.twilio_sid, `${row.origin}/calls/voice/${row.call_id}?mode=callback`);
    }
    const followId = newId("task");
    await dbRun(
      env,
      `INSERT INTO tasks
        (id, goal, status, schedule, scheduled_job_id, error, result_summary, plan_attempts, planner_note, locked_until, created_at, updated_at, completed_at)
       VALUES (?, ?, 'awaiting_approval', NULL, NULL, NULL, ?, 0, 'follow_up', NULL, ?, ?, NULL)`,
      [
        followId,
        `Call them back about: ${row.question.slice(0, 240)}`,
        "JARVIS said Master Hadi will get back to them.",
        now,
        now,
      ],
    ).catch(() => undefined);
    await dbRun(env, "UPDATE call_questions SET follow_up_id = ? WHERE id = ?", [followId, row.id]).catch(() => undefined);
    await pushNotice(
      env,
      "Call them back",
      row.question.slice(0, 180),
      { call_id: row.call_id, question_id: row.id },
      "JARVIS_QUESTION",
    );
  }
}

export async function routeRelay(request: Request, env: Env, path: string): Promise<Response | null> {
  if (request.method === "GET" && path === "/calls/questions") return listQuestions(env);
  const parts = path.split("/").filter(Boolean);
  if (request.method === "POST" && parts[0] === "calls" && parts[1] && parts[2] === "answer" && parts.length === 3) {
    return answerQuestion(request, env, parts[1]);
  }
  return null;
}

async function listQuestions(env: Env): Promise<Response> {
  await sweepQuestions(env);
  const since = new Date(Date.now() - 60 * 60 * 1000).toISOString();
  try {
    const rows = await dbAll(
      env,
      `SELECT id, call_id, question, status, answer, expires_at, asked_at
       FROM call_questions
       WHERE status = 'pending' OR (status = 'timed_out' AND resolved_at >= ?)
       ORDER BY asked_at DESC LIMIT 10`,
      [since],
    );
    return json({ questions: rows });
  } catch {
    return json({ questions: [] });
  }
}

async function answerQuestion(request: Request, env: Env, callId: string): Promise<Response> {
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return apiError(400, "bad_request", "Request body must be JSON.");
  }
  if (!isRecord(body)) return apiError(400, "bad_request", "JSON body must be an object.");
  const text = asString(body.text, 500);
  const questionId = asString(body.question_id, 80);
  if (!text || !questionId) return apiError(400, "bad_request", "question_id and text are required.");
  const row = await dbFirst<{ id: string; origin: string }>(
    env,
    "SELECT id, origin FROM call_questions WHERE id = ? AND call_id = ? AND status = 'pending'",
    [questionId, callId],
  );
  if (!row) return apiError(404, "not_found", "That question is no longer waiting.");
  const now = nowIso();
  await dbRun(env, "UPDATE call_questions SET status = 'answered', answer = ?, resolved_at = ? WHERE id = ?", [text, now, row.id]);
  const call = await dbFirst<{ twilio_sid: string | null }>(env, "SELECT twilio_sid FROM outbound_calls WHERE id = ?", [callId]);
  const origin = row.origin || new URL(request.url).origin;
  if (call?.twilio_sid) {
    const moved = await redirectCall(env, call.twilio_sid, `${origin}/calls/voice/${callId}?mode=relay`);
    if (!moved) return apiError(502, "twilio", "The answer was saved, but the live call could not be updated.");
  }
  return json({ ok: true });
}

async function redirectCall(env: Env, callSid: string, url: string): Promise<boolean> {
  const account = (env.TWILIO_ACCOUNT_SID ?? "").trim();
  const token = (env.TWILIO_AUTH_TOKEN ?? "").trim();
  if (!account || !token) return false;
  try {
    const form = new URLSearchParams({ Url: url, Method: "POST" });
    const response = await fetch(
      `https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(account)}/Calls/${encodeURIComponent(callSid)}.json`,
      {
        method: "POST",
        redirect: "error",
        signal: AbortSignal.timeout(20_000),
        headers: {
          authorization: `Basic ${btoa(`${account}:${token}`)}`,
          "content-type": "application/x-www-form-urlencoded",
        },
        body: form.toString(),
      },
    );
    return response.ok;
  } catch {
    return false;
  }
}
