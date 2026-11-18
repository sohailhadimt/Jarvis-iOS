// @ts-nocheck
import { describe, expect, it } from "vitest";
import { languageCommand, needsUnicode, scriptOf, smsLanguageRule, ttsLanguage, multilingualModel, languagePresets } from "../src/languages";
import { chatBubbles, unicodeBubbles } from "../src/sms-desk";
import { ownerAgentBody, ownerAgentPrompt } from "../src/owner-agent";
import { deskAgentBody, deskPrompt } from "../src/desk";

describe("languages", () => {
  it("reads language commands and nothing else", () => {
    expect(languageCommand("speak Urdu")).toBe("ur");
    expect(languageCommand("Turkish mode")).toBe("tr");
    expect(languageCommand("English")).toBe("en");
    expect(languageCommand("punjabi please")).toBe("pa");
    expect(languageCommand("Switch to Turkish")).toBe("tr");
    expect(languageCommand("urdu bolo")).toBe("ur");
    expect(languageCommand("اردو")).toBe("ur");
    expect(languageCommand("ਪੰਜਾਬੀ")).toBe("pa");
    expect(languageCommand("Türkçe konuş")).toBe("tr");
    expect(languageCommand("how do you say hello in Urdu")).toBeNull();
    expect(languageCommand("ring Ali and ask if he speaks Turkish")).toBeNull();
  });

  it("knows scripts and TTS languages", () => {
    expect(scriptOf("آپ کیسے ہیں")).toBe("arabic");
    expect(scriptOf("ਤੁਸੀਂ ਕਿਵੇਂ ਹੋ")).toBe("gurmukhi");
    expect(scriptOf("Nasılsın, iyi misin?")).toBe("turkish");
    expect(scriptOf("aap kaise ho")).toBe("latin");
    expect(ttsLanguage("آپ کیسے ہیں")).toBe("ur");
    expect(ttsLanguage("تسی کتھے او؟ میں گھر وچ آں")).toBe("pa");
    expect(ttsLanguage("ਸਤ ਸ੍ਰੀ ਅਕਾਲ")).toBe("pa");
    expect(ttsLanguage("Good evening, Sir")).toBeNull();
  });

  it("keeps Urdu, Punjabi and Turkish letters in SMS and caps them at two Unicode segments", () => {
    expect(needsUnicode("Good evening, Sir. £5 café")).toBe(false);
    expect(needsUnicode("İyi akşamlar efendim")).toBe(true);
    const urdu = "جی سر، کل ایشفورڈ میں بارش ہوگی۔ ".repeat(8);
    const [one, ...rest] = chatBubbles(urdu);
    expect(rest.length).toBe(0);
    expect(one).toContain("ایشفورڈ");
    expect(one.length).toBeLessThanOrEqual(134);
    expect(chatBubbles("İyi akşamlar efendim. Yarın yağmur var.")[0]).toBe("İyi akşamlar efendim. Yarın yağmur var.");
    expect(unicodeBubbles(urdu.repeat(2), true).length).toBe(3);
    // English still goes through the cheap GSM path.
    expect(chatBubbles("Very good, Sir.")[0]).toBe("Very good, Sir.");
  });

  it("tells the SMS brain to mirror his language and honour a pinned one", () => {
    expect(smsLanguageRule(null, "kya haal hai")).toContain("Roman Urdu");
    expect(smsLanguageRule("ur", "how are you")).toContain("reply in Urdu even when he writes in English");
    expect(smsLanguageRule("tr", "hi")).toContain("Turkish");
  });

  it("the personal and desk agents carry Urdu, Punjabi and Turkish with language detection on a multilingual voice model", () => {
    for (const body of [ownerAgentBody(["t"], { tts: { model_id: "eleven_turbo_v2" } }), deskAgentBody(["t"], { tts: {} })]) {
      const c = body.conversation_config;
      expect(Object.keys(c.language_presets).sort()).toEqual(["pa", "tr", "ur"]);
      expect(c.agent.prompt.built_in_tools.language_detection.params.system_tool_type).toBe("language_detection");
      expect(c.agent.language).toBe("en");
      expect(c.tts.model_id).toBe("eleven_v4_turbo");
      expect(c.tts.voice_id).toBe("JBFqnCBsd6RMkjVDRZzb");
    }
    expect(ownerAgentPrompt()).toContain("Urdu, Punjabi or Turkish");
    expect(deskPrompt()).toContain("only take a message");
    expect(multilingualModel("eleven_v3_conversational")).toBe("eleven_v3_conversational");
    expect(languagePresets()).toEqual({ ur: { overrides: {} }, pa: { overrides: {} }, tr: { overrides: {} } });
  });
});
