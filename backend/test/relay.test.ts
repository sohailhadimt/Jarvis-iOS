import { describe, expect, it } from "vitest";
import { questionFromTranscript } from "../src/relay";
import { clampTimeout, inQuietHours, mayCall, ownerSummaryLine } from "../src/owner-alert";
import { approvedScreening, outboundOpening, screeningScript } from "../src/calls";

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
  });
});
