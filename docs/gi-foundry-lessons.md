# What we keep from gi-foundry

`gi-foundry/` was Eric Gordon's Azure AI Foundry project, imported so this repo could
mirror its structure. The Exchange MCP was born inside it (`exchange-mcp/`) and was
promoted to top-level `foundry-mcp/` on 2026-07-02. The source is now archived at
`archive/gi-foundry/`; this note is what was worth taking out of it first.

Read on 2026-08-14 against the current state of this suite.

---

## 1. Where our conventions came from

Several house rules this repo follows verbatim originate in that plan, not in anything
we invented: PowerShell 7 with `Set-StrictMode -Version Latest` and
`$ErrorActionPreference = 'Stop'`; `SupportsShouldProcess` on anything destructive; a
`version.md` that lists **every** versioned file with no release without it; a one-line
purpose comment on every function and Bicep resource block. Worth knowing the lineage —
they are load-bearing here and were inherited, not chosen fresh.

---

## 2. Worth adopting — things it has that we do not

### 2.1 Bicep validation in CI, with a real security posture
`foundry-iac/.github/workflows/bicep-validate.yml` runs `az deployment group what-if` on
every PR touching the IaC. **This repo has no CI at all** — our bicep is validated only
when someone remembers to run `az bicep build` by hand (and I could not run it at all).

Three details in that workflow are the valuable part:

- **OIDC federated credentials instead of a stored `AZURE_CREDENTIALS` secret.** The token
  is minted per run; nothing long-lived sits in the repo. Client/tenant/subscription IDs
  are repo *variables*, not secrets.
- **The CI identity is scoped to Reader + Template Deployment Operator on one resource
  group — never Contributor.** Validate, never mutate.
- **Never use `what-if --result-format FullResourcePayloads` in CI.** It resolves
  `listKeys()` and secret values into the retained Actions log. The default
  `ResourceIdOnly` does not. That is a subtle leak most people would ship.

Directly applicable: our `sqlhost.bicep` and `functionapp.bicep` would both benefit, and
the SQL host now holds real (if metadata-only) firm data.

### 2.2 Private endpoints as the default, not the upgrade path
The Foundry stack puts Key Vault, OpenAI and storage behind private endpoints with
`publicNetworkAccess = Disabled`, four private DNS zones, and a delegated subnet. Our
shared SQL host is public-with-a-firewall-allowlist, and `sqlhost.bicep` says in a comment
that a private endpoint is the move "if this ever holds anything more sensitive than mail
METADATA". Eric's `network.bicep` + `keyvault.bicep` are the working reference for that
day, including the DNS-zone wiring that is the fiddly half.

### 2.3 Dual-key rotation choreography
`Rotate-OAIKey.ps1` runs a six-phase rotation: switch the consumer to Key2 → **pause 30s
for propagation** → regenerate Key1 → switch back to Key1 → pause → regenerate Key2. The
ordering matters: it never regenerates the key currently in use, and it never assumes the
switch took effect instantly.

Our `Rotate-MCPClientSecret.ps1` has the two-secret overlap but not the *switch-then-
regenerate* ordering or the propagation pause — it relies on the Function App picking up
the new secret from Key Vault on restart. Worth folding in if the connector ever needs a
zero-downtime rotation rather than a restart window.

### 2.4 Cost and ownership tags applied uniformly
Every resource carries `{ Environment, Owner: 'IT-Infrastructure', CostCenter: 'IT-AI',
ManagedBy: 'Bicep-IaC' }`. Our `sqlhost.bicep` accepts a `tags` param that nothing
currently populates, and the always-on S0 tier plus the always-ready Function instance are
now continuous spend. Tagging them is the difference between "AI costs" being an
answerable question and a guess.

### 2.5 Small things worth stealing
- `@batchSize(1)` on model deployments to stop a capacity race between parallel deploys.
- Irreversibility documented **in the parameter description**:
  `'Enable managed VNet on Foundry Hub — WARNING: irreversible after creation'`.
  Cheap, and it puts the warning where the person changing the value will actually read it.

---

## 3. Do not inherit — patterns we have already had to undo

This is the more useful half. Two of our worst incidents trace straight back to this plan.

### 3.1 App-only Graph permissions with a caller-supplied mailbox = confused deputy
The original `exchange-mcp` design (Phase 3/4) granted the app **application** permissions
(`Mail.Read`, `Mail.ReadBasic.All`, `User.Read.All` as Roles) and had every tool take a
`user_email` argument, with an `MCP_ALLOWED_MAILBOXES` env check as the guard. That is the
textbook confused-deputy shape: the server holds tenant-wide mail access and decides whose
mail to read based on what the caller *claims*.

Our rev-2 rewrite closed it **structurally rather than with a guard** — there is no
`user_email` argument anywhere; identity comes from the verified Easy Auth principal, and
the allowlist is checked against that verified UPN as defense-in-depth only. This is
REMEDIATION-GUIDE Lesson 1, and it is the single most important difference between the
inherited design and the shipped one.

### 3.2 A floating extension-bundle range
The plan specifies:

```json
"extensionBundle": { "version": "[4.*, 5.0.0)" }
```

with the note "Do not downgrade below 4.x". That floating range is precisely what caused
the **11 August 2026 outage**: Microsoft published preview bundle 4.46.0, an ordinary host
recycle adopted it silently, and `tools/list` broke for every new connector session — no
deploy, no config change, nothing in the activity log. `host.json` is now pinned to exact
`[4.44.0]`. Never float a preview bundle in production.

### 3.3 Y1 Consumption hosting
The plan specifies the Y1 Consumption plan ("scale to zero"). We are on Flex Consumption
and still had to add an always-ready instance, because scale-to-zero cold starts exceed
the MCP client's connect timeout and users see "couldn't reach the server". Scale-to-zero
is a cost feature that trades away first-request latency; interactive MCP endpoints cannot
pay that.

---

## 4. Verdict

Archived, not deleted. The IaC patterns in §2 are the reference implementations for
hardening we have deliberately deferred (private endpoints, CI validation, tagging), and
§3 is the record of *why* our design diverged — which is the part that gets forgotten and
re-litigated.
