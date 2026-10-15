import { describe, expect, it } from "vitest";
import { parsePlan } from "../src/plan";

const research = {
  agent: "research",
  title: "Read the company site",
  instruction: "Open the site and save every claim with a source URL. If a fact has no URL, say unknown.",
  action_level: "automatic",
  depends_on: [],
};

function plan(subtasks: unknown[]): string {
  return JSON.stringify({ subtasks });
}

describe("parsePlan", () => {
  it("parses a JSON plan", () => {
    const result = parsePlan(plan([research, { ...research, agent: "quality_control", title: "Review", depends_on: [0] }]));
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.subtasks).toHaveLength(2);
    expect(result.subtasks[1].depends_on).toEqual([0]);
    expect(result.subtasks[0].coerced).toBe(false);
  });

  it("parses JSON inside a markdown fence and surrounding prose", () => {
    const raw = `Here is the plan:\n\`\`\`json\n${plan([research])}\n\`\`\`\nDone.`;
    const result = parsePlan(raw);
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.subtasks[0].agent).toBe("research");
  });

  it("rejects an unknown agent", () => {
    const result = parsePlan(plan([{ ...research, agent: "hacker" }]));
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.error).toMatch(/unknown agent/);
  });

  it("rejects an empty subtask list and a missing instruction", () => {
    expect(parsePlan('{"subtasks":[]}').ok).toBe(false);
    const missing = parsePlan(plan([{ ...research, instruction: "  " }]));
    expect(missing.ok).toBe(false);
    if (missing.ok) return;
    expect(missing.error).toMatch(/instruction/);
  });

  it("raises outreach and automation off automatic", () => {
    const result = parsePlan(
      plan([
        {
          agent: "outreach",
          title: "Draft the email",
          instruction: "Draft only. Do not send.",
          action_level: "automatic",
          depends_on: [],
        },
      ]),
    );
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.subtasks[0].action_level).toBe("approval_required");
    expect(result.subtasks[0].coerced).toBe(true);
  });

  it("raises payment language to explicit authorisation", () => {
    const result = parsePlan(
      plan([
        {
          agent: "admin",
          title: "Pay the invoice",
          instruction: "Prepare the payment for approval.",
          action_level: "approval_required",
          depends_on: [],
        },
      ]),
    );
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.subtasks[0].action_level).toBe("explicit_authorisation");
    expect(result.subtasks[0].coerced).toBe(true);
  });

  it("rejects a self dependency, an out of range index, and a cycle", () => {
    const self = parsePlan(plan([{ ...research, depends_on: [0] }]));
    expect(self.ok).toBe(false);
    const range = parsePlan(plan([{ ...research, depends_on: [3] }]));
    expect(range.ok).toBe(false);
    const cycle = parsePlan(
      plan([
        { ...research, title: "A", depends_on: [1] },
        { ...research, title: "B", depends_on: [0] },
      ]),
    );
    expect(cycle.ok).toBe(false);
    if (cycle.ok) return;
    expect(cycle.error).toMatch(/cycle/);
  });

  it("rejects prose that has no JSON object", () => {
    const result = parsePlan("I will just email them all now.");
    expect(result.ok).toBe(false);
  });
});
