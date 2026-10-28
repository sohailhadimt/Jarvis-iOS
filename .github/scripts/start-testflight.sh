#!/usr/bin/env bash
set -euo pipefail
token="${CODEMAGIC_API_TOKEN:-}"
if [ -z "$token" ]; then
  echo "CODEMAGIC_API_TOKEN is not set"
  exit 0
fi
curl -sS -H "Authorization: Bearer ${token}" https://api.codemagic.io/apps -o /tmp/cm-apps.json
node --input-type=module <<'NODE'
import { readFileSync, writeFileSync } from "node:fs";
const raw = readFileSync("/tmp/cm-apps.json", "utf8");
let parsed;
try {
  parsed = JSON.parse(raw);
} catch {
  console.log("codemagic apps response was not JSON");
  process.exit(0);
}
const apps = parsed.applications || parsed.apps || [];
if (!Array.isArray(apps) || apps.length === 0) {
  console.log(JSON.stringify({ codemagic_apps: 0, error: parsed.message || parsed.error || "" }));
  process.exit(0);
}
const match = apps.find((app) => /jarvis/i.test(`${app.repository || ""} ${app.appName || ""}`)) || apps[0];
const appId = match._id || match.id || "";
writeFileSync("/tmp/cm-app-id.txt", appId);
console.log(JSON.stringify({ app_id: appId, workflow_ids: Object.keys(match.workflows || {}) }));
NODE
app_id=$(cat /tmp/cm-app-id.txt 2>/dev/null || true)
if [ -z "$app_id" ]; then
  exit 0
fi
curl -sS -X POST https://api.codemagic.io/builds \
  -H "Authorization: Bearer ${token}" \
  -H "Content-Type: application/json" \
  -d "{\"appId\":\"${app_id}\",\"workflowId\":\"ios-testflight\",\"branch\":\"cursor/inbound-call-screening-afd7\"}" \
  -o /tmp/cm-build.json
node --input-type=module <<'NODE'
import { readFileSync } from "node:fs";
const raw = readFileSync("/tmp/cm-build.json", "utf8");
let body;
try {
  body = JSON.parse(raw);
} catch {
  console.log("codemagic build response was not JSON");
  process.exit(0);
}
const build = body.build || {};
console.log(JSON.stringify({
  build_id: build._id || body.buildId || body._id || "",
  status: build.status || "",
  error: body.message || body.error || "",
}));
NODE
rm -f /tmp/cm-apps.json /tmp/cm-build.json /tmp/cm-app-id.txt
