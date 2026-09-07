# Kestra Workflows

## Configuration

Kestra is accessible at http://localhost:9002

Adminer is accessible at http://localhost:9011

Configuration of secrets and environment variables is performed through .env file at root.

In addition to the per-integration variables documented below, the flows read
these sender/recipient and endpoint values from `.env` (see `.env.example`):
`ENV_CONSULTING_EMAIL`, `ENV_ALERTS_EMAIL`, `ENV_EVENTS_EMAIL`,
`ENV_SEEK_ALERT_ADDRESS`, `ENV_CALDAV_URL`, `ENV_CALDAV_DIGEST_RECIPIENT`,
`POSTGRES_PASSWORD`, `BACKUP_SERVER_HOST`, `BACKUP_SERVER_IP`, and
`MAIL_LAN_HOST`. No personal names, business names, or private hostnames are
hardcoded in the tracked files.

Once updated, perform `docker compose up -d --force-recreate kestra` to apply changes.

## Ollama model

Current LLM tasks use a local `gemma4-nothink:12b` alias that removes Gemma 4's
thinking capability at the model level. Build it on the Ollama host before
importing or running those workflows:

```powershell
ollama pull gemma4:12b
ollama create gemma4-nothink:12b -f ollama/gemma4-12b-nothink.Modelfile
```

The workflows also retain their request-level no-thinking settings as defense
in depth.

## Network inspector

The first network-inspector workflow is a manual, read-only access preflight:

- `automation.infrastructure.network_inspector_preflight`

It verifies HTTPS access from the Kestra container to OPNsense, the Wazuh
manager API, and the Wazuh indexer API. It does not scan the network or change
any source system.

Create dedicated least-privilege API users, then configure these values in the
root `.env` file:

```dotenv
ENV_OPNSENSE_URL=https://firewall.your-domain.internal
ENV_OPNSENSE_API_KEY=
ENV_OPNSENSE_API_SECRET=
ENV_WAZUH_API_URL=https://WAZUH-MANAGER:55000
ENV_WAZUH_API_USERNAME=
ENV_WAZUH_API_PASSWORD=
ENV_WAZUH_INDEXER_URL=https://WAZUH-INDEXER:9200
ENV_WAZUH_INDEXER_USERNAME=
ENV_WAZUH_INDEXER_PASSWORD=
```

Use internal DNS names instead of IP addresses when that is what the TLS
certificate covers. If an internal certificate authority is not already in the
container trust store, place only its PEM certificate in
`certs/network-inspector/` using the filenames documented there. Never place a
private key or API credential in that directory.

After changing `.env` or adding CA certificates, recreate Kestra and manually
import `flows/network_inspector_preflight.yaml`. Run it once and inspect the
`verify_source_access` outputs. Do not weaken TLS verification to make the
preflight pass; fix the URL, certificate chain, or trusted CA instead.

### Preparing the OPNsense hostname

Before configuring the OPNsense API credentials, create an internal DNS record
in OPNsense:

1. Open **Services > Unbound DNS > Overrides**.
2. Add a host override with host `firewall`, domain `your-domain.internal`,
   type `A`, and the firewall's LAN IP address.
3. Apply the Unbound configuration.
4. From a LAN client that uses OPNsense for DNS, verify that
   `firewall.your-domain.internal` resolves to the firewall's LAN address.
5. Repeat the lookup from inside the Kestra container. Do not continue until
   both clients receive the internal address.

Do not create a public `A` or `AAAA` record for this hostname. A publicly
trusted TLS certificate can still be issued using an ACME DNS-01 challenge,
because that challenge uses a temporary public TXT record rather than exposing
the firewall hostname or Web GUI.

Once DNS works, add or issue a server certificate containing
`firewall.your-domain.internal` under **System > Trust > Certificates**, then select
it under **System > Settings > Administration > Web GUI** and set the protocol
to HTTPS. Keep console access available while changing the Web GUI certificate
so a certificate or listener mistake cannot lock out administration.

## Airtasker task scout

This workflow queries Airtasker's MCP to determine potential high-value tasks to make offers for. It summarises the work, applies scoring and ranking according to various criteria, then sends this information in an hourly digest.

### Workflow

- `airtasker_job_scout` runs hourly. It performs all required work to gather relevant tasks for the previous hour, scores and ranks them, then sends the filtered list to the email recipient.

### Refreshing tokens

Use the MCP Inspector to obtain a new Airtasker OAuth client ID and refresh
token. Run:

```powershell
npx -y "@modelcontextprotocol/inspector@v1-latest"
```

In the Inspector:

1. Set **Transport Type** to **Streamable HTTP** and **URL** to
   `https://mcp.airtasker.com/mcp`.
2. Do not click **Connect**. Select **Open Auth Settings**, **Clear OAuth
   State**, then **Guided OAuth Flow**. Clearing the state prevents Inspector
   from retrying the invalid token being replaced.
3. Click **Continue** through **Metadata Discovery** and **Client
   Registration**.
4. At **Preparing Authorization**, copy the generated authorization URL and
   replace only its `scope` query parameter with `scope=offline_access`. For
   example, replace `scope=openid%20profile%20offline_access` with
   `scope=offline_access`. Do not change `client_id`, `redirect_uri`, `state`,
   `code_challenge`, or `resource`.
5. Open the modified URL, sign in to Airtasker, and approve access. If Inspector
   does not populate the **Authorization Code** field after the callback, copy
   only the `code` value from the callback URL into that field.
6. Continue through **Token Request** and **Authentication Complete**.
7. Expand **Registered Client Information** and copy `client_id`. Expand
   **Access Tokens** and copy `refresh_token`. Keep the values from the same
   authorization run together. Do not use or store `access_token` in `.env`.

Update the root `.env` with the new values, without committing them:

```dotenv
ENV_AIRTASKER_CLIENT_ID=the_new_client_id
ENV_AIRTASKER_INITIAL_REFRESH_TOKEN=the_new_refresh_token
```

The workflow prefers the rotated token cached in
`/app/airtasker-oauth/tokens.json` over the initial token in `.env`. Remove only
that stale cache and recreate Kestra so it receives the updated environment:

```powershell
docker compose exec -T kestra rm -f /app/airtasker-oauth/tokens.json
docker compose up -d --force-recreate kestra
```

Let the next scheduled execution verify the replacement. A manual execution of
this workflow can send a real email and should not be used as a harmless token
test.

## Prospect outreach

This local stack researches a predetermined prospect list, prepares an evidenced
draft, presents it for human review, and sends only a human-approved immutable
message snapshot.

### Local screens

Prospect review: http://localhost:9012

The normal operational actions should be performed in the prospect review screen so state changes remain validated and auditable.

### Workflows

- `automation.marketing.prospect_research` has no trigger. Run it
  manually in Kestra; each execution snapshots all currently due prospects and
  researches them serially.
- `automation.marketing.research_one` claims and researches one
  explicit prospect. It is normally called only by the manual parent flow.
  `Research again` returns that prospect to the due queue for the next manual
  parent execution.
- `automation.marketing.send_approved` runs hourly. It snapshots all
  eligible approved messages and invokes `automation.marketing.send_one`
  serially for each message.
- `automation.marketing.send_one` claims and sends one immutable
  message snapshot through the existing `ENV_SMTP_*` configuration. It has no
  schedule and is normally called only by the hourly parent flow.

Research task outputs remain human-readable JSON in Kestra. Only the opening
characters of embedded Pebble-style template sequences are represented as JSON
Unicode escapes while they pass between tasks; Python and PostgreSQL decode
them back to the original source text.

### Review states and duplicate protection

PostgreSQL is the source of truth for prospect status, research evidence, draft
versions, approvals, outbound message snapshots, contact timestamps, and the
state-event audit trail.

`Approve and send` stays disabled until a reviewer has:

1. confirmed the recipient email; and
2. reviewed the current draft.

Note: add your own prospect rows to the
`marketing.prospects` table before using the research and outreach workflows.

Initial outreach has a unique `(prospect_id, sequence_no)` database constraint, so it
cannot be queued twice. SMTP is not automatically retried because a timeout can
occur after a provider accepted the message; uncertain results become
`send_ambiguous` and stop for manual reconciliation.

### Configurable message template

The standard subject and body are configured at
http://localhost:9012/settings/template. The local model supplies only the
bounded personalised passage inserted at the template's
`[[personalised_message]]` placeholder. That passage contains two sentences:
one evidenced observation and one cautious explanation of why the sender thinks they
could help. Approval stores an immutable rendered plain-text and HTML message
snapshot for the sender workflow.

An approval can be returned to review while its outbound message is still
`pending`. Once Kestra has claimed it as `sending`, cancellation is refused
because SMTP may already have accepted the message.

### Nginx-only engagement observations

Engagement uses an existing public Nginx server that you control. There is no
local tracking receiver, callback route, log importer, or public exposure of
the review application.

- The consulting link goes directly to your configured click-target URL with
  `utm_source`, `utm_medium`, `utm_campaign`, and the outbound message token
  in `utm_content`.
- The optional open pixel points directly to your configured tracking-pixel
  URL with the same campaign parameters.
- Nginx writes matching requests with the existing `campaign_json` log format.
  A consulting-page request is an observed click and a `/t/o.gif` request is an
  observed open.

Use
[`nginx/outreach_tracking.conf.example`](nginx/outreach_tracking.conf.example)
as the Nginx integration snippet. Its `map` belongs in the Nginx `http`
context; the conditional `access_log` and exact-match pixel `location` belong
in the HTTPS `server` block of your tracking domain. The pixel uses Nginx's
`empty_gif` directive, which returns a built-in transparent 1x1 GIF, so no
physical GIF file is required. Test the Nginx configuration before reloading
it.

Open and click observations are approximate. Image proxies, disabled images,
mail-security scanners, and link previews can hide or create activity; do not
treat these logs as proof that a person engaged.

### Applying workflow changes

The mounted flow files are not automatically re-imported into Kestra. After
updating this project, manually re-import:

1. `flows/prospect_research.yaml`
2. `flows/research_one.yaml`
3. `flows/send_one.yaml`
4. `flows/send_approved.yaml`

Rebuild or recreate the `prospect-review` service separately when its
application or database-init files change.

## Weekly Brisbane events

`automation.events.weekly_brisbane_events` runs at 7:00 pm every Sunday in
`Australia/Brisbane` and emails a curated guide for the following Monday through
Sunday.

The workflow fetches Brisbane City Council's official daily events JSON export.
Date filtering, normalisation, repeated-session grouping, categorisation,
diversity selection, factual fields and HTML rendering are deterministic. The
local `gemma4-nothink:12b` model receives only the selected records and writes a short
introduction plus one bounded summary per event. Its output must cover every
selected event ID exactly once or the workflow fails without sending a digest.
Events are grouped beneath day-by-day headings. A multi-day event appears once
at its starting position beneath a full start-to-finish date-range heading.
Events that began before the new Monday are not carried into later days merely
because they are still running.

Delivery reuses the project's existing `ENV_SMTP_*` configuration and sends
from and to `the configured consulting address`. The `maximum_events` input defaults to
18 for manual runs.

After changing the workflow, manually re-import:

1. `flows/weekly_brisbane_events.yaml`

## Weekly CalDAV events

`automation.events.weekly_caldav_events` runs at 6:00 pm every Sunday in
`Australia/Brisbane` and emails a day-by-day digest for the following
Monday-to-Sunday week. It discovers the authenticated CalDAV home and reads
the `Shared` and `Events` calendars from
`the CalDAV URL configured via `ENV_CALDAV_URL``.

Add the CalDAV credentials to the root `.env` file used by Docker Compose:

```dotenv
ENV_CALDAV_USERNAME=
ENV_CALDAV_PASSWORD=
```

The workflow does not contain or print these credentials. It sends the digest
to `the configured digest recipient` using the existing `ENV_SMTP_*` configuration.
The `Shared` calendar currently excludes only recurring series that occur more
than once a month when their title contains a dollar amount below `$100`.
High-value and no-dollar entries remain included. The `Events` calendar is not
filtered. Further selective blacklisting can be added with
`exclude_summary_patterns` and `exclude_uids` in the
`calendar_filters` block of `flows/weekly_caldav_events.yaml`.
After changing the workflow or `.env`, recreate Kestra and manually import:

1. `flows/weekly_caldav_events.yaml`

## Duplicacy backup validation

`automation.infrastructure.duplicacy_backup_validation` connects to
the authenticated validation API on `the configured backup server` each Sunday at
6:00 am. It starts a validation, polls it to completion, requires all ten
snapshot checks and both content checks to pass, then emails the result.

The repository mapping is fixed in the workflow:

| Source                    | Local repository | External repository |
| ------------------------- | ---------------: | ------------------: |
| `/etc`                    |    `localhost/8` |       `localhost/6` |
| `/opt`                    |   `localhost/10` |       `localhost/7` |
| `/var/www`                |   `localhost/12` |       `localhost/9` |
| `/var/lib/docker/volumes` |   `localhost/13` |      `localhost/11` |
| `/home/<user>`            |   `localhost/14` |       `localhost/4` |

The root-owned API service runs `duplicacy check` for every repository. It also
retrieves `test.txt` from the latest revision of both `/home/<user>` snapshots
and requires an exact line containing `Backup successfully validated!`. This
proves that actual file chunks can be read from each destination without
writing into the live source tree.

Configure these values in `.env` before recreating Kestra:

- `ENV_BACKUP_VALIDATION_URL`: HTTPS endpoint ending in `/backup-validation`
- `ENV_BACKUP_VALIDATION_USERNAME`: API Basic Auth username
- `ENV_BACKUP_VALIDATION_PASSWORD`: API Basic Auth password

The API must be reachable from the Kestra container and its TLS certificate must
be trusted there. If a validation is already running, the flow adopts and waits
for that run rather than starting a duplicate.

The Compose service pins the backup server and LAN mail hostnames to the
backup server's LAN IP inside the Kestra container (configured through
`BACKUP_SERVER_HOST`, `BACKUP_SERVER_IP`, and `MAIL_LAN_HOST` in `.env`). This
avoids transient Docker private-DNS failures during a multi-hour validation.
The API client additionally retries transient connection and resolution errors
five times with exponential backoff.

After changing the workflow, manually re-import:

1. `flows/duplicacy_backup_validation.yaml`
