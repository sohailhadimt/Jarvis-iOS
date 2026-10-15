import { htmlToText, parseDuckDuckGoHtml, type SearchHit } from "./html";
import { parsePublicHttpUrl } from "./sources";
import type { Env } from "./types";
import { LIMITS } from "./types";

export interface SearchSuccess {
  ok: true;
  provider: "tavily" | "brave" | "duckduckgo";
  query: string;
  results: SearchHit[];
  note: string;
}

export interface SearchFailure {
  ok: false;
  error: string;
  attempted: string[];
}

const SEARCH_NOTE =
  "These are search hits, not verified facts. Open a URL with fetch_url before stating what the page says, and pass that page URL to save_finding.";

export async function webSearch(env: Env, query: string): Promise<SearchSuccess | SearchFailure> {
  const trimmed = query.trim();
  if (!trimmed) return { ok: false, error: "query is required.", attempted: [] };
  if (trimmed.length > 300) return { ok: false, error: "query is too long.", attempted: [] };
  const attempted: string[] = [];

  if (env.TAVILY_API_KEY) {
    attempted.push("tavily");
    const tavily = await searchTavily(env.TAVILY_API_KEY, trimmed);
    if (tavily.ok) return tavily;
    attempted.push(`tavily failed: ${tavily.error}`);
  }
  if (env.BRAVE_API_KEY) {
    attempted.push("brave");
    const brave = await searchBrave(env.BRAVE_API_KEY, trimmed);
    if (brave.ok) return brave;
    attempted.push(`brave failed: ${brave.error}`);
  }
  attempted.push("duckduckgo");
  const duck = await searchDuckDuckGo(trimmed);
  if (duck.ok) return duck;
  return {
    ok: false,
    error: duck.error,
    attempted,
  };
}

async function searchTavily(apiKey: string, query: string): Promise<SearchSuccess | { ok: false; error: string }> {
  try {
    const response = await fetch("https://api.tavily.com/search", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        api_key: apiKey,
        query,
        max_results: 5,
        include_answer: false,
        search_depth: "basic",
      }),
      signal: AbortSignal.timeout(LIMITS.fetchTimeoutMs),
    });
    const text = await response.text();
    if (!response.ok) return { ok: false, error: `HTTP ${response.status}: ${text.slice(0, 240)}` };
    const body = JSON.parse(text) as { results?: { title?: string; url?: string; content?: string }[] };
    const results = (body.results ?? [])
      .map((item) => toHit(item.title, item.url, item.content))
      .filter((item): item is SearchHit => item !== null);
    return { ok: true, provider: "tavily", query, results, note: SEARCH_NOTE };
  } catch (err) {
    return { ok: false, error: err instanceof Error ? err.message : "Tavily request failed." };
  }
}

async function searchBrave(apiKey: string, query: string): Promise<SearchSuccess | { ok: false; error: string }> {
  try {
    const url = `https://api.search.brave.com/res/v1/web/search?q=${encodeURIComponent(query)}&count=5`;
    const response = await fetch(url, {
      headers: {
        accept: "application/json",
        "x-subscription-token": apiKey,
      },
      signal: AbortSignal.timeout(LIMITS.fetchTimeoutMs),
    });
    const text = await response.text();
    if (!response.ok) return { ok: false, error: `HTTP ${response.status}: ${text.slice(0, 240)}` };
    const body = JSON.parse(text) as {
      web?: { results?: { title?: string; url?: string; description?: string }[] };
    };
    const results = (body.web?.results ?? [])
      .map((item) => toHit(item.title, item.url, item.description))
      .filter((item): item is SearchHit => item !== null);
    return { ok: true, provider: "brave", query, results, note: SEARCH_NOTE };
  } catch (err) {
    return { ok: false, error: err instanceof Error ? err.message : "Brave request failed." };
  }
}

async function searchDuckDuckGo(query: string): Promise<SearchSuccess | { ok: false; error: string }> {
  const url = `https://html.duckduckgo.com/html/?q=${encodeURIComponent(query)}`;
  try {
    const response = await fetch(url, {
      headers: {
        "user-agent": "JARVIS-ASG-research/1.0",
        accept: "text/html",
      },
      signal: AbortSignal.timeout(LIMITS.fetchTimeoutMs),
    });
    const html = await response.text();
    if (!response.ok) {
      return { ok: false, error: `DuckDuckGo HTML returned HTTP ${response.status}.` };
    }
    const results = parseDuckDuckGoHtml(html);
    if (results.length === 0) {
      return {
        ok: false,
        error:
          "DuckDuckGo HTML returned no parseable results. The page may be a challenge or an empty result set. No hits were invented.",
      };
    }
    return { ok: true, provider: "duckduckgo", query, results, note: SEARCH_NOTE };
  } catch (err) {
    return { ok: false, error: err instanceof Error ? err.message : "DuckDuckGo request failed." };
  }
}

function toHit(title: unknown, url: unknown, snippet: unknown): SearchHit | null {
  if (typeof title !== "string" || typeof url !== "string") return null;
  const parsed = parsePublicHttpUrl(url);
  if (!parsed.ok) return null;
  return {
    title: title.replace(/\s+/g, " ").trim().slice(0, 300),
    url: parsed.url.toString(),
    snippet: typeof snippet === "string" ? snippet.replace(/\s+/g, " ").trim().slice(0, 500) : "",
  };
}

export interface PageFetch {
  ok: true;
  url: string;
  http_status: number;
  title: string | null;
  text: string;
  truncated: boolean;
  note?: string;
}

export async function fetchPublicPage(rawUrl: string): Promise<PageFetch | { ok: false; error: string }> {
  let current = rawUrl.trim();
  for (let hop = 0; hop < 3; hop++) {
    const parsed = parsePublicHttpUrl(current);
    if (!parsed.ok) return parsed;
    let response: Response;
    try {
      response = await fetch(parsed.url.toString(), {
        method: "GET",
        redirect: "manual",
        headers: {
          "user-agent": "JARVIS-ASG-research/1.0",
          accept: "text/html, text/plain;q=0.9, */*;q=0.1",
        },
        signal: AbortSignal.timeout(LIMITS.fetchTimeoutMs),
      });
    } catch (err) {
      return {
        ok: false,
        error: `Fetch failed for ${parsed.url.toString()}: ${err instanceof Error ? err.message : "unknown error"}`,
      };
    }
    if (response.status >= 300 && response.status < 400) {
      const location = response.headers.get("location");
      if (!location) return { ok: false, error: `Redirect from ${parsed.url.toString()} had no Location header.` };
      current = new URL(location, parsed.url).toString();
      continue;
    }
    const type = response.headers.get("content-type") ?? "";
    const buffer = await response.arrayBuffer();
    const truncatedBytes = buffer.byteLength > LIMITS.fetchBytes;
    const slice = truncatedBytes ? buffer.slice(0, LIMITS.fetchBytes) : buffer;
    const body = new TextDecoder().decode(slice);
    const textual = !type || /text\/html|text\/plain|application\/xhtml|application\/xml|text\/xml/i.test(type);
    if (!textual) {
      return {
        ok: true,
        url: parsed.url.toString(),
        http_status: response.status,
        title: null,
        text: "",
        truncated: truncatedBytes,
        note: `Content-Type ${type} was not extracted. Cite this URL only if you already know what it is.`,
      };
    }
    const extracted = htmlToText(body);
    const page: PageFetch = {
      ok: true,
      url: parsed.url.toString(),
      http_status: response.status,
      title: extracted.title,
      text: extracted.text,
      truncated: truncatedBytes || extracted.truncated,
    };
    if (response.status >= 400) {
      page.note = `HTTP ${response.status}. This is the error page text, not a confirmed fact.`;
    }
    return page;
  }
  return { ok: false, error: "Too many redirects." };
}
