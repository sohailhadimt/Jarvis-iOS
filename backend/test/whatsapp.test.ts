// @ts-nocheck -- uses the Node SQLite helper.
import { afterEach, describe, expect, it, vi } from "vitest";
import { openWindow, replyChannel, stripWhatsApp, isWhatsAppSender } from "../src/whatsapp";
import { sendSmsResult } from "../src/sms-desk";
import { watchVideo } from "../src/sms-extras";
import { sqliteD1 } from "./helpers/sqlite-d1";

const OWNER = "+447700900555";

function env(extra = {}) {
  const { db } = sqliteD1();
  return {
    DB: db,
    TWILIO_ACCOUNT_SID: "ACexampleaccountsid000000000000",
    TWILIO_AUTH_TOKEN: "twilio-auth-token-example",
    TWILIO_FROM_NUMBER: "+447700900000",
    GEMINI_API_KEY: "g-key",
    ...extra,
  };
}

afterEach(() => vi.unstubAllGlobals());

describe("WhatsApp channel", () => {
  it("stays off until a WhatsApp sender is configured", async () => {
    const e = env();
    await openWindow(e, OWNER);
    expect(await replyChannel(e, OWNER)).toBeNull();
  });

  it("answers on WhatsApp inside his window, and falls back to SMS if WhatsApp refuses", async () => {
    const e = env({ TWILIO_WHATSAPP_FROM: "whatsapp:+14155238886" });
    expect(isWhatsAppSender("whatsapp:+447700900555")).toBe(true);
    expect(stripWhatsApp("whatsapp:+447700900555")).toBe(OWNER);
    expect(await replyChannel(e, OWNER)).toBeNull();
    await openWindow(e, OWNER);
    expect(await replyChannel(e, OWNER)).toBe("whatsapp:+14155238886");
    expect(await replyChannel(e, OWNER, Date.now() + 24 * 3600_000)).toBeNull();

    const sent = [];
    let refuse = false;
    vi.stubGlobal("fetch", async (_url, init) => {
      const form = new URLSearchParams(init.body);
      sent.push([form.get("From"), form.get("To")]);
      if (refuse && form.get("From").startsWith("whatsapp:")) return Response.json({ code: 63016, message: "window closed" }, { status: 400 });
      return Response.json({ sid: "SM1", status: "queued" }, { status: 201 });
    });
    expect((await sendSmsResult(e, OWNER, "Hello Sir")).ok).toBe(true);
    expect(sent.at(-1)).toEqual(["whatsapp:+14155238886", "whatsapp:+447700900555"]);
    refuse = true;
    expect((await sendSmsResult(e, OWNER, "Hello again")).ok).toBe(true);
    expect(sent.at(-1)).toEqual(["+447700900000", OWNER]);
    expect(await replyChannel(e, OWNER)).toBeNull();
  });

  it("watches a video clip with Gemini, falling back across models", async () => {
    const urls = [];
    vi.stubGlobal("fetch", async (url, init) => {
      urls.push(String(url));
      if (String(url).includes("gemini-3.8-flash")) return new Response("{}", { status: 429 });
      const body = JSON.parse(init.body);
      expect(body.contents[0].parts[0].inline_data.mime_type).toBe("video/mp4");
      return Response.json({ candidates: [{ content: { parts: [{ text: "Your **boiler** is flashing E119, Sir: low pressure." }] } }] });
    });
    const said = await watchVideo(env(), { mime: "video/mp4", b64: "AAAA" }, "what's wrong?");
    expect(said).toBe("Your boiler is flashing E119, Sir: low pressure.");
    expect(urls[1]).toContain("gemini-3.5-flash-lite");
  });
});
