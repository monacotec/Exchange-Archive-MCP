# Protected Resource Metadata Endpoint (RFC 9728)

## Why this exists

MCP spec 2025-06-18 made one specific change that affects every hosted MCP server: the server is now classified as an **OAuth 2.1 resource server**, and it MUST publish a Protected Resource Metadata (PRM) document at `/.well-known/oauth-protected-resource`.

Without this endpoint, MCP-spec-compliant clients (including Claude Desktop's Connectors UI) cannot discover the authorization server and the OAuth flow fails before it starts.

This affects the **Foundry MCP** (HTTP-hosted) and the **Local MCP Phase 3** (when it becomes HTTP-hosted). It does **not** affect the Local MCP Phase 1/2 (stdio).

## What the endpoint returns

A JSON document conforming to RFC 9728. For our Foundry MCP:

```json
{
  "resource": "https://func-exchange-mcp-prod.azurewebsites.net",
  "authorization_servers": [
    "https://login.microsoftonline.com/{tenant_id}/v2.0"
  ],
  "scopes_supported": ["api://exchange-mcp/Archive.Read"],
  "bearer_methods_supported": ["header"],
  "resource_documentation": "https://func-exchange-mcp-prod.azurewebsites.net/docs",
  "mcp_protocol_version": "2025-06-18",
  "resource_type": "mcp-server"
}
```

## Implementation in `function_app.py`

The endpoint is anonymous (no bearer required — clients haven't acquired a token yet at this point) and idempotent.

```python
import os
import json
import azure.functions as func

# Bound at cold start from app settings / KV
MCP_SERVER_URL = os.environ["MCP_SERVER_URL"]
JWT_ISSUER     = os.environ["JWT_ISSUER"]      # e.g. https://login.microsoftonline.com/<tid>/v2.0
JWT_AUDIENCE   = os.environ["JWT_AUDIENCE"]    # api://exchange-mcp

@app.route(
    route=".well-known/oauth-protected-resource",
    auth_level=func.AuthLevel.ANONYMOUS,
    methods=["GET"],
)
def protected_resource_metadata(req: func.HttpRequest) -> func.HttpResponse:
    body = {
        "resource": MCP_SERVER_URL,
        "authorization_servers": [JWT_ISSUER],
        "scopes_supported": [f"{JWT_AUDIENCE}/Archive.Read"],
        "bearer_methods_supported": ["header"],
        "resource_documentation": f"{MCP_SERVER_URL}/docs",
        "mcp_protocol_version": "2025-06-18",
        "resource_type": "mcp-server",
    }
    return func.HttpResponse(
        json.dumps(body),
        status_code=200,
        mimetype="application/json",
        headers={"Cache-Control": "public, max-age=3600"},
    )
```

The `Cache-Control` header is a deliberate one-hour cap — long enough that clients don't hammer the endpoint, short enough that an auth server change propagates within an hour.

## WWW-Authenticate header

When the MCP server rejects an unauthenticated request (401), the response MUST include a `WWW-Authenticate` header pointing clients to the PRM endpoint. This is how clients discover where the metadata lives.

```python
@app.route(...)
def some_tool(req: func.HttpRequest) -> func.HttpResponse:
    if not has_valid_bearer(req):
        return func.HttpResponse(
            status_code=401,
            headers={
                "WWW-Authenticate": (
                    f'Bearer realm="{MCP_SERVER_URL}", '
                    f'resource_metadata_uri="{MCP_SERVER_URL}/.well-known/oauth-protected-resource"'
                )
            },
        )
    # ... handle the call
```

The Functions MCP extension's native auth handles this for us when configured. If we're on the hand-roll fallback path (Foundry plan §7.2), this is our code.

## Smoke test

```bash
# Should return 200 with valid JSON
curl -i https://func-exchange-mcp-prod.azurewebsites.net/.well-known/oauth-protected-resource

# Should return 401 with WWW-Authenticate pointing to PRM
curl -i https://func-exchange-mcp-prod.azurewebsites.net/runtime/webhooks/mcp
```

Both checks should pass before the server is registered in API Center.

## Local dev

In local dev (`func start`):

```bash
curl http://localhost:7071/.well-known/oauth-protected-resource
```

The `resource` value should be the localhost URL; the `authorization_servers` value remains the Entra tenant (we don't use a local mock IdP).

## Things to NOT do

- **Don't serve PRM behind auth.** It's discovery metadata. If the client needs a token to find out how to get a token, you have a chicken-and-egg problem.
- **Don't omit `Cache-Control`.** Without it, MCP clients may aggressively cache or aggressively refetch, neither of which is ideal.
- **Don't hardcode the tenant ID.** Use `{tenant_id}` resolution from app settings so a tenant rename (rare but possible) is a config change.
- **Don't put PII or detailed scope descriptions in `resource_documentation`.** It's a URL, not a description; point at a human-readable docs page.
