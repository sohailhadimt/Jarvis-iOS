import { getState, setState } from "./db";
import type { Env } from "./types";

/**
 * Sir's languages: English (default), Urdu, Punjabi and Turkish, on SMS, voice notes and calls.
 * SMS mirrors the language and script he writes in; "speak Urdu" / "Turkish mode" / "English" pins one.
 */

export type LangCode = "en" | "ur" | "pa" | "tr";

export const LANG_NAMES: Record<LangCode, string> = { en: "English", ur: "Urdu", pa: "Punjabi", tr: "Turkish" };

/** ElevenLabs agent language presets added next to English. All three are on eleven_v4_turbo / v3. */
export const AGENT_EXTRA_LANGUAGES: LangCode[] = ["ur", "pa", "tr"];

/** "speak Urdu", "Urdu mode", "switch to Turkish", "English please", "اردو", "ਪੰਜਾਬੀ", "Türkçe konuş". Null otherwise. */
export function languageCommand(text: string): LangCode | null {
  const t = text.normalize("NFC").replace(/\s+/g, " ").trim().replace(/[.!?۔]+$/u, "");
  if (!t || t.length > 40) return null;
  const which = (word: string): LangCode | null => {
    const w = word.toLowerCase();
    if (/^(?:urdu|اردو)$/u.test(w)) return "ur";
    if (/^(?:punjabi|panjabi|ਪੰਜਾਬੀ|پنجابی)$/u.test(w)) return "pa";
    if (/^(?:turkish|türkçe|turkce)$/u.test(w)) return "tr";
    if (/^(?:english|ingilizce|انگریزی)$/u.test(w)) return "en";
    return null;
  };
  const patterns = [
    /^(?:please\s+)?(?:speak|talk|text|reply|answer|chat|write|switch to|change to|go|use)\s+(?:in\s+|to\s+)?(\S+)(?:\s+(?:please|now|from now on|mode))?$/iu,
    /^(\S+)\s+(?:mode|only|please|from now on)$/iu,
    /^(?:in\s+)?(\S+)$/iu,
    /^(\S+)\s+(?:bolo|bolein|bolain|bol|konuş|konus|ਬੋਲੋ|بولو)$/iu,
  ];
  for (const p of patterns) {
    const m = p.exec(t);
    if (m) {
      const code = which(m[1]!);
      if (code) return code;
    }
  }
  return null;
}

export function confirmLanguage(code: LangCode): string {
  switch (code) {
    case "ur":
      return "جی سر، اب سے اردو میں بات ہوگی۔";
    case "pa":
      return "ਜੀ ਸਰ, ਹੁਣ ਤੋਂ ਪੰਜਾਬੀ ਵਿੱਚ ਗੱਲ ਕਰਾਂਗਾ।";
    case "tr":
      return "Tamam efendim, bundan sonra Türkçe konuşacağım.";
    default:
      return "Very good, Sir. English it is.";
  }
}

function prefKey(phone: string): string {
  return `sms_lang:${phone}`;
}

export async function readLanguage(env: Env, phone: string): Promise<LangCode | null> {
  const raw = (await getState(env, prefKey(phone)).catch(() => null)) ?? "";
  return raw === "ur" || raw === "pa" || raw === "tr" || raw === "en" ? raw : null;
}

export async function saveLanguage(env: Env, phone: string, code: LangCode): Promise<void> {
  await setState(env, prefKey(phone), code);
}

/** The script of a text, to mirror it: native scripts first, Turkish letters, else Latin. */
export function scriptOf(text: string): "gurmukhi" | "arabic" | "turkish" | "latin" | "other" {
  if (/[\u0A00-\u0A7F]/u.test(text)) return "gurmukhi";
  if (/[\u0600-\u06FF\u0750-\u077F\uFB50-\uFDFF\uFE70-\uFEFF]/u.test(text)) return "arabic";
  if (/[çğıöşüÇĞİÖŞÜ]/u.test(text) && /[ğıışŞİĞ]/u.test(text)) return "turkish";
  if (/[A-Za-z]/.test(text)) return "latin";
  return "other";
}

/** The instruction added to the SMS brain. */
export function smsLanguageRule(pref: LangCode | null, latest: string): string {
  const script = scriptOf(latest);
  const lines = [
    "Languages: you speak English, Urdu, Punjabi and Turkish fluently. Reply in the language and the script of Sir's latest text:",
    "Urdu in Urdu script (Nastaliq) if he wrote in Urdu script, Roman Urdu if he wrote it in Latin letters; Punjabi in Gurmukhi if he wrote Gurmukhi, Shahmukhi if he wrote Punjabi in Arabic script, Roman Punjabi if he wrote it in Latin letters; Turkish with proper Turkish letters.",
    "Mixed Urdu/Punjabi with English words is normal: answer the same way. Keep the butler manner and still call him Sir.",
    "Non-English scripts cost more per text, so in Urdu script, Gurmukhi, Shahmukhi or Turkish keep the reply under 130 characters unless he asked for detail.",
  ];
  if (script === "latin" && pref !== "ur" && pref !== "pa" && pref !== "tr") {
    lines.push("His latest text is in Latin letters. If it is English, reply in English. If it is Roman Urdu or Roman Punjabi (e.g. 'kya haal hai', 'ki haal aa'), reply in the same Roman style using Latin letters only, never Urdu or Gurmukhi script.");
  } else if (script === "arabic") {
    lines.push("His latest text is in Arabic script. Decide Urdu or Punjabi from the words: Punjabi (Shahmukhi) uses words like تسی، کیویں، او، وچ، دا، نوں، توں، اے، کی حال. Reply in Shahmukhi Punjabi if it is Punjabi, otherwise in Urdu, in Arabic script.");
  } else if (script === "gurmukhi") {
    lines.push("His latest text is Punjabi in Gurmukhi: reply in Gurmukhi Punjabi.");
  } else if (script === "turkish") {
    lines.push("His latest text is Turkish: reply in Turkish.");
  }
  if (pref && pref !== "en") {
    const plain = script === "latin";
    const native = pref === "ur" ? "Urdu script" : pref === "pa" ? "Gurmukhi" : "Turkish";
    lines.push(
      `He has asked for ${LANG_NAMES[pref]}: reply in ${LANG_NAMES[pref]} even when he writes in English` +
        (pref === "tr" ? "." : plain ? ` (use ${pref === "ur" ? "Roman Urdu" : "Roman Punjabi"} when he writes in Latin letters, ${native} when he writes in ${native}).` : ` (${native}).`),
    );
  } else if (pref === "en") {
    lines.push("He has asked for English: reply in English unless his text is entirely in another language.");
  }
  return lines.join(" ");
}

/** Letters outside the GSM-7 alphabet mean the text goes as Unicode (70 characters a segment). */
export function needsUnicode(text: string): boolean {
  for (const ch of text) {
    if (!/\p{L}/u.test(ch)) continue;
    if (/[A-Za-zÄÖÑÜäöñüàèéùìòÇØøÅåÆæßÉ]/.test(ch)) continue;
    return true;
  }
  return false;
}

/** Two Unicode segments (67 characters each when concatenated). */
export const UNICODE_SMS_MAX = 134;

/** ElevenLabs TTS language code for a voice-note script, when it is clearly not English. */
export function ttsLanguage(text: string): LangCode | null {
  const s = scriptOf(text);
  if (s === "gurmukhi") return "pa";
  if (s === "arabic") return /(?:^|\s)(?:وچ|دا|دے|نوں|توں|اے|آں|تسی|کتھے)(?=\s|$|[۔،؟?!.])/u.test(text) ? "pa" : "ur";
  if (s === "turkish") return "tr";
  return null;
}

/** The spoken-language line for the voice agents' prompts. */
export function agentLanguageRule(desk = false): string {
  return desk
    ? "Languages: callers may speak English, Urdu, Punjabi or Turkish. Answer in the language they speak (switch language when they do), but you still only take a message; never share anything about Master Hadi."
    : "Languages: Sir may speak English, Urdu, Punjabi or Turkish, or mix them. Reply in the language he is speaking and switch when he switches (use the language detection tool). Start in English. In Punjabi or Urdu still call him Sir.";
}

/** The ElevenLabs conversation_config pieces that turn on Urdu, Punjabi and Turkish with auto-switching. */
export function languagePresets(): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const code of AGENT_EXTRA_LANGUAGES) out[code] = { overrides: {} };
  return out;
}

export const LANGUAGE_DETECTION_TOOL = {
  name: "language_detection",
  description: "",
  params: { system_tool_type: "language_detection" },
};

/** TTS models that speak Urdu, Punjabi and Turkish. Anything else moves to eleven_v4_turbo. */
const MULTI = new Set(["eleven_v4_turbo", "eleven_v4", "eleven_v3_conversational"]);
export function multilingualModel(current: unknown): string {
  return typeof current === "string" && MULTI.has(current) ? current : "eleven_v4_turbo";
}

export const MAIN_LANG_VERSION = "lang-1";

/** Adds Urdu, Punjabi and Turkish presets and language detection to the dashboard (main) agent, once per version. */
export async function ensureMainMultilingual(env: Env, force = false): Promise<{ ok: boolean; state: string; error?: string }> {
  const apiKey = (env.ELEVENLABS_API_KEY ?? "").trim();
  const agentId = (env.ELEVENLABS_AGENT_ID ?? "").trim();
  if (!apiKey || !agentId) return { ok: false, state: "missing", error: "no key or agent" };
  const stamp = `${MAIN_LANG_VERSION}|${agentId}`;
  if (!force && (await getState(env, "main_agent_lang").catch(() => null)) === stamp) return { ok: true, state: "current" };
  const { eleven } = await import("./desk");
  const got = await eleven(apiKey, "GET", `/v1/convai/agents/${encodeURIComponent(agentId)}`);
  const body = got.body as { conversation_config?: { agent?: { prompt?: { built_in_tools?: Record<string, unknown> } }; tts?: { model_id?: unknown } } } | null;
  if (!got.ok || !body?.conversation_config) return { ok: false, state: "read_failed", error: got.detail };
  const current = body.conversation_config.agent?.prompt?.built_in_tools ?? {};
  const tools: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(current)) if (v) tools[k] = v;
  tools.language_detection = LANGUAGE_DETECTION_TOOL;
  const patched = await eleven(apiKey, "PATCH", `/v1/convai/agents/${encodeURIComponent(agentId)}`, {
    conversation_config: {
      language_presets: languagePresets(),
      agent: { prompt: { built_in_tools: tools } },
      tts: { model_id: multilingualModel(body.conversation_config.tts?.model_id) },
    },
  });
  if (!patched.ok) return { ok: false, state: "patch_failed", error: patched.detail };
  await setState(env, "main_agent_lang", stamp);
  return { ok: true, state: "updated" };
}
