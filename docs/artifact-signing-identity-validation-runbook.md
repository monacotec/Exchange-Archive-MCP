# Runbook — Azure Artifact Signing: Organization Identity Validation

**Purpose:** stand up code signing for `ArchiveOpen.exe` (the `giparchive:` desktop
handler) and, as a bonus, this repo's PowerShell scripts. The **Organization
identity validation** step is portal-only and Microsoft-gated (**1–20 business
days**), so it is the critical path — start it first.

**Context:** Artifact Signing (formerly *Trusted Signing* / *Azure Code Signing*)
issues short-lived (72 h) certificates from an identity-validated profile that
chain to a **publicly trusted** Microsoft root. No HSM, no long-lived cert to
protect. GI Partners (US organization) is eligible for **Public Trust**.

**Who runs this:** an admin with Owner/Contributor + User Access Administrator on
subscription `db17a4a4-f677-498a-b4a2-eb401ba9cf29`, and access to the legal
entity's public records + a business email that can receive external links.

---

## 0. Eligibility pre-check (do this BEFORE anything else)

Validation stalls or fails on mismatches, so confirm up front:

- [ ] **Legal entity name** exactly as it appears in official/public records
      (Secretary of State registration, D&B, etc.). This string becomes the
      certificate subject `O=` — get it exactly right; changing it later means a
      **new** validation and re-signing everything.
- [ ] **Public records are current** and discoverable (registration, address).
- [ ] **A business identifier** is available (e.g. D-U-N-S number or the
      registration/incorporation number).
- [ ] **A website** on the entity's domain.
- [ ] **Two business emails** (primary + secondary, same domain) that can receive
      external emails with links. Primary receives the verification link (expires
      in 7 days).
- [ ] **Billing account details** (legal name + address) under the subscription
      **match** the legal entity — Microsoft cross-checks these.
- [ ] Documents you may be asked to upload must be **issued within the last 12
      months** and, if they carry an expiry, expire **≥ 2 months** out.

> If any of these are uncertain (esp. entity-name/records mismatch), resolve it
> before submitting — a rejected validation costs days.

---

## 1. Provision the account (scriptable) — do first

Run the companion script (Phase Account):

```powershell
& 'C:\Users\jmonaco\Documents\AI Workfolder\Projects\Archive-Mailbox-MCP\foundry-mcp\scripts\Initialize-ArtifactSigning.ps1' -Phase Account
```

It registers the `Microsoft.CodeSigning` provider, creates the Artifact Signing
account (`gipartifactsign` in `finresgroup`/eastus by default), and grants you the
**Trusted Signing Identity Verifier** role so the portal will let you start
validation. If the `az artifact-signing` extension fails to load (EDR has blocked
other az extensions this session), create the account in the portal instead:
**portal → search "Artifact Signing Accounts" → Create** (same RG/region/name),
then continue below.

---

## 2. Register the Resource Provider (if not already)

Portal → **Subscriptions → [your sub] → Resource providers →** search
`Microsoft.CodeSigning` → **Register** (status becomes *Registered*). The script
already requests this; verify it here.

---

## 3. Organization identity validation (PORTAL ONLY — the long pole)

1. Portal → open the Artifact Signing account → **Objects → Identity validations**.
   (If **New identity** is greyed out, you lack the *Identity Verifier* role —
   fix via step 1 / RBAC, then return.)
2. Select **Organization**, click **New Identity**, choose **Public**.
3. Fill in, matching your step-0 records **exactly**:
   - **Organization Name** = legal business entity (→ certificate `O=`).
   - **Website URL** = entity domain.
   - **Primary Email** / **Secondary Email** = same-domain business addresses that
     accept external links.
   - **Business Identifier** = D-U-N-S or registration number.
   - **Address** = the entity's registered business address.
   - **First/Last Name** = the individual representative (must match their
     government ID — they complete an individual Verified-ID check as part of this).
4. Click **Certificate subject preview** and confirm it reads correctly.
5. **Create.** Status → **In Progress**.
6. Watch the primary inbox: you'll get an email verification link (7-day expiry)
   and, when status shows **Action Required**, a link for the representative's
   **Verified ID** check (Microsoft Authenticator + a third-party ID verifier;
   government photo ID, done on a phone — follow the on-screen QR flow).
7. If Microsoft needs more documents, status returns to **Action Required** and you
   upload them in the portal (3 attempts; recent, unaltered, color, per the
   on-screen file rules).
8. Done when status = **Completed** (email sent). **Processing: 1–20 business
   days.** Check the portal status any time.
9. **Copy the Identity Validation Id** from the completed validation's pane — you
   need it for the certificate profile.

---

## 4. Certificate profile + signer role (scriptable) — after Completed

```powershell
& 'C:\Users\jmonaco\Documents\AI Workfolder\Projects\Archive-Mailbox-MCP\foundry-mcp\scripts\Initialize-ArtifactSigning.ps1' `
    -Phase Profile -IdentityValidationId <paste-from-portal> -SignerPrincipalId <build-account-object-id>
```

Creates the **PublicTrust** certificate profile (`gip-code-signing`) and grants
**Trusted Signing Certificate Profile Signer** to the signing identity (default:
the identity-verifier account). Portal fallback if the extension won't load:
account → **Objects → Certificate profiles → Create → Public Trust**, pick the
completed identity validation, name it `gip-code-signing`.

---

## 5. Build-box prerequisites (one-time on whoever signs)

- Windows 10 1809+/11, **.NET 8 SDK** (build) + runtime.
- **Windows SDK** (for `signtool.exe`).
- The **Trusted/Artifact Signing dlib** (`Azure.CodeSigning.Dlib`) + a
  `metadata.json` holding the region **endpoint** (`https://eus.codesigning.azure.net`
  for East US), the **CodeSigningAccountName** (`gipartifactsign`), and the
  **CertificateProfileName** (`gip-code-signing`).

Then sign:

```powershell
& 'C:\Users\jmonaco\Documents\AI Workfolder\Projects\Archive-Mailbox-MCP\foundry-mcp\desktop-handler\build.ps1' `
    -DlibPath <path\Azure.CodeSigning.Dlib.dll> -MetadataPath <path\metadata.json>
```

`build.ps1` publishes the self-contained exe and signs it with `signtool … /dlib
… /dmdf …`, then verifies the signature chains to a trusted root.

---

## 6. What this unblocks

- **D1/D3:** the signed `ArchiveOpen.exe` can ship via Intune to all workstations.
- **Bonus:** the same profile signs this repo's PowerShell scripts (currently
  unsigned) — a standing security upgrade. Sign a `.ps1` with
  `Set-AuthenticodeSignature` using a cert issued from the same profile, or
  `signtool` for the exe path.

## 7. Costs

Consumption/low fixed monthly on the Basic SKU; confirm current pricing at the
account-creation blade. Signing a handful of exe/script revisions is negligible.

---

## Status log (fill in as you go)

| Step | Owner | Date | Status |
|---|---|---|---|
| Eligibility pre-check | | | |
| Account provisioned (Phase Account) | | | |
| Identity validation submitted | | | (1–20 business days) |
| Identity validation **Completed** | | | Identity Validation Id: `________` |
| Certificate profile created (Phase Profile) | | | |
| Build box prepped + test sign verified | | | |
