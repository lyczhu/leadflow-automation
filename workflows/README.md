# workflows/

Exported n8n workflow JSON lives here, versioned like source code.

Naming:

```
<seq>-<name>.v<major>.json
```

- `01-lead-intake.v1.json` — the main inbound path: webhook → validate → classify → CRM upsert → notify → audit
- `02-error-handler.v1.json` — workflow-level error handler: alert plus a failed-row audit for crashes and exhausted retries

Rules:

- Reference credentials **by name only**: keep the `credentials` block, strip ids and values. `scripts/deploy-workflows.ps1` injects ids from the n8n credential store.
- Bump `v<major>` only for structural changes; minor tweaks can be committed in place.
- Every export gets a one-line note in the PR/commit message describing what changed in the graph.

Notes:

- Audit rows are written inline at the three terminal points (success, rejected, failed). There is no audit sub-workflow.
- `outcome` only ever holds terminal values (`success` / `failed` / `rejected`): one execution writes exactly one row, so the `retrying` state lives in n8n execution history rather than in the sheet.

Import: n8n UI → Workflows → ⋯ → *Import from File*, or run `pwsh scripts/deploy-workflows.ps1` (see `reference/setup.md`).
