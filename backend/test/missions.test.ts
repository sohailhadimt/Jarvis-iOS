import { describe, expect, it } from "vitest";
import { mentionedAgents, parseMissionPlan, readRoomGoal, roomGoal, ROUTINE_IDS } from "../src/missions";
import { goalNeedsApproval } from "../src/personas";

const roster = [
  { id: "agent_jarvis", name: "J.A.R.V.I.S." },
  { id: "agent_edith", name: "E.D.I.T.H." },
  { id: "agent_ultron", name: "U.L.T.R.O.N." },
  { id: "agent_friday", name: "F.R.I.D.A.Y." },
];

describe("parseMissionPlan", () => {
  it("maps a spoken name onto the roster id", () => {
    const raw = JSON.stringify({
      assignments: [
        { agent: "EDITH", goal: "Research two Kent security companies and keep source URLs." },
        { agent: "agent_ultron", goal: "Draft a proposal from those findings. Do not send it." },
      ],
    });
    const result = parseMissionPlan(raw, roster);
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.assignments[0].agent_id).toBe("agent_edith");
    expect(result.assignments[1].agent_id).toBe("agent_ultron");
  });

  it("reads JSON inside a fence", () => {
    const raw = 'Plan:\n```json\n{"assignments":[{"agent":"F.R.I.D.A.Y.","goal":"Draft a landing page. Do not publish it."}]}\n```';
    const result = parseMissionPlan(raw, roster);
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.assignments[0].agent_id).toBe("agent_friday");
  });

  it("rejects an unknown agent and an empty plan", () => {
    expect(parseMissionPlan(JSON.stringify({ assignments: [{ agent: "Vision", goal: "Look." }] }), roster).ok).toBe(false);
    expect(parseMissionPlan(JSON.stringify({ assignments: [] }), roster).ok).toBe(false);
  });
});

describe("Project Money mentions", () => {
  it("matches @EDITH and ignores a bare name", () => {
    const hits = mentionedAgents("Ask @EDITH for a dossier, not Friday.", roster);
    expect(hits.map((agent) => agent.id)).toEqual(["agent_edith"]);
  });

  it("round-trips a room goal", () => {
    const goal = roomGoal("room_project_money", "@ULTRON draft the pricing.", 1);
    expect(readRoomGoal(goal)).toEqual({
      roomId: "room_project_money",
      hop: 1,
      text: "@ULTRON draft the pricing.",
    });
  });
});

describe("approval gate", () => {
  it("requires approval for send, spend, publish, and a call", () => {
    expect(goalNeedsApproval("Send the proposal")).toBe(true);
    expect(goalNeedsApproval("Please place a call to the founder")).toBe(true);
    expect(goalNeedsApproval("Research the company site")).toBe(false);
  });
});

describe("routines", () => {
  it("names the three built-in routines", () => {
    expect(ROUTINE_IDS).toEqual(["job_daily_briefing", "job_open_reminders", "job_pipeline_monitor"]);
  });
});
