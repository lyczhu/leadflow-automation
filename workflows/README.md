# workflows/

Exported n8n workflow JSON lives here, versioned like source code.

Naming:

```
<seq>-<name>.v<major>.json
```

- `01-lead-intake.v1.json` — the main inbound path
- `02-error-handler.v1.json` — shared error workflow (retry, alert)
- `03-subflow-audit.v1.json` — audit log writer, reused by other workflows

Rules:

- Export with **credentials stripped**. Never commit tokens; they belong in `.env` / n8n's credential store.
- Bump `v<major>` only for structural changes; minor tweaks can be committed in place.
- Every export gets a one-line note in the PR/commit message describing what changed in the graph.

Import: n8n UI → Workflows → ⋯ → *Import from File*.
