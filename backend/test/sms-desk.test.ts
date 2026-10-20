import { describe, expect, it } from "vitest";
import { bookingAllowed, extractQuote } from "../src/hunt";
import {
  asksCapabilities,
  birthdayNudge,
  capabilityBubbles,
  learnFacts,
  menuChoice,
  pairingDigits,
  parsePhones,
  paymentAsk,
  proposeSlots,
  scheduleEmail,
  screenStranger,
  smsBubbles,
  wantsHunt,
  wantsSchedule,
  welcomeBubbles,
} from "../src/sms-desk";

describe("text desk", () => {
  it("learns a birthday, a like, and a way of doing things", () => {
    const facts = learnFacts("My mum's birthday is 12 March. I like dark roast coffee. I want you to text me after ten.");
    expect(facts.map((fact) => fact.kind)).toEqual(["birthday", "like", "preference"]);
    expect(facts[0]).toMatchObject({ subject: "mum", whenMd: "03-12" });
    expect(facts[1]?.detail.toLowerCase()).toContain("dark roast");
    expect(facts[2]?.detail.toLowerCase()).toContain("text me after ten");
  });

  it("nudges a birthday inside the week and waits through quiet hours", () => {
    const now = new Date("2026-03-09T12:00:00Z");
    const nudge = birthdayNudge({ subject: "mum", whenMd: "03-13", now, quiet: false, nudgedFor: null });
    expect(nudge?.text).toBe("Your mum's birthday is Friday, Sir. Shall I find something?");
    expect(nudge?.occurrence).toBe("2026-03-13");
    expect(birthdayNudge({ subject: "mum", whenMd: "03-13", now, quiet: true, nudgedFor: null })).toBeNull();
    expect(birthdayNudge({ subject: "mum", whenMd: "03-13", now, quiet: false, nudgedFor: "2026-03-13" })).toBeNull();
    expect(birthdayNudge({ subject: "mum", whenMd: "03-17", now, quiet: false, nudgedFor: null })).toBeNull();
    expect(birthdayNudge({ subject: "mum", whenMd: "03-09", now, quiet: false, nudgedFor: null })?.text).toContain("today");
  });

  it("screens a stranger without chatting", () => {
    expect(screenStranger()).toBe("Hello, this is JARVIS, Master Hadi's assistant. I'll pass that to him.");
  });

  it("pairs only a bare 6-digit code and welcomes in separate texts", () => {
    expect(pairingDigits("482 913")).toBe("482913");
    expect(pairingDigits("the code is 482913")).toBeNull();
    const welcome = welcomeBubbles("+440000000000");
    expect(welcome[0]).toBe("Connected, Sir. I'm JARVIS.");
    expect(welcome[1]).toBe("Text or call +440000000000 whenever you need me.");
    expect(welcome[2]).toBe("1. Make a call for me\n2. Book an appointment or service\n3. Help with a subscription or bill");
    expect(welcome[3]).toBe("Reply 1, 2 or 3, or just tell me what you need.");
    expect(menuChoice("2")).toBe("2");
    expect(menuChoice("book a table")).toBeNull();
  });

  it("answers what it can do in short bubbles", () => {
    expect(asksCapabilities("What can you do?")).toBe(true);
    const bubbles = capabilityBubbles();
    expect(bubbles.join(" ")).toContain("book me a dentist this week");
    expect(bubbles.join(" ")).toContain("find a plumber who can come today");
    expect(bubbles.at(-1)).toBe("I'll text or call you when something needs you.");
    expect(smsBubbles("Of course, Sir. I can do that. Shall I go ahead?")).toEqual([
      "Of course, Sir.",
      "I can do that.",
      "Shall I go ahead?",
    ]);
  });

  it("keeps at most five callable numbers and drops emergency numbers", () => {
    const text = [
      "020 7946 0001",
      "020 7946 0002",
      "020 7946 0003",
      "020 7946 0004",
      "020 7946 0005",
      "020 7946 0006",
      "999",
      "112",
    ].join(" ");
    const phones = parsePhones(text);
    expect(phones).toHaveLength(5);
    expect(phones[0]).toBe("+442079460001");
    expect(phones).not.toContain("+44999");
    expect(phones).not.toContain("999");
  });

  it("treats a plumber search as a hunt and a meeting as a draft", () => {
    expect(wantsHunt("find me a plumber")).toBe(true);
    expect(wantsHunt("hello there")).toBe(false);
    expect(wantsSchedule("draft an email and propose times")).toBe(true);
    expect(paymentAsk("find me a plumber")).toBe(false);
    expect(paymentAsk("pay the invoice and mint a card")).toBe(true);
  });

  it("skips a busy morning and offers the next London slot", () => {
    const now = new Date("2026-03-09T08:00:00Z");
    const slots = proposeSlots(now, [{ startsAt: "2026-03-09T09:00:00.000Z", endsAt: "2026-03-09T09:30:00.000Z" }], 1);
    expect(slots).toHaveLength(1);
    expect(slots[0]?.label).toContain("11:00");
    expect(slots[0]?.label).not.toContain("09:00");
  });

  it("drafts the email and does not send it", () => {
    const email = scheduleEmail("Talk about the kitchen", [{ label: "Monday 16 March, 09:00" }]);
    expect(email.subject.length).toBeGreaterThan(0);
    expect(email.body).toContain("Monday 16 March, 09:00");
    expect(email.body.toLowerCase()).not.toContain("has been sent");
  });

  it("reads a quote and refuses a payment booking", () => {
    const quote = extractQuote(
      "Do not take a booking and do not take a card. The call-out fee is £40 and the job is £120. We can come Tuesday at 2pm.",
    );
    expect(quote.fees.replace(/\s/g, "")).toContain("40");
    expect(quote.price.replace(/\s/g, "")).toContain("120");
    expect(quote.availability.toLowerCase()).toContain("tuesday");
    expect(quote.payment).toBe(false);
    expect(bookingAllowed("Book Acme at £80. A confirmation call only. Nothing is paid.")).toBe(true);
    expect(bookingAllowed("Payment was asked for Acme. Nothing will be paid or booked.")).toBe(false);
    expect(bookingAllowed(extractQuote("Please pay by card now, the price is £50.").summary)).toBe(false);
  });
});
