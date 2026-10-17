import { logActivity, dbAll, dbFirst, dbRun } from "./db";
import { apiError, asString, clip, isRecord, json, newId, nowIso, readJson } from "./http";
import type { ChatMessage } from "./llm";
import { completeChat } from "./llm";
import { executeTool, parseToolArgs, toolsForNames } from "./tools";
import type { Env } from "./types";
import { LIMITS } from "./types";

interface PersonaRow {
  id: string;
  name: string;
  role: string;
  instructions: string;
  avatar: string;
  color_hex: string;
  memory: string;
  builtin: number;
  created_at: string;
  updated_at: string;
  tools_json?: string | null;
  voice_id?: string | null;
  voice_name?: string | null;
}

export const PERSONA_TOOL_NAMES = [
  "web_search",
  "fetch_url",
  "save_finding",
  "save_lead",
  "draft_document",
  "request_approval",
  "list_findings",
  "list_documents",
  "list_pipeline",
  "memory",
  "draft_call",
  "reminder",
  "files",
  "image_gen",
] as const;

const DEFAULT_TOOLS: Record<string, string[]> = {
  agent_jarvis: ["list_findings", "list_pipeline", "request_approval", "memory", "reminder"],
  agent_edith: ["web_search", "fetch_url", "save_finding", "save_lead", "list_findings", "memory"],
  agent_ultron: ["list_findings", "list_pipeline", "draft_document", "request_approval", "draft_call", "memory"],
  agent_friday: ["web_search", "fetch_url", "draft_document", "reminder", "request_approval", "memory"],
};

const MAX_PERSONA_STEPS = 3;
const PARALLEL_PERSONA_STEPS = 3;

interface TaskRow {
  id: string;
  agent_id: string;
  goal: string;
  status: string;
  result: string | null;
  approval_summary: string | null;
  created_at: string;
  updated_at: string;
}

const DEFAULTS: Array<Omit<PersonaRow, "memory" | "created_at" | "updated_at">> = [
  {
    id: "agent_jarvis",
    name: "J.A.R.V.I.S.",
    role: "Chief of staff",
    instructions:
      "Plan the mission, delegate to EDITH, ULTRON, and FRIDAY, check what they stored, and report back. Any send, spend, publish, or call stays a draft until Sohail approves it. You do not send, publish, spend, or dial.",
    avatar: "J",
    color_hex: "4BA8EE",
    builtin: 1,
  },
  {
    id: "agent_edith",
    name: "E.D.I.T.H.",
    role: "Research and intelligence",
    instructions:
      "Do deep research with web search and opened pages. Build prospect dossiers only from those pages and keep the source URL on every claim. Do not contact anyone, and do not invent companies, prices, or emails.",
    avatar: "E",
    color_hex: "7AA2FF",
    builtin: 1,
  },
  {
    id: "agent_ultron",
    name: "U.L.T.R.O.N.",
    role: "Sales and strategy",
    instructions:
      "Draft pitch outlines, pricing notes, proposals, and outreach from stored findings. Leave every send as a draft. Do not email, publish, or spend.",
    avatar: "U",
    color_hex: "E15B64",
    builtin: 1,
  },
  {
    id: "agent_friday",
    name: "F.R.I.D.A.Y.",
    role: "Builder and operations",
    instructions:
      "Draft landing pages, HTML, code snippets, automations, and schedules. Do not publish a site, run a payment, or send a message.",
    avatar: "F",
    color_hex: "C9A227",
    builtin: 1,
  },
];

export async function routePersona(
  request: Request,
  env: Env,
  path: string,
  parts: string[],
): Promise<Response | null> {
  if (
    parts[0] !== "agents" &&
    parts[0] !== "agent-tasks" &&
    parts[0] !== "group" &&
    parts[0] !== "missions" &&
    parts[0] !== "routines" &&
    parts[0] !== "rooms" &&
    parts[0] !== "reminders"
  ) {
    return null;
  }
  await ensurePersonas(env);
  if (parts[0] !== "agents" && parts[0] !== "agent-tasks") {
    const { routeMissionApi } = await import("./missions");
    return routeMissionApi(request, env, path, parts);
  }

  if (request.method === "GET" && path === "/agents") {
    const rows = await loadAgents(env);
    return json({ agents: rows.map(mapAgent) });
  }
  if (request.method === "POST" && path === "/agents") return createAgent(request, env);
  if (request.method === "POST" && parts[0] === "agents" && parts[1] && parts.length === 2) {
    return updateAgent(request, env, parts[1]);
  }
  if (request.method === "DELETE" && parts[0] === "agents" && parts[1] && parts.length === 2) {
    return deleteAgent(env, parts[1]);
  }
  if (request.method === "GET" && parts[0] === "agents" && parts[2] === "messages" && parts.length === 3) {
    return listMessages(env, parts[1]);
  }
  if (request.method === "POST" && parts[0] === "agents" && parts[2] === "messages" && parts.length === 3) {
    return addMessage(request, env, parts[1]);
  }
  if (request.method === "GET" && path === "/agent-tasks") {
    const rows = await dbAll<TaskRow>(env, "SELECT * FROM persona_tasks ORDER BY created_at DESC LIMIT 40");
    return json({ tasks: rows.map(mapTask) });
  }
  if (request.method === "POST" && path === "/agent-tasks") return enqueue(request, env);
  if (request.method === "POST" && parts[0] === "agent-tasks" && parts[2] === "approve" && parts.length === 3) {
    return settle(env, parts[1], true);
  }
  if (request.method === "POST" && parts[0] === "agent-tasks" && parts[2] === "decline" && parts.length === 3) {
    return settle(env, parts[1], false);
  }
  return null;
}

export async function runPersonaTick(env: Env): Promise<void> {
  await ensurePersonas(env);
  const now = nowIso();
  const candidates = await dbAll<TaskRow>(
    env,
    `SELECT t.* FROM persona_tasks t
     LEFT JOIN persona_task_state s ON s.task_id = t.id
     WHERE t.status = 'queued'
        OR (t.status = 'working' AND (s.locked_until IS NULL OR s.locked_until < ?))
     ORDER BY t.created_at
     LIMIT ?`,
    [now, PARALLEL_PERSONA_STEPS],
  );
  const claimed: TaskRow[] = [];
  for (const task of candidates) {
    if (claimed.length >= PARALLEL_PERSONA_STEPS) break;
    if (await claimPersona(env, task)) claimed.push(task);
  }
  await Promise.all(claimed.map((task) => stepPersona(env, task)));
}

async function claimPersona(env: Env, task: TaskRow): Promise<boolean> {
  const lockUntil = new Date(Date.now() + LIMITS.lockMs).toISOString();
  if (task.status === "queued") {
    const claimed = await dbRun(
      env,
      "UPDATE persona_tasks SET status = 'working', updated_at = ? WHERE id = ? AND status = 'queued'",
      [nowIso(), task.id],
    );
    if (claimed !== 1) return false;
    await dbRun(
      env,
      `INSERT INTO persona_task_state (task_id, messages_json, step, locked_until)
       VALUES (?, '[]', 0, ?)
       ON CONFLICT(task_id) DO UPDATE SET locked_until = excluded.locked_until`,
      [task.id, lockUntil],
    );
    return true;
  }
  const claimed = await dbRun(
    env,
    `UPDATE persona_task_state SET locked_until = ?
     WHERE task_id = ? AND (locked_until IS NULL OR locked_until < ?)`,
    [lockUntil, task.id, nowIso()],
  );
  return claimed === 1;
}

async function stepPersona(env: Env, task: TaskRow): Promise<void> {
  const agent = await loadAgent(env, task.agent_id);
  if (!agent) {
    await finish(env, task, "done", "That agent is no longer on the roster.");
    return;
  }
  const state = await dbFirst<{ messages_json: string; step: number }>(
    env,
    "SELECT messages_json, step FROM persona_task_state WHERE task_id = ?",
    [task.id],
  );
  const messages = readPersonaMessages(state?.messages_json);
  const step = state?.step ?? 0;
  if (messages.length === 0) {
    messages.push({ role: "system", content: systemPrompt(agent, goalNeedsApproval(visibleGoal(task.goal))) });
    messages.push({ role: "user", content: visibleGoal(task.goal) });
  }
  const tools = personaToolDefs(agent);
  const llm = await completeChat(env, messages, tools.length ? tools : null);
  if (!llm.ok) {
    if (llm.code === "rate_limited" || llm.code === "timeout") {
      await dbRun(env, "UPDATE persona_task_state SET locked_until = NULL WHERE task_id = ?", [task.id]);
      if (step === 0) {
        await dbRun(env, "UPDATE persona_tasks SET status = 'queued', updated_at = ? WHERE id = ?", [nowIso(), task.id]);
      }
      return;
    }
    await finish(env, task, "done", llm.message);
    return;
  }
  messages.push({ role: "assistant", content: llm.message.content, tool_calls: llm.message.tool_calls });
  const calls = llm.message.tool_calls ?? [];
  if (calls.length === 0) {
    const text = (llm.message.content ?? "").trim() || "I have nothing to add.";
    await finishPersonaText(env, task, agent, text);
    return;
  }
  let stopped = false;
  let approvalSummary = "";
  for (let i = 0; i < calls.length; i++) {
    const call = calls[i];
    let payload: unknown;
    if (i >= LIMITS.maxToolCallsExecuted) {
      payload = { ok: false, error: `Only ${LIMITS.maxToolCallsExecuted} tool calls run per step.` };
    } else if (stopped) {
      payload = { ok: false, error: "Not run. An approval already ended this step. Nothing external was sent." };
    } else {
      const parsed = parseToolArgs(call.function.arguments);
      if (!parsed.ok) payload = { ok: false, error: parsed.error };
      else {
        const outcome = await runPersonaTool(env, agent, task, call.function.name, parsed.value);
        payload = outcome.result;
        if (outcome.stop) {
          stopped = true;
          const record = isRecord(outcome.result) ? outcome.result : {};
          approvalSummary = typeof record.summary === "string" ? record.summary : "Approval required. Nothing was sent.";
        }
      }
    }
    messages.push({
      role: "tool",
      tool_call_id: call.id,
      name: call.function.name,
      content: clip(JSON.stringify(payload), LIMITS.toolResultChars),
    });
  }
  const nextStep = step + 1;
  if (stopped) {
    await savePersonaState(env, task.id, messages, nextStep, null);
    await markNeedsApproval(env, task, agent, approvalSummary || "Approval required. Nothing was sent, published, or paid.");
    return;
  }
  if (nextStep >= MAX_PERSONA_STEPS) {
    await finish(
      env,
      task,
      "done",
      "Stopped after 3 steps. Partial notes are stored. Nothing was sent, published, or paid.",
    );
    return;
  }
  await savePersonaState(env, task.id, messages, nextStep, null);
  await dbRun(env, "UPDATE persona_tasks SET status = 'working', updated_at = ? WHERE id = ?", [nowIso(), task.id]);
}

async function createAgent(request: Request, env: Env): Promise<Response> {
  const body = await readJson(request);
  if (!body.ok) return body.response;
  if (!isRecord(body.value)) return apiError(400, "bad_request", "JSON body must be an object.");
  const name = asString(body.value.name, 80);
  const role = asString(body.value.role, 120);
  const instructions = asString(body.value.instructions, 4000);
  if (!name || !role || !instructions) return apiError(400, "bad_request", "name, role, and instructions are required.");
  const requested = typeof body.value.id === "string" && body.value.id.startsWith("agent_") ? body.value.id : "";
  const avatar = typeof body.value.avatar === "string" && body.value.avatar ? body.value.avatar.slice(0, 4) : name.slice(0, 1);
  const color = typeof body.value.color_hex === "string" ? body.value.color_hex : "4BA8EE";
  const memory = typeof body.value.memory === "string" ? body.value.memory : "";
  const now = nowIso();
  if (requested) {
    const existing = await dbFirst<PersonaRow>(env, "SELECT id FROM persona_agents WHERE id = ?", [requested]);
    if (existing) {
      await dbRun(
        env,
        `UPDATE persona_agents SET name = ?, role = ?, instructions = ?, memory = ?, avatar = ?, color_hex = ?, updated_at = ? WHERE id = ?`,
        [name, role, instructions, memory, avatar, color, now, requested],
      );
      await writeProfile(env, requested, sanitizeTools(body.value.tools, DEFAULT_TOOLS[requested] ?? ["memory"]), voiceFields(body.value));
      const row = await loadAgent(env, requested);
      return json({ agent: row ? mapAgent(row) : null });
    }
  }
  const id = requested || newId("agent");
  await dbRun(
    env,
    `INSERT INTO persona_agents (id, name, role, instructions, avatar, color_hex, memory, builtin, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?)`,
    [id, name, role, instructions, avatar, color, memory, now, now],
  );
  await writeProfile(env, id, sanitizeTools(body.value.tools, ["memory"]), voiceFields(body.value));
  const row = await loadAgent(env, id);
  return json({ agent: row ? mapAgent(row) : null }, 201);
}

async function updateAgent(request: Request, env: Env, id: string): Promise<Response> {
  const existing = await dbFirst<PersonaRow>(env, "SELECT * FROM persona_agents WHERE id = ?", [id]);
  if (!existing) return apiError(404, "not_found", "No agent with that id.");
  const body = await readJson(request);
  if (!body.ok) return body.response;
  if (!isRecord(body.value)) return apiError(400, "bad_request", "JSON body must be an object.");
  const name = typeof body.value.name === "string" && body.value.name.trim() ? body.value.name.trim() : existing.name;
  const role = typeof body.value.role === "string" && body.value.role.trim() ? body.value.role.trim() : existing.role;
  const instructions =
    typeof body.value.instructions === "string" && body.value.instructions.trim()
      ? body.value.instructions.trim()
      : existing.instructions;
  const memory = typeof body.value.memory === "string" ? body.value.memory : existing.memory;
  const avatar = typeof body.value.avatar === "string" && body.value.avatar ? body.value.avatar.slice(0, 4) : existing.avatar;
  const color = typeof body.value.color_hex === "string" ? body.value.color_hex : existing.color_hex;
  const now = nowIso();
  await dbRun(
    env,
    `UPDATE persona_agents SET name = ?, role = ?, instructions = ?, memory = ?, avatar = ?, color_hex = ?, updated_at = ? WHERE id = ?`,
    [name, role, instructions, memory, avatar, color, now, id],
  );
  const current = await loadAgent(env, id);
  const tools = sanitizeTools(body.value.tools, parseTools(current?.tools_json, id));
  const voice = voiceFields(body.value, current?.voice_id ?? "", current?.voice_name ?? "");
  await writeProfile(env, id, tools, voice);
  const row = await loadAgent(env, id);
  return json({ agent: row ? mapAgent(row) : null });
}

async function deleteAgent(env: Env, id: string): Promise<Response> {
  const changes = await dbRun(env, "DELETE FROM persona_agents WHERE id = ?", [id]);
  if (!changes) return apiError(404, "not_found", "No agent with that id.");
  await dbRun(env, "DELETE FROM persona_messages WHERE agent_id = ?", [id]);
  await dbRun(env, "DELETE FROM persona_profiles WHERE agent_id = ?", [id]);
  return json({ deleted: true });
}

async function listMessages(env: Env, agentId: string): Promise<Response> {
  const agent = await dbFirst<PersonaRow>(env, "SELECT id FROM persona_agents WHERE id = ?", [agentId]);
  if (!agent) return apiError(404, "not_found", "No agent with that id.");
  const rows = await dbAll<{ id: string; role: string; author: string; text: string; created_at: string }>(
    env,
    "SELECT id, role, author, text, created_at FROM persona_messages WHERE agent_id = ? ORDER BY created_at LIMIT 80",
    [agentId],
  );
  return json({
    messages: rows.map((row) => ({
      id: row.id,
      role: row.role,
      author: row.author,
      text: row.text,
      created_at: row.created_at,
    })),
  });
}

async function addMessage(request: Request, env: Env, agentId: string): Promise<Response> {
  const agent = await dbFirst<PersonaRow>(env, "SELECT * FROM persona_agents WHERE id = ?", [agentId]);
  if (!agent) return apiError(404, "not_found", "No agent with that id.");
  const body = await readJson(request);
  if (!body.ok) return body.response;
  if (!isRecord(body.value)) return apiError(400, "bad_request", "JSON body must be an object.");
  const text = asString(body.value.text, 4000);
  if (!text) return apiError(400, "bad_request", "text is required.");
  const author = typeof body.value.author === "string" && body.value.author ? body.value.author : "You";
  const role = typeof body.value.role === "string" ? body.value.role : "user";
  await remember(env, agentId, role, author, text);
  return json({ ok: true }, 201);
}

async function enqueue(request: Request, env: Env): Promise<Response> {
  const body = await readJson(request);
  if (!body.ok) return body.response;
  if (!isRecord(body.value)) return apiError(400, "bad_request", "JSON body must be an object.");
  const goal = asString(body.value.goal, 4000);
  if (!goal) return apiError(400, "bad_request", "goal is required.");
  const agentId = typeof body.value.agent_id === "string" ? body.value.agent_id : "";
  const agent = await dbFirst<PersonaRow>(env, "SELECT * FROM persona_agents WHERE id = ?", [agentId]);
  if (!agent) return apiError(404, "not_found", "No agent with that id.");
  const id = typeof body.value.id === "string" && body.value.id.startsWith("job_") ? body.value.id : newId("job");
  const row = await queuePersonaTask(env, agent.id, goal, id);
  return json({ task: row ? mapTask(row) : null }, row && row.id === id ? 201 : 200);
}

async function settle(env: Env, id: string, approved: boolean): Promise<Response> {
  const task = await dbFirst<TaskRow>(env, "SELECT * FROM persona_tasks WHERE id = ?", [id]);
  if (!task) return apiError(404, "not_found", "No agent task with that id.");
  const note = approved
    ? "Approved as a draft. Nothing was sent, published, or paid."
    : "Declined. Nothing was sent, published, or paid.";
  const result = [task.approval_summary, note].filter(Boolean).join("\n\n");
  await finish(env, task, "done", result);
  await closePersonaApproval(env, id, approved);
  return json({ task: mapTask({ ...task, status: "done", result, updated_at: nowIso() }), external_action_taken: false });
}

export async function markPersonaDraft(env: Env, taskId: string, approved: boolean): Promise<void> {
  const task = await dbFirst<TaskRow>(env, "SELECT * FROM persona_tasks WHERE id = ?", [taskId]);
  if (!task || task.status === "done") {
    await closePersonaApproval(env, taskId, approved);
    return;
  }
  const note = approved
    ? "Approved as a draft. Nothing was sent, published, or paid."
    : "Declined. Nothing was sent, published, or paid.";
  const result = [task.approval_summary, note].filter(Boolean).join("\n\n");
  await finish(env, task, "done", result);
  await closePersonaApproval(env, taskId, approved);
}

async function closePersonaApproval(env: Env, taskId: string, approved: boolean): Promise<void> {
  if (!/^[A-Za-z0-9_-]+$/.test(taskId)) return;
  await dbRun(
    env,
    `UPDATE approvals SET status = ?, decided_at = ?
     WHERE action = 'persona_external' AND status = 'pending' AND payload_json LIKE ?`,
    [approved ? "approved" : "rejected", nowIso(), `%"persona_task_id":"${taskId}"%`],
  );
}

const LEGACY_INSTRUCTIONS: Record<string, string[]> = {
  agent_jarvis: [
    "Coordinate the other agents, break a request into assignments, and report back in a few sentences. You draft plans. You do not send, publish, or spend.",
    "Coordinate the other agents, break a request into assignments, and report back in a few sentences. Draft plans only. Do not send, publish, or spend.",
  ],
  agent_edith: ["Research the question, name sources when you have them, and draft lead notes. Do not contact anyone."],
  agent_ultron: ["Draft outreach, proposals, and follow-ups. Leave them as drafts. Never send them."],
  agent_friday: ["Draft page structure, copy, and design notes. Never publish a site or post."],
};

export async function ensurePersonas(env: Env): Promise<void> {
  const now = nowIso();
  for (const agent of DEFAULTS) {
    const existing = await dbFirst<{ id: string; instructions: string }>(
      env,
      "SELECT id, instructions FROM persona_agents WHERE id = ?",
      [agent.id],
    );
    if (!existing) {
      await dbRun(
        env,
        `INSERT INTO persona_agents (id, name, role, instructions, avatar, color_hex, memory, builtin, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, '', ?, ?, ?)`,
        [agent.id, agent.name, agent.role, agent.instructions, agent.avatar, agent.color_hex, agent.builtin, now, now],
      );
    } else if ((LEGACY_INSTRUCTIONS[agent.id] ?? []).includes(existing.instructions)) {
      await dbRun(
        env,
        "UPDATE persona_agents SET role = ?, instructions = ?, updated_at = ? WHERE id = ?",
        [agent.role, agent.instructions, now, agent.id],
      );
    }
    await ensureProfile(env, agent.id, DEFAULT_TOOLS[agent.id] ?? ["memory"]);
  }
}

export async function queuePersonaTask(env: Env, agentId: string, goal: string, id?: string): Promise<TaskRow | null> {
  const agent = await dbFirst<{ id: string }>(env, "SELECT id FROM persona_agents WHERE id = ?", [agentId]);
  if (!agent) return null;
  const taskId = id && id.startsWith("job_") ? id : newId("job");
  const existing = await dbFirst<TaskRow>(env, "SELECT * FROM persona_tasks WHERE id = ?", [taskId]);
  if (existing) return existing;
  const now = nowIso();
  await dbRun(
    env,
    `INSERT INTO persona_tasks (id, agent_id, goal, status, result, approval_summary, created_at, updated_at)
     VALUES (?, ?, ?, 'queued', NULL, NULL, ?, ?)`,
    [taskId, agentId, goal, now, now],
  );
  await remember(env, agentId, "user", "You", visibleGoal(goal));
  await logActivity(env, "jarvis", "persona.queued", taskId, { agent_id: agentId });
  return dbFirst<TaskRow>(env, "SELECT * FROM persona_tasks WHERE id = ?", [taskId]);
}

async function finish(env: Env, task: TaskRow, status: string, result: string): Promise<void> {
  await dbRun(env, "UPDATE persona_tasks SET status = ?, result = ?, updated_at = ? WHERE id = ?", [
    status,
    result,
    nowIso(),
    task.id,
  ]);
  await dbRun(env, "UPDATE persona_task_state SET locked_until = NULL WHERE task_id = ?", [task.id]);
  await logActivity(env, "agent", status === "needs_approval" ? "persona.needs_approval" : "persona.done", task.id, {
    summary: clip(result, 240),
  });
  if (!task.goal.startsWith("room:")) return;
  const agent = await loadAgent(env, task.agent_id);
  const { readRoomGoal, deliverRoomResult } = await import("./missions");
  const room = readRoomGoal(task.goal);
  if (!room) return;
  await deliverRoomResult(env, room.roomId, agent?.name ?? "Agent", result, room.hop);
}

async function remember(env: Env, agentId: string, role: string, author: string, text: string): Promise<void> {
  await dbRun(
    env,
    "INSERT INTO persona_messages (id, agent_id, role, author, text, created_at) VALUES (?, ?, ?, ?, ?, ?)",
    [newId("msg"), agentId, role, author, text, nowIso()],
  );
}

function systemPrompt(agent: PersonaRow, external: boolean): string {
  const tools = parseTools(agent.tools_json, agent.id);
  const guard = external
    ? "The request would send, publish, spend, or place a call. Start your reply with APPROVAL: and give the draft only. Do not claim you sent, published, paid, or dialled."
    : "If you are asked to send, publish, spend, or place a call, start your reply with APPROVAL: and give the draft only.";
  return [
    `You are ${agent.name}, ${agent.role}. ${agent.instructions}`,
    `Memory:\n${agent.memory || "(none)"}`,
    tools.length ? `Enabled tools: ${tools.join(", ")}.` : "You have no tools. Answer from the goal and your memory.",
    "files and image_gen stay on the iPhone. If they are enabled, say so and do not claim a file or image was made.",
    "web_search hits are not facts. fetch_url before you state what a page says. save_finding needs source URLs.",
    guard,
  ].join("\n");
}

export function goalNeedsApproval(goal: string): boolean {
  const lower = goal.toLowerCase();
  const needles = [
    "send ",
    "email them",
    "publish",
    "post this",
    "spend",
    "pay ",
    "purchase",
    "wire ",
    "tweet",
    "place a call",
    "phone them",
    "ring them",
    "dial ",
    "call them",
    "outbound call",
  ];
  return needles.some((needle) => lower.includes(needle));
}

function visibleGoal(goal: string): string {
  const match = goal.match(/^room:[A-Za-z0-9_-]+\nhop:\d+\n([\s\S]*)$/);
  return match ? match[1] : goal;
}

async function finishPersonaText(env: Env, task: TaskRow, agent: PersonaRow, text: string): Promise<void> {
  const approval = goalNeedsApproval(visibleGoal(task.goal)) || text.toUpperCase().startsWith("APPROVAL:");
  if (approval) {
    const summary = text.replace(/^APPROVAL:\s*/i, "").trim() || text;
    await markNeedsApproval(env, task, agent, summary);
    return;
  }
  await remember(env, agent.id, "agent", agent.name, text);
  await finish(env, task, "done", text);
}

async function markNeedsApproval(env: Env, task: TaskRow, agent: PersonaRow, summary: string): Promise<void> {
  const clean = summary.trim() || "Approval required. Nothing was sent, published, paid, or dialled.";
  await dbRun(
    env,
    "UPDATE persona_tasks SET status = 'needs_approval', result = ?, approval_summary = ?, updated_at = ? WHERE id = ?",
    [clean, clean, nowIso(), task.id],
  );
  await dbRun(
    env,
    `INSERT INTO approvals
      (id, task_id, subtask_id, action, level, summary, payload_json, status, reason, created_at, decided_at)
     VALUES (?, NULL, NULL, 'persona_external', 'approval_required', ?, ?, 'pending', NULL, ?, NULL)`,
    [newId("apr"), clean, JSON.stringify({ persona_task_id: task.id, external_action_taken: false }), nowIso()],
  );
  await remember(env, agent.id, "agent", agent.name, clean);
  await logActivity(env, "agent", "persona.needs_approval", task.id, { summary: clip(clean, 240) });
  if (task.goal.startsWith("room:")) {
    const { readRoomGoal, deliverRoomResult } = await import("./missions");
    const room = readRoomGoal(task.goal);
    if (room) await deliverRoomResult(env, room.roomId, agent.name, clean, room.hop);
  }
}

async function runPersonaTool(
  env: Env,
  agent: PersonaRow,
  task: TaskRow,
  name: string,
  args: Record<string, unknown>,
): Promise<{ result: unknown; stop: boolean }> {
  const allowed = parseTools(agent.tools_json, agent.id);
  if (!allowed.includes(name)) {
    return { stop: false, result: { ok: false, error: `Tool ${name} is not enabled for ${agent.name}.` } };
  }
  if (name === "memory") {
    const note = typeof args.note === "string" ? args.note.trim() : "";
    if (!note) return { stop: false, result: { ok: true, memory: agent.memory || "" } };
    const next = clip(agent.memory ? `${agent.memory}\n${note}` : note, 4000);
    await dbRun(env, "UPDATE persona_agents SET memory = ?, updated_at = ? WHERE id = ?", [next, nowIso(), agent.id]);
    return { stop: false, result: { ok: true, stored: true } };
  }
  if (name === "reminder") {
    const text = typeof args.text === "string" ? args.text.trim() : "";
    if (!text) return { stop: false, result: { ok: false, error: "text is required." } };
    const due = typeof args.due_at === "string" ? args.due_at.slice(0, 40) : null;
    const id = newId("rem");
    await dbRun(
      env,
      "INSERT INTO reminders (id, agent_id, text, due_at, status, created_at) VALUES (?, ?, ?, ?, 'open', ?)",
      [id, agent.id, clip(text, 500), due, nowIso()],
    );
    await logActivity(env, agent.name, "reminder.saved", task.id, { id });
    return { stop: false, result: { ok: true, id, note: "Reminder stored. Nothing was sent." } };
  }
  if (name === "draft_call" || name === "request_approval") {
    const summary = clip(typeof args.summary === "string" ? args.summary : visibleGoal(task.goal), 2000);
    const label = name === "draft_call" ? "Draft a call. Nothing was dialled." : "Draft only. Nothing was sent, published, or paid.";
    return { stop: true, result: { ok: true, approval_required: true, summary: `${label} ${summary}`.trim(), external_action_taken: false } };
  }
  if (name === "files" || name === "image_gen") {
    return {
      stop: false,
      result: { ok: false, error: "Files and image generation stay on the iPhone. Nothing was uploaded or generated." },
    };
  }
  return executeTool(env, task.id, task.id, "admin", "approval_required", name, args, allowed);
}

function personaToolDefs(agent: PersonaRow) {
  const names = parseTools(agent.tools_json, agent.id);
  const specs = toolsForNames(names);
  const extra: Array<{ type: "function"; function: { name: string; description: string; parameters: Record<string, unknown> } }> = [];
  if (names.includes("memory")) {
    extra.push(toolDef("memory", "Read this agent's memory, or store a short note.", { note: { type: "string" } }, []));
  }
  if (names.includes("reminder")) {
    extra.push(toolDef("reminder", "Store a reminder. This does not send a message.", { text: { type: "string" }, due_at: { type: "string" } }, ["text"]));
  }
  if (names.includes("draft_call")) {
    extra.push(toolDef("draft_call", "Queue a call draft for approval. This does not dial.", { contact: { type: "string" }, summary: { type: "string" } }, ["summary"]));
  }
  if (names.includes("files")) {
    extra.push(toolDef("files", "Files stay on the iPhone. Calling this does not upload anything.", {}, []));
  }
  if (names.includes("image_gen")) {
    extra.push(toolDef("image_gen", "Image generation stays on the iPhone. Calling this does not generate an image.", { prompt: { type: "string" } }, []));
  }
  return [...specs, ...extra];
}

function toolDef(name: string, description: string, properties: Record<string, unknown>, required: string[]) {
  return {
    type: "function" as const,
    function: {
      name,
      description,
      parameters: { type: "object", properties, required, additionalProperties: false },
    },
  };
}

async function savePersonaState(env: Env, taskId: string, messages: ChatMessage[], step: number, lockedUntil: string | null): Promise<void> {
  await dbRun(
    env,
    `INSERT INTO persona_task_state (task_id, messages_json, step, locked_until)
     VALUES (?, ?, ?, ?)
     ON CONFLICT(task_id) DO UPDATE SET messages_json = excluded.messages_json, step = excluded.step, locked_until = excluded.locked_until`,
    [taskId, JSON.stringify(messages), step, lockedUntil],
  );
}

function readPersonaMessages(raw: string | undefined): ChatMessage[] {
  if (!raw) return [];
  try {
    const value = JSON.parse(raw) as unknown;
    if (!Array.isArray(value)) return [];
    return value as ChatMessage[];
  } catch {
    return [];
  }
}

const AGENT_FROM = `SELECT a.*, p.tools_json, p.voice_id, p.voice_name
  FROM persona_agents a
  LEFT JOIN persona_profiles p ON p.agent_id = a.id`;

async function loadAgent(env: Env, id: string): Promise<PersonaRow | null> {
  return dbFirst<PersonaRow>(env, `${AGENT_FROM} WHERE a.id = ?`, [id]);
}

async function loadAgents(env: Env): Promise<PersonaRow[]> {
  return dbAll<PersonaRow>(env, `${AGENT_FROM} ORDER BY a.name`);
}

async function ensureProfile(env: Env, id: string, tools: string[]): Promise<void> {
  const existing = await dbFirst<{ agent_id: string }>(env, "SELECT agent_id FROM persona_profiles WHERE agent_id = ?", [id]);
  if (existing) return;
  await dbRun(
    env,
    "INSERT INTO persona_profiles (agent_id, tools_json, voice_id, voice_name) VALUES (?, ?, '', '')",
    [id, JSON.stringify(tools)],
  );
}

async function writeProfile(env: Env, id: string, tools: string[], voice: { voice_id: string; voice_name: string }): Promise<void> {
  await dbRun(
    env,
    `INSERT INTO persona_profiles (agent_id, tools_json, voice_id, voice_name)
     VALUES (?, ?, ?, ?)
     ON CONFLICT(agent_id) DO UPDATE SET tools_json = excluded.tools_json, voice_id = excluded.voice_id, voice_name = excluded.voice_name`,
    [id, JSON.stringify(tools), voice.voice_id, voice.voice_name],
  );
}

function voiceFields(body: Record<string, unknown>, fallbackId = "", fallbackName = ""): { voice_id: string; voice_name: string } {
  const voiceId = typeof body.voice_id === "string" ? body.voice_id.trim().slice(0, 80) : fallbackId;
  const voiceName = typeof body.voice_name === "string" ? body.voice_name.trim().slice(0, 80) : fallbackName;
  return { voice_id: voiceId, voice_name: voiceName };
}

function sanitizeTools(value: unknown, fallback: string[]): string[] {
  if (!Array.isArray(value)) return fallback;
  const allowed = new Set<string>(PERSONA_TOOL_NAMES);
  return [...new Set(value.filter((item): item is string => typeof item === "string" && allowed.has(item)))].slice(0, 12);
}

function parseTools(raw: string | null | undefined, id: string): string[] {
  if (raw) {
    try {
      const value = JSON.parse(raw) as unknown;
      if (Array.isArray(value)) {
        const allowed = new Set<string>(PERSONA_TOOL_NAMES);
        return value.filter((item): item is string => typeof item === "string" && allowed.has(item));
      }
    } catch {
      // Fall through to the built-in list.
    }
  }
  return DEFAULT_TOOLS[id] ?? ["memory"];
}

function mapAgent(row: PersonaRow) {
  return {
    id: row.id,
    name: row.name,
    role: row.role,
    instructions: row.instructions,
    avatar: row.avatar,
    color_hex: row.color_hex,
    memory: row.memory,
    builtin: row.builtin === 1,
    tools: parseTools(row.tools_json, row.id),
    voice_id: row.voice_id ?? "",
    voice_name: row.voice_name ?? "",
    created_at: row.created_at,
    updated_at: row.updated_at,
  };
}

function mapTask(row: TaskRow) {
  return {
    id: row.id,
    agent_id: row.agent_id,
    goal: row.goal,
    status: row.status,
    result: row.result,
    approval_summary: row.approval_summary,
    created_at: row.created_at,
    updated_at: row.updated_at,
  };
}
