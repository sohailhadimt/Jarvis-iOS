import { describe, expect, it } from "vitest";
import { route } from "../src/routes";
import type { Env } from "../src/types";
import { sanitizeVoiceDebug } from "../src/voice-debug";

describe("voice debug", () => {
  it("keeps a short kind and redacts a phone number", () => {
    const events = sanitizeVoiceDebug(
      {
        events: [
          { kind: "barge", detail: "stopped playback" },
          { kind: "end-of-turn", detail: "call +44 7700 900123 now" },
          { kind: "", detail: "dropped" },
          { kind: "speech began!", detail: "aec on" },
        ],
      },
      "2026-10-21T12:00:00.000Z",
    );
    expect(events).toEqual([
      { at: "2026-10-21T12:00:00.000Z", kind: "barge", detail: "stopped playback" },
      { at: "2026-10-21T12:00:00.000Z", kind: "end-of-turn", detail: "call [number] now" },
      { at: "2026-10-21T12:00:00.000Z", kind: "speechbegan", detail: "aec on" },
    ]);
  });

  it("keeps a stored timestamp", () => {
    const events = sanitizeVoiceDebug(
      {
        events: [{ kind: "speech-began", detail: "aec on", at: "2026-10-21T11:00:00.000Z" }],
      },
      "2026-10-21T12:00:00.000Z",
    );
    expect(events[0]?.at).toBe("2026-10-21T11:00:00.000Z");
  });

  it("stores a posted session and returns it from GET", async () => {
    const state: Record<string, string> = {};
    const env: Env = {
      JARVIS_APP_TOKEN: "secret-token",
      DB: {
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
              const value = state[String(bound[0] ?? "")];
              return value == null ? null : { value };
            },
            async run() {
              if (sql.includes("runtime_state")) state[String(bound[0] ?? "")] = String(bound[1] ?? "");
              return { success: true, meta: { changes: 1 } };
            },
          };
          return statement;
        },
      } as unknown as D1Database,
    };
    const ctx = { waitUntil() {}, passThroughOnException() {}, props: {} } as unknown as ExecutionContext;
    const posted = await route(
      new Request("https://jarvis.test/debug/voice", {
        method: "POST",
        headers: { authorization: "Bearer secret-token", "content-type": "application/json" },
        body: JSON.stringify({
          events: [
            { kind: "live-open", detail: "text session", at: "2026-10-21T16:00:00.000Z" },
            { kind: "input-transcript", detail: "ring +447700900123", at: "2026-10-21T16:00:01.000Z" },
          ],
        }),
      }),
      env,
      ctx,
    );
    expect(posted.status).toBe(200);
    const read = await route(
      new Request("https://jarvis.test/debug/voice", {
        method: "GET",
        headers: { authorization: "Bearer secret-token" },
      }),
      env,
      ctx,
    );
    const body = (await read.json()) as { revision: string; events: { kind: string; detail: string }[] };
    expect(body.revision).toBe("voice-log-2");
    expect(body.events.map((event) => event.kind)).toEqual(["live-open", "input-transcript"]);
    expect(body.events[1]?.detail).toBe("ring [number]");
    expect(JSON.stringify(body)).not.toContain("7700");
  });
});
