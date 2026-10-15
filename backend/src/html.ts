import { LIMITS } from "./types";

export function decodeEntities(value: string): string {
  return value
    .replace(/&nbsp;/gi, " ")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">")
    .replace(/&quot;/gi, "\"")
    .replace(/&#39;|&apos;/gi, "'")
    .replace(/&#(\d+);/g, (full, n: string) => {
      const code = Number(n);
      if (!Number.isInteger(code) || code <= 0 || code > 0x10ffff) return full;
      return String.fromCodePoint(code);
    })
    .replace(/&#x([0-9a-f]+);/gi, (full, n: string) => {
      const code = Number.parseInt(n, 16);
      if (!Number.isInteger(code) || code <= 0 || code > 0x10ffff) return full;
      return String.fromCodePoint(code);
    })
    .replace(/&amp;/gi, "&");
}

export function htmlToText(
  html: string,
  maxChars = LIMITS.textChars,
): { title: string | null; text: string; truncated: boolean } {
  const sliced = html.slice(0, LIMITS.htmlChars);
  const titleMatch = /<title[^>]*>([\s\S]*?)<\/title>/i.exec(sliced);
  const title = titleMatch ? decodeEntities(titleMatch[1].replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim()) : null;
  const without = sliced
    .replace(/<script[\s\S]*?<\/script>/gi, " ")
    .replace(/<style[\s\S]*?<\/style>/gi, " ")
    .replace(/<noscript[\s\S]*?<\/noscript>/gi, " ")
    .replace(/<!--[\s\S]*?-->/g, " ")
    .replace(/<[^>]+>/g, " ");
  const text = decodeEntities(without).replace(/\s+/g, " ").trim();
  return {
    title: title || null,
    text: text.slice(0, maxChars),
    truncated: text.length > maxChars || html.length > LIMITS.htmlChars,
  };
}

export interface SearchHit {
  title: string;
  url: string;
  snippet: string;
}

export function parseDuckDuckGoHtml(html: string): SearchHit[] {
  const hits: SearchHit[] = [];
  const linkRe = /<a[^>]*class="[^"]*result__a[^"]*"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>/gi;
  let match: RegExpExecArray | null;
  while ((match = linkRe.exec(html)) && hits.length < 8) {
    const url = unwrapDuckDuckGoUrl(decodeEntities(match[1]));
    const title = decodeEntities(match[2].replace(/<[^>]+>/g, " ")).replace(/\s+/g, " ").trim();
    if (!url || !title) continue;
    hits.push({ title, url, snippet: "" });
  }
  const snippets: string[] = [];
  const snipRe = /<(?:a|td|span)[^>]*class="[^"]*result__snippet[^"]*"[^>]*>([\s\S]*?)<\/(?:a|td|span)>/gi;
  let snippetMatch: RegExpExecArray | null;
  while ((snippetMatch = snipRe.exec(html)) && snippets.length < 8) {
    snippets.push(decodeEntities(snippetMatch[1].replace(/<[^>]+>/g, " ")).replace(/\s+/g, " ").trim());
  }
  hits.forEach((hit, index) => {
    if (snippets[index]) hit.snippet = snippets[index];
  });
  return hits;
}

export function unwrapDuckDuckGoUrl(href: string): string | null {
  let value = href.trim();
  if (!value || value.startsWith("javascript:")) return null;
  if (value.startsWith("//")) value = `https:${value}`;
  try {
    const url = new URL(value, "https://duckduckgo.com");
    const uddg = url.searchParams.get("uddg");
    if (uddg && /^https?:\/\//i.test(uddg)) return uddg;
    if (url.protocol !== "http:" && url.protocol !== "https:") return null;
    if (url.hostname.endsWith("duckduckgo.com")) return null;
    return url.toString();
  } catch {
    return null;
  }
}
