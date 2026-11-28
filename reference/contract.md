# Integration contract

Field-level contract for the leadflow pipeline. Implementers, operators and acceptance checks treat this file as the single reference for scope, payloads, normalisation, hashing, CRM mapping, the classifier contract, environment variables, credentials and runtime behaviour. Provisioning and the acceptance procedure live in [`setup.md`](setup.md).

## 0. Scope and non-negotiables

- Two versioned workflows: `01-lead-intake` (inbound path) and `02-error-handler` (workflow-level error handler bound through `settings.errorWorkflow`).
- n8n runs from a pinned image (`N8N_VERSION` in `.env`, never `latest`); `postgres:16-alpine` holds n8n state only.
- The repository contains no credential values. Workflow JSON carries credential names only; ids are injected at deploy time by `scripts/deploy-workflows.ps1`.
- Every execution produces exactly one terminal HTTP response (201 / 422 / 502) and exactly one audit row.
- Validation failures never reach the classifier or the CRM.
- Deal creation is gated by `icp_fit >= LEADFLOW_ICP_FIT_THRESHOLD`; the threshold is read from the environment and never hard-coded in a node.
- Success-path latency budget: p95 ≤ 10 s, measured from `latency_ms` over 50 submissions.

## 1. Webhook

- `POST /webhook/leadflow-intake`
- Headers: `Content-Type: application/json`, `X-Webhook-Secret: <shared secret>`
- Secret check: must equal `WEBHOOK_SHARED_SECRET`. When the env var is empty the check is skipped (local development only). Mismatch → `reject_reason=bad_secret`.

### Request body

| Field | Required | Validation | On missing / invalid |
| --- | --- | --- | --- |
| `form_id` | yes | non-empty string | `missing_field:form_id` |
| `name` | yes | non-empty string | `missing_field:name` |
| `email` | yes | `^[^\s@]+@[^\s@]+\.[^\s@]{2,}$` | `missing_field:email` / `invalid_email` |
| `company` | yes | non-empty string | `missing_field:company` |
| `phone` | no | normalised per §2 | set to `null`, `warning:phone_not_e164` — not a rejection |
| `message` | no | string | defaults to `""` |

Unknown fields are ignored for normalisation but still count towards `payload_hash`.

### Responses

| Path | HTTP | Body |
| --- | --- | --- |
| Success (incl. fallback) | 201 | `{"status":"accepted","run_id":"…","contact_id":"…","deal_id":"…"\|"skipped"}` |
| Rejected payload | 422 | `{"status":"rejected","run_id":"…","reason":"<stable code>"}` |
| LLM retries exhausted | 502 | `{"status":"failed","run_id":"…","reason":"llm_retries_exhausted"}` |

Rejection codes are stable: `missing_field:<field>`, `invalid_email`, `bad_secret`.

## 2. Normalisation (order matters)

Fixed order: `email` → `idempotency_key` → `company` → `phone`. The order affects the hash, so the implementation and the acceptance script must use the same sequence.

- **email**: `trim()` + lowercase.
- **phone**: strip non-digits; 10 digits → prefix `1`; 11 digits starting with `1` → prefix `+`; 8–15 digits with an international prefix → `+<digits>`; anything else → `null` + `warning:phone_not_e164`.
- **company**: strip one trailing legal suffix (case-insensitive, tolerating leading spaces and commas/periods). Suffix list:

```
inc, inc., llc, llc., ltd, ltd., co, corp, corporation, company, plc,
gmbh, ag, bv, s.a., s.a, a.s., srl, s.r.l., oy, ab, as, nv, sa
```

Only the trailing match is removed; no mid-string replacement.

## 3. Keys, hashes and timestamps

- `idempotency_key = sha256(normalised_email + "|" + form_id)` — hex. The delimiter prevents concatenation ambiguity.
- One key → **1 Contact and ≤1 Deal**. One email → 1 Contact; different `form_id` values share the Contact and each get their own Deal.
- `payload_hash = sha256(canonical_json(body))` — hex. `canonical_json` = recursively sorted object keys, UTF-8, compact (no whitespace), original types and values (the body **before** normalisation). Headers, URL and query string are excluded.
- `run_id` = UUID v4 (`crypto.randomUUID()`).
- `received_at` = UTC ISO-8601 with `Z`. Timestamps are stored in UTC regardless of `GENERIC_TIMEZONE`.
- `latency_ms` = terminal-node timestamp − `received_at`, integer milliseconds.

## 4. CRM writes (HubSpot)

- Contacts: `POST /crm/v3/objects/contacts/batch/upsert`, `idProperty=email`.
- Deals: `POST /crm/v3/objects/deals/batch/upsert`, `idProperty=leadflow_idempotency_key`.
- The deal property `leadflow_idempotency_key` must be a custom single-line text property created with **unique values required** (`isUnique: true`).
- **Do not use search-then-create.** HubSpot Search is eventually consistent; two rapid submissions can miss the existing record and create a duplicate deal.
- Association: `PUT /crm/v3/objects/deals/{dealId}/associations/contacts/{contactId}/3` (`HUBSPOT_DEFINED`, typeId 3, idempotent).
- Repeat submissions update the existing records; they are not skipped.
- Properties written (standard properties only, to avoid 400s on portals without extra custom fields):
  - Contact: `email`, `firstname`, `lastname`, `company`, `phone`
  - Deal: `dealname` = `{company} — {intent} ({urgency})`, `description` = `summary`, `leadflow_idempotency_key`
  - `pipeline` / `dealstage` use HubSpot defaults; add `LEADFLOW_DEAL_PIPELINE` only if the portal rejects the default.
- Service key scopes (sent as `Authorization: Bearer pat-…`): `crm.objects.contacts.read`, `crm.objects.contacts.write`, `crm.objects.deals.read`, `crm.objects.deals.write`, `crm.schemas.deals.read`, `crm.schemas.deals.write`.
- Deal owner assignment is out of scope.

Creating the unique property (one-time):

```bash
curl -X POST https://api.hubapi.com/crm/v3/properties/deals \
  -H "Authorization: Bearer $HUBSPOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"leadflow_idempotency_key","label":"Leadflow Idempotency Key",
       "type":"string","fieldType":"text","groupName":"dealinformation","isUnique":true}'
```

## 5. LLM classification

- `POST https://api.openai.com/v1/chat/completions`, 30 s timeout, `temperature: 0`.
- `response_format = {"type":"json_schema","json_schema":{"name":"lead_classification","strict":true,"schema":…}}`. With `strict: true`, every key must appear in `required` and `additionalProperties` must be `false`.
- Schema:

```json
{
  "type": "object",
  "properties": {
    "intent":  {"type": "string", "enum": ["demo_request","quote_request","partnership","support","spam","other"]},
    "icp_fit": {"type": "number", "minimum": 0, "maximum": 1},
    "urgency": {"type": "string", "enum": ["low","medium","high"]},
    "summary": {"type": "string"}
  },
  "required": ["intent","icp_fit","urgency","summary"],
  "additionalProperties": false
}
```

- Rule-based fallback (used when the model output is unusable): `{"intent":"other","icp_fit":0,"urgency":"medium","summary":(message || company)[:140]}`. `icp_fit=0` is always below the deal threshold, so a fallback never creates a deal.

## 6. Audit sheet

- Tab name: `audit`, first row:

| run_id | received_at | payload_hash | outcome | model_output | fallback | latency_ms |
| --- | --- | --- | --- | --- | --- | --- |

- `outcome` stores terminal values only: `success`, `failed`, `rejected`. Exactly one row per execution; `retrying` is never written (intermediate states are visible in n8n execution history instead).
- `model_output` is the JSON string of the four classification fields, with emails/phones masked.
- `fallback` is a boolean.
- `latency_ms` is an integer.

## 7. Masking

- email → first character + `***` + `@` + full domain (`jane@acme.com` → `j***@acme.com`)
- phone → first 2 characters + `***` + last 2 (`+15550102030` → `+1***30`)
- Applied to: all Slack messages, Sheets `model_output` (including `summary` with embedded PII), container logs. `payload_masked` keeps `form_id`/`company`/`message` intact for triage.

## 8. Environment variables

| Variable | Purpose | Default |
| --- | --- | --- |
| `N8N_VERSION` | pinned n8n image tag (never `latest`) | required |
| `N8N_ENCRYPTION_KEY` | n8n credential encryption key | required |
| `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | n8n database | `n8n` |
| `N8N_API_KEY` | n8n Public API key (local `.env` only) | required for deploy |
| `WEBHOOK_SHARED_SECRET` | webhook header validation | empty = check skipped |
| `LEADFLOW_ICP_FIT_THRESHOLD` | deal creation threshold | `0.6` |
| `LEADFLOW_OPENAI_MODEL` | model that supports `response_format: json_schema` | required |
| `LEADFLOW_AUDIT_SHEET_ID` | audit spreadsheet id | required |
| `LEADFLOW_SLACK_ALERT_CHANNEL` | alert channel | `#ops-alerts` |
| `LEADFLOW_SLACK_NOTIFY_CHANNEL` | success notification channel | `#leads` |
| `HUBSPOT_TOKEN` | local acceptance script only; never used inside the workflow | local only |

## 9. Credentials (n8n credential store, created by the operator)

| Name | Type | Notes |
| --- | --- | --- |
| `leadflow-openai` | `openAiApi` | used via predefined credential type on HTTP Request |
| `leadflow-hubspot` | `httpHeaderAuth` | header `Authorization: Bearer pat-…` |
| `leadflow-slack` | `slackApi` | bot token, scope `chat:write` |
| `leadflow-google-sheets` | `googleApi` | Service Account JSON; spreadsheet shared with the SA email (editor) |

Workflow JSON references these by name only. `scripts/deploy-workflows.ps1` injects the credential ids from the n8n store.

## 10. Retry, visibility and retention

- Escalating backoff (3 retries at 2 s / 8 s / 30 s, four attempts in total) applies to the LLM call only. It is implemented as an explicit loop and must be countable in the execution history.
- Other outbound calls use node-level retries (`maxTries=3`, `waitBetweenTries=2000`). Platform caps: `maxTries` ≤ 5 and `waitBetweenTries` ≤ 5000 ms, so escalating backoff cannot be expressed with node retries.
- Notification failures (Slack, Sheets) do not fail the run: `continueRegularOutput`.
- Execution data retention: `EXECUTIONS_DATA_PRUNE=true`, `EXECUTIONS_DATA_MAX_AGE=72` hours, success and error data saved. Raw payloads (with PII) live in the n8n database for at most that window and are treated as debug data, not as an external log.
