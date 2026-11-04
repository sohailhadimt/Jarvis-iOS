import { describe, expect, it } from "vitest";
import { alertDecision, isHotLead, parseAlert, quietNow, readChoice, smsBody, spokenAlert } from "../src/proactive-alert";

describe("proactive alerts", () => {
  it("quiet hours 22:00-07:30", () => {
    expect(quietNow(22 * 60)).toBe(true);
    expect(quietNow(7 * 60 + 29)).toBe(true);
    expect(quietNow(7 * 60 + 30)).toBe(false);
    expect(quietNow(21 * 60 + 59)).toBe(false);
  });
  it("money bypasses quiet, cap and kill switch apply", () => {
    expect(alertDecision({ type: "booking", minutes: 23 * 60, countToday: 0, max: 3, off: false })).toBe("quiet");
    expect(alertDecision({ type: "money", minutes: 23 * 60, countToday: 0, max: 3, off: false })).toBe("call");
    expect(alertDecision({ type: "money", minutes: 600, countToday: 3, max: 3, off: false })).toBe("cap");
    expect(alertDecision({ type: "money", minutes: 600, countToday: 0, max: 3, off: true })).toBe("off");
  });
  it("parses and validates", () => {
    expect(parseAlert({ type: "nope", summary: "x" })).toMatch(/type/);
    expect(parseAlert({ type: "booking" })).toMatch(/summary/);
    const a = parseAlert({ type: "booking", summary: "Client wants to sign", value: 17000, meet_link: "https://meet.google.com/abc" });
    expect(typeof a).toBe("object");
    if (typeof a === "object") {
      expect(a.dedupe_key).toBe("booking:client wants to sign");
      expect(spokenAlert(a)).toContain("Value: 17000.");
      expect(smsBody(a, "1")).toContain("https://meet.google.com/abc");
    }
  });
  it("reads keypad and voice", () => {
    expect(readChoice({ Digits: "1" })).toBe("1");
    expect(readChoice({ SpeechResult: "Yes tell them I'm on my way" })).toBe("2");
    expect(readChoice({ SpeechResult: "text me the link" })).toBe("1");
  });
  it("spots hot leads", () => {
    expect(isHotLead("wants to sign tonight")).toBe(true);
    expect(isHotLead("just browsing")).toBe(false);
  });
});
