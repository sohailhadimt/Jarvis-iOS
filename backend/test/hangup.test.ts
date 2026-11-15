import { afterEach, describe, expect, it, vi } from "vitest";
import { callIsLive, isOwnerCaller } from "../src/hangup";
import type { Env } from "../src/types";

const env = { TWILIO_ACCOUNT_SID: "ACx", TWILIO_AUTH_TOKEN: "t" } as unknown as Env;

afterEach(() => vi.unstubAllGlobals());

describe("owner line and dead calls", () => {
  it("treats the owner's own number as the owner, in any format", () => {
    expect(isOwnerCaller("+15557654321", "+1 555 765 4321")).toBe(true);
    expect(isOwnerCaller("+15550000000", "+15557654321")).toBe(false);
    expect(isOwnerCaller(null, "+15557654321")).toBe(false);
  });

  it("reports a completed Twilio call as not live, so take over never rings an empty room", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response(JSON.stringify({ sid: "CA1", status: "completed" }), { status: 200 })));
    expect(await callIsLive(env, "CA1")).toBe(false);
    vi.stubGlobal("fetch", vi.fn(async () => new Response(JSON.stringify({ sid: "CA1", status: "in-progress" }), { status: 200 })));
    expect(await callIsLive(env, "CA1")).toBe(true);
  });
});
