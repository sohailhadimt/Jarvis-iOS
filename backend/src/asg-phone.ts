/**
 * ASG receptionist line. Callers other than the owner reach a separate ElevenLabs agent
 * (looked up by name, so no id is committed). Leads land in the asg_leads D1 table.
 * Outbound calls are for consented callbacks only: each request must carry a consent note.
 */
import { registerElevenLabsCall } from "./calls";
import { dbAll, dbFirst, dbRun } from "./db";
import { apiError, isRecord, json, newId, nowIso } from "./http";
import type { Env } from "./types";

export const ASG_AGENT_NAME = "ASG Receptionist";
let cachedAgent = "";

export async function asgAgentId(env: Env): Promise<string> {
  const pinned = (env.ASG_AGENT_ID ?? "").trim();
  if (pinned) return pinned;
  if (cachedAgent) return cachedAgent;
  const key = (env.ELEVENLABS_API_KEY ?? "").trim();
  if (!key) return "";
  try {
    const res = await fetch(`https://api.elevenlabs.io/v1/convai/agents?search=${encodeURIComponent(ASG_AGENT_NAME)}`, {
      headers: { "xi-api-key": key },
      signal: AbortSignal.timeout(2500),
    });
    if (!res.ok) return "";
    const body = (await res.json()) as { agents?: { agent_id?: string; name?: string }[] };
    const hit = (body.agents ?? []).find((a) => a.name === ASG_AGENT_NAME && a.agent_id);
    cachedAgent = hit?.agent_id ?? "";
  } catch {
    return "";
  }
  return cachedAgent;
}

/** Off unless ASG_LINE is not "off". Owner number always keeps JARVIS. */
export function asgLineOn(env: Env): boolean {
  return (env.ASG_LINE ?? "on").trim() !== "off";
}

/** Returns TwiML for the ASG agent, or null so the caller falls back to JARVIS. */
export async function asgTwiml(env: Env, id: string, from: string, to: string, direction: "inbound" | "outbound"): Promise<string | null> {
  const agentId = await asgAgentId(env);
  if (!agentId) {
    console.error("asg agent not found");
    return null;
  }
  const result = await registerElevenLabsCall(env, {
    id,
    from,
    to,
    direction,
    first: "",
    prompt: "",
    contact: "ASG caller",
    brief: "ASG receptionist",
    agentId,
  });
  console.log("asg hand-off", JSON.stringify({ call: id, direction, ok: Boolean(result.twiml), reason: result.reason }));
  return result.twiml;
}

async function ensureTable(env: Env): Promise<void> {
  await dbRun(
    env,
    `CREATE TABLE IF NOT EXISTS asg_leads (
      id TEXT PRIMARY KEY, call_id TEXT, conversation_id TEXT, phone TEXT, caller_name TEXT, company TEXT,
      role TEXT, company_size TEXT, needs TEXT, email TEXT, preferred_times TEXT, summary TEXT,
      do_not_contact INTEGER DEFAULT 0, transcript TEXT, status TEXT DEFAULT 'new', created_at TEXT)`,
  );
}

/** Called from the post-call webhook for every conversation; ignores non-ASG agents. */
export async function captureAsgLead(env: Env, data: Record<string, unknown>): Promise<boolean> {
  const agentId = typeof data.agent_id === "string" ? data.agent_id : "";
  if (!agentId || agentId !== (await asgAgentId(env))) return false;
  const analysis = isRecord(data.analysis) ? data.analysis : {};
  const results = isRecord(analysis.data_collection_results) ? analysis.data_collection_results : {};
  const pick = (k: string): string => {
    const r = results[k];
    const v = isRecord(r) ? r.value : null;
    return v === null || v === undefined ? "" : String(v).slice(0, 500);
  };
  const meta = isRecord(data.metadata) ? data.metadata : {};
  const phoneCall = isRecord(meta.phone_call) ? meta.phone_call : {};
  const phone = String(phoneCall.external_number ?? "");
  const init = isRecord(data.conversation_initiation_client_data) ? data.conversation_initiation_client_data : {};
  const transcript = Array.isArray(data.transcript)
    ? data.transcript
        .filter(isRecord)
        .map((t) => `${t.role === "agent" ? "ASG" : "Caller"}: ${String(t.message ?? "")}`)
        .join("\n")
        .slice(0, 8000)
    : "";
  await ensureTable(env);
  await dbRun(
    env,
    `INSERT INTO asg_leads (id, call_id, conversation_id, phone, caller_name, company, role, company_size, needs, email,
      preferred_times, summary, do_not_contact, transcript, status, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'new', ?)`,
    [
      newId("lead"),
      String(init.user_id ?? ""),
      String(data.conversation_id ?? ""),
      phone,
      pick("caller_name"),
      pick("company"),
      pick("role"),
      pick("company_size"),
      pick("needs"),
      pick("email"),
      pick("preferred_times"),
      pick("summary") || String(analysis.transcript_summary ?? "").slice(0, 1000),
      pick("do_not_contact") === "true" ? 1 : 0,
      transcript,
      nowIso(),
    ],
  );
  try {
    const hotText = `${pick("summary")} ${pick("needs")} ${String(analysis.transcript_summary ?? "")}`;
    const { fireAlert, isHotLead } = await import("./proactive-alert");
    const origin = (await dbFirst<{ worker_origin: string }>(env, "SELECT worker_origin FROM call_settings WHERE id = 'default'"))?.worker_origin;
    if (origin && pick("do_not_contact") !== "true" && isHotLead(hotText)) {
      await fireAlert(env, {
        type: "hot_lead",
        summary: `A caller to the ASG line wants to buy. ${pick("needs")}`.slice(0, 300),
        who: [pick("caller_name"), pick("company")].filter(Boolean).join(" from "),
        value: "",
        when: pick("preferred_times"),
        meet_link: "",
        details: [pick("email"), pick("summary")].filter(Boolean).join(" | ").slice(0, 600),
        dedupe_key: `lead:${String(data.conversation_id ?? "")}`,
      }, origin.replace(/\/$/, ""));
    }
  } catch {
    // An alert failure never loses the lead.
  }
  return true;
}

/** App-token routes: GET /asg/leads, POST /asg/leads/:id (status), POST /asg/callback. */
export async function routeAsg(request: Request, env: Env, path: string): Promise<Response | null> {
  if (!path.startsWith("/asg/")) return null;
  if (request.method === "GET" && path === "/asg/leads") {
    await ensureTable(env);
    const rows = await dbAll(env, "SELECT * FROM asg_leads ORDER BY created_at DESC LIMIT 100");
    return json({ leads: rows });
  }
  const one = /^\/asg\/leads\/(lead_[A-Za-z0-9]+)$/.exec(path);
  if (request.method === "POST" && one) {
    const body = (await request.json().catch(() => ({}))) as { status?: string };
    await dbRun(env, "UPDATE asg_leads SET status = ? WHERE id = ?", [String(body.status ?? "booked").slice(0, 40), one[1]]);
    return json({ ok: true });
  }
  if (request.method === "POST" && path === "/asg/callback") return placeCallback(request, env);
  return null;
}

function e164(raw: string): string {
  const v = raw.replace(/[^\d+]/g, "");
  if (/^\+\d{8,15}$/.test(v)) return v;
  if (/^0\d{9,10}$/.test(v)) return `+44${v.slice(1)}`;
  return "";
}

async function placeCallback(request: Request, env: Env): Promise<Response> {
  const body = (await request.json().catch(() => null)) as { to?: string; consent?: string; name?: string } | null;
  const to = e164(String(body?.to ?? ""));
  const consent = String(body?.consent ?? "").trim();
  if (!to) return apiError(400, "bad_number", "Give a valid phone number.");
  if (consent.length < 10) return apiError(400, "consent_required", "Describe the prospect's request to be called back (consent).");
  await ensureTable(env);
  const blocked = await dbFirst(env, "SELECT id FROM asg_leads WHERE phone = ? AND do_not_contact = 1 LIMIT 1", [to]);
  if (blocked) return apiError(409, "do_not_contact", "This number asked not to be contacted.");
  const from = (env.TWILIO_FROM_NUMBER ?? "").trim();
  const sid = (env.TWILIO_ACCOUNT_SID ?? "").trim();
  const token = (env.TWILIO_AUTH_TOKEN ?? "").trim();
  if (!from || !sid || !token) return apiError(503, "not_configured", "Twilio is not configured.");
  const id = newId("call");
  const now = nowIso();
  await dbRun(
    env,
    `INSERT INTO outbound_calls (id, contact_name, to_number, brief, status, twilio_sid, conversation_id, transcript_json, summary, error, created_at, updated_at)
     VALUES (?, ?, ?, ?, 'placing', NULL, NULL, '[]', NULL, NULL, ?, ?)`,
    [id, String(body?.name ?? "ASG callback").slice(0, 80), to, `ASG consented callback: ${consent.slice(0, 300)}`, now, now],
  );
  const origin = new URL(request.url).origin.replace("http:", "https:");
  const form = new URLSearchParams({ To: to, From: from, Url: `${origin}/asg/voice/${id}`, Method: "POST", TimeLimit: "360" });
  const res = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(sid)}/Calls.json`, {
    method: "POST",
    headers: { authorization: `Basic ${btoa(`${sid}:${token}`)}`, "content-type": "application/x-www-form-urlencoded" },
    body: form.toString(),
  });
  const text = await res.text();
  if (!res.ok) {
    await dbRun(env, "UPDATE outbound_calls SET status = 'failed', error = ? WHERE id = ?", [text.slice(0, 300), id]);
    return apiError(502, "twilio_failed", text.slice(0, 300));
  }
  const twilioSid = (JSON.parse(text) as { sid?: string }).sid ?? "";
  await dbRun(env, "UPDATE outbound_calls SET twilio_sid = ?, status = 'in_progress' WHERE id = ?", [twilioSid, id]);
  return json({ ok: true, call_id: id });
}

/** Twilio fetches this when the callback is answered. */
export async function asgVoiceWebhook(request: Request, env: Env, id: string): Promise<Response> {
  const { twilioRequestSigned } = await import("./calls");
  const params: Record<string, string> = {};
  (await request.formData()).forEach((v, k) => (params[k] = String(v)));
  const ok = await twilioRequestSigned(request, params, (env.TWILIO_AUTH_TOKEN ?? "").trim());
  const xml = (b: string) => new Response(b, { headers: { "content-type": "text/xml; charset=utf-8" } });
  if (!ok) return xml("<Response><Hangup/></Response>");
  const row = await dbFirst<{ to_number: string }>(env, "SELECT to_number FROM outbound_calls WHERE id = ?", [id]);
  if (!row) return xml("<Response><Hangup/></Response>");
  const twiml = await asgTwiml(env, id, (env.TWILIO_FROM_NUMBER ?? "").trim(), row.to_number, "outbound");
  return xml(twiml ?? `<Response><Say language="en-GB">Sorry, ASG can't take this call right now. Sohail will be in touch. Goodbye.</Say><Hangup/></Response>`);
}
