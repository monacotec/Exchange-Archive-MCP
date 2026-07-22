# Claude Code Guardrail — Block Direct `az` / `azd` Calls

A drop-in Claude Code hook that prevents the agent from ever invoking the Azure CLI
(`az`) or Azure Developer CLI (`azd`) directly. Instead, the agent packages any Azure
or Microsoft Graph work — including authentication — as a PowerShell script the human
runs themselves.

## Why

Letting an agent call `az` directly has three failure modes we hit in practice:

1. **Surprise auth prompts.** Conditional-access sign-in frequency policies (e.g.
   4-hour token lifetime) mean the agent's cached az session expires mid-task. The
   agent's natural recovery is to run `az login`, which pops a browser window at an
   arbitrary moment — the human loses control over when and where credential prompts
   appear.
2. **Unreviewed cloud mutations.** A single compound command can slip a mutating call
   (`az keyvault delete`, `az ad app update`) past a human skimming the permission
   prompt, especially embedded mid-pipeline (`$x = az ... ; ...`).
3. **No durable audit.** Ad-hoc CLI calls leave no artifact. A script in the repo is
   reviewable before it runs, diffable after, and can carry its own mutation logging
   (timestamp + UPN per action).

The replacement convention: the agent writes an idempotent `.ps1` into the repo
(auth + work + verification + logging in one file), the human runs it from their own
shell and pastes results back.

## The hook

Add to `~/.claude/settings.json` (user-global; use a project's
`.claude/settings.json` instead to scope it to one repo). Merge into an existing
`hooks` block if you have one:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|PowerShell",
        "hooks": [
          {
            "type": "command",
            "shell": "powershell",
            "timeout": 15,
            "statusMessage": "Checking for direct az/azd calls",
            "command": "$j=[Console]::In.ReadToEnd()|ConvertFrom-Json; $c=[string]$j.tool_input.command; if($c -match '(?i)(^|[^\\w-])(az|azd)(\\.cmd|\\.exe)?(\\s|$)'){ Write-Output '{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"Direct az/azd calls are not allowed. Write the operation as a .ps1 in the repo for the user to run.\"}}' }"
          }
        ]
      }
    ]
  }
}
```

## How it works

- **`PreToolUse` on `Bash|PowerShell`** — the hook inspects every shell command
  before it executes, regardless of which shell tool the agent picked.
- **The regex** `(?i)(^|[^\w-])(az|azd)(\.cmd|\.exe)?(\s|$)` catches `az`/`azd` at the
  start of a command, after any separator (`;`, `|`, `&&`, `=`, `(`, quotes, spaces),
  and with Windows launcher suffixes (`az.cmd`, `az.exe`). This defeats the common
  bypass of embedding the call mid-command (`$tenant = az account show ...`), which a
  plain `deny: ["Bash(az *)"]` permission rule does **not** catch (prefix match only).
- **It does not false-positive** on `azure-functions`, `azure.identity`, or other
  tokens merely containing "az" — the trailing `(\s|$)` requires `az`/`azd` to stand
  alone.
- **`permissionDecision: "deny"`** blocks the call outright (no prompt) and feeds the
  reason back to the agent, which redirects it to the script convention instead of
  retrying.
- Runs in PowerShell (`"shell": "powershell"`) so it works on Windows hosts without
  Git Bash or `jq`.

## Verify it works

1. **Pipe-test the logic** (no Claude needed):

   ```powershell
   '{"tool_input":{"command":"$t = az account show"}}' | pwsh -NoProfile -Command `
     '$j=[Console]::In.ReadToEnd()|ConvertFrom-Json; if([string]$j.tool_input.command -match ''(?i)(^|[^\w-])(az|azd)(\.cmd|\.exe)?(\s|$)''){"DENIED"}else{"allowed"}'
   ```

   Expect `DENIED`. Swap the command for `pip install azure-functions` and expect
   `allowed`.

2. **Prove it fires in-session**: ask Claude to run `az version`. The call should be
   blocked with the deny reason before any permission prompt appears. (Settings
   changes apply to running sessions; if the hook doesn't fire, restart the session.)

## Caveats

- **`az bicep build` is also blocked** — it is a purely local compile, but it is still
  an `az` invocation. Options: install the standalone `bicep` CLI for local validation,
  put the compile inside the user-run deploy script, or carve out an exception by
  adding a negative lookahead to the regex: `(?!bicep\b)` after the `(az)` alternative.
- **This is agent-guardrail, not a security boundary** for a hostile actor — a human
  operator can still run `az` from any terminal; the SDKs (Python `azure-identity`,
  Graph PowerShell) are not blocked. The hook constrains the *agent's* default
  behavior; pair it with the script convention and (if needed) further hooks for
  `Connect-MgGraph` / `Connect-ExchangeOnline`.
- **Deny rules vs hook**: keep permission `allow` lists free of `Bash(az ...)` entries
  once this is installed — they become dead entries the hook overrides, and they
  confuse future readers.

## The companion script convention

Every script the agent writes for Azure/Graph work follows this shape (see
`foundry-mcp/scripts/Set-ClaudeConnectorAuth.ps1` in this repo for a full example):

- `#Requires -Version 7.0`, `Set-StrictMode -Version Latest`,
  `$ErrorActionPreference = 'Stop'`
- Interactive **browser** auth only — never device code; tenant and subscription
  pinned as parameters; re-auth only when a cheap probe shows the token is stale
- Idempotent — safe to re-run; converges instead of failing on partial state
- `SupportsShouldProcess` (`-WhatIf` / `-Confirm`) on anything destructive
- Prints its own verification (a fix you can't demonstrate isn't done) so the human
  can paste output back to the agent
- Logs every mutating action with ISO timestamp + signed-in UPN to a `logs/` file
