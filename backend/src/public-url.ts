import type { Env } from "./types";

/**
 * Every URL handed to Twilio (Url, StatusCallback, TwiML action/Play) is built here.
 *
 * Why: the worker used to remember the origin of the last authenticated request. Agent lanes call the
 * worker through a service binding at https://jarvis-lane, so that internal origin was saved and Twilio
 * rejected the call with 21205 "Url is not a valid URL". A fixed public base cannot drift like that.
 */
export const PUBLIC_BASE_URL = "https://jarvis-backend.jarvis-hadi.workers.dev";

const INTERNAL_HOST = /^(localhost|jarvis-lane|internal|self|127\.|0\.0\.0\.0|\[)/i;

/** An origin Twilio can reach: https, a dotted public host name, no credentials. */
export function isPublicOrigin(value: string | null | undefined): boolean {
  const origin = normaliseOrigin(value);
  return Boolean(origin);
}

/** "https://host" with no path or trailing slash, or "" when the value is not a public https origin. */
export function normaliseOrigin(value: string | null | undefined): string {
  const raw = String(value ?? "").trim();
  if (!raw) return "";
  let url: URL;
  try {
    url = new URL(raw.replace(/^http:\/\//i, "https://"));
  } catch {
    return "";
  }
  if (url.protocol !== "https:") return "";
  if (url.username || url.password) return "";
  const host = url.hostname;
  if (!host.includes(".") || host.endsWith(".") || INTERNAL_HOST.test(host)) return "";
  if (/^\d+\.\d+\.\d+\.\d+$/.test(host)) return "";
  return url.origin;
}

/** The base for callbacks: PUBLIC_BASE_URL (env, then the fixed host), then the caller's own origin. */
export function publicBase(env?: Pick<Env, "PUBLIC_BASE_URL"> | null, fallback?: string | null): string {
  return normaliseOrigin(env?.PUBLIC_BASE_URL) || PUBLIC_BASE_URL || normaliseOrigin(fallback);
}

/** Candidate bases in order, each valid and distinct. The second and third are only used on a retry. */
export function baseCandidates(env?: Pick<Env, "PUBLIC_BASE_URL"> | null, fallback?: string | null): string[] {
  const list = [normaliseOrigin(env?.PUBLIC_BASE_URL), PUBLIC_BASE_URL, normaliseOrigin(fallback)].filter(Boolean);
  return [...new Set(list)];
}

/** A validated absolute URL: base + path, with query values URL-encoded. Throws when the result is not valid. */
export function twilioUrl(base: string, path: string, query: Record<string, string | number> = {}): string {
  const origin = normaliseOrigin(base);
  if (!origin) throw new Error("callback base is not a public https origin");
  const url = new URL(path.startsWith("/") ? path : `/${path}`, origin);
  for (const [key, value] of Object.entries(query)) url.searchParams.set(key, String(value));
  const out = url.toString();
  if (!isValidTwilioUrl(out)) throw new Error("callback URL is not valid");
  return out;
}

export function isValidTwilioUrl(value: string): boolean {
  try {
    const url = new URL(value);
    return url.protocol === "https:" && Boolean(normaliseOrigin(url.origin)) && !/\s/.test(value);
  } catch {
    return false;
  }
}

const URL_FIELDS = ["Url", "StatusCallback", "FallbackUrl", "RecordingStatusCallback", "AsyncAmdStatusCallback"];

/** Every URL in a Calls.json form, including those inside inline TwiML (action=, url=, <Play>, <Redirect>). */
export function formUrls(form: URLSearchParams): string[] {
  const urls: string[] = [];
  for (const field of URL_FIELDS) for (const value of form.getAll(field)) urls.push(value);
  const twiml = form.get("Twiml") ?? "";
  for (const match of twiml.matchAll(/(?:action|url|statusCallback)="([^"]*)"/gi)) urls.push(unescapeXml(match[1]));
  for (const match of twiml.matchAll(/<(?:Play|Redirect)[^>]*>([^<]*)<\//gi)) urls.push(unescapeXml(match[1].trim()));
  return urls;
}

/** Names the first invalid URL field, or "" when every URL in the form is valid. */
export function invalidFormUrl(form: URLSearchParams): string {
  for (const url of formUrls(form)) if (!isValidTwilioUrl(url)) return url ? "callback URL" : "empty callback URL";
  return "";
}

function unescapeXml(value: string): string {
  return value.replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");
}

/** Twilio's "Url is not a valid URL" family (21205, 21201 invalid callback, 21609 invalid StatusCallback). */
export function isUrlError(body: string): boolean {
  try {
    const parsed = JSON.parse(body) as { code?: number; message?: string };
    if (parsed.code === 21205 || parsed.code === 21609 || parsed.code === 21201) return true;
    return /not a valid url/i.test(parsed.message ?? "");
  } catch {
    return /21205|not a valid url/i.test(body);
  }
}

export interface TwilioCallAttempt {
  ok: boolean;
  status: number;
  body: string;
  base: string;
  retried: boolean;
}

/**
 * POST Calls.json with a form built for a base. Before sending, every URL is validated; an invalid one
 * moves to the next base. If Twilio still answers with a URL error, the form is rebuilt on the next base
 * and sent once more. Nothing is dialled by a rejected request, so the retry cannot double-call.
 */
export async function createTwilioCall(
  env: Env,
  build: (base: string) => URLSearchParams,
  options: { fallbackOrigin?: string | null; timeoutMs?: number; fetcher?: typeof fetch } = {},
): Promise<TwilioCallAttempt> {
  const account = (env.TWILIO_ACCOUNT_SID ?? "").trim();
  const token = (env.TWILIO_AUTH_TOKEN ?? "").trim();
  const doFetch = options.fetcher ?? fetch;
  const bases = baseCandidates(env, options.fallbackOrigin);
  let last: TwilioCallAttempt = { ok: false, status: 0, body: '{"message":"Calling is not set up."}', base: "", retried: false };
  if (!account || !token) return last;
  let sent = 0;
  for (const base of bases) {
    let form: URLSearchParams;
    try {
      form = build(base);
    } catch (err) {
      console.error("twilio form build failed", base, err instanceof Error ? err.message : "build");
      continue;
    }
    const bad = invalidFormUrl(form);
    if (bad) {
      console.error("twilio form has an invalid URL; trying the next base", base, bad);
      last = { ok: false, status: 0, body: JSON.stringify({ code: 21205, message: `Invalid ${bad} before send` }), base, retried: sent > 0 };
      continue;
    }
    if (sent >= 2) break;
    sent += 1;
    try {
      const response = await doFetch(`https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(account)}/Calls.json`, {
        method: "POST",
        redirect: "manual",
        signal: AbortSignal.timeout(options.timeoutMs ?? 20_000),
        headers: {
          authorization: `Basic ${btoa(`${account}:${token}`)}`,
          "content-type": "application/x-www-form-urlencoded",
        },
        body: form.toString(),
      });
      const body = await response.text();
      last = { ok: response.ok, status: response.status, body, base, retried: sent > 1 };
      if (response.ok) return last;
      if (!isUrlError(body)) return last;
      console.error("twilio rejected a callback URL; retrying on the fallback base", base, body.slice(0, 200));
    } catch (err) {
      last = { ok: false, status: 0, body: JSON.stringify({ message: err instanceof Error ? err.message : "Twilio could not be reached." }), base, retried: sent > 1 };
      return last;
    }
  }
  return last;
}
