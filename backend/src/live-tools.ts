import type { Env } from "./types";
import { GEMINI_MODEL, GROQ_URL } from "./types";

const GEMINI_ROOT = "https://generativelanguage.googleapis.com/v1beta";
let geminiQuietUntil = 0;

/** Tests only. */
export function resetLiveSearchState(): void {
  geminiQuietUntil = 0;
}

/**
 * Live tools shared by SMS, the brain, and the personal voice agent:
 * weather for any place (Open-Meteo, no key) and a grounded web answer.
 */

const UA = "JARVIS-backend/1.0 (personal assistant; jarvis-hadi.workers.dev)";

const SKY: Record<number, string> = {
  0: "clear", 1: "mostly clear", 2: "partly cloudy", 3: "overcast", 45: "foggy", 48: "foggy",
  51: "light drizzle", 53: "drizzle", 55: "heavy drizzle", 56: "freezing drizzle", 57: "freezing drizzle",
  61: "light rain", 63: "rain", 65: "heavy rain", 66: "freezing rain", 67: "freezing rain",
  71: "light snow", 73: "snow", 75: "heavy snow", 77: "snow grains", 80: "showers", 81: "showers", 82: "heavy showers",
  85: "snow showers", 86: "heavy snow showers", 95: "thunderstorms", 96: "thunderstorms with hail", 99: "thunderstorms with hail",
};

export interface Place {
  name: string;
  lat: number;
  lon: number;
  country: string;
  timezone: string;
}

export interface WeatherAnswer {
  ok: boolean;
  place: string;
  text: string;
  error?: string;
}

const DEFAULT_PLACE = "Ashford, Kent";

/** Open-Meteo geocoding. UK first when a name is ambiguous ("Ashford" means Ashford, Kent). */
export async function geocode(raw: string, fetcher: typeof fetch = fetch): Promise<Place | null> {
  const query = raw.replace(/\s+/g, " ").trim();
  if (!query) return null;
  const parts = query.split(",").map((p) => p.trim()).filter(Boolean);
  const head = parts[0] ?? query;
  const hint = parts.slice(1).join(" ").toLowerCase();
  const url = `https://geocoding-api.open-meteo.com/v1/search?name=${encodeURIComponent(head)}&count=10&language=en&format=json`;
  try {
    const response = await fetcher(url, { headers: { "user-agent": UA }, signal: AbortSignal.timeout(6_000) });
    if (!response.ok) return null;
    const body = (await response.json()) as {
      results?: { name?: string; latitude?: number; longitude?: number; country?: string; country_code?: string; admin1?: string; admin2?: string; timezone?: string; population?: number }[];
    };
    const results = (body.results ?? []).filter((r) => Number.isFinite(r.latitude) && Number.isFinite(r.longitude));
    if (!results.length) return null;
    const score = (r: (typeof results)[number]) => {
      const where = `${r.admin1 ?? ""} ${r.admin2 ?? ""} ${r.country ?? ""} ${r.country_code ?? ""}`.toLowerCase();
      let s = 0;
      if (hint && hint.split(/\s+/).every((w) => where.includes(w))) s += 100;
      if (!hint && r.country_code === "GB") s += 50;
      if (!hint && /ashford/i.test(head) && /kent/i.test(where)) s += 30;
      s += Math.min(20, Math.log10((r.population ?? 0) + 1) * 3);
      return s;
    };
    const best = [...results].sort((a, b) => score(b) - score(a))[0]!;
    const region = best.country_code === "GB" ? best.admin2 || best.admin1 : best.country;
    return {
      name: region && region !== best.name ? `${best.name}, ${region}` : String(best.name),
      lat: Number(best.latitude),
      lon: Number(best.longitude),
      country: best.country_code ?? "",
      timezone: best.timezone || "auto",
    };
  } catch {
    return null;
  }
}

/** Which forecast day a phrase means: 0 today, 1 tomorrow, a weekday name, or "weekend"/"week" for several days. */
export function forecastDays(when: string, now = new Date()): { start: number; count: number; label: string } {
  const w = when.toLowerCase();
  if (/\bweek\b|\bnext (?:few|several) days\b|\b7 days?\b/.test(w)) return { start: 0, count: 7, label: "this week" };
  if (/\bweekend\b/.test(w)) {
    const dow = londonDow(now);
    const toSat = (6 - dow + 7) % 7;
    return { start: toSat, count: 2, label: "this weekend" };
  }
  if (/\btomorrow\b/.test(w)) return { start: 1, count: 1, label: "tomorrow" };
  const names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"];
  const found = names.findIndex((n) => new RegExp(`\\b${n.slice(0, 3)}(?:${n.slice(3)})?\\b`).test(w));
  if (found >= 0) {
    const ahead = (found - londonDow(now) + 7) % 7;
    return { start: ahead, count: 1, label: ahead === 0 ? "today" : names[found]!.replace(/^./, (c) => c.toUpperCase()) };
  }
  return { start: 0, count: 1, label: "today" };
}

function londonDow(now: Date): number {
  const short = new Intl.DateTimeFormat("en-GB", { timeZone: "Europe/London", weekday: "short" }).format(now);
  return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].indexOf(short);
}

/** Current conditions plus the forecast for the day(s) asked, in one or two spoken sentences. */
export async function weatherFor(placeRaw: string, when = "", fetcher: typeof fetch = fetch, now = new Date()): Promise<WeatherAnswer> {
  const placeName = placeRaw.trim() || DEFAULT_PLACE;
  const place = await geocode(placeName, fetcher);
  if (!place) return { ok: false, place: placeName, text: `I couldn't find a place called ${placeName}, Sir.`, error: "geocode" };
  const span = forecastDays(when, now);
  const url =
    `https://api.open-meteo.com/v1/forecast?latitude=${place.lat}&longitude=${place.lon}` +
    "&current=temperature_2m,apparent_temperature,weather_code,wind_speed_10m" +
    "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,wind_speed_10m_max" +
    `&timezone=${encodeURIComponent(place.timezone)}&forecast_days=${Math.min(16, Math.max(2, span.start + span.count))}&wind_speed_unit=mph`;
  try {
    const response = await fetcher(url, { headers: { "user-agent": UA }, signal: AbortSignal.timeout(6_000) });
    if (!response.ok) return { ok: false, place: place.name, text: "The weather service didn't answer, Sir. Try again in a minute.", error: `http ${response.status}` };
    const body = (await response.json()) as {
      current?: { temperature_2m?: number; apparent_temperature?: number; weather_code?: number; wind_speed_10m?: number };
      daily?: {
        time?: string[];
        weather_code?: number[];
        temperature_2m_max?: number[];
        temperature_2m_min?: number[];
        precipitation_probability_max?: number[];
        wind_speed_10m_max?: number[];
      };
    };
    const r = (n: unknown) => Math.round(Number(n));
    const d = body.daily ?? {};
    const day = (i: number) => {
      const hi = r(d.temperature_2m_max?.[i]);
      const lo = r(d.temperature_2m_min?.[i]);
      if (!Number.isFinite(hi)) return "";
      const rain = Number(d.precipitation_probability_max?.[i]);
      const sky = SKY[Number(d.weather_code?.[i])] ?? "mixed";
      return `${sky}, high ${hi}C, low ${lo}C${Number.isFinite(rain) ? `, ${Math.round(rain)}% chance of rain` : ""}`;
    };
    const parts: string[] = [];
    if (span.start === 0 && body.current && Number.isFinite(Number(body.current.temperature_2m))) {
      const c = body.current;
      parts.push(
        `${place.name} right now: ${r(c.temperature_2m)}C, ${SKY[Number(c.weather_code)] ?? "mixed"}` +
          `${Number.isFinite(Number(c.apparent_temperature)) && Math.abs(r(c.apparent_temperature) - r(c.temperature_2m)) >= 2 ? `, feels like ${r(c.apparent_temperature)}C` : ""}` +
          `${Number.isFinite(Number(c.wind_speed_10m)) ? `, wind ${r(c.wind_speed_10m)} mph` : ""}.`,
      );
    }
    if (span.count === 1) {
      const line = day(span.start);
      if (line) parts.push(`${span.start === 0 ? "Today" : span.label.replace(/^./, (c) => c.toUpperCase())}${span.start === 0 ? "" : ` in ${place.name}`}: ${line}.`);
    } else {
      const days: string[] = [];
      for (let i = span.start; i < span.start + span.count; i++) {
        const iso = d.time?.[i];
        const name = iso ? new Intl.DateTimeFormat("en-GB", { weekday: "short", timeZone: "UTC" }).format(new Date(`${iso}T12:00:00Z`)) : `Day ${i}`;
        const hi = r(d.temperature_2m_max?.[i]);
        if (!Number.isFinite(hi)) continue;
        days.push(`${name} ${SKY[Number(d.weather_code?.[i])] ?? "mixed"} ${hi}C`);
      }
      if (days.length) parts.push(`${place.name} ${span.label}: ${days.join("; ")}.`);
    }
    if (!parts.length) return { ok: false, place: place.name, text: "The weather service didn't answer, Sir.", error: "empty" };
    return { ok: true, place: place.name, text: parts.join(" ") };
  } catch (err) {
    return { ok: false, place: place.name, text: "The weather service didn't answer, Sir. Try again in a minute.", error: err instanceof Error ? err.message : "network" };
  }
}

/** Pull "weather in X tomorrow" apart. Null when the text is not about the weather. */
export function weatherAsk(text: string): { place: string; when: string } | null {
  const clean = text.replace(/\s+/g, " ").trim().replace(/[?!.]+$/, "");
  if (!/\b(weather|forecast|temperature|rain(?:ing)?|snow(?:ing)?|sunny|umbrella|how (?:hot|cold|warm))\b/i.test(clean)) return null;
  if (clean.length > 120) return null;
  if (/\b(remind|watch|ring|call|text|prank|song|rap|poem)\b/i.test(clean)) return null;
  const whenMatch = clean.match(/\b(today|tonight|tomorrow|this weekend|weekend|this week|next few days|(?:on )?(?:mon|tues?|wed(?:nes)?|thu(?:rs)?|fri|sat(?:ur)?|sun)(?:day)?)\b/i);
  const when = whenMatch ? whenMatch[1]! : "";
  let place = "";
  const at = clean.match(/\b(?:in|for|at|near|over)\s+([A-Za-z][A-Za-z .'-]*(?:,\s*[A-Za-z .'-]+)?)/i);
  if (at) place = at[1]!;
  else {
    const lead = clean.match(/^([A-Za-z][A-Za-z .'-]+?)\s+(?:weather|forecast)\b/i);
    if (lead && !/^(?:the|what'?s|whats|how'?s|hows|what is|how is|is|will)\b/i.test(lead[1]!)) place = lead[1]!;
  }
  place = place
    .replace(/\b(today|tonight|tomorrow|this weekend|weekend|this week|next few days|the|(?:on )?(?:mon|tues?|wed(?:nes)?|thu(?:rs)?|fri|sat(?:ur)?|sun)(?:day)?)\b/gi, " ")
    .replace(/\b(weather|forecast|like|be|going|to|it|will|is)\b/gi, " ")
    .replace(/\s+/g, " ")
    .trim()
    .replace(/[,\s]+$/, "");
  return { place, when };
}

// ---------------------------------------------------------------- grounded search

export interface LiveAnswer {
  ok: boolean;
  provider: "gemini" | "groq" | "search" | "";
  answer: string;
  sources: string[];
  error?: string;
}

const ANSWER_RULES =
  "Search the web, then answer in at most three short plain sentences for a British listener. Give the concrete fact (name, date, score, price, or UK phone number) first. No markdown, no URLs, no citation marks. If you could not find it, say so.";

/** Strip model citation marks such as 【3†L4-L8】 and [1]. */
export function stripCitations(text: string): string {
  return text
    .replace(/【[^】]*】/g, "")
    .replace(/\[(?:\d+(?:,\s*\d+)*)\]/g, "")
    .replace(/\*\*/g, "")
    .replace(/^[\s>*-]+/gm, "")
    .replace(/[ \t]+/g, " ")
    .replace(/\s+([.,;:])/g, "$1")
    .trim();
}

/**
 * A grounded answer from the live web. Order: Gemini Google Search grounding on GEMINI_API_KEY,
 * then Groq's built-in browser search on GROQ_API_KEY, then plain search hits.
 */
export async function liveSearch(env: Env, query: string, fetcher: typeof fetch = fetch): Promise<LiveAnswer> {
  const q = query.replace(/\s+/g, " ").trim().slice(0, 300);
  if (!q) return { ok: false, provider: "", answer: "", sources: [], error: "empty query" };
  const errors: string[] = [];
  const gemini = (env.GEMINI_API_KEY ?? "").trim();
  if (gemini) {
    const got = await geminiGrounded(gemini, q, fetcher).catch((err) => ({ ok: false as const, error: String(err) }));
    if (got.ok) return got;
    errors.push(`gemini: ${got.error}`);
  }
  const groq = (env.GROQ_API_KEY ?? "").trim();
  if (groq) {
    const got = await groqBrowser(groq, q, fetcher).catch((err) => ({ ok: false as const, error: String(err) }));
    if (got.ok) return got;
    errors.push(`groq: ${got.error}`);
  }
  try {
    const { webSearch } = await import("./search");
    const found = await webSearch(env, q);
    if (found.ok && found.results.length) {
      const top = found.results.slice(0, 3);
      return {
        ok: true,
        provider: "search",
        answer: top.map((r) => `${r.title}: ${r.snippet}`).join(" ").slice(0, 600),
        sources: top.map((r) => r.url),
      };
    }
    errors.push(`search: ${found.ok ? "no results" : found.error}`);
  } catch (err) {
    errors.push(`search: ${err instanceof Error ? err.message : "failed"}`);
  }
  console.warn("live search failed", errors.join(" | ").slice(0, 400));
  return { ok: false, provider: "", answer: "", sources: [], error: errors.join(" | ").slice(0, 400) };
}

async function geminiGrounded(key: string, q: string, fetcher: typeof fetch): Promise<LiveAnswer | { ok: false; error: string }> {
  if (Date.now() < geminiQuietUntil) return { ok: false, error: "grounding unavailable (recent 429)" };
  const response = await fetcher(`${GEMINI_ROOT}/models/${GEMINI_MODEL}:generateContent`, {
    method: "POST",
    signal: AbortSignal.timeout(8_000),
    headers: { "x-goog-api-key": key, "content-type": "application/json" },
    body: JSON.stringify({
      contents: [{ role: "user", parts: [{ text: `${ANSWER_RULES}\n\nQuestion: ${q}` }] }],
      tools: [{ google_search: {} }],
    }),
  });
  if (!response.ok) {
    // 429 here means Google Search grounding has no quota on this key (free tier). Skip it for a while.
    if (response.status === 429 || response.status === 403) geminiQuietUntil = Date.now() + 15 * 60_000;
    return { ok: false, error: `http ${response.status}` };
  }
  const body = (await response.json()) as {
    candidates?: { content?: { parts?: { text?: string }[] }; groundingMetadata?: { groundingChunks?: { web?: { title?: string; uri?: string } }[] } }[];
  };
  const c = body.candidates?.[0];
  const text = stripCitations((c?.content?.parts ?? []).map((p) => p.text ?? "").join(""));
  if (!text) return { ok: false, error: "empty" };
  const sources = (c?.groundingMetadata?.groundingChunks ?? []).map((g) => g.web?.title ?? "").filter(Boolean).slice(0, 4);
  return { ok: true, provider: "gemini", answer: text.slice(0, 700), sources };
}

/** Each Groq model has its own daily token allowance: when the small one is spent, the large one answers. */
const GROQ_SEARCH_MODELS = ["openai/gpt-oss-20b", "openai/gpt-oss-120b"];

async function groqBrowser(key: string, q: string, fetcher: typeof fetch): Promise<LiveAnswer | { ok: false; error: string }> {
  const errors: string[] = [];
  for (const model of GROQ_SEARCH_MODELS) {
    const got = await groqBrowserModel(key, q, fetcher, model);
    if (got.ok) return got;
    errors.push(`${model}: ${got.error}`);
    if (!/http (?:429|503|500|413)/.test(got.error)) break;
  }
  return { ok: false, error: errors.join("; ") };
}

async function groqBrowserModel(key: string, q: string, fetcher: typeof fetch, model: string): Promise<LiveAnswer | { ok: false; error: string }> {
  const response = await fetcher(GROQ_URL, {
    method: "POST",
    signal: AbortSignal.timeout(22_000),
    headers: { authorization: `Bearer ${key}`, "content-type": "application/json" },
    body: JSON.stringify({
      model,
      tools: [{ type: "browser_search" }],
      tool_choice: "required",
      temperature: 0.2,
      max_completion_tokens: 900,
      messages: [
        { role: "system", content: `${ANSWER_RULES} Today is ${new Date().toISOString().slice(0, 10)}.` },
        { role: "user", content: q },
      ],
    }),
  });
  if (!response.ok) return { ok: false, error: `http ${response.status}` };
  const body = (await response.json()) as {
    choices?: { message?: { content?: string; executed_tools?: { search_results?: { results?: { title?: string; url?: string }[] } }[] } }[];
  };
  const message = body.choices?.[0]?.message;
  const text = stripCitations(message?.content ?? "");
  if (!text) return { ok: false, error: "empty" };
  const sources: string[] = [];
  for (const t of message?.executed_tools ?? []) {
    for (const r of t.search_results?.results ?? []) {
      if (r.url && !sources.includes(r.url)) sources.push(r.url);
    }
  }
  return { ok: true, provider: "groq", answer: text.slice(0, 700), sources: sources.slice(0, 4) };
}

/** Questions that need today's web, not the model's memory. */
export function currentFactAsk(text: string): boolean {
  const t = text.trim();
  if (t.length > 200 || t.length < 8) return false;
  if (/^(?:ring|call|phone|text|remind|watch|prank|stop|start)\b/i.test(t)) return false;
  if (/\b(?:my|me|i|you|your|jarvis|sir|call|calls|reminder|reminders|text|texts|watch|watches)\b/i.test(t)) return false;
  return (
    /\b(?:who won|who is winning|what(?:'s| is) the score|latest|last (?:race|game|match|night)|tonight'?s|today'?s|this week'?s|news|headlines|results?|fixtures?|kick ?off|opening (?:hours|times)|open (?:now|today|until)|price of|how much (?:is|does|are)|exchange rate|share price|stock price)\b/i.test(t) ||
    /\b(?:f1|formula (?:1|one)|premier league|champions league|grand prix|election)\b/i.test(t)
  );
}
