import { dbAll } from "./db";
import { json } from "./http";
import { readOwnerMobile } from "./owner-alert";
import type { Env } from "./types";

/** App-token review of the last N days on Sir's line: his text thread and every call row. Numbers are masked. */
export async function sweepRoute(env: Env, url: URL): Promise<Response> {
  const days = Math.min(30, Math.max(1, Number(url.searchParams.get("days") ?? 14) || 14));
  const since = new Date(Date.now() - days * 86_400_000).toISOString();
  const owner = (await readOwnerMobile(env)) ?? "";
  const mask = (text: string | null) =>
    (text ?? "").replace(/\+?\d[\d\s()-]{7,}\d/g, (m) => (m.replace(/\D/g, "").endsWith(owner.replace(/\D/g, "").slice(-6)) && owner ? "[SIR]" : "[number]"));
  const turns = await dbAll<{ role: string; body: string; created_at: string }>(
    env,
    "SELECT role, body, created_at FROM sms_turns WHERE phone = ? AND created_at >= ? ORDER BY created_at ASC LIMIT 600",
    [owner, since],
  ).catch(() => []);
  const calls = await dbAll<{ id: string; contact_name: string; to_number: string; brief: string; status: string; summary: string | null; error: string | null; transcript_json: string | null; created_at: string }>(
    env,
    "SELECT id, contact_name, to_number, brief, status, summary, error, transcript_json, created_at FROM outbound_calls WHERE created_at >= ? ORDER BY created_at ASC LIMIT 300",
    [since],
  ).catch(() => []);
  const screens = await dbAll<{ call_id: string; direction: string; caller_phone: string | null; caller_name: string }>(
    env,
    "SELECT call_id, direction, caller_phone, caller_name FROM call_screen WHERE call_id IN (SELECT id FROM outbound_calls WHERE created_at >= ?)",
    [since],
  ).catch(() => []);
  const screenOf = new Map(screens.map((s) => [s.call_id, s]));
  return json({
    days,
    sms: turns.map((t) => ({ at: t.created_at, role: t.role, body: mask(t.body) })),
    calls: calls.map((c) => {
      const s = screenOf.get(c.id);
      let transcript: string[] = [];
      try {
        const parsed = JSON.parse(c.transcript_json ?? "[]") as { role?: string; message?: string; text?: string }[];
        transcript = Array.isArray(parsed) ? parsed.slice(0, 40).map((t) => `${t.role ?? "?"}: ${mask(t.message ?? t.text ?? "")}`.slice(0, 240)) : [];
      } catch {
        transcript = [];
      }
      return {
        id: c.id,
        at: c.created_at,
        contact: mask(c.contact_name),
        to: mask(c.to_number),
        direction: s?.direction ?? "outbound",
        caller: mask(s?.caller_phone ?? ""),
        brief: mask(c.brief).slice(0, 200),
        status: c.status,
        error: mask(c.error).slice(0, 200),
        summary: mask(c.summary).slice(0, 300),
        transcript,
      };
    }),
  });
}
