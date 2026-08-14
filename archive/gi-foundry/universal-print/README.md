# universal-print — Universal Print Automation

PowerShell scripts for registering printers and managing shares via Microsoft Universal Print.

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| M365 E3/E5 or Universal Print add-on | $0.40/printer/month standalone |
| Printer Administrator M365 role | Required for both scripts |
| Universal Print Connector installed | On a Windows 10/11 or Server 2016+ machine near the printers |
| Microsoft.Graph PS module | `Install-Module Microsoft.Graph -Scope CurrentUser` |
| Windows 10 21H1+ or Windows 11 | Required on client machines to add printers |

## Files

| File | Purpose |
|------|---------|
| `printers.csv` | Manifest of printers, share names, and assigned groups — populate before running |
| `Register-Printers.ps1` | Run on the connector host to register printers with Universal Print |
| `Set-PrinterShares.ps1` | Run from any machine with Graph access to create shares and assign groups |

## Run Order

1. Install the Universal Print Connector on the machine connected to your printers.
   Download: https://aka.ms/UPConnector
   Sign in with a Printer Administrator account when prompted.

2. Populate `printers.csv`:
   - `PrinterDisplayName` — must match the printer name exactly as Windows sees it on the connector host
   - `ShareName` — the name users will see when adding the printer (e.g. `SF-3F-HP4200`)
   - `GroupName` — existing Entra ID security group display name (e.g. `GRP-SF-Office`)
   - `Office` and `Floor` — informational only

3. On the **connector host machine**, run:
   ```powershell
   .\Register-Printers.ps1
   ```

4. From any machine with Graph access (does not need to be the connector host):
   ```powershell
   .\Set-PrinterShares.ps1
   ```
   Both scripts are safe to re-run — they skip rows that are already configured.

## Troubleshooting

| Symptom | Likely Cause | Resolution |
|---------|-------------|------------|
| Connector offline in portal | Service stopped or auth token expired | Restart `UniversalPrintConnector` service; re-sign-in if token expired |
| Printer shows 'Error' state | Driver mismatch on connector host | Re-install manufacturer driver; re-register printer |
| Users can't see shared printer | Group not assigned to share | Re-run `Set-PrinterShares.ps1`; verify group exists in Entra |
| Jobs stuck in queue | Printer offline or network issue | Check printer reachability from connector host; verify port 443 outbound open |
| 'Printer Administrator' role missing | License not assigned | Assign Universal Print license in M365 Admin Center → Licenses |
