// One check of the approved Trust Hub profile, then at most one test text and the 00:59 call message.
// Prints no phone numbers and no credentials.
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const PROFILE = "BU2457e8bdd303e450d0ff8850c864a3bd";
const BUNDLE = "BU0dba96562ef3c5a183856eb8faf9a882";
const NUMBER_SID = "PN66046ff3fcdfc8f9aa8ed11811dd9d5d";
const EXPECTED_FROM = "+447454037416";
const TEST_BODY = "JARVIS here, Sir. Texts are now working.";

const account = (process.env.TWILIO_ACCOUNT_SID || "").trim();
const token = (process.env.TWILIO_AUTH_TOKEN || "").trim();
const from = normalise(process.env.TWILIO_FROM_NUMBER || "");
const owner = normalise(process.env.OWNER_PHONE || "");
const auth = "Basic " + Buffer.from(`${account}:${token}`).toString("base64");

const report = {
  profile_http: 0,
  profile_status: "",
  sms_capable: false,
  bundle_status: "",
  sent: false,
  reason: "",
  test: null,
  call_message: null,
};

if (!account || !token || !from || !owner) {
  report.reason = "twilio_or_owner_secret_missing";
  console.log(JSON.stringify(report));
  process.exit(0);
}
if (from !== EXPECTED_FROM) {
  report.reason = "from_number_is_not_the_jarvis_uk_mobile";
  console.log(JSON.stringify(report));
  process.exit(0);
}

const profile = await twilio(`https://trusthub.twilio.com/v1/CustomerProfiles/${PROFILE}`);
report.profile_http = profile.status;
report.profile_status = profile.body.status || "";
if (profile.body.code) report.profile_code = profile.body.code;
if (profile.body.message) report.profile_message = redact(profile.body.message);

const number = await twilio(
  `https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(account)}/IncomingPhoneNumbers/${NUMBER_SID}.json`,
);
report.number_http = number.status;
report.sms_capable = Boolean(number.body.capabilities && number.body.capabilities.sms);
report.voice_capable = Boolean(number.body.capabilities && number.body.capabilities.voice);
if (number.body.code) report.number_code = number.body.code;

const bundle = await twilio(`https://numbers.twilio.com/v2/RegulatoryCompliance/Bundles/${BUNDLE}`);
report.bundle_http = bundle.status;
report.bundle_status = bundle.body.status || "";
if (bundle.body.code) report.bundle_code = bundle.body.code;

const allowed = report.profile_status === "twilio-approved" && report.sms_capable && report.bundle_status === "twilio-approved";
if (!allowed) {
  report.reason = blockReason(report);
  console.log(JSON.stringify(report));
  process.exit(0);
}

const existing = await recentMessages();
const priorTest = existing.find((item) => item.body === TEST_BODY);
report.test = priorTest ? await settle(priorTest.sid) : await sendAndSettle(TEST_BODY);
report.sent = Boolean(report.test && report.test.sid && accepted(report.test.status) && !report.test.error_code);
if (!report.sent) {
  report.reason = report.test?.error_message || `test_status_${report.test?.status || "none"}`;
  console.log(JSON.stringify(report));
  process.exit(0);
}

const spoken = (() => {
  try {
    return unreadAt0059();
  } catch (err) {
    report.reason = "unread_lookup_failed";
    report.lookup_error = redact(err instanceof Error ? err.message : "d1");
    return null;
  }
})();
if (!spoken) {
  report.reason = "unread_0059_message_not_found";
  console.log(JSON.stringify(report));
  process.exit(0);
}
const priorCall = existing.find((item) => item.body === spoken.text);
const call = priorCall ? await settle(priorCall.sid) : await sendAndSettle(spoken.text);
report.call_message = {
  id: spoken.id,
  unread: true,
  includes_0059: spoken.text.includes("00:59"),
  sid: call.sid || "",
  status: call.status || "",
  error_code: call.error_code,
  error_message: call.error_message || "",
};
console.log(JSON.stringify(report));

function blockReason(row) {
  if (row.profile_status !== "twilio-approved") return `profile_${row.profile_status || "missing"}`;
  if (!row.sms_capable) return "uk_number_sms_disabled";
  if (row.bundle_status !== "twilio-approved") return `bundle_${row.bundle_status || "missing"}`;
  return "not_allowed";
}

async function sendAndSettle(body) {
  const created = await twilio(
    `https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(account)}/Messages.json`,
    new URLSearchParams({ From: from, To: owner, Body: body }),
  );
  if (!created.body.sid) {
    return {
      sid: "",
      status: "rejected",
      error_code: created.body.code ?? created.status,
      error_message: redact(created.body.message || ""),
    };
  }
  return settle(created.body.sid);
}

async function settle(sid) {
  let last = { sid, status: "", error_code: null, error_message: "" };
  for (let attempt = 0; attempt < 8; attempt++) {
    const row = await twilio(
      `https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(account)}/Messages/${encodeURIComponent(sid)}.json`,
    );
    last = {
      sid,
      status: row.body.status || "",
      error_code: row.body.error_code ?? null,
      error_message: redact(row.body.error_message || row.body.message || ""),
    };
    if (finalStatus(last.status) || last.error_code) return last;
    await new Promise((resolve) => setTimeout(resolve, 4000));
  }
  return last;
}

async function recentMessages() {
  const listed = await twilio(
    `https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(account)}/Messages.json?PageSize=20`,
  );
  return (listed.body.messages || []).map((item) => ({ sid: item.sid, body: item.body || "" }));
}

function unreadAt0059() {
  const raw = execFileSync(
    "npx",
    [
      "wrangler",
      "d1",
      "execute",
      "jarvis-db",
      "--remote",
      "--json",
      "--command",
      "SELECT id, spoken FROM call_messages WHERE read_at IS NULL AND spoken LIKE '%00:59%' ORDER BY called_at DESC LIMIT 1;",
    ],
    { encoding: "utf8", cwd: fileURLToPath(new URL("../../backend/", import.meta.url)) },
  );
  const start = raw.indexOf("[");
  const parsed = JSON.parse(raw.slice(start));
  const first = Array.isArray(parsed) ? parsed[0] : parsed;
  const row = (first?.results ?? first?.result ?? [])[0];
  if (!row?.spoken || !row.id) return null;
  return { id: String(row.id), text: String(row.spoken) };
}

async function twilio(url, form) {
  const response = await fetch(url, {
    method: form ? "POST" : "GET",
    headers: {
      authorization: auth,
      ...(form ? { "content-type": "application/x-www-form-urlencoded" } : {}),
    },
    body: form ? form.toString() : undefined,
  });
  const body = await response.json().catch(() => ({}));
  return { status: response.status, body };
}

function accepted(status) {
  return ["queued", "accepted", "sending", "sent", "delivered", "received", "receiving"].includes(status);
}

function finalStatus(status) {
  return ["delivered", "undelivered", "failed", "read"].includes(status);
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
  return String(text).replace(/\+\d{6,}/g, "[number]").replace(/\b\d{8,}\b/g, "[digits]").slice(0, 220);
}
