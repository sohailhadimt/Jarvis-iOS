import { dbAll, dbFirst, dbRun } from "./db";
import { apiError, asString, isRecord, json, newId, nowIso, readJson } from "./http";
import type { Env } from "./types";

const CONVERSATION = /^[A-Za-z0-9_-]{1,80}$/;

interface AgentRow {
  id: string;
  conversation_id: string;
  role: string;
  text: string;
  status: string;
  reply_to: string | null;
  created_at: string;
}

/**
 * The app posts a typed message. The worker stores it, forwards it to the assistant
 * webhook, and returns before that webhook finishes.
 */
export async function agentChat(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const body = await readJson(request);
  if (!body.ok) return body.response;
  if (!isRecord(body.value)) return apiError(400, "bad_request", "Request body must be a JSON object.");
  const message = asString(body.value.message, 4_000);
  const conversationId = asString(body.value.conversationId, 80);
  if (!message) return apiError(400, "bad_request", "message is required.");
  if (!conversationId || !CONVERSATION.test(conversationId)) {
    return apiError(400, "bad_request", "conversationId is required.");
  }
  if (!webhookReady(env)) {
    return apiError(503, "webhook_not_configured", "The assistant webhook is not set on the worker.");
  }
  const id = newId("msg");
  const now = nowIso();
  try {
    await dbRun(
      env,
      `INSERT INTO agent_messages (id, conversation_id, role, text, status, reply_to, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
      [id, conversationId, "user", message, "pending", null, now],
    );
  } catch (err) {
    console.error("agent message was not stored", err instanceof Error ? err.name : "insert");
    return apiError(503, "agent_log_unavailable", "The assistant table is not ready. Apply schema.sql on D1, then try again.");
  }
  ctx.waitUntil(forwardAgentTask(env, { task: message, conversationId, replyTo: id }));
  return json({ messageId: id, status: "pending" });
}

/** The assistant posts its reply. The matching user message is marked done. */
export async function agentReply(request: Request, env: Env): Promise<Response> {
  const body = await readJson(request);
  if (!body.ok) return body.response;
  if (!isRecord(body.value)) return apiError(400, "bad_request", "Request body must be a JSON object.");
  const conversationId = asString(body.value.conversationId, 80);
  const replyTo = asString(body.value.replyTo, 80);
  const text = asString(body.value.text, 8_000);
  if (!conversationId || !CONVERSATION.test(conversationId)) {
    return apiError(400, "bad_request", "conversationId is required.");
  }
  if (!replyTo || !/^msg_[A-Za-z0-9]+$/.test(replyTo)) {
    return apiError(400, "bad_request", "replyTo is required.");
  }
  if (!text) return apiError(400, "bad_request", "text is required.");
  let pending: { id: string } | null = null;
  try {
    pending = await dbFirst<{ id: string }>(
      env,
      "SELECT id FROM agent_messages WHERE conversation_id = ? AND id = ? AND role = 'user'",
      [conversationId, replyTo],
    );
  } catch {
    return apiError(503, "agent_log_unavailable", "The assistant table is not ready. Apply schema.sql on D1, then try again.");
  }
  if (!pending) return apiError(404, "not_found", "That message is not in this conversation.");
  const existing = await dbFirst<{ id: string }>(
    env,
    "SELECT id FROM agent_messages WHERE conversation_id = ? AND role = 'assistant' AND reply_to = ? LIMIT 1",
    [conversationId, replyTo],
  ).catch(() => null);
  if (existing) {
    await markDone(env, replyTo, conversationId);
    return json({ ok: true, messageId: existing.id, replyTo, status: "done" });
  }
  const id = newId("msg");
  try {
    await dbRun(
      env,
      `INSERT INTO agent_messages (id, conversation_id, role, text, status, reply_to, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
      [id, conversationId, "assistant", text, "done", replyTo, nowIso()],
    );
  } catch {
    return apiError(503, "agent_log_unavailable", "The assistant reply could not be stored.");
  }
  await markDone(env, replyTo, conversationId);
  return json({ ok: true, messageId: id, replyTo, status: "done" });
}

/** Messages newer than a timestamp or a message id, for the app to poll. */
export async function agentMessages(env: Env, url: URL): Promise<Response> {
  const conversationId = (url.searchParams.get("conversationId") ?? "").trim();
  if (!CONVERSATION.test(conversationId)) return apiError(400, "bad_request", "conversationId is required.");
  const since = (url.searchParams.get("since") ?? "").trim();
  try {
    const rows = await rowsSince(env, conversationId, since);
    if (rows === null) return apiError(400, "bad_request", "since must be a message id or a timestamp.");
    return json({ messages: rows.map(present) });
  } catch {
    return apiError(503, "agent_log_unavailable", "The assistant table is not ready. Apply schema.sql on D1, then try again.");
  }
}

function webhookReady(env: Env): boolean {
  const url = (env.JARVIS_WEBHOOK_URL ?? "").trim();
  const key = (env.JARVIS_WEBHOOK_KEY ?? "").trim();
  return url.startsWith("https://") && key.length > 0;
}

async function forwardAgentTask(
  env: Env,
  input: { task: string; conversationId: string; replyTo: string },
): Promise<void> {
  const url = (env.JARVIS_WEBHOOK_URL ?? "").trim();
  const key = (env.JARVIS_WEBHOOK_KEY ?? "").trim();
  if (!url.startsWith("https://") || !key) {
    console.error("agent webhook skipped", "not_configured");
    return;
  }
  try {
    const response = await fetch(url, {
      method: "POST",
      redirect: "manual",
      signal: AbortSignal.timeout(8_000),
      headers: {
        authorization: key,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        task: input.task,
        conversationId: input.conversationId,
        replyTo: input.replyTo,
      }),
    });
    await response.text().catch(() => "");
    if (response.status < 200 || response.status >= 300) {
      console.error("agent webhook failed", String(response.status));
    }
  } catch (err) {
    console.error("agent webhook threw", err instanceof Error ? err.name : "Error");
  }
}

async function markDone(env: Env, id: string, conversationId: string): Promise<void> {
  await dbRun(
    env,
    "UPDATE agent_messages SET status = 'done' WHERE id = ? AND conversation_id = ? AND role = 'user'",
    [id, conversationId],
  ).catch(() => undefined);
}

async function rowsSince(env: Env, conversationId: string, since: string): Promise<AgentRow[] | null> {
  if (!since) {
    const latest = await dbAll<AgentRow>(
      env,
      `SELECT id, conversation_id, role, text, status, reply_to, created_at
       FROM agent_messages WHERE conversation_id = ? ORDER BY created_at DESC, id DESC LIMIT 40`,
      [conversationId],
    );
    return latest.reverse();
  }
  if (/^msg_[A-Za-z0-9]+$/.test(since)) {
    const anchor = await dbFirst<AgentRow>(
      env,
      `SELECT id, conversation_id, role, text, status, reply_to, created_at
       FROM agent_messages WHERE conversation_id = ? AND id = ?`,
      [conversationId, since],
    );
    if (!anchor) return [];
    return dbAll<AgentRow>(
      env,
      `SELECT id, conversation_id, role, text, status, reply_to, created_at
       FROM agent_messages
       WHERE conversation_id = ? AND id != ? AND created_at >= ?
       ORDER BY created_at ASC, id ASC LIMIT 40`,
      [conversationId, anchor.id, anchor.created_at],
    );
  }
  if (!/^\d{4}-\d{2}-\d{2}T/.test(since) || Number.isNaN(Date.parse(since))) return null;
  return dbAll<AgentRow>(
    env,
    `SELECT id, conversation_id, role, text, status, reply_to, created_at
     FROM agent_messages
     WHERE conversation_id = ? AND created_at > ?
     ORDER BY created_at ASC, id ASC LIMIT 40`,
    [conversationId, since],
  );
}

function present(row: AgentRow) {
  return {
    id: row.id,
    conversationId: row.conversation_id,
    role: row.role,
    text: row.text,
    status: row.status,
    replyTo: row.reply_to,
    createdAt: row.created_at,
  };
}
