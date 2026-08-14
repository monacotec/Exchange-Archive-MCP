# Day-Zero Hygiene Pass (Phase −1)

**Project:** MCP Exchange Archive bundle — cross-cutting
**Owner:** Jeff (GI Partners)
**Status:** Partially complete — code patches for items 1–6 are applied in this bundle revision (2026-07-02); verification steps remain
**Effort:** ~1 day total, runs in parallel with Local MCP Phase 0
**Source:** `REMEDIATION-GUIDE.md` Lessons 3 and 11 — findings 5, 6, 7, 12, 13, 44, 45, 46, 47, plus the doc corrections from Lesson 8 (finding 21)

---

## Why this phase exists

The remediation roadmap's item 2 (stop leaking secrets into durable records) lives almost entirely in `foundry-iac` and the shared operational scripts — components that **neither build plan owns**. Without an explicit home, these findings fall through the cracks. Everything here is independent of the two MCP builds, self-contained, and must land **before** Foundry Phase 0 runs the shared scripts and before any `azd`/`az deployment` run resolves `listKeys()` into a durable record.

---

## Tasks

| # | Task | Finding(s) | File(s) | Status in this bundle |
|---|---|---|---|---|
| 1 | Remove `listKeys()` → Key Vault secret materialization (ARM deployment history leak) | 6 | `foundry-iac/modules/openai.bicep` | ✅ Patched |
| 2 | OpenAI Hub connection: `authType: 'ApiKey'` → `'AAD'` (keyless); grant `Cognitive Services OpenAI User` to Hub **and** Project MIs; keep `isSharedToAll: true` | 13, 30 | `foundry-iac/modules/foundry.bicep` | ✅ Patched |
| 3 | CI: drop `--result-format FullResourcePayloads`; migrate `AZURE_CREDENTIALS` JSON secret → OIDC federated credentials | 7, 12 | `foundry-iac/.github/workflows/bicep-validate.yml` | ✅ Patched (federated credential must be created in Entra — see §Manual steps) |
| 4 | Identity-based `AzureWebJobsStorage` (`allowSharedKeyAccess: false`, MI + `Storage Blob Data Owner` / `Storage Queue Data Contributor`, `AzureWebJobsStorage__accountName`) | 5, 31 (partial) | `exchange-mcp/infra/modules/functionapp.bicep` | ✅ Patched |
| 5 | `try/finally` guaranteed `Disconnect-MgGraph` / `Disconnect-ExchangeOnline` on all shared scripts (per gi-foundry CLAUDE.md rule) | 44, 45, 46 | `scripts/Register-EntraApp.ps1`, `scripts/Set-ApplicationAccessPolicy.ps1`, `scripts/Rotate-MCPClientSecret.ps1` | ✅ Patched |
| 6 | Secret rotation: add `-RevokeOld` switch so the retiring secret can be revoked once the Function App confirms pickup, instead of staying live ~1 year | 47 | `scripts/Rotate-MCPClientSecret.ps1` | ✅ Patched |
| 7 | Resolve the `dry_run` doc contradiction — default is **locked** to `true`; removed from open decisions | 21 | `files/PLAN.md`, `files/DESIGN.md` | ✅ Patched |
| 8 | `Rotate-OAIKey.ps1` temp-file handling (plaintext key in `%TEMP%`, orphaned `.tmp`) | 22, 43 | `scripts/Rotate-OAIKey.ps1` | ⚠️ Deferred — going keyless (task 2) largely supersedes this script. Do not run it against the keyless connection. Fix or retire it when the keyless cutover is verified. |

## Manual steps (cannot be done in code)

1. **Create the OIDC federated credential** on a CI-dedicated Entra app: subject `repo:<org>/<repo>:pull_request`, audience `api://AzureADTokenExchange`. Grant it Reader + Template Deployment Operator on `rg-ai-foundry-prod` only. Set repo variables `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`; then **delete the `AZURE_CREDENTIALS` repo secret**.
2. **Rotate the OpenAI key1** after task 1 deploys (the old value is already in existing deployment history — removing the Bicep resource does not scrub prior records). Then purge the now-unused `oai-key1-current` KV secret.
3. **Scrub prior CI logs / deployment history**: delete retained GitHub Actions logs for prior `what-if FullResourcePayloads` runs; `az deployment group delete` prior deployment records at the RG scope if key material appears in them.

## Exit criteria (verify — a fix you can't demonstrate isn't done)

- `az deployment operation group list -g rg-ai-foundry-prod` | grep for key material → **no matches** after a fresh deploy.
- Latest CI run log → no key material; `azure/login` step shows OIDC (no `creds:`).
- `az functionapp config appsettings list` → no `AccountKey=` anywhere; `allowSharedKeyAccess` is `false` on the storage account.
- Foundry portal → Hub connection shows auth type Entra ID; a Project-scoped inference call succeeds with **no** key present.
- Force each patched script to throw mid-run → session is disconnected (no lingering `Get-MgContext` / `Get-ConnectionInformation`).
- `Rotate-MCPClientSecret.ps1 -RevokeOld` after a Function App restart → only the newest secret remains on the app registration.
