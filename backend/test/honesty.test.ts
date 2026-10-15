import { describe, expect, it } from "vitest";
import { buildRecommendations } from "../src/briefing";
import { computeNextRun, cronMatches, parseCron } from "../src/cron";
import { htmlToText, parseDuckDuckGoHtml } from "../src/html";
import { normalizeSourceUrls } from "../src/sources";

describe("source rules", () => {
  it("rejects an unsourced claim and a private URL", () => {
    expect(normalizeSourceUrls([]).ok).toBe(false);
    expect(normalizeSourceUrls(["javascript:alert(1)"]).ok).toBe(false);
    expect(normalizeSourceUrls(["http://127.0.0.1/secret"]).ok).toBe(false);
    expect(normalizeSourceUrls(["http://169.254.169.254/latest"]).ok).toBe(false);
    const ok = normalizeSourceUrls(["https://example.com/about"]);
    expect(ok.ok).toBe(true);
    if (!ok.ok) return;
    expect(ok.urls).toEqual(["https://example.com/about"]);
  });
});

describe("page text and search fallback", () => {
  it("strips script and style while keeping visible text", () => {
    const extracted = htmlToText(
      "<html><head><title>Acme</title><style>.x{color:red}</style><script>secret()</script></head><body><p>Hello &amp; welcome</p></body></html>",
    );
    expect(extracted.title).toBe("Acme");
    expect(extracted.text).toContain("Hello & welcome");
    expect(extracted.text).not.toContain("secret()");
    expect(extracted.text).not.toContain("color:red");
  });

  it("unwraps DuckDuckGo redirect links and ignores the search host", () => {
    const html = `
      <a class="result__a" href="https://duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fsecurity">Example Security</a>
      <a class="result__snippet">Kent security company</a>
      <a class="result__a" href="https://duckduckgo.com/about">DuckDuckGo</a>
    `;
    const hits = parseDuckDuckGoHtml(html);
    expect(hits).toEqual([
      { title: "Example Security", url: "https://example.com/security", snippet: "Kent security company" },
    ]);
  });
});

describe("scheduler", () => {
  it("matches a nightly cron on the 02:00 UTC minute and computes the next run", () => {
    const expr = parseCron("0 2 * * *");
    expect(expr).not.toBeNull();
    if (!expr) return;
    const at = new Date(Date.UTC(2026, 9, 15, 2, 0, 30));
    expect(cronMatches(at, expr)).toBe(true);
    expect(cronMatches(new Date(Date.UTC(2026, 9, 15, 2, 5, 0)), expr)).toBe(false);
    expect(computeNextRun(new Date(Date.UTC(2026, 9, 15, 1, 0, 0)), expr)).toBe("2026-10-15T02:00:00.000Z");
    expect(computeNextRun(at, expr)).toBe("2026-10-16T02:00:00.000Z");
  });
});

describe("briefing recommendations", () => {
  it("only refers to records that were passed in", () => {
    const recommendations = buildRecommendations({
      pendingApprovals: [{ id: "apr_1" }],
      failedTasks: [],
      prospects: [{ id: "lead_1", company: "Example Security" }],
      drafts: [],
      completedCount: 1,
    });
    const text = recommendations.map((item) => item.text).join(" ");
    expect(text).toContain("Example Security");
    expect(text).not.toMatch(/Acme|invented/i);
    expect(recommendations.every((item) => item.based_on.length > 0)).toBe(true);
    expect(recommendations.flatMap((item) => item.based_on)).toEqual(
      expect.arrayContaining(["approval:apr_1", "pipeline:lead_1"]),
    );
  });
});
