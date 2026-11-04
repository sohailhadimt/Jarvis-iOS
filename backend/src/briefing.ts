import { dbAll } from "./db";
import { mapApproval, mapDocument, mapFinding, mapPipeline, mapTask } from "./db";
import { nowIso } from "./http";
import type { ApprovalRow, DocumentRow, Env, FindingRow, PipelineRow, TaskRow } from "./types";
import { PIPELINE_STAGES } from "./types";

export interface Recommendation {
  id: string;
  text: string;
  based_on: string[];
}

export function buildRecommendations(input: {
  pendingApprovals: { id: string }[];
  failedTasks: { id: string; goal: string }[];
  prospects: { id: string; company: string }[];
  drafts: { id: string; kind: string; title: string }[];
  completedCount: number;
}): Recommendation[] {
  const recommendations: Recommendation[] = [];
  if (input.pendingApprovals.length > 0) {
    recommendations.push({
      id: "review-approvals",
      text: `${input.pendingApprovals.length} approval(s) are waiting. Nothing has been sent, published, or paid.`,
      based_on: input.pendingApprovals.map((item) => `approval:${item.id}`),
    });
  }
  if (input.failedTasks.length > 0) {
    recommendations.push({
      id: "review-failures",
      text: `${input.failedTasks.length} task(s) failed in this window. Read each task error before retrying. The error text is the failure record, not a guess.`,
      based_on: input.failedTasks.map((item) => `task:${item.id}`),
    });
  }
  if (input.drafts.length > 0) {
    recommendations.push({
      id: "review-drafts",
      text: `${input.drafts.length} draft(s) were stored and have not been sent. Read them and decide in Approvals.`,
      based_on: input.drafts.map((item) => `document:${item.id}`),
    });
  }
  if (input.prospects.length > 0) {
    const names = input.prospects.map((item) => item.company).join(", ");
    recommendations.push({
      id: "review-prospects",
      text: `Prospect rows still at stage prospect: ${names}. This backend has not contacted them.`,
      based_on: input.prospects.map((item) => `pipeline:${item.id}`),
    });
  }
  if (
    recommendations.length === 0 &&
    input.completedCount === 0 &&
    input.failedTasks.length === 0
  ) {
    recommendations.push({
      id: "no-work-in-window",
      text: "No completed or failed tasks are stored in the last 24 hours. Create a task when you want work done.",
      based_on: ["window:24h"],
    });
  }
  return recommendations;
}

export async function buildBriefing(env: Env) {
  const generatedAt = nowIso();
  const since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
  const [completed, failed, approvals, findings, documents, pipeline] = await Promise.all([
    dbAll<TaskRow>(
      env,
      "SELECT * FROM tasks WHERE status = 'completed' AND completed_at >= ? ORDER BY completed_at DESC LIMIT 20",
      [since],
    ),
    dbAll<TaskRow>(
      env,
      "SELECT * FROM tasks WHERE status = 'failed' AND updated_at >= ? ORDER BY updated_at DESC LIMIT 20",
      [since],
    ),
    dbAll<ApprovalRow>(
      env,
      "SELECT * FROM approvals WHERE status = 'pending' ORDER BY created_at ASC LIMIT 50",
    ),
    dbAll<FindingRow>(
      env,
      "SELECT * FROM findings WHERE created_at >= ? ORDER BY created_at DESC LIMIT 50",
      [since],
    ),
    dbAll<DocumentRow>(
      env,
      "SELECT * FROM documents WHERE created_at >= ? ORDER BY created_at DESC LIMIT 20",
      [since],
    ),
    dbAll<PipelineRow>(env, "SELECT * FROM pipeline ORDER BY updated_at DESC LIMIT 200"),
  ]);

  const byStage: Record<string, number> = {};
  for (const stage of PIPELINE_STAGES) byStage[stage] = 0;
  for (const row of pipeline) byStage[row.stage] = (byStage[row.stage] ?? 0) + 1;

  const revenueRows = pipeline.filter((row) => row.stage === "won" || row.stage === "active_client");
  const known = revenueRows.filter((row) => typeof row.mrr === "number" && row.mrr !== null);
  const knownTotal = Math.round(known.reduce((sum, row) => sum + (row.mrr ?? 0), 0) * 100) / 100;

  const prospects = pipeline
    .filter((row) => row.stage === "prospect")
    .slice(0, 15)
    .map((row) => ({ id: row.id, company: row.company }));
  const drafts = documents
    .filter((row) => row.kind === "proposal" || row.kind === "outreach_email" || row.kind === "website_html")
    .map((row) => ({ id: row.id, kind: row.kind, title: row.title }));

  const recommendations = buildRecommendations({
    pendingApprovals: approvals.map((row) => ({ id: row.id })),
    failedTasks: failed.map((row) => ({ id: row.id, goal: row.goal })),
    prospects,
    drafts,
    completedCount: completed.length,
  });

  let reminders: string[] = [];
  try {
    const rows = await dbAll<{ text: string }>(
      env,
      "SELECT text FROM brain_reminders WHERE status = 'open' ORDER BY created_at DESC LIMIT 12",
    );
    reminders = rows.map((row) => row.text).filter((text) => text.length > 0);
  } catch {
    reminders = [];
  }

  return {
    generated_at: generatedAt,
    window_start: since,
    separation:
      "facts are rows stored by JARVIS. recommendations are suggestions derived only from those rows. A recommendation is not an extra fact.",
    facts: {
      completed_tasks: completed.map(mapTask),
      failed_tasks: failed.map(mapTask),
      pending_approvals: approvals.map(mapApproval),
      results: {
        findings: findings.map(mapFinding),
        documents: documents.map(mapDocument),
      },
      pipeline: {
        by_stage: byStage,
        rows: pipeline.map(mapPipeline),
        mrr: {
          currency: "GBP",
          stages_counted: ["won", "active_client"],
          known_total: knownTotal,
          rows_with_mrr: known.length,
          rows_missing_mrr: revenueRows.length - known.length,
          note: "Null mrr is unknown. It is not counted as zero.",
        },
      },
    },
    recommendations,
    reminders,
  };
}
