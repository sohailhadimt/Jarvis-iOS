import { describe, expect, it } from "vitest";
import { awayFirstMessage, callStage, decisionOf, needsDelegation, ownerReach, parseAway, wittyFallback } from "../src/call-desk";

describe("call desk", () => {
  it("maps call statuses onto the home-screen stages", () => {
    expect(callStage("ringing")).toBe("dialing");
    expect(callStage("in_progress")).toBe("live");
    expect(callStage("screening")).toBe("live");
    expect(callStage("completed")).toBe("ended");
    expect(callStage("failed")).toBe("ended");
  });

  it("turns a booking into a decision and keeps a confirmation from looping", () => {
    expect(needsDelegation("Book a table for three tonight")).toBe(true);
    expect(needsDelegation("CONFIRM Take the eight")).toBe(false);
    expect(needsDelegation("Say the meeting moved")).toBe(false);
  });

  it("writes a short British question and never a link", () => {
    const line = wittyFallback("Seven is fully booked, but they can seat three at eight. https://example.test/menu");
    expect(line.toLowerCase()).toContain("sir");
    expect(line.endsWith("?")).toBe(true);
    expect(line).not.toContain("http");
  });

  it("reads an away order and a clear", () => {
    const set = parseAway("JARVIS, answer my calls and say I'll call back later for the next two hours.");
    expect(set).toEqual({ kind: "set", instruction: "I'll call back later", hours: 2 });
    expect(parseAway("JARVIS, answer my calls")).toEqual({ kind: "set", instruction: "He'll ring you back", hours: 8 });
    expect(parseAway("stop answering my calls")).toEqual({ kind: "clear" });
    expect(parseAway("what's the weather")).toBeNull();
    expect(awayFirstMessage("I'll call back later")).toContain("may be handled by AI");
    expect(awayFirstMessage("I'll call back later")).toContain("I'll call back later");
  });

  it("texts when he is busy or quiet, and keeps the daily cap", () => {
    expect(ownerReach({ quiet: true, busy: false, driving: true, countToday: 0, max: 3, urgentOnly: false, urgent: true })).toBe("text");
    expect(ownerReach({ quiet: false, busy: true, driving: false, countToday: 0, max: 3, urgentOnly: false, urgent: false })).toBe("text");
    expect(ownerReach({ quiet: false, busy: false, driving: true, countToday: 1, max: 3, urgentOnly: false, urgent: false })).toBe("call");
    expect(ownerReach({ quiet: false, busy: false, driving: true, countToday: 3, max: 3, urgentOnly: false, urgent: true })).toBe("text");
    expect(ownerReach({ quiet: false, busy: false, driving: false, countToday: 3, max: 3, urgentOnly: false, urgent: true })).toBe("push");
    expect(ownerReach({ quiet: false, busy: false, driving: false, countToday: 0, max: 3, urgentOnly: false, urgent: false })).toBe("call");
  });

  it("treats a spoken yes as confirmation and a no as leaving it", () => {
    expect(decisionOf("yes").confirm).toBe(true);
    expect(decisionOf("Leave it").confirm).toBe(false);
    expect(decisionOf("Take the eight").confirm).toBe(true);
  });
});
