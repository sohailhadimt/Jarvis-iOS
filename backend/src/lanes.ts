import { runTick } from "./execute";
import { runPersonaTick } from "./personas";
import type { Env } from "./types";
import { LIMITS } from "./types";

/**
 * Parallel agent lanes. Each lane runs one tick, then hands the next tick to a fresh
 * Worker invocation through the SELF service binding, so the free-tier per-invocation
 * limits (CPU, D1 queries, subrequests) reset on every hop. Several lanes run side by side,
 * so different agents work at the same time instead of one step every five minutes.
 *
 * Without the SELF binding or the app token this falls back to the old single tick.
 */
export function laneCount(env: Env): number {
  const raw = Number(env.AGENT_LANES ?? "");
  if (!Number.isFinite(raw) || raw < 1) return LIMITS.defaultLanes;
  return Math.min(LIMITS.maxLanes, Math.floor(raw));
}

export function lanesEnabled(env: Env): boolean {
  return Boolean(env.SELF && (env.JARVIS_APP_TOKEN ?? "").trim());
}

/** One lane step: a task-specialist step plus a round of persona-agent steps. */
export async function laneTick(env: Env, reason: string): Promise<boolean> {
  const [tasks, personas] = await Promise.all([
    runTick(env, reason),
    runPersonaTick(env).catch((err) => {
      console.error("jarvis persona lane failed", err instanceof Error ? err.message : String(err));
      return false;
    }),
  ]);
  return tasks || personas;
}

/** Cron or task creation: one tick here, then open the extra lanes. */
export async function startLanes(env: Env, reason: string): Promise<void> {
  const worked = await runTick(env, reason);
  if (!lanesEnabled(env)) return;
  const lanes = laneCount(env);
  // The first lane continues only when this tick found work. The others probe for work in parallel.
  const opens: Promise<void>[] = [];
  for (let lane = 0; lane < lanes; lane++) {
    if (lane === 0 && !worked) continue;
    opens.push(handOff(env, lane, 1));
  }
  await Promise.all(opens);
}

/** POST /tick from a lane. Runs one tick and passes the lane on while there is work. */
export async function runLane(env: Env, lane: number, hop: number): Promise<void> {
  const worked = await laneTick(env, `lane:${lane}:${hop}`);
  if (!worked || hop >= LIMITS.maxLaneHops || !lanesEnabled(env)) return;
  await handOff(env, lane, hop + 1);
}

export function parseLaneHeaders(request: Request): { lane: number; hop: number } {
  const lane = clampInt(request.headers.get("x-jarvis-lane"), 0, LIMITS.maxLanes - 1);
  const hop = clampInt(request.headers.get("x-jarvis-hop"), 1, LIMITS.maxLaneHops);
  return { lane, hop };
}

async function handOff(env: Env, lane: number, hop: number): Promise<void> {
  const self = env.SELF;
  const token = (env.JARVIS_APP_TOKEN ?? "").trim();
  if (!self || !token) return;
  try {
    const response = await self.fetch("https://jarvis-lane/tick", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "x-jarvis-lane": String(lane),
        "x-jarvis-hop": String(hop),
      },
    });
    // The lane runs in the callee's waitUntil. Drop the body so the connection closes.
    await response.body?.cancel();
  } catch (err) {
    console.error("jarvis lane hand-off failed", lane, hop, err instanceof Error ? err.message : String(err));
  }
}

function clampInt(value: string | null, min: number, max: number): number {
  const parsed = Number(value ?? "");
  if (!Number.isFinite(parsed)) return min;
  return Math.min(max, Math.max(min, Math.floor(parsed)));
}
