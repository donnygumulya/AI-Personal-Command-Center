# AI Personal Command Center (AIPCC)

A Telegram bot that turns natural language into task, reminder, and calendar actions. n8n runs the whole pipeline, with no separate backend service.

Type "remind me to follow up with HR on Friday at 10 AM" and the bot creates the task instead of you opening a separate app.

## Status

**Phase 1** (complete, running): Telegram sends a message to n8n. OpenAI classifies the intent and extracts fields. A Switch node routes the result to Postgres (tasks and reminders) or Google Calendar (create and list events), filtered by a specific day when the user names one.

**Phase 2** (complete, running): A second n8n workflow polls Gmail on a schedule, filters emails by sender or label, and asks OpenAI whether each one requires action. When it does, the bot proposes a task over Telegram and waits for a yes or no reply before writing anything to the database.

**Phase 3** (planned): Jira integration for project status queries and blocked-task summaries.

See `docs/architecture.md` for the full system design and `docs/setup.md` for setup instructions.

## Why build this

Turning a sentence into a database write or a calendar event takes two steps most chatbot demos skip: classify what the user wants, then extract the structured fields the action needs. AIPCC does both with a single OpenAI call per message, then hands the result to deterministic n8n nodes. A Switch node decides what happens next, not the model. You can always point to the exact classification result and Switch rule that produced any given reply.

## Tech stack

- **Orchestration**: n8n, self-hosted in Docker
- **Chat interface**: Telegram Bot API. Chat-specific logic stays in the trigger node, so swapping in WhatsApp Cloud API later means replacing that one node, not the pipeline.
- **AI**: OpenAI (`gpt-4o-mini`) for intent classification and field extraction
- **Storage**: PostgreSQL for tasks, reminders, and pending email-derived task proposals
- **Calendar**: Google Calendar API over OAuth2, for creating and listing events
- **Email**: Gmail API, read-only, polled on a schedule
- **Local dev tunnel**: ngrok, exposing the webhook Telegram and Google OAuth both need
- **Planned**: Jira API (Phase 3)

## Architecture

```
Telegram user
  → Telegram Trigger (n8n)
  → Postgres: check for a pending email-derived task proposal
  → no pending proposal: OpenAI classifies intent, Switch routes to
       create_task  → Postgres insert
       list_tasks   → Postgres query, filtered by date when one was named
       create_event → Google Calendar insert
       list_events  → Google Calendar query, filtered by date when one was named
       unknown      → usage-hint reply
  → pending proposal exists: the reply resolves it (insert into tasks, or discard)
  → Telegram: send reply
```

A second workflow polls Gmail on a schedule, filters by sender or label, and asks OpenAI whether each email needs a task. When it does, that workflow writes the proposal the check above looks for.

Full diagram, design rationale, and known limitations live in `docs/architecture.md`.

## Repo structure

```
AIPCC/
├── README.md
├── docs/
│   ├── architecture.md      # System design, intent routing, known issues
│   ├── setup.md             # Local setup: Telegram bot, n8n, Postgres, ngrok, Google/Gmail OAuth
│   └── PHASE2_HANDOFF.md    # Phase 2 design decisions and rationale
├── n8n/
│   └── workflow-phase1.json # Importable workflow: tasks, events, and the confirmation-reply extension
└── sql/
    └── schema.sql            # Postgres schema: tasks, message log, processed emails, pending confirmations
```

## Skills demonstrated

AI integration, intent classification, workflow automation, n8n, OpenAI API, Telegram Bot API, Gmail API, PostgreSQL, Google Calendar API, OAuth2, Docker, event-driven architecture, natural language processing.
