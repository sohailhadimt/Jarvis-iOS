import { describe, expect, it } from "vitest";
import {
  DAILY_CHALLENGES,
  composeReply,
  dailyChallenge,
  handleHq,
  levelProgress,
  looksExternal,
  perksForLevel,
  recordHqEvent,
  utcDayNumber,
} from "../src/hq";
import { route } from "../src/routes";
import type { Env } from "../src/types";

function ctx(): ExecutionContext {
  return {
    waitUntil(promise: Promise<unknown>) {
      promise.catch(() => undefined);
    },
    passThroughOnException() {
      return undefined;
    },
    props: {},
  } as ExecutionContext;
}

function memoryEnv(): Env {
  const events: Array<Record<string, unknown>> = [];
  let state: Record<string, unknown> | null = null;
  const db = {
    prepare(sql: string) {
      let params: unknown[] = [];
      const statement = {
        bind(...bound: unknown[]) {
          params = bound;
          return statement;
        },
        async all() {
          if (sql.includes("created_at >=")) {
            const start = String(params[0]);
            return {
              results: events
                .filter((event) => String(event.created_at) >= start)
                .map((event) => ({ kind: event.kind, created_at: event.created_at })),
              success: true,
              meta: {},
            };
          }
          if (sql.includes("ORDER BY created_at DESC")) {
            const limit = Number(params[0] ?? 30);
            const sorted = [...events].sort((a, b) => String(b.created_at).localeCompare(String(a.created_at)));
            return { results: sorted.slice(0, limit), success: true, meta: {} };
          }
          return { results: [], success: true, meta: {} };
        },
        async first() {
          if (sql.includes("SUM(xp)")) {
            return { xp: events.reduce((sum, event) => sum + Number(event.xp), 0) };
          }
          if (sql.includes("FROM hq_events") && sql.includes("kind = ?")) {
            return events.find((event) => event.kind === params[0] && event.source === params[1]) ?? null;
          }
          if (sql.includes("FROM hq_state")) return state;
          return null;
        },
        async run() {
          if (sql.includes("INSERT INTO hq_events")) {
            events.push({
              id: params[0],
              kind: params[1],
              source: params[2],
              summary: params[3],
              xp: params[4],
              bot: params[5],
              created_at: params[6],
            });
          } else if (sql.includes("INSERT INTO hq_state")) {
            state = {
              player_name: params[0],
              active_look_json: params[1],
              looks_json: params[2],
              furniture_json: params[3],
              updated_at: params[4],
            };
          }
          return { success: true, meta: { changes: 1 } };
        },
      };
      return statement;
    },
  };
  return { JARVIS_APP_TOKEN: "secret-token", DB: db as unknown as D1Database };
}

function throwingEnv(): Env {
  const db = {
    prepare() {
      const statement = {
        bind() {
          return statement;
        },
        async all() {
          throw new Error("no such table: hq_events");
        },
        async first() {
          throw new Error("no such table: hq_events");
        },
        async run() {
          throw new Error("no such table: hq_events");
        },
      };
      return statement;
    },
  };
  return { JARVIS_APP_TOKEN: "secret-token", DB: db as unknown as D1Database };
}

function authed(path: string, init: RequestInit = {}): Request {
  const headers = new Headers(init.headers);
  headers.set("authorization", "Bearer secret-token");
  return new Request(`https://jarvis.test${path}`, { ...init, headers });
}

const freeLook = {
  name: "HQ",
  top: "oxford",
  bottoms: "trousers",
  shoes: "oxfords",
  jacket: "blazer",
  accessory: "pin",
  top_color: "white",
  bottoms_color: "navy",
  shoes_color: "black",
  jacket_color: "navy",
};

describe("HQ levels and daily work", () => {
  it("spends an increasing amount of XP per level and stops at 50", () => {
    expect(levelProgress(0)).toEqual({ level: 1, xp_into_level: 0, xp_to_next: 800 });
    expect(levelProgress(800)).toEqual({ level: 2, xp_into_level: 0, xp_to_next: 1600 });
    expect(levelProgress(2400)).toEqual({ level: 3, xp_into_level: 0, xp_to_next: 2400 });
    expect(levelProgress(-20).level).toBe(1);
    expect(levelProgress(5_000_000).level).toBe(50);
  });

  it("unlocks the outfit pack, corner office, and rooftop from level", () => {
    expect(perksForLevel(2)).toEqual([]);
    expect(perksForLevel(3)).toEqual(["outfit_pack"]);
    expect(perksForLevel(5)).toEqual(["outfit_pack", "corner_office"]);
    expect(perksForLevel(8)).toEqual(["outfit_pack", "corner_office", "rooftop"]);
  });

  it("counts only today's matching events toward the daily challenge", () => {
    const now = new Date("2026-10-28T15:00:00.000Z");
    const spec = DAILY_CHALLENGES[utcDayNumber(now) % DAILY_CHALLENGES.length];
    const missed = dailyChallenge([{ kind: spec.kind, created_at: "2026-10-27T15:00:00.000Z" }], now);
    expect(missed.progress).toBe(0);
    expect(missed.done).toBe(false);
    const hit = dailyChallenge(
      [
        { kind: spec.kind, created_at: "2026-10-28T01:00:00.000Z" },
        { kind: "approval_approved", created_at: "2026-10-28T02:00:00.000Z" },
      ],
      now,
    );
    expect(hit.title).toBe(spec.title);
    expect(hit.done).toBe(true);
  });

  it("lets a finished task count when the challenge is to finish a task", () => {
    let now = new Date(Date.UTC(2026, 9, 28));
    for (let i = 0; i < 6; i += 1) {
      const candidate = new Date(Date.UTC(2026, 9, 28 + i));
      if (DAILY_CHALLENGES[utcDayNumber(candidate) % 3].kind === "task_completed") {
        now = candidate;
        break;
      }
    }
    const day = now.toISOString().slice(0, 10);
    const daily = dailyChallenge([{ kind: "task_done", created_at: `${day}T03:00:00.000Z` }], now);
    expect(daily.kind).toBe("task_completed");
    expect(daily.done).toBe(true);
  });
});

describe("HQ talk stays inside the building", () => {
  it("treats sending and publishing as approval work, and drafting as a draft", () => {
    expect(looksExternal("Draft a headline for the homepage")).toBe(false);
    expect(looksExternal("Please publish the homepage tonight")).toBe(true);
    expect(looksExternal("Email them the deck")).toBe(true);
    const parked = composeReply("U.L.T.R.O.N.", "Publish the deck", "I sent the email.", true);
    expect(parked.status).toBe("needs_approval");
    expect(parked.text).toContain("Nothing was sent");
    expect(parked.text).not.toMatch(/\bI sent\b/);
    const draft = composeReply("F.R.I.D.A.Y.", "Draft a headline", "Try: Security, clearly.", false);
    expect(draft.status).toBe("draft");
    expect(draft.text).toBe("Try: Security, clearly.");
  });

  it("requires the JARVIS bearer token", async () => {
    const response = await route(new Request("https://jarvis.test/hq/progress"), memoryEnv(), ctx());
    expect(response.status).toBe(401);
  });

  it("parks an external request on the approval flow and does not take it", async () => {
    const env = memoryEnv();
    const response = await route(
      authed("/hq/talk", {
        method: "POST",
        body: JSON.stringify({ bot: "ultron", text: "Publish this pitch to the client." }),
      }),
      env,
      ctx(),
    );
    expect(response.status).toBe(200);
    const body = (await response.json()) as {
      status: string;
      external_action_taken: boolean;
      reply: string;
      stored: boolean;
    };
    expect(body.status).toBe("needs_approval");
    expect(body.external_action_taken).toBe(false);
    expect(body.stored).toBe(true);
    expect(body.reply).toContain("Nothing was sent");
  });
});

describe("HQ event log", () => {
  it("ignores a client-supplied XP value and will not award the same source twice", async () => {
    const env = memoryEnv();
    const first = await route(
      authed("/hq/events", {
        method: "POST",
        body: JSON.stringify({
          kind: "task_completed",
          source: "task_abc",
          summary: "Homepage outline done. Call +44 7700 900123 if needed.",
          xp: 99999,
        }),
      }),
      env,
      ctx(),
    );
    expect(first.status).toBe(201);
    const created = (await first.json()) as { awarded: boolean; xp: number; event: { summary: string; xp: number } };
    expect(created.awarded).toBe(true);
    expect(created.xp).toBe(120);
    expect(created.event.xp).toBe(120);
    expect(created.event.summary).not.toContain("7700");
    expect(created.event.summary).toContain("[number]");

    const second = await route(
      authed("/hq/events", {
        method: "POST",
        body: JSON.stringify({ kind: "task_completed", source: "task_abc", summary: "again", xp: 99999 }),
      }),
      env,
      ctx(),
    );
    expect(second.status).toBe(200);
    const replay = (await second.json()) as { awarded: boolean };
    expect(replay.awarded).toBe(false);

    const progress = await route(authed("/hq/progress"), env, ctx());
    const body = (await progress.json()) as { xp: number; level: number; external_actions: boolean };
    expect(body.xp).toBe(120);
    expect(body.level).toBe(1);
    expect(body.external_actions).toBe(false);
  });

  it("rejects a made-up kind and a locked outfit", async () => {
    const env = memoryEnv();
    const bad = await route(
      authed("/hq/events", {
        method: "POST",
        body: JSON.stringify({ kind: "tap", source: "button", summary: "tapped" }),
      }),
      env,
      ctx(),
    );
    expect(bad.status).toBe(400);

    const locked = await route(
      authed("/hq/state", {
        method: "POST",
        body: JSON.stringify({
          player_name: "Sohail",
          active_look: { ...freeLook, jacket: "overcoat" },
          looks: [],
          furniture: [],
        }),
      }),
      env,
      ctx(),
    );
    expect(locked.status).toBe(403);

    const saved = await route(
      authed("/hq/state", {
        method: "POST",
        body: JSON.stringify({
          player_name: "Sohail",
          active_look: freeLook,
          looks: [{ ...freeLook, name: "Pitch day" }],
          furniture: [{ slot: "lamp", item: "lamp", color: "gold" }],
        }),
      }),
      env,
      ctx(),
    );
    expect(saved.status).toBe(200);
  });

  it("swallows a missing event table so JARVIS task completion still finishes", async () => {
    const result = await recordHqEvent(throwingEnv(), {
      kind: "task_completed",
      source: "task_missing",
      summary: "Done",
    });
    expect(result).toBeNull();
  });

  it("serves talk through the router for a draft", async () => {
    const response = await handleHq(
      authed("/hq/talk", {
        method: "POST",
        body: JSON.stringify({ bot: "friday", text: "Draft a headline for the homepage." }),
      }),
      memoryEnv(),
      "/hq/talk",
      ["hq", "talk"],
    );
    expect(response).not.toBeNull();
    const body = (await response!.json()) as { status: string; bot: string; external_action_taken: boolean };
    expect(body.bot).toBe("friday");
    expect(body.status).toBe("draft");
    expect(body.external_action_taken).toBe(false);
  });
});
