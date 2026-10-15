import { dbAll, dbFirst, dbRun } from "./db";
import { apiError, asString, isRecord, json, newId, nowIso, readJson } from "./http";
import { completeChat } from "./llm";
import type { Env } from "./types";

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
}

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
      "Coordinate the other agents, break a request into assignments, and report back in a few sentences. You draft plans. You do not send, publish, or spend.",
    avatar: "J",
    color_hex: "4BA8EE",
    builtin: 1,
  },
  {
    id: "agent_edith",
    name: "E.D.I.T.H.",
    role: "Research and leads",
    instructions:
      "Research the question, name sources when you have them, and draft lead notes. Do not contact anyone.",
    avatar: "E",
    color_hex: "7AA2FF",
    builtin: 1,
  },
  {
    id: "agent_ultron",
    name: "U.L.T.R.O.N.",
    role: "Sales",
    instructions:
      "Draft outreach, proposals, and follow-ups. Leave them as drafts. Never send them.",
    avatar: "U",
    color_hex: "E15B64",
    builtin: 1,
  },
  {
    id: "agent_friday",
    name: "F.R.I.D.A.Y.",
    role: "Websites, content, and design",
    instructions:
      "Draft page structure, copy, and design notes. Never publish a site or post.",
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
  if (parts[0] !== "agents" && parts[0] !== "agent-tasks" && parts[0] !== "group") return null;
  await ensurePersonas(env);

  if (request.method === "GET" && path === "/agents") {
    const rows = await dbAll<PersonaRow>(env, "SELECT * FROM persona_agents ORDER BY name");
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
  if (request.method === "GET" && path === "/group") return listGroup(env);
  if (request.method === "POST" && path === "/group") return postGroup(request, env);
  return null;
}

export async function runPersonaTick(env: Env): Promise<void> {
  await ensurePersonas(env);
  const task = await dbFirst<TaskRow>(
    env,
    "SELECT * FROM persona_tasks WHERE status = 'queued' ORDER BY created_at LIMIT 1",
  );
  if (!task) return;
  const agent = await dbFirst<PersonaRow>(env, "SELECT * FROM persona_agents WHERE id = ?", [task.agent_id]);
  if (!agent) {
    await finish(env, task.id, "done", "That agent is no longer on the roster.");
    return;
  }
  await dbRun(env, "UPDATE persona_tasks SET status = 'working', updated_at = ? WHERE id = ?", [nowIso(), task.id]);
  const external = looksExternal(task.goal);
  const llm = await completeChat(
    env,
    [
      {
        role: "system",
        content: systemPrompt(agent, external),
      },
      { role: "user", content: task.goal },
    ],
    null,
  );
  if (!llm.ok) {
    await dbRun(env, "UPDATE persona_tasks SET status = 'queued', updated_at = ? WHERE id = ?", [nowIso(), task.id]);
    return;
  }
  const text = (llm.message.content ?? "").trim() || "I have nothing to add.";
  const approval = external || text.toUpperCase().startsWith("APPROVAL:");
  if (approval) {
    const summary = text.replace(/^APPROVAL:\s*/i, "").trim() || text;
    await dbRun(
      env,
      "UPDATE persona_tasks SET status = 'needs_approval', result = ?, approval_summary = ?, updated_at = ? WHERE id = ?",
      [summary, summary, nowIso(), task.id],
    );
    await dbRun(
      env,
      `INSERT INTO approvals
        (id, task_id, subtask_id, action, level, summary, payload_json, status, reason, created_at, decided_at)
       VALUES (?, NULL, NULL, 'persona_external', 'approval_required', ?, ?, 'pending', NULL, ?, NULL)`,
      [newId("apr"), summary, JSON.stringify({ persona_task_id: task.id, external_action_taken: false }), nowIso()],
    );
    await remember(env, agent.id, "agent", agent.name, summary);
    return;
  }
  await finish(env, task.id, "done", text);
  await remember(env, agent.id, "agent", agent.name, text);
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
      const row = await dbFirst<PersonaRow>(env, "SELECT * FROM persona_agents WHERE id = ?", [requested]);
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
  const row = await dbFirst<PersonaRow>(env, "SELECT * FROM persona_agents WHERE id = ?", [id]);
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
  const row = await dbFirst<PersonaRow>(env, "SELECT * FROM persona_agents WHERE id = ?", [id]);
  return json({ agent: row ? mapAgent(row) : null });
}

async function deleteAgent(env: Env, id: string): Promise<Response> {
  const changes = await dbRun(env, "DELETE FROM persona_agents WHERE id = ?", [id]);
  if (!changes) return apiError(404, "not_found", "No agent with that id.");
  await dbRun(env, "DELETE FROM persona_messages WHERE agent_id = ?", [id]);
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
  const now = nowIso();
  const id = typeof body.value.id === "string" && body.value.id.startsWith("job_") ? body.value.id : newId("job");
  const existing = await dbFirst<TaskRow>(env, "SELECT * FROM persona_tasks WHERE id = ?", [id]);
  if (existing) return json({ task: mapTask(existing) });
  await dbRun(
    env,
    `INSERT INTO persona_tasks (id, agent_id, goal, status, result, approval_summary, created_at, updated_at)
     VALUES (?, ?, ?, 'queued', NULL, NULL, ?, ?)`,
    [id, agent.id, goal, now, now],
  );
  await remember(env, agent.id, "user", "You", goal);
  const row = await dbFirst<TaskRow>(env, "SELECT * FROM persona_tasks WHERE id = ?", [id]);
  return json({ task: row ? mapTask(row) : null }, 201);
}

async function settle(env: Env, id: string, approved: boolean): Promise<Response> {
  const task = await dbFirst<TaskRow>(env, "SELECT * FROM persona_tasks WHERE id = ?", [id]);
  if (!task) return apiError(404, "not_found", "No agent task with that id.");
  const note = approved
    ? "Approved as a draft. Nothing was sent, published, or paid."
    : "Declined. Nothing was sent, published, or paid.";
  const result = [task.approval_summary, note].filter(Boolean).join("\n\n");
  await finish(env, id, "done", result);
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
  await finish(env, taskId, "done", result);
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

async function listGroup(env: Env): Promise<Response> {
  const rows = await dbAll<{ id: string; author: string; text: string; created_at: string }>(
    env,
    "SELECT id, author, text, created_at FROM group_messages ORDER BY created_at LIMIT 80",
  );
  return json({
    messages: rows.map((row) => ({ id: row.id, author: row.author, text: row.text, created_at: row.created_at })),
  });
}

async function postGroup(request: Request, env: Env): Promise<Response> {
  const body = await readJson(request);
  if (!body.ok) return body.response;
  if (!isRecord(body.value)) return apiError(400, "bad_request", "JSON body must be an object.");
  const text = asString(body.value.text, 4000);
  if (!text) return apiError(400, "bad_request", "text is required.");
  const author = typeof body.value.author === "string" && body.value.author ? body.value.author : "You";
  await dbRun(env, "INSERT INTO group_messages (id, author, text, created_at) VALUES (?, ?, ?, ?)", [
    newId("grp"),
    author,
    text,
    nowIso(),
  ]);
  return json({ ok: true }, 201);
}

async function ensurePersonas(env: Env): Promise<void> {
  const now = nowIso();
  for (const agent of DEFAULTS) {
    const existing = await dbFirst<{ id: string }>(env, "SELECT id FROM persona_agents WHERE id = ?", [agent.id]);
    if (existing) continue;
    await dbRun(
      env,
      `INSERT INTO persona_agents (id, name, role, instructions, avatar, color_hex, memory, builtin, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, '', ?, ?, ?)`,
      [agent.id, agent.name, agent.role, agent.instructions, agent.avatar, agent.color_hex, agent.builtin, now, now],
    );
  }
}

async function finish(env: Env, id: string, status: string, result: string): Promise<void> {
  await dbRun(env, "UPDATE persona_tasks SET status = ?, result = ?, updated_at = ? WHERE id = ?", [
    status,
    result,
    nowIso(),
    id,
  ]);
}

async function remember(env: Env, agentId: string, role: string, author: string, text: string): Promise<void> {
  await dbRun(
    env,
    "INSERT INTO persona_messages (id, agent_id, role, author, text, created_at) VALUES (?, ?, ?, ?, ?, ?)",
    [newId("msg"), agentId, role, author, text, nowIso()],
  );
}

function systemPrompt(agent: PersonaRow, external: boolean): string {
  const guard = external
    ? "The request would send, publish, or spend. Start your reply with APPROVAL: and give the draft only. Do not claim you sent, published, or paid."
    : "If you are asked to send, publish, or spend, start your reply with APPROVAL: and give the draft only.";
  return `You are ${agent.name}, ${agent.role}. ${agent.instructions}\nMemory:\n${agent.memory || "(none)"}\n${guard}`;
}

function looksExternal(goal: string): boolean {
  const lower = goal.toLowerCase();
  const needles = ["send ", "email them", "publish", "post this", "spend", "pay ", "purchase", "wire ", "tweet"];
  return needles.some((needle) => lower.includes(needle));
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
