#!/usr/bin/env bash
set -euo pipefail
node --input-type=module <<'NODE'
const account = process.env.TWILIO_ACCOUNT_SID || "";
const token = process.env.TWILIO_AUTH_TOKEN || "";
const fromSecret = normalise(process.env.TWILIO_FROM_NUMBER || "");
const ownerSecret = normalise(process.env.OWNER_PHONE || "");
const expectedFrom = "+447454037416";
console.log(JSON.stringify({
  twilio_sid_set: Boolean(account),
  twilio_token_set: Boolean(token),
  from_secret_set: Boolean(fromSecret),
  from_is_expected_uk_mobile: fromSecret === expectedFrom,
  owner_secret_set: Boolean(ownerSecret),
  owner_looks_e164: /^\+\d{8,15}$/.test(ownerSecret),
}));
if (!account || !token) process.exit(1);
const auth = "Basic " + Buffer.from(`${account}:${token}`).toString("base64");
const since = Date.now() - 3 * 60 * 60 * 1000;
const dates = ["2026-10-20", "2026-10-21"];
const messages = [];
for (const date of dates) {
  const url = `https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(account)}/Messages.json?PageSize=100&DateSent=${date}`;
  const response = await fetch(url, { headers: { authorization: auth } });
  const body = await response.json();
  if (!response.ok) {
    console.log(JSON.stringify({ messages_http: response.status, twilio_code: body.code || null, twilio_message: body.message || "" }));
    continue;
  }
  for (const item of body.messages || []) messages.push(item);
}
const recent = messages.filter((item) => Date.parse(item.date_created || item.date_sent || "") >= since);
recent.sort((a, b) => Date.parse(a.date_created || 0) - Date.parse(b.date_created || 0));
console.log(`messages_in_window ${recent.length} fetched ${messages.length}`);
for (const item of recent) {
  console.log(JSON.stringify({
    sid: item.sid,
    status: item.status,
    error_code: item.error_code,
    error_message: item.error_message,
    direction: item.direction,
    date_created: item.date_created,
    from_is_jarvis: normalise(item.from) === fromSecret,
    from_is_expected_uk_mobile: normalise(item.from) === expectedFrom,
    to_is_owner_secret: normalise(item.to) === ownerSecret,
    body: redact(item.body || ""),
  }));
}
const alertUrl = "https://monitor.twilio.com/v1/alerts?PageSize=40&StartDate=2026-10-20T22:00:00Z";
const alerts = await fetch(alertUrl, { headers: { authorization: auth } });
const alertBody = await alerts.json().catch(() => ({}));
console.log(`alerts_http ${alerts.status}`);
for (const item of (alertBody.alerts || []).slice(0, 20)) {
  console.log(JSON.stringify({
    sid: item.sid || item.alert_sid || "",
    error_code: item.error_code,
    log_level: item.log_level,
    date_generated: item.date_generated || item.date_created,
    text: redact(item.alert_text || item.request_url || ""),
  }));
}

function normalise(value) {
  const trimmed = String(value || "").trim();
  if (!trimmed) return "";
  if (trimmed.startsWith("+")) return `+${trimmed.slice(1).replace(/\D/g, "")}`;
  const digits = trimmed.replace(/\D/g, "");
  if (digits.startsWith("00")) return `+${digits.slice(2)}`;
  if (digits.startsWith("0")) return `+44${digits.slice(1)}`;
  return digits ? `+${digits}` : "";
}
function redact(text) {
  return String(text).replace(/\+\d{6,}/g, "[number]").replace(/\b\d{10,}\b/g, "[digits]").slice(0, 180);
}
NODE

npx wrangler d1 execute jarvis-db --remote --json --command "SELECT id, status, substr(ifnull(summary,''),1,200) AS summary, created_at, updated_at, CASE WHEN conversation_id IS NULL OR conversation_id = '' THEN 0 ELSE 1 END AS has_conversation, CASE WHEN twilio_sid IS NULL OR twilio_sid = '' THEN '' ELSE twilio_sid END AS twilio_sid, length(ifnull(transcript_json,'')) AS transcript_len FROM outbound_calls WHERE id = 'call_959c1db561354036a621adcc6ae1dc35' OR id LIKE 'call_f0ce67d2%' OR created_at >= '2026-10-20T22:00:00Z' ORDER BY created_at DESC LIMIT 20;" > /tmp/calls.json
npx wrangler d1 execute jarvis-db --remote --json --command "SELECT id, call_id, caller_name, substr(spoken,1,220) AS spoken, called_at, created_at, CASE WHEN read_at IS NULL THEN 0 ELSE 1 END AS is_read FROM call_messages WHERE created_at >= '2026-10-20T22:00:00Z' OR call_id = 'call_959c1db561354036a621adcc6ae1dc35' OR call_id LIKE 'call_f0ce67d2%' ORDER BY created_at DESC LIMIT 20;" > /tmp/messages.json
npx wrangler d1 execute jarvis-db --remote --json --command "SELECT mobile_number FROM call_settings WHERE id = 'default';" > /tmp/settings.json
node --input-type=module <<'NODE'
import { readFileSync } from "node:fs";
function rows(path) {
  const raw = readFileSync(path, "utf8");
  const start = raw.indexOf("[");
  const parsed = JSON.parse(raw.slice(start));
  const first = Array.isArray(parsed) ? parsed[0] : parsed;
  return first?.results ?? first?.result ?? [];
}
function normalise(value) {
  const trimmed = String(value || "").trim();
  if (!trimmed) return "";
  if (trimmed.startsWith("+")) return `+${trimmed.slice(1).replace(/\D/g, "")}`;
  const digits = trimmed.replace(/\D/g, "");
  if (digits.startsWith("00")) return `+${digits.slice(2)}`;
  if (digits.startsWith("0")) return `+44${digits.slice(1)}`;
  return digits ? `+${digits}` : "";
}
const calls = rows("/tmp/calls.json");
const messages = rows("/tmp/messages.json");
const settings = rows("/tmp/settings.json");
const saved = normalise(settings[0]?.mobile_number || "");
const owner = normalise(process.env.OWNER_PHONE || "");
console.log(JSON.stringify({
  settings_row: settings.length > 0,
  mobile_empty: saved.length === 0,
  mobile_len: saved.length,
  mobile_matches_owner_secret: Boolean(saved) && saved === owner,
}));
for (const row of calls) console.log("call " + JSON.stringify(row));
for (const row of messages) console.log("stored " + JSON.stringify(row));
const account = process.env.TWILIO_ACCOUNT_SID || "";
const token = process.env.TWILIO_AUTH_TOKEN || "";
const auth = "Basic " + Buffer.from(`${account}:${token}`).toString("base64");
for (const row of calls) {
  if (!row.twilio_sid) continue;
  const response = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(account)}/Calls/${encodeURIComponent(row.twilio_sid)}.json`, { headers: { authorization: auth } });
  const body = await response.json();
  console.log(JSON.stringify({
    call_id: row.id,
    twilio_http: response.status,
    twilio_status: body.status || "",
    twilio_code: body.code || null,
    duration: body.duration || "",
    direction: body.direction || "",
  }));
}
const numberSid = "PN66046ff3fcdfc8f9aa8ed11811dd9d5d";
const number = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(account)}/IncomingPhoneNumbers/${numberSid}.json`, { headers: { authorization: auth } });
const numberBody = await number.json();
console.log(JSON.stringify({
  number_http: number.status,
  sms_capable: Boolean(numberBody.capabilities && numberBody.capabilities.sms),
  mms_capable: Boolean(numberBody.capabilities && numberBody.capabilities.mms),
  voice_capable: Boolean(numberBody.capabilities && numberBody.capabilities.voice),
  number_error: numberBody.code || null,
}));
const latest = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(account)}/Messages.json?PageSize=5`, { headers: { authorization: auth } });
const latestBody = await latest.json();
console.log(JSON.stringify({
  latest_http: latest.status,
  latest_count: Array.isArray(latestBody.messages) ? latestBody.messages.length : 0,
  latest_code: latestBody.code || null,
  latest_message: redact(latestBody.message || ""),
}));
for (const item of latestBody.messages || []) {
  console.log(JSON.stringify({
    sid: item.sid,
    status: item.status,
    error_code: item.error_code,
    date_created: item.date_created,
    from_is_expected_uk_mobile: normalise(item.from) === "+447454037416",
    to_is_owner_secret: normalise(item.to) === owner,
  }));
}
const geo = await fetch("https://messaging.twilio.com/v1/GeoPermissions/Sms/GB", { headers: { authorization: auth } });
const geoBody = await geo.json().catch(() => ({}));
console.log(JSON.stringify({
  geo_http: geo.status,
  geo_code: geoBody.code || null,
  geo_message: redact(geoBody.message || ""),
  geo_enabled: geoBody.enabled ?? geoBody.sms_enabled ?? null,
  geo_keys: Object.keys(geoBody).slice(0, 12),
}));
function redact(text) {
  return String(text).replace(/\+\d{6,}/g, "[number]").replace(/\b\d{8,}\b/g, "[digits]");
}
const accountInfo = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(account)}.json`, { headers: { authorization: auth } });
const accountBody = await accountInfo.json().catch(() => ({}));
console.log(JSON.stringify({
  account_http: accountInfo.status,
  account_status: accountBody.status || "",
  account_type: accountBody.type || "",
}));
const profiles = await fetch("https://trusthub.twilio.com/v1/CustomerProfiles?PageSize=20", { headers: { authorization: auth } });
const profileBody = await profiles.json().catch(() => ({}));
console.log(JSON.stringify({
  profiles_http: profiles.status,
  profiles_code: profileBody.code || null,
  profiles_message: redact(profileBody.message || ""),
  profiles: (profileBody.results || []).map((item) => ({ status: item.status, sid: item.sid })),
}));
const bundles = await fetch("https://numbers.twilio.com/v2/RegulatoryCompliance/Bundles?PageSize=20", { headers: { authorization: auth } });
const bundleBody = await bundles.json().catch(() => ({}));
console.log(JSON.stringify({
  bundles_http: bundles.status,
  bundles_code: bundleBody.code || null,
  bundles: (bundleBody.results || []).map((item) => ({ status: item.status, sid: item.sid })),
}));
const profileSid = (profileBody.results || []).find((item) => item.status === "draft")?.sid || "";
if (profileSid) {
  const detail = await fetch(`https://trusthub.twilio.com/v1/CustomerProfiles/${encodeURIComponent(profileSid)}`, { headers: { authorization: auth } });
  const detailBody = await detail.json().catch(() => ({}));
  const policy = typeof detailBody.policy_sid === "string" ? detailBody.policy_sid : "";
  console.log(JSON.stringify({ profile_sid: profileSid, profile_status: detailBody.status || "", policy_sid: policy }));
  if (policy) {
    const evaluation = await fetch(`https://trusthub.twilio.com/v1/CustomerProfiles/${encodeURIComponent(profileSid)}/Evaluations`, {
      method: "POST",
      headers: { authorization: auth, "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ PolicySid: policy }).toString(),
    });
    const evaluationBody = await evaluation.json().catch(() => ({}));
    const fields = [];
    for (const group of evaluationBody.results || []) {
      for (const field of group.fields || []) {
        if (field.passed === false) fields.push({ group: group.friendly_name || "", field: field.friendly_name || "", reason: redact(field.failure_reason || "") });
      }
    }
    console.log(JSON.stringify({
      evaluation_http: evaluation.status,
      evaluation_status: evaluationBody.status || "",
      evaluation_code: evaluationBody.code || null,
      failed_fields: fields.slice(0, 20),
    }));
    if (evaluationBody.status === "compliant") {
      const submitted = await fetch(`https://trusthub.twilio.com/v1/CustomerProfiles/${encodeURIComponent(profileSid)}`, {
        method: "POST",
        headers: { authorization: auth, "content-type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({ Status: "pending-review" }).toString(),
      });
      const submittedBody = await submitted.json().catch(() => ({}));
      console.log(JSON.stringify({
        submit_http: submitted.status,
        submit_status: submittedBody.status || "",
        submit_code: submittedBody.code || null,
        submit_error: redact(submittedBody.message || ""),
      }));
    }
  }
}
const services = await fetch("https://messaging.twilio.com/v1/Services?PageSize=20", { headers: { authorization: auth } });
const serviceBody = await services.json().catch(() => ({}));
console.log(JSON.stringify({
  services_http: services.status,
  services_code: serviceBody.code || null,
  services: (serviceBody.services || []).map((item) => ({ sid: item.sid, usecase: item.usecase || "" })),
}));
NODE
rm -f /tmp/settings.json
