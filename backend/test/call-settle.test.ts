import { describe, expect, it } from "vitest";
import { twilioSignature } from "../src/calls";
import { route } from "../src/routes";
import type { Env } from "../src/types";

interface CallRec {
  id: string;
  contact_name: string;
  status: string;
  summary: string | null;
  transcript_json: string;
  conversation_id: string | null;
  created_at: string;
  twilio_sid?: string | null;
}

interface ScreenRec {
  call_id: string;
  direction: string;
  caller_name: string;
  reason: string;
}

interface MsgRec {
  id: string;
  call_id: string;
  caller_name: string;
  summary: string;
  spoken: string;
  called_at: string;
  read_at: string | null;
  created_at: string;
}

function memoryDb(calls: CallRec[], screens: ScreenRec[], messages: MsgRec[], kv: Map<string, string>): D1Database {
  return {
    prepare(sql: string) {
      let bound: unknown[] = [];
      const statement = {
        bind(...args: unknown[]) {
          bound = args;
          return statement;
        },
        async first() {
          if (sql.includes("runtime_state")) {
            const value = kv.get(String(bound[0]));
            return value == null ? null : { value };
          }
          if (sql.includes("call_settings")) return null;
          if (sql.includes("call_screen")) return screens.find((row) => row.call_id === String(bound[0])) ?? null;
          if (sql.includes("call_messages")) {
            const row = sql.includes("WHERE id = ?")
              ? messages.find((item) => item.id === String(bound[0]))
              : messages.find((item) => item.call_id === String(bound[0]));
            return row ?? null;
          }
          if (sql.includes("outbound_calls")) {
            if (sql.includes("conversation_id = ?") && !sql.includes("WHERE id = ?")) {
              const row = calls.find((item) => item.conversation_id === String(bound[0]));
              return row ? { id: row.id } : null;
            }
            const row = calls.find((item) => item.id === String(bound[0]));
            if (!row) return null;
            if (sql.trim().startsWith("SELECT summary")) return { summary: row.summary };
            return row;
          }
          return null;
        },
        async all() {
          if (sql.includes("call_messages m") && sql.includes("read_at IS NULL")) {
            const results = messages
              .filter((row) => row.read_at == null)
              .map((row) => {
                const call = calls.find((item) => item.id === row.call_id);
                const screen = screens.find((item) => item.call_id === row.call_id);
                return {
                  id: row.id,
                  call_id: row.call_id,
                  caller_name: row.caller_name,
                  summary: row.summary,
                  spoken: row.spoken,
                  called_at: row.called_at,
                  transcript_json: call?.transcript_json ?? "[]",
                  call_summary: call?.summary ?? null,
                  created_at: call?.created_at ?? row.called_at,
                  screen_name: screen?.caller_name ?? "",
                };
              });
            return { results, success: true, meta: {} };
          }
          if (sql.includes("LEFT JOIN call_screen")) {
            const rows = calls.filter((call) => {
              const screen = screens.find((item) => item.call_id === call.id);
              return screen?.direction === "inbound" || call.contact_name === "Incoming call";
            });
            return { results: rows, success: true, meta: {} };
          }
          if (sql.includes("conversation_id IN")) {
            const wanted = new Set(bound.map(String));
            const rows = calls
              .filter((call) => call.conversation_id && wanted.has(call.conversation_id))
              .map((call) => ({ conversation_id: call.conversation_id }));
            return { results: rows, success: true, meta: {} };
          }
          return { results: [], success: true, meta: {} };
        },
        async run() {
          if (sql.includes("INSERT INTO runtime_state")) {
            kv.set(String(bound[0]), String(bound[1]));
          } else if (sql.includes("INSERT INTO call_messages")) {
            messages.push({
              id: String(bound[0]),
              call_id: String(bound[1]),
              caller_name: String(bound[2]),
              summary: String(bound[3]),
              spoken: String(bound[4]),
              called_at: String(bound[5]),
              read_at: null,
              created_at: String(bound[6]),
            });
          } else if (sql.includes("SET caller_name = ?")) {
            const row = messages.find((item) => item.id === String(bound[3]));
            if (row) {
              row.caller_name = String(bound[0]);
              row.summary = String(bound[1]);
              row.spoken = String(bound[2]);
            }
          } else if (sql.includes("caller_name = CASE")) {
            const screen = screens.find((item) => item.call_id === String(bound[4]));
            if (screen) {
              if (String(bound[0])) screen.caller_name = String(bound[1]);
              if (String(bound[2])) screen.reason = String(bound[3]);
            }
          } else if (sql.includes("transcript_json = ?")) {
            const call = calls.find((item) => item.id === String(bound[4]));
            if (call) {
              call.status = "completed";
              call.summary = String(bound[0]);
              call.transcript_json = String(bound[1]);
              if (bound[2]) call.conversation_id = String(bound[2]);
            }
          } else if (sql.includes("status = 'failed'")) {
            const call = calls.find((item) => item.id === String(bound[2]));
            if (call) call.status = "failed";
          } else if (sql.includes("UPDATE outbound_calls SET summary = ?")) {
            const call = calls.find((item) => item.id === String(bound[2]));
            if (call) call.summary = String(bound[0]);
          } else if (sql.includes("status = 'completed'")) {
            const call = calls.find((item) => item.id === String(bound[2]));
            if (call) {
              call.status = "completed";
              call.summary = String(bound[0]);
            }
          } else if (sql.includes("INSERT INTO call_screen")) {
            screens.push({ call_id: String(bound[0]), direction: "inbound", caller_name: "", reason: "" });
          }
          return { success: true, meta: { changes: 1 } };
        },
      };
      return statement;
    },
  } as unknown as D1Database;
}

function settleEnv(calls: CallRec[], screens: ScreenRec[], messages: MsgRec[], kv = new Map<string, string>()): Env {
  return {
    JARVIS_APP_TOKEN: "secret-token",
    OWNER_PHONE: "+15557654321",
    TWILIO_ACCOUNT_SID: "ACexampleaccountsid000000000000",
    TWILIO_AUTH_TOKEN: "twilio-auth-token-example",
    TWILIO_FROM_NUMBER: "+447700900000",
    ELEVENLABS_API_KEY: "elevenlabs-key-example-value",
    ELEVENLABS_AGENT_ID: "agent_example",
    ELEVENLABS_WEBHOOK_SECRET: "webhook-secret-example",
    GROQ_API_KEY: "groq-test-key",
    DB: memoryDb(calls, screens, messages, kv),
  };
}

function ctx(): ExecutionContext {
  return {
    waitUntil() {
      return undefined;
    },
    passThroughOnException() {
      return undefined;
    },
    props: {},
  } as unknown as ExecutionContext;
}

async function elevenSign(secret: string, body: string, stamp = Math.floor(Date.now() / 1000)): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${stamp}.${body}`));
  const hex = [...new Uint8Array(mac)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
  return `t=${stamp},v0=${hex}`;
}

function transcriptBody(callId: string): string {
  return JSON.stringify({
    type: "post_call_transcription",
    data: {
      conversation_id: "conv_done",
      status: "done",
      user_id: callId,
      transcript: [
        { role: "agent", message: "Who is calling?" },
        { role: "user", message: "This is Amira. The boiler is leaking." },
      ],
      analysis: { transcript_summary: "Amira called about a leaking boiler." },
    },
  });
}

describe("post-call delivery", () => {
  it("rejects a bad signature and accepts a transcription once", async () => {
    const created = new Date().toISOString();
    const calls: CallRec[] = [
      {
        id: "call_abc",
        contact_name: "Incoming call",
        status: "screening",
        summary: null,
        transcript_json: "[]",
        conversation_id: null,
        created_at: created,
      },
    ];
    const screens: ScreenRec[] = [{ call_id: "call_abc", direction: "inbound", caller_name: "", reason: "" }];
    const messages: MsgRec[] = [];
    const env = settleEnv(calls, screens, messages);
    const sms: string[] = [];
    const original = globalThis.fetch;
    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (url.includes("chat/completions")) {
        return new Response(
          JSON.stringify({
            choices: [{ message: { content: '{"name":"Amira","reason":"boiler leak","said":"The boiler is leaking."}' } }],
          }),
          { status: 200 },
        );
      }
      if (url.includes("api.twilio.com")) {
        sms.push(String(init?.body ?? ""));
        return new Response("{}", { status: 201 });
      }
      return new Response("{}", { status: 404 });
    }) as typeof fetch;
    try {
      const raw = transcriptBody("call_abc");
      const bad = await route(
        new Request("https://jarvis.example/calls/elevenlabs/post-call", {
          method: "POST",
          headers: { "elevenlabs-signature": "t=1,v0=deadbeef" },
          body: raw,
        }),
        env,
        ctx(),
      );
      expect(bad.status).toBe(401);
      expect(messages).toHaveLength(0);

      const header = await elevenSign("webhook-secret-example", raw);
      const post = (signature: string) =>
        route(
          new Request("https://jarvis.example/calls/elevenlabs/post-call", {
            method: "POST",
            headers: { "elevenlabs-signature": signature },
            body: raw,
          }),
          env,
          ctx(),
        );
      const ok = await post(header);
      expect(ok.status).toBe(200);
      const body = (await ok.json()) as { matched: boolean; message_id: string | null };
      expect(body.matched).toBe(true);
      expect(body.message_id).toBeTruthy();
      expect(calls[0]?.status).toBe("completed");
      expect(messages).toHaveLength(1);
      expect(messages[0]?.spoken).toContain("Sir, Amira called to tell you");
      expect(messages[0]?.spoken).toContain("the boiler is leaking");
      expect(messages[0]?.spoken).not.toContain("…");
      expect(messages[0]?.spoken).not.toContain("They said");
      expect(sms).toHaveLength(1);
      const sent = new URLSearchParams(sms[0]);
      expect(sent.get("To")).toBe("+15557654321");
      expect(sent.get("Body")).toBe(messages[0]?.spoken);

      const again = await post(header);
      expect(again.status).toBe(200);
      expect(messages).toHaveLength(1);
      expect(sms).toHaveLength(1);

      const audio = JSON.stringify({ type: "post_call_audio", data: { conversation_id: "conv_done" } });
      const audioHeader = await elevenSign("webhook-secret-example", audio);
      const ignored = await route(
        new Request("https://jarvis.example/calls/elevenlabs/post-call", {
          method: "POST",
          headers: { "elevenlabs-signature": audioHeader },
          body: audio,
        }),
        env,
        ctx(),
      );
      expect(ignored.status).toBe(200);
      expect(sms).toHaveLength(1);
    } finally {
      globalThis.fetch = original;
    }
  });

  it("matches a finished conversation from the agent list when the row has no conversation id", async () => {
    const createdMs = Date.now() - 30_000;
    const calls: CallRec[] = [
      {
        id: "call_open",
        contact_name: "Incoming call",
        status: "screening",
        summary: null,
        transcript_json: "[]",
        conversation_id: null,
        created_at: new Date(createdMs).toISOString(),
      },
    ];
    const screens: ScreenRec[] = [{ call_id: "call_open", direction: "inbound", caller_name: "", reason: "" }];
    const messages: MsgRec[] = [];
    const kv = new Map<string, string>();
    const env = settleEnv(calls, screens, messages, kv);
    const sms: string[] = [];
    const seen: string[] = [];
    const original = globalThis.fetch;
    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      const method = init?.method ?? "GET";
      seen.push(`${method} ${url}`);
      if (url.includes("chat/completions")) {
        return new Response(
          JSON.stringify({
            choices: [{ message: { content: '{"name":"Amira","reason":"boiler","said":"The boiler is leaking."}' } }],
          }),
          { status: 200 },
        );
      }
      if (url.includes("/v1/workspace/webhooks") && method === "POST") {
        return new Response(JSON.stringify({ webhook_id: "wh_test", webhook_secret: "super-secret-value" }), { status: 200 });
      }
      if (url.includes("/v1/workspace/webhooks")) return new Response(JSON.stringify({ webhooks: [] }), { status: 200 });
      if (url.includes("/v1/convai/settings")) return new Response("{}", { status: 200 });
      if (url.includes("/v1/convai/conversations?")) {
        return new Response(
          JSON.stringify({
            conversations: [
              { conversation_id: "conv_listed", status: "done", start_time_unix_secs: Math.floor(createdMs / 1000) },
            ],
          }),
          { status: 200 },
        );
      }
      if (url.includes("/v1/convai/conversations/conv_listed")) {
        return new Response(
          JSON.stringify({
            conversation_id: "conv_listed",
            status: "done",
            conversation_initiation_client_data: { user_id: "call_open" },
            transcript: [{ role: "user", message: "This is Amira. The boiler is leaking." }],
            analysis: { transcript_summary: "Amira called about the boiler." },
          }),
          { status: 200 },
        );
      }
      if (url.includes("api.twilio.com")) {
        sms.push(String(init?.body ?? ""));
        return new Response("{}", { status: 201 });
      }
      return new Response("{}", { status: 404 });
    }) as typeof fetch;
    try {
      const first = await route(
        new Request("https://jarvis.example/calls/settle", {
          method: "POST",
          headers: { authorization: "Bearer secret-token" },
        }),
        env,
        ctx(),
      );
      expect(first.status).toBe(200);
      const body = (await first.json()) as {
        webhook: { attached: boolean; created: boolean };
        settled: Array<{ call_id: string; message_id: string | null; spoken: string | null }>;
      };
      const text = JSON.stringify(body);
      expect(text).not.toContain("super-secret-value");
      expect(text).not.toContain("elevenlabs-key-example-value");
      expect(body.webhook.created).toBe(true);
      expect(body.webhook.attached).toBe(true);
      expect(kv.get("elevenlabs_post_call_secret")).toBe("super-secret-value");
      const hit = body.settled.find((row) => row.call_id === "call_open");
      expect(hit?.message_id).toBeTruthy();
      expect(hit?.spoken).toContain("Sir, Amira called to tell you");
      expect(hit?.spoken).toContain("the boiler is leaking");
      expect(hit?.spoken).not.toContain("…");
      expect(calls[0]?.conversation_id).toBe("conv_listed");
      expect(sms).toHaveLength(1);
      expect(seen.some((line) => line.startsWith("GET ") && line.includes("/conversations?"))).toBe(true);

      const second = await route(
        new Request("https://jarvis.example/calls/settle", { method: "POST", headers: { authorization: "Bearer secret-token" } }),
        env,
        ctx(),
      );
      expect(second.status).toBe(200);
      expect(sms).toHaveLength(1);
    } finally {
      globalThis.fetch = original;
    }
  });

  it("replaces a placeholder voicemail summary with the transcription", async () => {
    const calls: CallRec[] = [
      {
        id: "call_vm",
        contact_name: "Incoming call",
        status: "completed",
        summary: "A caller left a message.",
        transcript_json: JSON.stringify([{ role: "them", text: "The boiler is leaking and I need a call back." }]),
        conversation_id: null,
        created_at: new Date().toISOString(),
      },
    ];
    const screens: ScreenRec[] = [{ call_id: "call_vm", direction: "inbound", caller_name: "", reason: "" }];
    const messages: MsgRec[] = [
      {
        id: "cmsg_e89beexample",
        call_id: "call_vm",
        caller_name: "Someone",
        summary: "A caller left a message.",
        spoken: "Sir, you have a message from Someone at 11:06.",
        called_at: calls[0].created_at,
        read_at: null,
        created_at: calls[0].created_at,
      },
    ];
    const env = settleEnv(calls, screens, messages);
    const sms: string[] = [];
    const original = globalThis.fetch;
    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (url.includes("/v1/workspace/webhooks") && (init?.method ?? "GET") === "POST") {
        return new Response(JSON.stringify({ webhook_id: "wh_test", webhook_secret: "super-secret-value" }), { status: 200 });
      }
      if (url.includes("api.elevenlabs.io")) return new Response(JSON.stringify({ webhooks: [] }), { status: 200 });
      if (url.includes("api.twilio.com")) {
        sms.push(String(init?.body ?? ""));
        return new Response("{}", { status: 201 });
      }
      return new Response("{}", { status: 404 });
    }) as typeof fetch;
    try {
      const response = await route(
        new Request("https://jarvis.example/calls/settle", { method: "POST", headers: { authorization: "Bearer secret-token" } }),
        env,
        ctx(),
      );
      expect(response.status).toBe(200);
      expect(messages[0]?.summary).toContain("boiler is leaking");
      expect(messages[0]?.spoken).toContain("Sir, an unknown caller called to tell you");
      expect(messages[0]?.spoken).toContain("boiler is leaking");
      expect(messages[0]?.spoken).not.toContain("…");
      expect(messages[0]?.spoken).not.toContain("A caller left a message");
      expect(sms).toHaveLength(1);
    } finally {
      globalThis.fetch = original;
    }
  });

  it("keeps an empty voicemail transcription out of the message list", async () => {
    const calls: CallRec[] = [
      {
        id: "call_vm",
        contact_name: "Incoming call",
        status: "screening",
        summary: null,
        transcript_json: "[]",
        conversation_id: null,
        created_at: new Date().toISOString(),
      },
    ];
    const screens: ScreenRec[] = [{ call_id: "call_vm", direction: "inbound", caller_name: "", reason: "" }];
    const messages: MsgRec[] = [];
    const env = settleEnv(calls, screens, messages);
    const sms: string[] = [];
    const original = globalThis.fetch;
    globalThis.fetch = (async (_input: RequestInfo | URL, init?: RequestInit) => {
      sms.push(String(init?.body ?? ""));
      return new Response("{}", { status: 201 });
    }) as typeof fetch;
    try {
      const emptyParams = { CallSid: "CA123" };
      const emptyUrl = "https://jarvis-backend.jarvis-hadi.workers.dev/calls/voicemail/call_vm";
      const emptySig = await twilioSignature(emptyUrl, emptyParams, "twilio-auth-token-example");
      const empty = await route(
        new Request("http://internal.local/calls/voicemail/call_vm", {
          method: "POST",
          headers: { "content-type": "application/x-www-form-urlencoded", "X-Twilio-Signature": emptySig },
          body: new URLSearchParams(emptyParams).toString(),
        }),
        env,
        ctx(),
      );
      expect(empty.status).toBe(200);
      expect(calls[0]?.summary).toBeNull();
      expect(calls[0]?.status).toBe("screening");
      expect(messages).toHaveLength(0);
      expect(sms).toHaveLength(0);

      const params = { CallSid: "CA123", TranscriptionText: "The boiler is leaking." };
      const signed = "https://jarvis-backend.jarvis-hadi.workers.dev/calls/voicemail/call_vm";
      const signature = await twilioSignature(signed, params, "twilio-auth-token-example");
      const saved = await route(
        new Request("http://internal.local/calls/voicemail/call_vm", {
          method: "POST",
          headers: { "content-type": "application/x-www-form-urlencoded", "X-Twilio-Signature": signature },
          body: new URLSearchParams(params).toString(),
        }),
        env,
        ctx(),
      );
      expect(saved.status).toBe(200);
      expect(calls[0]?.summary).toBe("The boiler is leaking.");
      expect(messages).toHaveLength(1);
      expect(messages[0]?.spoken).toContain("called to tell you");
      expect(messages[0]?.spoken).toContain("the boiler is leaking");
      expect(messages[0]?.spoken).not.toContain("…");
      expect(sms).toHaveLength(1);
    } finally {
      globalThis.fetch = original;
    }
  });

  it("rewrites an unread analyst summary into two butler sentences and texts that once", async () => {
    const calls: CallRec[] = [
      {
        id: "call_polish",
        contact_name: "Incoming call",
        status: "completed",
        summary: "The user, identified as Master Hadi, initiated a call with JARVIS.",
        transcript_json: JSON.stringify([
          { role: "assistant", text: "Who is calling?" },
          { role: "them", text: "This is Adz. Please call me back about the boiler." },
        ]),
        conversation_id: "conv_old",
        created_at: "2026-10-20T23:17:48.000Z",
      },
    ];
    const screens: ScreenRec[] = [{ call_id: "call_polish", direction: "inbound", caller_name: "A Test Call", reason: "" }];
    const messages: MsgRec[] = [
      {
        id: "cmsg_polish",
        call_id: "call_polish",
        caller_name: "A Test Call",
        summary: "The user, identified as Master Hadi, initiated a call with JARVIS.",
        spoken: "Sir, you have a message from A Test Call. They said The user, identified as Master Hadi, initiated a call with JARVIS.",
        called_at: "2026-10-20T23:17:48.000Z",
        read_at: null,
        created_at: "2026-10-20T23:20:00.000Z",
      },
    ];
    const env = settleEnv(calls, screens, messages);
    const sms: string[] = [];
    const original = globalThis.fetch;
    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      const method = init?.method ?? "GET";
      if (url.includes("chat/completions")) {
        return new Response(
          JSON.stringify({
            choices: [
              {
                message: {
                  content: '{"name":"Adz","spoken":"Sir, Adz rang at 00:17. He\'d like you to call him back about the boiler."}',
                },
              },
            ],
          }),
          { status: 200 },
        );
      }
      if (url.includes("/v1/workspace/webhooks") && method === "POST") {
        return new Response(JSON.stringify({ webhook_id: "wh_test", webhook_secret: "super-secret-value" }), { status: 200 });
      }
      if (url.includes("api.elevenlabs.io")) return new Response(JSON.stringify({ webhooks: [] }), { status: 200 });
      if (url.includes("api.twilio.com")) {
        sms.push(String(init?.body ?? ""));
        return new Response("{}", { status: 201 });
      }
      return new Response("{}", { status: 404 });
    }) as typeof fetch;
    try {
      const response = await route(
        new Request("https://jarvis.example/calls/settle", { method: "POST", headers: { authorization: "Bearer secret-token" } }),
        env,
        ctx(),
      );
      expect(response.status).toBe(200);
      const body = (await response.json()) as { settled: Array<{ call_id: string; spoken: string | null }> };
      const hit = body.settled.find((row) => row.call_id === "call_polish");
      expect(hit?.spoken).toBe(
        "Sir, Adz called to tell you he'd like you to call him back about the boiler. Would you like me to call them back, or would you rather call them yourself?",
      );
      expect(hit?.spoken).not.toContain("…");
      expect(messages[0]?.caller_name).toBe("Adz");
      expect(messages[0]?.spoken).toBe(hit?.spoken);
      expect(sms).toHaveLength(1);
      expect(new URLSearchParams(sms[0]).get("Body")).toBe(hit?.spoken);

      const again = await route(
        new Request("https://jarvis.example/calls/settle", { method: "POST", headers: { authorization: "Bearer secret-token" } }),
        env,
        ctx(),
      );
      expect(again.status).toBe(200);
      expect(sms).toHaveLength(1);
    } finally {
      globalThis.fetch = original;
    }
  });

  it("settles a hung-up Polly call and texts a saved message that never reached Twilio", async () => {
    const calls: CallRec[] = [
      {
        id: "call_f0ce67d2098c49208dacf2c63f719957",
        contact_name: "Incoming call",
        status: "in_progress",
        summary: "",
        transcript_json: JSON.stringify([
          { role: "assistant", text: "Who is calling?" },
          { role: "them", text: "Tell me a joke." },
        ]),
        conversation_id: null,
        created_at: "2026-10-20T23:02:02.974Z",
        twilio_sid: "CA109c4e44c456d95e2f30115db502a40c",
      },
      {
        id: "call_959c1db561354036a621adcc6ae1dc35",
        contact_name: "Incoming call",
        status: "completed",
        summary: "Sir, Me rang at 00:59. Um, tell me a joke.",
        transcript_json: "[]",
        conversation_id: "conv_me",
        created_at: "2026-10-20T23:59:34.533Z",
        twilio_sid: "CAbe3d3488f344fab7738be7fa9a840a51",
      },
    ];
    const screens: ScreenRec[] = [
      { call_id: "call_f0ce67d2098c49208dacf2c63f719957", direction: "inbound", caller_name: "", reason: "" },
      { call_id: "call_959c1db561354036a621adcc6ae1dc35", direction: "inbound", caller_name: "Me", reason: "" },
    ];
    const messages: MsgRec[] = [
      {
        id: "cmsg_32de99cd1efd4a78880feee1b605b8a4",
        call_id: "call_959c1db561354036a621adcc6ae1dc35",
        caller_name: "Me",
        summary: "Sir, Me rang at 00:59. Um, tell me a joke.",
        spoken: "Sir, Me rang at 00:59. Um, tell me a joke.",
        called_at: "2026-10-20T23:59:34.533Z",
        read_at: null,
        created_at: "2026-10-21T00:01:42.195Z",
      },
    ];
    const env = settleEnv(calls, screens, messages);
    const sms: string[] = [];
    const original = globalThis.fetch;
    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      const method = init?.method ?? "GET";
      if (url.includes("/Calls/")) return new Response(JSON.stringify({ status: "completed" }), { status: 200 });
      if (url.includes("api.twilio.com") && method === "POST") {
        sms.push(String(init?.body ?? ""));
        return new Response(JSON.stringify({ sid: "SMexamplemessage0000000000000000", status: "queued" }), { status: 201 });
      }
      if (url.includes("/v1/workspace/webhooks") && method === "POST") {
        return new Response(JSON.stringify({ webhook_id: "wh_test", webhook_secret: "super-secret-value" }), { status: 200 });
      }
      if (url.includes("api.elevenlabs.io")) return new Response(JSON.stringify({ webhooks: [] }), { status: 200 });
      return new Response("{}", { status: 404 });
    }) as typeof fetch;
    try {
      const response = await route(
        new Request("https://jarvis.example/calls/settle", { method: "POST", headers: { authorization: "Bearer secret-token" } }),
        env,
        ctx(),
      );
      expect(response.status).toBe(200);
      const body = (await response.json()) as {
        sms: { sid: string; status: string; sent: boolean; error_code: string };
        settled: Array<{ call_id: string; status: string; message_id: string | null; spoken: string | null }>;
      };
      expect(calls[0]?.status).toBe("completed");
      const polly = body.settled.find((row) => row.call_id === "call_f0ce67d2098c49208dacf2c63f719957");
      expect(polly?.message_id).toBeTruthy();
      expect(polly?.spoken).toContain("called to tell you");
      expect(polly?.spoken?.toLowerCase()).toContain("tell me a joke");
      const meLine =
        "Sir, Me called to tell you tell me a joke. Would you like me to call them back, or would you rather call them yourself?";
      const saved = sms.map((item) => new URLSearchParams(item).get("Body"));
      expect(saved.filter((item) => item === meLine)).toHaveLength(1);
      expect(body.sms.sent).toBe(false);
      expect(body.sms.sid).toBe("SMexamplemessage0000000000000000");
      expect(body.sms.status).toBe("queued");
      expect(body.sms.error_code).toBe("");
      expect(sms.length).toBeGreaterThanOrEqual(2);

      const again = await route(
        new Request("https://jarvis.example/calls/settle", { method: "POST", headers: { authorization: "Bearer secret-token" } }),
        env,
        ctx(),
      );
      expect(again.status).toBe(200);
      expect(sms).toHaveLength(saved.length);
    } finally {
      globalThis.fetch = original;
    }
  });

  it("requires the app token before settling", async () => {
    const env = settleEnv([], [], []);
    const response = await route(new Request("https://jarvis.example/calls/settle", { method: "POST" }), env, ctx());
    expect(response.status).toBe(401);
  });
});
