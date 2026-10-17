-- JARVIS backend schema. Safe to re-run: every statement uses IF NOT EXISTS.
-- Apply with:
--   npx wrangler d1 execute jarvis-db --remote --file=./schema.sql

CREATE TABLE IF NOT EXISTS tasks (
  id TEXT PRIMARY KEY,
  goal TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('planning', 'running', 'awaiting_approval', 'completed', 'failed')),
  schedule TEXT,
  scheduled_job_id TEXT,
  error TEXT,
  result_summary TEXT,
  plan_attempts INTEGER NOT NULL DEFAULT 0,
  planner_note TEXT,
  locked_until TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  completed_at TEXT
);

CREATE TABLE IF NOT EXISTS subtasks (
  id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL,
  agent TEXT NOT NULL,
  title TEXT NOT NULL,
  instruction TEXT NOT NULL,
  action_level TEXT NOT NULL CHECK (action_level IN ('automatic', 'approval_required', 'explicit_authorisation')),
  depends_on_json TEXT NOT NULL DEFAULT '[]',
  status TEXT NOT NULL CHECK (status IN ('pending', 'running', 'awaiting_approval', 'completed', 'failed')),
  step INTEGER NOT NULL DEFAULT 0,
  max_steps INTEGER NOT NULL DEFAULT 6,
  messages_json TEXT,
  result_summary TEXT,
  error TEXT,
  attempt INTEGER NOT NULL DEFAULT 0,
  max_attempts INTEGER NOT NULL DEFAULT 3,
  next_attempt_at TEXT,
  locked_until TEXT,
  sort_order INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS progress_log (
  id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL,
  subtask_id TEXT,
  level TEXT NOT NULL CHECK (level IN ('info', 'warn', 'error')),
  message TEXT NOT NULL,
  detail_json TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS findings (
  id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL,
  subtask_id TEXT,
  claim TEXT NOT NULL,
  source_urls TEXT NOT NULL,
  excerpt TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS documents (
  id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL,
  subtask_id TEXT,
  kind TEXT NOT NULL CHECK (kind IN ('proposal', 'outreach_email', 'website_html', 'other')),
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  source_urls TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS approvals (
  id TEXT PRIMARY KEY,
  task_id TEXT,
  subtask_id TEXT,
  action TEXT NOT NULL,
  level TEXT NOT NULL CHECK (level IN ('automatic', 'approval_required', 'explicit_authorisation')),
  summary TEXT NOT NULL,
  payload_json TEXT,
  status TEXT NOT NULL CHECK (status IN ('pending', 'approved', 'rejected')),
  reason TEXT,
  created_at TEXT NOT NULL,
  decided_at TEXT
);

CREATE TABLE IF NOT EXISTS memory (
  id TEXT PRIMARY KEY,
  key TEXT,
  content TEXT NOT NULL,
  tags TEXT NOT NULL DEFAULT '[]',
  source_urls TEXT NOT NULL DEFAULT '[]',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS activity (
  id TEXT PRIMARY KEY,
  actor TEXT NOT NULL,
  action TEXT NOT NULL,
  task_id TEXT,
  detail_json TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS pipeline (
  id TEXT PRIMARY KEY,
  company TEXT NOT NULL,
  contact_name TEXT,
  contact_email TEXT,
  website TEXT,
  stage TEXT NOT NULL CHECK (stage IN (
    'prospect',
    'qualified',
    'contacted',
    'positive',
    'meeting',
    'proposal_sent',
    'negotiation',
    'won',
    'lost',
    'active_client'
  )),
  mrr REAL,
  notes TEXT,
  source_urls TEXT NOT NULL,
  task_id TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS scheduled_jobs (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  goal TEXT NOT NULL,
  cron TEXT NOT NULL,
  enabled INTEGER NOT NULL DEFAULT 0 CHECK (enabled IN (0, 1)),
  last_run_at TEXT,
  next_run_at TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS runtime_state (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_tasks_status_created ON tasks (status, created_at);
CREATE INDEX IF NOT EXISTS idx_subtasks_task ON subtasks (task_id, sort_order);
CREATE INDEX IF NOT EXISTS idx_subtasks_ready ON subtasks (status, next_attempt_at);
CREATE INDEX IF NOT EXISTS idx_progress_task ON progress_log (task_id, created_at);
CREATE INDEX IF NOT EXISTS idx_findings_task ON findings (task_id, created_at);
CREATE INDEX IF NOT EXISTS idx_documents_task ON documents (task_id, created_at);
CREATE INDEX IF NOT EXISTS idx_approvals_status ON approvals (status, created_at);
CREATE INDEX IF NOT EXISTS idx_activity_created ON activity (created_at);
CREATE INDEX IF NOT EXISTS idx_pipeline_stage ON pipeline (stage, updated_at);
CREATE INDEX IF NOT EXISTS idx_memory_updated ON memory (updated_at);
CREATE INDEX IF NOT EXISTS idx_jobs_enabled ON scheduled_jobs (enabled, next_run_at);

-- Example recurring job. Disabled until you turn it on (see README).
INSERT INTO scheduled_jobs (id, name, goal, cron, enabled, last_run_at, next_run_at, created_at)
SELECT
  'job_nightly_lead_research',
  'Nightly lead research',
  'Research up to 5 UK security companies, or Kent businesses with weak marketing or websites, that could be ASG prospects. Save each company as a pipeline prospect only when you have a real source URL. Do not invent contacts, revenue, or interest.',
  '0 2 * * *',
  0,
  NULL,
  NULL,
  '1970-01-01T00:00:00.000Z'
WHERE NOT EXISTS (
  SELECT 1 FROM scheduled_jobs WHERE id = 'job_nightly_lead_research'
);

-- Named persona agents (J.A.R.V.I.S., E.D.I.T.H., and the ones the phone creates).
CREATE TABLE IF NOT EXISTS persona_agents (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  role TEXT NOT NULL,
  instructions TEXT NOT NULL,
  avatar TEXT NOT NULL,
  color_hex TEXT NOT NULL,
  memory TEXT NOT NULL DEFAULT '',
  builtin INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS persona_messages (
  id TEXT PRIMARY KEY,
  agent_id TEXT NOT NULL,
  role TEXT NOT NULL,
  author TEXT NOT NULL,
  text TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS persona_tasks (
  id TEXT PRIMARY KEY,
  agent_id TEXT NOT NULL,
  goal TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('queued', 'working', 'done', 'needs_approval')),
  result TEXT,
  approval_summary TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS group_messages (
  id TEXT PRIMARY KEY,
  author TEXT NOT NULL,
  text TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_persona_messages_agent ON persona_messages (agent_id, created_at);
CREATE INDEX IF NOT EXISTS idx_persona_tasks_status ON persona_tasks (status, created_at);

-- Outbound AI calls. The Twilio token never lives in this file.
CREATE TABLE IF NOT EXISTS outbound_calls (
  id TEXT PRIMARY KEY,
  contact_name TEXT NOT NULL,
  to_number TEXT NOT NULL,
  brief TEXT NOT NULL,
  status TEXT NOT NULL,
  twilio_sid TEXT,
  conversation_id TEXT,
  transcript_json TEXT NOT NULL DEFAULT '[]',
  summary TEXT,
  error TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_outbound_calls_created ON outbound_calls (created_at);

-- Inbound screening. Default is to deny personal details.
CREATE TABLE IF NOT EXISTS call_screen (
  call_id TEXT PRIMARY KEY,
  direction TEXT NOT NULL,
  caller_phone TEXT,
  caller_name TEXT NOT NULL DEFAULT '',
  reason TEXT NOT NULL DEFAULT '',
  decision TEXT,
  personal_allowed INTEGER NOT NULL DEFAULT 0,
  personal_requested INTEGER NOT NULL DEFAULT 0,
  personal_note TEXT NOT NULL DEFAULT '',
  conference_name TEXT,
  notified_at TEXT,
  named_notified INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS call_devices (
  token TEXT PRIMARY KEY,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS call_permissions (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  phone TEXT,
  allow_personal INTEGER NOT NULL DEFAULT 0,
  note TEXT NOT NULL DEFAULT '',
  updated_at TEXT NOT NULL
);
