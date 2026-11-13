import { describe, expect, it } from "vitest";
import { BRAIN_PERSONA, GEORGE_VOICE_ID, brainSystem, guardUnplacedCall, runBrainTool } from "../src/brain";
import { route } from "../src/routes";
import type { Env } from "../src/types";

describe("shared brain", () => {
  it("uses one persona and George's voice", () => {
    expect(BRAIN_PERSONA).toContain("Master Hadi");
    expect(BRAIN_PERSONA).toContain("George");
    expect(BRAIN_PERSONA).toContain("Never call him Sohail");
    expect(brainSystem("sms")).toContain(BRAIN_PERSONA);
    expect(brainSystem("app")).toContain(BRAIN_PERSONA);
    expect(brainSystem("sms")).toContain("This reply is an SMS");
    expect(GEORGE_VOICE_ID).toBe("JBFqnCBsd6RMkjVDRZzb");
    expect(guardUnplacedCall("Calling 07700 900123 now, Sir.")).toBe("I have not placed a call, Sir. Nothing was dialled.");
  });

  it("does not dial or text from the shared tools", async () => {
    let fetched = false;
    const original = globalThis.fetch;
    globalThis.fetch = (async () => {
      fetched = true;
      return new Response("{}", { status: 500 });
    }) as typeof fetch;
    try {
      const call = await runBrainTool(memoryEnv().env, "place_outbound_call", JSON.stringify({ to: "+447700900123", brief: "hello" }), "sms");
      const text = await runBrainTool(memoryEnv().env, "send_sms", JSON.stringify({ to: "+447700900123", body: "hello" }), "app");
      expect(fetched).toBe(false);
      expect(JSON.stringify(call)).toContain("Nothing was dialled");
      expect(JSON.stringify(text)).toContain("Nothing was dialled");
      expect(JSON.stringify(call)).not.toContain("7700");
    } finally {
      globalThis.fetch = original;
    }
  });

  it("shows a phone-line sentence and a call line in the app history", async () => {
    const { env } = memoryEnv();
    const ctx = { waitUntil() {}, passThroughOnException() {}, props: {} } as unknown as ExecutionContext;
    const headers = { authorization: "Bearer secret-token", "content-type": "application/json" };
    const posted = await route(
      new Request("https://jarvis.test/brain/line", {
        method: "POST",
        headers,
        body: JSON.stringify({ source: "sms", role: "user", text: "The boiler quote was four hundred." }),
      }),
      env,
      ctx,
    );
    expect(posted.status).toBe(200);
    const persona = await route(new Request("https://jarvis.test/brain/persona", { headers }), env, ctx);
    const personaBody = (await persona.json()) as { persona: string; voice: string; voice_id: string; revision: string };
    expect(personaBody.revision).toBe("brain-1");
    expect(personaBody.voice).toBe("George");
    expect(personaBody.voice_id).toBe(GEORGE_VOICE_ID);
    expect(personaBody.persona).toContain("Master Hadi");
    const read = await route(new Request("https://jarvis.test/brain/history", { headers }), env, ctx);
    const body = (await read.json()) as { revision: string; turns: { source: string; body: string }[] };
    expect(body.revision).toBe("brain-1");
    expect(body.turns.some((turn) => turn.source === "sms" && turn.body === "The boiler quote was four hundred.")).toBe(true);
    expect(body.turns.some((turn) => turn.source === "call" && turn.body === "The boiler is leaking.")).toBe(true);
    expect(body.turns.some((turn) => turn.body.includes("[number]") && turn.body.includes("call me back"))).toBe(true);
    expect(JSON.stringify(body)).not.toContain("7700");
    expect(JSON.stringify(body)).not.toContain("447700900123");
  });
});

function memoryEnv(): { env: Env } {
  const turns: Record<string, unknown>[] = [];
  const reminders: Record<string, unknown>[] = [];
  const calls = [
    {
      id: "call_boiler",
      transcript_json: JSON.stringify([
        { role: "them", text: "The boiler is leaking." },
        { role: "them", text: "+447700900123" },
        { role: "them", text: "Please call me back on +447700900123." },
      ]),
    },
  ];
  const db = {
    prepare(sql: string) {
      let bound: unknown[] = [];
      const statement = {
        bind(...args: unknown[]) {
          bound = args;
          return statement;
        },
        async all() {
          if (sql.includes("FROM outbound_calls")) return { results: calls, success: true, meta: {} };
          if (sql.includes("FROM brain_reminders")) return { results: reminders, success: true, meta: {} };
          if (sql.includes("FROM brain_turns")) return { results: turns, success: true, meta: {} };
          return { results: [], success: true, meta: {} };
        },
        async first() {
          return null;
        },
        async run() {
          if (sql.includes("INSERT INTO brain_turns")) {
            turns.push({
              id: bound[0],
              source: bound[1],
              role: bound[2],
              body: bound[3],
              ref: bound[4],
              created_at: bound[5],
            });
          }
          if (sql.includes("INSERT INTO brain_reminders")) {
            reminders.push({ text: bound[1], status: "open" });
          }
          return { success: true, meta: { changes: 1 } };
        },
      };
      return statement;
    },
  };
  return { env: { JARVIS_APP_TOKEN: "secret-token", DB: db as unknown as D1Database } };
}
