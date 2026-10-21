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

CREATE TABLE IF NOT EXISTS call_questions (
  id TEXT PRIMARY KEY,
  call_id TEXT NOT NULL,
  question TEXT NOT NULL,
  status TEXT NOT NULL,
  answer TEXT NOT NULL DEFAULT '',
  timeout_seconds INTEGER NOT NULL,
  asked_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  resolved_at TEXT,
  origin TEXT NOT NULL DEFAULT '',
  notified INTEGER NOT NULL DEFAULT 0,
  follow_up_id TEXT
);

CREATE INDEX IF NOT EXISTS idx_call_questions_status ON call_questions (status, expires_at);

-- Sohail's own mobile and the limits that protect the Twilio balance. The number is saved from Settings.
CREATE TABLE IF NOT EXISTS call_settings (
  id TEXT PRIMARY KEY,
  mobile_number TEXT NOT NULL DEFAULT '',
  quiet_start TEXT NOT NULL DEFAULT '22:00',
  quiet_end TEXT NOT NULL DEFAULT '08:00',
  max_calls_per_day INTEGER NOT NULL DEFAULT 3,
  urgent_only INTEGER NOT NULL DEFAULT 0,
  question_timeout_seconds INTEGER NOT NULL DEFAULT 40,
  worker_origin TEXT NOT NULL DEFAULT '',
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS owner_alerts (
  id TEXT PRIMARY KEY,
  source_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  summary TEXT NOT NULL,
  detail TEXT NOT NULL,
  urgent INTEGER NOT NULL DEFAULT 0,
  channel TEXT NOT NULL,
  day TEXT NOT NULL,
  call_id TEXT,
  created_at TEXT NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_owner_alerts_source ON owner_alerts (source_id);

-- One temporary instruction for inbound calls, set by voice. Expired rows stay inactive.
CREATE TABLE IF NOT EXISTS call_away (
  id TEXT PRIMARY KEY,
  instruction TEXT NOT NULL,
  expires_at TEXT,
  active INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL
);

-- A business call that must come back to Sohail before JARVIS confirms.
CREATE TABLE IF NOT EXISTS call_delegations (
  id TEXT PRIMARY KEY,
  call_id TEXT NOT NULL,
  confirm_call_id TEXT,
  contact_name TEXT NOT NULL,
  to_number TEXT NOT NULL,
  goal TEXT NOT NULL,
  status TEXT NOT NULL,
  summary TEXT NOT NULL DEFAULT '',
  decision TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_call_delegations_call ON call_delegations (call_id);

-- Latest phone context. Coordinates are not stored.
CREATE TABLE IF NOT EXISTS owner_presence (
  id TEXT PRIMARY KEY,
  activity TEXT NOT NULL DEFAULT 'unknown',
  busy INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS call_recordings (
  call_id TEXT PRIMARY KEY,
  recording_sid TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

-- Why a hand-off succeeded or failed. No phone numbers and no provider secrets.
CREATE TABLE IF NOT EXISTS call_handoffs (
  id TEXT PRIMARY KEY,
  call_id TEXT NOT NULL,
  path TEXT NOT NULL,
  ok INTEGER NOT NULL,
  reason TEXT NOT NULL,
  detail TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_call_handoffs_created ON call_handoffs (created_at);

-- Text chat with the assistant. The webhook URL and key are Worker secrets, never rows.
CREATE TABLE IF NOT EXISTS agent_messages (
  id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL,
  role TEXT NOT NULL CHECK (role IN ('user', 'assistant')),
  text TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('pending', 'done')),
  reply_to TEXT,
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_agent_messages_conversation ON agent_messages (conversation_id, created_at);

-- Unread notes from finished inbound calls. The app speaks these; SMS stays the backup.
CREATE TABLE IF NOT EXISTS call_messages (
  id TEXT PRIMARY KEY,
  call_id TEXT NOT NULL,
  caller_name TEXT NOT NULL DEFAULT '',
  summary TEXT NOT NULL DEFAULT '',
  spoken TEXT NOT NULL,
  called_at TEXT NOT NULL,
  read_at TEXT,
  created_at TEXT NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_call_messages_call ON call_messages (call_id);
CREATE INDEX IF NOT EXISTS idx_call_messages_unread ON call_messages (read_at, created_at);

-- Prompt for the media bridge. The signed URL is not stored.
CREATE TABLE IF NOT EXISTS call_bridges (
  call_id TEXT PRIMARY KEY,
  first_message TEXT NOT NULL,
  prompt TEXT NOT NULL,
  created_at TEXT NOT NULL
);

-- Facts learned from texts. Birthdays use when_md (MM-DD). nudged_for is the occurrence date already texted.
CREATE TABLE IF NOT EXISTS owner_facts (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  subject TEXT NOT NULL,
  detail TEXT NOT NULL,
  when_md TEXT,
  nudged_for TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sms_turns (
  id TEXT PRIMARY KEY,
  phone TEXT NOT NULL,
  role TEXT NOT NULL,
  body TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_sms_turns_phone ON sms_turns (phone, created_at);

-- A one-time code from the app. Texting it links that phone as the owner.
CREATE TABLE IF NOT EXISTS sms_pairs (
  id TEXT PRIMARY KEY,
  code TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  used_phone TEXT,
  created_at TEXT NOT NULL
);

-- A comparison of businesses JARVIS is calling. Booking waits for an approval.
CREATE TABLE IF NOT EXISTS call_hunts (
  id TEXT PRIMARY KEY,
  goal TEXT NOT NULL,
  status TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS call_quotes (
  id TEXT PRIMARY KEY,
  hunt_id TEXT NOT NULL,
  call_id TEXT,
  business TEXT NOT NULL,
  phone TEXT NOT NULL,
  price TEXT,
  availability TEXT,
  fees TEXT,
  terms TEXT,
  summary TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL,
  book_call_id TEXT,
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_call_quotes_hunt ON call_quotes (hunt_id);
CREATE INDEX IF NOT EXISTS idx_call_quotes_call ON call_quotes (call_id);

-- Busy blocks posted by the phone. Used only to propose meeting times.
CREATE TABLE IF NOT EXISTS calendar_busy (
  id TEXT PRIMARY KEY,
  starts_at TEXT NOT NULL,
  ends_at TEXT NOT NULL,
  title TEXT NOT NULL DEFAULT '',
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

-- Named-agent tools and ElevenLabs voice. The voice id is optional and is not a secret.
CREATE TABLE IF NOT EXISTS persona_profiles (
  agent_id TEXT PRIMARY KEY,
  tools_json TEXT NOT NULL DEFAULT '[]',
  voice_id TEXT NOT NULL DEFAULT '',
  voice_name TEXT NOT NULL DEFAULT ''
);

-- One model step of a named-agent task, saved so the next cron tick can continue.
CREATE TABLE IF NOT EXISTS persona_task_state (
  task_id TEXT PRIMARY KEY,
  messages_json TEXT NOT NULL,
  step INTEGER NOT NULL DEFAULT 0,
  locked_until TEXT
);

-- JARVIS missions. Specialists are persona tasks linked below.
CREATE TABLE IF NOT EXISTS missions (
  id TEXT PRIMARY KEY,
  goal TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('planning', 'running', 'awaiting_approval', 'completed', 'failed')),
  report TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS mission_tasks (
  mission_id TEXT NOT NULL,
  task_id TEXT NOT NULL,
  PRIMARY KEY (mission_id, task_id)
);

-- Project Money is the shared room. Other rooms can be added later.
CREATE TABLE IF NOT EXISTS rooms (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  purpose TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS room_messages (
  id TEXT PRIMARY KEY,
  room_id TEXT NOT NULL,
  author TEXT NOT NULL,
  role TEXT NOT NULL,
  text TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_room_messages_room ON room_messages (room_id, created_at);

CREATE TABLE IF NOT EXISTS reminders (
  id TEXT PRIMARY KEY,
  agent_id TEXT NOT NULL,
  text TEXT NOT NULL,
  due_at TEXT,
  status TEXT NOT NULL DEFAULT 'open',
  created_at TEXT NOT NULL
);

INSERT INTO rooms (id, name, purpose, created_at)
SELECT
  'room_project_money',
  'Project Money',
  'EDITH, ULTRON, and FRIDAY compare notes on money-making projects. Mention someone with @EDITH, @ULTRON, @FRIDAY, or @JARVIS. Drafts stay drafts until you approve them.',
  '1970-01-01T00:00:00.000Z'
WHERE NOT EXISTS (SELECT 1 FROM rooms WHERE id = 'room_project_money');

INSERT INTO room_messages (id, room_id, author, role, text, created_at)
SELECT id, 'room_project_money', author, 'user', text, created_at
FROM group_messages
WHERE NOT EXISTS (SELECT 1 FROM room_messages WHERE room_messages.id = group_messages.id);

INSERT INTO scheduled_jobs (id, name, goal, cron, enabled, last_run_at, next_run_at, created_at)
SELECT
  'job_daily_briefing',
  'Daily briefing',
  'Prepare today''s briefing from stored findings, pending approvals, failed tasks, and the pipeline. Delegate research to EDITH, sales notes to ULTRON, and build notes to FRIDAY. Do not contact anyone and do not invent numbers.',
  '30 7 * * *',
  0,
  NULL,
  NULL,
  '1970-01-01T00:00:00.000Z'
WHERE NOT EXISTS (SELECT 1 FROM scheduled_jobs WHERE id = 'job_daily_briefing');

INSERT INTO scheduled_jobs (id, name, goal, cron, enabled, last_run_at, next_run_at, created_at)
SELECT
  'job_open_reminders',
  'Reminder sweep',
  'List open reminders and anything awaiting approval. Draft a short reminder. Do not send it.',
  '0 18 * * *',
  0,
  NULL,
  NULL,
  '1970-01-01T00:00:00.000Z'
WHERE NOT EXISTS (SELECT 1 FROM scheduled_jobs WHERE id = 'job_open_reminders');

INSERT INTO scheduled_jobs (id, name, goal, cron, enabled, last_run_at, next_run_at, created_at)
SELECT
  'job_pipeline_monitor',
  'Pipeline monitor',
  'Review the sales pipeline. Note prospects with no source URL and drafts waiting for approval. Delegate the reading to EDITH and the sales note to ULTRON. Do not contact anyone.',
  '0 9 * * 1',
  0,
  NULL,
  NULL,
  '1970-01-01T00:00:00.000Z'
WHERE NOT EXISTS (SELECT 1 FROM scheduled_jobs WHERE id = 'job_pipeline_monitor');
