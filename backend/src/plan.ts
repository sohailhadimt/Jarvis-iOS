import { ACTION_LEVELS, AGENTS, type ActionLevel, type AgentName, type PlanSubtask, LIMITS } from "./types";

export type ParsePlanResult =
  | { ok: true; subtasks: PlanSubtask[] }
  | { ok: false; error: string };

const EXTERNAL_AGENTS = new Set<AgentName>(["outreach", "automation"]);
const PAYMENT_PATTERN = /\b(pay|payment|invoice|charge|purchase|checkout)\b/i;

export function parsePlan(raw: string): ParsePlanResult {
  const jsonText = extractJsonObject(raw);
  if (!jsonText) return { ok: false, error: "No JSON object found in planner output." };
  let data: unknown;
  try {
    data = JSON.parse(jsonText) as unknown;
  } catch (err) {
    const message = err instanceof Error ? err.message : "parse error";
    return { ok: false, error: `Planner JSON is invalid: ${message}` };
  }
  if (!data || typeof data !== "object" || Array.isArray(data)) {
    return { ok: false, error: "Planner output must be a JSON object." };
  }
  const subtasksRaw = (data as { subtasks?: unknown }).subtasks;
  if (!Array.isArray(subtasksRaw) || subtasksRaw.length === 0) {
    return { ok: false, error: "Planner output must include a non-empty subtasks array." };
  }
  if (subtasksRaw.length > LIMITS.maxSubtasks) {
    return { ok: false, error: `Planner output has more than ${LIMITS.maxSubtasks} subtasks.` };
  }

  const subtasks: PlanSubtask[] = [];
  for (let i = 0; i < subtasksRaw.length; i++) {
    const item = subtasksRaw[i];
    if (!item || typeof item !== "object" || Array.isArray(item)) {
      return { ok: false, error: `Subtask ${i} is not an object.` };
    }
    const record = item as Record<string, unknown>;
    const agent = record.agent;
    if (typeof agent !== "string" || !isAgent(agent)) {
      return {
        ok: false,
        error: `Subtask ${i} has unknown agent '${String(agent)}'. Allowed: ${AGENTS.join(", ")}.`,
      };
    }
    const title = typeof record.title === "string" ? record.title.trim() : "";
    const instruction = typeof record.instruction === "string" ? record.instruction.trim() : "";
    if (!title || !instruction) {
      return { ok: false, error: `Subtask ${i} needs a non-empty title and instruction.` };
    }
    if (title.length > 200 || instruction.length > 4000) {
      return { ok: false, error: `Subtask ${i} title or instruction is too long.` };
    }
    const levelRaw = record.action_level;
    if (typeof levelRaw !== "string" || !isActionLevel(levelRaw)) {
      return {
        ok: false,
        error: `Subtask ${i} has invalid action_level '${String(levelRaw)}'. Allowed: ${ACTION_LEVELS.join(", ")}.`,
      };
    }
    let actionLevel: ActionLevel = levelRaw;
    let coerced = false;
    if (EXTERNAL_AGENTS.has(agent) && actionLevel === "automatic") {
      actionLevel = "approval_required";
      coerced = true;
    }
    if (PAYMENT_PATTERN.test(instruction) && actionLevel !== "explicit_authorisation") {
      actionLevel = "explicit_authorisation";
      coerced = true;
    }
    const depends = parseDepends(record.depends_on, i, subtasksRaw.length);
    if (!depends.ok) return { ok: false, error: `Subtask ${i}: ${depends.error}` };
    subtasks.push({
      agent,
      title,
      instruction,
      action_level: actionLevel,
      depends_on: depends.indexes,
      coerced,
    });
  }
  if (hasCycle(subtasks)) return { ok: false, error: "Subtask dependencies contain a cycle." };
  return { ok: true, subtasks };
}

export function extractJsonObject(raw: string): string | null {
  const trimmed = raw.trim();
  const fence = /```(?:json)?\s*([\s\S]*?)```/i.exec(trimmed);
  const text = fence ? fence[1].trim() : trimmed;
  const start = text.indexOf("{");
  if (start < 0) return null;
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let i = start; i < text.length; i++) {
    const char = text[i];
    if (inString) {
      if (escaped) escaped = false;
      else if (char === "\\") escaped = true;
      else if (char === "\"") inString = false;
      continue;
    }
    if (char === "\"") inString = true;
    else if (char === "{") depth++;
    else if (char === "}") {
      depth--;
      if (depth === 0) return text.slice(start, i + 1);
    }
  }
  return null;
}

function parseDepends(
  value: unknown,
  index: number,
  count: number,
): { ok: true; indexes: number[] } | { ok: false; error: string } {
  if (value === undefined || value === null) return { ok: true, indexes: [] };
  if (!Array.isArray(value)) return { ok: false, error: "depends_on must be an array of 0-based indexes." };
  const indexes: number[] = [];
  for (const entry of value) {
    if (typeof entry !== "number" || !Number.isInteger(entry)) {
      return { ok: false, error: "depends_on entries must be integer indexes." };
    }
    if (entry < 0 || entry >= count) return { ok: false, error: `depends_on index ${entry} is out of range.` };
    if (entry === index) return { ok: false, error: "a subtask cannot depend on itself." };
    if (!indexes.includes(entry)) indexes.push(entry);
  }
  return { ok: true, indexes };
}

function hasCycle(subtasks: { depends_on: number[] }[]): boolean {
  const state = new Array<number>(subtasks.length).fill(0);
  const visit = (index: number): boolean => {
    if (state[index] === 1) return true;
    if (state[index] === 2) return false;
    state[index] = 1;
    for (const dep of subtasks[index].depends_on) {
      if (visit(dep)) return true;
    }
    state[index] = 2;
    return false;
  };
  for (let i = 0; i < subtasks.length; i++) {
    if (visit(i)) return true;
  }
  return false;
}

export function isAgent(value: string): value is AgentName {
  return (AGENTS as readonly string[]).includes(value);
}

export function isActionLevel(value: string): value is ActionLevel {
  return (ACTION_LEVELS as readonly string[]).includes(value);
}

export function qcPassValue(summary: string | null): boolean | null {
  if (!summary) return null;
  const jsonText = extractJsonObject(summary);
  if (!jsonText) return null;
  try {
    const data = JSON.parse(jsonText) as { pass?: unknown };
    if (data.pass === true) return true;
    if (data.pass === false) return false;
    return null;
  } catch {
    return null;
  }
}
