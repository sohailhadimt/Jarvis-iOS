import { describe, expect, it } from "vitest";
import { rememberInboundMessage, spokenCallMessage } from "../src/call-messages";
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

function messageEnv(screens: ScreenRow[], calls: CallRow[], messages: MessageRow[]): Env {
  const db = {
    prepare(sql: string) {
      const statement = {
        args: [] as unknown[],
        bind(...args: unknown[]) {
          this.args = args;
          return this;
        },
        async run() {
          if (sql.includes("INSERT INTO call_messages")) {
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
        select(): MessageRow[] {
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
          if (sql.includes("FROM call_screen")) {
            return screens.find((row) => row.call_id === String(this.args[0])) ?? null;
          }
          if (sql.includes("FROM outbound_calls")) {
            return calls.find((row) => row.id === String(this.args[0])) ?? null;
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
  it("speaks the caller, the London time, and the reason without a phone number", () => {
    const line = spokenCallMessage(
      "Sohil",
      "2026-10-20T10:06:00.000Z",
      "to check you're well and asked you to ring him back on +15550001111",
    );
    expect(line).toBe("Sir, Sohil rang at 11:06. To check you're well and asked you to ring him back.");
    expect(line).not.toContain("+1555");
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
      expect(messages[0]?.spoken).toBe("Sir, Sohil rang at 11:06. To check you're well and asked you to ring him back.");
      expect(bodies).toHaveLength(1);
      const sent = new URLSearchParams(bodies[0]);
      expect(sent.get("To")).toBe("+15557654321");
      expect(sent.get("Body")).toBe(messages[0]?.spoken);

      const unread = await route(new Request("https://jarvis.example/calls/messages?unread=1", { headers: bearer }), env, ctx());
      expect(unread.status).toBe(200);
      const listed = (await unread.json()) as { messages: Array<{ id: string; read: boolean; spoken: string }> };
      expect(listed.messages).toHaveLength(1);
      expect(listed.messages[0]?.read).toBe(false);
      expect(listed.messages[0]?.spoken).toContain("Sir, Sohil rang at 11:06.");

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
      expect(messages[0]?.spoken).toBe("Sir, Sam rang at 11:06. The boiler is leaking.");
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

  it("rejects a missing bearer token", async () => {
    const env = messageEnv([], [], []);
    const response = await route(new Request("https://jarvis.example/calls/messages?unread=1"), env, ctx());
    expect(response.status).toBe(401);
  });
});

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
