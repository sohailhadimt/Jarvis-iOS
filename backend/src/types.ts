export const AGENTS = [
  "research",
  "lead_gen",
  "sales",
  "outreach",
  "marketing",
  "website",
  "analytics",
  "admin",
  "automation",
  "quality_control",
] as const;

export type AgentName = (typeof AGENTS)[number];

export const ACTION_LEVELS = ["automatic", "approval_required", "explicit_authorisation"] as const;

export type ActionLevel = (typeof ACTION_LEVELS)[number];

export const PIPELINE_STAGES = [
  "prospect",
  "qualified",
  "contacted",
  "positive",
  "meeting",
  "proposal_sent",
  "negotiation",
  "won",
  "lost",
  "active_client",
] as const;

export type PipelineStage = (typeof PIPELINE_STAGES)[number];

export const DOCUMENT_KINDS = ["proposal", "outreach_email", "website_html", "other"] as const;

export type DocumentKind = (typeof DOCUMENT_KINDS)[number];

export const TOOL_NAMES = [
  "web_search",
  "fetch_url",
  "save_finding",
  "save_lead",
  "draft_document",
  "request_approval",
  "list_findings",
  "list_documents",
  "list_pipeline",
] as const;

export type ToolName = (typeof TOOL_NAMES)[number];

export interface Env {
  DB: D1Database;
  GEMINI_API_KEY?: string;
  GROQ_API_KEY?: string;
  JARVIS_APP_TOKEN?: string;
  /** Grok Bot routine webhook. Set with `npx wrangler secret put`. Never commit the values. */
  JARVIS_WEBHOOK_URL?: string;
  JARVIS_WEBHOOK_KEY?: string;
  TAVILY_API_KEY?: string;
  BRAVE_API_KEY?: string;
  ENVIRONMENT?: string;
  /** Wrangler secrets. Never written into the repo or the iOS binary. */
  TWILIO_ACCOUNT_SID?: string;
  TWILIO_AUTH_TOKEN?: string;
  TWILIO_FROM_NUMBER?: string;
  ELEVENLABS_API_KEY?: string;
  ELEVENLABS_AGENT_ID?: string;
  ELEVENLABS_WEBHOOK_SECRET?: string;
  /** Set to "true" to send conversation_config_override on register-call. Off by default. */
  ELEVENLABS_CALL_OVERRIDES?: string;
  /**
   * Sohail's own mobile for put-through, take-over, SMS, and problem calls.
   * Set at deploy with `npx wrangler secret put OWNER_PHONE`. Never commit the number.
   */
  OWNER_PHONE?: string;
  APNS_KEY_ID?: string;
  APNS_TEAM_ID?: string;
  APNS_PRIVATE_KEY?: string;
  APNS_BUNDLE_ID?: string;
  /** sandbox or production. Production matches TestFlight. */
  APNS_ENVIRONMENT?: string;
  /** Optional. In-app VoIP audio is not linked until these and the Voice SDK exist. */
  TWILIO_API_KEY_SID?: string;
  TWILIO_API_KEY_SECRET?: string;
  TWILIO_VOICE_APP_SID?: string;
}

export interface PlanSubtask {
  agent: AgentName;
  title: string;
  instruction: string;
  action_level: ActionLevel;
  depends_on: number[];
  coerced: boolean;
}

export interface TaskRow {
  id: string;
  goal: string;
  status: string;
  schedule: string | null;
  scheduled_job_id: string | null;
  error: string | null;
  result_summary: string | null;
  plan_attempts: number;
  planner_note: string | null;
  locked_until: string | null;
  created_at: string;
  updated_at: string;
  completed_at: string | null;
}

export interface SubtaskRow {
  id: string;
  task_id: string;
  agent: string;
  title: string;
  instruction: string;
  action_level: string;
  depends_on_json: string;
  status: string;
  step: number;
  max_steps: number;
  messages_json: string | null;
  result_summary: string | null;
  error: string | null;
  attempt: number;
  max_attempts: number;
  next_attempt_at: string | null;
  locked_until: string | null;
  sort_order: number;
  created_at: string;
  updated_at: string;
}

export interface FindingRow {
  id: string;
  task_id: string;
  subtask_id: string | null;
  claim: string;
  source_urls: string;
  excerpt: string | null;
  created_at: string;
}

export interface DocumentRow {
  id: string;
  task_id: string;
  subtask_id: string | null;
  kind: string;
  title: string;
  body: string;
  source_urls: string;
  created_at: string;
}

export interface ApprovalRow {
  id: string;
  task_id: string | null;
  subtask_id: string | null;
  action: string;
  level: string;
  summary: string;
  payload_json: string | null;
  status: string;
  reason: string | null;
  created_at: string;
  decided_at: string | null;
}

export interface MemoryRow {
  id: string;
  key: string | null;
  content: string;
  tags: string;
  source_urls: string;
  created_at: string;
  updated_at: string;
}

export interface ActivityRow {
  id: string;
  actor: string;
  action: string;
  task_id: string | null;
  detail_json: string | null;
  created_at: string;
}

export interface PipelineRow {
  id: string;
  company: string;
  contact_name: string | null;
  contact_email: string | null;
  website: string | null;
  stage: string;
  mrr: number | null;
  notes: string | null;
  source_urls: string;
  task_id: string | null;
  created_at: string;
  updated_at: string;
}

export interface ScheduledJobRow {
  id: string;
  name: string;
  goal: string;
  cron: string;
  enabled: number;
  last_run_at: string | null;
  next_run_at: string | null;
  created_at: string;
}

export interface ProgressRow {
  id: string;
  task_id: string;
  subtask_id: string | null;
  level: string;
  message: string;
  detail_json: string | null;
  created_at: string;
}

export const LIMITS = {
  maxSubtasks: 12,
  maxSteps: 6,
  maxAttempts: 3,
  planAttempts: 2,
  lockMs: 120_000,
  llmTimeoutMs: 20_000,
  fetchTimeoutMs: 12_000,
  maxToolCallsExecuted: 4,
  toolResultChars: 6_000,
  htmlChars: 80_000,
  textChars: 5_000,
  fetchBytes: 100_000,
  rateLimitCooldownMs: 60_000,
  stepsPerTick: 1,
} as const;

export const SERVICE = "jarvis-backend";
export const VERSION = "1.0.0";
export const GEMINI_MODEL = "gemini-3.8-flash";
export const GROQ_MODEL = "llama-3.3-70b-versatile";
export const GEMINI_URL = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions";
export const GROQ_URL = "https://api.groq.com/openai/v1/chat/completions";
export const CRON_EXPRESSION = "*/5 * * * *";
