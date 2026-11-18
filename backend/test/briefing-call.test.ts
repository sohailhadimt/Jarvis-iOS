import { describe, expect, it } from "vitest";
import { askTwiml, callDue, isDone, parseSettings, spokenBriefing } from "../src/briefing-call";

// 2026-11-16 is a Monday; London is GMT in November.
const monday0730 = new Date("2026-11-16T07:30:00Z");
const base = { enabled: true, time: "07:30", days: [1, 2, 3, 4, 5] };

describe("briefing call schedule", () => {
  it("rings only inside the window on a chosen day, once", () => {
    expect(callDue(base, monday0730, false)).toBe(true);
    expect(callDue(base, new Date("2026-11-16T07:38:00Z"), false)).toBe(true);
    expect(callDue(base, new Date("2026-11-16T07:40:00Z"), false)).toBe(false);
    expect(callDue(base, new Date("2026-11-16T07:25:00Z"), false)).toBe(false);
    expect(callDue(base, monday0730, true)).toBe(false);
    expect(callDue(base, new Date("2026-11-15T07:30:00Z"), false)).toBe(false); // Sunday
    expect(callDue({ ...base, enabled: false }, monday0730, false)).toBe(false);
  });
  it("follows London time in summer", () => {
    expect(callDue(base, new Date("2026-07-06T06:30:00Z"), false)).toBe(true); // 07:30 BST, Monday
  });
  it("validates settings", () => {
    expect(parseSettings({ enabled: true, time: "7:30", days: [1] })).toBe("time must be HH:MM (24 hour).");
    expect(parseSettings({ enabled: true, time: "07:30", days: [1, 1, 9, 3] })).toEqual({ enabled: true, time: "07:30", days: [1, 3] });
  });
});

describe("briefing call speech", () => {
  it("says only what is stored", () => {
    const text = spokenBriefing({ completed: 2, failed: 0, approvals: 1, drafts: 0, reminders: ["call the plumber"] }, monday0730);
    expect(text).toContain("Good morning, Sir");
    expect(text).toContain("2 tasks finished");
    expect(text).toContain("1 approval is waiting");
    expect(text).toContain("call the plumber");
    expect(spokenBriefing({ completed: 0, failed: 0, approvals: 0, drafts: 0, reminders: [] }, monday0730)).toContain("Nothing needs your attention.");
  });
  it("ends on a goodbye phrase and escapes TwiML", () => {
    expect(isDone("that's all thanks")).toBe(true);
    expect(isDone("what's on my calendar")).toBe(false);
    expect(askTwiml("https://w.example", 2, "A & B")).toContain("A &amp; B");
  });
});
