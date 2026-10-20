import { awayFirstMessage, awayPrompt, readActiveAway, rememberRecording } from "./call-desk";
import { recordHandoff } from "./stream";
import { dbAll, dbFirst, dbRun } from "./db";
import {
  FALLBACK_SAY_VOICE,
  INBOUND_GREETING,
  approvedScreening,
  callingSecrets,
  guessCaller,
  registerElevenLabsCall,
  safeError,
  screeningScript,
  smsAction,
  toE164,
  twilioRequestSigned,
  type CallLine,
} from "./calls";
import { apiError, asString, isRecord, json, newId, nowIso } from "./http";
import type { Env } from "./types";

const ACTIVE = ["screening", "listening", "handling", "message", "connecting", "ringing", "in_progress", "wrapping"];

export function isScreenWebhook(method: string, path: string): boolean {
  if (method !== "POST") return false;
  if (path === "/calls/inbound" || path === "/calls/sms") return true;
  return /^\/calls\/(?:join|voicemail)\/[A-Za-z0-9_]+$/.test(path);
}

export function inboundFallbackResponse(): Response {
  return xml(takeMessage(`${INBOUND_GREETING} Please leave your name and a message after the tone, and I will pass it to Master Hadi.`), 200);
}

export async function handleScreenWebhook(request: Request, env: Env, path: string, ctx: ExecutionContext): Promise<Response> {
  const setup = callingSecrets(env);
  if (!setup.configured) {
    console.error("inbound call is not configured", setup.missing.join(","));
    if (path === "/calls/inbound") return xml(takeMessage(`${INBOUND_GREETING} Please leave your name and a message after the tone, and I will pass it to Master Hadi.`), 200);
    return xml(say(`${INBOUND_GREETING} I'm sorry, call screening is not set up. Goodbye.`), 503);
  }
  if (path === "/calls/inbound") {
    try {
      return await inboundCall(request, env, ctx);
    } catch (err) {
      console.error("inbound call failed", safeError(err instanceof Error ? err.message : "inbound"));
      return inboundFallbackResponse();
    }
  }
  if (path === "/calls/sms") return smsWebhook(request, env, ctx);
  const id = path.split("/").pop() ?? "";
  if (path.startsWith("/calls/voicemail/")) return voicemailWebhook(request, env, id);
  return joinWebhook(request, env, id);
}

export async function routeScreeningApi(request: Request, env: Env, path: string): Promise<Response | null> {
  const parts = path.split("/").filter(Boolean);
  if (request.method === "GET" && path === "/calls/active") return activeCalls(env);
  if (request.method === "POST" && path === "/calls/device") return saveDevice(request, env);
  if (request.method === "POST" && path === "/calls/permissions") return savePermissions(request, env);
  if (parts[0] !== "calls" || !parts[1] || !/^call_[A-Za-z0-9]+$/.test(parts[1])) return null;
  if (request.method === "POST" && parts[2] === "screen" && parts.length === 3) return decide(request, env, parts[1]);
  if (request.method === "POST" && parts[2] === "personal" && parts.length === 3) return setPersonal(request, env, parts[1]);
  return null;
}

async function inboundCall(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const token = (env.TWILIO_AUTH_TOKEN ?? "").trim();
  const params = await formParams(request);
  const valid = await twilioRequestSigned(request, params, token);
  if (!valid) {
    const url = new URL(request.url);
    console.error("inbound signature rejected", JSON.stringify({ host: url.host, path: url.pathname, token: Boolean(token), fields: Object.keys(params).sort().join(",") }));
    return xml(say("Hello, this is JARVIS, Master Hadi's personal assistant. This call could not be verified. Goodbye."), 403);
  }
  const caller = toE164(params.From ?? "");
  const ours = toE164(env.TWILIO_FROM_NUMBER ?? "");
  const dialed = toE164(params.To ?? "") ?? ours;
  if (!caller || (ours && caller === ours)) return xml("<Response><Hangup/></Response>", 200);
  const permission = await matchPermission(env, caller);
  const id = newId("call");
  const now = nowIso();
  const sid = params.CallSid ?? "";
  try {
    await dbRun(
      env,
      `INSERT INTO outbound_calls
        (id, contact_name, to_number, brief, status, twilio_sid, conversation_id, transcript_json, summary, error, created_at, updated_at)
       VALUES (?, 'Incoming call', ?, 'Screen this call', 'screening', ?, NULL, '[]', NULL, NULL, ?, ?)`,
      [id, caller, sid || null, now, now],
    );
    await dbRun(
      env,
      `INSERT INTO call_screen
        (call_id, direction, caller_phone, caller_name, reason, decision, personal_allowed, personal_requested, personal_note, conference_name, notified_at, named_notified)
       VALUES (?, 'inbound', ?, '', '', NULL, ?, 0, ?, ?, NULL, 0)`,
      [id, caller, permission.allow ? 1 : 0, permission.note, `jarvis-${id}`],
    );
  } catch (err) {
    console.error("inbound call was not stored", safeError(err instanceof Error ? err.message : "insert failed"));
  }
  ctx.waitUntil(notify(env, id, caller, "", ""));
  ctx.waitUntil(learnCaller(env, id, new URL(request.url).origin));
  if (sid) ctx.waitUntil(startCallRecording(env, sid, id));
  const away = await readActiveAway(env);
  const first = away ? awayFirstMessage(away.instruction) : INBOUND_GREETING;
  const prompt = away ? awayPrompt(away.instruction) : permission.allow ? approvedScreening(permission.note) : screeningScript();
  const connected = await registerElevenLabsCall(env, {
    id,
    from: caller,
    to: dialed || caller,
    direction: "inbound",
    first,
    prompt,
    contact: "Caller",
    brief: away ? away.instruction : "Find out who is calling and why. Do not reveal personal information.",
  });
  if (!connected.twiml) {
    const reason = connected.reason || "no_twiml";
    const detail = connected.error || "ElevenLabs did not return TwiML.";
    await dbRun(env, "UPDATE outbound_calls SET status = 'message', error = ?, updated_at = ? WHERE id = ?", [
      detail,
      nowIso(),
      id,
    ]).catch(() => undefined);
    await recordHandoff(env, { callId: id, path: "register", ok: false, reason, detail });
    return xml(
      takeMessage(
        `${first} Please leave your name and a message after the tone, and I will pass it to Master Hadi.`,
        voicemailCallback(request, id),
      ),
      200,
    );
  }
  await recordHandoff(env, { callId: id, path: "register", ok: true, reason: "twiml" });
  if (connected.conversationId) {
    await dbRun(env, "UPDATE outbound_calls SET conversation_id = ?, status = 'screening', updated_at = ? WHERE id = ?", [
      connected.conversationId,
      nowIso(),
      id,
    ]).catch(() => undefined);
  }
  return new Response(connected.twiml, { status: 200, headers: { "content-type": "text/xml; charset=utf-8" } });
}

function voicemailCallback(request: Request, id: string): string {
  const voicemail = new URL(request.url);
  voicemail.protocol = "https:";
  voicemail.pathname = `/calls/voicemail/${id}`;
  voicemail.search = "";
  return voicemail.toString();
}

async function voicemailWebhook(request: Request, env: Env, id: string): Promise<Response> {
  const token = (env.TWILIO_AUTH_TOKEN ?? "").trim();
  const params = await formParams(request);
  const valid = await twilioRequestSigned(request, params, token);
  if (!valid) return xml("<Response></Response>", 403);
  const spoken = (params.TranscriptionText || "").replace(/\s+/g, " ").trim();
  const summary = spoken
    ? `They left a message: ${spoken.slice(0, 220)} I'll get back to them.`
    : "A caller left a message. The recording is with Twilio.";
  await dbRun(
    env,
    "UPDATE outbound_calls SET status = 'completed', summary = ?, updated_at = ? WHERE id = ? AND (summary IS NULL OR summary = '')",
    [summary, nowIso(), id],
  ).catch(() => undefined);
  await recordHandoff(env, { callId: id, path: "voicemail", ok: true, reason: spoken ? "transcribed" : "recorded" });
  const { rememberInboundMessage } = await import("./call-messages");
  const owned = await rememberInboundMessage(env, id).catch(() => false);
  if (!owned) {
    const { readOwnerMobile } = await import("./owner-alert");
    const to = await readOwnerMobile(env);
    const from = toE164(env.TWILIO_FROM_NUMBER ?? "");
    const account = (env.TWILIO_ACCOUNT_SID ?? "").trim();
    if (to && from && account && token) {
      const form = new URLSearchParams({ From: from, To: to, Body: `Call summary: ${summary}`.slice(0, 320) });
      await fetch(`https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(account)}/Messages.json`, {
        method: "POST",
        headers: {
          authorization: `Basic ${btoa(`${account}:${token}`)}`,
          "content-type": "application/x-www-form-urlencoded",
        },
        body: form.toString(),
      }).catch(() => undefined);
    }
  }
  return xml("<Response></Response>", 200);
}

async function smsWebhook(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const token = (env.TWILIO_AUTH_TOKEN ?? "").trim();
  const params = await formParams(request);
  const valid = await twilioRequestSigned(request, params, token);
  if (!valid) return xml("<Response></Response>", 403);
  const body = params.Body ?? "";
  const from = params.From ?? "";
  const action = smsAction(body);
  if (action) {
    const { readOwnerMobile } = await import("./owner-alert");
    const owner = await readOwnerMobile(env);
    const sender = toE164(from);
    if (owner && sender === owner) {
      const row = await dbFirst<{ id: string }>(
        env,
        `SELECT outbound_calls.id AS id
         FROM outbound_calls
         JOIN call_screen ON call_screen.call_id = outbound_calls.id
         WHERE call_screen.direction = 'inbound' AND outbound_calls.status IN ('screening','listening','handling','message','connecting','in_progress','ringing')
         ORDER BY outbound_calls.created_at DESC LIMIT 1`,
      );
      if (row) {
        const origin = new URL(request.url).origin;
        if (action === "allow" || action === "deny") {
          await applyPersonal(env, row.id, action === "allow", "", origin);
        } else if (action === "connect") {
          await applyDecision(env, row.id, "connect", origin);
        } else {
          await applyDecision(env, row.id, action, origin);
        }
        return xml("<Response></Response>", 200);
      }
    }
  }
  if (body.trim()) {
    ctx.waitUntil(
      import("./sms-desk").then((mod) => mod.handleInboundSms(env, from, body).catch(() => undefined)),
    );
  }
  return xml("<Response></Response>", 200);
}

async function joinWebhook(request: Request, env: Env, id: string): Promise<Response> {
  const token = (env.TWILIO_AUTH_TOKEN ?? "").trim();
  const params = await formParams(request);
  const valid = await twilioRequestSigned(request, params, token);
  if (!valid) return xml(say("This call could not be verified. Goodbye."), 403);
  const muted = new URL(request.url).searchParams.get("muted") === "1";
  const room = `jarvis-${id}`;
  const flag = muted ? ' muted="true"' : "";
  return xml(
    `<Response><Dial><Conference beep="false" startConferenceOnEnter="true" endConferenceOnExit="true"${flag}>${escapeXml(room)}</Conference></Dial></Response>`,
    200,
  );
}

async function decide(request: Request, env: Env, id: string): Promise<Response> {
  const body = await readBody(request);
  if (!body.ok) return body.response;
  const action = asString(body.value.action, 20);
  if (action !== "connect" && action !== "handle" && action !== "message" && action !== "decline" && action !== "listen" && action !== "takeover") {
    return apiError(400, "bad_request", "action must be connect, handle, message, decline, listen, or takeover.");
  }
  const result = await applyDecision(env, id, action, new URL(request.url).origin);
  if (!result.ok) return result.response;
  return json({ ok: true, action, audio: result.audio });
}

async function setPersonal(request: Request, env: Env, id: string): Promise<Response> {
  const body = await readBody(request);
  if (!body.ok) return body.response;
  if (typeof body.value.allow !== "boolean") return apiError(400, "bad_request", "allow must be true or false.");
  const note = typeof body.value.note === "string" ? body.value.note.trim().slice(0, 1000) : "";
  const result = await applyPersonal(env, id, body.value.allow, note, new URL(request.url).origin);
  if (!result.ok) return result.response;
  return json({ ok: true, personal_allowed: body.value.allow });
}

async function applyDecision(
  env: Env,
  id: string,
  action: "connect" | "handle" | "message" | "decline" | "listen" | "takeover",
  origin: string,
): Promise<{ ok: true; audio: string } | { ok: false; response: Response }> {
  const call = await dbFirst<{ twilio_sid: string | null; status: string }>(env, "SELECT twilio_sid, status FROM outbound_calls WHERE id = ?", [id]);
  if (!call) return { ok: false, response: apiError(404, "not_found", "Call not found.") };
  const { readOwnerMobile } = await import("./owner-alert");
  const mobile = await readOwnerMobile(env);
  const from = toE164(env.TWILIO_FROM_NUMBER ?? "");
  if (action === "listen") {
    await dbRun(env, "UPDATE call_screen SET decision = 'listen' WHERE call_id = ?", [id]).catch(() => undefined);
    await dbRun(env, "UPDATE outbound_calls SET status = 'listening', updated_at = ? WHERE id = ?", [nowIso(), id]);
    return { ok: true, audio: "transcript" };
  }
  if ((action === "connect" || action === "takeover") && (!mobile || !from)) {
    return {
      ok: false,
      response: json(
        {
          configured: false,
          message: "Calling not set up.",
          missing: ["OWNER_PHONE"],
          error: { code: "mobile_not_set", message: "Set your mobile in Calling settings, or set the OWNER_PHONE secret on the worker." },
        },
        503,
      ),
    };
  }
  if (!call.twilio_sid) return { ok: false, response: apiError(409, "not_ready", "The call is not connected yet.") };
  if (action === "decline") {
    const updated = await updateTwiml(env, call.twilio_sid, say("I'm sorry, Master Hadi can't take your call. Goodbye."));
    if (!updated.ok) return { ok: false, response: apiError(502, "twilio", updated.error) };
    await mark(env, id, "declined", "decline");
    return { ok: true, audio: "none" };
  }
  if (action === "connect") {
    const twiml = `<Response><Say language="en-GB" voice="${FALLBACK_SAY_VOICE}">I'll put you through to Master Hadi.</Say><Dial callerId="${escapeXml(from ?? "")}"><Number>${escapeXml(mobile ?? "")}</Number></Dial></Response>`;
    const updated = await updateTwiml(env, call.twilio_sid, twiml);
    if (!updated.ok) return { ok: false, response: apiError(502, "twilio", updated.error) };
    await mark(env, id, "connecting", "connect");
    return { ok: true, audio: "mobile" };
  }
  if (action === "takeover") {
    const room = `jarvis-${id}`;
    const dialed = await createCall(env, mobile ?? "", from ?? "", `<?xml version="1.0" encoding="UTF-8"?><Response>${joinTwiml(room, false)}</Response>`);
    if (!dialed.ok) return { ok: false, response: apiError(502, "twilio", dialed.error) };
    const moved = await updateTwiml(
      env,
      call.twilio_sid,
      `<Response><Say language="en-GB" voice="${FALLBACK_SAY_VOICE}">Connecting you to Master Hadi.</Say>${joinTwiml(room, false)}</Response>`,
    );
    if (!moved.ok) return { ok: false, response: apiError(502, "twilio", moved.error) };
    await mark(env, id, "connecting", "takeover");
    return { ok: true, audio: "mobile" };
  }
  const mode = action === "handle" ? "handle" : "message";
  const moved = await redirectCall(env, call.twilio_sid, id, mode, origin);
  if (!moved.ok) return { ok: false, response: apiError(502, "twilio", moved.error) };
  await mark(env, id, action === "handle" ? "handling" : "message", action);
  return { ok: true, audio: "agent" };
}

async function applyPersonal(env: Env, id: string, allow: boolean, note = "", origin = ""): Promise<{ ok: true } | { ok: false; response: Response }> {
  const call = await dbFirst<{ twilio_sid: string | null }>(env, "SELECT twilio_sid FROM outbound_calls WHERE id = ?", [id]);
  if (!call) return { ok: false, response: apiError(404, "not_found", "Call not found.") };
  const storedNote = allow ? note : "";
  try {
    await dbRun(
      env,
      "UPDATE call_screen SET personal_allowed = ?, personal_note = CASE WHEN ? != '' THEN ? ELSE personal_note END, personal_requested = 1 WHERE call_id = ?",
      [allow ? 1 : 0, storedNote, storedNote, id],
    );
  } catch {
    return { ok: false, response: apiError(503, "call_log_unavailable", "The screening table is not ready. Apply schema.sql on D1.") };
  }
  if (allow && call.twilio_sid && origin) {
    await redirectCall(env, call.twilio_sid, id, "handle", origin);
    await dbRun(env, "UPDATE outbound_calls SET status = 'handling', updated_at = ? WHERE id = ?", [nowIso(), id]);
  }
  return { ok: true };
}

async function redirectCall(env: Env, callSid: string, id: string, mode: string, origin: string): Promise<{ ok: true } | { ok: false; error: string }> {
  const account = (env.TWILIO_ACCOUNT_SID ?? "").trim();
  const token = (env.TWILIO_AUTH_TOKEN ?? "").trim();
  const form = new URLSearchParams();
  form.set("Url", `${origin.replace(/\/$/, "")}/calls/voice/${id}?mode=${mode}`);
  form.set("Method", "POST");
  return twilioPost(account, token, `/2010-04-01/Accounts/${encodeURIComponent(account)}/Calls/${encodeURIComponent(callSid)}.json`, form);
}

async function activeCalls(env: Env): Promise<Response> {
  try {
    const rows = await dbAll<{
      id: string;
      contact_name: string;
      to_number: string;
      brief: string;
      status: string;
      transcript_json: string;
      summary: string | null;
      error: string | null;
      created_at: string;
      updated_at: string;
      caller_name: string;
      reason: string;
      personal_allowed: number;
      personal_requested: number;
      personal_note: string;
      decision: string | null;
    }>(
      env,
      `SELECT c.id, c.contact_name, c.to_number, c.brief, c.status, c.transcript_json, c.summary, c.error, c.created_at, c.updated_at,
              s.caller_name, s.reason, s.personal_allowed, s.personal_requested, s.personal_note, s.decision
       FROM outbound_calls c
       JOIN call_screen s ON s.call_id = c.id
       WHERE s.direction = 'inbound' AND c.status IN (${ACTIVE.map(() => "?").join(", ")})
       ORDER BY c.created_at DESC LIMIT 10`,
      ACTIVE,
    );
    return json({
      calls: rows.map((row) => ({
        id: row.id,
        contact_name: row.contact_name,
        to: row.to_number,
        brief: row.brief,
        status: row.status,
        transcript: parseTranscript(row.transcript_json),
        summary: row.summary,
        error: row.error,
        created_at: row.created_at,
        updated_at: row.updated_at,
        direction: "inbound",
        caller_name: row.caller_name || null,
        reason: row.reason || null,
        personal_allowed: row.personal_allowed === 1,
        personal_requested: row.personal_requested === 1,
        personal_note: row.personal_note || "",
        decision: row.decision,
      })),
    });
  } catch {
    return apiError(503, "call_log_unavailable", "The screening table is not ready. Apply schema.sql on D1.");
  }
}

async function saveDevice(request: Request, env: Env): Promise<Response> {
  const body = await readBody(request);
  if (!body.ok) return body.response;
  const token = asString(body.value.token, 400);
  if (!token || !/^[0-9a-fA-F]+$/.test(token)) return apiError(400, "bad_request", "token must be the APNs device token in hex.");
  try {
    await dbRun(env, "INSERT INTO call_devices (token, updated_at) VALUES (?, ?) ON CONFLICT(token) DO UPDATE SET updated_at = excluded.updated_at", [
      token.toLowerCase(),
      nowIso(),
    ]);
  } catch {
    return apiError(503, "call_log_unavailable", "The device table is not ready. Apply schema.sql on D1.");
  }
  return json({ ok: true });
}

async function savePermissions(request: Request, env: Env): Promise<Response> {
  const body = await readBody(request);
  if (!body.ok) return body.response;
  if (!Array.isArray(body.value.rules)) return apiError(400, "bad_request", "rules must be a list.");
  const rules = body.value.rules.slice(0, 100);
  try {
    await dbRun(env, "DELETE FROM call_permissions");
    for (const rule of rules) {
      if (!isRecord(rule)) continue;
      const name = asString(rule.name, 120);
      if (!name) continue;
      const phone = typeof rule.phone === "string" ? toE164(rule.phone) : null;
      const allow = rule.allow_personal === true ? 1 : 0;
      const note = typeof rule.note === "string" ? rule.note.trim().slice(0, 1000) : "";
      await dbRun(
        env,
        "INSERT INTO call_permissions (id, name, phone, allow_personal, note, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
        [newId("perm"), name, phone, allow, note, nowIso()],
      );
    }
  } catch {
    return apiError(503, "call_log_unavailable", "The permissions table is not ready. Apply schema.sql on D1.");
  }
  return json({ ok: true });
}

async function matchPermission(env: Env, phone: string): Promise<{ allow: boolean; note: string }> {
  try {
    const row = await dbFirst<{ allow_personal: number; note: string }>(
      env,
      "SELECT allow_personal, note FROM call_permissions WHERE phone = ? AND allow_personal = 1 LIMIT 1",
      [phone],
    );
    if (!row) return { allow: false, note: "" };
    return { allow: true, note: row.note || "" };
  } catch {
    return { allow: false, note: "" };
  }
}

async function learnCaller(env: Env, id: string, origin: string): Promise<void> {
  await sleep(8000);
  const row = await dbFirst<{ conversation_id: string | null; named_notified: number }>(
    env,
    `SELECT c.conversation_id AS conversation_id, s.named_notified AS named_notified
     FROM outbound_calls c JOIN call_screen s ON s.call_id = c.id WHERE c.id = ?`,
    [id],
  ).catch(() => null);
  if (!row?.conversation_id || row.named_notified === 1) return;
  const key = (env.ELEVENLABS_API_KEY ?? "").trim();
  if (!key) return;
  try {
    const response = await fetch(`https://api.elevenlabs.io/v1/convai/conversations/${encodeURIComponent(row.conversation_id)}`, {
      headers: { "xi-api-key": key },
      signal: AbortSignal.timeout(15_000),
    });
    if (!response.ok) return;
    const payload = (await response.json()) as unknown;
    const lines: CallLine[] = [];
    if (isRecord(payload) && Array.isArray(payload.transcript)) {
      for (const item of payload.transcript) {
        if (!isRecord(item)) continue;
        const text = typeof item.message === "string" ? item.message.trim() : "";
        if (!text) continue;
        lines.push({ role: item.role === "user" ? "them" : "assistant", text });
      }
    }
    const guess = guessCaller(lines);
    if (!guess.name && !guess.reason) return;
    await dbRun(
      env,
      "UPDATE call_screen SET caller_name = CASE WHEN ? != '' THEN ? ELSE caller_name END, reason = CASE WHEN ? != '' THEN ? ELSE reason END, named_notified = 1 WHERE call_id = ?",
      [guess.name, guess.name, guess.reason, guess.reason, id],
    );
    const phone = await dbFirst<{ caller_phone: string; personal_allowed: number }>(
      env,
      "SELECT caller_phone, personal_allowed FROM call_screen WHERE call_id = ?",
      [id],
    );
    if (guess.name && phone && phone.personal_allowed !== 1) {
      const named = await dbFirst<{ note: string }>(
        env,
        "SELECT note FROM call_permissions WHERE lower(name) = lower(?) AND allow_personal = 1 LIMIT 1",
        [guess.name],
      ).catch(() => null);
      if (named) {
        await dbRun(env, "UPDATE call_screen SET personal_allowed = 1, personal_note = ? WHERE call_id = ?", [named.note || "", id]);
        const sid = await dbFirst<{ twilio_sid: string | null }>(env, "SELECT twilio_sid FROM outbound_calls WHERE id = ?", [id]);
        if (sid?.twilio_sid) await redirectCall(env, sid.twilio_sid, id, "handle", origin);
      }
    }
    await notify(env, id, phone?.caller_phone ?? "", guess.name, guess.reason);
  } catch {
    // A missed follow-up still leaves the live card to poll.
  }
}

async function notify(env: Env, id: string, phone: string, name: string, reason: string): Promise<void> {
  const who = name || "Someone";
  const why = reason ? ` About: ${reason}` : "";
  const body = `${who} is calling${phone ? ` from ${phone}` : ""}.${why} Reply CONNECT, HANDLE, MESSAGE, or DECLINE.`;
  const pushed = await pushNotice(env, who, body, { call_id: id });
  if (!pushed) await sendSms(env, body);
  await dbRun(env, "UPDATE call_screen SET notified_at = ? WHERE call_id = ?", [nowIso(), id]).catch(() => undefined);
}

export async function pushNotice(
  env: Env,
  title: string,
  body: string,
  extra: Record<string, string>,
  category = "JARVIS_CALL",
): Promise<boolean> {
  const jwt = await apnsJwt(env);
  if (!jwt) return false;
  let tokens: { token: string }[] = [];
  try {
    tokens = await dbAll<{ token: string }>(env, "SELECT token FROM call_devices ORDER BY updated_at DESC LIMIT 5");
  } catch {
    return false;
  }
  if (tokens.length === 0) return false;
  const host = env.APNS_ENVIRONMENT === "sandbox" ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com";
  const topic = env.APNS_BUNDLE_ID?.trim() || "com.sohail.jarvis";
  let ok = false;
  for (const row of tokens) {
    const response = await fetch(`${host}/3/device/${row.token}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${jwt}`,
        "apns-topic": topic,
        "apns-push-type": "alert",
        "apns-priority": "10",
      },
      body: JSON.stringify({
        aps: { alert: { title, body }, sound: "default", category },
        ...extra,
      }),
    }).catch(() => null);
    if (response?.ok) ok = true;
  }
  return ok;
}

async function apnsJwt(env: Env): Promise<string | null> {
  const keyId = env.APNS_KEY_ID?.trim();
  const teamId = env.APNS_TEAM_ID?.trim();
  const raw = env.APNS_PRIVATE_KEY?.trim();
  if (!keyId || !teamId || !raw) return null;
  try {
    const der = pemToDer(raw);
    const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
    const header = b64url(JSON.stringify({ alg: "ES256", kid: keyId }));
    const claims = b64url(JSON.stringify({ iss: teamId, iat: Math.floor(Date.now() / 1000) }));
    const signed = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(`${header}.${claims}`));
    return `${header}.${claims}.${b64urlBytes(new Uint8Array(signed))}`;
  } catch (err) {
    console.error("apns key could not be read", safeError(err instanceof Error ? err.message : "apns"));
    return null;
  }
}

async function sendSms(env: Env, body: string): Promise<void> {
  const { readOwnerMobile } = await import("./owner-alert");
  const to = await readOwnerMobile(env);
  const from = toE164(env.TWILIO_FROM_NUMBER ?? "");
  const account = (env.TWILIO_ACCOUNT_SID ?? "").trim();
  const token = (env.TWILIO_AUTH_TOKEN ?? "").trim();
  if (!to || !from || !account || !token) return;
  const form = new URLSearchParams({ From: from, To: to, Body: clip(body, 320) });
  await twilioPost(account, token, `/2010-04-01/Accounts/${encodeURIComponent(account)}/Messages.json`, form);
}

async function createCall(env: Env, to: string, from: string, twiml: string): Promise<{ ok: true } | { ok: false; error: string }> {
  const account = (env.TWILIO_ACCOUNT_SID ?? "").trim();
  const token = (env.TWILIO_AUTH_TOKEN ?? "").trim();
  const form = new URLSearchParams({ To: to, From: from, Twiml: twiml });
  return twilioPost(account, token, `/2010-04-01/Accounts/${encodeURIComponent(account)}/Calls.json`, form);
}

async function updateTwiml(env: Env, callSid: string, twiml: string): Promise<{ ok: true } | { ok: false; error: string }> {
  const account = (env.TWILIO_ACCOUNT_SID ?? "").trim();
  const token = (env.TWILIO_AUTH_TOKEN ?? "").trim();
  const form = new URLSearchParams({ Twiml: twiml });
  return twilioPost(account, token, `/2010-04-01/Accounts/${encodeURIComponent(account)}/Calls/${encodeURIComponent(callSid)}.json`, form);
}

async function twilioPost(account: string, token: string, path: string, form: URLSearchParams): Promise<{ ok: true } | { ok: false; error: string }> {
  try {
    const response = await fetch(`https://api.twilio.com${path}`, {
      method: "POST",
      redirect: "error",
      signal: AbortSignal.timeout(20_000),
      headers: {
        authorization: `Basic ${btoa(`${account}:${token}`)}`,
        "content-type": "application/x-www-form-urlencoded",
      },
      body: form.toString(),
    });
    if (response.ok) return { ok: true };
    const text = await response.text();
    return { ok: false, error: twilioMessage(text) };
  } catch (err) {
    return { ok: false, error: safeError(err instanceof Error ? err.message : "Twilio could not be reached.") };
  }
}

async function startCallRecording(env: Env, callSid: string, id: string): Promise<void> {
  const account = (env.TWILIO_ACCOUNT_SID ?? "").trim();
  const token = (env.TWILIO_AUTH_TOKEN ?? "").trim();
  if (!account || !token || !callSid) return;
  try {
    const response = await fetch(
      `https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(account)}/Calls/${encodeURIComponent(callSid)}/Recordings.json`,
      {
        method: "POST",
        redirect: "error",
        signal: AbortSignal.timeout(8_000),
        headers: {
          authorization: `Basic ${btoa(`${account}:${token}`)}`,
          "content-type": "application/x-www-form-urlencoded",
        },
        body: "",
      },
    );
    if (!response.ok) return;
    const payload = (await response.json()) as { sid?: string };
    if (payload.sid) await rememberRecording(env, id, payload.sid);
  } catch {
    // Playback appears once Twilio has a recording. The call itself continues.
  }
}

async function mark(env: Env, id: string, status: string, decision: string): Promise<void> {
  await dbRun(env, "UPDATE outbound_calls SET status = ?, updated_at = ? WHERE id = ?", [status, nowIso(), id]);
  await dbRun(env, "UPDATE call_screen SET decision = ? WHERE call_id = ?", [decision, id]).catch(() => undefined);
}

function joinTwiml(room: string, muted: boolean): string {
  const flag = muted ? ' muted="true"' : "";
  return `<Dial><Conference beep="false" startConferenceOnEnter="true" endConferenceOnExit="true"${flag}>${escapeXml(room)}</Conference></Dial>`;
}

async function readBody(request: Request): Promise<{ ok: true; value: Record<string, unknown> } | { ok: false; response: Response }> {
  try {
    const value = (await request.json()) as unknown;
    if (!isRecord(value)) return { ok: false, response: apiError(400, "bad_request", "JSON body must be an object.") };
    return { ok: true, value };
  } catch {
    return { ok: false, response: apiError(400, "bad_request", "Request body must be JSON.") };
  }
}

async function formParams(request: Request): Promise<Record<string, string>> {
  const params = new URLSearchParams(await request.text());
  const fields: Record<string, string> = {};
  for (const [key, value] of params.entries()) fields[key] = value;
  return fields;
}

function parseTranscript(raw: string): CallLine[] {
  try {
    const parsed = JSON.parse(raw) as unknown;
    if (!Array.isArray(parsed)) return [];
    return parsed.flatMap((item) => {
      if (!isRecord(item) || typeof item.text !== "string") return [];
      const role = item.role === "them" ? "them" : "assistant";
      return [{ role, text: item.text }];
    });
  } catch {
    return [];
  }
}

function pemToDer(raw: string): ArrayBuffer {
  const body = raw.replace(/-----BEGIN PRIVATE KEY-----/g, "").replace(/-----END PRIVATE KEY-----/g, "").replace(/\s+/g, "");
  const binary = atob(body);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes.buffer;
}

function b64url(value: string): string {
  return b64urlBytes(new TextEncoder().encode(value));
}

function b64urlBytes(bytes: Uint8Array): string {
  let text = "";
  for (const byte of bytes) text += String.fromCharCode(byte);
  return btoa(text).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

function twilioMessage(text: string): string {
  try {
    const parsed = JSON.parse(text) as { message?: string };
    if (typeof parsed.message === "string") return safeError(parsed.message);
  } catch {
    // The body was not JSON.
  }
  return safeError(text || "Twilio refused the call.");
}

function say(line: string): string {
  return `<?xml version="1.0" encoding="UTF-8"?><Response><Say language="en-GB" voice="${FALLBACK_SAY_VOICE}">${escapeXml(line)}</Say><Hangup/></Response>`;
}

function takeMessage(line: string, voicemailUrl = ""): string {
  const callback = voicemailUrl ? ` transcribe="true" transcribeCallback="${escapeXml(voicemailUrl)}"` : "";
  return `<?xml version="1.0" encoding="UTF-8"?><Response><Say language="en-GB" voice="${FALLBACK_SAY_VOICE}">${escapeXml(line)}</Say><Record maxLength="120" playBeep="true"${callback}/><Hangup/></Response>`;
}

function xml(body: string, status: number): Response {
  return new Response(body, { status, headers: { "content-type": "text/xml; charset=utf-8" } });
}

function escapeXml(value: string): string {
  return value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;");
}

function clip(value: string, max: number): string {
  if (value.length <= max) return value;
  return `${value.slice(0, max)}…`;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
