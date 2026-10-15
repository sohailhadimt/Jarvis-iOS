import { newId, nowIso, parseJsonValue, parseStringArray } from "./http";
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

export type SqlParam = string | number | null;

export async function dbAll<T>(env: Env, sql: string, params: SqlParam[] = []): Promise<T[]> {
  const result = await env.DB.prepare(sql).bind(...params).all();
  return (result.results ?? []) as T[];
}

export async function dbFirst<T>(env: Env, sql: string, params: SqlParam[] = []): Promise<T | null> {
  const row = await env.DB.prepare(sql).bind(...params).first();
  return (row as T | null) ?? null;
}

export async function dbRun(env: Env, sql: string, params: SqlParam[] = []): Promise<number> {
  const result = await env.DB.prepare(sql).bind(...params).run();
  return result.meta?.changes ?? 0;
}

export async function getState(env: Env, key: string): Promise<string | null> {
  const row = await dbFirst<{ value: string }>(env, "SELECT value FROM runtime_state WHERE key = ?", [key]);
  return row?.value ?? null;
}

export async function setState(env: Env, key: string, value: string): Promise<void> {
  await dbRun(
    env,
    `INSERT INTO runtime_state (key, value, updated_at) VALUES (?, ?, ?)
     ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at`,
    [key, value, nowIso()],
  );
}

export async function logActivity(
  env: Env,
  actor: string,
  action: string,
  taskId: string | null,
  detail: unknown,
): Promise<void> {
  await dbRun(
    env,
    "INSERT INTO activity (id, actor, action, task_id, detail_json, created_at) VALUES (?, ?, ?, ?, ?, ?)",
    [newId("act"), actor, action, taskId, JSON.stringify(detail ?? null), nowIso()],
  );
}

export async function logProgress(
  env: Env,
  taskId: string,
  subtaskId: string | null,
  level: "info" | "warn" | "error",
  message: string,
  detail: unknown,
): Promise<void> {
  await dbRun(
    env,
    "INSERT INTO progress_log (id, task_id, subtask_id, level, message, detail_json, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
    [newId("log"), taskId, subtaskId, level, message, detail === undefined ? null : JSON.stringify(detail), nowIso()],
  );
}

export function mapTask(row: TaskRow) {
  return {
    id: row.id,
    goal: row.goal,
    status: row.status,
    schedule: row.schedule,
    scheduled_job_id: row.scheduled_job_id,
    error: row.error,
    result_summary: row.result_summary,
    created_at: row.created_at,
    updated_at: row.updated_at,
    completed_at: row.completed_at,
  };
}

export function mapSubtask(row: SubtaskRow) {
  return {
    id: row.id,
    task_id: row.task_id,
    agent: row.agent,
    title: row.title,
    instruction: row.instruction,
    action_level: row.action_level,
    depends_on: parseStringArray(row.depends_on_json),
    status: row.status,
    step: row.step,
    max_steps: row.max_steps,
    attempt: row.attempt,
    result_summary: row.result_summary,
    error: row.error,
    next_attempt_at: row.next_attempt_at,
    created_at: row.created_at,
    updated_at: row.updated_at,
  };
}

export function mapProgress(row: ProgressRow) {
  return {
    id: row.id,
    task_id: row.task_id,
    subtask_id: row.subtask_id,
    level: row.level,
    message: row.message,
    detail: parseJsonValue(row.detail_json),
    created_at: row.created_at,
  };
}

export function mapFinding(row: FindingRow) {
  return {
    id: row.id,
    task_id: row.task_id,
    subtask_id: row.subtask_id,
    claim: row.claim,
    source_urls: parseStringArray(row.source_urls),
    excerpt: row.excerpt,
    created_at: row.created_at,
  };
}

export function mapDocument(row: DocumentRow) {
  return {
    id: row.id,
    task_id: row.task_id,
    subtask_id: row.subtask_id,
    kind: row.kind,
    title: row.title,
    body: row.body,
    source_urls: parseStringArray(row.source_urls),
    created_at: row.created_at,
  };
}

export function mapApproval(row: ApprovalRow) {
  return {
    id: row.id,
    task_id: row.task_id,
    subtask_id: row.subtask_id,
    action: row.action,
    level: row.level,
    summary: row.summary,
    payload: parseJsonValue(row.payload_json),
    status: row.status,
    reason: row.reason,
    created_at: row.created_at,
    decided_at: row.decided_at,
  };
}

export function mapMemory(row: MemoryRow) {
  return {
    id: row.id,
    key: row.key,
    content: row.content,
    tags: parseStringArray(row.tags),
    source_urls: parseStringArray(row.source_urls),
    created_at: row.created_at,
    updated_at: row.updated_at,
  };
}

export function mapActivity(row: ActivityRow) {
  return {
    id: row.id,
    actor: row.actor,
    action: row.action,
    task_id: row.task_id,
    detail: parseJsonValue(row.detail_json),
    created_at: row.created_at,
  };
}

export function mapPipeline(row: PipelineRow) {
  return {
    id: row.id,
    company: row.company,
    contact_name: row.contact_name,
    contact_email: row.contact_email,
    website: row.website,
    stage: row.stage,
    mrr: row.mrr,
    notes: row.notes,
    source_urls: parseStringArray(row.source_urls),
    task_id: row.task_id,
    created_at: row.created_at,
    updated_at: row.updated_at,
  };
}
