#!/usr/bin/env bash
# Read-only checks against the deployed worker. Never dials and never sends an SMS.
set -euo pipefail
base="${WORKER_URL:-https://jarvis-backend.jarvis-hadi.workers.dev}"
base="${base%/}"
token="${JARVIS_APP_TOKEN:-}"

hit() {
  local name="$1" method="$2" path="$3" body="${4:-}" auth="${5:-}"
  local args=(-sS -o "/tmp/live-${name}.json" -w "%{http_code}" -X "$method" --max-time 20)
  if [ "$auth" = "yes" ]; then
    args+=(-H "authorization: Bearer ${token}")
  fi
  if [ -n "$body" ]; then
    args+=(-H "content-type: application/json" --data "$body")
  fi
  local code
  code=$(curl "${args[@]}" "${base}${path}" || echo "000")
  echo "${name} ${code}"
}

hit health GET /health
hit messages_open GET "/calls/messages?unread=1"
hit config_open GET /calls/config
hit outbound_open POST /calls/outbound '{"to":"+15557654321","purpose":"qa","approved":false}'
hit device_open POST /calls/device '{"token":"abcd"}'
hit chat_open POST /agent/chat '{"message":"hello","conversationId":"conv_qa"}'

if [ -z "$token" ]; then
  echo "app_token present=false"
  echo "Authenticated live checks were skipped."
  exit 0
fi
echo "app_token present=true"

hit config GET /calls/config "" yes
hit messages GET "/calls/messages?unread=1" "" yes
hit outbound POST /calls/outbound '{"to":"+15557654321","purpose":"qa live check","contact_name":"QA","approved":false}' yes
hit device POST /calls/device '{"token":"not-hex"}' yes
hit sms_probe POST /debug/sms-probe '{}' yes
hit sms_errors GET /debug/last-sms-errors "" yes

node --input-type=module <<'NODE'
import { readFileSync } from "node:fs";
function read(name) {
  try { return JSON.parse(readFileSync(`/tmp/live-${name}.json`, "utf8")); }
  catch { return null; }
}
const config = read("config") || {};
const messages = read("messages") || {};
const outbound = read("outbound") || {};
const count = Array.isArray(messages.messages) ? messages.messages.length : null;
const report = {
  configured: Boolean(config.configured),
  push: Boolean(config.screening && config.screening.push),
  assistant_webhook: Boolean(config.assistant_webhook),
  texts: typeof config.texts === "string" ? config.texts : "",
  unread_messages: count,
  outbound_code: outbound.error && outbound.error.code ? outbound.error.code : "",
};
const text = JSON.stringify(report);
if (/\+\d{8,}/.test(text)) {
  console.error("live check leaked a phone number");
  process.exit(1);
}
console.log(text);
const probe = read("sms_probe");
const errors = read("sms_errors");
const debug = JSON.stringify({ probe, errors });
if (/\+\d{8,}/.test(debug) || /sk-|AIza|Bearer\s+\S{8,}/i.test(debug)) {
  console.error("sms debug leaked a secret");
  process.exit(1);
}
console.log(`sms_debug ${debug}`);
NODE

outbound_code=$(node -e 'const b=require("/tmp/live-outbound.json"); process.stdout.write(String((b.error&&b.error.code)||""))' 2>/dev/null || true)
if [ "$outbound_code" != "not_approved" ]; then
  echo "Unapproved outbound did not stop at 403."
  exit 1
fi
rm -f /tmp/live-*.json
