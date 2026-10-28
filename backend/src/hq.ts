import { dbAll, dbFirst, dbRun } from "./db";
import { apiError, asString, isRecord, json, newId, nowIso, readJson } from "./http";
import { completeChat } from "./llm";
import type { Env } from "./types";

/**
 * ASG HQ game API.
 * XP is awarded only when this module records a real work event.
 * Talk drafts that would send, publish, or spend become JARVIS approvals.
 * Nothing here places a call, sends a message, or publishes a post.
 *
 * Outfit and furniture ids are mirrored in ASG-HQ/ASGHQ/Model/Catalog.swift.
 */

export const XP_BY_KIND: Record<string, number> = {
  task_completed: 120,
  task_done: 80,
  approval_approved: 40,
  post_approved: 100,
  call_booked: 150,
};

export const DAILY_CHALLENGES = [
  { kind: "call_booked", title: "Book 1 call", target: 1 },
  { kind: "task_completed", title: "Finish 1 task", target: 1 },
  { kind: "post_approved", title: "Approve 1 post", target: 1 },
] as const;

const COLORS = ["navy", "black", "white", "charcoal", "sand", "gold", "burgundy", "forest"] as const;
const LOCKED_CLOTH = new Set(["tee", "chinos", "trainers", "overcoat", "glasses", "gold", "burgundy", "forest"]);
const PIECES: Record<string, readonly string[]> = {
  top: ["oxford", "knit", "tee"],
  bottoms: ["trousers", "chinos"],
  shoes: ["oxfords", "trainers"],
  jacket: ["none", "blazer", "overcoat"],
  accessory: ["none", "pin", "glasses"],
};
const FURNITURE_SLOTS = ["lamp", "plant", "chair", "rug", "cart", "art"] as const;
const FURNITURE_ITEMS = ["none", "lamp", "plant", "chair", "rug", "cart", "art"] as const;

interface BotProfile {
  id: string;
  agentId: string;
  name: string;
  role: string;
  instructions: string;
  avatar: string;
  color: string;
}

export const HQ_BOTS: Record<string, BotProfile> = {
  jarvis: {
    id: "jarvis",
    agentId: "agent_jarvis",
    name: "J.A.R.V.I.S.",
    role: "Coordination",
    instructions:
      "Coordinate the other agents, break a request into assignments, and report back in a few sentences. You draft plans. You do not send, publish, or spend.",
    avatar: "J",
    color: "4BA8EE",
  },
  edith: {
    id: "edith",
    agentId: "agent_edith",
    name: "E.D.I.T.H.",
    role: "Research",
    instructions:
      "Research the question, name sources when you have them, and draft lead notes. Do not contact anyone.",
    avatar: "E",
    color: "7AA2FF",
  },
  ultron: {
    id: "ultron",
    agentId: "agent_ultron",
    name: "U.L.T.R.O.N.",
    role: "Pitches, decks, and outreach drafts",
    instructions: "Draft outreach, proposals, and follow-ups. Leave them as drafts. Never send them.",
    avatar: "U",
    color: "E15B64",
  },
  friday: {
    id: "friday",
    agentId: "agent_friday",
    name: "F.R.I.D.A.Y.",
    role: "Websites and design",
    instructions: "Draft page structure, copy, and design notes. Never publish a site or post.",
    avatar: "F",
    color: "C9A227",
  },
};

interface Look {
  name: string;
  top: string;
  bottoms: string;
  shoes: string;
  jacket: string;
  accessory: string;
  top_color: string;
  bottoms_color: string;
  shoes_color: string;
  jacket_color: string;
}

interface Furniture {
  slot: string;
  item: string;
  color: string;
}

interface EventRow {
  id: string;
  kind: string;
  source: string;
  summary: string;
  xp: number;
  bot: string | null;
  created_at: string;
}

export function levelProgress(xp: number): { level: number; xp_into_level: number; xp_to_next: number } {
  let level = 1;
  let left = Math.max(0, Math.floor(Number.isFinite(xp) ? xp : 0));
  let span = 800;
  while (left >= span && level < 50) {
    left -= span;
    level += 1;
    span = 800 * level;
  }
  return { level, xp_into_level: left, xp_to_next: span };
}

export function perksForLevel(level: number): string[] {
  const perks: string[] = [];
  if (level >= 3) perks.push("outfit_pack");
  if (level >= 5) perks.push("corner_office");
  if (level >= 8) perks.push("rooftop");
  return perks;
}

export function utcDayNumber(now: Date): number {
  return Math.floor(now.getTime() / 86_400_000);
}

export function dailyChallenge(
  events: Array<{ kind: string; created_at: string }>,
  now = new Date(),
): {
  id: string;
  title: string;
  kind: string;
  target: number;
  progress: number;
  done: boolean;
} {
  const spec = DAILY_CHALLENGES[utcDayNumber(now) % DAILY_CHALLENGES.length];
  const day = now.toISOString().slice(0, 10);
  const kinds = spec.kind === "task_completed" ? ["task_completed", "task_done"] : [spec.kind];
  const count = events.filter((event) => event.created_at.startsWith(day) && kinds.includes(event.kind)).length;
  return {
    id: `${day}:${spec.kind}`,
    title: spec.title,
    kind: spec.kind,
    target: spec.target,
    progress: Math.min(count, spec.target),
    done: count >= spec.target,
  };
}

export function looksExternal(text: string): boolean {
  const padded = ` ${text.toLowerCase()} `;
  const needles = [
    " send ",
    " email them",
    " e-mail them",
    " publish",
    " post this",
    " post it",
    " tweet",
    " go live",
    " spend",
    " pay ",
    " purchase",
    " wire ",
    " invoice them",
    " text them",
    " message them",
    " dm them",
    " call them",
    " phone them",
    " dial ",
  ];
  if (needles.some((needle) => padded.includes(needle))) return true;
  return /^(send|publish|pay|email|text|dial)\b/i.test(text.trim());
}

export function composeReply(
  botName: string,
  userText: string,
  model: string | null,
  external: boolean,
): { text: string; status: "draft" | "needs_approval" } {
  const cleaned = (model ?? "").replace(/^APPROVAL:\s*/i, "").trim();
  const usable = cleaned && !claimsSent(cleaned) ? cleaned : "";
  if (external) {
    const draft = usable || `Draft for review:\n${userText.trim().slice(0, 700)}`;
    return {
      status: "needs_approval",
      text: `${botName} parked this in JARVIS Approvals. Nothing was sent, published, or paid.\n\n${draft}`.slice(0, 1800),
    };
  }
  if (usable) return { status: "draft", text: usable.slice(0, 1800) };
  return {
    status: "draft",
    text: `${botName} saved this at HQ. The model did not answer, so there is no draft yet. Nothing was sent.`,
  };
}

function claimsSent(text: string): boolean {
  return /\b(i have sent|i've sent|i sent|i published|i posted|i emailed|i paid|email sent|payment sent)\b/i.test(text);
}

function scrub(summary: string): string {
  return summary
    .replace(/\+?\d[\d\s().-]{7,}\d/g, "[number]")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 240);
}

export async function recordHqEvent(
  env: Env,
  input: { kind: string; source: string; summary: string; bot?: string | null },
): Promise<{ created: boolean; xp: number } | null> {
  const xp = XP_BY_KIND[input.kind];
  if (!xp) return null;
  const source = input.source.trim().slice(0, 80);
  if (!source) return null;
  const summary = scrub(input.summary);
  if (!summary) return null;
  const bot = input.bot && HQ_BOTS[input.bot] ? input.bot : null;
  try {
    const existing = await dbFirst<{ id: string }>(
      env,
      "SELECT id FROM hq_events WHERE kind = ? AND source = ?",
      [input.kind, source],
    );
    if (existing) return { created: false, xp };
    await dbRun(
      env,
      `INSERT INTO hq_events (id, kind, source, summary, xp, bot, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
      [newId("hqe"), input.kind, source, summary, xp, bot, nowIso()],
    );
    return { created: true, xp };
  } catch (err) {
    console.error("hq event skipped", err instanceof Error ? err.message : "insert failed");
    return null;
  }
}

export async function handleHq(
  request: Request,
  env: Env,
  path: string,
  parts: string[],
): Promise<Response | null> {
  if (parts[0] !== "hq") return null;
  if (request.method === "GET" && path === "/hq/progress") return progress(env);
  if (request.method === "GET" && path === "/hq/events") return listEvents(env, new URL(request.url));
  if (request.method === "POST" && path === "/hq/events") return createEvent(request, env);
  if (request.method === "POST" && path === "/hq/talk") return talk(request, env);
  if (request.method === "POST" && path === "/hq/state") return saveState(request, env);
  return apiError(404, "not_found", `No route for ${request.method} ${path}.`);
}

async function progress(env: Env): Promise<Response> {
  try {
    const sumRow = await dbFirst<{ xp: number | null }>(env, "SELECT COALESCE(SUM(xp), 0) AS xp FROM hq_events");
    const xp = Math.max(0, Math.floor(Number(sumRow?.xp ?? 0)));
    const levels = levelProgress(xp);
    const perks = perksForLevel(levels.level);
    const now = new Date();
    const dayStart = `${now.toISOString().slice(0, 10)}T00:00:00.000Z`;
    const today = await dbAll<{ kind: string; created_at: string }>(
      env,
      "SELECT kind, created_at FROM hq_events WHERE created_at >= ?",
      [dayStart],
    );
    const recent = await dbAll<EventRow>(
      env,
      "SELECT id, kind, source, summary, xp, bot, created_at FROM hq_events ORDER BY created_at DESC LIMIT ?",
      [30],
    );
    const state = await readState(env);
    return json({
      xp,
      level: levels.level,
      xp_into_level: levels.xp_into_level,
      xp_to_next: levels.xp_to_next,
      perks,
      daily: dailyChallenge(today, now),
      events: recent.map(mapEvent),
      state,
      external_actions: false,
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : "HQ progress failed.";
    if (/no such table/i.test(message)) {
      return apiError(503, "hq_not_ready", "Apply backend/schema.sql on D1 so the HQ event log exists.");
    }
    throw err;
  }
}

async function listEvents(env: Env, url: URL): Promise<Response> {
  const limit = Math.min(100, Math.max(1, Number(url.searchParams.get("limit")) || 40));
  try {
    const rows = await dbAll<EventRow>(
      env,
      "SELECT id, kind, source, summary, xp, bot, created_at FROM hq_events ORDER BY created_at DESC LIMIT ?",
      [limit],
    );
    return json({ events: rows.map(mapEvent), external_actions: false });
  } catch (err) {
    const message = err instanceof Error ? err.message : "HQ events failed.";
    if (/no such table/i.test(message)) {
      return apiError(503, "hq_not_ready", "Apply backend/schema.sql on D1 so the HQ event log exists.");
    }
    throw err;
  }
}

async function createEvent(request: Request, env: Env): Promise<Response> {
  const body = await readJson(request);
  if (!body.ok) return body.response;
  if (!isRecord(body.value)) return apiError(400, "bad_request", "JSON body must be an object.");
  const kind = asString(body.value.kind, 40);
  if (!kind || !XP_BY_KIND[kind]) {
    return apiError(400, "bad_request", `kind must be one of: ${Object.keys(XP_BY_KIND).join(", ")}.`);
  }
  const source = asString(body.value.source, 80);
  if (!source || !/^[A-Za-z0-9_.:-]{1,80}$/.test(source)) {
    return apiError(400, "bad_request", "source is required and must be 1-80 characters of letters, numbers, or . _ : -.");
  }
  const summary = asString(body.value.summary, 240);
  if (!summary) return apiError(400, "bad_request", "summary is required.");
  let bot: string | null = null;
  if (body.value.bot !== undefined && body.value.bot !== null) {
    if (typeof body.value.bot !== "string" || !HQ_BOTS[body.value.bot]) {
      return apiError(400, "bad_request", "bot must be jarvis, friday, ultron, or edith.");
    }
    bot = body.value.bot;
  }
  const recorded = await recordHqEvent(env, { kind, source, summary, bot });
  if (!recorded) return apiError(503, "hq_not_ready", "Apply backend/schema.sql on D1 so the HQ event log exists.");
  const row = await dbFirst<EventRow>(env, "SELECT * FROM hq_events WHERE kind = ? AND source = ?", [kind, source]);
  return json(
    {
      event: row ? mapEvent(row) : { kind, source, summary: scrub(summary), xp: recorded.xp, bot, created_at: nowIso() },
      awarded: recorded.created,
      xp: recorded.xp,
      external_actions: false,
    },
    recorded.created ? 201 : 200,
  );
}

async function talk(request: Request, env: Env): Promise<Response> {
  const body = await readJson(request);
  if (!body.ok) return body.response;
  if (!isRecord(body.value)) return apiError(400, "bad_request", "JSON body must be an object.");
  const botId = asString(body.value.bot, 20);
  const bot = botId ? HQ_BOTS[botId] : undefined;
  if (!bot) return apiError(400, "bad_request", "bot must be jarvis, friday, ultron, or edith.");
  const text = asString(body.value.text, 4000);
  if (!text) return apiError(400, "bad_request", "text is required.");
  const external = looksExternal(text);
  let model: string | null = null;
  const llm = await completeChat(
    env,
    [
      {
        role: "system",
        content: [
          `You are ${bot.name}, ${bot.role}, at ASG HQ.`,
          bot.instructions,
          "Reply in under 80 words.",
          external
            ? "The user asked for something that would send, publish, call, or spend. Give the draft only. Start with APPROVAL:. Do not claim you sent, published, called, or paid."
            : "If you are asked to send, publish, call, or spend, say it has to wait for approval. Do not claim you did it.",
        ].join("\n"),
      },
      { role: "user", content: text },
    ],
    null,
  );
  if (llm.ok) model = llm.message.content;
  const composed = composeReply(bot.name, text, model, external);
  try {
    await ensureBot(env, bot);
    const now = nowIso();
    const taskId = newId("job");
    const status = composed.status === "needs_approval" ? "needs_approval" : "done";
    await dbRun(
      env,
      `INSERT INTO persona_tasks (id, agent_id, goal, status, result, approval_summary, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        taskId,
        bot.agentId,
        text,
        status,
        composed.text,
        composed.status === "needs_approval" ? composed.text : null,
        now,
        now,
      ],
    );
    await dbRun(
      env,
      "INSERT INTO persona_messages (id, agent_id, role, author, text, created_at) VALUES (?, ?, ?, ?, ?, ?)",
      [newId("msg"), bot.agentId, "user", "You", text, now],
    );
    await dbRun(
      env,
      "INSERT INTO persona_messages (id, agent_id, role, author, text, created_at) VALUES (?, ?, ?, ?, ?, ?)",
      [newId("msg"), bot.agentId, "agent", bot.name, composed.text, now],
    );
    if (composed.status === "needs_approval") {
      await dbRun(
        env,
        `INSERT INTO approvals
          (id, task_id, subtask_id, action, level, summary, payload_json, status, reason, created_at, decided_at)
         VALUES (?, NULL, NULL, 'persona_external', 'approval_required', ?, ?, 'pending', NULL, ?, NULL)`,
        [
          newId("apr"),
          composed.text,
          JSON.stringify({ persona_task_id: taskId, source: "asg_hq", bot: bot.id, external_action_taken: false }),
          now,
        ],
      );
    }
    return json({
      bot: bot.id,
      bot_name: bot.name,
      reply: composed.text,
      status: composed.status,
      task_id: taskId,
      stored: true,
      external_action_taken: false,
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : "Could not store the HQ task.";
    console.error("hq talk store failed", message);
    return apiError(503, "hq_not_ready", "The agent tables are not ready. Apply backend/schema.sql on D1, then try again.");
  }
}

async function saveState(request: Request, env: Env): Promise<Response> {
  const body = await readJson(request);
  if (!body.ok) return body.response;
  if (!isRecord(body.value)) return apiError(400, "bad_request", "JSON body must be an object.");
  const name = cleanName(body.value.player_name);
  if (!name) return apiError(400, "bad_request", "player_name is required and must be 1-40 characters.");
  let xp = 0;
  try {
    const sumRow = await dbFirst<{ xp: number | null }>(env, "SELECT COALESCE(SUM(xp), 0) AS xp FROM hq_events");
    xp = Math.max(0, Math.floor(Number(sumRow?.xp ?? 0)));
  } catch (err) {
    const message = err instanceof Error ? err.message : "";
    if (/no such table/i.test(message)) {
      return apiError(503, "hq_not_ready", "Apply backend/schema.sql on D1 so the HQ event log exists.");
    }
    throw err;
  }
  const perks = new Set(perksForLevel(levelProgress(xp).level));
  const active = parseLook(body.value.active_look, perks, false);
  if (!active.ok) return apiError(403, "perk_locked", active.error);
  if (!Array.isArray(body.value.looks) || body.value.looks.length > 12) {
    return apiError(400, "bad_request", "looks must be an array of at most 12 saved outfits.");
  }
  const looks: Look[] = [];
  for (const entry of body.value.looks) {
    const parsed = parseLook(entry, perks, true);
    if (!parsed.ok) return apiError(403, "perk_locked", parsed.error);
    looks.push(parsed.look);
  }
  const furniture = parseFurniture(body.value.furniture, perks);
  if (!furniture.ok) return apiError(furniture.status, furniture.code, furniture.error);
  const now = nowIso();
  try {
    await dbRun(
      env,
      `INSERT INTO hq_state (id, player_name, active_look_json, looks_json, furniture_json, updated_at)
       VALUES ('default', ?, ?, ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET
         player_name = excluded.player_name,
         active_look_json = excluded.active_look_json,
         looks_json = excluded.looks_json,
         furniture_json = excluded.furniture_json,
         updated_at = excluded.updated_at`,
      [name, JSON.stringify(active.look), JSON.stringify(looks), JSON.stringify(furniture.items), now],
    );
  } catch (err) {
    const message = err instanceof Error ? err.message : "";
    if (/no such table/i.test(message)) {
      return apiError(503, "hq_not_ready", "Apply backend/schema.sql on D1 so HQ state can be saved.");
    }
    throw err;
  }
  return json({
    state: { player_name: name, active_look: active.look, looks, furniture: furniture.items, updated_at: now },
    external_actions: false,
  });
}

async function readState(env: Env): Promise<Record<string, unknown> | null> {
  try {
    const row = await dbFirst<{
      player_name: string;
      active_look_json: string;
      looks_json: string;
      furniture_json: string;
      updated_at: string;
    }>(env, "SELECT player_name, active_look_json, looks_json, furniture_json, updated_at FROM hq_state WHERE id = 'default'");
    if (!row) return null;
    return {
      player_name: row.player_name,
      active_look: JSON.parse(row.active_look_json) as unknown,
      looks: JSON.parse(row.looks_json) as unknown,
      furniture: JSON.parse(row.furniture_json) as unknown,
      updated_at: row.updated_at,
    };
  } catch {
    return null;
  }
}

async function ensureBot(env: Env, bot: BotProfile): Promise<void> {
  const existing = await dbFirst<{ id: string }>(env, "SELECT id FROM persona_agents WHERE id = ?", [bot.agentId]);
  if (existing) return;
  const now = nowIso();
  await dbRun(
    env,
    `INSERT INTO persona_agents (id, name, role, instructions, avatar, color_hex, memory, builtin, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, '', 1, ?, ?)`,
    [bot.agentId, bot.name, bot.role, bot.instructions, bot.avatar, bot.color, now, now],
  );
}

function mapEvent(row: EventRow) {
  return {
    id: row.id,
    kind: row.kind,
    source: row.source,
    summary: row.summary,
    xp: Number(row.xp),
    bot: row.bot,
    created_at: row.created_at,
  };
}

function cleanName(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim().replace(/\s+/g, " ");
  if (!trimmed || trimmed.length > 40) return null;
  if (!/^[\p{L}\p{N} .'-]+$/u.test(trimmed)) return null;
  return trimmed;
}

function parseLook(
  value: unknown,
  perks: Set<string>,
  requireName: boolean,
): { ok: true; look: Look } | { ok: false; error: string } {
  if (!isRecord(value)) return { ok: false, error: "Each look must be an object." };
  const pack = perks.has("outfit_pack");
  const look: Look = {
    name: "HQ",
    top: "",
    bottoms: "",
    shoes: "",
    jacket: "",
    accessory: "",
    top_color: "",
    bottoms_color: "",
    shoes_color: "",
    jacket_color: "",
  };
  if (requireName || value.name !== undefined) {
    const name = cleanName(value.name);
    if (!name) return { ok: false, error: "Look name must be 1-40 characters." };
    look.name = name;
  }
  const pieceFields = ["top", "bottoms", "shoes", "jacket", "accessory"] as const;
  for (const field of pieceFields) {
    const piece = value[field];
    if (typeof piece !== "string" || !PIECES[field].includes(piece)) {
      return { ok: false, error: `${field} is not a known piece.` };
    }
    if (!pack && LOCKED_CLOTH.has(piece)) return { ok: false, error: `${piece} unlocks with the outfit pack at level 3.` };
    look[field] = piece;
  }
  const colorFields = ["top_color", "bottoms_color", "shoes_color", "jacket_color"] as const;
  for (const field of colorFields) {
    const color = value[field];
    if (typeof color !== "string" || !(COLORS as readonly string[]).includes(color)) {
      return { ok: false, error: `${field} is not a known colour.` };
    }
    if (!pack && (color === "gold" || color === "burgundy" || color === "forest")) {
      return { ok: false, error: `${color} cloth unlocks with the outfit pack at level 3.` };
    }
    look[field] = color;
  }
  return { ok: true, look };
}

function parseFurniture(
  value: unknown,
  perks: Set<string>,
): { ok: true; items: Furniture[] } | { ok: false; status: number; code: string; error: string } {
  if (!Array.isArray(value)) return { ok: false, status: 400, code: "bad_request", error: "furniture must be an array." };
  const seen = new Set<string>();
  const items: Furniture[] = [];
  for (const entry of value) {
    if (!isRecord(entry)) return { ok: false, status: 400, code: "bad_request", error: "Each furniture row must be an object." };
    const slot = entry.slot;
    const item = entry.item;
    const color = entry.color;
    if (typeof slot !== "string" || !(FURNITURE_SLOTS as readonly string[]).includes(slot)) {
      return { ok: false, status: 400, code: "bad_request", error: "Unknown furniture slot." };
    }
    if (seen.has(slot)) return { ok: false, status: 400, code: "bad_request", error: "Each furniture slot can appear once." };
    seen.add(slot);
    if (typeof item !== "string" || !(FURNITURE_ITEMS as readonly string[]).includes(item)) {
      return { ok: false, status: 400, code: "bad_request", error: "Unknown furniture item." };
    }
    if (typeof color !== "string" || !(COLORS as readonly string[]).includes(color)) {
      return { ok: false, status: 400, code: "bad_request", error: "Unknown furniture colour." };
    }
    if (item === "cart" && !perks.has("outfit_pack")) {
      return { ok: false, status: 403, code: "perk_locked", error: "The bar cart unlocks with the outfit pack at level 3." };
    }
    if (item === "art" && !perks.has("corner_office")) {
      return { ok: false, status: 403, code: "perk_locked", error: "The art frame unlocks with the corner office at level 5." };
    }
    items.push({ slot, item, color });
  }
  return { ok: true, items };
}
