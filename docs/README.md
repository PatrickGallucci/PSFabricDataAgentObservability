# PSFabricDataAgentObservability

Production-grade observability for Fabric Data Agent (FDA) NL-to-DAX interactions, backed by a Fabric Eventhouse (KQL) database.

Captures the full interaction trail — **question → reasoning → grounding → generated DAX → answer**, plus user, timestamp, latency, tokens, downstream execution telemetry, governance events, and cost/usage — into a queryable, retention-managed sink. Built around the only first-party path that links the natural-language question to the generated DAX in a single call: the FDA published-endpoint response. The module proxies that call, records the entire payload (with optional PII redaction), and correlates it with Workspace Monitoring DAX traces and M365 Unified Audit governance events.

## What it captures

| Surface | Source | Table |
|---|---|---|
| Question, reasoning, generated DAX, answer, user, latency, tokens | FDA published endpoint response (via `Invoke-FDAQuery` proxy) | `FDAInteractions` |
| Executed DAX, duration, rows, cache hit, errors | Workspace Monitoring export (recommended) or XMLA fallback | `FDAExecutions` |
| Auth, consent, RLS context, tenant/app/IP | M365 Unified Audit Log via `Sync-FDAGovernanceLog` | `FDAAuthEvents` |
| Per-call tokens, estimated CU & USD | Derived from FDA usage payload + configurable rate table | `FDACostMetering` |
| Free-form structured events at any level | `Write-FDALog` (built-in + custom levels) | `FDALogEvents` |
| Registered log levels (history) | `Register-FDALogLevel` / `Unregister-FDALogLevel` | `FDALogLevels` |
| Runtime configuration (versioned) | `Set-FDAObservabilityConfig` | `FDAConfiguration` |

## Requirements

- PowerShell 7.2+ (Windows / Linux / macOS)
- A Fabric workspace with permission to create an Eventhouse (or an existing one to point at)
- Permission to enable Workspace Monitoring on the semantic model (for executed-DAX correlation)
- For governance sync: an app registration with `ActivityFeed.Read` on `manage.office.com`
- Either a Service Principal, a Managed Identity, or an interactive user that can hit FDA + Eventhouse
- For **UserDelegated** (browser) sign-in: a public client app present in your tenant — see the prerequisite below

## Prerequisite — one-time, tenant admin (recommended)

Browser sign-in (`-AuthMethod UserDelegated`) uses a public client app that must exist in your tenant. The least-friction option is to have a **tenant admin** instantiate the Azure CLI well-known app once:

```powershell
Connect-MgGraph -Scopes "Application.ReadWrite.All"
New-MgServicePrincipal -AppId "04b07795-8ddb-461a-bbee-02f9e1bf7b46"   # Azure CLI
```

Once that service principal exists, `Connect-FDAObservability` works with `config.json` `ClientId` left `null`.

!!! tip "Why this is easiest"
    The Azure CLI app already carries broad pre-consented delegated permissions (Fabric/Power BI, ARM, Kusto), so there's nothing else to configure.

!!! note "No admin access?"
    Register your own public-client app (Authentication → **Allow public client flows = Yes**, redirect URI `http://localhost`), grant it the delegated permissions above, and put its app id in `config.json` `ClientId` (or pass `-ClientId`). The symptom of a missing/unprovisioned app is **`AADSTS700016`** at sign-in.

## Quick start

```powershell
Import-Module ./PSFabricDataAgentObservability.psd1

# 1. Sign in. UserDelegated uses the browser (auth-code + PKCE): a window opens,
#    you sign in, the tenant is discovered from the token and returned. No
#    tenant prompt, no code to paste.
$TenantId = Connect-FDAObservability -AuthMethod UserDelegated

# 2. One-time provisioning. The Workspace / Eventhouse / Database default to
#    config.json (WorkspaceName 'FUAM PUB', EventhouseName 'FDAObservability',
#    DatabaseName 'FDAObs') and are CREATED if they don't already exist.
Initialize-FDAObservability -TenantId $TenantId

#    …or override any of the names (still create-if-missing):
Initialize-FDAObservability -TenantId $TenantId `
    -WorkspaceName 'My WS' -EventhouseName 'FDAObservabilityProd' -DatabaseName 'FDAObs'

#    …or target existing ids explicitly:
Initialize-FDAObservability -WorkspaceId '<workspace-guid>' -EventhouseId '<eventhouse-guid>'

# 3. Replace direct FDA calls with the proxy.
$answer = Invoke-FDAQuery -AgentEndpoint 'https://<fda-endpoint>' `
                          -Question 'Revenue by region last quarter?'
```

The defaults live in **config.json** in the module root and are read at runtime:

```json
{
    "WorkspaceName": "FUAM PUB",
    "EventhouseName": "FDAObservability",
    "DatabaseName": "FDAObs",
    "ClientId": null
}
```

`ClientId` is the public client used for browser sign-in; `null` means the Azure CLI well-known app. If that app isn't provisioned in your tenant (you'll see `AADSTS700016`), set it to an app you've registered there with **Allow public client flows = Yes** and an `http://localhost` redirect URI.

## Auth — caller picks

```powershell
# Service Principal (server / scheduled jobs)
Connect-FDAObservability -AuthMethod ServicePrincipal `
    -TenantId $tid -ClientId $cid -ClientSecret $sec `
    -WorkspaceId $ws -EventhouseId $eh

# Managed Identity (Function App, VM, Automation Account, Arc)
Connect-FDAObservability -AuthMethod ManagedIdentity `
    -WorkspaceId $ws -EventhouseId $eh

# User-delegated (browser auth-code + PKCE) — returns the discovered TenantId
$TenantId = Connect-FDAObservability -AuthMethod UserDelegated
```

Tokens are cached and refreshed transparently. Cert-based SP auth is supported via `-Certificate`. For **UserDelegated**, the browser auth-code + PKCE flow requests `offline_access`, so a **single interactive sign-in covers every scope** (Fabric, Kusto, ARM, Power BI) — the cached refresh token is redeemed silently for each new resource instead of prompting again. The tenant is read from the returned token, so you don't supply it up front.

## Logging levels — built-in + dynamic custom

| Built-in | Numeric | Use for |
|---|---|---|
| `Verbose` | 10 | Raw payloads, full reasoning traces |
| `Information` | 30 | Default operational level |
| `Warning` | 50 | Degraded responses, retries, slow queries |
| `Error` | 70 | Failed FDA calls, downstream DAX errors |
| `Critical` | 90 | Auth failures, data exposure, ingest loss |

Add your own at any numeric weight:

```powershell
Register-FDALogLevel -Name 'Audit'    -Numeric 60 -Category 'Compliance'
Register-FDALogLevel -Name 'Trace'    -Numeric 5  -Category 'Diagnostics'
Register-FDALogLevel -Name 'Forensic' -Numeric 95 -Category 'Security'

Write-FDALog -Level 'Audit' -Message 'PII export approved' `
             -Category 'Compliance' -Properties @{ ConsentClaim = 'CC-1234' }

# Filter at query time.
Search-FDALog -Table FDALogEvents -MinLevel 'Audit' -Last 1d
```

Per-category thresholds:

```powershell
Set-FDAObservabilityConfig -Category 'Diagnostics' -MinLevel 'Warning'
Set-FDAObservabilityConfig -Category 'Cost'        -MinLevel 'Verbose'
```

## Cmdlet index

### Setup
- `Initialize-FDAObservability` — provision tables, mappings, policies, functions, seed levels (select or create the workspace/Eventhouse interactively when ids are omitted)
- `Connect-FDAObservability` — install token providers, resolve tenant/workspace/Eventhouse (interactively when ids are omitted)
- `Disconnect-FDAObservability` — flush, stop timer, clear state
- `Set-FDAObservabilityConfig` / `Get-FDAObservabilityConfig` — versioned runtime config

### Levels
- `Register-FDALogLevel` / `Unregister-FDALogLevel` / `Get-FDALogLevel`

### Capture
- `Invoke-FDAQuery` ★ — proxy wrapper around the FDA endpoint
- `Write-FDALog` — manual structured event
- `Sync-FDAGovernanceLog` — pull M365 Unified Audit Fabric/Power BI events

### Read
- `Search-FDALog` — structured filter or raw KQL
- `Get-FDAInteraction` / `Get-FDAExecutionTelemetry` / `Get-FDAAuthEvent` / `Get-FDACostUsage`
- `New-FDAObservabilityReport` — `DailyOps | FailureSummary | TopUsers | Slowest | CostByUser`

### Health
- `Test-FDAObservability` — end-to-end health check

## Operating principles

- **Batched async ingest** (default 5 s / 100 events) keeps `Invoke-FDAQuery` latency-neutral.
- **Critical** events flush synchronously so you never lose them on a crash.
- **Disk spool** at `~/.fda-observability/spool/` if the Eventhouse is unreachable, drained on next connect.
- **PII redaction** is on by default. `Invoke-FDAQuery -PreservePII -ConsentClaim '<id>'` is the only way to bypass; the consent claim is logged with the record.
- **Schema drift** is graceful by default. `Set-FDAObservabilityConfig -StrictSchema $true` flips to hard-fail.

## Out of scope (and the correlation pattern instead)

The FDA service does **not** expose a third-party hook to intercept its NL-to-DAX generation for callers that do not go through this module — e.g. M365 Copilot. For those, we capture the executed DAX from **Workspace Monitoring** and the auth/governance context from **M365 Unified Audit**, and correlate them by ActivityID and timestamp. The natural-language question itself is not available outside the proxy path. This is documented in `OPERATIONS.md`.

## See also

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — full architecture, design choices, trade-offs
- [`SCHEMA.md`](SCHEMA.md) — table reference
- [`OPERATIONS.md`](OPERATIONS.md) — runbook, dashboards, retention, alerts
- [Changelog](changelog.md)
