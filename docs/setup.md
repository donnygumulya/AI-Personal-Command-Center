# AIPCC — Setup (Phase 1)

Local setup on Windows, using Docker for n8n + Postgres and ngrok to expose a public HTTPS webhook for Telegram.

## Prerequisites

- Docker Desktop, running
- A Telegram account
- An OpenAI API key
- A Google Cloud account (for Calendar API access)
- A free ngrok account

## 1. Environment

### 1.1 Project folder

```powershell
cd $HOME\Desktop\Projects
mkdir AIPCC
cd AIPCC
mkdir docs, n8n, sql
```

### 1.2 `docker-compose.yml`

```yaml
services:
  postgres_aipcc:
    image: postgres:16
    container_name: aipcc_postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: aipcc_user
      POSTGRES_PASSWORD: aipcc_pass
      POSTGRES_DB: aipcc_db
    ports:
      - "5433:5432"
    volumes:
      - aipcc_pg_data:/var/lib/postgresql/data

  n8n_aipcc:
    image: n8nio/n8n:latest
    container_name: aipcc_n8n
    restart: unless-stopped
    ports:
      - "5679:5678"
    environment:
      - N8N_SECURE_COOKIE=false
      - GENERIC_TIMEZONE=Asia/Jakarta
      - TZ=Asia/Jakarta
      - WEBHOOK_URL=https://${NGROK_DOMAIN}/
    volumes:
      - aipcc_n8n_data:/home/node/.n8n
    depends_on:
      - postgres_aipcc

volumes:
  aipcc_pg_data:
  aipcc_n8n_data:
```

Non-default ports (5433, 5679 instead of 5432, 5678) avoid clashing with any other local Postgres/n8n instances. `WEBHOOK_URL` gets filled in properly once the ngrok domain is claimed (step 3) — leave it out or blank for the first `docker compose up -d`.

**Watch your indentation** — every service (`postgres_aipcc`, `n8n_aipcc`) must sit at the same 2-space level under `services:`. A misaligned service name breaks the whole file silently (YAML reads it as a nested key instead of a sibling service).

### 1.3 Start containers

```powershell
docker compose config   # validates the YAML before starting anything
docker compose up -d
docker ps                # confirm both containers show "Up"
```

n8n is now reachable at `http://localhost:5679` — but only locally, and (important, see step 5) some flows require reaching it via a public domain instead.

## 2. Telegram bot

1. Telegram → search **@BotFather** → `/newbot`
2. Give it a name and a `bot`-suffixed username
3. Save the bot token BotFather returns
4. Verify it:
   ```powershell
   Invoke-RestMethod -Uri "https://api.telegram.org/bot<TOKEN>/getMe"
   ```

## 3. ngrok tunnel

Telegram's webhook requires a public HTTPS URL — `localhost` isn't reachable from Telegram's servers.

```powershell
winget install ngrok.ngrok
ngrok config add-authtoken <YOUR_TOKEN>
```

Claim a **free static domain** in the ngrok dashboard (Domains → Create Domain). Without one, the URL changes every time you restart the tunnel, which then requires re-editing `docker-compose.yml` and re-registering every OAuth credential each time — worth the two minutes to set up once.

```powershell
ngrok http 5679 --domain=YOUR-NGROK-DOMAIN
```

**Leave this running in its own terminal window for the entire time you're using the bot.** If it's closed (or your machine sleeps), Telegram silently can't reach n8n anymore — this was the cause of several confusing failures during initial setup that looked like credential or code problems but were actually just a dead tunnel.

Put the real domain (no scheme, no slash) in a `.env` file next to `docker-compose.yml`. Compose reads it automatically, and `.env` is gitignored so your domain stays out of the repo:
```
NGROK_DOMAIN=your-name-123.ngrok-free.dev
```
then:
```powershell
docker compose up -d
```

## 4. Postgres schema

`sql/schema.sql`:
```sql
CREATE TABLE IF NOT EXISTS tasks (
    id              SERIAL PRIMARY KEY,
    telegram_chat_id BIGINT NOT NULL,
    title           TEXT NOT NULL,
    description     TEXT,
    due_at          TIMESTAMPTZ,
    status          TEXT NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending', 'completed', 'cancelled')),
    reminded_at     TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_tasks_chat_status ON tasks (telegram_chat_id, status);
CREATE INDEX IF NOT EXISTS idx_tasks_due_at ON tasks (due_at) WHERE due_at IS NOT NULL;
```

Apply it — via DBeaver (host `localhost`, port `5433`, db `aipcc_db`, user/pass `aipcc_user`/`aipcc_pass`) or:
```powershell
Get-Content sql\schema.sql | docker exec -i aipcc_postgres psql -U aipcc_user -d aipcc_db
```

## 5. n8n workflow

Import `n8n/workflow-phase1.json` directly (Workflows → Import from File), or build it node-by-node. Node names below match the importable file — using the same descriptive names if you build by hand makes the Phase 2 instructions later (§8) easier to follow, since they reference these nodes by name:

`Telegram Trigger → OpenAI ("Message a model") → Code ("Parse Intent Response") → Switch ("Route by Intent", 5 outputs) → per-branch action → Telegram (reply)`

`Parse Intent Response` extracts `intent`/`title`/`description`/`due_at`, plus `query_date` (set when the user names a specific day, e.g. "today"/"tomorrow") and the `range_start`/`range_end` pair computed from it — these feed the `list_tasks` SQL filter and the `list_events` calendar window (see step 6.5 and `docs/architecture.md` §"Intent classification").

### Credentials needed inside n8n:
- **Telegram** — the bot token from step 2
- **OpenAI** — your API key, model `gpt-4o-mini`
- **Postgres** — host `postgres_aipcc` (Docker service name, **not** `localhost`), port `5432` (the internal container port, **not** `5433`), db/user/pass as in step 1.2
- **Google Calendar** — see step 6, the trickiest part of setup

### A gotcha worth knowing up front

The OpenAI "Message a model" node's actual output path in the "Parse Intent Response" Code node may not match the commonly-documented `$json.message.content`. Check the real shape by running the OpenAI node once and inspecting its output — in this build it was:
```javascript
$input.item.json.output[0].content[0].text
```

Another gotcha worth knowing before you build much further: **nodes like Postgres, Telegram, and Calendar don't merge their result into the item's JSON — they replace it entirely.** Any expression downstream of one of those that needs earlier data (e.g. the original title from `Parse Intent Response`) must reference that node explicitly — `$('Parse Intent Response').item.json.title`, not `$json.title` — or it'll silently read `undefined`. See `docs/architecture.md` §"Known issues" for the fuller version of this (including a "Multiple matching items" error you can hit if you reach back across such a node with multiple items in flight, and the fan-out pattern that avoids it).

## 6. Google Calendar OAuth

This step has the most sharp edges. Follow this order exactly.

### 6.1 Google Cloud Console

1. New (or existing) project → enable **Google Calendar API**
2. **APIs & Services → OAuth consent screen**:
   - User type: External
   - Add yourself under **Test users** (exact email you'll sign in with)
   - Under **Authorized domains**: if your ngrok domain is on the public suffix list (`ngrok-free.app` / `ngrok-free.dev` are), enter your **full assigned subdomain**, e.g. `your-name-123.ngrok-free.dev` — not just `ngrok-free.dev`. Google won't accept the bare base domain since it doesn't belong to you, only your specific subdomain does.
3. **APIs & Services → Credentials → Create Credentials → OAuth client ID**, type **Web application**

### 6.2 Get the redirect URI from n8n first

In the Google Calendar node's credential form, n8n shows an OAuth Redirect URL like:
```
https://YOUR-NGROK-DOMAIN/rest/oauth2-credential/callback
```
Copy it exactly into **Authorized redirect URIs** on the OAuth client, then finish creating it to get a Client ID + Secret.

### 6.3 The critical step: access n8n via the ngrok URL, not localhost, for the OAuth flow

**Do the entire "Sign in with Google" flow from `https://YOUR-NGROK-DOMAIN`, not `http://localhost:5679`.**

This one caused the most debugging time during initial setup. n8n sets a session/CSRF-state cookie scoped to whichever origin you're browsing from. If you start the OAuth flow from `localhost` but the callback returns to the ngrok domain, the cookie doesn't carry over (different origins don't share cookies), so n8n can't validate its own CSRF state and the flow fails with a generic `Unauthorized` / `OAuth2 callback failed` error — no useful message on the browser's side, and only visible as `decodeCsrfState` failing if you check `docker logs aipcc_n8n` with debug logging on.

If you hit this: open n8n via the ngrok URL, delete any half-created Google Calendar credential, and redo the credential creation + sign-in flow entirely from that origin, in one continuous pass (don't reuse old tabs/links).

### 6.4 Other things that can cause the same generic failure

- **System clock drift.** Windows can silently fall out of sync, and Google's OAuth token exchange rejects requests that look mistimed. Check with `w32tm /query /status` (want `Leap Indicator: 0`) and fix with `w32tm /resync /force` (run PowerShell as Administrator) if not.
- **Stale/duplicate credentials in n8n** from earlier failed attempts — delete all but one before retrying.

### 6.5 Configure the Calendar nodes

**Create branch** ("Create an event") — Resource: Event, Operation: Create:
- Start: `{{ $('Parse Intent Response').item.json.due_at }}`
- End: `{{ new Date(new Date($('Parse Intent Response').item.json.due_at).getTime() + 60*60*1000).toISOString() }}`
- Summary: `{{ $('Parse Intent Response').item.json.title }}`

**List branch** ("Get many events") — Resource: Event, Operation: Get Many:
- Time Min: `={{ $json.range_start }}`
- Time Max: `={{ $json.range_end }}`

(`range_start`/`range_end` come straight from `Parse Intent Response` via `$json` here, since **Route by Intent** — a Switch node — is a pure passthrough that doesn't touch the data; no explicit node-name reference is needed at this specific spot. They resolve to "now → +7 days" for a plain "what's on my calendar," or a single day's boundaries when `query_date` was set — see the note in step 5.)

**Enable "Always Output Data"** (Settings tab) on this node — without it, a day/range with zero events causes n8n to skip the downstream formatter entirely rather than running it with an empty list, so the user gets no reply at all instead of "Nothing on your calendar." See `docs/architecture.md` §"Known issues" for why. The formatter Code node ("Format Event List") correspondingly filters out the placeholder item this produces via `.filter(ev => ev && ev.id)` before checking for the empty case.

## 7. Testing

n8n's Telegram Trigger can't listen for test events and production events simultaneously. Debug loop:

1. Unpublish the workflow
2. Open **Telegram Trigger** → **Listen for Test Event**
3. Send a message from Telegram
4. Watch execution flow across the canvas, click any red-flagged node for its error
5. Once it works, **Publish** again to run headless (bot works without the n8n editor open)

Test phrasings worth trying for each branch:
- *"remind me to call the bank tomorrow at 3pm"* → `create_task`
- *"what are my tasks"* → `list_tasks` (all pending, `query_date: null`)
- *"what are my tasks today"* / *"apa tugas saya hari ini"* → `list_tasks` with `query_date` set to today — works across languages, since the model resolves the date, not just the keyword
- *"schedule a meeting with John Friday at 10am"* → `create_event`
- *"what's on my calendar this week"* → `list_events` (next 7 days, `query_date: null`)
- *"what's on my calendar tomorrow"* / *"what did I have yesterday"* → `list_events` with `query_date` set to that specific day — confirm the reply says "Nothing on your calendar for `<date>`" rather than the generic "next 7 days" message when there's nothing that day
- *"hey"* / something vague → `unknown`

`list_tasks` vs `list_events` is the one pair worth testing a few different phrasings of — the model doesn't always distinguish them cleanly.

## Troubleshooting quick reference

| Symptom | Likely cause |
|---|---|
| Telegram message produces no n8n execution at all | ngrok tunnel not running, or workflow not actually published |
| `Cannot read properties of undefined (reading 'content')` in "Parse Intent Response" | OpenAI node's output path doesn't match `message.content` — check the real shape (see step 5) |
| Message always routes to Fallback despite correct intent | Typo/placeholder value in a Switch routing rule (e.g. leftover `value2`) |
| `new row ... violates check constraint "tasks_status_check"` | A field is being explicitly mapped to `status` with an invalid value — leave `status` unmapped so the schema default applies |
| `duplicate key value violates unique constraint "tasks_pkey"` | `id` is being explicitly mapped in the Postgres Insert node — remove it, `SERIAL` handles it |
| OAuth `Unauthorized` / `decodeCsrfState` failure | Started the OAuth flow from `localhost` instead of the ngrok URL (see 6.3), or clock drift (see 6.4) |
| `Invalid domain: must not be empty` on OAuth consent screen | Authorized domains needs the full ngrok subdomain, not the bare `ngrok-free.dev` (see 6.1) |
| Asking about a day with zero events/tasks gets **no reply at all** | The "get many" node (Calendar or Postgres) returned zero items, and n8n skipped every downstream node on that connection rather than running them with an empty list. Enable **Always Output Data** on the "get many" node and filter the placeholder item out in its formatter (see step 6.5). |
| A field that should have a value from an earlier node reads `undefined` | You're using `$json` after a Postgres/Telegram/Calendar node, which replaces the item's JSON with its own output instead of merging. Reference the earlier node explicitly, e.g. `$('Parse Intent Response').item.json.title` (see the gotcha in step 5). |
| `Multiple matching items for item [N]` error on a node-name expression like `$('SomeNode').item...` | n8n can't resolve which upstream item corresponds to the current one, usually because a node in between (often a Postgres write) didn't preserve item lineage. Restructure so the node needing that data reads `$json` directly from its immediate parent instead of reaching backward — fan the parent's output out to multiple sibling nodes in parallel rather than chaining them through each other. See `docs/architecture.md` §"Known issues". |

## 8. Phase 2 — Gmail email-to-task setup

Full design/rationale: `docs/architecture.md` §"Phase 2 — Email-derived tasks". This section is the concrete build steps.

### 8.1 Apply the Phase 2 schema

`sql/schema.sql` now also defines `processed_emails` and `pending_confirmations`. If you didn't reapply the whole file, add just the new tables:

```powershell
Get-Content sql\schema.sql | docker exec -i aipcc_postgres psql -U aipcc_user -d aipcc_db
```

(`CREATE TABLE IF NOT EXISTS` makes this safe to rerun against an existing database — it won't touch `tasks` or `message_log`.)

### 8.2 Find your Telegram chat ID

The Gmail-poll workflow runs on a schedule, not from an incoming Telegram message, so it has no `chat.id` to read — you set it once as a fixed value. Easiest way: send your bot any message, then in n8n open the Phase 1 workflow, run **Listen for Test Event**, send a message again, and read `message.chat.id` off the Telegram Trigger's output panel. Keep that number for step 8.5.

### 8.3 Gmail OAuth credential

Same shape as the Google Calendar credential (step 6), reusing the same Google Cloud project:

1. **APIs & Services → Library** → enable the **Gmail API**.
2. You can reuse the existing OAuth client from step 6.2, or create a separate one — either way, add the same n8n OAuth Redirect URL (`https://YOUR-NGROK-DOMAIN/rest/oauth2-credential/callback`) to **Authorized redirect URIs** if it isn't already there.
3. In n8n, create a new **Gmail** credential. Same warning as 6.3 applies: do the sign-in flow from the ngrok URL, not `localhost`, or you'll hit the same CSRF/`Unauthorized` failure.
4. Scope needed: read-only is enough (`gmail.readonly`) since this workflow only reads mail, never sends or modifies it.

### 8.4 Decide your sender/label allowlist

Pick whichever is less maintenance for you:
- **Label-based**: create a Gmail filter that applies a label (e.g. `AIPCC`) to mail from senders you care about, then query `label:AIPCC is:unread` in the Gmail node.
- **Sender-based**: query directly, e.g. `is:unread from:(boss@company.com OR billing@bank.com)`.

Either way, keep `is:unread` in the query — it's your cheapest filter and prevents already-seen mail from being pulled every poll (on top of the `processed_emails` check).

### 8.5 Build the Gmail-poll workflow (new, separate workflow)

Create a new n8n workflow (e.g. "AIPCC - Phase 2 Email Scan") — don't add this into the Phase 1 workflow, it has its own trigger. Use descriptive node names as you go (shown below) rather than n8n's defaults ("Code1", "Execute a SQL query2", ...) — it makes every later expression referencing a node by name much easier to get right, and this is exactly the kind of confusion that cost real debugging time while building this.

```
Schedule Trigger ("Poll Gmail", every 15 minutes)
  → Gmail: Get Many, renamed to "Gmail"
      Query: from step 8.4, e.g. "label:AIPCC is:unread"
  → Postgres ("Check Already Processed"): Execute Query
      SELECT NOT EXISTS (
        SELECT 1 FROM processed_emails WHERE gmail_message_id = '{{ $json.id }}'
      ) AS is_new;
  → IF ("Is New Email?"): {{ $json.is_new }} is true
       True  → continue below
       False → dead end, nothing to do
  → OpenAI ("Judge Actionability") — system prompt along the lines of:
      "Given this email's sender, subject, and body, decide whether it requires
       the user to take a concrete action. Return ONLY JSON:
       { "actionable": bool, "title": string|null, "description": string|null,
         "due_at": ISO-8601 string|null }."
      User message: ={{ "From: " + $('Gmail').item.json.From + "\nSubject: " +
        $('Gmail').item.json.Subject + "\nBody: " + $('Gmail').item.json.snippet }}

      Check your Gmail node's actual field names before wiring this — they may
      be capitalized (`From`, `Subject`) rather than lowercase; using the wrong
      case doesn't error, it just silently sends "From: undefined" to the model.
  → Code ("Parse Actionability Response") — parse the JSON response defensively
    (same pattern as Phase 1's "Parse Intent Response": strip ```json fences,
    fall back to { actionable: false, title: null, ... } on a parse failure),
    and flatten in the fields the next steps need:
      return { json: { ...parsed,
        gmail_message_id: $('Gmail').item.json.id,
        email_from: $('Gmail').item.json.From,
        email_subject: $('Gmail').item.json.Subject
      } };
  → IF ("Is Actionable?"): {{ $json.actionable }} is true
       True  → fan out to THREE parallel nodes (all reading $json directly from
               this IF node — see the fan-out note below):
                 - Postgres ("Insert Pending Confirmation"): INSERT INTO
                   pending_confirmations (telegram_chat_id, title, description,
                   due_at, source_gmail_message_id) VALUES (<your chat ID from
                   8.2>, $json.title, $json.description, $json.due_at,
                   $json.gmail_message_id) — escape single quotes in
                   title/description (free text you don't control)
                 - Telegram ("Send Proposal"): chatId = <your chat ID>, text =
                   "📧 From: {{ $json.email_from }} — {{ $json.email_subject }}
                    \nSuggested task: {{ $json.title }}{{ $json.due_at ? ' — due '
                    + $json.due_at : '' }}\nReply YES to add, NO to skip."
                 - Postgres ("Mark Processed"): INSERT INTO processed_emails
                   (gmail_message_id) VALUES ('{{ $json.gmail_message_id }}')
                   ON CONFLICT (gmail_message_id) DO NOTHING;
       False → connect directly to the SAME "Mark Processed" node above (a
               second incoming connection into it) — an email is marked
               processed whether or not it turned out to be actionable.
```

**Why the fan-out instead of chaining these three nodes in sequence**: Postgres/Telegram nodes replace the item's JSON with their own output rather than merging into it (see the gotcha in step 5). If "Insert Pending Confirmation" ran before "Send Proposal," the Telegram node would no longer have `title`/`email_from`/etc. to read. Connecting all three directly off the same IF output, as parallel siblings rather than a chain, means each one reads fresh, untouched data straight from the IF node — no back-references needed, and no risk of a "Multiple matching items" error.

Credentials needed: the Gmail credential from 8.3, plus the existing OpenAI, Postgres, and Telegram credentials from Phase 1 (same ones, no need to recreate).

Leave this workflow **inactive** while testing — use **Execute step**/**Test workflow** manually so you're not spamming yourself every 15 minutes during setup, and check the Postgres/Telegram nodes' output on each run before publishing.

### 8.6 Extend the Phase 1 workflow to handle yes/no replies

Edit the existing Phase 1 workflow directly in the n8n UI — insert this **between** the Telegram Trigger and the existing "Message a model" node. `n8n/workflow-phase1.json` already has this built in under the node names used below, so importing it (or reading it as a reference) is the fastest way to get this exactly right:

```
Telegram Trigger
  → Postgres ("Check Pending Confirmation"): Execute Query
      SELECT
        EXISTS (
          SELECT 1 FROM pending_confirmations WHERE telegram_chat_id = {{ $json.message.chat.id }}
        ) AS has_pending,
        (
          SELECT row_to_json(t) FROM (
            SELECT id, title, description, due_at
            FROM pending_confirmations
            WHERE telegram_chat_id = {{ $json.message.chat.id }}
            ORDER BY created_at ASC
            LIMIT 1
          ) t
        ) AS pending;

      This always returns exactly one row (has_pending: true/false, pending:
      the row or null), rather than a plain SELECT that returns zero rows when
      there's nothing pending — a zero-row result here would silently skip
      every downstream node on this path (see the "Always Output Data" gotcha
      in step 6.5), so the query is written to never do that.

  → IF ("Has Pending Confirmation?"): {{ $json.has_pending }} is true
       True  → continue below
       False → connect to the existing "Message a model" node. Its User
               message field must now read
               `={{ $('Telegram Trigger').item.json.message.text }}` instead
               of `={{ $json.message.text }}`, since $json at this point is
               this Postgres node's output, not the Telegram message.

  → Code ("Parse Confirmation Reply") — classify the reply and flatten the
    nested `pending` object:
      const text = $('Telegram Trigger').item.json.message.text.trim();
      const pending = $json.pending;
      let reply_type;
      if (/^y(es)?$/i.test(text)) reply_type = 'yes';
      else if (/^no?$/i.test(text)) reply_type = 'no';
      else reply_type = 'unclear';
      return { json: { reply_type,
        telegram_chat_id: $('Telegram Trigger').item.json.message.chat.id,
        pending_id: pending.id, title: pending.title,
        description: pending.description, due_at: pending.due_at } };

  → Switch ("Route by Confirmation Reply") on {{ $json.reply_type }}:
       "yes" → fan out to THREE parallel nodes, all reading $json directly
               from this Switch (same fan-out reasoning as step 8.5 — none of
               these three should chain into another, since each Postgres
               write replaces the item's JSON):
                 - Postgres ("Insert Confirmed Task"): INSERT INTO tasks
                   (telegram_chat_id, title, description, due_at) VALUES
                   ($json.telegram_chat_id, $json.title, $json.description,
                   $json.due_at)
                 - Postgres ("Delete Pending Confirmation"): DELETE FROM
                   pending_confirmations WHERE id = {{ $json.pending_id }}
                 - Telegram ("Reply - Confirmed Task Added"): "✅ Task added:
                   {{ $json.title }}"
       "no"  → fan out to TWO parallel nodes:
                 - Postgres: the SAME "Delete Pending Confirmation" node above
                   (a second incoming connection into it)
                 - Telegram ("Reply - Discarded"): "🗑️ Discarded."
       fallback ("unclear") → Telegram ("Reply - Ask Yes or No"): "Please
               reply YES or NO for: \"{{ $json.title }}\"" (the pending row
               stays; nothing continues to Message a model)
```

A pending confirmation captures **every** message in that chat until it's resolved — there's no way to tell "yes"/"no" answering a proposal apart from the start of some unrelated sentence, so this is deliberate, not a bug (see `docs/architecture.md` §"One pending confirmation per chat, resolved in order").

Test with the same debug loop as Phase 1 (unpublish → Listen for Test Event → send a message → check node outputs → republish) — but re-trigger **Listen for Test Event** and send fresh each time you test; reusing an old cached Telegram Trigger execution to test a new reply gives misleading results (the reply-type classifier will just re-evaluate whatever message it last captured). Manually insert a test row into `pending_confirmations` first (via DBeaver or `docker exec`) so you have something to confirm/discard without waiting for the poll workflow.

### 8.7 Testing

1. Manually run the Gmail-poll workflow once (**Execute Workflow**) against a test email from an allowlisted sender — confirm it lands a proposal message in Telegram and a row in `pending_confirmations`.
2. Reply `yes` — confirm a row appears in `tasks` and the pending row is gone.
3. Repeat, reply `no` this time — confirm the pending row is gone, nothing was added to `tasks`, and you get a "🗑️ Discarded." reply (easy to accidentally omit — the No branch needs its own Telegram reply node, separate from the Yes branch's).
4. Reply with an unrelated message while a proposal is pending — confirm you get the re-prompt, not a normal Phase 1 response (see the known limitation in `docs/architecture.md`).
5. Run the poll workflow again against the same email — confirm it's skipped (no duplicate proposal), since it's now in `processed_emails`.

## 9. Phase 3 — Jira setup

Design and query details: `docs/architecture.md` §"Phase 3 — Jira queries". `n8n/workflow-phase1.json` already contains all of this, so importing it is the fastest route.

### 9.1 Jira credential

1. Create an API token at id.atlassian.com → Security → API tokens. Treat it like a password: enter it only in n8n's credential form, never in chat or a committed file.
2. In n8n, create a **Jira Software Cloud API** credential with your Atlassian email, the token, and Domain set to your site URL, e.g. `https://your-site.atlassian.net`. Copy it from your browser's address bar up to `.atlassian.net`, with no trailing slash or path.
3. Save. n8n tests the connection immediately.

### 9.2 Teach the classifier about Jira

In the "Message a model" system prompt:
- Add `"jira_status" | "jira_blocked"` to the `intent` list.
- Add two rules describing them, plus `Words like "Jira", "ticket", "issue", or "sprint" always mean a jira_* intent, never list_tasks.`
- Add both to the rule that forces `query_date` to null.

Add two rules to the **Route by Intent** Switch, matching `jira_status` and `jira_blocked`, with outputs named `Jira Status` and `Jira Blocked`. They sit above the fallback output.

### 9.3 Build the branch

Two **Jira Software** nodes (Resource `Issue`, Operation `Get Many`, Limit `10`, JQL under Options), each with **Always Output Data** enabled in Settings:
- `Jira - Open Issues` from `Jira Status`
- `Jira - Blocked Issues` from `Jira Blocked`

Both connect into one Code node, `Format Jira List`, then one Telegram node, `Reply - Jira List`. The JQL and formatter code are in the workflow file.

### 9.4 A mistake that costs an afternoon

**In a field showing the `fx` (expression) icon, type `{{ ... }}`, not `={{ ... }}`.** The leading `=` is how n8n stores expression mode internally, and typing it yourself adds a literal `=` to the value. On a Telegram node that turned the Chat ID into `=123456789` and produced "Bad Request: chat not found". In a text field it prepends a stray `=` to every message. If you see a `==` prefix in an exported workflow, a field has this problem.

### 9.5 Testing

Create two unresolved issues assigned to you in Jira, one with the label `blocked`. Send "status of my jira tickets" and "what's blocked in Jira". The plain issue appears only in the first reply, the labeled one in both. A site with no matching issues should reply "No open Jira issues assigned to you" or "Nothing blocked", not silence.

## 10. Task reminders

Design and tradeoffs: `docs/architecture.md` §"Task reminders". This needs no new credentials and no schema change.

1. Import `n8n/workflow-reminders.json` (Workflows → Import from File). Open the Postgres and Telegram nodes and select your existing credentials if they show blank.
2. Toggle the workflow **Active**.

The workflow makes only outbound Telegram calls, so it works without the ngrok tunnel. n8n just has to be running.

**Test:** send the bot "remind me to test the reminder in 30 minutes" and wait up to 5 minutes. You should get "⏰ Reminder: ..." with the due time, and `SELECT title, reminded_at FROM tasks ORDER BY id DESC LIMIT 1;` should show `reminded_at` set. To skip the wait, open the workflow and click **Execute workflow**.

Tasks that are already more than 15 minutes overdue, and tasks with no due time, are never reminded.
