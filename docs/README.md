# FabricDataAgentObservability

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

## Quick start

```powershell
Import-Module ./FabricDataAgentObservability.psd1

# 1. Connect — pick the auth method that fits your runner.
Connect-FDAObservability -AuthMethod UserDelegated `
    -TenantId        '<tenant-guid>' `
    -WorkspaceId     '<workspace-guid>' `
    -EventhouseId    '<eventhouse-guid>'

# 2. One-time provisioning (or run examples/01-setup-eventhouse.ps1).
Initialize-FDAObservability -WorkspaceId '<workspace-guid>' `
                            -EventhouseId '<eventhouse-guid>'

# 3. Replace direct FDA calls with the proxy.
$answer = Invoke-FDAQuery -AgentEndpoint 'https://<fda-endpoint>' `
                          -Question 'Revenue by region last quarter?'
```

To provision the Eventhouse itself in one call:

```powershell
Initialize-FDAObservability -WorkspaceId '<ws>' -CreateEventhouse -EventhouseName 'FDAObservability'
```

## Auth — caller picks

```powershell
# Service Principal (server / scheduled jobs)
Connect-FDAObservability -AuthMethod ServicePrincipal `
    -TenantId $tid -ClientId $cid -ClientSecret $sec `
    -WorkspaceId $ws -EventhouseId $eh

# Managed Identity (Function App, VM, Automation Account, Arc)
Connect-FDAObservability -AuthMethod ManagedIdentity `
    -WorkspaceId $ws -EventhouseId $eh

# User-delegated (device code flow)
Connect-FDAObservability -AuthMethod UserDelegated `
    -TenantId $tid -WorkspaceId $ws -EventhouseId $eh
```

Tokens are cached and refreshed transparently. Cert-based SP auth is supported via `-Certificate`.

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
- `Initialize-FDAObservability` — provision tables, mappings, policies, functions, seed levels
- `Connect-FDAObservability` — install token providers, resolve Eventhouse endpoints
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
