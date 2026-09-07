CREATE SCHEMA IF NOT EXISTS marketing;

CREATE TABLE IF NOT EXISTS marketing.prospects (
    id BIGSERIAL PRIMARY KEY,
    prospect_key TEXT NOT NULL UNIQUE,
    business_name TEXT NOT NULL,
    branch_location TEXT,
    region TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'queued',
    website_url TEXT,
    contact_name TEXT,
    contact_role TEXT,
    contact_email TEXT,
    personalization_detail TEXT,
    personalization_source_url TEXT,
    personalization_evidence TEXT,
    fit_score SMALLINT,
    score_explanation TEXT,
    research_confidence TEXT,
    research_attempts INTEGER NOT NULL DEFAULT 0,
    next_research_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_researched_at TIMESTAMPTZ,
    contacted_at TIMESTAMPTZ,
    do_not_contact_at TIMESTAMPTZ,
    last_error TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT prospects_status_check CHECK (
        status IN (
            'queued', 'researching', 'research_requested', 'research_failed',
            'awaiting_approval', 'approved_to_send', 'sending', 'contacted',
            'rejected', 'disqualified', 'do_not_contact', 'send_ambiguous'
        )
    ),
    CONSTRAINT prospects_fit_score_check CHECK (
        fit_score IS NULL OR fit_score BETWEEN 0 AND 100
    )
);

CREATE TABLE IF NOT EXISTS marketing.research_runs (
    id BIGSERIAL PRIMARY KEY,
    prospect_id BIGINT NOT NULL REFERENCES marketing.prospects(id),
    kestra_execution_id TEXT,
    profile_version TEXT NOT NULL,
    attempt INTEGER NOT NULL,
    status TEXT NOT NULL,
    queries JSONB NOT NULL DEFAULT '[]'::jsonb,
    raw_results JSONB,
    extracted_data JSONB,
    error_message TEXT,
    started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS marketing.drafts (
    id BIGSERIAL PRIMARY KEY,
    prospect_id BIGINT NOT NULL REFERENCES marketing.prospects(id),
    version INTEGER NOT NULL,
    subject TEXT NOT NULL,
    body TEXT NOT NULL,
    created_by TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'current',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (prospect_id, version),
    CONSTRAINT drafts_status_check CHECK (
        status IN ('current', 'superseded', 'approved', 'sent', 'rejected')
    )
);

CREATE UNIQUE INDEX IF NOT EXISTS drafts_one_current_per_prospect
    ON marketing.drafts (prospect_id)
    WHERE status = 'current';

CREATE TABLE IF NOT EXISTS marketing.outbound_messages (
    id BIGSERIAL PRIMARY KEY,
    prospect_id BIGINT NOT NULL REFERENCES marketing.prospects(id),
    draft_id BIGINT NOT NULL REFERENCES marketing.drafts(id),
    sequence_no INTEGER NOT NULL DEFAULT 1,
    recipient_email TEXT NOT NULL,
    sender_email TEXT NOT NULL,
    subject TEXT NOT NULL,
    body TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    approved_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    claimed_at TIMESTAMPTZ,
    sent_at TIMESTAMPTZ,
    kestra_execution_id TEXT,
    smtp_message_id TEXT,
    error_message TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (prospect_id, sequence_no),
    CONSTRAINT outbound_status_check CHECK (
        status IN ('pending', 'sending', 'sent', 'ambiguous', 'cancelled')
    )
);

CREATE TABLE IF NOT EXISTS marketing.state_events (
    id BIGSERIAL PRIMARY KEY,
    prospect_id BIGINT NOT NULL REFERENCES marketing.prospects(id),
    from_status TEXT,
    to_status TEXT NOT NULL,
    action TEXT NOT NULL,
    actor TEXT NOT NULL,
    detail JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS prospects_research_queue_idx
    ON marketing.prospects (next_research_at, id)
    WHERE status IN ('queued', 'research_requested', 'research_failed');

CREATE INDEX IF NOT EXISTS prospects_review_queue_idx
    ON marketing.prospects (updated_at DESC)
    WHERE status = 'awaiting_approval';

CREATE INDEX IF NOT EXISTS outbound_pending_idx
    ON marketing.outbound_messages (approved_at, id)
    WHERE status = 'pending';
