import { logActivity, dbAll, dbFirst, dbRun } from "./db";
import { apiError, asString, clip, isRecord, json, newId, nowIso, readJson } from "./http";
import { completeChat } from "./llm";
import { ensurePersonas, queuePersonaTask } from "./personas";
import type { Env } from "./types";

export const PROJECT_MONEY_ROOM = "room_project_money";

export const ROUTINE_IDS = ["job_daily_briefing", "job_open_reminders", "job_pipeline_monitor"] as const;

interface MissionRow {
  id: string;
  goal: string;
  status: string;
  report: string | null;
  created_at: string;
  updated_at: string;
}

interface RosterAgent {
  id: string;
  name: string;
  role: string;
}

export function isRoutine(id: string): boolean {
  return (ROUTINE_IDS as readonly string[]).includes(id);
}

export function parseMissionPlan(
  raw: string,
  roster: Array<{ id: string; name: string }>,
): { ok: true; assignments: Array<{ agent_id: string; goal: string }> } | { ok: false; error: string } {
  const jsonText = extractJsonObject(raw);
  if (!jsonText) return { ok: false, error: "No JSON object found in the mission plan." };
  let data: unknown;
  try {
    data = JSON.parse(jsonText) as unknown;
  } catch (err) {
    const message = err instanceof Error ? err.message : "parse error";
    return { ok: false, error: `Mission plan JSON is invalid: ${message}` };
  }
  if (!isRecord(data)) return { ok: false, error: "Mission plan must be a JSON object." };
  const assignments = data.assignments;
  if (!Array.isArray(assignments) || assignments.length === 0) {
    return { ok: false, error: "Mission plan must include a non-empty assignments array." };
  }
  if (assignments.length > 4) return { ok: false, error: "Mission plan has more than 4 assignments." };
  const resolved: Array<{ agent_id: string; goal: string }> = [];
  for (let i = 0; i < assignments.length; i++) {
    const item = assignments[i];
    if (!isRecord(item)) return { ok: false, error: `Assignment ${i} is not an object.` };
    const agent = typeof item.agent === "string" ? item.agent.trim() : "";
    const goal = typeof item.goal === "string" ? item.goal.trim() : "";
    if (!agent) return { ok: false, error: `Assignment ${i} is missing an agent.` };
    if (!goal || goal.length > 2000) return { ok: false, error: `Assignment ${i} needs a goal of at most 2000 characters.` };
    const match = roster.find((row) => row.id === agent || squash(row.name) === squash(agent));
    if (!match) return { ok: false, error: `Assignment ${i} names an unknown agent (${agent}).` };
    resolved.push({ agent_id: match.id, goal });
  }
  return { ok: true, assignments: resolved };
}

export function mentionedAgents<T extends { id: string; name: string }>(text: string, roster: T[]): T[] {
  const folded = text.toLowerCase().replace(/\./g, "");
  return roster.filter((agent) => {
    const key = squash(agent.name);
    return key.length >= 4 && folded.includes(`@${key}`);
  });
}

export function roomGoal(roomId: string, text: string, hop: number): string {
  return `room:${roomId}\nhop:${hop}\n${text}`;
}

export function readRoomGoal(goal: string): { roomId: string; hop: number; text: string } | null {
  const match = goal.match(/^room:([A-Za-z0-9_-]+)\nhop:(\d+)\n([\s\S]*)$/);
  if (!match) return null;
  return { roomId: match[1], hop: Number(match[2]), text: match[3] };
}

export async function openMission(env: Env, goal: string): Promise<string> {
  const id = newId("msn");
  const now = nowIso();
  await dbRun(
    env,
    "INSERT INTO missions (id, goal, status, report, created_at, updated_at) VALUES (?, ?, 'planning', NULL, ?, ?)",
    [id, goal, now, now],
  );
  await logActivity(env, "jarvis", "mission.created", null, { mission_id: id });
  return id;
}

export async function runMissionTick(env: Env): Promise<void> {
  await ensureRoom(env);
  const pending = await dbFirst<{ id: string }>(
    env,
    "SELECT id FROM missions WHERE status = 'planning' ORDER BY created_at LIMIT 1",
  );
  if (pending) await planMission(env, pending.id);
  await reconcileMissions(env);
}

export async function routeMissionApi(
  request: Request,
  env: Env,
  path: string,
  parts: string[],
): Promise<Response | null> {
  if (parts[0] !== "missions" && parts[0] !== "routines" && parts[0] !== "rooms" && parts[0] !== "reminders" && path !== "/group") {
    return null;
  }
  await ensurePersonas(env);
  await ensureRoom(env);

  if (request.method === "GET" && path === "/missions") return listMissions(env);
  if (request.method === "POST" && path === "/missions") return createMission(request, env);
  if (request.method === "GET" && parts[0] === "missions" && parts[1] && parts.length === 2) {
    return getMission(env, parts[1]);
  }
  if (request.method === "GET" && path === "/routines") return listRoutines(env);
  if (request.method === "POST" && parts[0] === "routines" && parts[1] && parts.length === 2) {
    return setRoutine(request, env, parts[1]);
  }
  if (request.method === "GET" && path === "/rooms") return listRooms(env);
  if (request.method === "GET" && parts[0] === "rooms" && parts[2] === "messages" && parts.length === 3) {
    return listRoomMessages(env, parts[1]);
  }
  if (request.method === "POST" && parts[0] === "rooms" && parts[2] === "messages" && parts.length === 3) {
    return postRoomMessage(request, env, parts[1], false);
  }
  if (request.method === "GET" && path === "/group") return listRoomMessages(env, PROJECT_MONEY_ROOM);
  if (request.method === "POST" && path === "/group") return postRoomMessage(request, env, PROJECT_MONEY_ROOM, false);
  if (request.method === "GET" && path === "/reminders") return listReminders(env);
  return null;
}

export async function deliverRoomResult(
  env: Env,
  roomId: string,
  author: string,
  text: string,
  hop: number,
): Promise<void> {
  await insertRoomLine(env, roomId, author, "agent", text);
  if (hop >= 1) return;
  const roster = await rosterOf(env);
  const hits = mentionedAgents(text, roster).filter((agent) => squash(agent.name) !== squash(author)).slice(0, 1);
  for (const agent of hits) {
    await queuePersonaTask(env, agent.id, roomGoal(roomId, text, 1));
  }
}

async function createMission(request: Request, env: Env): Promise<Response> {
  const body = await readJson(request);
  if (!body.ok) return body.response;
  if (!isRecord(body.value)) return apiError(400, "bad_request", "JSON body must be an object.");
  const goal = asString(body.value.goal, 4000);
  if (!goal) return apiError(400, "bad_request", "goal is required.");
  const id = await openMission(env, goal);
  await planMission(env, id);
  return json({ mission: await missionPayload(env, id) }, 201);
}

async function listMissions(env: Env): Promise<Response> {
  const rows = await dbAll<MissionRow>(env, "SELECT * FROM missions ORDER BY created_at DESC LIMIT 40");
  return json({ missions: rows.map(mapMission) });
}

async function getMission(env: Env, id: string): Promise<Response> {
  const payload = await missionPayload(env, id);
  if (!payload) return apiError(404, "not_found", "No mission with that id.");
  return json({ mission: payload });
}

async function planMission(env: Env, id: string): Promise<void> {
  const mission = await dbFirst<MissionRow>(env, "SELECT * FROM missions WHERE id = ?", [id]);
  if (!mission || mission.status !== "planning") return;
  const claimed = await dbRun(
    env,
    "UPDATE missions SET status = 'running', updated_at = ? WHERE id = ? AND status = 'planning'",
    [nowIso(), id],
  );
  if (claimed !== 1) return;
  const roster = await rosterOf(env);
  if (roster.length === 0) {
    await failMission(env, id, "No agents are on the roster, so the mission was not planned.");
    return;
  }
  const llm = await completeChat(
    env,
    [
      { role: "system", content: missionSystemPrompt(roster) },
      { role: "user", content: `Mission:\n${mission.goal}\n\nRespond with the JSON object only.` },
    ],
    null,
  );
  if (!llm.ok) {
    await failMission(env, id, llm.message);
    return;
  }
  const parsed = parseMissionPlan(llm.message.content ?? "", roster);
  if (!parsed.ok) {
    await failMission(env, id, parsed.error);
    return;
  }
  for (const assignment of parsed.assignments) {
    const task = await queuePersonaTask(env, assignment.agent_id, assignment.goal);
    if (!task) continue;
    await dbRun(env, "INSERT OR IGNORE INTO mission_tasks (mission_id, task_id) VALUES (?, ?)", [id, task.id]);
  }
  await dbRun(env, "UPDATE missions SET status = 'running', report = NULL, updated_at = ? WHERE id = ?", [nowIso(), id]);
  await logActivity(env, "jarvis", "mission.planned", null, {
    mission_id: id,
    assignments: parsed.assignments.length,
  });
}

async function reconcileMissions(env: Env): Promise<void> {
  const rows = await dbAll<MissionRow>(
    env,
    "SELECT * FROM missions WHERE status IN ('running', 'awaiting_approval') ORDER BY created_at LIMIT 10",
  );
  for (const mission of rows) {
    const tasks = await dbAll<{ id: string; status: string; result: string | null; approval_summary: string | null; name: string }>(
      env,
      `SELECT t.id, t.status, t.result, t.approval_summary, a.name
       FROM mission_tasks m
       JOIN persona_tasks t ON t.id = m.task_id
       JOIN persona_agents a ON a.id = t.agent_id
       WHERE m.mission_id = ?`,
      [mission.id],
    );
    if (tasks.length === 0) {
      const age = Date.now() - Date.parse(mission.updated_at);
      if (mission.status === "running" && age > 180_000) {
        await failMission(env, mission.id, "The plan did not queue any specialist work.");
      }
      continue;
    }
    if (tasks.some((task) => task.status === "queued" || task.status === "working")) continue;
    const waiting = tasks.some((task) => task.status === "needs_approval");
    if (waiting && mission.status === "awaiting_approval") continue;
    const lines = tasks.map((task) => {
      const body = (task.result || task.approval_summary || "").trim() || "(no result stored)";
      return `${task.name}: ${body}`;
    });
    const report = [
      "JARVIS checked the specialist results. Nothing was sent, published, or paid.",
      ...lines,
    ].join("\n\n");
    const status = waiting ? "awaiting_approval" : "completed";
    await dbRun(env, "UPDATE missions SET status = ?, report = ?, updated_at = ? WHERE id = ?", [
      status,
      report,
      nowIso(),
      mission.id,
    ]);
    await logActivity(env, "jarvis", waiting ? "mission.awaiting_approval" : "mission.completed", null, {
      mission_id: mission.id,
    });
  }
}

async function listRoutines(env: Env): Promise<Response> {
  const rows = await dbAll<{ id: string; name: string; goal: string; cron: string; enabled: number; last_run_at: string | null; next_run_at: string | null }>(
    env,
    "SELECT id, name, goal, cron, enabled, last_run_at, next_run_at FROM scheduled_jobs ORDER BY name",
  );
  return json({
    routines: rows.map((row) => ({
      id: row.id,
      name: row.name,
      goal: row.goal,
      cron: row.cron,
      enabled: row.enabled === 1,
      last_run_at: row.last_run_at,
      next_run_at: row.next_run_at,
    })),
  });
}

async function setRoutine(request: Request, env: Env, id: string): Promise<Response> {
  if (!/^[A-Za-z0-9_-]+$/.test(id)) return apiError(400, "bad_request", "Invalid routine id.");
  const existing = await dbFirst<{ id: string }>(env, "SELECT id FROM scheduled_jobs WHERE id = ?", [id]);
  if (!existing) return apiError(404, "not_found", "No routine with that id.");
  const body = await readJson(request);
  if (!body.ok) return body.response;
  if (!isRecord(body.value) || typeof body.value.enabled !== "boolean") {
    return apiError(400, "bad_request", "enabled must be true or false.");
  }
  const enabled = body.value.enabled ? 1 : 0;
  await dbRun(env, "UPDATE scheduled_jobs SET enabled = ?, next_run_at = NULL WHERE id = ?", [enabled, id]);
  await logActivity(env, "api", enabled ? "routine.enabled" : "routine.disabled", null, { id });
  return json({ ok: true, id, enabled: enabled === 1 });
}

async function listRooms(env: Env): Promise<Response> {
  const rows = await dbAll<{ id: string; name: string; purpose: string }>(
    env,
    "SELECT id, name, purpose FROM rooms ORDER BY name",
  );
  return json({ rooms: rows });
}

async function listRoomMessages(env: Env, roomId: string): Promise<Response> {
  const room = await dbFirst<{ id: string }>(env, "SELECT id FROM rooms WHERE id = ?", [roomId]);
  if (!room) return apiError(404, "not_found", "No room with that id.");
  const rows = await dbAll<{ id: string; author: string; role: string; text: string; created_at: string }>(
    env,
    "SELECT id, author, role, text, created_at FROM room_messages WHERE room_id = ? ORDER BY created_at LIMIT 80",
    [roomId],
  );
  return json({
    messages: rows.map((row) => ({
      id: row.id,
      author: row.author,
      role: row.role,
      text: row.text,
      created_at: row.created_at,
    })),
  });
}

async function postRoomMessage(request: Request, env: Env, roomId: string, fromAgent: boolean): Promise<Response> {
  const room = await dbFirst<{ id: string }>(env, "SELECT id FROM rooms WHERE id = ?", [roomId]);
  if (!room) return apiError(404, "not_found", "No room with that id.");
  const body = await readJson(request);
  if (!body.ok) return body.response;
  if (!isRecord(body.value)) return apiError(400, "bad_request", "JSON body must be an object.");
  const text = asString(body.value.text, 4000);
  if (!text) return apiError(400, "bad_request", "text is required.");
  const author = typeof body.value.author === "string" && body.value.author ? body.value.author : "You";
  const role = fromAgent || (typeof body.value.role === "string" && body.value.role === "agent") ? "agent" : "user";
  await insertRoomLine(env, roomId, author, role, text);
  if (role === "user") {
    const roster = await rosterOf(env);
    const hits = mentionedAgents(text, roster).filter((agent) => squash(agent.name) !== squash(author)).slice(0, 3);
    for (const agent of hits) {
      await queuePersonaTask(env, agent.id, roomGoal(roomId, text, 0));
    }
  }
  return json({ ok: true }, 201);
}

async function listReminders(env: Env): Promise<Response> {
  const rows = await dbAll<{ id: string; agent_id: string; text: string; due_at: string | null; status: string; created_at: string }>(
    env,
    "SELECT id, agent_id, text, due_at, status, created_at FROM reminders WHERE status = 'open' ORDER BY created_at DESC LIMIT 40",
  );
  return json({
    reminders: rows.map((row) => ({
      id: row.id,
      agent_id: row.agent_id,
      text: row.text,
      due_at: row.due_at,
      status: row.status,
      created_at: row.created_at,
    })),
  });
}

async function insertRoomLine(env: Env, roomId: string, author: string, role: string, text: string): Promise<void> {
  await dbRun(
    env,
    "INSERT INTO room_messages (id, room_id, author, role, text, created_at) VALUES (?, ?, ?, ?, ?, ?)",
    [newId("rm"), roomId, author, role, text, nowIso()],
  );
  await logActivity(env, author, "room.message", null, { room_id: roomId });
}

async function missionPayload(env: Env, id: string) {
  const mission = await dbFirst<MissionRow>(env, "SELECT * FROM missions WHERE id = ?", [id]);
  if (!mission) return null;
  const tasks = await dbAll<{ id: string; agent_id: string; goal: string; status: string; result: string | null; name: string }>(
    env,
    `SELECT t.id, t.agent_id, t.goal, t.status, t.result, a.name
     FROM mission_tasks m
     JOIN persona_tasks t ON t.id = m.task_id
     JOIN persona_agents a ON a.id = t.agent_id
     WHERE m.mission_id = ?
     ORDER BY t.created_at`,
    [id],
  );
  return {
    ...mapMission(mission),
    tasks: tasks.map((task) => ({
      id: task.id,
      agent_id: task.agent_id,
      name: task.name,
      goal: task.goal,
      status: task.status,
      result: task.result,
    })),
  };
}

function mapMission(row: MissionRow) {
  return {
    id: row.id,
    goal: row.goal,
    status: row.status,
    report: row.report,
    created_at: row.created_at,
    updated_at: row.updated_at,
  };
}

async function rosterOf(env: Env): Promise<RosterAgent[]> {
  return dbAll<RosterAgent>(env, "SELECT id, name, role FROM persona_agents ORDER BY name");
}

async function failMission(env: Env, id: string, report: string): Promise<void> {
  await dbRun(env, "UPDATE missions SET status = 'failed', report = ?, updated_at = ? WHERE id = ?", [
    clip(report, 2000),
    nowIso(),
    id,
  ]);
  await logActivity(env, "jarvis", "mission.failed", null, { mission_id: id, error: clip(report, 300) });
}

async function ensureRoom(env: Env): Promise<void> {
  const existing = await dbFirst<{ id: string }>(env, "SELECT id FROM rooms WHERE id = ?", [PROJECT_MONEY_ROOM]);
  if (existing) return;
  await dbRun(
    env,
    "INSERT INTO rooms (id, name, purpose, created_at) VALUES (?, ?, ?, ?)",
    [
      PROJECT_MONEY_ROOM,
      "Project Money",
      "EDITH, ULTRON, and FRIDAY compare notes on money-making projects. Mention someone with @EDITH, @ULTRON, @FRIDAY, or @JARVIS.",
      nowIso(),
    ],
  );
}

function missionSystemPrompt(roster: RosterAgent[]): string {
  const lines = roster.map((agent) => `- ${agent.name} (${agent.id}): ${agent.role}`);
  return [
    "You are JARVIS, chief of staff. Split one mission across the named team.",
    "EDITH does research and dossiers. ULTRON drafts sales, pricing, and outreach. FRIDAY drafts pages, code, automations, and schedules.",
    "Do not assign a step that sends, spends, publishes, or places a call. Ask for a draft instead.",
    "Each goal must say to leave unknown facts unknown and to keep a source URL on every factual claim.",
    "Roster:",
    ...lines,
    'Return only {"assignments":[{"agent":"E.D.I.T.H.","goal":"what they should do"}]} with 1 to 4 assignments.',
  ].join("\n");
}

function extractJsonObject(raw: string): string | null {
  const fenced = raw.match(/```(?:json)?\s*([\s\S]*?)```/i);
  const text = fenced ? fenced[1] : raw;
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  if (start < 0 || end <= start) return null;
  return text.slice(start, end + 1);
}

function squash(name: string): string {
  return name.toLowerCase().replace(/[^a-z]/g, "");
}
