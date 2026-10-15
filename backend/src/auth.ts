import { apiError } from "./http";

export interface AuthOk {
  ok: true;
}

export interface AuthRejected {
  ok: false;
  response: Response;
}

/**
 * Bearer check for every route except GET /health.
 * A missing Worker secret is 503 so the client can tell "not set up" from "wrong key".
 */
export function authorize(request: Request, expected: string | undefined): AuthOk | AuthRejected {
  if (!expected) {
    return {
      ok: false,
      response: apiError(
        503,
        "not_configured",
        "JARVIS_APP_TOKEN is not set on the Worker. Run: npx wrangler secret put JARVIS_APP_TOKEN",
      ),
    };
  }
  const header = request.headers.get("Authorization") ?? "";
  const match = /^Bearer\s+(\S+)\s*$/i.exec(header);
  if (!match) {
    return {
      ok: false,
      response: apiError(401, "unauthorized", "Missing or invalid bearer token."),
    };
  }
  if (!tokensMatch(match[1], expected)) {
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
