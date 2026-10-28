import { describe, expect, it } from "vitest";
import { authorize, normalizeAppToken, tokensMatch } from "../src/auth";
import { route } from "../src/routes";
import type { Env } from "../src/types";

function request(path: string, init: RequestInit = {}): Request {
  return new Request(`https://jarvis.test${path}`, init);
}

function mockEnv(token?: string): Env {
  return {
    JARVIS_APP_TOKEN: token,
    DB: {
      prepare(sql: string) {
        const statement = {
          bind() {
            return statement;
          },
          async all() {
            return { results: [], success: true, meta: {} };
          },
          async first() {
            if (sql.includes("SELECT 1")) return { ok: 1 };
            return null;
          },
          async run() {
            return { success: true, meta: { changes: 1 } };
          },
        };
        return statement;
      },
    } as unknown as D1Database,
  };
}

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

describe("API auth", () => {
  it("compares tokens without treating a different length as a match", () => {
    expect(tokensMatch("secret-token", "secret-token")).toBe(true);
    expect(tokensMatch("secret-token", "secret-tokex")).toBe(false);
    expect(tokensMatch("short", "secret-token")).toBe(false);
  });

  it("rejects a missing, wrong, or non-bearer token", () => {
    const missing = authorize(request("/tasks"), "secret-token");
    const wrong = authorize(request("/tasks", { headers: { authorization: "Bearer nope" } }), "secret-token");
    const basic = authorize(request("/tasks", { headers: { authorization: "Basic secret-token" } }), "secret-token");
    expect(missing.ok).toBe(false);
    expect(wrong.ok).toBe(false);
    expect(basic.ok).toBe(false);
    if (missing.ok || wrong.ok || basic.ok) return;
    expect(missing.response.status).toBe(401);
    expect(wrong.response.status).toBe(401);
    expect(basic.response.status).toBe(401);
  });

  it("accepts the exact bearer token", () => {
    const result = authorize(request("/tasks", { headers: { authorization: "Bearer secret-token" } }), "secret-token");
    expect(result.ok).toBe(true);
  });

  it("accepts the same token when the secret or the header has extra bearer text or space", () => {
    expect(normalizeAppToken("  Bearer secret-token\n")).toBe("secret-token");
    const newline = authorize(request("/tasks", { headers: { authorization: "Bearer secret-token" } }), "secret-token\n");
    const doubled = authorize(
      request("/tasks", { headers: { authorization: "Bearer Bearer secret-token" } }),
      "secret-token",
    );
    const quoted = authorize(request("/tasks", { headers: { authorization: "Bearer secret-token" } }), '"secret-token"');
    const legacy = authorize(request("/tasks", { headers: { "x-app-token": "secret-token" } }), "secret-token");
    expect(newline.ok).toBe(true);
    expect(doubled.ok).toBe(true);
    expect(quoted.ok).toBe(true);
    expect(legacy.ok).toBe(true);
  });

  it("reports a missing server token as not configured", () => {
    const result = authorize(request("/tasks", { headers: { authorization: "Bearer secret-token" } }), undefined);
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.response.status).toBe(503);
  });

  it("serves health without a token and protects tasks", async () => {
    const env = mockEnv("secret-token");
    const health = await route(request("/health"), env, ctx());
    expect(health.status).toBe(200);
    const healthBody = (await health.json()) as { ok: boolean; external_actions: boolean };
    expect(healthBody.ok).toBe(true);
    expect(healthBody.external_actions).toBe(false);

    const open = await route(request("/tasks"), env, ctx());
    expect(open.status).toBe(401);

    const listed = await route(request("/tasks", { headers: { authorization: "Bearer secret-token" } }), env, ctx());
    expect(listed.status).toBe(200);
    const body = (await listed.json()) as { tasks: unknown[] };
    expect(body.tasks).toEqual([]);
  });

  it("rejects a task with no goal or a bad schedule before doing work", async () => {
    const env = mockEnv("secret-token");
    const headers = { authorization: "Bearer secret-token", "content-type": "application/json" };
    const noGoal = await route(
      request("/tasks", { method: "POST", headers, body: JSON.stringify({}) }),
      env,
      ctx(),
    );
    expect(noGoal.status).toBe(400);
    const badCron = await route(
      request("/tasks", { method: "POST", headers, body: JSON.stringify({ goal: "Find prospects", schedule: "tomorrow" }) }),
      env,
      ctx(),
    );
    expect(badCron.status).toBe(400);
  });

  it("creates a task when the token and goal are valid", async () => {
    const env = mockEnv("secret-token");
    const response = await route(
      request("/tasks", {
        method: "POST",
        headers: { authorization: "Bearer secret-token", "content-type": "application/json" },
        body: JSON.stringify({ goal: "Find five security companies in Kent with weak websites." }),
      }),
      env,
      ctx(),
    );
    expect(response.status).toBe(201);
    const body = (await response.json()) as { task: { goal: string; status: string } };
    expect(body.task.status).toBe("planning");
    expect(body.task.goal).toMatch(/Kent/);
  });

  it("returns 503 on protected routes when the Worker secret is unset", async () => {
    const response = await route(request("/briefing"), mockEnv(undefined), ctx());
    expect(response.status).toBe(503);
  });
});
