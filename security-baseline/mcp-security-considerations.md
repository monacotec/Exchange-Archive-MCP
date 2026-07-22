# MCP Security Considerations for Custom Deployments

> Distilled from three sources:
> - *"The MCP Security Survival Guide"* (Towards Data Science, Aug 2025, Hailey Quach)
> - *"Securing MCP Servers for Enterprise Use: Beyond HTTPS Protocol"* (DBASolved / Medium, Aug 2025, Bobby Curtis)
> - *"It's time to secure your MCP servers. Here's how."* (Microsoft Tech Community, Sep 2025, Wassim Chegham)
>
> Intended as a living reference to incorporate into custom MCP server projects at design and review time.

---

## Quick Reference Checklist

Use this at project kickoff and before any deployment.

**Authentication & Access**
- [ ] Authentication required on every endpoint — no open listeners
- [ ] OAuth 2.1 or JWT implemented with proper token audience (`aud`) / issuer (`iss`) validation
- [ ] Token passthrough explicitly disabled
- [ ] API keys use automated rotation; short-lived tokens (15–30 min) with secure refresh
- [ ] Role-based access control enforced with explicitly defined roles and permission enums
- [ ] Per-tool permission enforcement — each tool checks that the caller holds the required permission before executing
- [ ] Authentication middleware applied at the transport layer before any MCP handler runs
- [ ] Multi-tenant deployments enforce per-tenant token scoping and namespace isolation

**Network & Encryption**
- [ ] Listening on `127.0.0.1` only — never `0.0.0.0` by default
- [ ] CSRF protection and Origin/Host header validation in place
- [ ] Deployed in isolated network segment, separate from general corporate network
- [ ] Private connectivity used for cloud deployments (AWS PrivateLink, GCP Private Service Connect, etc.)
- [ ] All data at rest encrypted with AES-256 minimum
- [ ] All data in transit over HTTPS/TLS — no plaintext channels
- [ ] No credentials embedded in container images or source code

**Code & Runtime**
- [ ] All user input sanitized before shell or SQL execution
- [ ] Server runs with least-privilege OS account / containerized
- [ ] Container images scanned; secrets managed via vault, not image layers
- [ ] Rate limiting and resource constraints configured
- [ ] Regular patching schedule established for entire MCP stack

**Operations**
- [ ] Sessions tied to user identity, stored server-side, never in URLs
- [ ] All tool calls logged with inputs, outputs, timestamps, and user
- [ ] Real-time monitoring and alerting on security events active
- [ ] Human approval gate on any destructive or privileged action
- [ ] Incident response procedure documented and tested for AI system compromise
- [ ] Third-party MCP server code reviewed before install; no blind auto-updates
- [ ] Compliance requirements mapped to security controls (GDPR, SOC 2, HIPAA, etc.)

**MCP Spec 2025-06-18 (see §19)**
- [ ] Server documented as OAuth 2.1 *resource server*, not authorization server
- [ ] `/.well-known/oauth-protected-resource` endpoint serves RFC 9728 metadata
- [ ] Tokens carry RFC 8707 Resource Indicator bound to the MCP server's URI
- [ ] `aud` claim validated to match the MCP server's resource URI
- [ ] PKCE used on every client flow (public and confidential)

---

## 1. Authentication

**Threat:** Unauthenticated clients connecting and executing tools.

**Requirements:**
- Treat every MCP server as a protected resource regardless of network location
- Implement OAuth 2.1 or **JWT (JSON Web Tokens)** with full claim validation on every request — validate `aud` (audience), `iss` (issuer), and `exp` (expiry); reject tokens missing any of these
- Use per-client API keys with **automated rotation** — static long-lived keys are a standing liability
- Implement **short-lived tokens**: 15–30 minute lifespans with secure refresh mechanisms are the recommended baseline for enterprise deployments
- Enforce **role-based access control (RBAC)** — define roles and permissions as explicit code-level enums or constants, not magic strings; data analysts, developers, and administrators should have differentiated access
- Apply authentication middleware at the **transport layer** so it runs before any MCP request handler — never rely on individual handlers to remember to check auth
- Never reuse static client credentials across services — this is the foundation of Confused Deputy attacks

**Why JWT is well-suited for MCP specifically:**
- **Stateless** — each token carries all verification data, so the server needs no session store; this scales naturally for concurrent agent requests
- **Self-contained** — user identity, role, and permissions travel in the token payload, reducing round-trips
- **Tamper-proof** — the digital signature means any modification to the payload invalidates the token immediately

**Anti-pattern to avoid:** Assuming "local = safe." CVE-2025-49596 (MCP Inspector RCE) resulted entirely from a local tool with no auth, listening on all interfaces.

---

## 2. OAuth Flow and the Confused Deputy Problem

**Threat:** An attacker registers a legitimate-looking OAuth client, crafts a malicious redirect link exploiting a cached consent cookie, and receives a fully authorized token scoped to the real user's identity — without any consent screen appearing.

**Requirements:**
- Validate redirect URIs strictly against an allowlist — never accept attacker-supplied redirect targets
- Invalidate or scope consent cookies so they cannot be reused across unrelated client registrations
- The MCP Proxy must verify the *origin* of the authorization request, not just the presence of a valid token
- Never allow the proxy to issue an MCP authorization code to a redirect URI it did not initiate

**Design principle:** The system that holds authority (the proxy) must be able to identify *who is asking*, not just *that someone is asking*.

---

## 3. Token Passthrough

**Threat:** A client passes a raw upstream token to the MCP server, which forwards it downstream without validation — bypassing audit trails, rate limits, and access controls.

**Rule:** Token passthrough is explicitly prohibited by the MCP spec.

**Requirements:**
- The MCP server must fetch its own tokens or validate everything a client sends
- Every token must be scoped to this specific server and its declared purpose
- Logs must reflect the actual acting identity, not a forwarded one

---

## 4. Input Validation and Injection Prevention

**Threat:** SQL injection escalating to prompt injection (CVE demonstrated via archived Anthropic SQLite reference server). Shell injection via unsanitized file paths or parameters.

**Requirements:**

### SQL
- Use parameterized queries — never concatenate user input into SQL strings
- Even "internal" data retrieved from a DB must be treated as untrusted before inclusion in prompts or tool calls

### Shell
- Use `subprocess.run([...], shell=False)` — never string-interpolate into shell commands
- Normalize and whitelist file paths; reject traversal patterns (`../`)
- Whitelist input formats rather than blacklisting bad patterns

### Prompt Injection
- Sanitize and delimit all content before it enters the LLM context
- Assume an attacker may have pre-seeded malicious instructions into any stored data the agent will later read
- Gate any destructive action triggered by agent reasoning behind explicit human confirmation

**Note:** The archived SQLite server had 5,000+ forks before the vulnerability was disclosed. Supply chain risk is real — fork and control the lifecycle of any reference implementation you build on.

---

## 5. Principle of Least Privilege

**Threat:** A compromised MCP server with broad permissions causes cascading damage — data deletion, regulatory breach, lateral movement.

**Requirements:**
- Run MCP server processes under a dedicated low-privilege OS account
- Containerize with AppArmor, seccomp, or equivalent sandboxing
- Restrict file system access to exactly what the server needs
- Block outbound network egress unless a specific external call is required
- Do not grant write access to production databases unless the workflow explicitly demands it

**Mental model:** Design the blast radius first. If this server were fully compromised, what is the worst an attacker could do? Minimize that surface before writing the first line.

---

## 6. Network Architecture and Exposure

**Threat:** Server listening on `0.0.0.0` combined with browser quirks (e.g., "0.0.0.0 Day") allows cross-site request forgery from any website the user visits. Flat network placement gives a compromised server lateral reach to unrelated systems.

**Requirements:**

### Binding and CSRF
- Default bind address must be `127.0.0.1` — never `0.0.0.0`
- Add CSRF protection (CSRF tokens or `SameSite` cookie policy)
- Validate `Origin` and `Host` headers on every request
- Dev/debug tools must follow the same network security rules as production — there is no "it's just local"

### Enterprise Network Segmentation
- Deploy MCP servers in **isolated network zones** — not on the general corporate LAN
- Configure firewalls to allow only the specific traffic the server requires; default-deny everything else
- For cloud deployments, use **private connectivity** to keep sensitive traffic off the public internet:
  - AWS: PrivateLink or VPC endpoints
  - GCP: Private Service Connect
  - Azure: Private Endpoint / Private Link
- Never expose MCP server management interfaces to the public internet, even temporarily

**Mental model:** An MCP server that can reach your CRM, email system, and database simultaneously is a high-value pivot point. Segment it as if it were already compromised.

---

## 7. Data Encryption

**Threat:** Sensitive business data — customer records, financial data, strategic plans — stored or cached by the MCP server in plaintext. Interception of data in transit or at rest.

**Requirements:**

### At Rest
- Encrypt all data stored or cached by the MCP server using **AES-256 minimum**
- This includes: model context/conversation logs, cached API responses, session state, any local database used by the server
- Apply the same encryption standard to container volumes and attached storage

### In Transit
- All communication must use **HTTPS/TLS** — no plaintext channels, including internal service-to-service calls
- Enforce minimum TLS 1.2; prefer TLS 1.3
- Do not terminate TLS at a load balancer and pass plaintext internally unless the internal segment is explicitly isolated and audited

### Secrets Management
- Never embed credentials, API keys, or tokens in container images, source code, or configuration files committed to version control
- Use a secrets manager (AWS Secrets Manager, Azure Key Vault, HashiCorp Vault, etc.) for all credentials the server needs at runtime
- Rotate secrets on a schedule and immediately upon any suspected exposure

---

## 8. Container Security

**Threat:** Vulnerable base images, hardcoded credentials in container layers, and lack of runtime protection give attackers a persistent foothold even after patching the application layer.

**Requirements:**
- Use minimal, regularly updated base images; scan every image before deployment
- **Never embed credentials in container images** — this is one of the most common deployment mistakes and is extremely difficult to remediate after the fact
- Apply AppArmor, seccomp, or equivalent runtime protection profiles
- Run containers as non-root users with read-only root filesystems where possible
- Implement proper resource constraints (CPU, memory, network) to prevent resource exhaustion attacks
- Use a container registry with vulnerability scanning; do not pull images from unverified public registries

---

## 9. Session Management

**Threat:** Session IDs treated as identity proof; session hijacking across nodes in distributed deployments.

**Requirements:**
- Never expose session IDs in URLs
- Store session state server-side, not client-side
- Tie every session to verified user identity
- In multi-node deployments: validate identity on each request — a valid session on node A is not proof of identity on node B without re-authentication
- Do not share session context across tenants

---

## 10. Third-Party and Community MCP Servers

**Threat:** Malicious or vulnerable servers installed from GitHub without review; auto-updates introduce new attack surface silently.

**Requirements:**
- Read the code before installing any community MCP server
- Prefer trusted registries over arbitrary GitHub repos
- Disable auto-update from upstream; require diff review before applying updates
- For critical workflows, fork the server and own the release lifecycle
- Do not install servers you would not install as a binary from an unknown source

**Reference:** Trend Micro identified 492 publicly exposed MCP servers with no client authentication or encryption, many with hardcoded credentials, hosted on AWS and GCP.

---

## 11. Logging, Monitoring, and Incident Response

**Threat:** Agent tool chains operate without visibility; no forensic record when something goes wrong; no defined response when a server is compromised.

**Requirements:**

### Logging
- Log every tool call: name, inputs, outputs, timestamp, user/session identity
- Log all human approval events (granted and denied)
- Monitor outbound network calls from the server process
- Alert on anomalous patterns — high-volume tool calls, off-hours execution, unexpected data access
- Align log schema with OpenTelemetry or OCSF where possible for interoperability with existing SIEM tooling

**Minimum log fields per tool call:**

| Field | Notes |
|---|---|
| `timestamp` | ISO 8601 UTC |
| `session_id` | Verified server-side session |
| `user_identity` | Authenticated identity, not just session |
| `tool_name` | Exact tool invoked |
| `input_summary` | Sanitized — no secrets or PII in logs |
| `output_summary` | Result or error code |
| `approval_status` | `auto`, `human_approved`, `human_denied` |

### Monitoring and Alerting
- Deploy real-time monitoring with **intelligent alerting** focused on actionable events — not noise
- Track performance metrics alongside security events; degraded performance can be an early signal of an active attack or resource abuse
- Configure alerts for: failed authentication spikes, unusual tool call volumes, new tool registrations, unexpected egress destinations

### Incident Response
- Develop and **test** incident response procedures specific to AI system compromise — MCP incidents have unique characteristics (agent chaining, ambiguous blast radius) that differ from standard API compromises
- Know how to revoke all active tokens, isolate the server, and audit the tool call log from a defined point-in-time
- Maintain an out-of-band communication channel for IR that does not rely on the potentially compromised system

---

## 12. Human-in-the-Loop Approvals

**Threat:** AI with elevated permissions executes privileged actions autonomously — including destructive ones triggered by injected prompts.

**Requirements:**
- Any action that deletes data, sends external communications, modifies permissions, or spends money must require explicit human approval
- Do not train users to reflexively approve — batch low-risk confirmations; surface high-risk ones distinctly
- Agents should not have privilege levels that exceed the least-privileged human who can approve their actions
- Even if the agent's reasoning looks correct, privileged operations need a confirmation gate

**Atlassian case:** "Living Off AI" attack — prompt injection in a Jira ticket triggered privileged API calls. The agent had elevated permissions and direct API access. Bounded permissions and human approval gates contained the damage.

---

## 13. Resource Management and Rate Limiting

**Threat:** Unrestricted agent tool calls exhaust compute, memory, or downstream API quotas; abuse or a runaway agent causes service degradation or unexpected cost.

**Requirements:**
- Configure **rate limiting** on all MCP endpoints — both per-user and global limits
- Set resource constraints on the server process (CPU, memory, open file handles)
- Implement circuit breakers on downstream API calls to prevent cascade failures
- Monitor resource utilization as a security signal — a sudden spike in tool calls may indicate a prompt injection loop or an attacker probing the system
- Apply cost controls on any MCP server that can trigger paid API calls or cloud resource provisioning

---

## 14. Update and Patch Management

**Threat:** Known vulnerabilities persist in deployed servers because no patching process exists; supply chain risk from outdated dependencies.

**Requirements:**
- Establish a **regular patching schedule** covering all components: the MCP server, base OS, runtime (Node.js, Python, etc.), container base images, and dependencies
- Track CVEs relevant to your MCP stack; subscribe to security advisories for key dependencies
- Treat MCP server updates the same as production application updates — test in staging before deploying
- For community or third-party servers: pin to known-good versions and review changelogs before upgrading; do not enable automatic upstream updates in production
- Maintain a software bill of materials (SBOM) for each MCP server so you can quickly assess exposure when a new CVE is published

---

## 15. Multi-Tenant Deployments

**Threat:** One customer accesses another customer's data due to shared infrastructure without isolated auth or data partitioning.

**Requirements:**
- Scope auth tokens per tenant — no cross-tenant token reuse
- Namespace all tool invocations by tenant ID
- Enforce context boundaries the AI cannot cross in prompt construction
- Never share agent memory or session state across tenants
- Audit cross-tenant access attempts; treat them as security events

**Asana case:** MCP integration bug allowed one customer to read another's data. Fixed by enforcing isolated auth tokens and data partitions per tenant.

---

## 16. Compliance Alignment

**Threat:** MCP server deployment creates regulatory exposure because security controls are not mapped to applicable frameworks.

**Requirements:**
- Before deploying, identify which regulations apply to the data the MCP server will access: GDPR, HIPAA, SOC 2, PCI-DSS, CCPA, etc.
- Map each compliance requirement to a specific technical control — do not assume that encryption alone satisfies a data protection obligation
- Ensure comprehensive audit logging satisfies the access logging requirements of applicable frameworks
- Include MCP server access in data processing agreements and privacy impact assessments where required
- Review data retention and deletion obligations; ensure conversation logs and cached responses are purged according to policy

---

## 17. Future-Proofing: Design Patterns to Adopt Early

These patterns are emerging in the MCP ecosystem and in adjacent agent protocols (A2A, ANP, Agora). Building toward them now reduces future rework.

| Pattern | What It Means for Your Project |
|---|---|
| **Zero Trust per tool call** | Don't assume auth at session start is sufficient; re-verify on sensitive calls |
| **Agent identity tokens** | Cryptographically identify the agent chain, not just the human user |
| **Permission scope declarations** | Declare in server schema which tools require elevated roles |
| **Safety profile metadata** | Advertise whether server performs file writes, network calls, etc. — allows runtime to sandbox automatically |
| **Trace tokens on requests** | Carry a session fingerprint through all components for correlated audit logs |
| **Policy gateway integration** | Route agent actions through a governance layer that enforces time/scope/role rules |

---

## 18. Implementation Reference: JWT + RBAC for Node.js MCP Servers

> Source: Microsoft Tech Community (Azure-Samples/mcp-container-ts)  
> Note: This pattern is a practical, widely-used approach. Full compliance with the official MCP Authorization Specification requires additional work — treat this as a solid foundation, not the final word.

This section provides concrete implementation patterns for the auth concepts in §1. The examples use TypeScript/Node.js but the design applies to any language.

### Step 1 — Define Roles and Permissions as Enums

Never use magic strings for roles or permissions. Define them as enums so typos become compile errors and your permission model is self-documenting.

```typescript
// src/auth/authorization.ts

export enum UserRole {
  ADMIN    = "admin",
  USER     = "user",
  READONLY = "readonly",
}

export enum Permission {
  CREATE_TODOS = "create:todos",
  READ_TODOS   = "read:todos",
  UPDATE_TODOS = "update:todos",
  DELETE_TODOS = "delete:todos",
  LIST_TOOLS   = "list:tools",
}

export interface AuthenticatedUser {
  id:          string;
  role:        UserRole;
  permissions: Permission[];
}

// Map each role to its default permission set
const rolePermissions: Record<UserRole, Permission[]> = {
  [UserRole.ADMIN]:    Object.values(Permission),  // all permissions
  [UserRole.USER]:     [Permission.CREATE_TODOS, Permission.READ_TODOS,
                        Permission.UPDATE_TODOS, Permission.LIST_TOOLS],
  [UserRole.READONLY]: [Permission.READ_TODOS, Permission.LIST_TOOLS],
};
```

**Key design notes:**
- Admin gets all permissions via `Object.values(Permission)` — adding a new permission automatically grants it to admins
- Read-only role can list tools but cannot mutate anything
- The `AuthenticatedUser` interface is the single source of truth for what the server knows about a caller

### Step 2 — Centralized JWT Service

All token creation and verification logic lives in one module. This keeps security-critical code auditable in a single location.

```typescript
// src/auth/jwt.ts — key patterns shown

// All config from environment variables — never hardcoded
const JWT_SECRET   = process.env.JWT_SECRET!;
const JWT_AUDIENCE = process.env.JWT_AUDIENCE!;
const JWT_ISSUER   = process.env.JWT_ISSUER!;
const JWT_EXPIRY   = process.env.JWT_EXPIRY || "2h";  // default 2h; use 15-30m for enterprise

// Fail fast at startup if config is missing
if (!JWT_SECRET || !JWT_AUDIENCE || !JWT_ISSUER) {
  throw new Error("JWT environment variables are not set!");
}

// Token verification: validates algorithm, audience, issuer, and expiry
export function verifyToken(token: string): AuthenticatedUser {
  const decoded = jwt.verify(token, JWT_SECRET, {
    algorithms: ["HS256"],   // lock to specific algorithm — never accept "none"
    audience:    JWT_AUDIENCE,
    issuer:      JWT_ISSUER,
  }) as jwt.JwtPayload;

  // Always validate the shape of the decoded payload
  if (typeof decoded.id !== "string" || typeof decoded.role !== "string") {
    throw new Error("Token payload is missing required fields.");
  }

  return { id: decoded.id, role: decoded.role as UserRole,
           permissions: decoded.permissions || [] };
}
```

**Critical security points:**
- Lock `algorithms` to `["HS256"]` — never pass `algorithms: ["HS256", "none"]`; the "none" algorithm bypass is a classic JWT attack
- Validate `audience` and `issuer` on every verification to prevent token reuse across services
- Fail fast at startup if env vars are missing — don't let a misconfigured server run silently

### Step 3 — Authentication Middleware at the Transport Layer

Apply auth as middleware on the MCP endpoint route, not inside individual handlers. This guarantees no handler can be reached without a valid token, and the authenticated user is available on the request object everywhere downstream.

```typescript
// src/server-middlewares.ts

export function authenticateJWT(req, res, next): void {
  const authHeader = req.headers.authorization;

  // Require Bearer scheme explicitly
  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    res.status(401).json({ error: "Authorization header with 'Bearer' scheme required." });
    return;
  }

  try {
    req.user = verifyToken(authHeader.substring(7));
    next();  // valid token — proceed to handler
  } catch (error) {
    res.status(401).json({ error: "Invalid token", message: error.message });
  }
}

// In src/index.ts — apply to the MCP endpoint only
app.use("/mcp", authenticateJWT);
```

### Step 4 — Per-Tool Permission Enforcement

Authentication (who you are) and authorization (what you can do) are separate checks. Every sensitive MCP tool handler should verify the caller's permissions before executing — do not rely solely on the middleware.

```typescript
// src/server.ts — inside a request handler

this.server.setRequestHandler(ListToolsRequestSchema, async (request) => {
  const user = this.currentUser;

  // Check 1: authenticated at all
  if (!user) return this.createRPCErrorResponse("Authentication required.");

  // Check 2: has the specific permission for this operation
  if (!hasPermission(user, Permission.LIST_TOOLS)) {
    return this.createRPCErrorResponse("Insufficient permissions to list tools.");
  }

  // Check 3: filter the tool list to only tools the user can actually call
  const allowedTools = TodoTools.filter((tool) => {
    const required = this.getToolRequiredPermissions(tool.name);
    return required.some((p) => hasPermission(user, p));
  });

  return { jsonrpc: "2.0", tools: allowedTools };
});
```

**Why tool-level filtering matters:** An agent should only be able to discover tools it is permitted to call. Returning the full tool list to a read-only user and then rejecting calls at execution time leaks information about the server's capabilities and creates unnecessary attack surface.

### Environment Variable Requirements

The following env vars must be set before the server starts. Store them in your secrets manager, not in `.env` files committed to source control.

| Variable | Purpose | Example |
|---|---|---|
| `JWT_SECRET` | HMAC signing secret — treat like a password | 32+ random bytes |
| `JWT_AUDIENCE` | Expected `aud` claim — your server's identifier | `https://mcp.yourcompany.com` |
| `JWT_ISSUER` | Expected `iss` claim — your auth service | `https://auth.yourcompany.com` |
| `JWT_EXPIRY` | Token lifetime | `30m` (enterprise) / `2h` (dev) |

### Full Reference

Working implementation: https://github.com/Azure-Samples/mcp-container-ts

---

## Threat Model Summary

| Threat | Key Control |
|---|---|
| Unauthenticated access | OAuth 2.1 + token audience validation + RBAC |
| Confused Deputy / OAuth hijack | Redirect URI allowlist + origin validation |
| Token passthrough abuse | Server-side token fetch; no client token forwarding |
| SQL / shell injection | Parameterized queries; `shell=False`; input whitelisting |
| Prompt injection via stored data | Treat all retrieved data as untrusted; human gate on destructive actions |
| Over-privileged server compromise | Least privilege OS account; containerization; egress blocking |
| Network exposure / CSRF | Localhost-only bind; CSRF tokens; Origin/Host validation; network segmentation |
| Flat network lateral movement | Isolated network zone; private cloud connectivity; default-deny firewall |
| Data at rest / in transit exposure | AES-256 at rest; TLS 1.2+ in transit; secrets manager |
| Credential leakage via container | No embedded creds; vault-based secrets; image scanning |
| Session hijacking | Server-side sessions; per-request identity verification |
| Malicious community server | Code review before install; fork for production; SBOM |
| No forensic visibility | Structured tool call logging; anomaly alerting; IR runbook |
| Resource exhaustion / runaway agent | Rate limiting; resource constraints; circuit breakers |
| Unpatched CVE | Regular patch schedule; SBOM; CVE tracking |
| Multi-tenant data leakage | Per-tenant token scoping; namespace isolation |
| Compliance gap | Framework mapping; audit logging; data retention controls |

---

## 19. MCP Spec 2025-06-18 Deltas (Rev 2 Appendix)

> Added in rev 2 of this document. The June 2025 MCP authorization spec formalized requirements that affect any new MCP server we build from this point forward. This appendix is **mandatory** for new servers; existing servers should be migrated at their next major release.

### 19.1 MCP servers are OAuth 2.1 Resource Servers, not Authorization Servers

The June 2025 revision clarified that an MCP server is a *resource server* — it accepts and validates tokens; it does not issue them. The authorization server is Entra (or whichever IdP). The MCP server's job is to expose enough metadata for clients to find the right authorization server.

**Requirement:** Document explicitly in each MCP project's README that the server is a resource server. Do not implement token-issuance endpoints.

### 19.2 Protected Resource Metadata (RFC 9728) is mandatory

**Requirement:** Every hosted MCP server MUST serve `GET /.well-known/oauth-protected-resource` returning a JSON document conforming to RFC 9728.

Minimum response shape:

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

The fallback to default endpoints (`/authorize`, `/token`, `/register`) that earlier MCP drafts allowed has been **removed**. Without the PRM endpoint, MCP-spec-compliant clients (including Claude's connector UI) will not be able to discover the authorization server, and the server will appear broken even if everything else is correct.

**Verification:** `curl https://<host>/.well-known/oauth-protected-resource` returns 200 with valid JSON. Add to the deployment smoke-test.

### 19.3 Resource Indicators (RFC 8707) on every token request

**Requirement:** MCP clients MUST include a `resource=` parameter on token requests, binding the issued token to the MCP server's resource URI. MCP servers MUST validate the `aud` claim matches their resource URI.

This prevents tokens issued for one MCP server from being replayed against another, and is the formal mechanism behind the "no token passthrough" rule (§3).

**Verification:** Decode an issued bearer token (jwt.io or `Get-MgContext | Select -ExpandProperty AuthType` for delegate flows); confirm `aud` matches `api://exchange-mcp` and not, e.g., the Graph audience.

### 19.4 PKCE is always required

**Requirement:** All MCP client flows MUST use Authorization Code with PKCE. This was implied by OAuth 2.1 in the rev 1 spec but is now explicit. Public clients (including loopback redirect on a local PowerShell host) cannot omit PKCE.

This is already the default in `Microsoft.Graph.Authentication` and in the Functions MCP extension; no code change required, but document the assertion.

### 19.5 Dynamic Client Registration (RFC 7591) — SHOULD, not MUST

The spec recommends Authorization Servers and MCP clients support DCR. **Entra does not currently support DCR.** This is acceptable per the spec ("SHOULD"). Our deployment uses static client registration via the Entra app reg.

**Action:** Document this gap explicitly. If a future Entra capability enables DCR, evaluate adoption then.

### 19.6 Practical impact on rev 1 designs

For the two Exchange Archive MCPs in this suite:

- **Local MCP, Phase 1–2 (stdio):** §19.2–§19.4 do not apply at the protocol level (stdio doesn't expose a `.well-known/` endpoint). PKCE is already the default in `Connect-MgGraph`.
- **Local MCP, Phase 3 (HTTPS):** All of §19 applies.
- **Foundry MCP, all phases:** All of §19 applies. The PRM endpoint is added in Phase 4 of the Foundry plan.

### 19.7 References for this appendix

- MCP Specification, 2025-06-18 revision: https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization
- RFC 9728 — OAuth 2.0 Protected Resource Metadata
- RFC 8707 — Resource Indicators for OAuth 2.0
- RFC 7591 — OAuth 2.0 Dynamic Client Registration
- Anthropic. *Building custom connectors via remote MCP servers* — Claude Help Center

---

## References

- Anthropic. *MCP Security Best Practices*. https://modelcontextprotocol.io/specification/draft/basic/security_best_practices
- Oligo Security. *CVE-2025-49596 — RCE in Anthropic MCP Inspector*. https://www.oligo.security/blog/critical-rce-vulnerability-in-anthropic-mcp-inspector-cve-2025-49596
- Trend Micro. *Why a Classic MCP Server Vulnerability Can Undermine Your Entire AI Agent*. https://www.trendmicro.com/en_ca/research/25/f/why-a-classic-mcp-server-vulnerability-can-undermine-your-entire-ai-agent.html
- Trend Micro. *MCP Security: Network-Exposed Servers Are Backdoors to Your Private Data*. https://www.trendmicro.com/vinfo/us/security/news/cybercrime-and-digital-threats/mcp-security-network-exposed-servers-are-backdoors-to-your-private-data
- Cato Networks. *CTRL+PoC: Attack Targeting Atlassian's MCP*. https://www.catonetworks.com/blog/cato-ctrl-poc-attack-targeting-atlassians-mcp/
- UpGuard. *Asana Discloses Data Exposure Bug in MCP Server*. https://www.upguard.com/blog/asana-discloses-data-exposure-bug-in-mcp-server
- Protect AI. *MCP Security 101*. https://protectai.com/blog/mcp-security-101
- OWASP. *Confused Deputy Problem / CSRF*. https://owasp.org/www-community/attacks/csrf
- Bobby Curtis / DBASolved. *Securing MCP Servers for Enterprise Use: Beyond HTTPS Protocol*. https://medium.com/dbasolved/securing-mcp-servers-for-enterprise-use-beyond-https-protocol-bdcd731e0801
- Wassim Chegham / Microsoft. *It's time to secure your MCP servers. Here's how.* https://techcommunity.microsoft.com/blog/azuredevcommunityblog/its-time-to-secure-your-mcp-servers-heres-how-/4434308
- Microsoft. *Azure-Samples/mcp-container-ts* (reference implementation). https://github.com/Azure-Samples/mcp-container-ts
