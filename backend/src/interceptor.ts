import { PASS_ALONG, toE164 } from "./calls";
import { getState, setState } from "./db";
import { apiError, isRecord, json } from "./http";
import type { Env } from "./types";

/** First words when a forwarded call is answered. */
export const INTERCEPTOR_GREETING =
  "You've reached Sohail Hadi's line. He's unavailable right now. I'm J.A.R.V.I.S., his assistant. May I take a message?";

/** Played when the interceptor and busy mode are both off. */
export const INTERCEPTOR_DECLINE = "Please try again later.";

const ENABLED_KEY = "interceptor_enabled";
const BUSY_KEY = "interceptor_busy";

export interface InterceptorState {
  enabled: boolean;
  busy: boolean;
}

/** A carrier forward. ForwardedFrom is the owner's line. Called is used when it is not the Twilio number. */
export function forwardedCall(
  params: Record<string, string>,
  twilioNumber: string | null,
): { forwarded: boolean; original: string | null } {
  const diverted = toE164(params.ForwardedFrom ?? "");
  if (diverted) return { forwarded: true, original: diverted };
  const called = toE164(params.Called ?? "");
  const to = toE164(params.To ?? "") ?? twilioNumber;
  if (called && to && called !== to) return { forwarded: true, original: called };
  return { forwarded: false, original: null };
}

/** The switch answers forwarded calls. Busy mode answers as well, so a Focus can turn it on. */
export function interceptorAnswers(state: InterceptorState): boolean {
  return state.enabled || state.busy;
}

export function interceptorPrompt(): string {
  return [
    "You are JARVIS, Sohail Hadi's personal assistant, answering a call that was forwarded from his mobile.",
    `Your first spoken words are exactly: "${INTERCEPTOR_GREETING}"`,
    "Then listen. Take their name and a short message.",
    "Never claim to be Sohail Hadi. Do not reveal his schedule, location, address, numbers, email, health, or finances.",
    `When the message is complete, say exactly: "${PASS_ALONG}" Then thank them and end the call.`,
    "British English. Short turns.",
  ].join("\n");
}

export function missedCallerLine(shown: string): string {
  const who = shown.replace(/\s+/g, " ").trim();
  if (!who) return "Sir, you missed a call.";
  return `Sir, you missed a call from ${who}.`;
}

/** Missing row means the interceptor is on. Busy mode starts off. A database error keeps answering. */
export async function readInterceptor(env: Env): Promise<InterceptorState> {
  try {
    const enabled = await getState(env, ENABLED_KEY);
    const busy = await getState(env, BUSY_KEY);
    return {
      enabled: enabled == null ? true : enabled === "1",
      busy: busy === "1",
    };
  } catch {
    return { enabled: true, busy: false };
  }
}

export async function writeInterceptor(
  env: Env,
  patch: { enabled?: boolean; busy?: boolean },
): Promise<InterceptorState> {
  if (typeof patch.enabled === "boolean") await setState(env, ENABLED_KEY, patch.enabled ? "1" : "0");
  if (typeof patch.busy === "boolean") await setState(env, BUSY_KEY, patch.busy ? "1" : "0");
  return readInterceptor(env);
}

export async function interceptorRoute(request: Request, env: Env): Promise<Response> {
  if (request.method === "GET") return json(await readInterceptor(env));
  if (request.method !== "POST") return apiError(405, "method_not_allowed", "Use GET or POST.");
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return apiError(400, "bad_request", "Request body must be JSON.");
  }
  if (!isRecord(body)) return apiError(400, "bad_request", "JSON body must be an object.");
  const enabled = typeof body.enabled === "boolean" ? body.enabled : undefined;
  const busy = typeof body.busy === "boolean" ? body.busy : undefined;
  if (enabled === undefined && busy === undefined) {
    return apiError(400, "bad_request", "Say whether the interceptor or busy mode is on.");
  }
  try {
    return json(await writeInterceptor(env, { enabled, busy }));
  } catch {
    return apiError(503, "unavailable", "Busy mode could not be saved.");
  }
}
