# JARVIS cloud backend

This is the autonomous backend for JARVIS. It runs on the **Cloudflare Workers free plan**: a Worker, one D1 database (SQLite), and a cron trigger every 5 minutes. It does not need a paid Cloudflare product, a server, or a credit card.

The iOS app is separate. This folder is the only part you deploy here. Phone wake features (Siri, the Action Button, Lock Screen widgets) only open listening on the iPhone. Task steps, screening timeouts, and problem-call checks stay on this worker's cron, including while the phone is locked.

## What it does

You send a goal. JARVIS (the chief of staff) breaks it into subtasks and hands each one to a specialist: research, lead generation, sales, outreach, marketing, website, analytics, admin, automation, or quality control.

The named team is the same idea with its own roster. EDITH researches, ULTRON drafts sales and strategy, and FRIDAY drafts pages, code, and schedules. Project Money (`/group`) is the room where they compare notes. `POST /missions` makes JARVIS assign the work. Up to three of those steps run on each cron tick. Send, spend, publish, and call stay drafts until you approve them. The daily briefing, reminder sweep, and pipeline monitor are scheduled jobs and stay off until you enable them.

Specialists can search the web, read a page, save a finding, save a sales prospect, and draft a proposal, an outreach email, or website HTML. **They cannot send email, publish a site, or pay anyone.** Those actions are drafts plus an approval. Approving a row records your decision. It still does not send anything.

Every finding and every lead must have a source URL. If a page was not fetched, that fact is not stored.

Work is done one model step at a time. The Workers free plan allows about **10 milliseconds of CPU** per run, so a long tool loop would be killed. Creating a task starts the first step immediately. Later steps run on the cron, every 5 minutes, and the conversation is saved in D1 between steps.

Models, in order:

1. Gemini `gemini-3.8-flash` at `https://generativelanguage.googleapis.com/v1beta/openai/chat/completions`
2. If Gemini returns HTTP 429, Groq `llama-3.3-70b-versatile`

`gemini-2.5-flash` is retired and is not used.

Search, in order: Tavily if `TAVILY_API_KEY` is set, otherwise Brave if `BRAVE_API_KEY` is set, otherwise a GET of DuckDuckGo's HTML results. `fetch_url` then GETs the page and extracts the text.

The work queue is a table in D1. Workers KV is not used: the free KV plan allows very few writes per day, and every step has to be saved. Cloudflare Queues are not required.

## 1. Create the free accounts

| Thing | Cost | Where |
|---|---|---|
| Cloudflare account | Free | [dash.cloudflare.com/sign-up](https://dash.cloudflare.com/sign-up) |
| Gemini API key | Free tier | [aistudio.google.com/apikey](https://aistudio.google.com/apikey) |
| Groq API key | Free tier | [console.groq.com/keys](https://console.groq.com/keys) |
| Tavily API key | Optional free tier | [tavily.com](https://tavily.com) |
| Brave Search API key | Optional free tier | [api.search.brave.com](https://api.search.brave.com/) |
| App token | You invent it | `openssl rand -hex 32` |

You need Gemini or Groq. Both is better, because a Gemini 429 falls through to Groq. Tavily and Brave are optional. With neither key, search uses DuckDuckGo HTML.

## 2. Install and log in

From this `backend/` folder, on your own machine:

```bash
cd backend
npm install
npx wrangler login
```

`wrangler login` opens a browser and asks you to allow Wrangler on your Cloudflare account. That is the free account from step 1.

## 3. Create the D1 database

```bash
npx wrangler d1 create jarvis-db
```

The command prints a `database_id`. Open `wrangler.toml` and replace `00000000-0000-0000-0000-000000000000` with that id. The binding name stays `DB` and the database name stays `jarvis-db`.

The database id is not a secret. You can commit it. GitHub Actions does not need that commit: the deploy workflow looks up `jarvis-db` by name, creates it when it is missing, and writes the id into `wrangler.toml` for that run.

## 4. Apply the schema

```bash
npx wrangler d1 execute jarvis-db --remote --file=./schema.sql
```

This creates the tables. It is safe to run again. It also inserts a **disabled** nightly lead-research job (`0 2 * * *` UTC). Nothing calls the model until you enable that job or create a task.

For local `wrangler dev`:

```bash
npx wrangler d1 execute jarvis-db --local --file=./schema.sql
```

## 5. Set the secrets

Secrets stay on Cloudflare. They are not written into the repo.

```bash
npx wrangler secret put GEMINI_API_KEY
npx wrangler secret put GROQ_API_KEY
npx wrangler secret put JARVIS_APP_TOKEN
```

Optional:

```bash
npx wrangler secret put TAVILY_API_KEY
npx wrangler secret put BRAVE_API_KEY
```

Phone calls, once the UK number exists. The auth token is a worker secret. It is not written into the repo and it is not put in the iOS app.

```bash
npx wrangler secret put TWILIO_ACCOUNT_SID
npx wrangler secret put TWILIO_AUTH_TOKEN
npx wrangler secret put TWILIO_FROM_NUMBER
npx wrangler secret put ELEVENLABS_API_KEY
npx wrangler secret put ELEVENLABS_AGENT_ID
```

When those values are GitHub Actions secrets, the deploy workflow runs `wrangler secret put` for each one that is present and skips the rest. It never prints the values. Optional, for the post-call webhook:

```bash
npx wrangler secret put ELEVENLABS_WEBHOOK_SECRET
```

Inbound screening, after the number exists. These stay empty until you are ready. `OWNER_PHONE` is your own mobile, in E.164. Put-through, take-over, the SMS fallback, and problem calls ring that number. Set it when you deploy. Do not commit it. The same number can also be typed later in the app under Calling. That copy stays in the iPhone Keychain and, once you tap save, overrides the secret. Push needs an APNs auth key and the Push capability on the App ID.

```bash
npx wrangler secret put OWNER_PHONE
npx wrangler secret put APNS_KEY_ID
npx wrangler secret put APNS_TEAM_ID
npx wrangler secret put APNS_PRIVATE_KEY
```

Until those five calling secrets are set, `GET /calls/config` reports `"message": "Calling not set up."` and `POST /calls` does not dial.

Paste the key when prompted, then press Enter. `JARVIS_APP_TOKEN` is the bearer token the iOS app will send. Generate one with:

```bash
openssl rand -hex 32
```

Use the same value in the app. For local dev, copy `.dev.vars.example` to `.dev.vars` and fill it in. `.dev.vars` is gitignored.

## 6. Deploy

```bash
npx wrangler deploy
```

The live worker is `https://jarvis-backend.jarvis-hadi.workers.dev`. Check it:

```bash
curl https://jarvis-backend.jarvis-hadi.workers.dev/health
```

You want `"ok": true` and `"db": "ok"`. Then, with your token:

```bash
curl -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"goal":"Find one Kent security company with a public website and save it only if you have the page URL."}' \
  https://jarvis-backend.jarvis-hadi.workers.dev/tasks
```

Poll `GET /tasks/:id`. The first planning step starts immediately. Further steps wait for the next 5-minute cron. The endpoint shapes are in [API.md](API.md).

## 7. Turn on automatic deploys

In the GitHub repo: **Settings → Secrets and variables → Actions → New repository secret**.

| Secret | Value |
|---|---|
| `CLOUDFLARE_API_TOKEN` | A Cloudflare API token (see below) |
| `CLOUDFLARE_ACCOUNT_ID` | The account id on the Cloudflare dashboard overview (right-hand side) |

Create the token at [dash.cloudflare.com/profile/api-tokens](https://dash.cloudflare.com/profile/api-tokens). Use a custom token, not the global key.

- Permissions: **Account → Workers Scripts → Edit**, **Account → D1 → Edit**
- Account resources: your account

`.github/workflows/deploy-backend.yml` runs when `backend/` changes on `main` or on a pull request, and when started by hand. It typechecks, tests, creates or reuses the D1 database `jarvis-db`, applies `schema.sql`, deploys, then copies worker secrets from GitHub when those secrets exist. `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` are required. A missing Twilio, Gemini, Groq, ElevenLabs, or app-token secret is skipped and listed in the job summary.

## Nightly lead research

The schema inserts `job_nightly_lead_research` with `enabled = 0`. To turn it on:

```bash
npx wrangler d1 execute jarvis-db --remote --command "UPDATE scheduled_jobs SET enabled = 1, next_run_at = NULL WHERE id = 'job_nightly_lead_research';"
```

It then creates one task each day at 02:00 UTC, on the 5-minute tick that matches that minute. The goal tells the specialists to save a prospect only when they have a source URL.

You can also pass `schedule` on `POST /tasks`. That runs the goal once now and creates an enabled scheduled job for later. Cron fields are numeric, five fields, UTC. Example: `"0 2 * * *"`.

## Outbound phone calls

Saying "call Sam and tell them the meeting moved" in the app looks up Sam, then waits for a spoken or tapped yes. The app asks this worker to dial. Twilio and ElevenLabs credentials stay here.

The worker places the call with the Twilio Calls API and, when Twilio requests TwiML, registers it with ElevenLabs Conversational AI (`POST /v1/convai/twilio/register-call`). ElevenLabs speaks with the agent's voice and streams audio with Twilio. The worker does not bridge the audio itself.

Every outbound call starts with: "Hello, this is JARVIS, Master Hadi's personal assistant. Master Hadi has asked me to tell you …" and then the message. JARVIS listens, stays inside the brief, and the summary comes back to the iPhone.

If the other person asks something outside the brief, JARVIS says "One moment please" and the question is pushed to the iPhone. A typed or spoken reply is relayed. If nobody answers within the configured 30 to 45 seconds, JARVIS says he will find out and call back, and a follow-up task is left for Sohail.

JARVIS can also ring `OWNER_PHONE` when a task fails, a call does not connect, or the Twilio balance is low. A number saved from Calling settings on the iPhone is used instead when one is set. That call uses the ElevenLabs voice, with a short summary and a way to press 1 or say "details". Quiet hours and a daily cap (three by default) keep it inside the balance. Outside those limits he sends a push notification instead.

On the ElevenLabs agent, telephony needs μ-law 8000 Hz in both directions. Otherwise `register-call` rejects the hand-off and the caller hears the British Polly fallback instead of JARVIS. The first call asks ElevenLabs to set that audio format, to set the voice to George (`JBFqnCBsd6RMkjVDRZzb`, the same voice as the iPhone), and to allow per-call overrides of the first message, system prompt, language, and voice. The API key has to be allowed to edit the agent. The worker does not replace the agent's prompt text.

If that update is refused, set the same four things yourself:

- Voice: output format μ-law 8000 Hz, and the voice George.
- Advanced: input format μ-law 8000 Hz.
- Security: allow overriding the first message, the system prompt, the language, and the voice.

You can also set the agent's first message to `{{opening_line}}` and mention `{{contact_name}}` and `{{brief}}` in its prompt. Inbound calls still send those variables when overrides are off.

Leave the Twilio number's voice webhook on this worker. Importing the number into the ElevenLabs dashboard replaces that webhook. Optional post-call webhook: `https://<your-worker>/calls/elevenlabs`.

Apply `schema.sql` so the call tables exist before the first real call.

## Inbound screening

An iPhone cannot intercept a normal carrier call. Forward the mobile to the Twilio number with the GSM codes shown in Settings. The deploy workflow sets number `PN66046ff3fcdfc8f9aa8ed11811dd9d5d` so voice is `POST https://jarvis-backend.jarvis-hadi.workers.dev/calls/inbound` and SMS is `POST https://jarvis-backend.jarvis-hadi.workers.dev/calls/sms`. Running the workflow again sets the same URLs.

JARVIS answers: "Hello, you've reached Master Hadi's phone, this is JARVIS his personal assistant. This call may be handled by AI. Who's calling and how can I help?"

The app shows Put me through, Let JARVIS handle it, Take a message, and Decline. Put me through uses Twilio `<Dial>` to the mobile saved in Calling settings, or to `OWNER_PHONE` when that field is empty. Take over moves the caller into a conference and rings that same mobile, which drops the AI. Listen-in on the iPhone is the live transcript. In-app muted audio needs the Twilio Voice SDK, which is not linked in this build.

Schedule, location, and other personal details are denied unless that person is allowed in Settings or you approve the live prompt. Push uses `APNS_KEY_ID`, `APNS_TEAM_ID`, and `APNS_PRIVATE_KEY` when the App ID has Push Notifications. Otherwise the worker texts that same mobile.

## ASG context the model is given

These are founder-supplied facts, not researched ones:

- ASG (Adz Security Growth) is a marketing, digital growth, and web development agency.
- It serves security companies, and any business with weak marketing or a weak website.
- It is based in Kent, United Kingdom.
- The founder is Sohail.

Proposals may use only those facts plus findings that have source URLs. Prices, case studies, and client results are unknown unless a finding says so.

## Free-plan limits that affect behaviour

- About 10 ms of CPU per invocation. One model call, then save.
- Cron: `*/5 * * * *`. The free plan allows this. A task with several steps takes several ticks.
- 100,000 Worker requests per day. The cron alone is about 288 requests per day.
- D1 free storage is enough for drafts, findings, and the pipeline.
- Gemini's free tier rate-limits. HTTP 429 stores a one-minute cooldown and the same step is tried on Groq.
- Failures are stored as failures. A rate limit is a rate limit, not a completed task.

## Local checks

```bash
npm install
npx tsc --noEmit
npx vitest run
npx wrangler dev
```
