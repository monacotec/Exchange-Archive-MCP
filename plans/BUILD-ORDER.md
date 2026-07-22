# Build Order — Both MCPs

This file resolves "which phase do I work on next?" across both plans.

## The week-by-week view

### Week 1 — De-risk

| Day | Work | Output | Done when |
|---|---|---|---|
| Mon AM | Run `local-mcp/spike/Spike-ArchiveAccess.ps1` | Folder tree printed; cache file at `%LOCALAPPDATA%\ExchangeArchiveMcp\graph-cache\` | Archive folder hierarchy visible; sign-in works silently on second run |
| Mon PM | Clone `Azure-Samples/remote-mcp-functions-python` into a scratch RG; `azd up` | Working remote MCP with Entra auth | You can call its `hello` tool from Claude Desktop via the Connectors UI |
| Tue AM | Diff that template against `foundry-mcp/function_app.py` | A list of what we keep vs. replace | Decision logged: hand-roll JWT middleware? Hand-roll OBO? |
| Tue PM | Confirm `MailItemsAccessed` is in `AuditOwner` for the test mailbox; record the result | One-line entry in `docs/audit-verification.md` | Either confirmed or remediation ticket filed |

By end of Tuesday you have an honest answer to "what is the actual scope of Foundry Phases 2–3?" — which could be anywhere from 2.5 days to 0.5 days. **Do not skip this week.**

### Weeks 2–3 — Local MCP Phases 1 + 2

The Local MCP gets shipped first because:

- It unblocks Jeff's daily archive workflows immediately
- The two-step confirm pattern needs to be built and battle-tested before we port it to Foundry's v2
- Single-user scope means less can go wrong; faster iteration cycle

Phase 1 (read-only, 2 d) → Phase 2 (writes + confirm, 2 d) → tag `v0.2.0`.

### Weeks 4–5 — Foundry MCP Phases 1–4

Once Local MCP is in daily use:

- Phase 1: Infra (Bicep, VNet, KV, Private Endpoints) — 1 d
- Phase 2: **Configure** native Entra auth on the Functions MCP extension (or hand-roll if needed) — 0.5–1.5 d
- Phase 3: **Configure** OBO to Graph (or hand-roll if needed) — 0.5–1 d
- Phase 4: Wire the three read-only tools to the per-user Graph client — 1 d

Tag `v0.4.0`.

### Week 6 — Discoverability + hardening

- Foundry Phase 5 (API Center registration, Claude Desktop Connectors UI wiring) — 0.5 d
- Foundry Phase 6 (security checklist walk) — 1 d
- Local MCP Phase 4 (security checklist walk against same baseline) — 1 d

Tag both at `v1.0.0`.

### Beyond v1

Parallelisable:

- **Local MCP Phase 3** — HTTPS hosted transport for multi-user. Only do this if there's actual demand; stdio is fine for single-user daily use.
- **Foundry MCP v2** — write tools. Port the Local MCP's two-step confirm pattern. Block on v1 having been in use long enough to know the pattern works under real prompts.

## Hard dependencies between the two plans

These are the only places where one plan blocks the other:

1. **Local MCP Phase 2 must ship before Foundry v2 even starts.** The confirm pattern is the reusable piece.
2. **The security baseline updates (§19 / 2025-06-18 spec) must be reviewed before either MCP's hardening phase.** That's one document, not two.
3. **The Entra app registration is shared.** Both MCPs use the same app reg with two redirect URIs (loopback for local, Connectors-UI callback for Foundry). Get this right once in Phase 0.

Everything else can be done in either order.

## Where to look if you're stuck

| Symptom | First place to look |
|---|---|
| "Spike doesn't sign in" | `docs/claude-desktop-wiring.md` — wrong redirect URI is the usual cause |
| "Foundry tool calls work but audit log shows the MI, not the user" | `docs/audit-verification.md` — OBO isn't engaged |
| "Claude Desktop can't see the Foundry MCP" | `docs/claude-desktop-wiring.md` — config-file vs Connectors-UI |
| "PRM endpoint returns 404" | `docs/protected-resource-metadata.md` — likely a routing issue in `function_app.py` |
| "Confirmation token rejected" | `plans/LOCAL-MCP-PLAN.md` §6 — most often clock skew or replay |
