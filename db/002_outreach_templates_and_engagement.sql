CREATE TABLE IF NOT EXISTS marketing.email_templates (
    id BIGSERIAL PRIMARY KEY,
    version INTEGER NOT NULL UNIQUE,
    subject_template TEXT NOT NULL,
    body_template TEXT NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT false,
    created_by TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS email_templates_one_active
    ON marketing.email_templates ((is_active))
    WHERE is_active;

INSERT INTO marketing.email_templates
    (version, subject_template, body_template, is_active, created_by)
SELECT
    1,
    'A quick introduction',
    $template$Good [[greeting]][[recipient_first_name]],

I’m a software and workflow consultant working with local businesses.

I’m not selling a particular software package. I work with the people who know the business best to understand how the existing systems and processes fit together, then identify one or two practical improvements that could save time or provide better visibility.

[[personalised_message]]

My work typically involves improvements such as automating repetitive administration, connecting systems that do not currently communicate, improving project and budget reporting, or replacing fragile manual processes.

You can see a little more about the kind of work I do here:

https://example.com/consulting

Would you be open to a brief conversation?

Kind regards,

[[business_name]]$template$,
    true,
    'migration:initial-standard-template'
WHERE NOT EXISTS (
    SELECT 1 FROM marketing.email_templates
);

CREATE TABLE IF NOT EXISTS marketing.delivery_settings (
    id SMALLINT PRIMARY KEY DEFAULT 1,
    tracking_pixel_url TEXT NOT NULL
        DEFAULT 'https://example.com/t/o.gif',
    click_target_url TEXT NOT NULL
        DEFAULT 'https://example.com/consulting',
    utm_source TEXT NOT NULL DEFAULT 'outreach',
    utm_medium TEXT NOT NULL DEFAULT 'email',
    utm_campaign TEXT NOT NULL DEFAULT 'outreach_campaign',
    track_opens BOOLEAN NOT NULL DEFAULT false,
    track_clicks BOOLEAN NOT NULL DEFAULT false,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT delivery_settings_singleton_check CHECK (id = 1)
);

INSERT INTO marketing.delivery_settings (id)
VALUES (1)
ON CONFLICT (id) DO NOTHING;

ALTER TABLE marketing.delivery_settings
    ADD COLUMN IF NOT EXISTS tracking_pixel_url TEXT NOT NULL
        DEFAULT 'https://example.com/t/o.gif',
    ADD COLUMN IF NOT EXISTS utm_source TEXT NOT NULL DEFAULT 'outreach',
    ADD COLUMN IF NOT EXISTS utm_medium TEXT NOT NULL DEFAULT 'email',
    ADD COLUMN IF NOT EXISTS utm_campaign TEXT NOT NULL
        DEFAULT 'outreach_campaign';

ALTER TABLE marketing.delivery_settings
    DROP COLUMN IF EXISTS tracking_public_base_url;

ALTER TABLE marketing.drafts
    ADD COLUMN IF NOT EXISTS template_id BIGINT
        REFERENCES marketing.email_templates(id),
    ADD COLUMN IF NOT EXISTS personalised_message TEXT;

ALTER TABLE marketing.outbound_messages
    DROP CONSTRAINT IF EXISTS outbound_messages_prospect_id_sequence_no_key;

CREATE UNIQUE INDEX IF NOT EXISTS outbound_one_non_cancelled_sequence
    ON marketing.outbound_messages (prospect_id, sequence_no)
    WHERE status <> 'cancelled';

ALTER TABLE marketing.outbound_messages
    ADD COLUMN IF NOT EXISTS html_body TEXT,
    ADD COLUMN IF NOT EXISTS tracking_token UUID,
    ADD COLUMN IF NOT EXISTS track_opens BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS track_clicks BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS click_target_url TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS outbound_tracking_token_unique
    ON marketing.outbound_messages (tracking_token)
    WHERE tracking_token IS NOT NULL;
