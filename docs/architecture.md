# AIPCC — Architecture

## Phase 1 — Chat-driven tasks and calendar

### Overview

Phase 1 is a single n8n workflow that turns a Telegram message into one of five actions: create a task/reminder, list tasks, create a calendar event, list calendar events, or (if the message doesn't match any of those) ask the user to rephrase.

There's no separate backend service — n8n is the entire application: trigger, orchestration, and integration layer in one.

### Data flow

```
Telegram (user)
  → ngrok tunnel (HTTPS)
  → n8n: Telegram Trigger
  → n8n: OpenAI ("Message a model") — intent classification + entity extraction
  → n8n: Code node — parse model output, attach telegram_chat_id
  → n8n: Switch — route on `intent`
       ├── create_task    → Postgres (Insert)         → Telegram (reply)
       ├── list_tasks     → Postgres (Execute Query)   → Code (format) → Telegram (reply)
       ├── create_event   → Google Calendar (Create)   → Telegram (reply)
       ├── list_events    → Google Calendar (Get Many) → Code (format) → Telegram (reply)
       └── unknown        → Telegram (reply w/ usage hint)
```

### Why this shape

**Single intent-classification step, not per-branch parsing.** One OpenAI call extracts `intent`, `title`, `description`, and `due_at` up front, and every downstream branch just consumes that structured object. This keeps the routing logic in one place (the Switch node) instead of scattered across five separate prompts.

**LLM used for classification + entity extraction, not orchestration.** The model's only job is to turn a sentence into structured JSON. It does not call tools, decide what to do next, or see the result of any action. All control flow is deterministic (the Switch node), which makes behavior debuggable and predictable — important for a project meant to demonstrate the intent-routing pattern, not just "wrap an LLM in a chat box."

**One Postgres table for tasks and reminders.** A reminder is a task with `due_at` set. Splitting these into two tables would duplicate every column for no real benefit at Phase 1's scale.

### Intent classification

The OpenAI system prompt returns strictly this shape:

```json
{
  "intent": "create_task" | "list_tasks" | "create_event" | "list_events" | "unknown",
  "title": string | null,
  "description": string | null,
  "due_at": string | null,    // ISO 8601, resolved from relative language ("Friday at 10am")
  "query_date": string | null // ISO date (YYYY-MM-DD), only for list_tasks/list_events
}
```

Key rules baked into the prompt:
- `create_task`: `title` required, `due_at` optional (its presence is what makes a task also function as a reminder)
- `create_event`: `title` and `due_at` both required
- `list_tasks` vs `list_events`: distinguished by whether the user is asking about to-dos vs. their calendar/schedule — this is the one classification the model has the hardest time being unambiguous about
- `query_date`: only meaningful for `list_tasks`/`list_events`. If the user names a specific day ("today", "tomorrow", "this Friday"), it's resolved to an ISO date; a plain "what are my tasks"/"what's on my calendar" with no day mentioned leaves it `null`, which means "show the default range" (all pending tasks, or the next 7 days of events) rather than a specific day. The parsing step (`Parse Intent Response`) turns this single field into a `range_start`/`range_end` pair — day-boundaries in Asia/Jakarta when `query_date` is set, otherwise "now → +7 days" — that both the tasks query and the calendar query read from, so the day-boundary math exists in exactly one place.
- Anything that doesn't clearly match → `unknown`

The model is explicitly instructed to return raw JSON with no markdown code fences — but the parsing step doesn't fully trust that instruction (see Known issues below).

### Switch routing

The Switch node has one rule per known intent, plus an **Extra Output** fallback (not a 5th literal rule) for anything that doesn't match — this is what catches `unknown` as well as any malformed/unexpected model output.

### Database schema

```sql
CREATE TABLE tasks (
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
```

`reminded_at` exists for a not-yet-built scheduled workflow that would check for due tasks and proactively notify the user — it's written into the schema now so Phase 2/3 doesn't need a migration to add it later.

### Confirmation flow

**Not implemented for direct chat commands in Phase 1.** Every action (task insert, calendar event creation) executes immediately once classified — there's no "did you mean X? y/n" step before a write happens. This remains a reasonable scope cut for direct commands: the user typed the request themselves, so a misclassification is at least something they said. Phase 2 introduces a confirmation step, but only for tasks the system proposes on its own initiative (see below) — see [Why confirmation is required](#why-confirmation-is-required-for-phase-2-but-not-phase-1) for why the bar is different there.

### Known issues / fragile points

- **OpenAI response shape isn't stable across node versions.** The Code node reads `$input.item.json.output[0].content[0].text`, not the more commonly documented `message.content` — this depends on the exact "Message a model" node version and could break on an n8n/node update. Worth re-verifying this path if upgrading n8n.
- **Model sometimes wraps JSON in markdown fences despite instructions.** The Code node strips ` ```json ` fences defensively before parsing, and falls back to `{ intent: "unknown", ... }` if parsing still fails, rather than crashing the workflow.
- **`list_tasks` vs `list_events` classification is the weakest link.** Phrasings like "what do I have going on" can plausibly mean either. No current mitigation beyond prompt wording — worth watching in real usage.
- **A node that returns zero items stops execution on that branch entirely** — n8n doesn't invoke a downstream node at all when its input connection carries no items, regardless of the node's own execution mode. This bit the `list_events`/`Get many events` branch: with zero calendar events in range, `Format Event List` never ran, so the user got no reply at all instead of "Nothing on your calendar." Fixed by enabling **Always Output Data** on `Get many events` (forces a single placeholder item through even on an empty result) combined with a `.filter(ev => ev && ev.id)` in `Format Event List` to discard that placeholder before formatting. The same fix pattern applies anywhere a Postgres/API "get many" node feeds a formatter that needs to handle the empty case (the Phase 2 confirmation-check query sidesteps this by always returning exactly one row via `EXISTS(...)`/`row_to_json(...)` rather than a variable-length result set — the more robust pattern where the empty case matters).
- **Nodes like Postgres/Telegram/Calendar don't merge their result back into the item's JSON — they replace it.** Any expression after such a node that needs data from *before* it must reference the earlier node explicitly (e.g. `$('Parse Intent Response').item.json.title`), not `$json`. Reaching back across such a node with a bare node-name reference when the execution has multiple items in flight can also fail with a "Multiple matching items" error (n8n can't resolve pairedItem lineage through a node that didn't declare it). The reliable fix used throughout this workflow is to avoid the backward reference altogether: fan a single upstream output out to every sibling node that needs its data, in parallel, rather than chaining them through each other.

## Phase 2 — Email-derived tasks

### Overview

Phase 2 adds a second, independent n8n workflow that periodically scans Gmail for important mail and proposes tasks from it, plus a small extension to the Phase 1 Telegram pipeline so it can receive the user's yes/no answer to those proposals. Two separate trigger types feed the same `tasks` table:

- Phase 1: user-initiated, via Telegram messages.
- Phase 2: system-initiated, via a schedule, subject to user confirmation before anything is written.

### Why confirmation is required for Phase 2 (but not Phase 1)

Phase 1 has no confirmation step, and that's an accepted scope cut there: the user typed the request, so even a misclassification reflects something they actually said. Phase 2 is different in kind, not just degree — the system is deciding, unprompted, that an email is worth turning into a task, then guessing the title/description/due date from it. Two independent judgment calls (importance, then extraction) compound the chance of a wrong result, and unlike a chat command there's no original user utterance to fall back on if it's wrong. Auto-creating tasks from that chain of guesses is a meaningfully bigger blast radius than Phase 1's direct commands, so Phase 2 always proposes and waits for a yes/no before writing to `tasks`.

### Data flow

```
Gmail (new mail)
  → n8n: Schedule Trigger (every 15 min)
  → n8n: Gmail — Get Many, filtered to an allowlist (senders / label), narrowed further to `is:unread`
  → n8n: Postgres — skip any message already in `processed_emails`
  → n8n: OpenAI ("Message a model") — given subject + body snippet, decide:
         { actionable: bool, title, description, due_at }
  → IF actionable:
       → Postgres: insert into `pending_confirmations`
       → Telegram: send proposal, e.g.
         "📧 From: {{sender}} — {{subject}}
          Suggested task: {{title}}{{due_at ? ' — due ' + due_at : ''}}
          Reply YES to add, NO to skip."
  → Postgres: insert message id into `processed_emails` (always, regardless of actionable — an email is only evaluated once)
```

```
Telegram (existing Phase 1 trigger, extended)
  Telegram Trigger
    → Postgres: SELECT oldest row from `pending_confirmations` for this telegram_chat_id
    → IF a pending row exists:
         → message matches /^\s*y(es)?\s*$/i  → insert into `tasks` from the pending row → delete the pending row → reply "✅ Task added: {{title}}"
         → message matches /^\s*no?\s*$/i     → delete the pending row → reply "🗑️ Discarded."
         → anything else                       → reply "Please reply YES or NO for: \"{{title}}\"" (row stays, nothing falls through to intent classification)
    → ELSE: continue into the existing Phase 1 pipeline (Message a model → Code → Switch → ...) unchanged
```

### Why sender/label rules first, LLM second

A pure LLM-judgment pass over every unread email (the simplest option) would run a paid model call on every single message, most of which are never task-worthy — newsletters, receipts, notifications. Cheap, deterministic narrowing (a sender allowlist and/or a Gmail label) filters that down first, so the LLM only ever evaluates mail that's already plausibly relevant, and only does the harder job — deciding *if* it's actionable and extracting the task fields — on that smaller set. This mirrors Phase 1's principle of keeping the LLM's job narrow (classification/extraction, not judgment about what deserves attention in the first place) as far as is practical, while still letting it handle the genuinely fuzzy part (is *this* email from an allowlisted sender actually asking for something).

The allowlist is expected to be a short, manually maintained list (or a single Gmail label the user applies via a Gmail filter) — see `docs/setup.md` for configuring it.

### Why polling instead of push notifications

Gmail push notifications (`watch()` + Google Cloud Pub/Sub) would notice new mail immediately, but require a Pub/Sub topic, a subscription that must be renewed every 7 days, and another public webhook endpoint through ngrok — meaningfully more moving parts for a local/personal-scale project where a several-minute delay before a task appears is a non-issue. A Schedule Trigger polling on an interval (e.g. every 15 minutes) uses only infrastructure Phase 1 already has (the same n8n instance, the same Postgres).

### One pending confirmation per chat, resolved in order

`pending_confirmations` isn't limited to one row — if the poll finds several important emails before the user answers, each gets its own Telegram proposal message queued up. But only the **oldest unresolved** row is ever the one a yes/no reply applies to (`ORDER BY created_at ASC LIMIT 1`), so replies are unambiguous even with a backlog. The tradeoff: while any confirmation is outstanding, *every* incoming Telegram message is treated as an answer to it — a normal command typed before resolving a pending proposal gets a re-prompt instead of being classified. For a single-user personal assistant this is an acceptable, documented limitation rather than a real usability problem, since the user will typically clear a proposal within a message or two.

### New database tables

```sql
CREATE TABLE processed_emails (
    id                 SERIAL PRIMARY KEY,
    gmail_message_id   TEXT NOT NULL UNIQUE,
    processed_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE pending_confirmations (
    id                       SERIAL PRIMARY KEY,
    telegram_chat_id        BIGINT NOT NULL,
    title                   TEXT NOT NULL,
    description             TEXT,
    due_at                  TIMESTAMPTZ,
    source_gmail_message_id TEXT,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

`processed_emails` exists purely so the same email isn't re-evaluated (and re-billed against the OpenAI call) on every subsequent poll — it's written to whether or not the email turned out to be actionable. `pending_confirmations` rows are deleted once resolved (yes or no); nothing is kept as a permanent log of declined proposals, since there's no Phase 2 requirement to review history — only `tasks` (confirmed) persists.

### Known limitations carried into Phase 2

- **Owner chat ID must be configured, not derived.** Phase 1 gets `telegram_chat_id` from the incoming message; the Gmail-poll workflow has no incoming message to read it from, so the target chat ID is a fixed value set once during setup (see `docs/setup.md`). This means Phase 2 in its current form only supports a single Telegram user receiving email-derived proposals.
- **The allowlist is manually maintained.** Sender/label rules require the user to keep the list current as important senders change — there's no learning or feedback loop from past yes/no answers back into the filter.
- **A pending confirmation blocks normal chat commands for that user** until answered (see above) — an accepted tradeoff at personal-assistant scale, but would need revisiting (e.g. a `/pending` command, or scoping by keyword instead of "any message") if this were ever multi-user.

## Phase 3 — Jira queries

### Overview

Phase 3 adds two read-only intents to the Phase 1 classifier, `jira_status` and `jira_blocked`. Each routes to its own Jira "Get Many" node, and both feed one shared formatter and one Telegram reply. Nothing is written to Jira or to Postgres.

```
Route by Intent
  ├── jira_status  → Jira - Open Issues    ┐
  └── jira_blocked → Jira - Blocked Issues ┴→ Format Jira List → Reply - Jira List
```

### Queries

| Intent | JQL |
|---|---|
| `jira_status` | `assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC` |
| `jira_blocked` | `assignee = currentUser() AND resolution = Unresolved AND (labels = blocked OR flagged is not EMPTY OR priority in (High, Highest)) ORDER BY priority DESC` |

Both return at most 10 issues across every project the user can see. `Format Jira List` reads the intent from `Parse Intent Response` to pick the header and the empty-result message, so the two queries share one formatter.

### Decisions worth knowing

- **"Blocked" is a heuristic.** Jira has no built-in blocked state. The query treats a `blocked` label, a set Flagged field, or High/Highest priority as blocked, because those exist in every default Jira Cloud site. A JQL clause like `status = Blocked` fails the entire query with a validation error when the site has no status by that name, so it stays out of the default. Add it to the JQL if your workflow has that status.
- **The classifier disambiguates by keyword.** "Jira", "ticket", "issue", and "sprint" always route to a `jira_*` intent, never `list_tasks`. Without that rule "what's on my plate" style phrasings collide with local tasks, the classifier's known weak spot.
- **Both Jira nodes run with Always Output Data enabled**, for the same reason as the calendar branch: zero matching issues would otherwise skip the formatter and send no reply. The formatter filters on `i.key` to drop the placeholder item.

### Known limitations

- Queries cover every project, not a chosen one. Add `AND project = ABC` to the JQL to scope it.
- Results cap at 10 issues, and there is no paging.
- Only issues assigned to the token's owner appear. Queries for teammates' issues aren't supported.
