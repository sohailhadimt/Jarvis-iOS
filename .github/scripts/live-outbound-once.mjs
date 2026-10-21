// One approved outbound call through the SMS YES path. A D1 flag stops a second dial.
import { createHmac } from "node:crypto";
import { readFileSync } from "node:fs";

const PURPOSE = "Say hello from JARVIS and ask if he's available tomorrow morning.";
const FLAG = "live_outbound_hello";
const RESULT = "live_outbound_hello_result";

function redact(value) {
  return String(value ?? "")
    .replace(/\+\d[\d\s().-]{6,}/g, "[number]")
    .replace(/\b0\d{9,10}\b/g, "[number]")
    .replace(/\bAC[0-9a-f]{32}\b/gi, "[account]")
    .replace(/\b(?:sk|rk)_[A-Za-z0-9]+/g, "[redacted]")
    .replace(/AIza[0-9A-Za-z_-]+/g, "[redacted]");
}

function log(line) {
  console.log(redact(line));
}

function e164(raw) {
  const trimmed = String(raw ?? "").trim();
  if (!trimmed) return "";
  let digits = "";
  for (const character of trimmed) {
    if (character >= "0" && character <= "9") digits += character;
    else if (character === "+" && digits.length === 0) digits = "+";
  }
  if (digits.startsWith("+")) {
    const body = digits.slice(1);
    return /^\d{8,15}$/.test(body) ? `+${body}` : "";
  }
  if (digits.startsWith("00") && digits.length >= 10) {
    const body = digits.slice(2);
    return /^\d{8,15}$/.test(body) ? `+${body}` : "";
  }
  if (digits.startsWith("0") && digits.length >= 10 && digits.length <= 11) return `+44${digits.slice(1)}`;
  if (/^\d{10,15}$/.test(digits)) return `+${digits}`;
  return "";
}

function databaseId() {
  const toml = readFileSync("wrangler.toml", "utf8");
  const match = /database_id\s*=\s*["']([^"']+)["']/.exec(toml);
  if (!match) throw new Error("wrangler.toml has no database id");
  return match[1];
}

async function d1(sql, params = []) {
  const account = process.env.CLOUDFLARE_ACCOUNT_ID || "";
  const token = process.env.CLOUDFLARE_API_TOKEN || "";
  if (!account || !token) throw new Error("cloudflare credentials are missing");
  const response = await fetch(
    `https://api.cloudflare.com/client/v4/accounts/${account}/d1/database/${databaseId()}/query`,
    {
      method: "POST",
      headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
      body: JSON.stringify({ sql, params }),
    },
  );
  const text = await response.text();
  if (!response.ok) throw new Error(`d1 HTTP ${response.status} ${redact(text).slice(0, 300)}`);
  const parsed = JSON.parse(text);
  if (!parsed.success) throw new Error(`d1 rejected ${redact(JSON.stringify(parsed.errors || [])).slice(0, 300)}`);
  const block = Array.isArray(parsed.result) ? parsed.result[0] : null;
  return {
    changes: Number(block?.meta?.changes ?? 0),
    results: Array.isArray(block?.results) ? block.results : [],
  };
}

async function readFlag() {
  const row = (await d1("SELECT value FROM runtime_state WHERE key = ?", [FLAG])).results[0];
  return row && typeof row.value === "string" ? row.value : "";
}

async function readResult() {
  const row = (await d1("SELECT value FROM runtime_state WHERE key = ?", [RESULT])).results[0];
  if (!row || typeof row.value !== "string") return {};
  try {
    const parsed = JSON.parse(row.value);
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch {
    return {};
  }
}

async function writeResult(patch) {
  const next = { ...(await readResult()), ...patch };
  delete next.phone;
  delete next.to;
  delete next.from;
  const value = JSON.stringify(next);
  await d1(
    `INSERT INTO runtime_state (key, value, updated_at) VALUES (?, ?, ?)
     ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at`,
    [RESULT, value, new Date().toISOString()],
  );
  return next;
}

async function setFlag(value) {
  await d1(
    `INSERT INTO runtime_state (key, value, updated_at) VALUES (?, ?, ?)
     ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at`,
    [FLAG, value, new Date().toISOString()],
  );
}

async function claim() {
  const now = new Date().toISOString();
  const claimed = await d1(
    `INSERT INTO runtime_state (key, value, updated_at) VALUES (?, 'sending', ?)
     ON CONFLICT(key) DO UPDATE SET value = 'sending', updated_at = ?
     WHERE runtime_state.value NOT IN ('sending', 'sent', 'failed')`,
    [FLAG, now, now],
  );
  return claimed.changes;
}

async function savedMobile() {
  try {
    const row = (await d1("SELECT mobile_number AS n FROM call_settings WHERE id = 'default'")).results[0];
    return e164(row?.n ?? "");
  } catch {
    return "";
  }
}

async function findCall(since) {
  const row = (
    await d1(
      `SELECT id, status, twilio_sid, conversation_id, error, substr(COALESCE(summary, ''), 1, 180) AS summary
       FROM outbound_calls
       WHERE brief = ? AND created_at >= ?
       ORDER BY created_at DESC LIMIT 1`,
      [PURPOSE, since],
    )
  ).results[0];
  if (!row) return null;
  return {
    id: String(row.id ?? ""),
    status: String(row.status ?? ""),
    twilio_sid: String(row.twilio_sid ?? ""),
    conversation_id: String(row.conversation_id ?? ""),
    error: redact(row.error ?? ""),
    summary: redact(row.summary ?? ""),
  };
}

async function handoff(callId) {
  if (!/^call_[A-Za-z0-9]+$/.test(callId)) return { path: "", ok: 0, reason: "" };
  const row = (
    await d1("SELECT path, ok, reason FROM call_handoffs WHERE call_id = ? ORDER BY created_at DESC LIMIT 1", [callId])
  ).results[0];
  if (!row) return { path: "", ok: 0, reason: "" };
  return { path: String(row.path ?? ""), ok: Number(row.ok ?? 0), reason: redact(row.reason ?? "") };
}

async function outcomeSent(callId) {
  const row = (await d1("SELECT value FROM runtime_state WHERE key = ?", [`sms_outcome:${callId}`])).results[0];
  if (!row || typeof row.value !== "string") return false;
  try {
    const parsed = JSON.parse(row.value);
    return Boolean(parsed && parsed.sent === true);
  } catch {
    return false;
  }
}

function workerBase() {
  const base = String(process.env.WORKER_URL || "https://jarvis-backend.jarvis-hadi.workers.dev").replace(/\/$/, "");
  if (!base.startsWith("https://")) throw new Error("worker url missing");
  return base;
}

function sign(url, params, token) {
  const names = Object.keys(params).sort();
  let payload = url;
  for (const name of names) payload += name + params[name];
  return createHmac("sha1", token).update(payload).digest("base64");
}

async function postYes(owner, from) {
  const url = `${workerBase()}/calls/sms`;
  const params = { From: owner, To: from, Body: "YES" };
  const response = await fetch(url, {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      "X-Twilio-Signature": sign(url, params, process.env.TWILIO_AUTH_TOKEN),
    },
    body: new URLSearchParams(params),
  });
  return response.status;
}

async function writePending(owner) {
  const pending = {
    name: "them",
    phone: owner,
    purpose: PURPOSE,
    verb: "ask",
    expires_at: new Date(Date.now() + 10 * 60 * 1000).toISOString(),
  };
  await d1(
    `INSERT INTO runtime_state (key, value, updated_at) VALUES ('sms_outbound_yes', ?, ?)
     ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at`,
    [JSON.stringify(pending), new Date().toISOString()],
  );
}

async function twilioGet(path) {
  const sid = process.env.TWILIO_ACCOUNT_SID;
  const token = process.env.TWILIO_AUTH_TOKEN;
  const response = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(sid)}${path}`, {
    headers: { authorization: `Basic ${Buffer.from(`${sid}:${token}`).toString("base64")}` },
  });
  const text = await response.text();
  let body = {};
  try {
    body = JSON.parse(text);
  } catch {
    body = {};
  }
  return { http: response.status, body };
}

function messageKind(text) {
  if (text === "The call did not connect, Sir.") return "outcome_failed";
  if (text.startsWith("Sir,") && !text.includes("Would you like me to call")) return "outcome";
  if (text.startsWith("I'm ringing") || text.startsWith("I’m ringing")) return "confirmation";
  return "";
}

async function recentMessages(sinceMs) {
  const listed = await twilioGet("/Messages.json?PageSize=30");
  const messages = Array.isArray(listed.body.messages) ? listed.body.messages : [];
  const found = [];
  for (const item of messages) {
    const text = typeof item.body === "string" ? item.body : "";
    const kind = messageKind(text);
    if (!kind) continue;
    const when = Date.parse(item.date_created || item.date_sent || "");
    if (Number.isFinite(when) && when + 120_000 < sinceMs) continue;
    found.push({
      kind,
      sid: String(item.sid || ""),
      status: String(item.status || ""),
      error_code: item.error_code == null ? "" : String(item.error_code),
      body: kind === "confirmation" ? "" : redact(text).slice(0, 180),
    });
  }
  return found;
}

async function refreshCall(callId) {
  const token = process.env.JARVIS_APP_TOKEN || "";
  if (!token || !/^call_[A-Za-z0-9]+$/.test(callId)) return;
  await fetch(`${workerBase()}/calls/${callId}`, { headers: { authorization: `Bearer ${token}` } }).catch(() => undefined);
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function watch(seed, sinceMs) {
  let latest = seed;
  let twilio = { status: "", error_code: "", error: "", http: 0 };
  let texts = [];
  let terminalSince = 0;
  const deadline = Date.now() + 7 * 60 * 1000;
  while (Date.now() < deadline) {
    const current = (await findCall(new Date(sinceMs - 120_000).toISOString())) || latest;
    latest = current;
    if (current.twilio_sid) {
      const call = await twilioGet(`/Calls/${encodeURIComponent(current.twilio_sid)}.json`);
      twilio = {
        http: call.http,
        status: String(call.body.status || ""),
        error_code: call.body.error_code == null ? "" : String(call.body.error_code),
        error: redact(call.body.error_message || call.body.message || ""),
      };
    }
    const link = await handoff(current.id);
    if (current.conversation_id || twilio.status === "completed" || twilio.status === "in-progress") {
      await refreshCall(current.id);
    }
    texts = await recentMessages(sinceMs);
    const outcome = texts.find((item) => item.kind === "outcome" || item.kind === "outcome_failed");
    const sms = Boolean(outcome) || (await outcomeSent(current.id));
    const terminal = ["completed", "failed", "busy", "no-answer", "canceled"].includes(twilio.status);
    if (terminal) terminalSince = terminalSince || Date.now();
    log(
      `poll twilio=${twilio.status || "none"} http=${twilio.http} db=${current.status} conversation=${Boolean(current.conversation_id)} handoff=${link.path}:${link.ok} outcome=${sms}`,
    );
    if (terminal && sms) break;
    if (terminal && twilio.status !== "completed" && Date.now() - terminalSince > 75_000) break;
    if (terminal && twilio.status === "completed" && current.summary && Date.now() - terminalSince > 90_000 && sms) break;
    await sleep(12_000);
  }
  const link = await handoff(latest.id);
  const outcome = texts.find((item) => item.kind === "outcome" || item.kind === "outcome_failed");
  const confirmation = texts.find((item) => item.kind === "confirmation");
  const sent = (await outcomeSent(latest.id)) || Boolean(outcome);
  const result = await writeResult({
    call_id: latest.id,
    twilio_sid: latest.twilio_sid,
    twilio_status: twilio.status,
    db_status: latest.status,
    error_code: twilio.error_code,
    error: twilio.error || latest.error,
    conversation: Boolean(latest.conversation_id),
    handoff_path: link.path,
    handoff_ok: link.ok,
    handoff_reason: link.reason,
    outcome_sms: sent,
    outcome_sid: outcome?.sid || "",
    outcome_status: outcome?.status || "",
    outcome_error: outcome?.error_code || "",
    outcome_body: outcome?.body || "",
    confirmation_sid: confirmation?.sid || "",
    confirmation_status: confirmation?.status || "",
  });
  log(`OUTBOUND_RESULT ${JSON.stringify(result)}`);
  const connected = twilio.status === "completed" || twilio.status === "in-progress";
  const eleven = Boolean(latest.conversation_id) || (link.path === "register" && link.ok === 1);
  if (!connected || !eleven || !sent) process.exitCode = 1;
}

async function main() {
  const from = e164(process.env.TWILIO_FROM_NUMBER);
  const owner = e164(process.env.OWNER_PHONE);
  const saved = await savedMobile();
  const sender = saved || owner;
  if (!from || !owner || !sender || !process.env.TWILIO_ACCOUNT_SID || !process.env.TWILIO_AUTH_TOKEN) {
    log("calling secrets are missing");
    process.exit(1);
  }
  log(`owner_match=${Boolean(saved) && saved === owner} saved=${Boolean(saved)}`);
  if (owner === from) {
    await setFlag("failed");
    await writeResult({ error: "destination matched the twilio number" });
    log("destination matched the twilio number");
    process.exit(1);
  }

  const flag = await readFlag();
  if (flag === "failed") {
    log(`already failed ${JSON.stringify(await readResult())}`);
    process.exit(0);
  }
  if (flag === "sent") {
    const stored = await readResult();
    log(`already sent ${JSON.stringify(stored)}`);
    if (stored.twilio_sid && stored.outcome_sms && (stored.twilio_status === "completed" || stored.twilio_status === "in-progress")) {
      process.exit(0);
    }
    if (stored.twilio_sid) {
      await watch(
        {
          id: String(stored.call_id || ""),
          status: String(stored.db_status || ""),
          twilio_sid: String(stored.twilio_sid),
          conversation_id: "",
          error: String(stored.error || ""),
          summary: "",
        },
        Date.parse(stored.at || "") || Date.now() - 30 * 60 * 1000,
      );
      return;
    }
    process.exit(0);
  }

  const since = new Date().toISOString();
  if (flag !== "sending") {
    const changes = await claim();
    if (changes !== 1) {
      log(`claim changes=${changes}; not dialling`);
      process.exit(0);
    }
  } else {
    const existing = await findCall(new Date(Date.now() - 2 * 60 * 60 * 1000).toISOString());
    if (existing?.twilio_sid) {
      log(`resume ${existing.id}`);
      await setFlag("sent");
      await watch(existing, Date.now() - 2 * 60 * 60 * 1000);
      return;
    }
    if (existing) {
      await setFlag("failed");
      await writeResult({ call_id: existing.id, error: existing.error || "no sid", db_status: existing.status });
      log(`dial rejected ${existing.status} ${existing.error}`);
      process.exit(1);
    }
    log("previous claim did not dial; continuing once");
  }

  await writeResult({ phase: "claimed", at: since });
  await writePending(owner);
  const http = await postYes(sender, from);
  log(`sms webhook HTTP ${http}`);
  if (http !== 200) {
    await setFlag("failed");
    await writeResult({ error: `webhook HTTP ${http}` });
    process.exit(1);
  }

  let row = null;
  for (let attempt = 0; attempt < 12 && !row?.twilio_sid; attempt += 1) {
    await sleep(5_000);
    row = await findCall(since);
    if (row && !row.twilio_sid && row.status === "failed") break;
  }
  if (!row) {
    await setFlag("failed");
    await writeResult({ error: "no outbound row after YES" });
    log("no outbound row after YES");
    process.exit(1);
  }
  if (!row.twilio_sid) {
    await setFlag("failed");
    await writeResult({ call_id: row.id, error: row.error || "twilio rejected", db_status: row.status });
    log(`no sid status=${row.status} error=${row.error}`);
    process.exit(1);
  }
  await setFlag("sent");
  await writeResult({ call_id: row.id, twilio_sid: row.twilio_sid, at: since });
  await watch(row, Date.parse(since));
}

main().catch((err) => {
  log(err instanceof Error ? err.message : "outbound step failed");
  process.exit(1);
});
