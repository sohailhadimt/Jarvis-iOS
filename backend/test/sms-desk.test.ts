import { describe, expect, it } from "vitest";
import { twilioSignature } from "../src/calls";
import { bookingAllowed, extractQuote } from "../src/hunt";
import { route } from "../src/routes";
import {
  asksCapabilities,
  birthdayNudge,
  callChoice,
  callFollowUp,
  capabilityBubbles,
  handleInboundSms,
  learnFacts,
  menuChoice,
  noteSmsOutcome,
  outboundAsk,
  pairingDigits,
  parsePhones,
  paymentAsk,
  pendingRevision,
  proposeSlots,
  rememberSmsOutcome,
  scheduleEmail,
  screenStranger,
  smsBubbles,
  wantsHunt,
  wantsSchedule,
  welcomeBubbles,
} from "../src/sms-desk";
import { CHAT_FALLBACK } from "../src/llm";
import type { Env } from "../src/types";

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

  it("reads a call from the notes and offers a callback only after yes", async () => {
    expect(callFollowUp("What did he say")).toBe("detail");
    expect(callFollowUp("more")).toBe("detail");
    expect(callFollowUp("details")).toBe("detail");
    expect(callFollowUp("call him back")).toBe("callback");
    expect(callFollowUp("call back")).toBe("callback");
    expect(callFollowUp("yes")).toBeNull();
    expect(callChoice("you call")).toBe("dial");
    expect(callChoice("call him back")).toBe("dial");
    expect(callChoice("1")).toBe("dial");
    expect(callChoice("I'll call")).toBe("number");
    expect(callChoice("2")).toBe("number");
    expect(outboundAsk("Call 07700 900123 and ask him if he is free tomorrow")?.purpose).toBe("if he is free tomorrow");
    expect(outboundAsk("call him back")).toBeNull();

    const kv = new Map<string, string>();
    const env = deskEnv(kv);
    const calls: string[] = [];
    const texts: string[] = [];
    const original = globalThis.fetch;
    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      const method = init?.method ?? "GET";
      if (url.includes("/Calls.json") && method === "POST") {
        calls.push(String(init?.body ?? ""));
        return new Response(JSON.stringify({ sid: "CA1234567890abcdef1234567890abcd" }), { status: 201 });
      }
      if (url.includes("/Messages.json") && method === "POST") {
        texts.push(new URLSearchParams(String(init?.body ?? "")).get("Body") ?? "");
        return new Response(JSON.stringify({ sid: "SMnote", status: "queued" }), { status: 201 });
      }
      return new Response("{}", { status: 404 });
    }) as typeof fetch;
    try {
      await handleInboundSms(env, "+15557654321", "What did he say");
      const note = texts.join(" ");
      expect(note).not.toContain(CHAT_FALLBACK);
      expect(note).toContain("boiler");
      expect(note).toContain("+15550001111");
      expect(note).not.toContain("Good evening");
      expect(calls).toHaveLength(0);

      texts.length = 0;
      await handleInboundSms(env, "+15557654321", "call him back");
      expect(calls).toHaveLength(1);
      expect(new URLSearchParams(calls[0]).get("To")).toBe("+15550001111");
      expect(texts.join(" ")).toContain("calling Sohail back");
      expect(texts.join(" ").toLowerCase()).not.toContain("reply yes");

      texts.length = 0;
      const beforeNumber = calls.length;
      await handleInboundSms(env, "+15557654321", "I'll call");
      expect(calls).toHaveLength(beforeNumber);
      expect(texts.join(" ")).toContain("+15550001111");

      texts.length = 0;
      await handleInboundSms(env, "+15557654321", "Call 07700 900123 and ask him if he is free tomorrow");
      expect(texts.join(" ")).toContain("Shall I ring 07700 900123");
      expect(texts.join(" ")).toContain("Reply YES");
      expect(calls).toHaveLength(beforeNumber);
      const pending = kv.get("sms_outbound_yes") ?? "";
      const expired = JSON.parse(pending) as { expires_at: string };
      expired.expires_at = new Date(Date.now() - 60_000).toISOString();
      kv.set("sms_outbound_yes", JSON.stringify(expired));
      texts.length = 0;
      await handleInboundSms(env, "+15557654321", "yes");
      expect(calls).toHaveLength(beforeNumber);
      expect(texts.join(" ").toLowerCase()).toContain("expired");
      await handleInboundSms(env, "+15557654321", "Call 07700 900123 and ask him if he is free tomorrow");
      texts.length = 0;
      await handleInboundSms(env, "+15557654321", "YES");
      expect(calls).toHaveLength(beforeNumber + 1);
      expect(new URLSearchParams(calls[beforeNumber] ?? "").get("To")).toBe("+447700900123");

      const alone = deskEnv(new Map());
      const stray: string[] = [];
      globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
        const url = String(input);
        if (url.includes("/Calls.json")) stray.push(url);
        if (url.includes("/Messages.json") && (init?.method ?? "GET") === "POST") {
          return new Response(JSON.stringify({ sid: "SMnote", status: "queued" }), { status: 201 });
        }
        return new Response("{}", { status: 404 });
      }) as typeof fetch;
      await handleInboundSms(alone, "+15557654321", "yes");
      expect(stray).toHaveLength(0);
    } finally {
      globalThis.fetch = original;
    }
  }, 15_000);

  it("texts the outcome of an approved call once", async () => {
    const env = deskEnv(new Map());
    const texts: string[] = [];
    const original = globalThis.fetch;
    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      if (String(input).includes("/Messages.json") && (init?.method ?? "GET") === "POST") {
        texts.push(new URLSearchParams(String(init?.body ?? "")).get("Body") ?? "");
        return new Response(JSON.stringify({ sid: "SMout", status: "queued" }), { status: 201 });
      }
      return new Response("{}", { status: 404 });
    }) as typeof fetch;
    try {
      await rememberSmsOutcome(env, "call_smsout", "+15557654321", "them");
      await noteSmsOutcome(env, "call_smsout", "He is free tomorrow morning.", "completed");
      await noteSmsOutcome(env, "call_smsout", "He is free tomorrow morning.", "completed");
      expect(texts).toEqual(["Sir, He is free tomorrow morning."]);
    } finally {
      globalThis.fetch = original;
    }
  });

  it("keeps the pending number so a follow-up becomes the YES confirmation", async () => {
    expect(pendingRevision("Tell them I said hello")).toEqual({ verb: "tell", purpose: "hello" });
    expect(pendingRevision("Call the number and tell them hello")).toEqual({ verb: "tell", purpose: "hello" });
    expect(pendingRevision("What did he say")).toBeNull();

    const env = deskEnv(new Map());
    env.GEMINI_API_KEY = "gemini-test-key";
    env.ELEVENLABS_API_KEY = "elevenlabs-key-example-value";
    env.ELEVENLABS_AGENT_ID = "agent_example";
    const calls: string[] = [];
    const texts: string[] = [];
    const models: string[] = [];
    const original = globalThis.fetch;
    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      const method = init?.method ?? "GET";
      if (url.includes("generativelanguage") || url.includes("groq.com")) {
        models.push(url);
        return new Response("{}", { status: 500 });
      }
      if (url.includes("/Calls.json") && method === "POST") {
        calls.push(String(init?.body ?? ""));
        return new Response(JSON.stringify({ sid: "CA1234567890abcdef1234567890abcd" }), { status: 201 });
      }
      if (url.includes("/Messages.json") && method === "POST") {
        texts.push(new URLSearchParams(String(init?.body ?? "")).get("Body") ?? "");
        return new Response(JSON.stringify({ sid: "SMnote", status: "queued" }), { status: 201 });
      }
      return new Response("{}", { status: 404 });
    }) as typeof fetch;
    const pending: Promise<unknown>[] = [];
    const context = {
      waitUntil(promise: Promise<unknown>) {
        pending.push(promise);
      },
      passThroughOnException() {
        return undefined;
      },
      props: {},
      async flush() {
        await Promise.all(pending.splice(0));
      },
    };
    const post = async (body: string) => {
      const url = "https://jarvis.test/calls/sms";
      const params = {
        From: "+15557654321",
        To: "+15551230001",
        Body: body,
        MessageSid: "SM1234567890abcdef1234567890abcd",
      };
      const signature = await twilioSignature(url, params, "twilio-token");
      const response = await route(
        new Request(url, {
          method: "POST",
          headers: { "content-type": "application/x-www-form-urlencoded", "X-Twilio-Signature": signature },
          body: new URLSearchParams(params).toString(),
        }),
        env,
        context as unknown as ExecutionContext,
      );
      expect(response.status).toBe(200);
      await context.flush();
    };
    try {
      await post("Call 07700 900123 and ask him if he is free tomorrow");
      expect(texts.join(" ")).toContain("Shall I ring 07700 900123");
      expect(texts.join(" ")).toContain("Reply YES");
      expect(calls).toHaveLength(0);
      expect(models).toHaveLength(0);

      texts.length = 0;
      await post("Tell them I said hello");
      expect(texts.join(" ")).toContain("Shall I ring 07700 900123 to tell them hello");
      expect(texts.join(" ")).toContain("Reply YES");
      expect(texts.join(" ")).not.toContain("couldn't reach my notes");
      expect(calls).toHaveLength(0);
      expect(models).toHaveLength(0);

      texts.length = 0;
      await post("Call the number and tell them hello");
      expect(texts.join(" ")).toContain("to tell them hello");
      expect(calls).toHaveLength(0);

      texts.length = 0;
      await post("YES");
      expect(calls).toHaveLength(1);
      expect(new URLSearchParams(calls[0] ?? "").get("To")).toBe("+447700900123");
      expect(models).toHaveLength(0);

      texts.length = 0;
      await post("What did he say");
      expect(texts.join(" ")).not.toContain("couldn't reach my notes");
      expect(texts.join(" ").toLowerCase()).toContain("boiler");
      expect(models).toHaveLength(0);
    } finally {
      globalThis.fetch = original;
    }
  }, 20_000);

  it("logs the model error when the fallback is sent", async () => {
    const kv = new Map<string, string>();
    const env = deskEnv(kv);
    env.GEMINI_API_KEY = "gemini-test-key";
    const texts: string[] = [];
    let sentSchema = "";
    const original = globalThis.fetch;
    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      if (url.includes("generativelanguage")) {
        sentSchema = String(init?.body ?? "");
        return new Response(
          JSON.stringify({ error: { message: 'Invalid JSON payload received. Unknown name "additionalProperties"' } }),
          { status: 400 },
        );
      }
      if (url.includes("/Messages.json") && (init?.method ?? "GET") === "POST") {
        texts.push(new URLSearchParams(String(init?.body ?? "")).get("Body") ?? "");
        return new Response(JSON.stringify({ sid: "SMfail", status: "queued" }), { status: 201 });
      }
      return new Response("{}", { status: 404 });
    }) as typeof fetch;
    try {
      await handleInboundSms(env, "+15557654321", "What is the weather in Paris");
      expect(sentSchema).not.toContain("additionalProperties");
      expect(texts.join(" ")).toContain("couldn't reach my notes");
      const logged = JSON.parse(kv.get("sms_last_errors") ?? "[]") as Array<{ where: string; error: string }>;
      expect(logged[0]?.where).toBe("chat");
      expect(logged[0]?.error).toContain("additionalProperties");
      expect(logged[0]?.error).not.toContain("gemini-test-key");
    } finally {
      globalThis.fetch = original;
    }
  });
});

function deskEnv(kv: Map<string, string>): Env {
  const message = {
    call_id: "call_sohail",
    caller_name: "Sohail",
    summary: "Good evening.",
    spoken: "Sir, Sohail rang at 02:41. Good evening.",
    called_at: "2026-10-21T01:41:00.000Z",
    transcript_json: JSON.stringify([
      { role: "them", text: "Good evening." },
      { role: "them", text: "The boiler is leaking. Please call me back on +15550001111." },
    ]),
    caller_phone: "+15550001111",
  };
  const db = {
    prepare(sql: string) {
      let bound: unknown[] = [];
      const statement = {
        bind(...args: unknown[]) {
          bound = args;
          return statement;
        },
        async first() {
          if (sql.includes("runtime_state")) {
            const value = kv.get(String(bound[0]));
            return value == null ? null : { value };
          }
          if (sql.includes("call_messages")) return message;
          if (sql.includes("call_settings")) return null;
          if (sql.includes("outbound_calls")) return { transcript_json: message.transcript_json, worker_origin: "" };
          return null;
        },
        async all() {
          return { results: [], success: true, meta: {} };
        },
        async run() {
          if (sql.includes("INSERT INTO runtime_state")) {
            kv.set(String(bound[0]), String(bound[1]));
            return { success: true, meta: { changes: 1 } };
          }
          if (sql.includes("UPDATE runtime_state") && sql.includes("sms_callback")) {
            const current = kv.get("sms_callback") ?? "";
            if (current && current === String(bound[2])) {
              kv.set("sms_callback", "");
              return { success: true, meta: { changes: 1 } };
            }
            return { success: true, meta: { changes: 0 } };
          }
          return { success: true, meta: { changes: 1 } };
        },
      };
      return statement;
    },
  };
  return {
    JARVIS_APP_TOKEN: "secret-token",
    OWNER_PHONE: "+15557654321",
    TWILIO_ACCOUNT_SID: "AC123",
    TWILIO_AUTH_TOKEN: "twilio-token",
    TWILIO_FROM_NUMBER: "+15551230001",
    DB: db as unknown as D1Database,
  };
}
