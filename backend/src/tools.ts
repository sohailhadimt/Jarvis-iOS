import { ALLOWED_TOOLS } from "./agents";
import { dbAll, dbFirst, dbRun, logActivity, logProgress, mapDocument, mapFinding, mapPipeline } from "./db";
import { clip, isRecord, newId, nowIso } from "./http";
import type { LlmTool } from "./llm";
import { fetchPublicPage, webSearch } from "./search";
import { normalizeSourceUrls, optionalSourceUrls, parsePublicHttpUrl } from "./sources";
import {
  DOCUMENT_KINDS,
  PIPELINE_STAGES,
  type AgentName,
  type DocumentKind,
  type DocumentRow,
  type Env,
  type FindingRow,
  type PipelineRow,
  type PipelineStage,
  type ToolName,
} from "./types";

const SPECS: Record<ToolName, { description: string; parameters: Record<string, unknown> }> = {
  web_search: {
    description: "Search the public web. Results are untrusted hits with URLs, not facts you may assert.",
    parameters: {
      type: "object",
      properties: { query: { type: "string" } },
      required: ["query"],
      additionalProperties: false,
    },
  },
  fetch_url: {
    description: "GET a public http(s) page and extract visible text. Private hosts are blocked.",
    parameters: {
      type: "object",
      properties: { url: { type: "string" } },
      required: ["url"],
      additionalProperties: false,
    },
  },
  save_finding: {
    description: "Store a factual claim. Rejects the call when source_urls is missing or empty.",
    parameters: {
      type: "object",
      properties: {
        claim: { type: "string" },
        source_urls: { type: "array", items: { type: "string" } },
        excerpt: { type: "string" },
      },
      required: ["claim", "source_urls"],
      additionalProperties: false,
    },
  },
  save_lead: {
    description: "Store a sales prospect. Stage is always prospect on create. source_urls is required. Does not contact the company.",
    parameters: {
      type: "object",
      properties: {
        company: { type: "string" },
        contact_name: { type: "string" },
        contact_email: { type: "string" },
        website: { type: "string" },
        notes: { type: "string" },
        source_urls: { type: "array", items: { type: "string" } },
        mrr: { type: "number", description: "GBP per month, only if a source states it. Omit if unknown." },
      },
      required: ["company", "source_urls"],
      additionalProperties: false,
    },
  },
  draft_document: {
    description: "Store a draft proposal, outreach email, or website HTML. Does not send or publish. proposal and outreach_email require source_urls.",
    parameters: {
      type: "object",
      properties: {
        kind: { type: "string", enum: [...DOCUMENT_KINDS] },
        title: { type: "string" },
        body: { type: "string" },
        source_urls: { type: "array", items: { type: "string" } },
      },
      required: ["kind", "title", "body"],
      additionalProperties: false,
    },
  },
  request_approval: {
    description: "Queue a human approval. This never sends, publishes, or pays.",
    parameters: {
      type: "object",
      properties: {
        action: { type: "string" },
        summary: { type: "string" },
        payload: { type: "object" },
      },
      required: ["action", "summary"],
      additionalProperties: false,
    },
  },
  list_findings: {
    description: "Read findings already stored for this task. Does not add facts.",
    parameters: { type: "object", properties: {}, additionalProperties: false },
  },
  list_documents: {
    description: "Read drafts already stored for this task.",
    parameters: { type: "object", properties: {}, additionalProperties: false },
  },
  list_pipeline: {
    description: "Read pipeline rows already stored. Does not add companies.",
    parameters: { type: "object", properties: {}, additionalProperties: false },
  },
};

export function toolsFor(agent: AgentName): LlmTool[] {
  return ALLOWED_TOOLS[agent].map((name) => ({
    type: "function",
    function: {
      name,
      description: SPECS[name].description,
      parameters: SPECS[name].parameters,
    },
  }));
}

export function toolsForNames(names: readonly string[]): LlmTool[] {
  const out: LlmTool[] = [];
  for (const name of names) {
    const spec = SPECS[name as ToolName];
    if (!spec) continue;
    out.push({
      type: "function",
      function: { name, description: spec.description, parameters: spec.parameters },
    });
  }
  return out;
}

export function parseToolArgs(raw: string): { ok: true; value: Record<string, unknown> } | { ok: false; error: string } {
  if (!raw.trim()) return { ok: true, value: {} };
  try {
    const value = JSON.parse(raw) as unknown;
    if (!isRecord(value)) return { ok: false, error: "Tool arguments must be a JSON object." };
    return { ok: true, value };
  } catch (err) {
    return { ok: false, error: `Tool arguments are not valid JSON: ${err instanceof Error ? err.message : "parse error"}` };
  }
}

export interface ToolOutcome {
  result: unknown;
  stop: boolean;
}

export async function executeTool(
  env: Env,
  taskId: string,
  subtaskId: string,
  agent: AgentName,
  actionLevel: string,
  name: string,
  args: Record<string, unknown>,
  allow?: readonly string[],
): Promise<ToolOutcome> {
  const permitted = allow ?? (ALLOWED_TOOLS[agent] as readonly string[]);
  if (!permitted.includes(name)) {
    return { stop: false, result: { ok: false, error: `Tool ${name} is not allowed for the ${agent} agent.` } };
  }
  switch (name as ToolName) {
    case "web_search":
      return { stop: false, result: await webSearch(env, typeof args.query === "string" ? args.query : "") };
    case "fetch_url":
      return { stop: false, result: await fetchPublicPage(typeof args.url === "string" ? args.url : "") };
    case "save_finding":
      return { stop: false, result: await saveFinding(env, taskId, subtaskId, args) };
    case "save_lead":
      return { stop: false, result: await saveLead(env, taskId, subtaskId, args) };
    case "draft_document":
      return { stop: false, result: await draftDocument(env, taskId, subtaskId, args) };
    case "request_approval":
      return requestApproval(env, taskId, subtaskId, actionLevel, args);
    case "list_findings":
      return { stop: false, result: { ok: true, findings: await findingsForTask(env, taskId) } };
    case "list_documents":
      return { stop: false, result: { ok: true, documents: await documentsForTask(env, taskId) } };
    case "list_pipeline":
      return { stop: false, result: { ok: true, pipeline: await pipelineRows(env) } };
    default:
      return { stop: false, result: { ok: false, error: `Unknown tool ${name}.` } };
  }
}

async function saveFinding(env: Env, taskId: string, subtaskId: string, args: Record<string, unknown>) {
  const claim = typeof args.claim === "string" ? args.claim.trim() : "";
  if (!claim || claim.length > 2000) return { ok: false, error: "claim is required and must be at most 2000 characters." };
  const sources = normalizeSourceUrls(args.source_urls);
  if (!sources.ok) return { ok: false, error: sources.error };
  const excerpt = typeof args.excerpt === "string" ? clip(args.excerpt.trim(), 1000) : null;
  const existing = await dbFirst<{ id: string; source_urls: string }>(
    env,
    "SELECT id, source_urls FROM findings WHERE task_id = ? AND claim = ? LIMIT 1",
    [taskId, claim],
  );
  if (existing) {
    const merged = [...new Set([...parseUrls(existing.source_urls), ...sources.urls])];
    await dbRun(env, "UPDATE findings SET source_urls = ?, excerpt = COALESCE(?, excerpt) WHERE id = ?", [
      JSON.stringify(merged),
      excerpt,
      existing.id,
    ]);
    return { ok: true, id: existing.id, deduped: true, source_urls: merged };
  }
  const id = newId("find");
  await dbRun(
    env,
    "INSERT INTO findings (id, task_id, subtask_id, claim, source_urls, excerpt, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
    [id, taskId, subtaskId, claim, JSON.stringify(sources.urls), excerpt, nowIso()],
  );
  await logActivity(env, "agent", "finding.saved", taskId, { id, source_urls: sources.urls });
  await logProgress(env, taskId, subtaskId, "info", `Stored a finding with ${sources.urls.length} source URL(s).`, {
    finding_id: id,
  });
  return { ok: true, id, deduped: false, source_urls: sources.urls };
}

async function saveLead(env: Env, taskId: string, subtaskId: string, args: Record<string, unknown>) {
  const company = typeof args.company === "string" ? args.company.trim() : "";
  if (!company || company.length > 200) return { ok: false, error: "company is required and must be at most 200 characters." };
  const sources = normalizeSourceUrls(args.source_urls);
  if (!sources.ok) return { ok: false, error: sources.error };
  const contactName = optionalShort(args.contact_name, 200);
  const notes = optionalShort(args.notes, 2000);
  const email = optionalEmail(args.contact_email);
  if (args.contact_email !== undefined && args.contact_email !== null && email === undefined) {
    return { ok: false, error: "contact_email is not a usable email address." };
  }
  let website: string | null = null;
  if (typeof args.website === "string" && args.website.trim()) {
    const parsed = parsePublicHttpUrl(args.website);
    if (!parsed.ok) return { ok: false, error: `website: ${parsed.error}` };
    website = parsed.url.toString();
  }
  const mrr = parseMrr(args.mrr);
  if (!mrr.ok) return mrr;
  const now = nowIso();
  const existing = await dbFirst<PipelineRow>(
    env,
    "SELECT * FROM pipeline WHERE lower(company) = lower(?) LIMIT 1",
    [company],
  );
  if (existing) {
    const merged = [...new Set([...parseUrls(existing.source_urls), ...sources.urls])];
    await dbRun(
      env,
      `UPDATE pipeline
       SET contact_name = COALESCE(contact_name, ?),
           contact_email = COALESCE(contact_email, ?),
           website = COALESCE(website, ?),
           mrr = COALESCE(mrr, ?),
           notes = CASE WHEN ? IS NULL THEN notes WHEN notes IS NULL OR notes = '' THEN ? ELSE notes || char(10) || ? END,
           source_urls = ?,
           updated_at = ?
       WHERE id = ?`,
      [contactName, email ?? null, website, mrr.mrr, notes, notes, notes, JSON.stringify(merged), now, existing.id],
    );
    await logActivity(env, "agent", "lead.updated", taskId, { id: existing.id, company, source_urls: merged });
    return {
      ok: true,
      id: existing.id,
      deduped: true,
      stage: existing.stage,
      source_urls: merged,
      note: "Existing pipeline row kept its stage. save_lead does not move a company backwards to prospect.",
    };
  }
  const id = newId("lead");
  await dbRun(
    env,
    `INSERT INTO pipeline
      (id, company, contact_name, contact_email, website, stage, mrr, notes, source_urls, task_id, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, 'prospect', ?, ?, ?, ?, ?, ?)`,
    [id, company, contactName, email ?? null, website, mrr.mrr, notes, JSON.stringify(sources.urls), taskId, now, now],
  );
  await logActivity(env, "agent", "lead.saved", taskId, { id, company, stage: "prospect", source_urls: sources.urls });
  await logProgress(env, taskId, subtaskId, "info", `Saved prospect ${company}. Not contacted.`, { pipeline_id: id });
  return { ok: true, id, deduped: false, stage: "prospect", source_urls: sources.urls };
}

async function draftDocument(env: Env, taskId: string, subtaskId: string, args: Record<string, unknown>) {
  const kind = args.kind;
  if (typeof kind !== "string" || !(DOCUMENT_KINDS as readonly string[]).includes(kind)) {
    return { ok: false, error: `kind must be one of: ${DOCUMENT_KINDS.join(", ")}.` };
  }
  const title = typeof args.title === "string" ? args.title.trim() : "";
  const body = typeof args.body === "string" ? args.body.trim() : "";
  if (!title || title.length > 200) return { ok: false, error: "title is required and must be at most 200 characters." };
  if (!body || body.length > 50_000) return { ok: false, error: "body is required and must be at most 50000 characters." };
  const sourced = kind === "proposal" || kind === "outreach_email";
  const sources = sourced ? normalizeSourceUrls(args.source_urls) : optionalSourceUrls(args.source_urls);
  if (!sources.ok) return { ok: false, error: sources.error };
  const id = newId("doc");
  await dbRun(
    env,
    "INSERT INTO documents (id, task_id, subtask_id, kind, title, body, source_urls, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
    [id, taskId, subtaskId, kind, title, body, JSON.stringify(sources.urls), nowIso()],
  );
  await logActivity(env, "agent", "document.drafted", taskId, { id, kind, source_urls: sources.urls });
  await logProgress(env, taskId, subtaskId, "info", `Drafted ${kind} "${title}". It was not sent or published.`, {
    document_id: id,
  });
  return { ok: true, id, kind: kind as DocumentKind, stored_only: true, source_urls: sources.urls };
}

async function requestApproval(
  env: Env,
  taskId: string,
  subtaskId: string,
  actionLevel: string,
  args: Record<string, unknown>,
): Promise<ToolOutcome> {
  const action = typeof args.action === "string" ? args.action.trim() : "";
  const summary = typeof args.summary === "string" ? args.summary.trim() : "";
  if (!action || action.length > 80) return { stop: false, result: { ok: false, error: "action is required (max 80 characters)." } };
  if (!summary || summary.length > 2000) {
    return { stop: false, result: { ok: false, error: "summary is required (max 2000 characters)." } };
  }
  let payloadJson: string | null = null;
  if (args.payload !== undefined) {
    if (!isRecord(args.payload)) return { stop: false, result: { ok: false, error: "payload must be an object." } };
    payloadJson = JSON.stringify(args.payload);
    if (payloadJson.length > 8000) return { stop: false, result: { ok: false, error: "payload is too large." } };
  }
  const level = paymentLike(action) || paymentLike(summary) ? "explicit_authorisation" : normalizeLevel(actionLevel);
  const existing = await dbFirst<{ id: string }>(
    env,
    "SELECT id FROM approvals WHERE subtask_id = ? AND action = ? AND status = 'pending' LIMIT 1",
    [subtaskId, action],
  );
  const now = nowIso();
  const id = existing?.id ?? newId("apr");
  if (!existing) {
    await dbRun(
      env,
      `INSERT INTO approvals
        (id, task_id, subtask_id, action, level, summary, payload_json, status, reason, created_at, decided_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', NULL, ?, NULL)`,
      [id, taskId, subtaskId, action, level, summary, payloadJson, now],
    );
  }
  await dbRun(env, "UPDATE subtasks SET status = 'awaiting_approval', updated_at = ? WHERE id = ?", [now, subtaskId]);
  await dbRun(
    env,
    "UPDATE tasks SET status = 'awaiting_approval', updated_at = ? WHERE id = ? AND status != 'failed'",
    [now, taskId],
  );
  await logActivity(env, "agent", "approval.requested", taskId, { id, action, level, external_action_taken: false });
  await logProgress(env, taskId, subtaskId, "info", `Approval queued for ${action}. Nothing was sent, published, or paid.`, {
    approval_id: id,
  });
  return {
    stop: true,
    result: {
      ok: true,
      id,
      status: "pending",
      external_action_taken: false,
      message: "Approval recorded. This backend does not perform the external action.",
    },
  };
}

async function findingsForTask(env: Env, taskId: string) {
  const rows = await dbAll<FindingRow>(env, "SELECT * FROM findings WHERE task_id = ? ORDER BY created_at ASC LIMIT 50", [taskId]);
  return rows.map(mapFinding);
}

async function documentsForTask(env: Env, taskId: string) {
  const rows = await dbAll<DocumentRow>(
    env,
    "SELECT * FROM documents WHERE task_id = ? ORDER BY created_at ASC LIMIT 20",
    [taskId],
  );
  return rows.map((row) => ({ ...mapDocument(row), body: clip(row.body, 2000) }));
}

async function pipelineRows(env: Env) {
  const rows = await dbAll<PipelineRow>(env, "SELECT * FROM pipeline ORDER BY updated_at DESC LIMIT 50");
  return rows.map(mapPipeline);
}

function parseUrls(value: string): string[] {
  try {
    const parsed = JSON.parse(value) as unknown;
    if (!Array.isArray(parsed)) return [];
    return parsed.filter((item): item is string => typeof item === "string");
  } catch {
    return [];
  }
}

function optionalShort(value: unknown, max: number): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (!trimmed) return null;
  return clip(trimmed, max);
}

function optionalEmail(value: unknown): string | null | undefined {
  if (value === undefined || value === null || value === "") return null;
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  if (!trimmed) return null;
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(trimmed) || trimmed.length > 200) return undefined;
  return trimmed;
}

export function parseMrr(value: unknown): { ok: true; mrr: number | null } | { ok: false; error: string } {
  if (value === undefined || value === null || value === "") return { ok: true, mrr: null };
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0 || value > 1_000_000_000) {
    return { ok: false, error: "mrr must be a non-negative number in major currency units (GBP), or null if unknown." };
  }
  return { ok: true, mrr: Math.round(value * 100) / 100 };
}

function paymentLike(value: string): boolean {
  return /\b(pay|payment|invoice|charge|purchase|checkout)\b/i.test(value);
}

function normalizeLevel(level: string): string {
  if (level === "explicit_authorisation" || level === "approval_required") return level;
  return "approval_required";
}

export function isPipelineStage(value: string): value is PipelineStage {
  return (PIPELINE_STAGES as readonly string[]).includes(value);
}
