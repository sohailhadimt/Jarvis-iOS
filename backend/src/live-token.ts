import { apiError, isRecord, json } from "./http";
import { GEMINI_LIVE_MODEL, type Env } from "./types";

const TOKEN_URL = "https://generativelanguage.googleapis.com/v1beta/auth_tokens";
const SOCKET_URL =
  "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContentConstrained";

export interface LiveTicket {
  ok: true;
  token: string;
  model: string;
  websocket_url: string;
  expires_at: string;
  session_expires_at: string;
}

export interface LiveTicketFailure {
  ok: false;
  reason: "not_configured" | "quota" | "unavailable";
  status: number;
}

/** Mints a one-use Live token. The Gemini API key stays on the worker. */
export async function mintGeminiLiveToken(env: Env, now = Date.now()): Promise<LiveTicket | LiveTicketFailure> {
  const key = (env.GEMINI_API_KEY ?? "").trim();
  if (!key) return { ok: false, reason: "not_configured", status: 503 };
  const expires = new Date(now + 30 * 60 * 1000).toISOString();
  // A slow start used to miss the 2 minute new-session window and fall back with no error.
  const sessionBy = new Date(now + 10 * 60 * 1000).toISOString();
  let response: Response;
  try {
    response = await fetch(TOKEN_URL, {
      method: "POST",
      redirect: "manual",
      signal: AbortSignal.timeout(8_000),
      headers: {
        "x-goog-api-key": key,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        uses: 1,
        expireTime: expires,
        newSessionExpireTime: sessionBy,
      }),
    });
  } catch {
    return { ok: false, reason: "unavailable", status: 502 };
  }
  const text = await response.text().catch(() => "");
  if (response.status === 429) return { ok: false, reason: "quota", status: 429 };
  // Gemini's own 401 must not look like a rejected app token. The phone treats 401 as that sentence.
  if (!response.ok) {
    const status = response.status === 401 || response.status === 403 ? 502 : response.status || 502;
    return { ok: false, reason: "unavailable", status };
  }
  const token = tokenName(text);
  if (!token) return { ok: false, reason: "unavailable", status: 502 };
  return {
    ok: true,
    token,
    model: GEMINI_LIVE_MODEL,
    websocket_url: `${SOCKET_URL}?access_token=${encodeURIComponent(token)}`,
    expires_at: expires,
    session_expires_at: sessionBy,
  };
}

export async function liveTokenResponse(env: Env): Promise<Response> {
  const ticket = await mintGeminiLiveToken(env);
  if (!ticket.ok) {
    const message =
      ticket.reason === "not_configured"
        ? "GEMINI_API_KEY is not set on the Worker."
        : ticket.reason === "quota"
          ? "Gemini Live is over its quota."
          : "Gemini Live could not mint a token.";
    return apiError(ticket.status, ticket.reason, message);
  }
  return json(ticket);
}

function tokenName(text: string): string {
  try {
    const parsed = JSON.parse(text) as unknown;
    if (!isRecord(parsed)) return "";
    const name = typeof parsed.name === "string" ? parsed.name.trim() : "";
    return name;
  } catch {
    return "";
  }
}
