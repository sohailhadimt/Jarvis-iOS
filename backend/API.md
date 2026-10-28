# JARVIS backend API

Base URL after deploy: `https://jarvis-backend.<subdomain>.workers.dev`

All JSON. Timestamps are UTC ISO-8601 (`2026-10-15T02:00:00.000Z`). Unknown fields on input are ignored. The server never sends email, publishes a site, or takes payment. `external_actions` on health is `false`, and approval responses include `"external_action_taken": false`.

## Auth

Every route except `GET /health` and the Twilio and ElevenLabs call webhooks requires:

```http
Authorization: Bearer <JARVIS_APP_TOKEN>
```

| Status | Code | When |
|---|---|---|
| 401 | `unauthorized` | Header missing, not `Bearer`, or token does not match |
| 503 | `not_configured` | The Worker secret `JARVIS_APP_TOKEN` is not set |

Error body, used for every error:

```json
{
  "error": {
    "code": "unauthorized",
    "message": "Missing or invalid bearer token."
  }
}
```

Other codes: `bad_request` (400), `not_found` (404), `conflict` (409), `internal` (500).

`OPTIONS` on any path returns `204` with `Access-Control-Allow-Origin: *` and allow-headers `authorization, content-type`.

## Shared shapes

### Task

```json
{
  "id": "task_<32 hex chars>",
  "goal": "string",
  "status": "planning",
  "schedule": null,
  "scheduled_job_id": null,
  "error": null,
  "result_summary": null,
  "created_at": "2026-10-15T05:00:00.000Z",
  "updated_at": "2026-10-15T05:00:00.000Z",
  "completed_at": null
}
```

`status`: `planning` | `running` | `awaiting_approval` | `completed` | `failed`

`completed_at` is set only when `status` is `completed`. Failures leave it `null` and put the reason in `error`.

`result_summary` is specialist text. It is not a separate fact. Facts are the `findings` array.

### Subtask

```json
{
  "id": "sub_<32 hex>",
  "task_id": "task_<32 hex>",
  "agent": "research",
  "title": "string",
  "instruction": "string",
  "action_level": "automatic",
  "depends_on": ["sub_<32 hex>"],
  "status": "pending",
  "step": 0,
  "max_steps": 6,
  "attempt": 0,
  "result_summary": null,
  "error": null,
  "next_attempt_at": null,
  "created_at": "2026-10-15T05:00:00.000Z",
  "updated_at": "2026-10-15T05:00:00.000Z"
}
```

`agent`: `research` | `lead_gen` | `sales` | `outreach` | `marketing` | `website` | `analytics` | `admin` | `automation` | `quality_control`

`action_level`: `automatic` | `approval_required` | `explicit_authorisation`

`status`: `pending` | `running` | `awaiting_approval` | `completed` | `failed`

The model transcript is not returned. Use `progress`.

### Progress entry

```json
{
  "id": "log_<32 hex>",
  "task_id": "task_<32 hex>",
  "subtask_id": null,
  "level": "info",
  "message": "string",
  "detail": null,
  "created_at": "2026-10-15T05:00:00.000Z"
}
```

`level`: `info` | `warn` | `error`. `detail` is either `null` or a JSON value.

### Finding

```json
{
  "id": "find_<32 hex>",
  "task_id": "task_<32 hex>",
  "subtask_id": "sub_<32 hex>",
  "claim": "string",
  "source_urls": ["https://example.com/page"],
  "excerpt": null,
  "created_at": "2026-10-15T05:00:00.000Z"
}
```

`source_urls` has at least one `http` or `https` URL. The API will not store a finding without one.

### Document

```json
{
  "id": "doc_<32 hex>",
  "task_id": "task_<32 hex>",
  "subtask_id": "sub_<32 hex>",
  "kind": "proposal",
  "title": "string",
  "body": "string",
  "source_urls": ["https://example.com/page"],
  "created_at": "2026-10-15T05:00:00.000Z"
}
```

`kind`: `proposal` | `outreach_email` | `website_html` | `other`

A document is a stored draft. It has not been sent or published.

### Approval

```json
{
  "id": "apr_<32 hex>",
  "task_id": "task_<32 hex>",
  "subtask_id": "sub_<32 hex>",
  "action": "send_outreach",
  "level": "approval_required",
  "summary": "string",
  "payload": null,
  "status": "pending",
  "reason": null,
  "created_at": "2026-10-15T05:00:00.000Z",
  "decided_at": null
}
```

`level`: `approval_required` | `explicit_authorisation`

`status`: `pending` | `approved` | `rejected`

`payload` is `null` or an object. Payment-like actions are stored as `explicit_authorisation`.

### Memory

```json
{
  "id": "mem_<32 hex>",
  "key": null,
  "content": "string",
  "tags": ["preference"],
  "source_urls": [],
  "created_at": "2026-10-15T05:00:00.000Z",
  "updated_at": "2026-10-15T05:00:00.000Z"
}
```

Operator memory may have an empty `source_urls` array. Findings and pipeline rows may not.

### Pipeline row

```json
{
  "id": "lead_<32 hex>",
  "company": "Example Security",
  "contact_name": null,
  "contact_email": null,
  "website": null,
  "stage": "prospect",
  "mrr": null,
  "notes": null,
  "source_urls": ["https://example.com/"],
  "task_id": null,
  "created_at": "2026-10-15T05:00:00.000Z",
  "updated_at": "2026-10-15T05:00:00.000Z"
}
```

`stage`: `prospect` | `qualified` | `contacted` | `positive` | `meeting` | `proposal_sent` | `negotiation` | `won` | `lost` | `active_client`

`mrr` is a number in GBP per month, or `null` when unknown. `null` is not zero.

Leads created by the lead-gen agent always start at `prospect`. A manual `POST` may set another stage.

### Activity

```json
{
  "id": "act_<32 hex>",
  "actor": "api",
  "action": "task.created",
  "task_id": "task_<32 hex>",
  "detail": {},
  "created_at": "2026-10-15T05:00:00.000Z"
}
```

## GET /health

No auth.

`200`

```json
{
  "ok": true,
  "service": "jarvis-backend",
  "version": "1.0.0",
  "time": "2026-10-15T05:00:00.000Z",
  "cron": "*/5 * * * *",
  "external_actions": false,
  "db": "ok"
}
```

`503` when D1 cannot answer `SELECT 1`. Same fields, `"ok": false`, `"db": "error"`, plus `"message"`.

## POST /tasks

Creates a task and starts planning on this request (`waitUntil`). Later steps run on the cron.

```json
{
  "goal": "Find Kent security companies with weak websites.",
  "schedule": "0 2 * * *"
}
```

| Field | Required | Rules |
|---|---|---|
| `goal` | yes | string, 1–8000 characters |
| `schedule` | no | 5-field UTC cron, numeric only (`*`, numbers, lists, ranges, `*/n`). `null` or omitted means run once |

`201`

```json
{ "task": { } }
```

The task object is the Task shape. `status` is `planning`.

If `schedule` is set, a scheduled job is also created and enabled. The task still runs once now. The job's next run is the next matching minute after now.

`400` when `goal` is missing or `schedule` is not a cron expression.

## GET /tasks

Query:

| Param | Default | Rules |
|---|---|---|
| `limit` | 50 | integer 1–100 |
| `status` | all | one task status |

`200`

```json
{ "tasks": [] }
```

Newest first.

## GET /tasks/:id

`200`

```json
{
  "task": {},
  "subtasks": [],
  "progress": [],
  "findings": [],
  "documents": [],
  "approvals": []
}
```

Subtasks are in plan order. Progress, findings, documents, and approvals are oldest first.

`404` `{ "error": { "code": "not_found", "message": "Task not found." } }`

Poll this while `status` is `planning` or `running`. Expect minutes between steps on the free plan, not seconds.

## GET /briefing

Morning briefing for the last 24 hours, plus every still-pending approval and the current pipeline.

`200`

```json
{
  "generated_at": "2026-10-15T05:00:00.000Z",
  "window_start": "2026-10-14T05:00:00.000Z",
  "separation": "facts are rows stored by JARVIS. recommendations are suggestions derived only from those rows. A recommendation is not an extra fact.",
  "facts": {
    "completed_tasks": [],
    "failed_tasks": [],
    "pending_approvals": [],
    "results": {
      "findings": [],
      "documents": []
    },
    "pipeline": {
      "by_stage": {
        "prospect": 0,
        "qualified": 0,
        "contacted": 0,
        "positive": 0,
        "meeting": 0,
        "proposal_sent": 0,
        "negotiation": 0,
        "won": 0,
        "lost": 0,
        "active_client": 0
      },
      "rows": [],
      "mrr": {
        "currency": "GBP",
        "stages_counted": ["won", "active_client"],
        "known_total": 0,
        "rows_with_mrr": 0,
        "rows_missing_mrr": 0,
        "note": "Null mrr is unknown. It is not counted as zero."
      }
    }
  },
  "recommendations": [
    {
      "id": "no-work-in-window",
      "text": "No completed or failed tasks are stored in the last 24 hours. Create a task when you want work done.",
      "based_on": ["window:24h"]
    }
  ]
}
```

`facts.completed_tasks` are tasks completed since `window_start`. `facts.failed_tasks` failed since `window_start` (matched on `updated_at`). `facts.pending_approvals` is every pending approval, including older ones. `facts.results` are findings and documents created in the window. `facts.pipeline` is the current table, not only the window.

`recommendations[].based_on` entries are `approval:<id>`, `task:<id>`, `document:<id>`, `pipeline:<id>`, or `window:24h`. The text names only companies present in those rows.

Show `facts` and `recommendations` as separate sections in the app.

## GET /approvals

| Param | Default | Rules |
|---|---|---|
| `status` | all | `pending` \| `approved` \| `rejected` |
| `limit` | 50 | integer 1–100 |

`200` `{ "approvals": [] }`, newest first.

## POST /approvals

Queue an approval from the app. This does not perform the action.

```json
{
  "action": "send_outreach",
  "summary": "Send the stored draft to Example Security.",
  "task_id": "task_<32 hex>",
  "subtask_id": null,
  "level": "approval_required",
  "payload": { "document_id": "doc_<32 hex>" }
}
```

| Field | Required | Rules |
|---|---|---|
| `action` | yes | string, 1–80 characters |
| `summary` | yes | string, 1–2000 characters |
| `task_id` | no | string up to 80 characters, or null |
| `subtask_id` | no | string up to 80 characters, or null |
| `level` | no | `explicit_authorisation` or anything else (stored as `approval_required`). Payment words in the action or summary force `explicit_authorisation` |
| `payload` | no | object, JSON at most 8000 characters |

`201`

```json
{
  "approval": {},
  "external_action_taken": false
}
```

## POST /approvals/:id/approve

## POST /approvals/:id/reject

Body is optional. When `Content-Type` is `application/json`:

```json
{ "reason": "Not this company." }
```

`note` is accepted as an alias of `reason`. Max 2000 characters.

`200`

```json
{
  "approval": {},
  "external_action_taken": false
}
```

Approve sets `status` to `approved` and `decided_at`. If the approval has a `subtask_id`, that subtask becomes `completed` with a result that says nothing was sent. The task status is then recomputed.

Reject sets `status` to `rejected`. The linked subtask becomes `failed`, and the task becomes `failed`.

`404` if the id does not exist. `409` if it is already `approved` or `rejected`.

## GET /memory

| Param | Default | Rules |
|---|---|---|
| `q` | none | case-insensitive substring match on content, key, and tags |
| `limit` | 50 | integer 1–100 |

`200` `{ "memory": [] }`, most recently updated first.

`%` and `_` in `q` are matched literally.

## POST /memory

```json
{
  "content": "Prefer security companies in Kent.",
  "key": "preference.region",
  "tags": ["preference"],
  "source_urls": []
}
```

| Field | Required | Rules |
|---|---|---|
| `content` | yes | string, 1–4000 characters |
| `key` | no | string up to 120 characters, or null |
| `tags` | no | array of up to 12 strings, each 1–40 characters |
| `source_urls` | no | `[]` or public http(s) URLs. Private hosts are rejected |

`201` `{ "memory": {} }`

## DELETE /memory/:id

`200` `{ "deleted": true, "id": "mem_<32 hex>" }`

`404` if that id is not stored.

## GET /activity

Audit log.

| Param | Default | Rules |
|---|---|---|
| `limit` | 100 | integer 1–500 |

`200` `{ "activity": [] }`, newest first.

## GET /pipeline

| Param | Default | Rules |
|---|---|---|
| `stage` | all | one pipeline stage |
| `limit` | 100 | integer 1–200 |

`200` `{ "pipeline": [] }`, most recently updated first.

## POST /pipeline

Create a row. `source_urls` is required.

```json
{
  "company": "Example Security",
  "contact_name": null,
  "contact_email": null,
  "website": "https://example.com",
  "stage": "prospect",
  "mrr": null,
  "notes": null,
  "source_urls": ["https://example.com/"]
}
```

| Field | Required | Rules |
|---|---|---|
| `company` | yes | string, 1–200 characters |
| `source_urls` | yes | 1–12 public http(s) URLs |
| `stage` | no | a pipeline stage. Default `prospect` |
| `mrr` | no | number ≥ 0, or null. Major units (pounds), not pence |
| `contact_name` | no | string up to 200, or null |
| `contact_email` | no | mailbox form, or null |
| `website` | no | public http(s) URL, or null |
| `notes` | no | string up to 4000, or null |

`201` `{ "pipeline": {} }`

If the JSON body includes `id`, this updates that row instead of creating one. Same rules as below.

## POST /pipeline/:id

Update a row. Omitted fields stay as they are. You cannot clear `source_urls`.

```json
{
  "stage": "qualified",
  "mrr": 750,
  "notes": "Asked for a homepage rebuild."
}
```

`200` `{ "pipeline": {} }`

`404` if the id does not exist.

## Execution the client should expect

1. `POST /tasks` returns while `status` is `planning`.
2. The first cron-or-create step asks Gemini (then Groq) for a JSON plan and inserts subtasks. `status` becomes `running`.
3. Each later tick runs one specialist step: one model call and up to four tools, then saves.
4. A subtask that calls `request_approval` moves to `awaiting_approval` and stops. The task does too, once nothing else is still running.
5. `quality_control` runs last when the plan includes it. A final message containing `"pass": false` fails the task. Missing a pass/fail object still completes the task, and `result_summary` says the verdict was missing.
6. Rate limits and upstream errors are written to `progress` and retried with backoff (about 5 minutes, then 15). After the attempt budget, the subtask and the task are `failed` with the real error string.
7. Task and agent routes never send email, publish a site, or take payment. Outbound phone calls are separate: `POST /calls` asks Twilio to dial, and ElevenLabs speaks on that call. That path stays off until the calling secrets are set, and the app shows "Calling not set up" until then.

## Named agents

`GET /agents` returns `{ "agents": [] }` and seeds J.A.R.V.I.S., E.D.I.T.H., U.L.T.R.O.N., and F.R.I.D.A.Y. when they are missing.

`POST /agents` creates one. Body: `name`, `role`, `instructions`, optional `avatar` and `color_hex`. `201` `{ "agent": {} }`.

`POST /agents/:id` updates name, role, instructions, memory, avatar, or color. `DELETE /agents/:id` removes the agent and its thread.

`GET /agents/:id/messages` and `POST /agents/:id/messages` with `{ "author", "role", "text" }` are that agent's thread.

`POST /agent-tasks` with `{ "agent_id", "goal", "id?" }` queues work. `GET /agent-tasks` lists it. Status is `queued`, `working`, `done`, or `needs_approval`. The cron tick runs one queued task through Gemini. Sending, publishing, or spending becomes `needs_approval` and an approval row. Nothing is sent.

`POST /agent-tasks/:id/approve` and `POST /agent-tasks/:id/decline` mark the draft done and return `external_action_taken: false`. Approving or rejecting the matching row in `/approvals` does the same and still does not send, publish, or pay.

`GET /group` and `POST /group` with `{ "author", "text" }` are the shared room.

## ASG HQ

These routes serve the separate ASG HQ iPhone game. They use the same bearer token. The game reads progress and posts a line of talk. It does not post events for itself, and it does not call, send, or publish.

XP is the sum of rows in `hq_events`. The server assigns the points. A body field named `xp` is ignored.

| Kind | XP | Written by |
|---|---|---|
| `task_completed` | 120 | A task reaching `completed` |
| `task_done` | 80 | `POST /hq/events` from another system |
| `approval_approved` | 40 | An approval decision that is not a post |
| `post_approved` | 100 | An approved post or publish decision |
| `call_booked` | 150 | A call Twilio accepted. The summary is the contact name only |

The same `kind` and `source` are stored once. Phone-shaped numbers in a summary are replaced with `[number]`.

`GET /hq/progress` returns `xp`, `level`, `xp_into_level`, `xp_to_next`, `perks`, `daily`, `events`, and cosmetic `state`. Level 1 starts at 0 XP. Level `n` then costs `800 * n` XP. Perks: `outfit_pack` at level 3, `corner_office` at level 5, `rooftop` at level 8. The daily challenge rotates by UTC date between booking a call, finishing a task, and approving a post. `task_done` counts toward finishing a task.

`POST /hq/events` with `{ "kind", "source", "summary", "bot?" }` is how other systems add a row. `201` when the row is new, `200` with `awarded: false` when that source was already counted. `external_actions` is `false`.

`POST /hq/talk` with `{ "bot": "jarvis|friday|ultron|edith", "text" }` stores a persona task for that bot and returns `{ "reply", "status", "task_id", "stored", "external_action_taken": false }`. `status` is `draft` or `needs_approval`. A request to send, publish, call, or spend becomes a `persona_external` approval. Approving it in JARVIS still does not send, publish, or pay. If the model is not configured, the reply says so and nothing is invented as a completed send.

`POST /hq/state` saves `player_name`, `active_look`, `looks`, and `furniture`. Locked clothes and furniture are rejected with `403 perk_locked` until the level perk is real. This does not change XP.

If `hq_events` is missing, progress and event writes return `503 hq_not_ready`. Apply `schema.sql` (the deploy workflow does this on main). A missing table does not fail task completion, approvals, or call booking.

## Outbound calls

The iOS app never holds the Twilio auth token. These routes run on the worker. `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_FROM_NUMBER`, `ELEVENLABS_API_KEY`, and `ELEVENLABS_AGENT_ID` are wrangler secrets. Until every one of them is set, calling is not configured.

`GET /calls/config` (bearer token) returns:

```json
{ "configured": false, "message": "Calling not set up.", "missing": ["TWILIO_FROM_NUMBER"] }
```

`missing` lists secret names only. Values are never returned.

`POST /calls` body:

```json
{ "to": "+447700900123", "contact_name": "Ada", "brief": "The meeting moved to four." }
```

`201` `{ "configured": true, "call": {} }` after Twilio accepts the call. `503` with `calling_not_configured` when a secret is missing. The worker does not call Twilio in that case. `400` for a bad number, including 999, 112, and 911.

The call record has `id`, `contact_name`, `to`, `brief`, `status` (`placing`, `ringing`, `in_progress`, `wrapping`, `completed`, `failed`), `transcript` (`role` is `assistant` or `them`), `summary`, `error`, `created_at`, `updated_at`. It does not include the Twilio sid or any secret.

`GET /calls/:id` refreshes the transcript from ElevenLabs when a conversation id is known. `GET /calls` lists the latest 50.

Twilio's voice webhook is `POST /calls/voice/:id`. The status webhook is `POST /calls/twilio-status/:id`. Both require a valid `X-Twilio-Signature` and do not use the app bearer token. The voice webhook registers the call with ElevenLabs Conversational AI and returns that TwiML. The agent's first words are exactly: "Hello, this is Sohail's AI assistant. I'm calling on his behalf."

`POST /calls/elevenlabs` is the optional post-call webhook. It updates a call only when `user_id` or `conversation_id` matches a row this worker created. Set `ELEVENLABS_WEBHOOK_SECRET` to require the `ElevenLabs-Signature` header (`t=<unix>,v0=<hex hmac>` of `timestamp.body`).
