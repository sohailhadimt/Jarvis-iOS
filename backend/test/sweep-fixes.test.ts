import { describe, expect, it } from "vitest";
import { brainSystem, dropTrailingOffers, smsAnswer } from "../src/brain";
import { ownerCallSummary } from "../src/call-settle";
import { saysSentPicture } from "../src/sms-extras";
import { ownerAgentPrompt } from "../src/owner-agent";

describe("sweep of Sir's texts and calls, 18 Nov", () => {
  it("drops the trailing 'let me know' and 'take care' padding", () => {
    expect(dropTrailingOffers("I miss you too, Sir. Let me know if there's anything I can do for you today. Take care.")).toBe("I miss you too, Sir.");
    expect(smsAnswer("A rather purr-fect punchline, Sir. Please let me know if you require any assistance today.", false)).toBe("A rather purr-fect punchline, Sir.");
    expect(dropTrailingOffers("Let me know when you land, Sir.")).toBe("Let me know when you land, Sir.");
  });

  it("knows his slang, knock-knock jokes, search-first facts, no fake YES offers, and that photos never arrive", () => {
    const sms = brainSystem("sms");
    expect(sms).toMatch(/yh, ye and ya mean yeah/);
    expect(sms).toMatch(/Yh is never a name/);
    expect(sms).toMatch(/Who's there\?/);
    expect(sms).toMatch(/Never invent fire rates, recoil/);
    expect(sms).toMatch(/Never ask him to reply YES yourself/);
    expect(sms).toMatch(/cannot receive photos or videos/);
  });

  it("answers honestly when he says he sent a photo or video", () => {
    expect(saysSentPicture("I've sent you the video of it and the photo of it")).toBe(true);
    expect(saysSentPicture("Use the photo that I sent u as ur menu")).toBe(true);
    expect(saysSentPicture("did u get my pic")).toBe(true);
    expect(saysSentPicture("send me a photo of a cat")).toBe(false);
  });

  it("summarises Sir's own call as his, not as a stranger's message", () => {
    const summary = ownerCallSummary([{ role: "them", text: "Act like a takeaway." }, { role: "jarvis", text: "Certainly." }], null);
    expect(summary).toBe("You rang JARVIS: Act like a takeaway.");
    expect(summary).not.toMatch(/called to tell you/);
  });

  it("the call prompt can book a call to him and never invents text commands", () => {
    const prompt = ownerAgentPrompt();
    expect(prompt).toMatch(/schedule_call_to_owner/);
    expect(prompt).toMatch(/cannot book tickets/);
  });
});
