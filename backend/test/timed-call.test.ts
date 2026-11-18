import { describe, expect, it } from "vitest";
import { bookedCallLine, normaliseClockWords, parseReminder, parseTimedCall, WAKE_TASK } from "../src/sms-extras";

const at = (iso: string) => new Date(iso);
const london = (d: Date) => new Intl.DateTimeFormat("en-GB", { timeZone: "Europe/London", hour: "2-digit", minute: "2-digit", hour12: false }).format(d);

describe("timed calls to Sir", () => {
  const now = at("2026-11-18T10:14:52Z");

  it("books his exact wake-up text for 12:30, not the later 4:30 or the 'in 2 and a half hours'", () => {
    const call = parseTimedCall(
      "Jarvis call me to wake me up at half 12pm so in about 2 and a half hours okay make sure you do, I've got work at 4:30pm in hernbay",
      now,
    );
    expect(call).not.toBeNull();
    expect(london(call!.dueAt)).toBe("12:30");
    expect(call!.byCall).toBe(true);
    expect(call!.task).toBe(WAKE_TASK);
    expect(bookedCallLine(call!.dueAt, now)).toBe("Booked, Sir, I'll ring you at 12:30.");
  });

  it("understands half 12, quarter to, o'clock and relative times", () => {
    expect(london(parseTimedCall("ring me at half 12", now)!.dueAt)).toBe("12:30");
    expect(london(parseTimedCall("call me at quarter to 8 tonight", now)!.dueAt)).toBe("19:45");
    expect(london(parseTimedCall("wake me up at 7 o'clock tomorrow", now)!.dueAt)).toBe("07:00");
    expect(london(parseTimedCall("wake me up at 7am tomorrow", now)!.dueAt)).toBe("07:00");
    expect(london(parseTimedCall("call me in 2 hours", now)!.dueAt)).toBe("12:14");
    expect(london(parseTimedCall("call me in 2 and a half hours", now)!.dueAt)).toBe("12:44");
    expect(london(parseTimedCall("give me a ring in an hour and a half about the van", now)!.dueAt)).toBe("11:44");
    expect(parseTimedCall("give me a ring in an hour and a half about the van", now)!.task).toBe("about the van");
    expect(normaliseClockWords("at half past 3pm")).toBe("at 3:30pm");
  });

  it("leaves other people and plain chat alone", () => {
    expect(parseTimedCall("call mum at 6", now)).toBeNull();
    expect(parseTimedCall("call me", now)).toBeNull();
    expect(parseTimedCall("remind me at 6 to stretch, call me", now)).toBeNull();
    const r = parseReminder("remind me at half 6 to stretch", now);
    expect(r && r !== "unclear" && london(r.dueAt)).toBe("18:30");
  });
});
