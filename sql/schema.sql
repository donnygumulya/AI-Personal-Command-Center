-- AIPCC Phase 1 schema
-- Tasks and reminders, unified into a single table.

CREATE TABLE IF NOT EXISTS tasks (
    id              SERIAL PRIMARY KEY,
    telegram_chat_id BIGINT NOT NULL,
    title           TEXT NOT NULL,
    description     TEXT,
    due_at          TIMESTAMPTZ,              -- NULL = plain task with no due time
    status          TEXT NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending', 'completed', 'cancelled')),
    reminded_at     TIMESTAMPTZ,              -- set once a reminder notification has been sent
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Speeds up "list my pending tasks" and "what's due soon" queries
CREATE INDEX IF NOT EXISTS idx_tasks_chat_status ON tasks (telegram_chat_id, status);
CREATE INDEX IF NOT EXISTS idx_tasks_due_at ON tasks (due_at) WHERE due_at IS NOT NULL;

-- Optional: log every parsed message for later analysis/eval of intent accuracy
CREATE TABLE IF NOT EXISTS message_log (
    id                  SERIAL PRIMARY KEY,
    telegram_chat_id    BIGINT NOT NULL,
    raw_message         TEXT NOT NULL,
    parsed_intent       TEXT,
    parsed_fields       JSONB,
    confidence          NUMERIC,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- AIPCC Phase 2 additions
-- See docs/architecture.md "Phase 2 — Email-derived tasks" for the full design.

-- Tracks every Gmail message the poll workflow has already evaluated, so it's
-- never re-judged (and re-billed against the OpenAI call) on a later poll.
CREATE TABLE IF NOT EXISTS processed_emails (
    id                 SERIAL PRIMARY KEY,
    gmail_message_id   TEXT NOT NULL UNIQUE,
    processed_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Email-derived task proposals awaiting a yes/no reply over Telegram before
-- they're written into `tasks`. Rows are deleted once resolved either way.
CREATE TABLE IF NOT EXISTS pending_confirmations (
    id                       SERIAL PRIMARY KEY,
    telegram_chat_id        BIGINT NOT NULL,
    title                   TEXT NOT NULL,
    description             TEXT,
    due_at                  TIMESTAMPTZ,
    source_gmail_message_id TEXT,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_pending_confirmations_chat
    ON pending_confirmations (telegram_chat_id, created_at);
