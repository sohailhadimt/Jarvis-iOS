import { getState, setState } from "./db";
import { isRecord, json, nowIso, readJson } from "./http";
import type { Env } from "./types";

export interface VoiceDebugEvent {
  at: string;
  kind: string;
  detail: string;
}

const KEY = "voice_debug";
const LIMIT = 40;

/** Bumped when a round trip must prove this worker stored the phone's events. */
export const VOICE_DEBUG_REVISION = "voice-log-2";

/** Keeps kind and a short detail. Drops anything that looks like a phone number. */
export function sanitizeVoiceDebug(input: unknown, at = nowIso(), limit = 20): VoiceDebugEvent[] {
  if (!isRecord(input) || !Array.isArray(input.events)) return [];
  const events: VoiceDebugEvent[] = [];
  for (const item of input.events.slice(0, limit)) {
    if (!isRecord(item)) continue;
    const kind = clip(String(item.kind ?? "").replace(/[^\w.-]/g, ""), 40);
    if (!kind) continue;
    const detail = clip(redact(String(item.detail ?? "")), 180);
    const storedAt = typeof item.at === "string" ? clip(item.at, 40) : "";
    events.push({ at: storedAt || at, kind, detail });
  }
  return events;
}

export async function saveVoiceDebug(request: Request, env: Env): Promise<Response> {
  const body = await readJson(request);
  if (!body.ok) return body.response;
  const incoming = sanitizeVoiceDebug(body.value);
  if (incoming.length === 0) return json({ ok: true, stored: 0 });
  const prior = await readVoiceDebug(env);
  const merged = [...prior, ...incoming].slice(-LIMIT);
  await setState(env, KEY, JSON.stringify(merged));
  return json({ ok: true, stored: incoming.length });
}

export async function readVoiceDebug(env: Env): Promise<VoiceDebugEvent[]> {
  try {
    const raw = await getState(env, KEY);
    if (!raw) return [];
    const parsed = JSON.parse(raw) as unknown;
    if (!Array.isArray(parsed)) return [];
    return sanitizeVoiceDebug({ events: parsed }, nowIso(), LIMIT);
  } catch {
    return [];
  }
}

function redact(value: string): string {
  return value.replace(/\s+/g, " ").replace(/\+\d[\d\s().-]*\d/g, "[number]").trim();
}

function clip(value: string, max: number): string {
  return value.length <= max ? value : value.slice(0, max);
}
