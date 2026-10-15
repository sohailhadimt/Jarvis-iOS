import { authorize } from "./auth";
import { buildBriefing } from "./briefing";
import { computeNextRun, parseCron } from "./cron";
import {
  dbAll,
  dbFirst,
  dbRun,
  logActivity,
  logProgress,
  mapActivity,
  mapApproval,
  mapDocument,
  mapFinding,
  mapMemory,
  mapPipeline,
  mapProgress,
  mapSubtask,
  mapTask,
} from "./db";
import { recomputeTaskStatus, runTick } from "./execute";
import {
  apiError,
  asOptionalString,
  asString,
  clampLimit,
  emptyCors,
  isRecord,
  json,
  newId,
  nowIso,
  readJson,
} from "./http";
import { markPersonaDraft, routePersona } from "./personas";
import { optionalSourceUrls } from "./sources";
import { isPipelineStage, parseMrr } from "./tools";
import type {
  ActivityRow,
  ApprovalRow,
  DocumentRow,
  Env,
  FindingRow,
  MemoryRow,
  PipelineRow,
  ProgressRow,
  SubtaskRow,
  TaskRow,
} from "./types";
import { CRON_EXPRESSION, PIPELINE_STAGES, SERVICE, VERSION } from "./types";

const TASK_STATUSES = ["planning", "running", "awaiting_approval", "completed", "failed"] as const;

export async function route(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  if (request.method === "OPTIONS") return emptyCors();
  const url = new URL(request.url);
  const path = normalizePath(url.pathname);

  try {
    if (request.method === "GET" && path === "/health") return health(env);
    const auth = authorize(request, env.JARVIS_APP_TOKEN);
    if (!auth.ok) return auth.response;

    const parts = path.split("/").filter(Boolean);
    if (request.method === "POST" && path === "/tasks") return createTask(request, env, ctx);
    if (request.method === "GET" && path === "/tasks") return listTasks(env, url);
    if (request.method === "GET" && parts[0] === "tasks" && parts[1] && parts.length === 2) return getTask(env, parts[1]);
    if (request.method === "GET" && path === "/briefing") return json(await buildBriefing(env));
    if (request.method === "GET" && path === "/approvals") return listApprovals(env, url);
    if (request.method === "POST" && path === "/approvals") return createApproval(request, env);
    if (request.method === "POST" && parts[0] === "approvals" && parts[2] === "approve" && parts.length === 3) {
      return decideApproval(env, parts[1], "approved", request);
    }
    if (request.method === "POST" && parts[0] === "approvals" && parts[2] === "reject" && parts.length === 3) {
      return decideApproval(env, parts[1], "rejected", request);
    }
    if (request.method === "GET" && path === "/memory") return listMemory(env, url);
    if (request.method === "POST" && path === "/memory") return createMemory(request, env);
    if (request.method === "DELETE" && parts[0] === "memory" && parts[1] && parts.length === 2) {
      return deleteMemory(env, parts[1]);
    }
    if (request.method === "GET" && path === "/activity") return listActivity(env, url);
    if (request.method === "GET" && path === "/pipeline") return listPipeline(env, url);
    if (request.method === "POST" && path === "/pipeline") return writePipeline(request, env, null);
    if (request.method === "POST" && parts[0] === "pipeline" && parts[1] && parts.length === 2) {
      return writePipeline(request, env, parts[1]);
    }
    const persona = await routePersona(request, env, path, parts);
    if (persona) return persona;
    return apiError(404, "not_found", `No route for ${request.method} ${path}.`);
  } catch (err) {
    const message = err instanceof Error ? err.message : "Request failed.";
    console.error("jarvis request failed", message);
    return apiError(500, "internal", message);
  }
}

function normalizePath(pathname: string): string {
  if (pathname.length > 1 && pathname.endsWith("/")) return pathname.slice(0, -1);
  return pathname || "/";
}

async function health(env: Env): Promise<Response> {
  const body = {
    service: SERVICE,
    version: VERSION,
    time: nowIso(),
    cron: CRON_EXPRESSION,
    external_actions: false,
  };
  try {
    await dbFirst<{ ok: number }>(env, "SELECT 1 AS ok");
    return json({ ok: true, ...body, db: "ok" });
  } catch (err) {
    return json(
      { ok: false, ...body, db: "error", message: err instanceof Error ? err.message : "D1 query failed." },
      503,
    );
  }
}

async function createTask(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const body = await readJson(request);
  if (!body.ok) return body.response;
  if (!isRecord(body.value)) return apiError(400, "bad_request", "JSON body must be an object.");
  const goal = asString(body.value.goal, 8000);
  if (!goal) return apiError(400, "bad_request", "goal is required and must be a non-empty string up to 8000 characters.");
  let schedule: string | null = null;
  if (body.value.schedule !== undefined && body.value.schedule !== null) {
    if (typeof body.value.schedule !== "string" || !parseCron(body.value.schedule)) {
      return apiError(400, "bad_request", "schedule must be a 5-field UTC cron expression, for example \"0 2 * * *\".");
    }
    schedule = body.value.schedule.trim();
  }
  const now = nowIso();
  const id = newId("task");
  let scheduledJobId: string | null = null;
  if (schedule) {
    const expr = parseCron(schedule);
    scheduledJobId = newId("job");
    await dbRun(
      env,
      `INSERT INTO scheduled_jobs (id, name, goal, cron, enabled, last_run_at, next_run_at, created_at)
       VALUES (?, ?, ?, ?, 1, NULL, ?, ?)`,
      [scheduledJobId, clipName(goal), goal, schedule, expr ? computeNextRun(new Date(), expr) : null, now],
    );
  }
  await dbRun(
    env,
    `INSERT INTO tasks
      (id, goal, status, schedule, scheduled_job_id, error, result_summary, plan_attempts, planner_note, locked_until, created_at, updated_at, completed_at)
     VALUES (?, ?, 'planning', ?, ?, NULL, NULL, 0, NULL, NULL, ?, ?, NULL)`,
    [id, goal, schedule, scheduledJobId, now, now],
  );
  await logActivity(env, "api", "task.created", id, { schedule, scheduled_job_id: scheduledJobId });
  await logProgress(env, id, null, "info", "Task created. Planning runs on this request, then one step every cron tick.", null);
  ctx.waitUntil(runTick(env, "create"));
  const task = await dbFirst<TaskRow>(env, "SELECT * FROM tasks WHERE id = ?", [id]);
  return json({ task: task ? mapTask(task) : { id, goal, status: "planning", schedule, scheduled_job_id: scheduledJobId, error: null, result_summary: null, created_at: now, updated_at: now, completed_at: null } }, 201);
}

async function listTasks(env: Env, url: URL): Promise<Response> {
  const limit = clampLimit(url.searchParams.get("limit"), 50, 100);
  const status = url.searchParams.get("status");
  if (status && !(TASK_STATUSES as readonly string[]).includes(status)) {
    return apiError(400, "bad_request", `status must be one of: ${TASK_STATUSES.join(", ")}.`);
  }
  const rows = status
    ? await dbAll<TaskRow>(env, "SELECT * FROM tasks WHERE status = ? ORDER BY created_at DESC LIMIT ?", [status, limit])
    : await dbAll<TaskRow>(env, "SELECT * FROM tasks ORDER BY created_at DESC LIMIT ?", [limit]);
  return json({ tasks: rows.map(mapTask) });
}

async function getTask(env: Env, id: string): Promise<Response> {
  const task = await dbFirst<TaskRow>(env, "SELECT * FROM tasks WHERE id = ?", [id]);
  if (!task) return apiError(404, "not_found", "Task not found.");
  const [subtasks, progress, findings, documents, approvals] = await Promise.all([
    dbAll<SubtaskRow>(env, "SELECT * FROM subtasks WHERE task_id = ? ORDER BY sort_order ASC", [id]),
    dbAll<ProgressRow>(env, "SELECT * FROM progress_log WHERE task_id = ? ORDER BY created_at ASC", [id]),
    dbAll<FindingRow>(env, "SELECT * FROM findings WHERE task_id = ? ORDER BY created_at ASC", [id]),
    dbAll<DocumentRow>(env, "SELECT * FROM documents WHERE task_id = ? ORDER BY created_at ASC", [id]),
    dbAll<ApprovalRow>(env, "SELECT * FROM approvals WHERE task_id = ? ORDER BY created_at ASC", [id]),
  ]);
  return json({
    task: mapTask(task),
    subtasks: subtasks.map(mapSubtask),
    progress: progress.map(mapProgress),
    findings: findings.map(mapFinding),
    documents: documents.map(mapDocument),
    approvals: approvals.map(mapApproval),
  });
}

async function listApprovals(env: Env, url: URL): Promise<Response> {
  const status = url.searchParams.get("status");
  if (status && status !== "pending" && status !== "approved" && status !== "rejected") {
    return apiError(400, "bad_request", "status must be pending, approved, or rejected.");
  }
  const limit = clampLimit(url.searchParams.get("limit"), 50, 100);
  const rows = status
    ? await dbAll<ApprovalRow>(env, "SELECT * FROM approvals WHERE status = ? ORDER BY created_at DESC LIMIT ?", [status, limit])
    : await dbAll<ApprovalRow>(env, "SELECT * FROM approvals ORDER BY created_at DESC LIMIT ?", [limit]);
  return json({ approvals: rows.map(mapApproval) });
}

async function createApproval(request: Request, env: Env): Promise<Response> {
  const body = await readJson(request);
  if (!body.ok) return body.response;
  if (!isRecord(body.value)) return apiError(400, "bad_request", "JSON body must be an object.");
  const action = asString(body.value.action, 80);
  const summary = asString(body.value.summary, 2000);
  if (!action || !summary) return apiError(400, "bad_request", "action and summary are required.");
  const taskId = optionalId(body.value.task_id, "task_id");
  if (!taskId.ok) return apiError(400, "bad_request", taskId.error);
  const subtaskId = optionalId(body.value.subtask_id, "subtask_id");
  if (!subtaskId.ok) return apiError(400, "bad_request", subtaskId.error);
  let level = body.value.level === "explicit_authorisation" ? "explicit_authorisation" : "approval_required";
  if (/\b(pay|payment|invoice|charge|purchase|checkout)\b/i.test(`${action} ${summary}`)) level = "explicit_authorisation";
  let payload: string | null = null;
  if (body.value.payload !== undefined && body.value.payload !== null) {
    if (!isRecord(body.value.payload)) return apiError(400, "bad_request", "payload must be an object.");
    payload = JSON.stringify(body.value.payload);
    if (payload.length > 8000) return apiError(400, "bad_request", "payload is too large.");
  }
  const id = newId("apr");
  const now = nowIso();
  await dbRun(
    env,
    `INSERT INTO approvals
      (id, task_id, subtask_id, action, level, summary, payload_json, status, reason, created_at, decided_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', NULL, ?, NULL)`,
    [id, taskId.value, subtaskId.value, action, level, summary, payload, now],
  );
  await logActivity(env, "api", "approval.created", taskId.value, { id, action, level, external_action_taken: false });
  const row = await dbFirst<ApprovalRow>(env, "SELECT * FROM approvals WHERE id = ?", [id]);
  return json({ approval: row ? mapApproval(row) : null, external_action_taken: false }, 201);
}

async function decideApproval(
  env: Env,
  id: string,
  status: "approved" | "rejected",
  request: Request,
): Promise<Response> {
  const row = await dbFirst<ApprovalRow>(env, "SELECT * FROM approvals WHERE id = ?", [id]);
  if (!row) return apiError(404, "not_found", "Approval not found.");
  if (row.status !== "pending") return apiError(409, "conflict", `Approval is already ${row.status}.`);
  let reason: string | null = null;
  if (request.headers.get("content-type")?.includes("application/json")) {
    const body = await readJson(request);
    if (!body.ok) return body.response;
    if (!isRecord(body.value)) return apiError(400, "bad_request", "JSON body must be an object.");
    const text = body.value.reason ?? body.value.note;
    if (text !== undefined && text !== null) {
      if (typeof text !== "string" || text.trim().length > 2000) {
        return apiError(400, "bad_request", "reason must be a string up to 2000 characters.");
      }
      reason = text.trim() || null;
    }
  }
  const now = nowIso();
  await dbRun(env, "UPDATE approvals SET status = ?, reason = ?, decided_at = ? WHERE id = ? AND status = 'pending'", [
    status,
    reason,
    now,
    id,
  ]);
  if (row.action === "persona_external" && row.payload_json) {
    try {
      const payload = JSON.parse(row.payload_json) as { persona_task_id?: unknown };
      if (typeof payload.persona_task_id === "string" && payload.persona_task_id) {
        await markPersonaDraft(env, payload.persona_task_id, status === "approved");
      }
    } catch {
      // The approval row is already decided. A bad payload does not undo that.
    }
  }
  if (row.subtask_id) {
    if (status === "approved") {
      await dbRun(
        env,
        `UPDATE subtasks
         SET status = 'completed',
             result_summary = ?,
             error = NULL,
             locked_until = NULL,
             updated_at = ?
         WHERE id = ?`,
        [
          `User approved "${row.action}". No external action was taken. This backend only records the decision.`,
          now,
          row.subtask_id,
        ],
      );
    } else {
      await dbRun(
        env,
        "UPDATE subtasks SET status = 'failed', error = ?, locked_until = NULL, updated_at = ? WHERE id = ?",
        [`User rejected "${row.action}"${reason ? `: ${reason}` : "."}`, now, row.subtask_id],
      );
    }
  }
  if (row.task_id) {
    await logProgress(
      env,
      row.task_id,
      row.subtask_id,
      status === "approved" ? "info" : "warn",
      status === "approved"
        ? `Approval ${id} approved. Nothing was sent, published, or paid.`
        : `Approval ${id} rejected.`,
      { reason },
    );
    await recomputeTaskStatus(env, row.task_id);
  }
  await logActivity(env, "api", status === "approved" ? "approval.approved" : "approval.rejected", row.task_id, {
    id,
    reason,
    external_action_taken: false,
  });
  const updated = await dbFirst<ApprovalRow>(env, "SELECT * FROM approvals WHERE id = ?", [id]);
  return json({ approval: updated ? mapApproval(updated) : null, external_action_taken: false });
}

async function listMemory(env: Env, url: URL): Promise<Response> {
  const limit = clampLimit(url.searchParams.get("limit"), 50, 100);
  const q = url.searchParams.get("q")?.trim() ?? "";
  const rows = q
    ? await dbAll<MemoryRow>(
        env,
        `SELECT * FROM memory
         WHERE content LIKE ? ESCAPE '\\' OR IFNULL(key, '') LIKE ? ESCAPE '\\' OR tags LIKE ? ESCAPE '\\'
         ORDER BY updated_at DESC
         LIMIT ?`,
        [likeContains(q), likeContains(q), likeContains(q), limit],
      )
    : await dbAll<MemoryRow>(env, "SELECT * FROM memory ORDER BY updated_at DESC LIMIT ?", [limit]);
  return json({ memory: rows.map(mapMemory) });
}

async function createMemory(request: Request, env: Env): Promise<Response> {
  const body = await readJson(request);
  if (!body.ok) return body.response;
  if (!isRecord(body.value)) return apiError(400, "bad_request", "JSON body must be an object.");
  const content = asString(body.value.content, 4000);
  if (!content) return apiError(400, "bad_request", "content is required and must be at most 4000 characters.");
  const key = asOptionalString(body.value.key, 120);
  if (body.value.key !== undefined && body.value.key !== null && key === undefined) {
    return apiError(400, "bad_request", "key must be a string up to 120 characters.");
  }
  const tags = stringList(body.value.tags, 12, 40);
  if (!tags.ok) return apiError(400, "bad_request", tags.error);
  const sources = optionalSourceUrls(body.value.source_urls);
  if (!sources.ok) return apiError(400, "bad_request", sources.error);
  const id = newId("mem");
  const now = nowIso();
  await dbRun(
    env,
    "INSERT INTO memory (id, key, content, tags, source_urls, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
    [id, key ?? null, content, JSON.stringify(tags.values), JSON.stringify(sources.urls), now, now],
  );
  await logActivity(env, "api", "memory.created", null, { id, key: key ?? null });
  const row = await dbFirst<MemoryRow>(env, "SELECT * FROM memory WHERE id = ?", [id]);
  return json({ memory: row ? mapMemory(row) : null }, 201);
}

async function deleteMemory(env: Env, id: string): Promise<Response> {
  const changes = await dbRun(env, "DELETE FROM memory WHERE id = ?", [id]);
  if (changes !== 1) return apiError(404, "not_found", "Memory not found.");
  await logActivity(env, "api", "memory.deleted", null, { id });
  return json({ deleted: true, id });
}

async function listActivity(env: Env, url: URL): Promise<Response> {
  const limit = clampLimit(url.searchParams.get("limit"), 100, 500);
  const rows = await dbAll<ActivityRow>(env, "SELECT * FROM activity ORDER BY created_at DESC LIMIT ?", [limit]);
  return json({ activity: rows.map(mapActivity) });
}

async function listPipeline(env: Env, url: URL): Promise<Response> {
  const stage = url.searchParams.get("stage");
  if (stage && !isPipelineStage(stage)) {
    return apiError(400, "bad_request", `stage must be one of: ${PIPELINE_STAGES.join(", ")}.`);
  }
  const limit = clampLimit(url.searchParams.get("limit"), 100, 200);
  const rows = stage
    ? await dbAll<PipelineRow>(env, "SELECT * FROM pipeline WHERE stage = ? ORDER BY updated_at DESC LIMIT ?", [stage, limit])
    : await dbAll<PipelineRow>(env, "SELECT * FROM pipeline ORDER BY updated_at DESC LIMIT ?", [limit]);
  return json({ pipeline: rows.map(mapPipeline) });
}

async function writePipeline(request: Request, env: Env, pathId: string | null): Promise<Response> {
  const body = await readJson(request);
  if (!body.ok) return body.response;
  if (!isRecord(body.value)) return apiError(400, "bad_request", "JSON body must be an object.");
  const id = pathId ?? (typeof body.value.id === "string" ? body.value.id : null);
  if (id) return updatePipeline(env, id, body.value);
  const company = asString(body.value.company, 200);
  if (!company) return apiError(400, "bad_request", "company is required.");
  const sources = optionalSourceUrls(body.value.source_urls);
  if (!sources.ok || sources.urls.length === 0) {
    return apiError(400, "bad_request", sources.ok ? "source_urls must contain at least one http(s) URL." : sources.error);
  }
  const stage = body.value.stage === undefined || body.value.stage === null ? "prospect" : body.value.stage;
  if (typeof stage !== "string" || !isPipelineStage(stage)) {
    return apiError(400, "bad_request", `stage must be one of: ${PIPELINE_STAGES.join(", ")}.`);
  }
  const mrr = parseMrr(body.value.mrr);
  if (!mrr.ok) return apiError(400, "bad_request", mrr.error);
  const contactName = asOptionalString(body.value.contact_name, 200);
  const notes = asOptionalString(body.value.notes, 4000);
  const email = asOptionalString(body.value.contact_email, 200);
  if (presentButInvalid(body.value.contact_name, contactName)) {
    return apiError(400, "bad_request", "contact_name must be a string up to 200 characters.");
  }
  if (presentButInvalid(body.value.notes, notes)) {
    return apiError(400, "bad_request", "notes must be a string up to 4000 characters.");
  }
  if (presentButInvalid(body.value.contact_email, email) || (email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email))) {
    return apiError(400, "bad_request", "contact_email is not a usable email address.");
  }
  let website: string | null = null;
  if (body.value.website !== undefined && body.value.website !== null && body.value.website !== "") {
    const site = asString(body.value.website, 500);
    if (!site) return apiError(400, "bad_request", "website must be an http(s) URL.");
    const parsed = optionalSourceUrls([site]);
    if (!parsed.ok) return apiError(400, "bad_request", parsed.error);
    website = parsed.urls[0] ?? null;
  }
  const now = nowIso();
  const leadId = newId("lead");
  await dbRun(
    env,
    `INSERT INTO pipeline
      (id, company, contact_name, contact_email, website, stage, mrr, notes, source_urls, task_id, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)`,
    [leadId, company, contactName ?? null, email ?? null, website, stage, mrr.mrr, notes ?? null, JSON.stringify(sources.urls), now, now],
  );
  await logActivity(env, "api", "pipeline.created", null, { id: leadId, company, stage, source_urls: sources.urls });
  const row = await dbFirst<PipelineRow>(env, "SELECT * FROM pipeline WHERE id = ?", [leadId]);
  return json({ pipeline: row ? mapPipeline(row) : null }, 201);
}

async function updatePipeline(env: Env, id: string, body: Record<string, unknown>): Promise<Response> {
  const existing = await dbFirst<PipelineRow>(env, "SELECT * FROM pipeline WHERE id = ?", [id]);
  if (!existing) return apiError(404, "not_found", "Pipeline row not found.");
  const company = body.company === undefined ? existing.company : asString(body.company, 200);
  if (!company) return apiError(400, "bad_request", "company must be a non-empty string.");
  const stage = body.stage === undefined ? existing.stage : body.stage;
  if (typeof stage !== "string" || !isPipelineStage(stage)) {
    return apiError(400, "bad_request", `stage must be one of: ${PIPELINE_STAGES.join(", ")}.`);
  }
  const mrr = body.mrr === undefined ? { ok: true as const, mrr: existing.mrr } : parseMrr(body.mrr);
  if (!mrr.ok) return apiError(400, "bad_request", mrr.error);
  let sourceUrls = parseStoredUrls(existing.source_urls);
  if (body.source_urls !== undefined) {
    const sources = optionalSourceUrls(body.source_urls);
    if (!sources.ok || sources.urls.length === 0) {
      return apiError(400, "bad_request", sources.ok ? "source_urls must contain at least one http(s) URL." : sources.error);
    }
    sourceUrls = sources.urls;
  }
  const contactName = body.contact_name === undefined ? existing.contact_name : asOptionalString(body.contact_name, 200);
  const notes = body.notes === undefined ? existing.notes : asOptionalString(body.notes, 4000);
  const email = body.contact_email === undefined ? existing.contact_email : asOptionalString(body.contact_email, 200);
  if (email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return apiError(400, "bad_request", "contact_email is not a usable email address.");
  }
  let website = existing.website;
  if (body.website !== undefined) {
    if (body.website === null || body.website === "") website = null;
    else if (typeof body.website === "string") {
      const parsed = optionalSourceUrls([body.website]);
      if (!parsed.ok) return apiError(400, "bad_request", parsed.error);
      website = parsed.urls[0] ?? null;
    } else return apiError(400, "bad_request", "website must be an http(s) URL or null.");
  }
  if (contactName === undefined || notes === undefined || email === undefined) {
    return apiError(400, "bad_request", "A text field is too long or not a string.");
  }
  const now = nowIso();
  await dbRun(
    env,
    `UPDATE pipeline
     SET company = ?, contact_name = ?, contact_email = ?, website = ?, stage = ?, mrr = ?, notes = ?, source_urls = ?, updated_at = ?
     WHERE id = ?`,
    [company, contactName, email, website, stage, mrr.mrr, notes, JSON.stringify(sourceUrls), now, id],
  );
  await logActivity(env, "api", "pipeline.updated", null, { id, stage, mrr: mrr.mrr });
  const row = await dbFirst<PipelineRow>(env, "SELECT * FROM pipeline WHERE id = ?", [id]);
  return json({ pipeline: row ? mapPipeline(row) : null });
}

function presentButInvalid(input: unknown, parsed: string | null | undefined): boolean {
  return input !== undefined && input !== null && input !== "" && parsed === undefined;
}

function optionalId(
  value: unknown,
  field: string,
): { ok: true; value: string | null } | { ok: false; error: string } {
  if (value === undefined || value === null || value === "") return { ok: true, value: null };
  if (typeof value !== "string" || !value.trim() || value.trim().length > 80) {
    return { ok: false, error: `${field} must be a string up to 80 characters.` };
  }
  return { ok: true, value: value.trim() };
}

function clipName(goal: string): string {
  const trimmed = goal.trim();
  return trimmed.length <= 80 ? trimmed : `${trimmed.slice(0, 79)}…`;
}

function likeContains(value: string): string {
  return `%${value.replace(/[\\%_]/g, (char) => `\\${char}`)}%`;
}

function stringList(
  value: unknown,
  maxItems: number,
  maxLen: number,
): { ok: true; values: string[] } | { ok: false; error: string } {
  if (value === undefined || value === null) return { ok: true, values: [] };
  if (!Array.isArray(value)) return { ok: false, error: "tags must be an array of strings." };
  if (value.length > maxItems) return { ok: false, error: `tags accepts at most ${maxItems} items.` };
  const values: string[] = [];
  for (const item of value) {
    if (typeof item !== "string" || !item.trim() || item.trim().length > maxLen) {
      return { ok: false, error: `each tag must be a non-empty string up to ${maxLen} characters.` };
    }
    values.push(item.trim());
  }
  return { ok: true, values };
}

function parseStoredUrls(value: string): string[] {
  try {
    const parsed = JSON.parse(value) as unknown;
    if (!Array.isArray(parsed)) return [];
    return parsed.filter((item): item is string => typeof item === "string");
  } catch {
    return [];
  }
}
