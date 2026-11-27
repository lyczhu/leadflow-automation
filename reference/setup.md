# Setup and acceptance runbook

One-time provisioning, deployment and the acceptance procedure for this pipeline. The field-level contract lives in [`contract.md`](contract.md); the public README only carries the business outcome and architecture.

## 1. Prerequisites

- Docker Desktop running (`docker info` exits 0)
- A pinned n8n version chosen from the current stable releases (never `latest`); if the image or a node type turns out to be incompatible, stop and record the failure instead of silently downgrading
- Accounts: OpenAI, HubSpot (private app), Slack workspace, Google Cloud service account with Sheets API enabled

## 2. Start the stack

```bash
cp .env.example .env          # set N8N_VERSION, N8N_ENCRYPTION_KEY, LEADFLOW_* values
docker compose config         # must exit 0 before delivery
docker compose up -d
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:5678/healthz
```

## 3. One-time external setup

### 3.1 n8n API key

UI → Settings → n8n API. Scopes needed: workflows read/write, credentials read. Store it as `N8N_API_KEY` in the local `.env` (git-ignored).

### 3.2 Credentials inside n8n

Create these four credentials with exactly these names (see `contract.md` §9):

| Name | Type | Value |
| --- | --- | --- |
| `leadflow-openai` | OpenAI API | API key |
| `leadflow-hubspot` | Header Auth | header `Authorization`, value `Bearer pat-…` |
| `leadflow-slack` | Slack API | bot token (`chat:write`) |
| `leadflow-google-sheets` | Google API (Service Account) | service account JSON |

### 3.3 HubSpot

- Private app scopes: `crm.objects.contacts.read/write`, `crm.objects.deals.read/write`, `crm.schemas.deals.read/write`
- Create the unique deal property (once) — command in `contract.md` §4. The property must require unique values.
- Store the token as `HUBSPOT_TOKEN` in the local `.env` (used only by the acceptance script).

### 3.4 Google Sheets

- Create a spreadsheet, rename the tab to `audit`, add the header row from `contract.md` §6.
- Share the spreadsheet with the service account email (editor). Put the spreadsheet id in `LEADFLOW_AUDIT_SHEET_ID`.

### 3.5 Slack

- Create channels `#ops-alerts` and `#leads`, invite the bot.
- Channel names can be overridden with `LEADFLOW_SLACK_ALERT_CHANNEL` / `LEADFLOW_SLACK_NOTIFY_CHANNEL`.

### 3.6 Verify the setup (read-only)

```powershell
curl.exe -s -H "x-n8n-api-key: $env:N8N_API_KEY" http://localhost:5678/api/v1/credentials |
  ConvertFrom-Json | Select-Object -ExpandProperty data | Select-Object name
curl.exe -s -H "Authorization: Bearer $env:HUBSPOT_TOKEN" "https://api.hubapi.com/crm/v3/objects/contacts?limit=1"
```

Expect four credential names and HTTP 200 from HubSpot. Do not start deployment until both pass.

## 4. Deploy the workflows

```powershell
pwsh scripts/deploy-workflows.ps1 -DryRun   # shows credential mapping and target files
pwsh scripts/deploy-workflows.ps1           # upserts, binds errorWorkflow, activates
```

Notes:

- The Public API treats `active` as read-only on create/update. Activation must go through `POST /api/v1/workflows/{id}/activate` (deactivate before updating an active workflow, re-activate afterwards).
- Workflow JSON references credentials by name; the script injects the ids. A missing credential aborts the run with a pointer to this file.
- `02-error-handler` must be active and referenced from `settings.errorWorkflow` of `01-lead-intake`.

## 5. Smoke test

```bash
curl -i -X POST http://localhost:5678/webhook/leadflow-intake \
  -H "Content-Type: application/json" \
  -H "X-Webhook-Secret: $WEBHOOK_SHARED_SECRET" \
  -d '{"form_id":"smoke-1","name":"Jane Doe","email":"Jane@Acme.com","company":"Acme Inc.","phone":"+1 (555) 010-2030","message":"Need lead automation"}'
```

Expect `201` with a `run_id`, one new audit row, a Slack notification, and a HubSpot contact plus (when `icp_fit` passes the threshold) one deal.

## 6. Acceptance runbook (10 assertions)

Use sentinel values (`acceptance-<YYYYMMDD>@example.com`, `form_id=acceptance-<YYYYMMDD>`) and record the audit-sheet row count as the baseline before starting.

| # | Assertion | Method |
| --- | --- | --- |
| 1 | Same `email + form_id` twice: no new records, 1 contact, ≤1 deal | `scripts/acceptance.ps1` |
| 2 | Invalid payloads (missing `email`, bad `email`, bad secret): 422, stable codes, no CRM writes, masked alert | script + visual Slack check |
| 3 | Wrong OpenAI key: 4 HTTP attempts (1 + 3 retries at ~2/8/30 s), then exactly 1 alert, 1 `failed` audit row | manual: swap key in n8n UI, submit, wait ~40 s, restore key |
| 4 | Exactly one audit row per execution; `payload_hash` recomputes | script (hash) + row-count check |
| 5 | `docker compose config` exits 0 | script |
| 6 | Fallback branch: pinned unusable classifier output → `fallback=true`, `outcome=success`, no new deal | n8n pinned data / temporary mock |
| 7 | Masking: no full email/phone in audit rows or alerts | manual regex check |
| 8 | Zero credentials committed | `git grep -I -E "(sk-[A-Za-z0-9]{10,}\|pat-[A-Za-z0-9-]{10,}\|xox[bap]-)"` |
| 9 | Normalisation: `JANE@Acme.com` + `Acme Inc.` equals `jane@acme.com` + `Acme` (same key, same contact/deal, update not insert) | `scripts/acceptance.ps1` |
| 10 | Latency: p95 ≤ 10 s over 50 successful submissions, from audit `latency_ms` | script (after the 50-run sample) |

After assertion 3, restore the OpenAI credential, re-run assertion 1, and reset `LEADFLOW_ICP_FIT_THRESHOLD` to `0.6` before committing anything.

Cleanup: delete the sentinel contacts and deals (`DELETE /crm/v3/objects/{object}/{id}`) and clear acceptance rows from the audit tab so demo recordings start from a clean sheet.

## 7. Troubleshooting

- **Workflow not receiving traffic**: check `active` state via `GET /api/v1/workflows`; production webhooks only work when active. Test webhooks (`/webhook-test/…`) only work while the editor is listening.
- **`$env` values empty**: env vars are read when the container starts; recreate the container after editing `.env`.
- **Credential errors after redeploy**: the deploy script maps by name — renaming a credential in the UI breaks the mapping until the script is re-run.
- **Retry loop not visible**: retries are an explicit loop, not node-level `retryOnFail`; count the HTTP node runs in the execution, not retry badges.
- **Duplicate deals after rapid submissions**: the deal upsert depends on the unique `leadflow_idempotency_key` property; confirm `isUnique` in the property definition.
