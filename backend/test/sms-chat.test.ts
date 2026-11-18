import { afterEach, describe, expect, it } from "vitest";
import { adviceQuestion, chatBubbles, gsmText, handleInboundSms, simulateSmsRoute, wantsDetail } from "../src/sms-desk";
import type { Env } from "../src/types";
import { sqliteD1 } from "./helpers/sqlite-d1";

const OWNER = "+447700900555";
const original = globalThis.fetch;

interface Seen {
  texts: { to: string; body: string }[];
  prompts: { role: string; content: string }[][];
  calls: number;
}

function chatEnv(answers: string[]): { env: Env; seen: Seen } {
  const { db } = sqliteD1();
  const seen: Seen = { texts: [], prompts: [], calls: 0 };
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    if (url.includes("groq.com") || url.includes("generativelanguage")) {
      const body = JSON.parse(String(init?.body ?? "{}")) as { messages: { role: string; content: string }[] };
      seen.prompts.push(body.messages);
      const content = answers[seen.prompts.length - 1] ?? "Very good, Sir.";
      return new Response(JSON.stringify({ choices: [{ message: { role: "assistant", content }, finish_reason: "stop" }] }), { status: 200 });
    }
    if (url.includes("/Calls.json")) {
      seen.calls++;
      return new Response(JSON.stringify({ sid: "CA1234567890abcdef1234567890abcdef" }), { status: 201 });
    }
    if (url.includes("/Messages.json") && (init?.method ?? "GET") === "POST") {
      const form = new URLSearchParams(String(init?.body ?? ""));
      seen.texts.push({ to: form.get("To") ?? "", body: form.get("Body") ?? "" });
      return new Response(JSON.stringify({ sid: "SM1234567890abcdef1234567890abcdef", status: "queued" }), { status: 201 });
    }
    return new Response("{}", { status: 404 });
  }) as typeof fetch;
  const env = {
    DB: db,
    GROQ_API_KEY: "groq-test-key",
    TWILIO_ACCOUNT_SID: "ACtest",
    TWILIO_AUTH_TOKEN: "twilio-token",
    TWILIO_FROM_NUMBER: "+447700900999",
    OWNER_PHONE: OWNER,
  } as unknown as Env;
  return { env, seen };
}

afterEach(() => {
  globalThis.fetch = original;
});

describe("owner SMS conversation", () => {
  it("chats with Sir and carries the thread across three texts", async () => {
    const { env, seen } = chatEnv([
      "Evening, Sir. All quiet here. How was the gym?",
      "Leg day, then. I would stretch tonight and take the lift tomorrow, Sir.",
      "You told me it was leg day, Sir. Hence the stretching.",
    ]);
    await handleInboundSms(env, OWNER, "Evening Jarvis, how's it going?");
    await handleInboundSms(env, OWNER, "Gym was brutal, leg day");
    await handleInboundSms(env, OWNER, "Why did you say stretch?");
    expect(seen.texts.map((t) => t.body)).toEqual([
      "Evening, Sir. All quiet here. How was the gym?",
      "Leg day, then. I would stretch tonight and take the lift tomorrow, Sir.",
      "You told me it was leg day, Sir. Hence the stretching.",
    ]);
    expect(seen.texts.every((t) => t.to === OWNER)).toBe(true);
    const third = seen.prompts[2] ?? [];
    expect(third[0]?.role).toBe("system");
    expect(third[0]?.content).toContain("You are texting Sir directly");
    expect(third.slice(1).map((m) => `${m.role}:${m.content}`)).toEqual([
      "user:Evening Jarvis, how's it going?",
      "assistant:Evening, Sir. All quiet here. How was the gym?",
      "user:Gym was brutal, leg day",
      "assistant:Leg day, then. I would stretch tonight and take the lift tomorrow, Sir.",
      "user:Why did you say stretch?",
    ]);
    expect(seen.calls).toBe(0);
  });

  it("keeps only the last 20 texts of this phone's thread", async () => {
    const { env, seen } = chatEnv([]);
    for (let i = 0; i < 12; i++) await handleInboundSms(env, OWNER, `note number ${i} about nothing much`);
    const last = seen.prompts.at(-1) ?? [];
    expect(last.length - 1).toBe(20);
    expect(last.at(-1)?.content).toBe("note number 11 about nothing much");
  });

  it("sends a chat reply as one text, not one text per sentence", async () => {
    const { env, seen } = chatEnv(["Of course, Sir. I can do that. Shall I go ahead?"]);
    await handleInboundSms(env, OWNER, "Fancy a chat?");
    expect(seen.texts).toHaveLength(1);
  });

  it("keeps command paths deterministic: a call still waits for YES and never reaches the model", async () => {
    const { env, seen } = chatEnv([]);
    await handleInboundSms(env, OWNER, "Call 07700 900123 and ask him if he is free tomorrow");
    expect(seen.texts.map((t) => t.body).join(" ")).toContain("Reply YES");
    expect(seen.prompts).toHaveLength(0);
    expect(seen.calls).toBe(0);
    await handleInboundSms(env, OWNER, "YES");
    expect(seen.calls).toBe(1);
    expect(seen.prompts).toHaveLength(0);
  });

  it("never chats with a stranger", async () => {
    const { env, seen } = chatEnv(["I should not be used."]);
    await handleInboundSms(env, "+447700900321", "Hi, where is Sohail today?");
    expect(seen.prompts).toHaveLength(0);
    const toStranger = seen.texts.filter((t) => t.to === "+447700900321").map((t) => t.body);
    expect(toStranger).toEqual(["Hello, this is JARVIS, Master Hadi's assistant. I'll pass that to him."]);
  });

  it("simulates a three-turn thread without sending a text", async () => {
    const { env, seen } = chatEnv(["Good evening, Sir.", "Noted, Sir.", "You said pizza, Sir."]);
    const post = async (text: string, reset = false) => {
      const response = await simulateSmsRoute(
        new Request("https://jarvis.test/debug/sms-simulate", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ text, thread: "42", reset }),
        }),
        env,
      );
      return (await response.json()) as { reply: string; history: number; sent: boolean };
    };
    expect((await post("Evening", true)).history).toBe(2);
    await post("Pizza tonight I think");
    const third = await post("What did I say I'm eating?");
    expect(third.reply).toBe("You said pizza, Sir.");
    expect(third.history).toBe(6);
    expect(third.sent).toBe(false);
    expect(seen.texts).toHaveLength(0);
    expect((seen.prompts[2] ?? []).some((m) => m.content === "Pizza tonight I think")).toBe(true);
  });

  it("treats tell me more as chat when the thread was not about a call", async () => {
    const { env, seen } = chatEnv(["Rome was not built in a day, Sir.", "Quite literally, Sir: it took centuries."]);
    await handleInboundSms(env, OWNER, "Tell me about Rome");
    await handleInboundSms(env, OWNER, "tell me more");
    expect(seen.prompts).toHaveLength(2);
  });

  it("helpers", () => {
    expect(gsmText("It’s “fine” — really… 👍")).toBe(`It's "fine" - really...`);
    expect(gsmText("a plan—perhaps tea. Let me know.A warm cup")).toBe("a plan - perhaps tea. Let me know. A warm cup");
    expect(chatBubbles("a ".repeat(400))).toHaveLength(1);
    expect(chatBubbles("a ".repeat(400))[0]!.length).toBeLessThanOrEqual(306);
    expect(chatBubbles("Word. ".repeat(150), true).length).toBe(3);
    expect(wantsDetail("explain it properly")).toBe(true);
    expect(wantsDetail("hello")).toBe(false);
    expect(adviceQuestion("Should I buy a PS5?")).toBe(true);
    expect(adviceQuestion("pay the invoice")).toBe(false);
  });
});
