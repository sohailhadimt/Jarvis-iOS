import { describe, expect, it } from "vitest";
import { route } from "../src/routes";
import type { Env } from "../src/types";

interface AgentRow {
  id: string;
  conversation_id: string;
  role: string;
  text: string;
  status: string;
  reply_to: string | null;
  created_at: string;
}

function agentEnv(rows: AgentRow[]): Env {
  const db = {
    prepare(sql: string) {
      const statement = {
        args: [] as unknown[],
        bind(...args: unknown[]) {
          this.args = args;
          return this;
        },
        async run() {
          if (sql.includes("INSERT INTO agent_messages")) {
            rows.push({
              id: String(this.args[0]),
              conversation_id: String(this.args[1]),
              role: String(this.args[2]),
              text: String(this.args[3]),
              status: String(this.args[4]),
              reply_to: this.args[5] == null ? null : String(this.args[5]),
              created_at: String(this.args[6]),
            });
            return { success: true, meta: { changes: 1 } };
          }
          if (sql.includes("UPDATE agent_messages")) {
            const id = String(this.args[0]);
            const conversation = String(this.args[1]);
            let changes = 0;
            for (const row of rows) {
              if (row.id === id && row.conversation_id === conversation && row.role === "user") {
                row.status = "done";
                changes += 1;
              }
            }
            return { success: true, meta: { changes } };
          }
          return { success: true, meta: { changes: 0 } };
        },
        select(): AgentRow[] {
          if (sql.includes("role = 'assistant' AND reply_to")) {
            return rows.filter(
              (row) =>
                row.conversation_id === String(this.args[0]) &&
                row.role === "assistant" &&
                row.reply_to === String(this.args[1]),
            );
          }
          if (sql.includes("AND id = ?")) {
            return rows.filter((row) => row.conversation_id === String(this.args[0]) && row.id === String(this.args[1]));
          }
          if (sql.includes("id != ? AND created_at >= ?")) {
            return rows
              .filter(
                (row) =>
                  row.conversation_id === String(this.args[0]) &&
                  row.id !== String(this.args[1]) &&
                  row.created_at >= String(this.args[2]),
              )
              .sort((a, b) => a.created_at.localeCompare(b.created_at) || a.id.localeCompare(b.id));
          }
          if (sql.includes("created_at > ?")) {
            return rows
              .filter((row) => row.conversation_id === String(this.args[0]) && row.created_at > String(this.args[1]))
              .sort((a, b) => a.created_at.localeCompare(b.created_at));
          }
          return rows
            .filter((row) => row.conversation_id === String(this.args[0]))
            .sort((a, b) => b.created_at.localeCompare(a.created_at));
        },
        async first() {
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
    JARVIS_WEBHOOK_URL: "https://example.test/hook",
    JARVIS_WEBHOOK_KEY: "hook-key",
    DB: db as unknown as D1Database,
  };
}

function ctx(held: Promise<unknown>[]): ExecutionContext {
  return {
    waitUntil(promise: Promise<unknown>) {
      held.push(promise.catch(() => undefined));
    },
    passThroughOnException() {
      return undefined;
    },
    props: {},
  } as ExecutionContext;
}

const bearer = { authorization: "Bearer secret-token", "content-type": "application/json" };

describe("agent chat", () => {
  it("stores the message, forwards the task, and returns pending before the webhook finishes", async () => {
    const rows: AgentRow[] = [];
    const env = agentEnv(rows);
    const held: Promise<unknown>[] = [];
    const seen: Array<{ url: string; authorization: string; body: Record<string, unknown> }> = [];
    const original = globalThis.fetch;
    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
      const headers = new Headers(init?.headers);
      const body = typeof init?.body === "string" ? (JSON.parse(init.body) as Record<string, unknown>) : {};
      seen.push({ url, authorization: headers.get("authorization") ?? "", body });
      return new Response("accepted", { status: 202 });
    }) as typeof fetch;
    try {
      const response = await route(
        new Request("https://jarvis.test/agent/chat", {
          method: "POST",
          headers: bearer,
          body: JSON.stringify({ message: "What's on today, sir?", conversationId: "conv_home" }),
        }),
        env,
        ctx(held),
      );
      expect(response.status).toBe(200);
      const pending = (await response.json()) as { messageId: string; status: string };
      expect(pending.status).toBe("pending");
      expect(pending.messageId.startsWith("msg_")).toBe(true);
      expect(JSON.stringify(pending)).not.toContain("example.test");
      expect(JSON.stringify(pending)).not.toContain("hook-key");
      expect(rows).toHaveLength(1);
      expect(rows[0]).toMatchObject({ role: "user", status: "pending", text: "What's on today, sir?", conversation_id: "conv_home" });
      await Promise.all(held);
      expect(seen).toHaveLength(1);
      expect(seen[0]?.url).toBe("https://example.test/hook");
      expect(seen[0]?.authorization).toBe("hook-key");
      expect(seen[0]?.body).toEqual({
        task: "What's on today, sir?",
        conversationId: "conv_home",
        replyTo: pending.messageId,
      });
    } finally {
      globalThis.fetch = original;
    }
  });

  it("stores the assistant reply and lets the app poll past the user message", async () => {
    const rows: AgentRow[] = [];
    const env = agentEnv(rows);
    const held: Promise<unknown>[] = [];
    const original = globalThis.fetch;
    globalThis.fetch = (async () => new Response("ok", { status: 200 })) as typeof fetch;
    try {
      const posted = await route(
        new Request("https://jarvis.test/agent/chat", {
          method: "POST",
          headers: bearer,
          body: JSON.stringify({ message: "Good evening.", conversationId: "conv_home" }),
        }),
        env,
        ctx(held),
      );
      const pending = (await posted.json()) as { messageId: string };
      const reply = await route(
        new Request("https://jarvis.test/agent/reply", {
          method: "POST",
          headers: bearer,
          body: JSON.stringify({
            conversationId: "conv_home",
            replyTo: pending.messageId,
            text: "Good evening, sir. The evening is clear.",
          }),
        }),
        env,
        ctx(held),
      );
      expect(reply.status).toBe(200);
      const saved = (await reply.json()) as { ok: boolean; replyTo: string; status: string };
      expect(saved.ok).toBe(true);
      expect(saved.replyTo).toBe(pending.messageId);
      expect(saved.status).toBe("done");
      expect(rows.find((row) => row.id === pending.messageId)?.status).toBe("done");
      const polled = await route(
        new Request(`https://jarvis.test/agent/messages?conversationId=conv_home&since=${pending.messageId}`, {
          headers: { authorization: "Bearer secret-token" },
        }),
        env,
        ctx(held),
      );
      expect(polled.status).toBe(200);
      const body = (await polled.json()) as { messages: Array<{ role: string; text: string; replyTo: string }> };
      expect(body.messages).toHaveLength(1);
      expect(body.messages[0]).toMatchObject({
        role: "assistant",
        text: "Good evening, sir. The evening is clear.",
        replyTo: pending.messageId,
      });
      const byTime = await route(
        new Request("https://jarvis.test/agent/messages?conversationId=conv_home&since=1970-01-01T00:00:00.000Z", {
          headers: { authorization: "Bearer secret-token" },
        }),
        env,
        ctx(held),
      );
      const timed = (await byTime.json()) as { messages: Array<{ role: string }> };
      expect(timed.messages.map((row) => row.role)).toEqual(["user", "assistant"]);
    } finally {
      globalThis.fetch = original;
    }
  });

  it("answers in character when the assistant webhook refuses the task", async () => {
    const rows: AgentRow[] = [];
    const env = agentEnv(rows);
    const held: Promise<unknown>[] = [];
    const original = globalThis.fetch;
    globalThis.fetch = (async () => new Response("no", { status: 500 })) as typeof fetch;
    try {
      const response = await route(
        new Request("https://jarvis.test/agent/chat", {
          method: "POST",
          headers: bearer,
          body: JSON.stringify({ message: "What is on this evening?", conversationId: "conv_home" }),
        }),
        env,
        ctx(held),
      );
      expect(response.status).toBe(200);
      await Promise.all(held);
      const user = rows.find((row) => row.role === "user");
      const assistant = rows.find((row) => row.role === "assistant");
      expect(user?.status).toBe("done");
      expect(assistant?.text).toBe("I'm still with you, sir. Ask me again in a moment.");
      expect(assistant?.reply_to).toBe(user?.id);
    } finally {
      globalThis.fetch = original;
    }
  });

  it("refuses the chat when the webhook secret is missing and does not echo a key", async () => {
    const rows: AgentRow[] = [];
    const env = agentEnv(rows);
    env.JARVIS_WEBHOOK_URL = "";
    env.JARVIS_WEBHOOK_KEY = "";
    const response = await route(
      new Request("https://jarvis.test/agent/chat", {
        method: "POST",
        headers: bearer,
        body: JSON.stringify({ message: "Hello", conversationId: "conv_home" }),
      }),
      env,
      ctx([]),
    );
    expect(response.status).toBe(503);
    const text = await response.text();
    expect(text).toContain("webhook_not_configured");
    expect(text).not.toContain("hook-key");
    expect(rows).toHaveLength(0);
  });

  it("requires the app token", async () => {
    const response = await route(
      new Request("https://jarvis.test/agent/chat", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ message: "Hello", conversationId: "conv_home" }),
      }),
      agentEnv([]),
      ctx([]),
    );
    expect(response.status).toBe(401);
  });
});
