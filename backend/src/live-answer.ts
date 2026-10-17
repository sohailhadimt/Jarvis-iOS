import { webSearch } from "./search";
import type { Env } from "./types";
import { GEMINI_MODEL } from "./types";

export type LiveKind = "weather" | "news" | "local" | "facts";

export interface LiveFix {
  lat: number;
  lon: number;
}

export interface LiveGathered {
  kind: LiveKind;
  /** A spoken answer, when grounding or the weather reading is already enough. */
  reply: string | null;
  /** Notes for a second model pass. No URLs. */
  notes: string;
}

const ANSWER_RULE =
  "Answer in one or two spoken sentences. Give the fact itself. Do not say you will search, look it up, or check. Do not read coordinates, URLs, or a list of links.";

export function liveQueryKind(text: string): LiveKind | null {
  const lower = text.toLowerCase();
  if (includesAny(lower, ["weather", "forecast", "raining", "temperature", "umbrella"])) return "weather";
  if (includesAny(lower, ["near me", "nearby", "around here", "closest", "nearest", "where can i", "open now"])) {
    return "local";
  }
  if (includesAny(lower, ["news", "headline", "headlines", "what's happening", "whats happening"])) return "news";
  if (
    includesAny(lower, [
      "who is",
      "who's",
      "who was",
      "who are",
      "where is",
      "where's",
      "capital of",
      "when is",
      "when did",
      "price of",
      "how much",
      "stock price",
      "share price",
      "who won",
      "score",
      "prime minister",
      "president",
    ])
  ) {
    return "facts";
  }
  return null;
}

export function readFix(value: unknown): LiveFix | null {
  if (!value || typeof value !== "object") return null;
  const record = value as { lat?: unknown; lon?: unknown };
  const lat = typeof record.lat === "number" ? record.lat : Number(record.lat);
  const lon = typeof record.lon === "number" ? record.lon : Number(record.lon);
  if (!Number.isFinite(lat) || !Number.isFinite(lon)) return null;
  if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return null;
  return { lat, lon };
}

export async function gatherLive(env: Env, question: string, fix: LiveFix | null): Promise<LiveGathered | null> {
  const kind = liveQueryKind(question);
  if (!kind) return null;
  const weather = kind === "weather" || kind === "local" ? await readWeather(fix) : null;
  const where = fix
    ? `The user is at latitude ${fix.lat.toFixed(3)}, longitude ${fix.lon.toFixed(3)}. Do not read the coordinates aloud.`
    : "No location was provided. If the question needs where the user is, say you do not have it. Do not invent a city.";
  const observed = weather ? `Observed weather: ${weather}.` : "";
  const grounded = await geminiGround(env, question, `${where}\n${observed}`.trim());
  if (grounded) return { kind, reply: grounded, notes: "" };
  const searched = await searchNotes(env, question);
  const notes = [observed, searched].filter((line) => line.length > 0).join("\n");
  if (kind === "weather" && weather) {
    return { kind, reply: `It's ${weather} where you are, sir.`, notes };
  }
  return { kind, reply: null, notes };
}

function includesAny(text: string, needles: string[]): boolean {
  return needles.some((needle) => text.includes(needle));
}

async function readWeather(fix: LiveFix | null): Promise<string | null> {
  if (!fix) return null;
  const params = new URLSearchParams({
    latitude: String(fix.lat),
    longitude: String(fix.lon),
    current: "temperature_2m,weather_code",
    daily: "temperature_2m_max,temperature_2m_min",
    forecast_days: "1",
    timezone: "auto",
  });
  try {
    const response = await fetch(`https://api.open-meteo.com/v1/forecast?${params.toString()}`, {
      signal: AbortSignal.timeout(4_000),
    });
    if (!response.ok) return null;
    const body = (await response.json()) as {
      current?: { temperature_2m?: number; weather_code?: number };
      daily?: { temperature_2m_max?: number[]; temperature_2m_min?: number[] };
    };
    const temp = body.current?.temperature_2m;
    if (typeof temp !== "number" || !Number.isFinite(temp)) return null;
    const code = typeof body.current?.weather_code === "number" ? body.current.weather_code : 0;
    const high = body.daily?.temperature_2m_max?.[0];
    const low = body.daily?.temperature_2m_min?.[0];
    let line = `${Math.round(temp)} degrees and ${weatherWord(code)}`;
    if (typeof high === "number" && typeof low === "number") {
      line += `, high ${Math.round(high)}, low ${Math.round(low)}`;
    }
    return line;
  } catch {
    return null;
  }
}

function weatherWord(code: number): string {
  if (code === 0) return "clear";
  if (code === 1 || code === 2) return "fair";
  if (code === 3) return "cloudy";
  if (code === 45 || code === 48) return "foggy";
  if (code >= 51 && code <= 57) return "drizzle";
  if ((code >= 61 && code <= 65) || (code >= 80 && code <= 82)) return "rain";
  if ((code >= 71 && code <= 77) || code === 85 || code === 86) return "snow";
  if (code >= 95) return "storms";
  return "unsettled";
}

async function geminiGround(env: Env, question: string, context: string): Promise<string | null> {
  if (!env.GEMINI_API_KEY) return null;
  const url = `https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent`;
  const asked = context ? `${context}\n\nQuestion: ${question}` : question;
  try {
    const response = await fetch(url, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-goog-api-key": env.GEMINI_API_KEY,
      },
      body: JSON.stringify({
        systemInstruction: { parts: [{ text: ANSWER_RULE }] },
        contents: [{ role: "user", parts: [{ text: asked }] }],
        tools: [{ google_search: {} }],
        generationConfig: { temperature: 0.2, maxOutputTokens: 300 },
      }),
      signal: AbortSignal.timeout(12_000),
    });
    if (!response.ok) return null;
    const body = (await response.json()) as {
      candidates?: { content?: { parts?: { text?: string }[] } }[];
    };
    const parts = body.candidates?.[0]?.content?.parts ?? [];
    const text = parts.map((part) => part.text ?? "").join("").trim();
    return spokenAnswer(text);
  } catch {
    return null;
  }
}

async function searchNotes(env: Env, question: string): Promise<string> {
  const found = await webSearch(env, question);
  if (!found.ok || found.results.length === 0) return "";
  return found.results
    .slice(0, 4)
    .map((hit) => {
      const snippet = hit.snippet.replace(/https?:\/\/\S+/gi, "").trim();
      return snippet ? `${hit.title}: ${snippet}` : hit.title;
    })
    .filter((line) => line.length > 0)
    .join("\n");
}

export function spokenAnswer(raw: string): string | null {
  let text = raw
    .replace(/https?:\/\/\S+/gi, " ")
    .replace(/\[[^\]]*\]\([^)]*\)/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  if (!text || isSearchPromise(text)) return null;
  const sentences = text.split(/(?<=[.!?])\s+/).slice(0, 3);
  text = sentences.join(" ").trim();
  if (text.length < 2) return null;
  if (text.length > 500) text = text.slice(0, 500).trim();
  return text;
}

function isSearchPromise(text: string): boolean {
  if (text.length >= 140) return false;
  const lower = text.toLowerCase();
  const starts =
    lower.startsWith("i'll") ||
    lower.startsWith("i will") ||
    lower.startsWith("let me") ||
    lower.startsWith("i'm going to") ||
    lower.startsWith("i am going to");
  if (!starts) return false;
  return (
    lower.includes("search") ||
    lower.includes("look that up") ||
    lower.includes("look it up") ||
    lower.includes("look this up") ||
    lower.includes("google")
  );
}
