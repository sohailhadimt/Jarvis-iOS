import { describe, expect, it } from "vitest";
import { callPushCopy, callTextIsThin, deliverOwnerText, rememberInboundMessage, spokenCallMessage } from "../src/call-messages";
import { sendSmsResult } from "../src/sms-desk";
import { route } from "../src/routes";
import type { Env } from "../src/types";

interface ScreenRow {
  call_id: string;
  direction: string;
  caller_name: string;
  reason: string;
}

interface CallRow {
  id: string;
  status: string;
  summary: string | null;
  created_at: string;
  transcript_json?: string;
  recording?: boolean;
}

interface MessageRow {
  id: string;
  call_id: string;
  caller_name: string;
  summary: string;
  spoken: string;
  called_at: string;
  read_at: string | null;
  created_at: string;
}

function messageEnv(
  screens: ScreenRow[],
  calls: CallRow[],
  messages: MessageRow[],
  devices: string[] = [],
  kv: Map<string, string> = new Map(),
): Env {
  const db = {
    prepare(sql: string) {
      const statement = {
        args: [] as unknown[],
        bind(...args: unknown[]) {
          this.args = args;
          return this;
        },
        async run() {
          if (sql.includes("INSERT INTO runtime_state")) {
            kv.set(String(this.args[0]), String(this.args[1]));
          } else if (sql.includes("INSERT INTO call_messages")) {
            messages.push({
              id: String(this.args[0]),
              call_id: String(this.args[1]),
              caller_name: String(this.args[2]),
              summary: String(this.args[3]),
              spoken: String(this.args[4]),
              called_at: String(this.args[5]),
              read_at: null,
              created_at: String(this.args[6]),
            });
          } else if (sql.includes("SET caller_name = ?")) {
            const row = messages.find((item) => item.id === String(this.args[3]));
            if (row) {
              row.caller_name = String(this.args[0]);
              row.summary = String(this.args[1]);
              row.spoken = String(this.args[2]);
            }
          } else if (sql.includes("SET summary = ?")) {
            const row = messages.find((item) => item.id === String(this.args[2]));
            if (row) {
              row.summary = String(this.args[0]);
              row.spoken = String(this.args[1]);
            }
          } else if (sql.includes("SET read_at = ?")) {
            const row = messages.find((item) => item.id === String(this.args[1]) && item.read_at == null);
            if (row) row.read_at = String(this.args[0]);
          }
          return { success: true, meta: { changes: 1 } };
        },
        select(): unknown[] {
          if (sql.includes("FROM call_devices")) {
            return devices.map((token) => ({ token }));
          }
          if (sql.includes("WHERE read_at IS NULL")) {
            return messages.filter((row) => row.read_at == null).sort((a, b) => a.created_at.localeCompare(b.created_at));
          }
          if (sql.includes("FROM call_messages WHERE call_id = ?")) {
            return messages.filter((row) => row.call_id === String(this.args[0]));
          }
          if (sql.includes("FROM call_messages WHERE id = ?")) {
            return messages.filter((row) => row.id === String(this.args[0]));
          }
          if (sql.includes("FROM call_messages")) {
            return [...messages].sort((a, b) => b.created_at.localeCompare(a.created_at));
          }
          return [];
        },
        async first() {
          if (sql.includes("runtime_state")) {
            const value = kv.get(String(this.args[0]));
            return value == null ? null : { value };
          }
          if (sql.includes("FROM call_screen")) {
            return screens.find((row) => row.call_id === String(this.args[0])) ?? null;
          }
          if (sql.includes("FROM call_recordings")) {
            const call = calls.find((row) => row.id === String(this.args[0]));
            return call?.recording ? { recording_sid: "REaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" } : null;
          }
          if (sql.includes("FROM outbound_calls")) {
            const call = calls.find((row) => row.id === String(this.args[0]));
            if (!call) return null;
            if (sql.includes("transcript_json")) return { transcript_json: call.transcript_json ?? null };
            return call;
          }
          return this.select()[0] ?? null;
        },
        async all() {
          return { results: this.select(), success: true, meta: {} };
        },
      };
      return statement;
    },
  };
  return {
    JARVIS_APP_TOKEN: "secret-token",
    OWNER_PHONE: "+15557654321",
    TWILIO_ACCOUNT_SID: "AC123",
    TWILIO_AUTH_TOKEN: "twilio-token",
    TWILIO_FROM_NUMBER: "+15551230001",
    DB: db as unknown as D1Database,
  };
}

const bearer = { authorization: "Bearer secret-token" };

describe("call messages", () => {
  it("speaks the caller, the London time, and a callback number", () => {
    const line = spokenCallMessage(
      "Sohil",
      "2026-10-20T10:06:00.000Z",
      "to check you're well and asked you to ring him back on +15550001111",
    );
    expect(line).toBe(
      "Sir, Sohil called to tell you to check you're well and asked you to ring him back on +15550001111. Would you like me to call them back, or would you rather call them yourself?",
    );
    expect(line).toContain("+15550001111");
    expect(spokenCallMessage("Sohil", "2026-10-20T10:06:00.000Z", "the boiler is leaking", "him")).toContain("call him back");
    expect(spokenCallMessage("Sohil", "2026-10-20T10:06:00.000Z", "the boiler is leaking")).toContain("call them back");
  });

  it("skips a greeting and asks whether to call them back", () => {
    const line = spokenCallMessage(
      "Sohail",
      "2026-10-21T01:41:00.000Z",
      "Good evening. The boiler is leaking. Please call me back on +15550001111.",
    );
    expect(line).toBe(
      "Sir, Sohail called to tell you the boiler is leaking. Please call me back on +15550001111. Would you like me to call them back, or would you rather call them yourself?",
    );
    expect(line).not.toContain("Good evening");
    expect(callTextIsThin("Sir, Sohail rang at 02:41. Good evening.")).toBe(true);
    expect(callTextIsThin(line)).toBe(false);
    const copy = callPushCopy("Sohail", "Sir, Sohail rang at 02:41. Good evening. The boiler is leaking.", line);
    expect(copy.body).toBe("The boiler is leaking.");
    expect(copy.body).not.toContain("Good evening");
  });

  it("stores an unread inbound message, texts it once, and marks it read", async () => {
    const screens: ScreenRow[] = [
      { call_id: "call_abc", direction: "inbound", caller_name: "Sohil", reason: "" },
    ];
    const calls: CallRow[] = [
      {
        id: "call_abc",
        status: "completed",
        summary: "to check you're well and asked you to ring him back",
        created_at: "2026-10-20T10:06:00.000Z",
      },
    ];
    const messages: MessageRow[] = [];
    const env = messageEnv(screens, calls, messages);
    const bodies: string[] = [];
    const original = globalThis.fetch;
    globalThis.fetch = (async (_input: RequestInfo | URL, init?: RequestInit) => {
      bodies.push(String(init?.body ?? ""));
      return new Response("{}", { status: 201 });
    }) as typeof fetch;
    try {
      expect(await rememberInboundMessage(env, "call_abc")).toBe(true);
      expect(await rememberInboundMessage(env, "call_abc")).toBe(true);
      expect(messages).toHaveLength(1);
      expect(messages[0]?.spoken).toBe(
        "Sir, Sohil called to tell you to check you're well and asked you to ring him back. Would you like me to call them back, or would you rather call them yourself?",
      );
      expect(bodies).toHaveLength(1);
      const sent = new URLSearchParams(bodies[0]);
      expect(sent.get("To")).toBe("+15557654321");
      expect(sent.get("Body")).toBe(messages[0]?.spoken);

      const unread = await route(new Request("https://jarvis.example/calls/messages?unread=1", { headers: bearer }), env, ctx());
      expect(unread.status).toBe(200);
      const listed = (await unread.json()) as { messages: Array<{ id: string; read: boolean; spoken: string }> };
      expect(listed.messages).toHaveLength(1);
      expect(listed.messages[0]?.read).toBe(false);
      expect(listed.messages[0]?.spoken).toContain("Sir, Sohil called to tell you");

      const read = await route(
        new Request(`https://jarvis.example/calls/messages/${listed.messages[0]?.id}/read`, { method: "POST", headers: bearer }),
        env,
        ctx(),
      );
      expect(read.status).toBe(200);
      const again = await route(new Request("https://jarvis.example/calls/messages?unread=1", { headers: bearer }), env, ctx());
      const empty = (await again.json()) as { messages: unknown[] };
      expect(empty.messages).toEqual([]);

      const recent = await route(new Request("https://jarvis.example/calls/messages", { headers: bearer }), env, ctx());
      const kept = (await recent.json()) as { messages: Array<{ read: boolean }> };
      expect(kept.messages).toHaveLength(1);
      expect(kept.messages[0]?.read).toBe(true);
    } finally {
      globalThis.fetch = original;
    }
  });

  it("texts once when a placeholder summary is replaced with the real message", async () => {
    const screens: ScreenRow[] = [{ call_id: "call_vm", direction: "inbound", caller_name: "Sam", reason: "" }];
    const calls: CallRow[] = [
      {
        id: "call_vm",
        status: "completed",
        summary: "The boiler is leaking.",
        created_at: "2026-10-20T10:06:00.000Z",
      },
    ];
    const messages: MessageRow[] = [
      {
        id: "cmsg_e89beexample",
        call_id: "call_vm",
        caller_name: "Someone",
        summary: "A caller left a message.",
        spoken: "Sir, you have a message from Someone at 11:06.",
        called_at: "2026-10-20T10:06:00.000Z",
        read_at: null,
        created_at: "2026-10-20T10:07:00.000Z",
      },
    ];
    const env = messageEnv(screens, calls, messages);
    const bodies: string[] = [];
    const original = globalThis.fetch;
    globalThis.fetch = (async (_input: RequestInfo | URL, init?: RequestInit) => {
      bodies.push(String(init?.body ?? ""));
      return new Response("{}", { status: 201 });
    }) as typeof fetch;
    try {
      expect(await rememberInboundMessage(env, "call_vm")).toBe(true);
      expect(await rememberInboundMessage(env, "call_vm")).toBe(true);
      expect(messages[0]?.summary).toBe("The boiler is leaking.");
      expect(messages[0]?.caller_name).toBe("Sam");
      expect(messages[0]?.spoken).toBe(
        "Sir, Sam called to tell you the boiler is leaking. Would you like me to call them back, or would you rather call them yourself?",
      );
      expect(messages[0]?.spoken).not.toContain("…");
      expect(bodies).toHaveLength(1);
    } finally {
      globalThis.fetch = original;
    }
  });

  it("does not store an outbound call", async () => {
    const messages: MessageRow[] = [];
    const env = messageEnv(
      [{ call_id: "call_out", direction: "outbound", caller_name: "Plumber", reason: "" }],
      [{ id: "call_out", status: "completed", summary: "They can come today.", created_at: "2026-10-20T10:06:00.000Z" }],
      messages,
    );
    expect(await rememberInboundMessage(env, "call_out")).toBe(false);
    expect(messages).toHaveLength(0);
  });

  it("returns the Twilio error code when the text is rejected", async () => {
    const env = messageEnv([], [], []);
    const original = globalThis.fetch;
    globalThis.fetch = (async () =>
      new Response(JSON.stringify({ code: 20003, message: "Primary compliance profile is not approved.", status: 401 }), {
        status: 401,
      })) as typeof fetch;
    try {
      const result = await sendSmsResult(env, "+15557654321", "Sir, Me rang at 00:59. Um, tell me a joke.");
      expect(result.ok).toBe(false);
      expect(result.errorCode).toBe("20003");
      expect(result.error).toContain("compliance profile");
      expect(result.sid).toBe("");
    } finally {
      globalThis.fetch = original;
    }
  });

  it("uses the caller in the title and the short reason as the body", () => {
    const copy = callPushCopy(
      "Sohil",
      "Sir, Sohil rang at 11:06. To check you're well and asked you to ring him back.",
      "to check you're well and asked you to ring him back",
    );
    expect(copy.title).toBe("JARVIS – Call from Sohil");
    expect(copy.body).toBe("To check you're well and asked you to ring him back.");
    expect(copy.body).not.toContain("rang at");
  });

  it("pushes the short line and skips SMS when a device token is registered", async () => {
    const screens: ScreenRow[] = [{ call_id: "call_push", direction: "inbound", caller_name: "Sohil", reason: "" }];
    const calls: CallRow[] = [
      {
        id: "call_push",
        status: "completed",
        summary: "to check you're well and asked you to ring him back",
        created_at: "2026-10-20T10:06:00.000Z",
        transcript_json: JSON.stringify([
          { role: "them", text: "Please ring me back." },
          { role: "assistant", text: "I shall tell him." },
        ]),
        recording: true,
      },
    ];
    const messages: MessageRow[] = [];
    const env = messageEnv(screens, calls, messages, ["00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"]);
    env.APNS_KEY_ID = "KEYID12345";
    env.APNS_TEAM_ID = "TEAMID1234";
    env.APNS_PRIVATE_KEY = await testApnsPem();
    env.APNS_BUNDLE_ID = "com.sohail.jarvis";
    const hits: { url: string; body: string; topic: string }[] = [];
    const original = globalThis.fetch;
    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const headers = new Headers(init?.headers);
      hits.push({ url: String(input), body: String(init?.body ?? ""), topic: headers.get("apns-topic") ?? "" });
      return new Response("", { status: 200 });
    }) as typeof fetch;
    try {
      expect(await rememberInboundMessage(env, "call_push")).toBe(true);
      expect(hits.some((hit) => hit.url.includes("twilio.com"))).toBe(false);
      const push = hits.find((hit) => hit.url.includes("api.push.apple.com"));
      expect(push?.topic).toBe("com.sohail.jarvis");
      const payload = JSON.parse(push?.body ?? "{}") as {
        aps: { alert: { title: string; body: string }; category: string };
        kind: string;
        message_id: string;
        call_id: string;
      };
      expect(payload.aps.alert.title).toBe("JARVIS – Call from Sohil");
      expect(payload.aps.alert.body).toBe("To check you're well and asked you to ring him back.");
      expect(payload.aps.category).toBe("JARVIS_MESSAGE");
      expect(payload.kind).toBe("call_message");
      expect(payload.call_id).toBe("call_push");
      expect(payload.message_id).toMatch(/^cmsg_/);

      const card = await route(
        new Request(`https://jarvis.example/calls/messages/${payload.message_id}`, { headers: bearer }),
        env,
        ctx(),
      );
      expect(card.status).toBe(200);
      const body = (await card.json()) as {
        message: { caller_name: string; spoken: string; recording: boolean; transcript: Array<{ role: string; text: string }> };
      };
      expect(body.message.caller_name).toBe("Sohil");
      expect(body.message.spoken).toContain("called to tell you");
      expect(body.message.recording).toBe(true);
      expect(body.message.transcript.map((line) => line.role)).toEqual(["them", "assistant"]);
    } finally {
      globalThis.fetch = original;
    }
  });

  it("texts when a device is registered but Apple push is not configured", async () => {
    const screens: ScreenRow[] = [{ call_id: "call_sms", direction: "inbound", caller_name: "Sohil", reason: "" }];
    const calls: CallRow[] = [
      {
        id: "call_sms",
        status: "completed",
        summary: "The boiler is leaking.",
        created_at: "2026-10-20T10:06:00.000Z",
      },
    ];
    const env = messageEnv(screens, calls, [], ["abc123"]);
    const bodies: string[] = [];
    const original = globalThis.fetch;
    globalThis.fetch = (async (_input: RequestInfo | URL, init?: RequestInit) => {
      bodies.push(String(init?.body ?? ""));
      return new Response(JSON.stringify({ sid: "SMexample", status: "queued" }), { status: 201 });
    }) as typeof fetch;
    try {
      expect(await rememberInboundMessage(env, "call_sms")).toBe(true);
      expect(bodies).toHaveLength(1);
      expect(new URLSearchParams(bodies[0] ?? "").get("Body")?.toLowerCase()).toContain("the boiler is leaking");
    } finally {
      globalThis.fetch = original;
    }
  });

  it("does not text a call again when that body already went out", async () => {
    const spoken = "Sir, Sohail rang at 02:41. Good evening.";
    const kv = new Map<string, string>([
      [
        "owner_sms:cmsg_once",
        JSON.stringify({
          ok: false,
          sid: "",
          status: "401",
          errorCode: "20003",
          error: "refused",
          spoken,
        }),
      ],
    ]);
    const messages: MessageRow[] = [
      {
        id: "cmsg_once",
        call_id: "call_once",
        caller_name: "Sohail",
        summary: spoken,
        spoken,
        called_at: "2026-10-21T01:41:00.000Z",
        read_at: null,
        created_at: "2026-10-21T01:42:00.000Z",
      },
    ];
    const env = messageEnv([], [], messages, [], kv);
    let posts = 0;
    const original = globalThis.fetch;
    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const method = init?.method ?? "GET";
      if (String(input).includes("Messages.json") && method === "GET") {
        return new Response(JSON.stringify({ messages: [{ body: spoken, direction: "outbound-api", status: "delivered", sid: "SMold" }] }), {
          status: 200,
        });
      }
      if (method === "POST") posts += 1;
      return new Response("{}", { status: 201 });
    }) as typeof fetch;
    try {
      const first = await deliverOwnerText(env, "call_once");
      const second = await deliverOwnerText(env, "call_once");
      expect(first.sent).toBe(false);
      expect(second.sent).toBe(false);
      expect(posts).toBe(0);
    } finally {
      globalThis.fetch = original;
    }
  });

  it("sends one corrected body and then stops", async () => {
    const previous = "Sir, Sohail rang at 02:41. Good evening.";
    const spoken = "Sir, Sohail rang at 02:41. The boiler is leaking. Please call me back on +15550001111.";
    const kv = new Map<string, string>([
      [
        "owner_sms:cmsg_fix",
        JSON.stringify({ ok: false, sid: "", status: "401", errorCode: "20003", error: "refused", spoken: previous }),
      ],
    ]);
    const messages: MessageRow[] = [
      {
        id: "cmsg_fix",
        call_id: "call_fix",
        caller_name: "Sohail",
        summary: spoken,
        spoken,
        called_at: "2026-10-21T01:41:00.000Z",
        read_at: null,
        created_at: "2026-10-21T01:42:00.000Z",
      },
    ];
    const env = messageEnv([], [], messages, [], kv);
    const bodies: string[] = [];
    const original = globalThis.fetch;
    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const method = init?.method ?? "GET";
      if (String(input).includes("Messages.json") && method === "GET") {
        return new Response(
          JSON.stringify({ messages: [{ body: previous, direction: "outbound-api", status: "delivered", sid: "SMold" }] }),
          { status: 200 },
        );
      }
      if (method === "POST") {
        bodies.push(String(init?.body ?? ""));
        return new Response(JSON.stringify({ sid: "SMcorrected", status: "queued" }), { status: 201 });
      }
      return new Response("{}", { status: 404 });
    }) as typeof fetch;
    try {
      const blocked = await deliverOwnerText(env, "call_fix");
      const sent = await deliverOwnerText(env, "call_fix", { correction: true });
      const again = await deliverOwnerText(env, "call_fix", { correction: true });
      expect(blocked.sent).toBe(false);
      expect(sent.sent).toBe(true);
      expect(sent.sid).toBe("SMcorrected");
      expect(again.sent).toBe(false);
      expect(bodies).toHaveLength(1);
      expect(new URLSearchParams(bodies[0]).get("Body")).toBe(spoken);
    } finally {
      globalThis.fetch = original;
    }
  });

  it("rejects a missing bearer token", async () => {
    const env = messageEnv([], [], []);
    const response = await route(new Request("https://jarvis.example/calls/messages?unread=1"), env, ctx());
    expect(response.status).toBe(401);
  });
});

async function testApnsPem(): Promise<string> {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign"])) as CryptoKeyPair;
  const pkcs8 = await crypto.subtle.exportKey("pkcs8", pair.privateKey);
  if (!(pkcs8 instanceof ArrayBuffer)) throw new Error("expected pkcs8");
  const bytes = new Uint8Array(pkcs8);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  const body = btoa(binary);
  const lines = body.match(/.{1,64}/g)?.join("\n") ?? body;
  return `-----BEGIN PRIVATE KEY-----\n${lines}\n-----END PRIVATE KEY-----\n`;
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
