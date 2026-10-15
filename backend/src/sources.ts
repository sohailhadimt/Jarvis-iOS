export function isBlockedHostname(hostname: string): boolean {
  const host = hostname.toLowerCase().replace(/^\[|\]$/g, "").replace(/\.+$/, "");
  if (!host) return true;
  if (host === "localhost" || host.endsWith(".localhost") || host.endsWith(".local")) return true;
  if (host === "metadata.google.internal" || host === "metadata.internal") return true;
  if (host.includes(":")) {
    if (host === "::1" || host === "::") return true;
    if (host.startsWith("fe80:") || host.startsWith("fc") || host.startsWith("fd")) return true;
    return false;
  }
  const ip = parseIpv4(host);
  if (!ip) return false;
  const [a, b] = ip;
  if (a === 0 || a === 10 || a === 127) return true;
  if (a === 169 && b === 254) return true;
  if (a === 172 && b >= 16 && b <= 31) return true;
  if (a === 192 && b === 168) return true;
  if (a === 100 && b >= 64 && b <= 127) return true;
  return false;
}

function parseIpv4(host: string): [number, number, number, number] | null {
  const parts = host.split(".");
  if (parts.length !== 4) return null;
  const nums: number[] = [];
  for (const part of parts) {
    if (!/^\d{1,3}$/.test(part)) return null;
    const n = Number(part);
    if (n > 255) return null;
    nums.push(n);
  }
  return [nums[0], nums[1], nums[2], nums[3]];
}

export function parsePublicHttpUrl(input: string): { ok: true; url: URL } | { ok: false; error: string } {
  let url: URL;
  try {
    url = new URL(input.trim());
  } catch {
    return { ok: false, error: "Invalid URL." };
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    return { ok: false, error: "Only http and https URLs are allowed." };
  }
  if (url.username || url.password) {
    return { ok: false, error: "URLs with embedded credentials are not allowed." };
  }
  if (isBlockedHostname(url.hostname)) {
    return { ok: false, error: `Host is blocked: ${url.hostname}` };
  }
  return { ok: true, url };
}

export function normalizeSourceUrls(input: unknown): { ok: true; urls: string[] } | { ok: false; error: string } {
  if (!Array.isArray(input) || input.length === 0) {
    return {
      ok: false,
      error: "source_urls must be a non-empty array of http(s) URLs. Refusing to store an unsourced claim.",
    };
  }
  if (input.length > 12) {
    return { ok: false, error: "source_urls accepts at most 12 URLs." };
  }
  const urls: string[] = [];
  for (const item of input) {
    if (typeof item !== "string") {
      return { ok: false, error: "Each source URL must be a string." };
    }
    const parsed = parsePublicHttpUrl(item);
    if (!parsed.ok) return { ok: false, error: parsed.error };
    urls.push(parsed.url.toString());
  }
  return { ok: true, urls: [...new Set(urls)] };
}

export function optionalSourceUrls(input: unknown): { ok: true; urls: string[] } | { ok: false; error: string } {
  if (input === undefined || input === null) return { ok: true, urls: [] };
  if (Array.isArray(input) && input.length === 0) return { ok: true, urls: [] };
  return normalizeSourceUrls(input);
}
