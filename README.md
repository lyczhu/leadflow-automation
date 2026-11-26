# leadflow-automation

Turn an inbound form submission into a qualified, deduplicated CRM deal — with LLM classification, retry/alert branches and a full audit trail.

## Business outcome

Sales teams lose leads in the gap between "form submitted" and "someone followed up". This workflow closes that gap:

| Before | After |
| --- | --- |
| Leads sit in an inbox until someone notices | Every submission becomes a tracked deal within seconds |
| Duplicate contacts from repeat submissions | Idempotent upsert — one contact, one deal |
| Everything is "high priority" | LLM classifies intent, ICP fit and urgency before routing |
| No one knows what the automation did | Every run written to an audit log |

## Architecture

```mermaid
flowchart LR
  A[Form / Tally / Webflow] --> B[n8n Webhook]
  B --> C{Validate payload}
  C -- invalid --> D[Slack #ops-alerts]
  C -- valid --> E[Dedupe: email + domain]
  E --> F[LLM classify<br/>schema-constrained JSON]
  F --> G[HubSpot upsert Contact]
  G --> H[HubSpot create / update Deal]
  H --> I[Slack notify owner]
  H --> J[Sheets audit log]
  F -. error .-> K[Retry w/ backoff] -. exhausted .-> D
```

### Flow nodes

| # | Node | Responsibility |
| --- | --- | --- |
| 1 | `Webhook` | Receives form POST, verifies shared secret |
| 2 | `Validate` | Schema check: required fields, email format, phone normalization |
| 3 | `Dedupe` | Lookup by normalized email, fall back to company domain |
| 4 | `Classify` | OpenAI call with JSON Schema: `intent`, `icp_fit`, `urgency`, `summary` |
| 5 | `Upsert Contact` | HubSpot contact create-or-update, keyed by email |
| 6 | `Upsert Deal` | Creates a deal only when `icp_fit >= threshold` |
| 7 | `Notify` | Slack message to the owning rep with a one-line summary |
| 8 | `Audit` | Appends run id, payload hash, outcome, LLM output to Sheets |
| 9 | `Error branch` | Exponential backoff, then alert; never fails silently |

## Design notes

- **Idempotency** — every write is keyed by a deterministic key (`sha256(email + form_id)`). A repeated submission updates, never duplicates, and replaying the same webhook is safe.
- **Backoff with a ceiling** — 3 retries at 2s / 8s / 30s, then a Slack alert carrying the run id and the raw payload.
- **Normalization before matching** — lowercased emails, E.164 phone numbers, company names stripped of legal suffixes (`Inc`, `Ltd`, `GmbH`). Dedupe is only as good as its normalization.
- **Structured LLM output** — the model returns a fixed JSON shape validated before use; on schema violation it falls back to rule-based defaults rather than writing garbage into the CRM.
- **Audit log as a first-class output** — payload hash + decision + model output, so any record in HubSpot can be traced back to the run that created it.
- **No silent side effects** — write operations are logged and reversible; failures route to a human.

## Stack

- **n8n** (self-hosted, Docker) — orchestration
- **PostgreSQL** — n8n persistence
- **OpenAI API** — classification with JSON Schema output
- **HubSpot** — CRM
- **Google Sheets** — audit log
- **Slack** — alerts and notifications

## Run

```bash
cp .env.example .env        # set N8N_VERSION and N8N_ENCRYPTION_KEY
docker compose up -d
open http://localhost:5678  # n8n UI
```

Then import the workflow from `workflows/` and set the credentials inside n8n.

## Repository layout

```
.
├── docker-compose.yml      # n8n + postgres
├── .env.example
├── workflows/              # exported n8n JSON, versioned
└── LICENSE
```

## License

MIT
