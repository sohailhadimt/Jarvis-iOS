// One YES-path call. A stored retry flag stops a second dial.
import { createHmac } from "node:crypto";
import { readFileSync } from "node:fs";

const PURPOSE = "Say hello from JARVIS and ask if he's available tomorrow morning.";
const FLAG = "live_outbound_hello";
const RESULT = "live_outbound_hello_result";

function redact(value) {
  return String(value ?? "")
    .replace(/\+\d[\d\s().-]{6,}/g, "[number]")
    .replace(/\b0\d{9,10}\b/g, "[number]")
    .replace(/\bAC[0-9a-f]{32}\b/gi, "[account]");
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
  if (digits.startsWith("+")) return /^\d{8,15}$/.test(digits.slice(1)) ? digits : "";
  if (digits.startsWith("00") && digits.length >= 10) return `+${digits.slice(2)}`;
  if (digits.startsWith("0") && digits.length >= 10 && digits.length <= 11) return `+44${digits.slice(1)}`;
  if (/^\d{10,15}$/.test(digits)) return `+${digits}`;
  return "";
}

function databaseId() {
  const match = /database_id\s*=\s*["']([^"']+)["']/.exec(readFileSync("wrangler.toml", "utf8"));
  if (!match) throw new Error("wrangler.toml has no database id");
  return match[1];
}

async function d1(sql, params = []) {
  const account = process.env.CLOUDFLARE_ACCOUNT_ID || "";
  const token = process.env.CLOUDFLARE_API_TOKEN || "";
  const response = await fetch(
    `https://api.cloudflare.com/client/v4/accounts/${account}/d1/database/${databaseId()}/query`,
    {
      method: "POST",
      headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
      body: JSON.stringify({ sql, params }),
    },
  );
  const text = await response.text();
  if (!response.ok) throw new Error(`d1 HTTP ${response.status} ${redact(text).slice(0, 240)}`);
  const parsed = JSON.parse(text);
  const block = Array.isArray(parsed.result) ? parsed.result[0] : null;
  return { changes: Number(block?.meta?.changes ?? 0), results: Array.isArray(block?.results) ? block.results : [] };
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
  await d1(
    `INSERT INTO runtime_state (key, value, updated_at) VALUES (?, ?, ?)
     ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at`,
    [RESULT, JSON.stringify(next), new Date().toISOString()],
  );
  return next;
}

function workerBase() {
  const base = String(process.env.WORKER_URL || "https://jarvis-backend.jarvis-hadi.workers.dev").replace(/\/$/, "");
  if (!base.startsWith("https://")) throw new Error("worker url missing");
  return base;
}

function sign(url, params, token) {
  let payload = url;
  for (const name of Object.keys(params).sort()) payload += name + params[name];
  return createHmac("sha1", token).update(payload).digest("base64");
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function main() {
  const stored = await readResult();
  if (stored.retried || stored.twilio_sid) {
    log(`OUTBOUND_RESULT ${JSON.stringify({ skipped: true, ...stored })}`);
    return;
  }
  const from = e164(process.env.TWILIO_FROM_NUMBER);
  const owner = e164(process.env.OWNER_PHONE);
  if (!from || !owner || owner === from || !process.env.TWILIO_ACCOUNT_SID || !process.env.TWILIO_AUTH_TOKEN) {
    log("OUTBOUND_RESULT {\"error\":\"calling secrets missing or destination matched the twilio number\"}");
    process.exitCode = 1;
    return;
  }
  let sender = owner;
  try {
    const row = (await d1("SELECT mobile_number AS n FROM call_settings WHERE id = 'default'")).results[0];
    sender = e164(row?.n ?? "") || owner;
  } catch {
    sender = owner;
  }
  const since = new Date().toISOString();
  await writeResult({ retried: true, at: since });
  const claimed = await d1(
    `INSERT INTO runtime_state (key, value, updated_at) VALUES (?, 'sending', ?)
     ON CONFLICT(key) DO UPDATE SET value = 'sending', updated_at = ?
     WHERE runtime_state.value NOT IN ('sending', 'sent')`,
    [FLAG, since, since],
  );
  if (claimed.changes !== 1) {
    log("OUTBOUND_RESULT {\"error\":\"claim missed\"}");
    return;
  }
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
  const url = `${workerBase()}/calls/sms`;
  const params = { From: sender, To: from, Body: "YES" };
  const webhook = await fetch(url, {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      "X-Twilio-Signature": sign(url, params, process.env.TWILIO_AUTH_TOKEN),
    },
    body: new URLSearchParams(params),
  });
  log(`sms webhook HTTP ${webhook.status}`);
  if (webhook.status !== 200) {
    await writeResult({ error: `webhook HTTP ${webhook.status}` });
    process.exitCode = 1;
    return;
  }
  let row = null;
  for (let attempt = 0; attempt < 8 && !row; attempt += 1) {
    await sleep(4_000);
    row = (
      await d1(
        `SELECT id, status, twilio_sid, error FROM outbound_calls
         WHERE brief = ? AND created_at >= ? ORDER BY created_at DESC LIMIT 1`,
        [PURPOSE, since],
      )
    ).results[0];
    if (row && !row.twilio_sid && row.status !== "failed") row = null;
  }
  const error = redact(row?.error ?? "");
  const code = /Twilio\s+(\d+)/.exec(error)?.[1] || "";
  if (!row?.twilio_sid) {
    await d1(
      `UPDATE runtime_state SET value = 'failed', updated_at = ? WHERE key = ?`,
      [new Date().toISOString(), FLAG],
    );
    const result = await writeResult({
      call_id: row?.id || "",
      twilio_sid: "",
      twilio_status: row?.status || "failed",
      error_code: code,
      error,
    });
    log(`OUTBOUND_RESULT ${JSON.stringify(result)}`);
    return;
  }
  await d1(`UPDATE runtime_state SET value = 'sent', updated_at = ? WHERE key = ?`, [new Date().toISOString(), FLAG]);
  const sid = process.env.TWILIO_ACCOUNT_SID;
  const token = process.env.TWILIO_AUTH_TOKEN;
  const call = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(sid)}/Calls/${encodeURIComponent(row.twilio_sid)}.json`, {
    headers: { authorization: `Basic ${Buffer.from(`${sid}:${token}`).toString("base64")}` },
  });
  const body = await call.json().catch(() => ({}));
  const result = await writeResult({
    call_id: String(row.id),
    twilio_sid: String(row.twilio_sid),
    twilio_status: String(body.status || row.status || ""),
    error_code: body.error_code == null ? "" : String(body.error_code),
    error: redact(body.error_message || error),
  });
  log(`OUTBOUND_RESULT ${JSON.stringify(result)}`);
}

main().catch((err) => {
  log(err instanceof Error ? err.message : "outbound step failed");
  process.exit(1);
});
