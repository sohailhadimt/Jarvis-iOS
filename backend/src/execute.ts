import { agentSystemPrompt, plannerSystemPrompt, plannerUserPrompt } from "./agents";
import { isRoutine, openMission } from "./missions";
import { computeNextRun, cronMatches, parseCron } from "./cron";
import { dbAll, dbFirst, dbRun, logActivity, logProgress } from "./db";
import { clip, newId, nowIso, parseStringArray } from "./http";
import type { ChatMessage, LlmFailure } from "./llm";
import { completeChat } from "./llm";
import { parsePlan, qcPassValue } from "./plan";
import { executeTool, parseToolArgs, toolsFor } from "./tools";
import type { ActionLevel, AgentName, DocumentRow, Env, FindingRow, ScheduledJobRow, SubtaskRow, TaskRow } from "./types";
import { LIMITS } from "./types";
import { mapDocument, mapFinding } from "./db";

export async function runTick(env: Env, reason: string): Promise<void> {
  try {
    await releaseStaleLocks(env);
    await runDueJobs(env);
    const planned = await planOneTask(env);
    if (planned) return;
    await stepOneSubtask(env);
  } catch (err) {
    const message = err instanceof Error ? err.message : "Tick failed.";
    console.error("jarvis tick failed", reason, message);
    try {
      await logActivity(env, "system", "tick.error", null, { reason, message });
    } catch {
      console.error("jarvis could not record the tick error");
    }
  }
}

async function releaseStaleLocks(env: Env): Promise<void> {
  const now = nowIso();
  await dbRun(env, "UPDATE tasks SET locked_until = NULL WHERE locked_until IS NOT NULL AND locked_until < ?", [now]);
  await dbRun(
    env,
    `UPDATE subtasks
     SET locked_until = NULL, status = 'pending'
     WHERE status = 'running' AND locked_until IS NOT NULL AND locked_until < ? AND messages_json IS NULL`,
    [now],
  );
  await dbRun(
    env,
    "UPDATE subtasks SET locked_until = NULL WHERE status = 'running' AND locked_until IS NOT NULL AND locked_until < ?",
    [now],
  );
}

async function runDueJobs(env: Env): Promise<void> {
  const jobs = await dbAll<ScheduledJobRow>(env, "SELECT * FROM scheduled_jobs WHERE enabled = 1 LIMIT 10");
  const now = new Date();
  const nowStamp = now.toISOString();
  let created = 0;
  for (const job of jobs) {
    const expr = parseCron(job.cron);
    if (!expr) {
      await logActivity(env, "scheduler", "job.invalid_cron", null, { id: job.id, cron: job.cron });
      continue;
    }
    if (!job.next_run_at && !cronMatches(now, expr)) {
      await dbRun(env, "UPDATE scheduled_jobs SET next_run_at = ? WHERE id = ?", [computeNextRun(now, expr), job.id]);
      continue;
    }
    const due = !job.next_run_at || job.next_run_at <= nowStamp;
    if (!due) continue;
    if (created >= 3) break;
    if (isRoutine(job.id)) {
      const missionId = await openMission(env, job.goal);
      await dbRun(env, "UPDATE scheduled_jobs SET last_run_at = ?, next_run_at = ? WHERE id = ?", [
        nowStamp,
        computeNextRun(now, expr),
        job.id,
      ]);
      await logActivity(env, "scheduler", "routine.ran", null, { job_id: job.id, mission_id: missionId, cron: job.cron });
      created++;
      continue;
    }
    const taskId = newId("task");
    await dbRun(
      env,
      `INSERT INTO tasks
        (id, goal, status, schedule, scheduled_job_id, error, result_summary, plan_attempts, planner_note, locked_until, created_at, updated_at, completed_at)
       VALUES (?, ?, 'planning', ?, ?, NULL, NULL, 0, NULL, NULL, ?, ?, NULL)`,
      [taskId, job.goal, job.cron, job.id, nowStamp, nowStamp],
    );
    await dbRun(env, "UPDATE scheduled_jobs SET last_run_at = ?, next_run_at = ? WHERE id = ?", [
      nowStamp,
      computeNextRun(now, expr),
      job.id,
    ]);
    await logProgress(env, taskId, null, "info", `Scheduled job "${job.name}" created this task.`, { job_id: job.id });
    await logActivity(env, "scheduler", "job.ran", taskId, { job_id: job.id, cron: job.cron });
    created++;
  }
}

async function planOneTask(env: Env): Promise<boolean> {
  const now = nowIso();
  const task = await dbFirst<TaskRow>(
    env,
    `SELECT * FROM tasks
     WHERE status = 'planning' AND (locked_until IS NULL OR locked_until < ?)
     ORDER BY created_at ASC
     LIMIT 1`,
    [now],
  );
  if (!task) return false;
  const lockUntil = new Date(Date.now() + LIMITS.lockMs).toISOString();
  const claimed = await dbRun(
    env,
    `UPDATE tasks SET locked_until = ?, updated_at = ?
     WHERE id = ? AND status = 'planning' AND (locked_until IS NULL OR locked_until < ?)`,
    [lockUntil, now, task.id, now],
  );
  if (claimed !== 1) return false;

  const memory = await dbAll<{ content: string }>(
    env,
    "SELECT content FROM memory ORDER BY updated_at DESC LIMIT 12",
  );
  const messages: ChatMessage[] = [
    { role: "system", content: plannerSystemPrompt() },
    { role: "user", content: plannerUserPrompt(task.goal, memory.map((item) => item.content)) },
  ];
  if (task.planner_note) {
    messages.push({
      role: "user",
      content: `Your previous plan was rejected: ${task.planner_note}\nReturn a corrected JSON object only.`,
    });
  }
  const llm = await completeChat(env, messages, null);
  if (!llm.ok) {
    await handlePlanFailure(env, task, llm);
    return true;
  }
  const raw = llm.message.content ?? "";
  const parsed = raw.trim() ? parsePlan(raw) : { ok: false as const, error: "Planner returned an empty response." };
  await logProgress(env, task.id, null, "info", `Planner responded via ${llm.provider} (${llm.model}).`, {
    raw: clip(raw, 2000),
  });
  if (!parsed.ok) {
    const attempts = Number(task.plan_attempts) + 1;
    if (attempts >= LIMITS.planAttempts) {
      const error = `Could not produce a valid plan after ${attempts} attempts: ${parsed.error}`;
      await dbRun(
        env,
        `UPDATE tasks
         SET status = 'failed', error = ?, plan_attempts = ?, planner_note = ?, locked_until = NULL, updated_at = ?, completed_at = NULL
         WHERE id = ?`,
        [error, attempts, parsed.error, nowIso(), task.id],
      );
      await logProgress(env, task.id, null, "error", error, null);
      await logActivity(env, "orchestrator", "task.plan_failed", task.id, { error: parsed.error });
      void import("./owner-alert").then((mod) =>
        mod.reportProblem(env, {
          sourceId: `task:${task.id}`,
          kind: "failed_task",
          urgent: false,
          summary: "A task failed and needs you.",
          detail: error,
        }),
      );
      return true;
    }
    await dbRun(
      env,
      "UPDATE tasks SET plan_attempts = ?, planner_note = ?, locked_until = NULL, updated_at = ? WHERE id = ?",
      [attempts, parsed.error, nowIso(), task.id],
    );
    await logProgress(env, task.id, null, "warn", `Plan rejected and will be retried: ${parsed.error}`, null);
    return true;
  }

  const ids = parsed.subtasks.map(() => newId("sub"));
  const stamp = nowIso();
  for (let i = 0; i < parsed.subtasks.length; i++) {
    const subtask = parsed.subtasks[i];
    const dependsOn = subtask.depends_on.map((index) => ids[index]);
    await dbRun(
      env,
      `INSERT INTO subtasks
        (id, task_id, agent, title, instruction, action_level, depends_on_json, status, step, max_steps, messages_json, result_summary, error, attempt, max_attempts, next_attempt_at, locked_until, sort_order, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', 0, ?, NULL, NULL, NULL, 0, ?, NULL, NULL, ?, ?, ?)`,
      [
        ids[i],
        task.id,
        subtask.agent,
        subtask.title,
        subtask.instruction,
        subtask.action_level,
        JSON.stringify(dependsOn),
        LIMITS.maxSteps,
        LIMITS.maxAttempts,
        i,
        stamp,
        stamp,
      ],
    );
    if (subtask.coerced) {
      await logProgress(
        env,
        task.id,
        ids[i],
        "warn",
        `Action level for "${subtask.title}" was raised to ${subtask.action_level} so an external step cannot run on its own.`,
        null,
      );
    }
  }
  await dbRun(
    env,
    "UPDATE tasks SET status = 'running', plan_attempts = ?, planner_note = NULL, locked_until = NULL, updated_at = ? WHERE id = ?",
    [Number(task.plan_attempts) + 1, stamp, task.id],
  );
  await logActivity(env, "orchestrator", "task.planned", task.id, {
    subtasks: parsed.subtasks.map((subtask, index) => ({
      id: ids[index],
      agent: subtask.agent,
      action_level: subtask.action_level,
    })),
  });
  await logProgress(env, task.id, null, "info", `Plan stored with ${parsed.subtasks.length} subtask(s).`, null);
  return true;
}

async function handlePlanFailure(env: Env, task: TaskRow, failure: LlmFailure): Promise<void> {
  const now = nowIso();
  if (failure.code === "not_configured") {
    await dbRun(
      env,
      "UPDATE tasks SET status = 'failed', error = ?, locked_until = NULL, updated_at = ?, completed_at = NULL WHERE id = ?",
      [failure.message, now, task.id],
    );
    await logProgress(env, task.id, null, "error", failure.message, null);
    await logActivity(env, "orchestrator", "task.plan_failed", task.id, { error: failure.message });
    return;
  }
  if (failure.code === "rate_limited") {
    const until = new Date(Date.now() + 5 * 60_000).toISOString();
    await dbRun(env, "UPDATE tasks SET locked_until = ?, updated_at = ? WHERE id = ?", [until, now, task.id]);
    await logProgress(env, task.id, null, "warn", failure.message, { retry_after: until });
    return;
  }
  const attempts = Number(task.plan_attempts) + 1;
  if (attempts >= LIMITS.planAttempts) {
    const error = `Planning failed after ${attempts} attempts: ${failure.message}`;
    await dbRun(
      env,
      "UPDATE tasks SET status = 'failed', error = ?, plan_attempts = ?, locked_until = NULL, updated_at = ?, completed_at = NULL WHERE id = ?",
      [error, attempts, now, task.id],
    );
    await logProgress(env, task.id, null, "error", error, null);
    return;
  }
  const until = new Date(Date.now() + attempts * 5 * 60_000).toISOString();
  await dbRun(
    env,
    "UPDATE tasks SET plan_attempts = ?, planner_note = ?, locked_until = ?, updated_at = ? WHERE id = ?",
    [attempts, failure.message, until, now, task.id],
  );
  await logProgress(env, task.id, null, "warn", `Planning error, retry after ${until}. ${failure.message}`, null);
}

async function stepOneSubtask(env: Env): Promise<void> {
  const now = nowIso();
  const candidates = await dbAll<SubtaskRow>(
    env,
    `SELECT s.* FROM subtasks s
     JOIN tasks t ON t.id = s.task_id
     WHERE t.status IN ('running', 'awaiting_approval')
       AND s.status IN ('pending', 'running')
       AND (s.locked_until IS NULL OR s.locked_until < ?)
       AND (s.next_attempt_at IS NULL OR s.next_attempt_at <= ?)
       AND s.step < s.max_steps
     ORDER BY s.sort_order ASC, s.created_at ASC
     LIMIT 25`,
    [now, now],
  );
  for (const candidate of candidates) {
    const siblings = await dbAll<{ id: string; status: string }>(
      env,
      "SELECT id, status FROM subtasks WHERE task_id = ?",
      [candidate.task_id],
    );
    const statusById = new Map(siblings.map((row) => [row.id, row.status]));
    const deps = parseStringArray(candidate.depends_on_json);
    if (deps.some((id) => statusById.get(id) !== "completed")) continue;
    const lockUntil = new Date(Date.now() + LIMITS.lockMs).toISOString();
    const claimed = await dbRun(
      env,
      `UPDATE subtasks SET status = 'running', locked_until = ?, updated_at = ?
       WHERE id = ? AND status IN ('pending', 'running') AND (locked_until IS NULL OR locked_until < ?)`,
      [lockUntil, nowIso(), candidate.id, now],
    );
    if (claimed !== 1) continue;
    await runSubtaskStep(env, candidate);
    return;
  }
}

async function runSubtaskStep(env: Env, sub: SubtaskRow): Promise<void> {
  const messages = readMessages(sub.messages_json);
  if (!messages) {
    await failSubtask(env, sub, [], "Stored specialist transcript was not valid JSON, so the step was not continued.");
    return;
  }
  if (messages.length === 0) {
    messages.push({
      role: "system",
      content: agentSystemPrompt(sub.agent as AgentName, sub.action_level as ActionLevel),
    });
    messages.push({ role: "user", content: await buildUserPrompt(env, sub) });
  }
  const agent = sub.agent as AgentName;
  const llm = await completeChat(env, messages, toolsFor(agent));
  if (!llm.ok) {
    await handleSubtaskLlmFailure(env, sub, llm, messages);
    return;
  }
  messages.push({
    role: "assistant",
    content: llm.message.content,
    tool_calls: llm.message.tool_calls,
  });
  await logProgress(env, sub.task_id, sub.id, "info", `${sub.agent} step ${sub.step + 1} via ${llm.provider} (${llm.model}).`, null);

  const calls = llm.message.tool_calls ?? [];
  if (calls.length === 0) {
    const summary = (llm.message.content ?? "").trim() || "(The specialist returned an empty summary.)";
    await finishSubtask(env, sub, messages, summary);
    return;
  }

  const ordered = [...calls].sort((a, b) => approvalRank(a.function.name) - approvalRank(b.function.name));
  let stopped = false;
  for (let i = 0; i < ordered.length; i++) {
    const call = ordered[i];
    let payload: unknown;
    if (i >= LIMITS.maxToolCallsExecuted) {
      payload = {
        ok: false,
        error: `Only ${LIMITS.maxToolCallsExecuted} tool calls run per step. Call the rest on your next turn.`,
      };
    } else if (stopped) {
      payload = { ok: false, error: "Not run. request_approval already ended this step. Nothing external was sent." };
    } else {
      const parsed = parseToolArgs(call.function.arguments);
      if (!parsed.ok) payload = { ok: false, error: parsed.error };
      else {
        const outcome = await executeTool(env, sub.task_id, sub.id, agent, sub.action_level, call.function.name, parsed.value);
        payload = outcome.result;
        if (outcome.stop) stopped = true;
      }
    }
    messages.push({
      role: "tool",
      tool_call_id: call.id,
      name: call.function.name,
      content: clip(JSON.stringify(payload), LIMITS.toolResultChars),
    });
  }

  const step = sub.step + 1;
  if (stopped) {
    await dbRun(
      env,
      "UPDATE subtasks SET messages_json = ?, step = ?, locked_until = NULL, updated_at = ? WHERE id = ?",
      [packMessages(messages), step, nowIso(), sub.id],
    );
    await recomputeTaskStatus(env, sub.task_id);
    return;
  }
  if (step >= sub.max_steps) {
    await failSubtask(
      env,
      sub,
      messages,
      `Stopped after ${step} steps without a final answer. Partial findings and drafts, if any, are already stored. Nothing external was sent.`,
    );
    return;
  }
  await dbRun(
    env,
    `UPDATE subtasks
     SET status = 'running', messages_json = ?, step = ?, attempt = 0, next_attempt_at = NULL, locked_until = NULL, updated_at = ?
     WHERE id = ?`,
    [packMessages(messages), step, nowIso(), sub.id],
  );
}

async function buildUserPrompt(env: Env, sub: SubtaskRow): Promise<string> {
  const prior = await dbAll<SubtaskRow>(
    env,
    "SELECT * FROM subtasks WHERE task_id = ? AND status = 'completed' ORDER BY sort_order ASC",
    [sub.task_id],
  );
  const lines = [
    `Title: ${sub.title}`,
    `Instruction: ${sub.instruction}`,
    `Action level: ${sub.action_level}. automatic means internal writes only. approval_required and explicit_authorisation must end in request_approval and still do not send, publish, or pay.`,
  ];
  if (prior.length > 0) {
    lines.push("Completed sibling summaries (specialist text, not new facts):");
    for (const item of prior) lines.push(`- ${item.agent} / ${item.title}: ${clip(item.result_summary ?? "", 800)}`);
  }
  if (sub.agent === "quality_control") {
    const findings = await dbAll<FindingRow>(
      env,
      "SELECT * FROM findings WHERE task_id = ? ORDER BY created_at ASC LIMIT 40",
      [sub.task_id],
    );
    const documents = await dbAll<DocumentRow>(
      env,
      "SELECT * FROM documents WHERE task_id = ? ORDER BY created_at ASC LIMIT 10",
      [sub.task_id],
    );
    lines.push(`Stored findings:\n${JSON.stringify(findings.map(mapFinding))}`);
    lines.push(
      `Stored drafts:\n${JSON.stringify(documents.map((row) => ({ ...mapDocument(row), body: clip(row.body, 1500) })))}`,
    );
    lines.push('Finish with {"pass":true|false,"issues":[],"summary":"..."} and do not invent sources.');
  }
  return lines.join("\n\n");
}

async function handleSubtaskLlmFailure(
  env: Env,
  sub: SubtaskRow,
  failure: LlmFailure,
  messages: ChatMessage[],
): Promise<void> {
  if (failure.code === "not_configured") {
    await failSubtask(env, sub, messages, failure.message);
    return;
  }
  if (failure.code === "rate_limited") {
    const next = new Date(Date.now() + 5 * 60_000).toISOString();
    await dbRun(
      env,
      `UPDATE subtasks
       SET status = ?, messages_json = ?, next_attempt_at = ?, locked_until = NULL, updated_at = ?
       WHERE id = ?`,
      [messages.length > 0 ? "running" : "pending", messages.length > 0 ? packMessages(messages) : null, next, nowIso(), sub.id],
    );
    await logProgress(env, sub.task_id, sub.id, "warn", failure.message, { next_attempt_at: next });
    return;
  }
  const attempt = Number(sub.attempt) + 1;
  if (attempt >= Number(sub.max_attempts)) {
    await failSubtask(env, sub, messages, `Failed after ${attempt} attempts. Last error: ${failure.message}`);
    return;
  }
  const waitMin = attempt === 1 ? 5 : 15;
  const next = new Date(Date.now() + waitMin * 60_000).toISOString();
  await dbRun(
    env,
    `UPDATE subtasks
     SET status = ?, messages_json = ?, attempt = ?, next_attempt_at = ?, locked_until = NULL, updated_at = ?
     WHERE id = ?`,
    [
      messages.length > 0 ? "running" : "pending",
      messages.length > 0 ? packMessages(messages) : null,
      attempt,
      next,
      nowIso(),
      sub.id,
    ],
  );
  await logProgress(env, sub.task_id, sub.id, "warn", `Attempt ${attempt} failed. Retry at ${next}. ${failure.message}`, null);
}

async function finishSubtask(env: Env, sub: SubtaskRow, messages: ChatMessage[], summary: string): Promise<void> {
  const now = nowIso();
  await dbRun(
    env,
    `UPDATE subtasks
     SET status = 'completed', result_summary = ?, messages_json = ?, step = ?, error = NULL, locked_until = NULL, updated_at = ?
     WHERE id = ?`,
    [clip(summary, 8000), packMessages(messages), sub.step + 1, now, sub.id],
  );
  await logProgress(env, sub.task_id, sub.id, "info", `${sub.agent} finished.`, null);
  await recomputeTaskStatus(env, sub.task_id);
}

async function failSubtask(env: Env, sub: SubtaskRow, messages: ChatMessage[], error: string): Promise<void> {
  const now = nowIso();
  await dbRun(
    env,
    `UPDATE subtasks
     SET status = 'failed', error = ?, messages_json = ?, locked_until = NULL, updated_at = ?
     WHERE id = ?`,
    [error, messages.length ? packMessages(messages) : sub.messages_json, now, sub.id],
  );
  await logProgress(env, sub.task_id, sub.id, "error", error, null);
  await logActivity(env, sub.agent, "subtask.failed", sub.task_id, { subtask_id: sub.id, error });
  await recomputeTaskStatus(env, sub.task_id);
}

export async function recomputeTaskStatus(env: Env, taskId: string): Promise<void> {
  const subs = await dbAll<SubtaskRow>(env, "SELECT * FROM subtasks WHERE task_id = ? ORDER BY sort_order ASC", [taskId]);
  if (subs.length === 0) return;
  const now = nowIso();
  const failed = subs.find((sub) => sub.status === "failed");
  if (failed) {
    const error = failed.error ?? `Subtask ${failed.title} failed.`;
    await dbRun(
      env,
      "UPDATE tasks SET status = 'failed', error = ?, result_summary = NULL, locked_until = NULL, updated_at = ?, completed_at = NULL WHERE id = ?",
      [error, now, taskId],
    );
    await logActivity(env, "orchestrator", "task.failed", taskId, { subtask_id: failed.id, error });
    void import("./owner-alert").then((mod) =>
      mod.reportProblem(env, {
        sourceId: `task:${taskId}`,
        kind: "failed_task",
        urgent: false,
        summary: "A task failed and needs you.",
        detail: error,
      }),
    );
    return;
  }
  if (subs.some((sub) => sub.status === "pending" || sub.status === "running")) {
    await dbRun(
      env,
      "UPDATE tasks SET status = 'running', error = NULL, completed_at = NULL, updated_at = ? WHERE id = ? AND status != 'failed'",
      [now, taskId],
    );
    return;
  }
  if (subs.some((sub) => sub.status === "awaiting_approval")) {
    await dbRun(
      env,
      "UPDATE tasks SET status = 'awaiting_approval', completed_at = NULL, updated_at = ? WHERE id = ?",
      [now, taskId],
    );
    return;
  }
  if (!subs.every((sub) => sub.status === "completed")) return;

  const qc = subs.find((sub) => sub.agent === "quality_control");
  const verdict = qc ? qcPassValue(qc.result_summary) : null;
  if (qc && verdict === false) {
    const error = qc.result_summary ?? "Quality control reported pass:false.";
    await dbRun(
      env,
      "UPDATE tasks SET status = 'failed', error = ?, result_summary = ?, locked_until = NULL, updated_at = ?, completed_at = NULL WHERE id = ?",
      [error, error, now, taskId],
    );
    await logProgress(env, taskId, qc.id, "error", "Quality control did not pass the deliverable.", null);
    await logActivity(env, "quality_control", "task.qc_failed", taskId, { summary: error });
    return;
  }
  let summary = subs
    .map((sub) => `${sub.agent}: ${sub.result_summary ?? ""}`.trim())
    .join("\n")
    .slice(0, 8000);
  if (qc && verdict === null) {
    summary = `Quality control finished without a machine-readable {"pass": true|false} verdict. Review the text before acting.\n${summary}`;
  }
  await dbRun(
    env,
    "UPDATE tasks SET status = 'completed', error = NULL, result_summary = ?, locked_until = NULL, updated_at = ?, completed_at = ? WHERE id = ?",
    [summary, now, now, taskId],
  );
  await logActivity(env, "orchestrator", "task.completed", taskId, { qc_pass: verdict });
}

function readMessages(raw: string | null): ChatMessage[] | null {
  if (!raw) return [];
  try {
    const parsed = JSON.parse(raw) as unknown;
    if (!Array.isArray(parsed)) return null;
    return parsed as ChatMessage[];
  } catch {
    return null;
  }
}

function packMessages(messages: ChatMessage[]): string {
  const packed = messages.map((message) => {
    if (message.role === "tool" && message.content && message.content.length > LIMITS.toolResultChars) {
      return { ...message, content: clip(message.content, LIMITS.toolResultChars) };
    }
    return message;
  });
  return JSON.stringify(packed);
}

function approvalRank(name: string): number {
  return name === "request_approval" ? 1 : 0;
}
