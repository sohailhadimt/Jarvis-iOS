import { getState, setState } from "./db";
import type { Env } from "./types";

/**
 * WhatsApp through Twilio. Inert until TWILIO_WHATSAPP_FROM is set (the sandbox number or his own approved sender).
 * Inbound WhatsApp hits the same signed SMS webhook; replies go back on WhatsApp while his 24-hour window is open.
 */
export const WA_WINDOW_MS = 23 * 60 * 60_000;

export function whatsappFrom(env: Env): string | null {
  const raw = (env.TWILIO_WHATSAPP_FROM ?? "").trim().replace(/^whatsapp:/i, "");
  return /^\+\d{8,15}$/.test(raw) ? `whatsapp:${raw}` : null;
}

export function isWhatsAppSender(from: string): boolean {
  return /^whatsapp:\+\d{8,15}$/i.test(from.trim());
}

export function stripWhatsApp(from: string): string {
  return from.trim().replace(/^whatsapp:/i, "");
}

/** He wrote on WhatsApp: answer him there until the service window closes. */
export async function openWindow(env: Env, phone: string, now = Date.now()): Promise<void> {
  await setState(env, `wa_window:${phone}`, String(now + WA_WINDOW_MS));
}

/** The WhatsApp From to reply with, or null to use plain SMS. */
export async function replyChannel(env: Env, phone: string, now = Date.now()): Promise<string | null> {
  const from = whatsappFrom(env);
  if (!from) return null;
  const until = Number((await getState(env, `wa_window:${phone}`).catch(() => null)) ?? "0");
  return until > now ? from : null;
}
