import { beforeEach, describe, expect, it, vi } from "vitest";

const runTick = vi.fn<(env: unknown, reason: string) => Promise<boolean>>();
const runPersonaTick = vi.fn<(env: unknown) => Promise<boolean>>();

vi.mock("../src/execute", () => ({ runTick: (env: unknown, reason: string) => runTick(env, reason) }));
vi.mock("../src/personas", () => ({ runPersonaTick: (env: unknown) => runPersonaTick(env) }));

const { laneCount, lanesEnabled, parseLaneHeaders, runLane, startLanes } = await import("../src/lanes");

function selfBinding() {
  const calls: { lane: string | null; hop: string | null; auth: string | null }[] = [];
  const fetch = vi.fn(async (_url: string, init?: RequestInit) => {
    const headers = new Headers(init?.headers);
    calls.push({ lane: headers.get("x-jarvis-lane"), hop: headers.get("x-jarvis-hop"), auth: headers.get("Authorization") });
    return new Response(null, { status: 202 });
  });
  return { binding: { fetch } as unknown as Fetcher, calls, fetch };
}

describe("agent lanes", () => {
  beforeEach(() => {
    runTick.mockReset();
    runPersonaTick.mockReset();
    runPersonaTick.mockResolvedValue(false);
  });

  it("needs the SELF binding and the app token", () => {
    const { binding } = selfBinding();
    expect(lanesEnabled({ DB: {} as D1Database } as never)).toBe(false);
    expect(lanesEnabled({ DB: {} as D1Database, SELF: binding } as never)).toBe(false);
    expect(lanesEnabled({ DB: {} as D1Database, SELF: binding, JARVIS_APP_TOKEN: "tok" } as never)).toBe(true);
  });

  it("clamps the lane count", () => {
    expect(laneCount({ AGENT_LANES: "" } as never)).toBe(3);
    expect(laneCount({ AGENT_LANES: "0" } as never)).toBe(3);
    expect(laneCount({ AGENT_LANES: "5" } as never)).toBe(5);
    expect(laneCount({ AGENT_LANES: "40" } as never)).toBe(6);
  });

  it("falls back to one tick when lanes are off", async () => {
    runTick.mockResolvedValue(true);
    await startLanes({ DB: {} } as never, "cron");
    expect(runTick).toHaveBeenCalledTimes(1);
  });

  it("opens every lane after a tick that did work", async () => {
    runTick.mockResolvedValue(true);
    const { binding, calls } = selfBinding();
    await startLanes({ DB: {}, SELF: binding, JARVIS_APP_TOKEN: "tok", AGENT_LANES: "3" } as never, "cron");
    expect(calls.map((c) => c.lane)).toEqual(["0", "1", "2"]);
    expect(calls.every((c) => c.hop === "1" && c.auth === "Bearer tok")).toBe(true);
  });

  it("keeps passing a lane on while it finds work, and stops when it does not", async () => {
    const { binding, calls } = selfBinding();
    const env = { DB: {}, SELF: binding, JARVIS_APP_TOKEN: "tok" } as never;
    runTick.mockResolvedValueOnce(true);
    await runLane(env, 1, 4);
    expect(calls).toEqual([{ lane: "1", hop: "5", auth: "Bearer tok" }]);
    runTick.mockResolvedValueOnce(false);
    await runLane(env, 1, 5);
    expect(calls).toHaveLength(1);
  });

  it("counts persona agent work as work", async () => {
    const { binding, calls } = selfBinding();
    runTick.mockResolvedValueOnce(false);
    runPersonaTick.mockResolvedValueOnce(true);
    await runLane({ DB: {}, SELF: binding, JARVIS_APP_TOKEN: "tok" } as never, 0, 1);
    expect(calls).toHaveLength(1);
  });

  it("stops at the hop cap so a lane cannot run forever", async () => {
    const { binding, fetch } = selfBinding();
    runTick.mockResolvedValue(true);
    await runLane({ DB: {}, SELF: binding, JARVIS_APP_TOKEN: "tok" } as never, 0, 25);
    expect(fetch).not.toHaveBeenCalled();
  });

  it("reads lane headers defensively", () => {
    const req = new Request("https://x/tick", { method: "POST", headers: { "x-jarvis-lane": "99", "x-jarvis-hop": "abc" } });
    expect(parseLaneHeaders(req)).toEqual({ lane: 5, hop: 1 });
  });
});
