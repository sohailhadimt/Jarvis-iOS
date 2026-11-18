import { getState } from "./db";
import { apiError, isRecord, json } from "./http";
import type { Env } from "./types";

const SIGNED_URL = "https://api.elevenlabs.io/v1/convai/conversation/get-signed-url";
/** Starter-plan guard: the app agent may talk this many seconds per London day unless overridden. */
export const DEFAULT_DAILY_SECONDS = 15 * 60;
const MAX_REPORT_SECONDS = 10 * 60;

export function londonDay(now = Date.now()): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/London" }).format(new Date(now));
}

function dailyCap(env: Env): number {
  const raw = Number(env.ELEVENLABS_APP_DAILY_SECONDS);
  return Number.isFinite(raw) && raw > 0 ? raw : DEFAULT_DAILY_SECONDS;
}

async function usedToday(env: Env, now: number): Promise<number> {
  const value = Number(await getState(env, `eleven_app:${londonDay(now)}`));
  return Number.isFinite(value) && value > 0 ? value : 0;
}

/**
 * Mints a signed ElevenLabs Agents URL for the in-app voice agent. The API key and agent id stay on the Worker.
 * The phone falls back to Gemini Live when this answers 429 (budget) or 503.
 */
export async function elevenSessionResponse(env: Env, now = Date.now()): Promise<Response> {
  const key = (env.ELEVENLABS_API_KEY ?? "").trim();
  const agent = (env.ELEVENLABS_APP_AGENT_ID ?? "").trim();
  if (!key || !agent) return apiError(503, "not_configured", "The ElevenLabs app voice agent is not configured on the Worker.");
  const used = await usedToday(env, now);
  const cap = dailyCap(env);
  if (used >= cap) {
    return apiError(429, "budget", "Today's ElevenLabs voice minutes for the app are used. Gemini Live takes over.");
  }
  // Two short tries beat one long wait: the phone falls back to Gemini Live sooner if ElevenLabs is down.
  let response: Response | null = null;
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      response = await fetch(`${SIGNED_URL}?agent_id=${encodeURIComponent(agent)}`, {
        headers: { "xi-api-key": key },
        signal: AbortSignal.timeout(4_000),
      });
      if (response.status < 500) break;
    } catch {
      response = null;
    }
    if (attempt === 0) await new Promise((resolve) => setTimeout(resolve, 250));
  }
  if (!response) return apiError(502, "unavailable", "ElevenLabs could not be reached.");
  if (!response.ok) {
    const status = response.status === 401 || response.status === 403 ? 502 : response.status === 429 ? 429 : 502;
    return apiError(status, response.status === 429 ? "quota" : "unavailable", "ElevenLabs could not start a session.");
  }
  const body = (await response.json().catch(() => null)) as unknown;
  const url = isRecord(body) && typeof body.signed_url === "string" ? body.signed_url : "";
  if (!url.startsWith("wss://")) return apiError(502, "unavailable", "ElevenLabs returned no session URL.");
  return json({
    ok: true,
    signed_url: url,
    remaining_seconds: Math.max(0, cap - used),
    // One conversation never outlives what is left of the day, capped at the agent's own ten minutes.
    max_seconds: Math.min(600, Math.max(30, cap - used)),
  });
}

/** The phone reports how long a conversation actually ran so the daily guard stays honest. */
export async function elevenUsageResponse(request: Request, env: Env, now = Date.now()): Promise<Response> {
  const body = (await request.json().catch(() => null)) as unknown;
  const raw = isRecord(body) ? Number(body.seconds) : NaN;
  if (!Number.isFinite(raw) || raw < 0) return apiError(400, "bad_request", "seconds must be a number.");
  const seconds = Math.min(MAX_REPORT_SECONDS, Math.round(raw));
  // One atomic add, so two conversations ending together cannot overwrite each other's seconds.
  const row = await env.DB.prepare(
    `INSERT INTO runtime_state (key, value, updated_at) VALUES (?, ?, ?)
     ON CONFLICT(key) DO UPDATE SET value = CAST(CAST(runtime_state.value AS INTEGER) + CAST(excluded.value AS INTEGER) AS TEXT),
       updated_at = excluded.updated_at
     RETURNING value`,
  ).bind(`eleven_app:${londonDay(now)}`, String(seconds), new Date(now).toISOString()).first<{ value: string }>();
  const total = Number(row?.value ?? seconds) || seconds;
  return json({ ok: true, used_seconds: total, remaining_seconds: Math.max(0, dailyCap(env) - total) });
}
