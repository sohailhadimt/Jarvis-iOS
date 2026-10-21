import { describe, expect, it } from "vitest";
import { needsDelegation } from "../src/call-desk";
import { callbackBrief, questionFromTranscript } from "../src/relay";
import { clampTimeout, inQuietHours, mayCall, ownerSummaryLine, spokenClip } from "../src/owner-alert";
import { approvedScreening, outboundOpening, screeningScript } from "../src/calls";
import { route } from "../src/routes";
import type { Env } from "../src/types";

describe("live question relay", () => {
  it("takes the caller's last line when JARVIS asks for a moment", () => {
    const question = questionFromTranscript([
      { role: "assistant", text: "Hello, this is JARVIS, Master Hadi's personal assistant. Master Hadi has asked me to tell you the gate is open." },
      { role: "them", text: "What time will he arrive?" },
      { role: "assistant", text: "One moment please." },
    ]);
    expect(question).toBe("What time will he arrive?");
    expect(questionFromTranscript([{ role: "them", text: "Hello" }])).toBeNull();
    expect(screeningScript()).toContain('say exactly: "One moment please."');
    expect(approvedScreening("He is free after four.")).toContain('say exactly: "One moment please."');
  });

  it("keeps the asked-me opening and a separate owner-call line", () => {
    expect(outboundOpening("I'm busy")).toContain("Master Hadi has asked me to tell you I'm busy.");
    const line = ownerSummaryLine("A task failed and needs you.");
    expect(line.startsWith("Hello, this is JARVIS.")).toBe(true);
    expect(line).not.toContain("has asked me to tell you");
    expect(line).toContain("Say details");
  });
});

describe("problem calls", () => {
  it("stays quiet at night and caps the day", () => {
    expect(inQuietHours(23 * 60, "22:00", "08:00")).toBe(true);
    expect(inQuietHours(7 * 60, "22:00", "08:00")).toBe(true);
    expect(inQuietHours(8 * 60, "22:00", "08:00")).toBe(false);
    expect(inQuietHours(12 * 60, "22:00", "08:00")).toBe(false);
    expect(mayCall({ quiet: true, countToday: 0, max: 3, urgentOnly: false, urgent: true })).toBe("push");
    expect(mayCall({ quiet: false, countToday: 3, max: 3, urgentOnly: false, urgent: true })).toBe("push");
    expect(mayCall({ quiet: false, countToday: 0, max: 3, urgentOnly: true, urgent: false })).toBe("push");
    expect(mayCall({ quiet: false, countToday: 1, max: 3, urgentOnly: false, urgent: false })).toBe("call");
    expect(clampTimeout(10)).toBe(30);
    expect(clampTimeout(44)).toBe(44);
    expect(clampTimeout(90)).toBe(45);
    const driving = `Hello, this is JARVIS. Briefly: ${spokenClip(`${"The restaurant can seat three at eight ".repeat(8)}`, 120)}`;
    expect(driving).not.toContain("…");
    expect(driving.endsWith(".")).toBe(true);
    expect(driving.length).toBeLessThan(180);
  });

  it("gives a timed-out caller a callback brief and does not dial", async () => {
    const brief = callbackBrief("Can you book a table for Friday? My number is +15557654321.");
    expect(brief.startsWith("I'm calling you back, as promised.")).toBe(true);
    expect(brief).toContain("book a table");
    expect(brief).not.toContain("+1555");
    expect(brief).not.toContain("…");
    expect(needsDelegation(brief)).toBe(false);
    expect(outboundOpening(brief)).toContain("I'm calling you back, as promised.");
    const calls: string[] = [];
    const original = globalThis.fetch;
    globalThis.fetch = (async (input: RequestInfo | URL) => {
      calls.push(String(input));
      return new Response("should not dial", { status: 500 });
    }) as typeof fetch;
    try {
      const response = await route(
        new Request("https://jarvis.example/calls/call_restaurant1?refresh=0", { headers: { authorization: "Bearer secret-token" } }),
        callbackEnv(),
        { waitUntil() {}, passThroughOnException() {}, props: {} } as unknown as ExecutionContext,
      );
      expect(response.status).toBe(200);
      const body = (await response.json()) as { call: { brief: string; callback_needed: boolean; summary: string; to: string } };
      expect(body.call.callback_needed).toBe(true);
      expect(body.call.brief).toContain("I'm calling you back, as promised.");
      expect(body.call.brief).toContain("Friday");
      expect(body.call.brief).not.toContain("+1555");
      expect(body.call.summary).toContain("table");
      expect(body.call.to).toBe("+15557654321");
      expect(calls).toEqual([]);
    } finally {
      globalThis.fetch = original;
    }
  });
});

function callbackEnv(): Env {
  const call = {
    id: "call_restaurant1",
    contact_name: "Incoming call",
    to_number: "+15557654321",
    brief: "Screen this call",
    status: "completed",
    twilio_sid: null,
    conversation_id: null,
    transcript_json: "[]",
    summary: "They asked about a table.",
    error: null,
    created_at: "2026-10-21T12:00:00.000Z",
    updated_at: "2026-10-21T12:05:00.000Z",
  };
  const db = {
    prepare(sql: string) {
      let bound: unknown[] = [];
      const statement = {
        bind(...args: unknown[]) {
          bound = args;
          return statement;
        },
        async first() {
          if (sql.includes("call_questions")) {
            return String(bound[0]) === call.id ? { question: "Can you book a table for Friday?" } : null;
          }
          if (sql.includes("outbound_calls")) return String(bound[0]) === call.id ? call : null;
          return null;
        },
        async all() {
          return { results: [], success: true, meta: {} };
        },
        async run() {
          return { success: true, meta: { changes: 0 } };
        },
      };
      return statement;
    },
  };
  return {
    JARVIS_APP_TOKEN: "secret-token",
    TWILIO_ACCOUNT_SID: "ACexampleaccountsid000000000000",
    TWILIO_AUTH_TOKEN: "twilio-auth-token-example",
    TWILIO_FROM_NUMBER: "+15551230001",
    ELEVENLABS_API_KEY: "elevenlabs-key-example-value",
    ELEVENLABS_AGENT_ID: "agent_example",
    DB: db as unknown as D1Database,
  };
}
