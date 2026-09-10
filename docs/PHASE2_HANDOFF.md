# AIPCC — Phase 2 Handoff Brief

Context for picking this project up in a new session/tool. Phase 1 is complete and working; this is the state to build Phase 2 on top of.

## What this project is

AI Personal Command Center — a Telegram bot, orchestrated entirely in n8n, that turns natural language into structured actions across Postgres and Google Calendar. Full design rationale: `docs/architecture.md`. Full setup instructions: `docs/setup.md`.

## Current state (Phase 1 — done)

Single n8n workflow: `Telegram Trigger → OpenAI (intent classification) → Code (parse) → Switch → 5 branches → Telegram reply`.

Five intents handled: `create_task`, `list_tasks`, `create_event`, `list_events`, `unknown`. Tasks/reminders live in a Postgres `tasks` table (schema in `sql/schema.sql`); calendar actions go through Google Calendar API via OAuth2.

Local dev stack: Docker Compose (n8n + Postgres containers), ngrok for the public HTTPS webhook Telegram/Google OAuth need.

## Known limitations (carried into Phase 2 planning)

- **No confirmation step before writes** — a misclassified intent currently creates a wrong task/event silently. Worth considering whether Phase 2's email-derived task creation needs this more than Phase 1 did (auto-generating tasks from emails without user confirmation is a bigger blast radius than a direct chat command).
- **`list_tasks` vs `list_events` classification is occasionally ambiguous** — same intent-classification approach will apply to Phase 2's "is this email actionable" judgment call, likely with the same category of ambiguity.
- **OpenAI node response shape isn't guaranteed stable across n8n versions** — currently reading `output[0].content[0].text`. Verify this hasn't shifted before building Phase 2 nodes that depend on the same pattern.

## Phase 2 scope (per README)

Gmail summarization → auto-generated tasks from important emails. **Design resolved** — full architecture in `docs/architecture.md` §"Phase 2 — Email-derived tasks", build steps in `docs/setup.md` §8. Summary of the decisions:
- **Importance**: sender/label allowlist narrows candidates first (cheap, deterministic), then a single LLM call judges actionability + extracts task fields only from what passes — avoids running the LLM over every unread email.
- **Confirmation**: required. Unlike Phase 1's direct chat commands, Phase 2 proposes tasks unprompted from a chain of two guesses (importance, then extraction) with no original user utterance to fall back on if wrong — so nothing is written to `tasks` until the user replies yes/no over Telegram.
- **Trigger**: scheduled polling (n8n Schedule Trigger + Gmail node), not Gmail push/Pub-Sub — push would add a renewing subscription and another public webhook for a delay that doesn't matter at personal scale.

New tables (`processed_emails`, `pending_confirmations`) are already added to `sql/schema.sql` and applied to the running dev database.

## Repo structure

```
AIPCC/
├── README.md
├── docs/architecture.md   # system design, intent routing, known issues
├── docs/setup.md          # full local setup incl. real gotchas hit during Phase 1
├── n8n/workflow-phase1.json
└── sql/schema.sql
```

## Environment quick reference

- Docker Compose: `postgres_aipcc` (port 5433 external / 5432 internal), `n8n_aipcc` (port 5679 external)
- n8n reachable at `http://localhost:5679`, but **OAuth flows must go through the ngrok URL**, not localhost — see `docs/setup.md` §6.3 for why (CSRF cookie scoped to origin)
- `WEBHOOK_URL` env var on the n8n container must point at the ngrok domain with scheme + trailing slash
