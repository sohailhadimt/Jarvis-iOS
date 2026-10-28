import { describe, expect, it } from "vitest";
import { INBOUND_GREETING, clearElevenLabsTelephonyCache, twilioSignature } from "../src/calls";
import { continueInboundConversation } from "../src/inbound-converse";
import {
  INTERCEPTOR_DECLINE,
  INTERCEPTOR_GREETING,
  forwardedCall,
  interceptorAnswers,
  interceptorPrompt,
  missedCallerLine,
} from "../src/interceptor";
import { route } from "../src/routes";
import type { Env } from "../src/types";

const bearer = { authorization: "Bearer secret-token", "content-type": "application/json" };
const signedInbound = "https://jarvis-backend.jarvis-hadi.workers.dev/calls/inbound";

function callingEnv(): Env {
  return {
    JARVIS_APP_TOKEN: "secret-token",
    TWILIO_ACCOUNT_SID: "ACexampleaccountsid000000000000",
    TWILIO_AUTH_TOKEN: "twilio-auth-token-example",
    TWILIO_FROM_NUMBER: "+447700900000",
    ELEVENLABS_API_KEY: "elevenlabs-key-example-value",
    ELEVENLABS_AGENT_ID: "agent_example",
    OWNER_PHONE: "+15557654321",
    DB: stateDb(),
  };
}

function stateDb(seed: Record<string, string> = {}, summaries: string[] = []): Env["DB"] {
  const state = { ...seed };
  return {
    prepare(sql: string) {
      let bound: unknown[] = [];
      const statement = {
        bind(...args: unknown[]) {
          bound = args;
          return statement;
        },
        async all() {
          return { results: [], success: true, meta: {} };
        },
        async first() {
          if (sql.includes("runtime_state")) {
            const value = state[String(bound[0] ?? "")];
            return value == null ? null : { value };
          }
          if (sql.includes("outbound_calls")) {
            return { summary: null, status: "in_progress", transcript_json: "[]", created_at: "2026-10-21T10:00:00.000Z" };
          }
          return null;
        },
        async run() {
          if (sql.includes("INSERT INTO runtime_state")) state[String(bound[0] ?? "")] = String(bound[1] ?? "");
          if (sql.includes("summary = ?")) summaries.push(String(bound[0] ?? ""));
          return { success: true, meta: { changes: 1 } };
        },
      };
      return statement;
    },
  } as unknown as Env["DB"];
}

function heldCtx(): { ctx: ExecutionContext; done: () => Promise<void> } {
  const jobs: Promise<unknown>[] = [];
  return {
    ctx: {
      waitUntil(promise: Promise<unknown>) {
        jobs.push(promise.catch(() => undefined));
      },
      passThroughOnException() {
        return undefined;
      },
      props: {},
    } as ExecutionContext,
    done: () => Promise.all(jobs).then(() => undefined),
  };
}

function inbound(params: Record<string, string>, signature: string): Request {
  return new Request("http://internal.local/calls/inbound", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded", "X-Twilio-Signature": signature },
    body: new URLSearchParams(params).toString(),
  });
}

describe("forwarded calls", () => {
  it("treats ForwardedFrom or a different Called number as a forward", () => {
    expect(forwardedCall({ ForwardedFrom: "+447700900123", Called: "+447700900000", To: "+447700900000" }, "+447700900000")).toEqual({
      forwarded: true,
      original: "+447700900123",
    });
    expect(forwardedCall({ Called: "+447700900123", To: "+447700900000" }, "+447700900000")).toEqual({
      forwarded: true,
      original: "+447700900123",
    });
    expect(forwardedCall({ Called: "+447700900000", To: "+447700900000" }, "+447700900000")).toEqual({
      forwarded: false,
      original: null,
    });
    expect(forwardedCall({ From: "+15550001111", To: "+447700900000" }, "+447700900000").forwarded).toBe(false);
    expect(interceptorAnswers({ enabled: true, busy: false })).toBe(true);
    expect(interceptorAnswers({ enabled: false, busy: true })).toBe(true);
    expect(interceptorAnswers({ enabled: false, busy: false })).toBe(false);
    expect(missedCallerLine("")).toBe("Sir, you missed a call.");
    expect(missedCallerLine("07700 900123")).toBe("Sir, you missed a call from 07700 900123.");
    expect(interceptorPrompt()).toContain(INTERCEPTOR_GREETING);
  });

  it("reads the default switch and saves a change", async () => {
    const env = callingEnv();
    const open = await route(new Request("https://jarvis.test/calls/interceptor", { headers: bearer }), env, heldCtx().ctx);
    expect(open.status).toBe(200);
    expect(await open.json()).toEqual({ enabled: true, busy: false });

    const locked = await route(new Request("https://jarvis.test/calls/interceptor"), env, heldCtx().ctx);
    expect(locked.status).toBe(401);

    const saved = await route(
      new Request("https://jarvis.test/calls/interceptor", {
        method: "POST",
        headers: bearer,
        body: JSON.stringify({ enabled: false }),
      }),
      env,
      heldCtx().ctx,
    );
    expect(saved.status).toBe(200);
    expect(await saved.json()).toEqual({ enabled: false, busy: false });

    const busy = await route(
      new Request("https://jarvis.test/calls/interceptor", {
        method: "POST",
        headers: bearer,
        body: JSON.stringify({ busy: true }),
      }),
      env,
      heldCtx().ctx,
    );
    expect(await busy.json()).toEqual({ enabled: false, busy: true });

    const empty = await route(
      new Request("https://jarvis.test/calls/interceptor", {
        method: "POST",
        headers: bearer,
        body: JSON.stringify({}),
      }),
      env,
      heldCtx().ctx,
    );
    expect(empty.status).toBe(400);
  });

  it("asks a forwarded caller to try later and texts the missed caller", async () => {
    const summaries: string[] = [];
    const env = callingEnv();
    env.DB = stateDb({ interceptor_enabled: "0" }, summaries);
    const params = {
      CallSid: "CA123",
      From: "+15550001111",
      To: "+447700900000",
      Called: "+447700900123",
      ForwardedFrom: "+447700900123",
    };
    const signature = await twilioSignature(signedInbound, params, "twilio-auth-token-example");
    const seen: Array<{ url: string; body: string }> = [];
    const original = globalThis.fetch;
    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      seen.push({ url: String(input), body: String(init?.body ?? "") });
      return new Response("{}", { status: 201 });
    }) as typeof fetch;
    const held = heldCtx();
    try {
      const response = await route(inbound(params, signature), env, held.ctx);
      await held.done();
      expect(response.status).toBe(200);
      const xml = await response.text();
      expect(xml).toContain(INTERCEPTOR_DECLINE);
      expect(xml).toContain("<Hangup");
      expect(xml).not.toContain(INTERCEPTOR_GREETING);
      expect(xml).not.toContain("Master Hadi's phone");
      expect(xml).not.toContain("+15550001111");
      expect(seen.some((call) => call.url.includes("register-call"))).toBe(false);
      expect(summaries).toContain("Asked the caller to try again later.");
      expect(summaries.some((line) => line.includes("15550001111"))).toBe(false);
      const sent = seen.filter((call) => call.url.includes("Messages.json")).map((call) => new URLSearchParams(call.body));
      expect(sent).toHaveLength(1);
      expect(sent[0]?.get("To")).toBe("+15557654321");
      expect(sent[0]?.get("From")).toBe("+447700900000");
      expect(sent[0]?.get("Body")).toContain("missed a call");
      expect(sent[0]?.get("Body")).toContain("+15550001111");
      expect(sent[0]?.get("Body")).not.toContain("447700900123");
    } finally {
      globalThis.fetch = original;
    }
  });

  it("greets a forwarded Polly call and still screens a direct call", async () => {
    const env = callingEnv();
    env.ELEVENLABS_FORCE_POLLY = "true";
    const forwarded = {
      CallSid: "CA123",
      From: "+15550001111",
      To: "+447700900000",
      Called: "+447700900123",
    };
    const direct = { CallSid: "CA124", From: "+15550001111", To: "+447700900000", Called: "+447700900000" };
    const original = globalThis.fetch;
    globalThis.fetch = (async () => new Response("{}", { status: 500 })) as typeof fetch;
    try {
      const forwardedSignature = await twilioSignature(signedInbound, forwarded, "twilio-auth-token-example");
      const opened = await route(inbound(forwarded, forwardedSignature), env, heldCtx().ctx);
      const xml = await opened.text();
      expect(xml).toContain("<Gather");
      expect(xml).toContain(INTERCEPTOR_GREETING);
      expect(xml).not.toContain("Master Hadi's phone");
      expect(xml).not.toContain(INTERCEPTOR_DECLINE);

      env.DB = stateDb({ interceptor_enabled: "0", interceptor_busy: "1" });
      const busySignature = await twilioSignature(signedInbound, forwarded, "twilio-auth-token-example");
      const busy = await route(inbound(forwarded, busySignature), env, heldCtx().ctx);
      expect(await busy.text()).toContain(INTERCEPTOR_GREETING);

      const directSignature = await twilioSignature(signedInbound, direct, "twilio-auth-token-example");
      const plain = await route(inbound(direct, directSignature), env, heldCtx().ctx);
      const plainXml = await plain.text();
      expect(plainXml).toContain(INBOUND_GREETING);
      expect(plainXml).not.toContain("Sohail Hadi's line");
    } finally {
      globalThis.fetch = original;
    }
  });

  it("sends the interceptor greeting as the ElevenLabs opening line", async () => {
    clearElevenLabsTelephonyCache();
    const env = callingEnv();
    env.ELEVENLABS_FORCE_POLLY = "false";
    const params = {
      CallSid: "CA123",
      From: "+15550001111",
      To: "+447700900000",
      ForwardedFrom: "+447700900123",
    };
    const signature = await twilioSignature(signedInbound, params, "twilio-auth-token-example");
    const seen: Array<{ url: string; body: string }> = [];
    const twiml = '<?xml version="1.0" encoding="UTF-8"?><Response><Connect><Stream url="wss://example.test/media" /></Connect></Response>';
    const original = globalThis.fetch;
    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      seen.push({ url, body: String(init?.body ?? "") });
      if (url.includes("register-call")) return new Response(JSON.stringify(twiml), { status: 200 });
      return new Response("no", { status: 500 });
    }) as typeof fetch;
    try {
      const response = await route(inbound(params, signature), env, heldCtx().ctx);
      expect(response.status).toBe(200);
      expect(await response.text()).toBe(twiml);
      const registered = seen.find((call) => call.url.includes("register-call"));
      const payload = JSON.parse(registered?.body ?? "{}") as {
        conversation_initiation_client_data?: { dynamic_variables?: { opening_line?: string; brief?: string } };
      };
      expect(payload.conversation_initiation_client_data?.dynamic_variables?.opening_line).toBe(INTERCEPTOR_GREETING);
      expect(payload.conversation_initiation_client_data?.dynamic_variables?.brief).toBe("Take a message.");
    } finally {
      globalThis.fetch = original;
    }
  });

  it("keeps asking for a message after the interceptor greeting", async () => {
    const env = callingEnv();
    const transcript = JSON.stringify([{ role: "assistant", text: INTERCEPTOR_GREETING }]);
    env.DB = {
      prepare(sql: string) {
        const statement = {
          bind() {
            return statement;
          },
          async all() {
            return { results: [], success: true, meta: {} };
          },
          async first() {
            if (sql.includes("outbound_calls")) {
              return { status: "in_progress", summary: null, transcript_json: transcript };
            }
            return null;
          },
          async run() {
            return { success: true, meta: { changes: 1 } };
          },
        };
        return statement;
      },
    } as unknown as Env["DB"];
    const xml = await continueInboundConversation(env, "call_abc", "", "https://jarvis.test/calls/converse/call_abc");
    expect(xml).toContain("May I take a message?");
    expect(xml).not.toContain("Who's calling");
  });
});
