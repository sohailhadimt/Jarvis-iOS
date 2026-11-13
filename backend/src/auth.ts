import { apiError } from "./http";

export interface AuthOk {
  ok: true;
}

export interface AuthRejected {
  ok: false;
  response: Response;
}

/** Drops surrounding space, quotes, and a repeated "Bearer " so a pasted header still matches. */
export function normalizeAppToken(value: string): string {
  let token = value.trim();
  if (
    (token.startsWith('"') && token.endsWith('"') && token.length >= 2) ||
    (token.startsWith("'") && token.endsWith("'") && token.length >= 2)
  ) {
    token = token.slice(1, -1).trim();
  }
  while (/^bearer\s+/i.test(token)) token = token.replace(/^bearer\s+/i, "").trim();
  return token;
}

/**
 * Bearer check for every route except GET /health.
 * A missing Worker secret is 503 so the client can tell "not set up" from "wrong key".
 * The stored secret is trimmed. A trailing newline from a secret paste must not reject the app.
 */
export function authorize(request: Request, expected: string | undefined): AuthOk | AuthRejected {
  const secret = normalizeAppToken(expected ?? "");
  if (!secret) {
    return {
      ok: false,
      response: apiError(
        503,
        "not_configured",
        "JARVIS_APP_TOKEN is not set on the Worker. Run: npx wrangler secret put JARVIS_APP_TOKEN",
      ),
    };
  }
  const header = request.headers.get("Authorization") ?? request.headers.get("x-app-token") ?? "";
  const provided = normalizeAppToken(header);
  if (!provided || !tokensMatch(provided, secret)) {
    return {
      ok: false,
      response: apiError(401, "unauthorized", "Missing or invalid bearer token."),
    };
  }
  return { ok: true };
}

export function tokensMatch(provided: string, expected: string): boolean {
  const a = new TextEncoder().encode(provided);
  const b = new TextEncoder().encode(expected);
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}
