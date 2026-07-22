# Audit Verification — Mailbox Owner Actions

## What this is for

Both MCPs claim that per-user audit attribution lands in the Exchange unified audit log. That claim is **conditionally true** — it depends on each target user's mailbox having `MailItemsAccessed` in its `AuditOwner` action set.

This doc is the verification step run once in **Foundry Phase 0** and **Local Phase 0** before either plan's audit claims are treated as load-bearing.

## The check

```powershell
# Connect to Exchange Online (one-time)
Connect-ExchangeOnline -ShowBanner:$false

# For your mailbox (or any target user)
$mbx = Get-Mailbox -Identity jmonaco@gipartners.com

# Verify mailbox auditing is enabled
$mbx | Format-List Identity, AuditEnabled, DefaultAuditSet

# Verify MailItemsAccessed is in the owner action set
$mbx.AuditOwner -contains 'MailItemsAccessed'
# Expected: True
```

## Expected results

| Field | Required value | Why |
|---|---|---|
| `AuditEnabled` | `True` | Implicit in M365 default; verify anyway |
| `DefaultAuditSet` | Contains `Owner` | The default set; if missing, custom config has overridden it |
| `AuditOwner` | Includes `MailItemsAccessed` | Our MCP reads via delegated auth = owner action |

If `MailItemsAccessed` is **not** in `AuditOwner`, the user reading their own archive via Graph (which is what both MCPs do under OBO / delegated auth) will not generate unified-audit events. Tooling will look like it works, App Insights will have correct per-user data, but the IT audit team won't see the activity in the Purview portal.

## How to remediate

> **Note (2026):** the `Set-Mailbox -AuditEnabled` parameter was removed from the EXO V3 REST cmdlet surface. `-AuditOwner` is not exposed in the REST proxy either. Mailbox audit posture is now controlled at the tenant level + Purview audit retention policies; per-mailbox PowerShell remediation no longer works.

### Step 1 — confirm the tenant flag

```powershell
Get-OrganizationConfig | Format-List AuditDisabled
# If True, the only PowerShell knob still available:
Set-OrganizationConfig -AuditDisabled $false
# Re-check the mailbox after ~60 minutes.
```

### Step 2 — prove events are captured end-to-end

This is the load-bearing check; the mailbox property may not reflect what the unified log actually records.

```powershell
# Touch an archive item via Outlook / OWA / the spike. Wait ~30 minutes.
Search-UnifiedAuditLog `
    -StartDate (Get-Date).AddHours(-2) `
    -EndDate   (Get-Date) `
    -UserIds   jmonaco@gipartners.com `
    -Operations MailItemsAccessed `
    -ResultSize 10 |
    Select-Object CreationDate, UserIds, Operations
```

If events land, audit verification is PASS regardless of the `AuditOwner` property contents.

### Step 3 — only if Step 2 fails: Purview portal

**Microsoft Purview → Audit → Audit retention policies → New audit retention policy**

- Users: members of `MCP-ArchiveAccess`
- Record types: `ExchangeItem`, `ExchangeItemGroup`, `MailItemsAccessed`
- Duration: per tenant retention policy

This replaces the old `Set-Mailbox -AuditOwner` mechanism.

## Important caveat — `MailItemsAccessed` and Purview licensing

`MailItemsAccessed` is one of the auditing actions in the **Microsoft Purview Audit (Premium)** feature set. On E3 it logs but is throttled per the standard retention and the throttling rules; on E5 (or E3 with the Audit add-on) you get the full Premium behaviour. Confirm your tenant's license tier before relying on per-call attribution at scale.

## Authoritative vs corroborating

After this verification:

- **App Insights** (Foundry MCP) — primary, authoritative per-call audit. We control the schema and write every tool call with full custom dimensions.
- **Local JSONL** (Local MCP write tools) — primary, authoritative per-call audit for writes.
- **Exchange unified audit log** — corroborating. Useful for cross-correlating with non-MCP mail activity ("did the user also access this mailbox via Outlook?"). Not the primary record for MCP attribution.

Document the result of this verification in the project README or wiki when the plans reference it.

## Log a result like this

After running the check, add a line to the project log:

```
Audit verification — 2026-05-23
  Mailbox: jmonaco@gipartners.com
  AuditEnabled: True
  AuditOwner contains MailItemsAccessed: True
  Tenant tier: E5
  Conclusion: Exchange unified log will corroborate per-user MCP access.
  Result: PASS
```

Or:

```
Audit verification — 2026-05-23
  Mailbox: jmonaco@gipartners.com
  AuditEnabled: True
  AuditOwner contains MailItemsAccessed: False
  Result: FAIL
  Remediation: Apply Set-Mailbox -AuditOwner @{Add='MailItemsAccessed',...} to the MCP-ArchiveAccess group.
  Re-run after remediation.
```
