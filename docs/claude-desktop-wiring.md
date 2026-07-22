# Claude Desktop Wiring

How to connect each of the two MCPs to Claude Desktop. **They use different pathways and are not interchangeable.**

## Local MCP (stdio) — `claude_desktop_config.json`

The Local MCP runs as a child process of Claude Desktop, communicating over stdio. This pathway is unchanged from rev 1 and still works.

### Config file location

| OS | Path |
|---|---|
| Windows | `%APPDATA%\Claude\claude_desktop_config.json` |
| macOS | `~/Library/Application Support/Claude/claude_desktop_config.json` |

### Entry

```jsonc
{
  "mcpServers": {
    "exchange-archive": {
      "command": "pwsh",
      "args": [
        "-NoLogo",
        "-File",
        "C:\\Users\\jmonaco\\Code\\exchange-archive-mcp\\src\\Server.ps1"
      ]
    }
  }
}
```

### Verification

1. Restart Claude Desktop after saving the config file.
2. In a chat, ask Claude to list its tools. The five `archive_*` tools should appear.
3. First tool call triggers an interactive Entra sign-in via `Connect-MgGraph`. Subsequent calls are silent.

### Troubleshooting

- **Tools don't appear:** Check Claude Desktop's MCP log (Help → View Logs). Path typos and `pwsh` not being on PATH are the usual causes.
- **First call hangs:** The interactive browser sign-in may be blocked by a popup blocker. Disable it for `localhost` and the Entra portal.
- **"Cannot find module Microsoft.Graph.Authentication":** Run `Install-Module Microsoft.Graph.Authentication -Scope CurrentUser`.

---

## Foundry MCP (HTTP) — **Settings → Connectors**, NOT the config file

> **This is a rev 2 change.** Anthropic's published policy: *"Claude Desktop will not connect to remote servers that are configured directly via `claude_desktop_config.json`."* If you try the config-file pathway for a remote server, it silently fails.

### Add as a custom connector

1. Claude Desktop → **Settings** → **Connectors** → **Add custom connector**.
2. **Server URL:** `https://func-exchange-mcp-archive-mailbox-mcp.azurewebsites.net/runtime/webhooks/mcp`
3. **Name:** `Exchange Archive (Foundry)` (or your preference).
4. **OAuth Client ID** (under advanced settings): `9519ca68-dae2-4add-8309-4bdd1fa45e79`. Leave the client secret blank — the app reg is a PKCE public client. This field is **required**: Entra does not support Dynamic Client Registration, so without it Claude Desktop shows *"Automatic client registration isn't supported."* The Claude callback URIs must be registered on the app reg's **public-client** platform (not Web, which forces confidential-client + secret) — `scripts/Set-ClaudeConnectorAuth.ps1` enforces this.
5. Click **Connect**. Claude Desktop:
   - Hits the server's `/.well-known/oauth-protected-resource` to discover the authorization server.
   - Opens a browser to the Entra sign-in page.
   - User signs in and consents to `Archive.Read`.
   - Token is stored in Claude Desktop's connector store, refreshed automatically.

### Entra app pre-requisites

The Entra app reg MUST have these redirect URIs allowlisted:

- `https://claude.ai/api/mcp/auth_callback`
- `https://claude.com/api/mcp/auth_callback` *(Anthropic-flagged future callback)*

These are added in Foundry plan Phase 0 §5.1. If they're missing, the OAuth dance fails with a redirect-URI mismatch error.

### Verification

1. After connect succeeds, the connector appears in the Settings → Connectors list with a green dot.
2. In a chat, ask Claude to list available tools. The three `*_archive_*` tools should appear.
3. Test invocation: "search my archive for emails from CFO in March 2026."
4. Check App Insights — the call should appear with `user_identity` = the signed-in user's `upn` claim.

### Troubleshooting

- **"Cannot reach the server":** Check the Function App is running (`az functionapp show`) and that corporate egress filtering isn't blocking `*.azurewebsites.net`. The endpoint is public by design (Foundry Agent Service reachability), gated by Easy Auth — no VPN required.
- **"Automatic client registration isn't supported":** Expected on first setup — Entra has no DCR. Edit the connector and set the OAuth Client ID (step 4 above).
- **"OAuth flow failed: redirect_uri mismatch":** The Entra app reg is missing `https://claude.ai/api/mcp/auth_callback`. Add it via Phase 0 §5.1.
- **AADSTS7000218 ("client_assertion or client_secret required"):** The Claude callback URI is registered under the app reg's Web platform. Run `foundry-mcp/scripts/Set-ClaudeConnectorAuth.ps1` to move it to the public-client platform.
- **"OAuth flow failed: invalid_scope":** The user has not been added to the `MCP-ArchiveAccess` security group. ApplicationAccessPolicy is blocking. Add the user via IT ticket.
- **"Server discovered but no tools":** Likely the PRM endpoint is missing or returns invalid JSON. See [`protected-resource-metadata.md`](protected-resource-metadata.md).

---

## Summary table

| | Local MCP | Foundry MCP |
|---|---|---|
| Transport | stdio | HTTP (streamable) |
| Pathway | `claude_desktop_config.json` | Settings → Connectors UI |
| Auth | `Connect-MgGraph` interactive (browser) | OAuth 2.1 / PKCE via Claude Desktop |
| Token storage | MSAL.NET cache (`%LOCALAPPDATA%\Microsoft\Graph\TokenCache\`) | Claude Desktop's connector store |
| Multi-user | No (single OS user) | Yes (each user has their own connector instance) |
| Network | local pwsh process | VNet-integrated Function App |
