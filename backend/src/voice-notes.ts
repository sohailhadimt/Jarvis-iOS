import { GEORGE_VOICE_ID } from "./brain";
import { dbAll, dbFirst, dbRun, getState, setState } from "./db";
import { completeChat, type ChatMessage } from "./llm";
import type { Env } from "./types";

/**
 * Voice notes by link. UK Twilio numbers cannot send MMS, so JARVIS makes the audio,
 * keeps it in D1 for a week, and texts a short unguessable link that plays in one tap.
 */

export const VOICE_NOTE_DAYS = 7;
/** Most characters George speaks in one note. The ElevenLabs Starter plan is 30k a month. */
export const VOICE_NOTE_MAX_CHARS = 400;
/** Seconds of generated sound for a beatbox or sound effect (about 40 credits a second). */
export const SOUND_SECONDS = 8;
/** Stop making notes when the plan has fewer credits than this left, so calls keep working. */
const CREDIT_FLOOR = 2_500;
const FALLBACK_ORIGIN = "https://jarvis-backend.jarvis-hadi.workers.dev";

export type VoiceKind = "speech" | "sing" | "beatbox" | "sound";

export interface VoiceAsk {
  kind: VoiceKind;
  /** He asked to hear it on a call rather than by link. */
  byCall: boolean;
  /** For a sound: what it should sound like. */
  prompt: string;
  /** Roast, hype, diss track or rap over a beat. */
  style?: VoiceStyle;
}

export type VoiceStyle = "roast" | "hype" | "diss" | "rap";

/** Diss tracks stay playful: no threats, slurs or digs at who someone is. */
export function dissUnsafe(text: string): boolean {
  return /\b(?:kill|stab|shoot|murder|die|dead|hurt|beat (?:him|her|them) up|bomb|rape|race|racist|religion|muslim|jewish|christian|hindu|sikh|gay|lesbian|trans|disabled|disability|retard\w*|n[i1]gg\w*|paki|f[a@]g\w*|ugly|fat)\b/i.test(text);
}

const VOICE_WORDS =
  /\b(?:voice ?(?:note|message|memo|msg|clip|recording)s?|audio (?:note|message|clip|file)|send (?:me )?(?:a |an )?(?:recording|audio)|say (?:it|that|this)(?: out loud| to me)?|say (?:something|hello|hi|good ?night|good ?morning|happy)|read (?:it|that|this) (?:out|to me)|out loud|speak to me|let me hear|sing|singing|song|rap|rapping|beat ?box(?:ing)?|sound (?:effect|of)|make (?:a|the) (?:noise|sound))\b/i;

/** A text from Sir that wants audio back. Strangers never reach this. */
export function voiceAsk(text: string): VoiceAsk | null {
  const clean = text.replace(/\s+/g, " ").trim();
  if (!clean) return null;
  const byCallStyle = /\b(?:call|ring|phone) me\b/i.test(clean);
  if (/^(?:please\s+|go on,?\s+|jarvis,?\s+)?roast me\b/i.test(clean) || /\b(?:roast me|give me a roast)\b/i.test(clean))
    return { kind: "speech", byCall: byCallStyle, prompt: "", style: "roast" };
  if (/\b(?:hype me(?: up)?|gas me up|motivate me|pep talk)\b/i.test(clean))
    return { kind: "speech", byCall: byCallStyle, prompt: "", style: "hype" };
  const diss = /\bdiss(?: track| song| verse)?\b(?:\s+(?:about|on|for|against)\s+(.{2,80}))?/i.exec(clean);
  if (diss && !/(?:\+|\b0)\d[\d\s-]{8,}\d/.test(clean)) {
    return { kind: "sing", byCall: byCallStyle, prompt: (diss[1] ?? "").replace(/[.?!]+$/, "").trim(), style: "diss" };
  }
  if (!VOICE_WORDS.test(clean)) return null;
  // "Call 07700 900123 and say hello" is a call to someone else, handled by the call desk.
  if (/(?:\+|\b0)\d[\d\s-]{8,}\d/.test(clean)) return null;
  // Talking about songs or rap is chat, not a request for audio.
  const wantsAudio =
    /\b(?:voice|audio|recording|out loud|let me hear|speak to me|say (?:it|that|this|something)(?: to me)?$|say (?:it|that|this|something) to me|read (?:it|that|this) (?:out|to me))\b/i.test(clean) ||
    /\b(?:send|give|do (?:a|me|us)|make|can you|could you|will you|go on|please|call me)\b.{0,40}\b(?:sing|song|rap|beat ?box|sound|noise)/i.test(clean) ||
    /^(?:sing|rap|beat ?box)\b/i.test(clean);
  if (!wantsAudio) return null;
  const byCall = /\b(?:call|ring|phone) me\b/i.test(clean);
  if (/\bbeat ?box/i.test(clean)) return { kind: "beatbox", byCall, prompt: "" };
  const sound = /\b(?:sound (?:effect )?of|noise of|sound like)\s+(.{3,80})$/i.exec(clean);
  if (sound?.[1]) return { kind: "sound", byCall, prompt: sound[1].replace(/[.?!]+$/, "") };
  if (/\b(?:rap|rapping|bars|verse)\b/i.test(clean)) return { kind: "sing", byCall, prompt: "", style: "rap" };
  if (/\b(?:sing|singing|song)\b/i.test(clean)) return { kind: "sing", byCall, prompt: "" };
  return { kind: "speech", byCall, prompt: "" };
}

/** The beatbox JARVIS sends. Chosen by the voice lab listening check (see /debug/voice-lab). */
// Lab run lab1 (16 Nov): sound v3 had the tightest groove (onset periodicity 0.56 vs 0.32 for v2,
// 5 hits a second, widest spread of kick/snare/hat timbres); George reading syllables on eleven_v3 was words, not a beat.
export const BEATBOX = {
  model: "eleven_text_to_sound_v3",
  seconds: 12,
  influence: 0.7,
};

const BEATBOX_BASE =
  "Skilled solo human beatboxer performing a complex, fire hip-hop beatbox routine into a close microphone, voice only: deep punchy kick, sharp rimshot snare, inward K snare, rapid crisp hi-hat rolls, lip-roll and throat bass, quick fills and a new variation every bar, tight swinging groove";

/** Refinements in plain words; slang like "make it fire" just means the full routine. */
export function beatboxPrompt(refinement = ""): string {
  const r = refinement.toLowerCase();
  const tempo = /\b(?:faster|quicker|speed it up|hype)\b/.test(r) ? "105 bpm" : /\b(?:slower|chill|calm)\b/.test(r) ? "85 bpm" : "95 bpm";
  const extra = /\bbass|deeper\b/.test(r) ? ", heavy bass" : /\bhi.?hat|tss\b/.test(r) ? ", busy hi-hats" : "";
  return `${BEATBOX_BASE}${extra}, ${tempo}, no instruments, no music, no background noise, dry studio`;
}

/** The backing beat rap notes play over. Made once, then reused so each rap only costs the words. */
export const RAP_BEAT_PROMPT =
  "Original boom bap hip hop instrumental loop, 90 bpm, punchy kick and crisp snare, swinging hi-hats, warm sub bass and a moody piano chord, no vocals, seamless loop, studio quality";

export async function rapBeat(env: Env): Promise<string | null> {
  await ensureVoiceTable(env);
  const saved = ((await getState(env, "voice:rap_beat").catch(() => null)) ?? "").trim();
  if (saved) {
    const row = await dbFirst<{ id: string }>(env, "SELECT id FROM voice_notes WHERE id = ? AND expires_at > ?", [saved, new Date().toISOString()]).catch(() => null);
    if (row) return saved;
  }
  const clip = await soundClip(env, RAP_BEAT_PROMPT, { seconds: 12, model: BEATBOX.model, influence: 0.6 });
  if (!clip.ok) return null;
  const id = noteId();
  const now = new Date().toISOString();
  await dbRun(
    env,
    "INSERT INTO voice_notes (id, kind, mime, audio_b64, bytes, chars, script, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
    [id, "beat", "audio/mpeg", toBase64(clip.bytes), clip.bytes.length, 480, "[beat] rap bed", now, "2099-01-01T00:00:00.000Z"],
  );
  await noteUsage(env, 480);
  await setState(env, "voice:rap_beat", id).catch(() => undefined);
  return id;
}

export interface VoiceNote {
  id: string;
  url: string;
  kind: VoiceKind;
  chars: number;
  bytes: number;
  script: string;
}

export interface VoiceResult {
  ok: boolean;
  note?: VoiceNote;
  error?: string;
  /** Short reason Sir can read. */
  reason?: string;
}

let ready = false;
export async function ensureVoiceTable(env: Env): Promise<void> {
  if (ready) return;
  await dbRun(
    env,
    `CREATE TABLE IF NOT EXISTS voice_notes (
      id TEXT PRIMARY KEY,
      kind TEXT NOT NULL,
      mime TEXT NOT NULL,
      audio_b64 TEXT NOT NULL,
      bytes INTEGER NOT NULL,
      chars INTEGER NOT NULL,
      script TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL,
      expires_at TEXT NOT NULL
    )`,
  );
  await dbRun(env, "CREATE INDEX IF NOT EXISTS idx_voice_notes_expires ON voice_notes (expires_at)").catch(() => 0);
  const cols = await dbAll<{ name: string }>(env, "PRAGMA table_info(voice_notes)").catch(() => []);
  if (cols.length && !cols.some((c) => c.name === "bed")) {
    await dbRun(env, "ALTER TABLE voice_notes ADD COLUMN bed TEXT NOT NULL DEFAULT ''").catch(() => 0);
  }
  ready = true;
}

/** 20 characters of base62 from 15 random bytes: about 119 bits, so a link cannot be guessed. */
export function noteId(): string {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789";
  const bytes = crypto.getRandomValues(new Uint8Array(20));
  let out = "";
  for (const byte of bytes) out += alphabet[byte % alphabet.length];
  return out;
}

export async function noteOrigin(env: Env): Promise<string> {
  try {
    const { readCallSettings } = await import("./owner-alert");
    const saved = ((await readCallSettings(env)).worker_origin ?? "").trim().replace(/^http:/, "https:").replace(/\/+$/, "");
    if (/^https:\/\/[A-Za-z0-9.-]+$/.test(saved)) return saved;
  } catch {
    // fall through
  }
  return FALLBACK_ORIGIN;
}

/** Remaining ElevenLabs credits this cycle, or null when the plan cannot be read. */
export async function elevenCredits(env: Env): Promise<{ used: number; limit: number; resets: string } | null> {
  const key = (env.ELEVENLABS_API_KEY ?? "").trim();
  if (!key) return null;
  try {
    const response = await fetch("https://api.elevenlabs.io/v1/user/subscription", {
      headers: { "xi-api-key": key },
      signal: AbortSignal.timeout(5_000),
    });
    if (!response.ok) return null;
    const body = (await response.json()) as { character_count?: number; character_limit?: number; next_character_count_reset_unix?: number };
    const used = Number(body.character_count ?? NaN);
    const limit = Number(body.character_limit ?? NaN);
    if (!Number.isFinite(used) || !Number.isFinite(limit)) return null;
    const resets = body.next_character_count_reset_unix ? new Date(body.next_character_count_reset_unix * 1000).toISOString() : "";
    return { used, limit, resets };
  } catch {
    return null;
  }
}

function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(binary);
}

function fromBase64(value: string): Uint8Array {
  const binary = atob(value);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}

/** Strips v3 audio tags such as [sings] for models that would read them aloud. */
export function stripTags(text: string): string {
  return text.replace(/\[[^\]]{1,24}\]/g, " ").replace(/\s+/g, " ").trim();
}

/** The words George speaks. History lets "say it" mean the last thing he said. */
export async function writeScript(env: Env, ask: VoiceAsk, request: string, history: { role: string; body: string }[]): Promise<string> {
  const singing = ask.kind === "sing";
  const messages: ChatMessage[] = [
    {
      role: "system",
      content: [
        "You are J.A.R.V.I.S., Sir's British butler assistant, voiced by George. Write only the exact words you will speak in a voice note to Sir.",
        ask.style === "roast"
          ? "He asked you to roast him. Write a short, original, affectionate roast of Sir (three to five quick jokes), dry British wit, cheeky not cruel. Nothing about race, religion, sexuality, disability, weight or looks; no swearing. You may use [laughs] once."
          : ask.style === "hype"
            ? "He asked you to hype him up. Write a short, original, energetic pep talk for Sir, building to a big finish, confident and warm. You may use [excited] or [laughs] once."
            : ask.style === "diss"
              ? `He asked for a diss track${ask.prompt ? ` about ${ask.prompt}` : ""}. Write an original playful diss rap (six to eight short rhyming lines) with clean, witty, teasing bars about harmless things like their cooking, their football team, their timekeeping or their dance moves. No slurs, no swearing, no threats or violence, nothing about race, religion, sexuality, disability, weight or looks, no real people's names other than the target, and never mention or imitate any real artist. Start with [rapping].`
              : ask.style === "rap"
                ? "He asked you to rap. Write a short original rap verse (six to eight lines) with tight rhythm and rhyme, playful and in character, as JARVIS. Never mention or imitate any real artist. Start with [rapping]."
                : singing
          ? "He asked you to sing or rap. Write a short original verse (four to eight lines) with rhythm and rhyme, playful and in character. You may use the audio tags [sings], [rapping], [laughs] or [clears throat] sparingly. Never use real artists' lyrics."
          : "Sound natural and warm, as if leaving a voice note. You may use [laughs] or [sighs] once if it fits.",
        "If he says 'say it' or 'say that', speak your previous message to him.",
        `Under ${VOICE_NOTE_MAX_CHARS - 40} characters. No emoji, no markdown, no URLs, no stage directions other than the tags above.`,
      ].join("\n"),
    },
  ];
  for (const turn of history.slice(-8)) {
    if ((turn.role === "user" || turn.role === "assistant") && turn.body) messages.push({ role: turn.role, content: turn.body });
  }
  if (!history.length || history[history.length - 1]?.body !== request) messages.push({ role: "user", content: request });
  const tidy = (raw: string): string =>
    raw.replace(/https?:\/\/\S+/gi, " ").replace(/[*_#`"]+/g, "").replace(/\s+/g, " ").trim();
  const first = await completeChat(env, messages, null, { timeoutMs: 8_000, budgetMs: 12_000, maxTokens: 900 });
  let script = first.ok ? tidy(first.message.content ?? "") : "";
  if (!script || refusal(script)) {
    // Some models refuse a bare "send me a voice note". Ask again plainly, without the history.
    const retry = await completeChat(
      env,
      [
        messages[0] as ChatMessage,
        { role: "user", content: `Write the short, friendly voice note JARVIS sends Sir for this request: "${request.slice(0, 200)}"` },
      ],
      null,
      { timeoutMs: 6_000, budgetMs: 8_000, maxTokens: 900 },
    );
    const second = retry.ok ? tidy(retry.message.content ?? "") : "";
    script = second && !refusal(second) ? second : "";
  }
  if (!script) script = explicitWords(request) ?? "Good evening, Sir. JARVIS here, just checking in. Text me any time.";
  return script.slice(0, VOICE_NOTE_MAX_CHARS);
}

export function refusal(text: string): boolean {
  return /\b(?:can(?:no|'|’)t|unable to|won't) (?:comply|help with|assist with|do that)|I'm sorry,? (?:Sir,? )?but I can|as an AI\b/i.test(text);
}

/** "voice note saying good night" -> "Good night, Sir." */
export function explicitWords(request: string): string | null {
  const match = /\b(?:saying|that says|to say|say)\s+(.{2,300})$/i.exec(request.trim());
  const words = (match?.[1] ?? "").replace(/[.?!]+$/, "").trim();
  if (!words || /^(?:it|that|this|something)\b/i.test(words)) return null;
  return `${words.charAt(0).toUpperCase()}${words.slice(1)}, Sir.`;
}

async function elevenAudio(env: Env, url: string, body: Record<string, unknown>): Promise<{ ok: true; bytes: Uint8Array } | { ok: false; error: string; status: number }> {
  const key = (env.ELEVENLABS_API_KEY ?? "").trim();
  if (!key) return { ok: false, error: "ElevenLabs is not set up", status: 0 };
  try {
    const response = await fetch(url, {
      method: "POST",
      headers: { "xi-api-key": key, "content-type": "application/json", accept: "audio/mpeg" },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(20_000),
    });
    if (!response.ok) {
      const text = (await response.text()).replace(/\s+/g, " ").slice(0, 160);
      return { ok: false, error: `ElevenLabs HTTP ${response.status}: ${text}`, status: response.status };
    }
    const bytes = new Uint8Array(await response.arrayBuffer());
    if (bytes.length < 2_000) return { ok: false, error: "ElevenLabs returned almost no audio", status: 200 };
    return { ok: true, bytes };
  } catch (err) {
    return { ok: false, error: err instanceof Error ? err.message : "ElevenLabs unreachable", status: 0 };
  }
}

/** George speaking. eleven_v3 understands audio tags; v2 is the fallback with the tags removed. */
export async function speak(env: Env, script: string, singing: boolean): Promise<{ ok: true; bytes: Uint8Array; chars: number } | { ok: false; error: string }> {
  const base = `https://api.elevenlabs.io/v1/text-to-speech/${GEORGE_VOICE_ID}?output_format=mp3_44100_64`;
  const tagged = script.slice(0, VOICE_NOTE_MAX_CHARS);
  const first = await elevenAudio(env, base, { text: tagged, model_id: "eleven_v3" });
  if (first.ok) return { ok: true, bytes: first.bytes, chars: tagged.length };
  const plain = stripTags(tagged);
  const second = await elevenAudio(env, base, {
    text: plain,
    model_id: "eleven_multilingual_v2",
    voice_settings: { stability: singing ? 0.3 : 0.5, similarity_boost: 0.8, style: singing ? 0.6 : 0.2 },
  });
  if (second.ok) return { ok: true, bytes: second.bytes, chars: plain.length };
  return { ok: false, error: `${first.error} | ${second.error}` };
}

/** A real generated sound, so a beatbox is a beatbox and not George saying "boots and cats". */
export async function soundClip(
  env: Env,
  prompt: string,
  opts: { seconds?: number; model?: string; influence?: number } = {},
): Promise<{ ok: true; bytes: Uint8Array } | { ok: false; error: string }> {
  const result = await elevenAudio(env, "https://api.elevenlabs.io/v1/sound-generation?output_format=mp3_44100_64", {
    text: prompt.slice(0, 450),
    duration_seconds: opts.seconds ?? SOUND_SECONDS,
    prompt_influence: opts.influence ?? 0.6,
    model_id: opts.model ?? "eleven_text_to_sound_v2",
  });
  return result.ok ? result : { ok: false, error: result.error };
}

export async function makeVoiceNote(
  env: Env,
  ask: VoiceAsk,
  request: string,
  history: { role: string; body: string }[] = [],
): Promise<VoiceResult> {
  if (!(env.ELEVENLABS_API_KEY ?? "").trim()) return { ok: false, error: "no_key", reason: "my voice is not set up yet" };
  const credits = await elevenCredits(env);
  if (credits && credits.limit - credits.used < CREDIT_FLOOR) {
    return { ok: false, error: "credits_low", reason: "my voice allowance for this month is nearly used up" };
  }
  let bytes: Uint8Array;
  let chars = 0;
  let script = "";
  if (ask.kind === "beatbox" || ask.kind === "sound") {
    const beat = ask.kind === "beatbox";
    const prompt = beat ? beatboxPrompt(request) : ask.prompt;
    const seconds = beat ? BEATBOX.seconds : SOUND_SECONDS;
    const clip = await soundClip(env, prompt, beat ? { seconds, model: BEATBOX.model, influence: BEATBOX.influence } : {});
    if (!clip.ok) return { ok: false, error: clip.error, reason: "the recording did not come out" };
    bytes = clip.bytes;
    chars = seconds * 40;
    script = `[${ask.kind}] ${prompt}`.slice(0, 300);
  } else {
    script = await writeScript(env, ask, request, history);
    const spoken = await speak(env, script, ask.kind === "sing");
    if (!spoken.ok) return { ok: false, error: spoken.error, reason: "the recording did not come out" };
    bytes = spoken.bytes;
    chars = spoken.chars;
  }
  const bed = ask.style === "diss" || ask.style === "rap" ? ((await rapBeat(env).catch(() => null)) ?? "") : "";
  const note = await storeNote(env, ask.kind, bytes, chars, script, bed);
  return { ok: true, note };
}

export async function storeNote(env: Env, kind: VoiceKind, bytes: Uint8Array, chars: number, script: string, bed = ""): Promise<VoiceNote> {
  await ensureVoiceTable(env);
  const id = noteId();
  const now = new Date();
  const expires = new Date(now.getTime() + VOICE_NOTE_DAYS * 86_400_000);
  await dbRun(
    env,
    "INSERT INTO voice_notes (id, kind, mime, audio_b64, bytes, chars, script, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
    [id, kind, "audio/mpeg", toBase64(bytes), bytes.length, chars, script, now.toISOString(), expires.toISOString()],
  );
  if (bed) await dbRun(env, "UPDATE voice_notes SET bed = ? WHERE id = ?", [bed, id]).catch(() => 0);
  await noteUsage(env, chars);
  const url = `${await noteOrigin(env)}/v/${id}`;
  return { id, url, kind, chars, bytes: bytes.length, script };
}

/** Beatbox candidates for the listening check. Each run costs about 1,100 ElevenLabs credits. */
export async function voiceLab(env: Env): Promise<{ label: string; url: string; bytes: number; chars: number; error: string }[]> {
  const prompt = beatboxPrompt("");
  const out: { label: string; url: string; bytes: number; chars: number; error: string }[] = [];
  const sfx = [
    { label: "sfx-v2-12s", model: "eleven_text_to_sound_v2", seconds: 12, influence: 0.7 },
    { label: "sfx-v3-12s", model: "eleven_text_to_sound_v3", seconds: 12, influence: 0.7 },
  ];
  for (const c of sfx) {
    const clip = await soundClip(env, prompt, c);
    if (!clip.ok) {
      out.push({ label: c.label, url: "", bytes: 0, chars: 0, error: clip.error.slice(0, 160) });
      continue;
    }
    const note = await storeNote(env, "beatbox", clip.bytes, c.seconds * 40, `[lab ${c.label}] ${prompt}`.slice(0, 300));
    out.push({ label: c.label, url: note.url, bytes: note.bytes, chars: note.chars, error: "" });
  }
  const tagged =
    "[beatboxing] Boom, ts-k, pff-ts, boom boom, ka-tss. Boom, ts-k, pff, brrrrr, boom, ka-tss! [beatboxing] Boom ts-ts k, boom-boom pff, ts-ts-ts-ts, krr-boom!";
  const spoken = await elevenAudio(env, `https://api.elevenlabs.io/v1/text-to-speech/${GEORGE_VOICE_ID}?output_format=mp3_44100_64`, {
    text: tagged,
    model_id: "eleven_v3",
  });
  if (spoken.ok) {
    const note = await storeNote(env, "beatbox", spoken.bytes, tagged.length, "[lab tts-v3] George beatbox with audio tags");
    out.push({ label: "tts-v3", url: note.url, bytes: note.bytes, chars: note.chars, error: "" });
  } else out.push({ label: "tts-v3", url: "", bytes: 0, chars: 0, error: spoken.error.slice(0, 160) });
  return out;
}

export async function noteUrl(env: Env, id: string): Promise<string | null> {
  await ensureVoiceTable(env);
  const row = await dbFirst<{ id: string }>(env, "SELECT id FROM voice_notes WHERE id = ? AND expires_at > ?", [id, new Date().toISOString()]);
  return row ? `${await noteOrigin(env)}/v/${row.id}` : null;
}

/** The kind of the voice note a reply line announces, from its lead words. */
export function kindFromLine(line: string): VoiceKind | null {
  if (!/\/v\/[A-Za-z0-9]{20}|tap to play/i.test(line)) return null;
  if (/beatbox/i.test(line)) return "beatbox";
  if (/little number|song|rap/i.test(line)) return "sing";
  if (/your sound/i.test(line)) return "sound";
  return "speech";
}

/** A follow-up about the last voice note: another, better, again, where is it. */
export function voiceFollowUp(text: string): "again" | "resend" | null {
  const clean = text.toLowerCase().replace(/[’']/g, "").replace(/\s+/g, " ").trim();
  if (/\b(?:where is it|wheres it|where is the (?:link|beat|beatbox|song|note)|send it|send the link|no link|didnt (?:come|get|arrive|send)|not there|i cant see it|cant see (?:it|the link)|link\??$)\b/.test(clean)) return "resend";
  if (/\b(?:more|another|again|better|harder|complex|complicated|fire|redo|remix|one more|try again|do it again|cold|mid|weak|louder|faster|slower|longer|level up|step it up|go harder)\b/.test(clean)) return "again";
  return null;
}

/** A chat reply that says audio is attached or coming, which chat cannot deliver. */
export function claimsAudio(text: string): boolean {
  const t = text.trim();
  if (/\b(?:here(?:'s| is|’s)|i(?:'ve| have) (?:made|recorded|got)|sending|coming (?:up|right up))\b.{0,50}\b(?:beatbox|beat|voice note|voice message|recording|song|rap|verse|clip|audio|track)\b/i.test(t)) return true;
  if (/\bhere it is\b/i.test(t)) return true;
  // A bare trailing colon only promises audio when the line is about audio; otherwise chatBubbles turns it into a full stop.
  return /:\s*$/.test(t) && /\b(?:beat ?box|beat|voice|recording|song|rap|verse|clip|audio|track|listen)\b/i.test(t);
}

/** The voice kind a chat line talks about, if any. */
export function kindFromText(text: string): VoiceKind | null {
  if (/beat ?box|beat\b/i.test(text)) return "beatbox";
  if (/\b(?:song|sing|rap|verse)\b/i.test(text)) return "sing";
  if (/\b(?:voice (?:note|message)|recording|audio)\b/i.test(text)) return "speech";
  return null;
}

async function noteUsage(env: Env, chars: number): Promise<void> {
  const month = new Date().toISOString().slice(0, 7);
  const key = `voice_chars:${month}`;
  const prior = Number((await getState(env, key).catch(() => null)) ?? 0) || 0;
  await setState(env, key, String(prior + chars)).catch(() => undefined);
}

/** One line in persona, then the link. */
export function noteLine(ask: VoiceAsk, url: string): string {
  const lead =
    ask.style === "roast"
      ? "Roast incoming, Sir. Brace yourself. Tap to play:"
      : ask.style === "hype"
        ? "Hype, as requested, Sir. Volume up. Tap to play:"
        : ask.style === "diss"
          ? "Diss track, fresh off the desk, Sir. Volume up. Tap to play:"
          : ask.style === "rap"
            ? "Bars over a beat, Sir. Tap to play:"
            : ask.kind === "beatbox"
      ? "Beatbox, as requested, Sir. Tap to play:"
      : ask.kind === "sing"
        ? "A little number for you, Sir. Tap to play:"
        : ask.kind === "sound"
          ? "Your sound, Sir. Tap to play:"
          : "Voice note for you, Sir. Tap to play:";
  return `${lead} ${url}`;
}

export function noteFailure(result: VoiceResult): string {
  return `I couldn't make that voice note just now, Sir: ${result.reason ?? "the recording did not come out"}. Nothing was charged to you.`;
}

/** Rings Sir's own number and plays the note. Only ever called on his explicit request, only to his number. */
export async function callOwnerWithNote(env: Env, owner: string, url: string): Promise<{ ok: boolean; sid: string; error: string }> {
  return callAndPlay(env, owner, `<Response><Pause length="1"/><Play>${escapeXml(`${url}.mp3`)}</Play></Response>`);
}

/** Places a call that plays fixed TwiML. Callers decide who may be rung; this only dials. */
export async function callAndPlay(
  env: Env,
  to: string,
  twiml: string,
  timeLimit = 0,
): Promise<{ ok: boolean; sid: string; error: string }> {
  const owner = to;
  const account = (env.TWILIO_ACCOUNT_SID ?? "").trim();
  const token = (env.TWILIO_AUTH_TOKEN ?? "").trim();
  const from = (env.TWILIO_FROM_NUMBER ?? "").trim();
  if (!account || !token || !from || !owner) return { ok: false, sid: "", error: "calling is not set up" };
  try {
    const response = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(account)}/Calls.json`, {
      method: "POST",
      redirect: "manual",
      signal: AbortSignal.timeout(15_000),
      headers: { authorization: `Basic ${btoa(`${account}:${token}`)}`, "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ To: owner, From: from, Twiml: twiml, Timeout: "30", ...(timeLimit > 0 ? { TimeLimit: String(timeLimit) } : {}) }).toString(),
    });
    const body = (await response.json().catch(() => ({}))) as { sid?: string; message?: string };
    if (!response.ok || !body.sid) return { ok: false, sid: "", error: (body.message ?? `HTTP ${response.status}`).slice(0, 120) };
    return { ok: true, sid: body.sid, error: "" };
  } catch (err) {
    return { ok: false, sid: "", error: err instanceof Error ? err.message : "Twilio unreachable" };
  }
}

export function escapeXml(value: string): string {
  return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&apos;");
}

export function isVoiceNotePath(method: string, path: string): boolean {
  return (method === "GET" || method === "HEAD") && /^\/v\/[A-Za-z0-9]{20}(?:\.mp3)?$/.test(path);
}

/** Public, no login: the link itself is the key. Expired or unknown links get 410/404. */
export async function serveVoiceNote(request: Request, env: Env, path: string): Promise<Response> {
  const match = /^\/v\/([A-Za-z0-9]{20})(\.mp3)?$/.exec(path);
  const id = match?.[1] ?? "";
  const raw = Boolean(match?.[2]);
  await ensureVoiceTable(env).catch(() => undefined);
  const row = await dbFirst<{ kind: string; mime: string; audio_b64: string; expires_at: string; bed?: string }>(
    env,
    "SELECT kind, mime, audio_b64, expires_at, bed FROM voice_notes WHERE id = ?",
    [id],
  ).catch(() => null);
  const headers = { "x-robots-tag": "noindex, nofollow", "cache-control": "private, max-age=3600", "referrer-policy": "no-referrer" };
  if (!row) return page(404, "This voice note isn't here.", "", headers);
  if (Date.parse(row.expires_at) < Date.now()) return page(410, "This voice note has expired.", "", headers);
  if (!raw) return page(200, "A voice note from JARVIS", `/v/${id}.mp3`, headers, row.bed ? `/v/${row.bed}.mp3` : "");
  const bytes = fromBase64(row.audio_b64);
  const total = bytes.length;
  const range = /^bytes=(\d*)-(\d*)$/.exec(request.headers.get("range") ?? "");
  const base = { ...headers, "content-type": row.mime || "audio/mpeg", "accept-ranges": "bytes" };
  if (range && (range[1] || range[2])) {
    let start = range[1] ? Number(range[1]) : Math.max(0, total - Number(range[2]));
    let end = range[1] && range[2] ? Number(range[2]) : total - 1;
    end = Math.min(end, total - 1);
    start = Math.min(start, end);
    const slice = bytes.subarray(start, end + 1);
    return new Response(request.method === "HEAD" ? null : slice, {
      status: 206,
      headers: { ...base, "content-range": `bytes ${start}-${end}/${total}`, "content-length": String(slice.length) },
    });
  }
  return new Response(request.method === "HEAD" ? null : bytes, { status: 200, headers: { ...base, "content-length": String(total) } });
}

function page(status: number, title: string, src: string, headers: Record<string, string>, bed = ""): Response {
  const player = src && bed
    ? `<audio id="a" src="${src}" preload="auto" playsinline></audio><audio id="m" src="${bed}" preload="auto" loop playsinline></audio>
<button id="b">&#9654;&#xFE0E; Play</button>
<script>var a=document.getElementById('a'),m=document.getElementById('m'),b=document.getElementById('b'),c=null;
function stop(){m.pause();m.currentTime=0;a.pause();a.currentTime=0;b.innerHTML='&#9654;&#xFE0E; Play'}
b.onclick=function(){if(!a.paused){stop();return}
try{if(!c){var C=window.AudioContext||window.webkitAudioContext;c=new C();var g=c.createGain();g.gain.value=0.32;c.createMediaElementSource(m).connect(g).connect(c.destination);var v=c.createGain();v.gain.value=1;c.createMediaElementSource(a).connect(v).connect(c.destination)}c.resume()}catch(e){m.volume=0.32}
m.currentTime=0;m.play();setTimeout(function(){a.play()},1400);b.textContent='\u275A\u275A Stop'};
a.onended=function(){setTimeout(stop,1200)}</script>`
    : src
    ? `<audio id="a" src="${src}" preload="auto" controls playsinline></audio>
<button id="b" onclick="var a=document.getElementById('a');a.paused?a.play():a.pause()">&#9654;&#xFE0E; Play</button>
<script>var a=document.getElementById('a'),b=document.getElementById('b');a.onplay=function(){b.textContent='\\u275A\\u275A Pause'};a.onpause=a.onended=function(){b.innerHTML='&#9654;&#xFE0E; Play'};a.play().catch(function(){})</script>`
    : "";
  const html = `<!doctype html><html lang="en-GB"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex,nofollow"><title>JARVIS</title>
<style>body{margin:0;min-height:100vh;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:24px;background:#05070d;color:#cfe8ff;font:17px -apple-system,system-ui,sans-serif;text-align:center}h1{font-weight:500;font-size:20px;letter-spacing:.04em}.orb{width:120px;height:120px;border-radius:50%;background:radial-gradient(circle,#7fd8ff 0,#1b6fff 45%,transparent 70%);box-shadow:0 0 60px #1b6fff}button{font-size:22px;padding:16px 44px;border-radius:40px;border:1px solid #4fb6ff;background:#0b1a33;color:#e6f4ff}audio{width:280px}</style></head>
<body><div class="orb"></div><h1>${title}</h1>${player}</body></html>`;
  return new Response(html, { status, headers: { ...headers, "content-type": "text/html; charset=utf-8" } });
}

export async function sweepVoiceNotes(env: Env): Promise<void> {
  try {
    await ensureVoiceTable(env);
    await dbRun(env, "DELETE FROM voice_notes WHERE expires_at < ?", [new Date().toISOString()]);
  } catch {
    console.error("voice note sweep failed");
  }
}

export async function recentNotes(env: Env): Promise<{ id: string; kind: string; bytes: number; chars: number; created_at: string }[]> {
  await ensureVoiceTable(env);
  return dbAll(env, "SELECT id, kind, bytes, chars, created_at FROM voice_notes ORDER BY created_at DESC LIMIT 5");
}
