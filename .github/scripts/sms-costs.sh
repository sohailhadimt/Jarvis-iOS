#!/usr/bin/env bash
# Read-only: Twilio balance, the GB SMS price, and how the last owner texts were delivered. Sends nothing.
set -euo pipefail
node --input-type=module <<'NODE'
const account = process.env.TWILIO_ACCOUNT_SID || "";
const token = process.env.TWILIO_AUTH_TOKEN || "";
if (!account || !token) {
  console.log("sms_costs skipped: no Twilio secrets");
  process.exit(0);
}
const auth = { authorization: "Basic " + Buffer.from(`${account}:${token}`).toString("base64") };
const base = `https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(account)}`;
const redact = (text) => String(text || "").replace(/\+\d{6,}/g, "[number]").replace(/\b\d{10,}\b/g, "[digits]");
const get = async (url) => {
  const response = await fetch(url, { headers: auth });
  return { status: response.status, body: await response.json().catch(() => ({})) };
};
const balance = await get(`${base}/Balance.json`);
console.log(`twilio_balance http=${balance.status} balance=${balance.body.balance ?? ""} currency=${balance.body.currency ?? ""}`);
const price = await get("https://pricing.twilio.com/v1/Messaging/Countries/GB");
for (const row of (price.body.outbound_sms_prices || []).slice(0, 6)) {
  const prices = (row.prices || []).map((p) => `${p.number_type}:${p.current_price}`).join(",");
  console.log(`gb_outbound carrier=${row.carrier} ${prices} unit=${price.body.price_unit || ""}`);
}
const inbound = (price.body.inbound_sms_prices || []).map((p) => `${p.number_type}:${p.current_price}`).join(",");
console.log(`gb_inbound ${inbound} unit=${price.body.price_unit || ""}`);
const owner = process.env.OWNER_PHONE || "";
const list = await get(`${base}/Messages.json?PageSize=40`);
const rows = (list.body.messages || []).filter((m) => !owner || m.to === owner || m.from === owner).slice(0, 12);
console.log(`owner_texts_recent ${rows.length}`);
for (const m of rows) {
  console.log(JSON.stringify({
    sid: m.sid,
    direction: m.direction,
    status: m.status,
    error_code: m.error_code,
    segments: m.num_segments,
    price: m.price,
    unit: m.price_unit,
    date: m.date_created,
    body: redact(m.body).slice(0, 120),
  }));
}
const numbers = await get(`${base}/IncomingPhoneNumbers.json?PageSize=5`);
for (const n of numbers.body.incoming_phone_numbers || []) {
  console.log(`number_caps sms=${n.capabilities?.sms} mms=${n.capabilities?.mms} voice=${n.capabilities?.voice}`);
}
const calls = await get(`${base}/Calls.json?PageSize=8`);
for (const c of (calls.body.calls || []).slice(0, 8)) {
  console.log(JSON.stringify({ call: c.sid, to_owner: !!owner && c.to === owner, status: c.status, duration: c.duration, price: c.price, unit: c.price_unit, start: c.start_time }));
}
NODE
