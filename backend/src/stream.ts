import { dbAll, dbFirst, dbRun } from "./db";
import { isRecord, json, newId, nowIso } from "./http";
import type { Env } from "./types";

const GEORGE_VOICE_ID = "JBFqnCBsd6RMkjVDRZzb";
const FALLBACK_GREETING =
  "Hello, you've reached Master Hadi's phone, this is JARVIS his personal assistant. This call may be handled by AI. Who's calling and how can I help?";

const MULAW_BIAS = 0x84;
const MULAW_CLIP = 32635;
const MULAW_DECODE = new Int16Array(256);

for (let index = 0; index < 256; index += 1) {
  const value = ~index & 0xff;
  const sign = value & 0x80;
  const exponent = (value >> 4) & 0x07;
  const mantissa = value & 0x0f;
  let sample = ((mantissa << 3) + MULAW_BIAS) << exponent;
  sample -= MULAW_BIAS;
  MULAW_DECODE[index] = sign ? -sample : sample;
}

export interface HandoffRow {
  call_id: string;
  path: string;
  ok: boolean;
  reason: string;
  detail: string;
  created_at: string;
  status: string;
}

export function redactDebug(text: string): string {
  return text
    .replace(/[A-Za-z0-9+/=_-]{24,}/g, "[redacted]")
    .replace(/\+\d{8,15}/g, "[number]")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 400);
}

export function streamSocketUrl(request: Request, callId: string): string {
  const url = new URL(request.url);
  url.protocol = url.protocol === "https:" ? "wss:" : "wss:";
  url.pathname = `/calls/stream/${callId}`;
  url.search = "";
  return url.toString();
}

export function streamTwiml(input: { streamUrl: string; say: string; voice: string; voicemailUrl: string }): string {
  const stream = escapeXml(input.streamUrl);
  const say = escapeXml(input.say);
  const voice = escapeXml(input.voice);
  const voicemail = escapeXml(input.voicemailUrl);
  return `<?xml version="1.0" encoding="UTF-8"?><Response><Connect><Stream url="${stream}"/></Connect><Say language="en-GB" voice="${voice}">${say}</Say><Record maxLength="120" playBeep="true" timeout="8" transcribe="true" transcribeCallback="${voicemail}"/><Hangup/></Response>`;
}

export function summaryFromLines(lines: Array<{ role: string; text: string }>): string {
  const them = lines
    .filter((line) => line.role === "them")
    .map((line) => line.text.trim())
    .filter(Boolean)
    .join(" ");
  const spoken = them.replace(/\s+/g, " ").trim();
  if (!spoken) return "A caller reached you. I didn't catch a message.";
  const clipped = spoken.length > 220 ? `${spoken.slice(0, 220).trim()}…` : spoken;
  return `They said: ${clipped} I'll get back to them.`;
}

export function parseAudioFormat(format: string): { encoding: "ulaw" | "pcm"; rate: number } {
  const matched = /^(ulaw|pcm)_(\d+)$/.exec(format);
  if (!matched) return { encoding: "pcm", rate: 16000 };
  const rate = Number(matched[2]);
  return { encoding: matched[1] === "ulaw" ? "ulaw" : "pcm", rate: Number.isFinite(rate) && rate > 0 ? rate : 16000 };
}

export function userAudioForEleven(twilioPayload: string, format: string): string {
  const target = parseAudioFormat(format);
  if (target.encoding === "ulaw" && target.rate === 8000) return twilioPayload;
  const pcm8 = mulawToPcm(b64ToBytes(twilioPayload));
  const pcm = resample(pcm8, 8000, target.rate);
  if (target.encoding === "ulaw") return bytesToB64(pcmToMulaw(pcm));
  return bytesToB64(pcmToBytes(pcm));
}

export function agentAudioForTwilio(payload: string, format: string): string {
  const source = parseAudioFormat(format);
  if (source.encoding === "ulaw" && source.rate === 8000) return payload;
  const bytes = b64ToBytes(payload);
  const pcm = source.encoding === "ulaw" ? mulawToPcm(bytes) : bytesToPcm(bytes);
  const down = resample(pcm, source.rate, 8000);
  return bytesToB64(pcmToMulaw(down));
}

export type ElevenEvent =
  | { kind: "pong"; eventId: number }
  | { kind: "audio"; b64: string }
  | { kind: "clear" }
  | { kind: "transcript"; role: "assistant" | "them"; text: string }
  | { kind: "meta"; conversationId: string; userFormat: string; agentFormat: string }
  | { kind: "error"; reason: string }
  | { kind: "ignore" };

export function readElevenEvent(payload: unknown): ElevenEvent {
  if (!isRecord(payload) || typeof payload.type !== "string") return { kind: "ignore" };
  if (payload.type === "ping" && isRecord(payload.ping_event) && typeof payload.ping_event.event_id === "number") {
    return { kind: "pong", eventId: payload.ping_event.event_id };
  }
  if (payload.type === "audio" && isRecord(payload.audio_event) && typeof payload.audio_event.audio_base_64 === "string") {
    return { kind: "audio", b64: payload.audio_event.audio_base_64 };
  }
  if (payload.type === "interruption") return { kind: "clear" };
  if (payload.type === "user_transcript" && isRecord(payload.user_transcription_event)) {
    const text = payload.user_transcription_event.user_transcript;
    if (typeof text === "string" && text.trim()) return { kind: "transcript", role: "them", text: text.trim() };
  }
  if (payload.type === "agent_response" && isRecord(payload.agent_response_event)) {
    const text = payload.agent_response_event.agent_response;
    if (typeof text === "string" && text.trim()) return { kind: "transcript", role: "assistant", text: text.trim() };
  }
  if (payload.type === "conversation_initiation_metadata" && isRecord(payload.conversation_initiation_metadata_event)) {
    const meta = payload.conversation_initiation_metadata_event;
    return {
      kind: "meta",
      conversationId: typeof meta.conversation_id === "string" ? meta.conversation_id : "",
      userFormat: typeof meta.user_input_audio_format === "string" ? meta.user_input_audio_format : "pcm_16000",
      agentFormat: typeof meta.agent_output_audio_format === "string" ? meta.agent_output_audio_format : "pcm_16000",
    };
  }
  if (payload.type === "client_error" && isRecord(payload.error_event)) {
    const message = typeof payload.error_event.message === "string" ? payload.error_event.message : "";
    const name = typeof payload.error_event.error_name === "string" ? payload.error_event.error_name : "client_error";
    return { kind: "error", reason: redactDebug(`${name} ${message}`) || "elevenlabs_error" };
  }
  return { kind: "ignore" };
}

export function initiationMessage(input: { callId: string; first: string; prompt: string; overrides: boolean }): string {
  const body: Record<string, unknown> = {
    type: "conversation_initiation_client_data",
    user_id: input.callId,
    source_info: { source: "twilio" },
    dynamic_variables: { opening_line: input.first },
  };
  if (input.overrides) {
    body.conversation_config_override = {
      agent: { first_message: input.first, language: "en", prompt: { prompt: input.prompt } },
      tts: { voice_id: GEORGE_VOICE_ID },
    };
  }
  return JSON.stringify(body);
}

export async function saveBridge(env: Env, callId: string, first: string, prompt: string): Promise<void> {
  await dbRun(
    env,
    `INSERT INTO call_bridges (call_id, first_message, prompt, created_at)
     VALUES (?, ?, ?, ?)
     ON CONFLICT(call_id) DO UPDATE SET first_message = excluded.first_message, prompt = excluded.prompt`,
    [callId, first.slice(0, 800), prompt.slice(0, 4000), nowIso()],
  ).catch(() => undefined);
}

export async function recordHandoff(
  env: Env,
  input: { callId: string; path: string; ok: boolean; reason: string; detail?: string },
): Promise<void> {
  await dbRun(
    env,
    `INSERT INTO call_handoffs (id, call_id, path, ok, reason, detail, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?)`,
    [
      newId("hop"),
      input.callId,
      input.path.slice(0, 40),
      input.ok ? 1 : 0,
      redactDebug(input.reason).slice(0, 80) || "unknown",
      redactDebug(input.detail ?? ""),
      nowIso(),
    ],
  ).catch(() => undefined);
}

export async function lastCallDebug(env: Env): Promise<Response> {
  const handoffs = await dbAll<{
    call_id: string;
    path: string;
    ok: number;
    reason: string;
    detail: string;
    created_at: string;
  }>(
    env,
    "SELECT call_id, path, ok, reason, detail, created_at FROM call_handoffs ORDER BY created_at DESC LIMIT 10",
  ).catch(() => []);
  const stored = await dbAll<{ id: string; status: string; error: string | null; created_at: string }>(
    env,
    "SELECT id, status, error, created_at FROM outbound_calls ORDER BY created_at DESC LIMIT 10",
  ).catch(() => []);
  const fromHandoffs: HandoffRow[] = handoffs.map((row) => ({
    call_id: row.call_id,
    path: row.path,
    ok: row.ok === 1,
    reason: redactDebug(row.reason),
    detail: redactDebug(row.detail),
    created_at: row.created_at,
    status: stored.find((call) => call.id === row.call_id)?.status ?? "",
  }));
  const seen = new Set(fromHandoffs.map((row) => row.call_id));
  const fromStored: HandoffRow[] = stored
    .filter((row) => !seen.has(row.id))
    .map((row) => ({
      call_id: row.id,
      path: "stored",
      ok: row.status !== "failed" && row.status !== "message",
      reason: row.error ? "stored_error" : row.status,
      detail: redactDebug(row.error ?? ""),
      created_at: row.created_at,
      status: row.status,
    }));
  const calls = [...fromHandoffs, ...fromStored]
    .sort((a, b) => (a.created_at < b.created_at ? 1 : -1))
    .slice(0, 10);
  return json({ calls });
}

export async function handleCallStream(request: Request, env: Env, callId: string): Promise<Response> {
  if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
    return new Response("Expected a websocket.", { status: 426 });
  }
  const pair = new WebSocketPair();
  const client = pair[0];
  const server = pair[1];
  server.accept();
  void bridgeCall(server, env, callId);
  return new Response(null, { status: 101, webSocket: client });
}

async function bridgeCall(twilio: WebSocket, env: Env, callId: string): Promise<void> {
  const bridge = await dbFirst<{ first_message: string; prompt: string }>(
    env,
    "SELECT first_message, prompt FROM call_bridges WHERE call_id = ?",
    [callId],
  ).catch(() => null);
  const first = bridge?.first_message || FALLBACK_GREETING;
  const prompt = bridge?.prompt || `Your first spoken words are exactly: "${first}" Take a message. Then say: I'll pass that to Master Hadi and get back to you.`;
  const apiKey = (env.ELEVENLABS_API_KEY ?? "").trim();
  const agentId = (env.ELEVENLABS_AGENT_ID ?? "").trim();
  if (!apiKey || !agentId) {
    await recordHandoff(env, { callId, path: "stream", ok: false, reason: "missing_secret" });
    twilio.close(1011, "not configured");
    return;
  }
  let signed = "";
  try {
    const response = await fetch(
      `https://api.elevenlabs.io/v1/convai/conversation/get-signed-url?agent_id=${encodeURIComponent(agentId)}`,
      { headers: { "xi-api-key": apiKey }, signal: AbortSignal.timeout(8_000) },
    );
    const text = await response.text();
    if (!response.ok) {
      await recordHandoff(env, { callId, path: "stream", ok: false, reason: `signed_url_${response.status}`, detail: text });
      twilio.close(1011, "voice unavailable");
      return;
    }
    const parsed = JSON.parse(text) as unknown;
    signed = isRecord(parsed) && typeof parsed.signed_url === "string" ? parsed.signed_url : "";
  } catch (err) {
    await recordHandoff(env, {
      callId,
      path: "stream",
      ok: false,
      reason: "signed_url_network",
      detail: err instanceof Error ? err.message : "network",
    });
    twilio.close(1011, "voice unavailable");
    return;
  }
  if (!signed.startsWith("wss://")) {
    await recordHandoff(env, { callId, path: "stream", ok: false, reason: "signed_url_missing" });
    twilio.close(1011, "voice unavailable");
    return;
  }
  const agent = new WebSocket(signed);
  let streamSid = "";
  let userFormat = "pcm_16000";
  let agentFormat = "pcm_16000";
  let ready = false;
  let heardAgent = false;
  let overrides = true;
  let retried = false;
  let finished = false;
  const slow = setTimeout(() => {
    if (!ready && !finished) void failOpen("no_metadata");
  }, 4_000);
  const queued: string[] = [];
  const lines: Array<{ role: "assistant" | "them"; text: string }> = [];

  const failOpen = async (reason: string, detail = "") => {
    if (finished) return;
    finished = true;
    await recordHandoff(env, { callId, path: "stream", ok: false, reason, detail });
    try {
      agent.close();
    } catch {
      // Already closed.
    }
    try {
      twilio.close(1011, "voice unavailable");
    } catch {
      // Twilio already left.
    }
  };

  const finish = async (reason: string) => {
    if (finished) return;
    finished = true;
    const summary = summaryFromLines(lines);
    await dbRun(
      env,
      "UPDATE outbound_calls SET status = 'completed', summary = ?, transcript_json = ?, updated_at = ? WHERE id = ?",
      [summary, JSON.stringify(lines.map((line) => ({ role: line.role, text: line.text }))), nowIso(), callId],
    ).catch(() => undefined);
    await recordHandoff(env, { callId, path: "stream", ok: true, reason, detail: summary });
    const { rememberInboundMessage } = await import("./call-messages");
    const owned = await rememberInboundMessage(env, callId).catch(() => false);
    if (!owned) await textOwner(env, summary);
    try {
      agent.close();
    } catch {
      // Already closed.
    }
  };

  const sendUser = (payload: string) => {
    if (agent.readyState !== WebSocket.OPEN) return;
    agent.send(JSON.stringify({ user_audio_chunk: userAudioForEleven(payload, userFormat) }));
  };

  twilio.addEventListener("message", (event) => {
    const raw = typeof event.data === "string" ? event.data : "";
    if (!raw) return;
    let message: unknown;
    try {
      message = JSON.parse(raw);
    } catch {
      return;
    }
    if (!isRecord(message) || typeof message.event !== "string") return;
    if (message.event === "start" && isRecord(message.start) && typeof message.start.streamSid === "string") {
      streamSid = message.start.streamSid;
    }
    if (message.event === "media" && isRecord(message.media) && typeof message.media.payload === "string") {
      if (message.media.track === "outbound") return;
      if (!ready) {
        if (queued.length < 200) queued.push(message.media.payload);
        return;
      }
      sendUser(message.media.payload);
    }
    if (message.event === "stop") void finish("caller_left");
  });

  twilio.addEventListener("close", () => {
    void finish("twilio_closed");
  });

  agent.addEventListener("open", () => {
    agent.send(initiationMessage({ callId, first, prompt, overrides }));
  });

  agent.addEventListener("message", (event) => {
    const raw = typeof event.data === "string" ? event.data : "";
    if (!raw) return;
    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
    } catch {
      return;
    }
    const next = readElevenEvent(parsed);
    if (next.kind === "pong") {
      agent.send(JSON.stringify({ type: "pong", event_id: next.eventId }));
      return;
    }
    if (next.kind === "error") {
      if (overrides && !retried && /override/i.test(next.reason)) {
        retried = true;
        if (first !== FALLBACK_GREETING) {
          void failOpen("override_not_allowed", next.reason);
          return;
        }
        overrides = false;
        agent.send(initiationMessage({ callId, first, prompt, overrides: false }));
        return;
      }
      if (!heardAgent) void failOpen(next.reason);
      return;
    }
    if (next.kind === "meta") {
      userFormat = next.userFormat || userFormat;
      agentFormat = next.agentFormat || agentFormat;
      ready = true;
      clearTimeout(slow);
      if (next.conversationId) {
        void dbRun(env, "UPDATE outbound_calls SET conversation_id = ?, status = 'screening', updated_at = ? WHERE id = ?", [
          next.conversationId,
          nowIso(),
          callId,
        ]).catch(() => undefined);
      }
      void recordHandoff(env, {
        callId,
        path: "stream",
        ok: true,
        reason: "connected",
        detail: `${userFormat} ${agentFormat}`,
      });
      for (const payload of queued) sendUser(payload);
      queued.length = 0;
      return;
    }
    if (next.kind === "audio" && streamSid) {
      heardAgent = true;
      const payload = agentAudioForTwilio(next.b64, agentFormat);
      twilio.send(JSON.stringify({ event: "media", streamSid, media: { payload } }));
      return;
    }
    if (next.kind === "clear" && streamSid) {
      twilio.send(JSON.stringify({ event: "clear", streamSid }));
      return;
    }
    if (next.kind === "transcript") {
      lines.push({ role: next.role, text: next.text.slice(0, 500) });
      void dbRun(
        env,
        "UPDATE outbound_calls SET transcript_json = ?, updated_at = ? WHERE id = ?",
        [JSON.stringify(lines.map((line) => ({ role: line.role, text: line.text }))), nowIso(), callId],
      ).catch(() => undefined);
    }
  });

  agent.addEventListener("close", () => {
    if (!heardAgent) void failOpen("agent_closed");
    else void finish("agent_closed");
  });

  agent.addEventListener("error", () => {
    if (!heardAgent) void failOpen("agent_error");
  });
}

async function textOwner(env: Env, summary: string): Promise<void> {
  const account = (env.TWILIO_ACCOUNT_SID ?? "").trim();
  const token = (env.TWILIO_AUTH_TOKEN ?? "").trim();
  const from = (env.TWILIO_FROM_NUMBER ?? "").trim();
  const saved = await dbFirst<{ mobile_number: string }>(env, "SELECT mobile_number FROM call_settings WHERE id = 'default'").catch(
    () => null,
  );
  const to = (saved?.mobile_number || env.OWNER_PHONE || "").trim();
  if (!account || !token || !from.startsWith("+") || !to.startsWith("+")) return;
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

function mulawToPcm(bytes: Uint8Array): Int16Array {
  const pcm = new Int16Array(bytes.length);
  for (let index = 0; index < bytes.length; index += 1) pcm[index] = MULAW_DECODE[bytes[index] ?? 0] ?? 0;
  return pcm;
}

function pcmToMulaw(pcm: Int16Array): Uint8Array {
  const bytes = new Uint8Array(pcm.length);
  for (let index = 0; index < pcm.length; index += 1) bytes[index] = encodeMulaw(pcm[index] ?? 0);
  return bytes;
}

function encodeMulaw(sample: number): number {
  const sign = sample < 0 ? 0x80 : 0;
  let magnitude = Math.min(MULAW_CLIP, Math.abs(sample));
  magnitude += MULAW_BIAS;
  let exponent = 7;
  let mask = 0x4000;
  while (exponent > 0 && (magnitude & mask) === 0) {
    exponent -= 1;
    mask >>= 1;
  }
  const mantissa = (magnitude >> (exponent + 3)) & 0x0f;
  return (~(sign | (exponent << 4) | mantissa)) & 0xff;
}

function resample(pcm: Int16Array, from: number, to: number): Int16Array {
  if (from === to || pcm.length === 0) return pcm;
  if (to === from * 2) {
    const out = new Int16Array(pcm.length * 2);
    for (let index = 0; index < pcm.length; index += 1) {
      out[index * 2] = pcm[index] ?? 0;
      out[index * 2 + 1] = pcm[index] ?? 0;
    }
    return out;
  }
  if (from === to * 2) {
    const out = new Int16Array(Math.floor(pcm.length / 2));
    for (let index = 0; index < out.length; index += 1) {
      const mixed = ((pcm[index * 2] ?? 0) + (pcm[index * 2 + 1] ?? 0)) / 2;
      out[index] = Math.max(-32768, Math.min(32767, Math.round(mixed)));
    }
    return out;
  }
  const out = new Int16Array(Math.max(1, Math.round((pcm.length * to) / from)));
  for (let index = 0; index < out.length; index += 1) {
    const position = (index * from) / to;
    const left = Math.floor(position);
    const right = Math.min(pcm.length - 1, left + 1);
    const mix = position - left;
    out[index] = (pcm[left] ?? 0) * (1 - mix) + (pcm[right] ?? 0) * mix;
  }
  return out;
}

function bytesToPcm(bytes: Uint8Array): Int16Array {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const count = Math.floor(bytes.byteLength / 2);
  const pcm = new Int16Array(count);
  for (let index = 0; index < count; index += 1) pcm[index] = view.getInt16(index * 2, true);
  return pcm;
}

function pcmToBytes(pcm: Int16Array): Uint8Array {
  const bytes = new Uint8Array(pcm.length * 2);
  const view = new DataView(bytes.buffer);
  for (let index = 0; index < pcm.length; index += 1) view.setInt16(index * 2, pcm[index] ?? 0, true);
  return bytes;
}

function b64ToBytes(value: string): Uint8Array {
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  return bytes;
}

function bytesToB64(bytes: Uint8Array): string {
  let binary = "";
  for (let index = 0; index < bytes.length; index += 1) binary += String.fromCharCode(bytes[index] ?? 0);
  return btoa(binary);
}

function escapeXml(value: string): string {
  return value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;");
}
