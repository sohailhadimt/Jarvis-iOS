import { dbRun } from "./db";
import { json, nowIso } from "./http";
import { toE164 } from "./calls";
import type { Env } from "./types";

const LIVE_STATUSES = ["queued", "ringing", "in-progress"];
const OPEN_ROWS = ["screening", "listening", "handling", "message", "connecting", "ringing", "in_progress", "wrapping"];

interface TwilioCall {
  sid: string;
  from: string;
  to: string;
  status: string;
}

/** Ends every live call on the JARVIS line, every JARVIS conference, and closes open call cards. */
export async function hangUpEverything(env: Env): Promise<Response> {
  const account = (env.TWILIO_ACCOUNT_SID ?? "").trim();
  const token = (env.TWILIO_AUTH_TOKEN ?? "").trim();
  const auth = `Basic ${btoa(`${account}:${token}`)}`;
  const base = `https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(account)}`;
  const ended: string[] = [];
  const errors: string[] = [];
  let conferences = 0;
  if (account && token) {
    for (const status of LIVE_STATUSES) {
      const calls = await twilioGet<{ calls?: TwilioCall[] }>(`${base}/Calls.json?Status=${status}&PageSize=50`, auth);
      for (const call of calls?.calls ?? []) {
        const done = await complete(`${base}/Calls/${encodeURIComponent(call.sid)}.json`, auth);
        if (done) ended.push(call.sid.slice(-6));
        else errors.push(`call ${call.sid.slice(-6)}`);
      }
    }
    const confs = await twilioGet<{ conferences?: { sid: string; friendly_name: string }[] }>(
      `${base}/Conferences.json?Status=in-progress&PageSize=50`,
      auth,
    );
    for (const conf of confs?.conferences ?? []) {
      if (await complete(`${base}/Conferences/${encodeURIComponent(conf.sid)}.json`, auth)) conferences += 1;
      else errors.push(`conference ${conf.sid.slice(-6)}`);
    }
    const waiting = await twilioGet<{ conferences?: { sid: string }[] }>(`${base}/Conferences.json?Status=init&PageSize=50`, auth);
    for (const conf of waiting?.conferences ?? []) {
      if (await complete(`${base}/Conferences/${encodeURIComponent(conf.sid)}.json`, auth)) conferences += 1;
    }
  }
  const closed = await closeOpenRows(env, 0);
  return json({ ok: errors.length === 0, calls_ended: ended.length, conferences_ended: conferences, cards_closed: closed, errors });
}

/** Closes call cards older than maxAgeMs (0 closes all). Returns rows changed. */
export async function closeOpenRows(env: Env, maxAgeMs: number): Promise<number> {
  const cutoff = new Date(Date.now() - maxAgeMs).toISOString();
  try {
    return await dbRun(
      env,
      `UPDATE outbound_calls SET status = 'completed', updated_at = ?
       WHERE status IN (${OPEN_ROWS.map(() => "?").join(", ")}) AND created_at <= ?
         AND (id IN (SELECT call_id FROM call_screen WHERE direction = 'inbound') OR brief = 'Owner on his JARVIS line')`,
      [nowIso(), ...OPEN_ROWS, cutoff],
    );
  } catch {
    return 0;
  }
}

/** Twilio's view of one call: true only while the leg can still be moved. */
export async function callIsLive(env: Env, callSid: string): Promise<boolean> {
  const account = (env.TWILIO_ACCOUNT_SID ?? "").trim();
  const token = (env.TWILIO_AUTH_TOKEN ?? "").trim();
  if (!account || !token || !callSid) return false;
  const auth = `Basic ${btoa(`${account}:${token}`)}`;
  const call = await twilioGet<TwilioCall>(
    `https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(account)}/Calls/${encodeURIComponent(callSid)}.json`,
    auth,
  );
  if (!call) return true; // Twilio unreachable: do not block the owner on a read failure.
  return LIVE_STATUSES.includes(call.status);
}

export function isOwnerCaller(caller: string | null, owner: string | null): boolean {
  if (!caller || !owner) return false;
  // Caller ID only. "+44 07…", "0044…", "447…" and "07…" are the same UK line.
  const canon = (raw: string) => {
    const e164 = toE164(raw);
    return e164 ? e164.replace(/^\+440(?=\d{9,10}$)/, "+44") : null;
  };
  const a = canon(caller);
  return Boolean(a) && a === canon(owner);
}

async function twilioGet<T>(url: string, auth: string): Promise<T | null> {
  try {
    const response = await fetch(url, { headers: { authorization: auth }, redirect: "manual", signal: AbortSignal.timeout(10_000) });
    if (!response.ok) return null;
    return (await response.json()) as T;
  } catch {
    return null;
  }
}

async function complete(url: string, auth: string): Promise<boolean> {
  try {
    const response = await fetch(url, {
      method: "POST",
      redirect: "manual",
      signal: AbortSignal.timeout(10_000),
      headers: { authorization: auth, "content-type": "application/x-www-form-urlencoded" },
      body: "Status=completed",
    });
    return response.ok;
  } catch {
    return false;
  }
}
