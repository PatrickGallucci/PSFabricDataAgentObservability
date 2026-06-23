# PSFabricDataAgentObservability

[![CI](https://github.com/PatrickGallucci/PSFabricDataAgentObservability/actions/workflows/ci.yml/badge.svg)](https://github.com/PatrickGallucci/PSFabricDataAgentObservability/actions/workflows/ci.yml)
[![Docs](https://github.com/PatrickGallucci/PSFabricDataAgentObservability/actions/workflows/docs.yml/badge.svg)](https://patrickgallucci.github.io/PSFabricDataAgentObservability/)
[![Publish](https://github.com/PatrickGallucci/PSFabricDataAgentObservability/actions/workflows/publish.yml/badge.svg)](https://github.com/PatrickGallucci/PSFabricDataAgentObservability/actions/workflows/publish.yml)
[![PowerShell Gallery](https://img.shields.io/powershellgallery/v/PSFabricDataAgentObservability?logo=powershell&logoColor=white&label=PSGallery)](https://www.powershellgallery.com/packages/PSFabricDataAgentObservability)
[![Downloads](https://img.shields.io/powershellgallery/dt/PSFabricDataAgentObservability?color=blue&label=downloads)](https://www.powershellgallery.com/packages/PSFabricDataAgentObservability)
[![Platforms](https://img.shields.io/powershellgallery/p/PSFabricDataAgentObservability?color=informational)](https://www.powershellgallery.com/packages/PSFabricDataAgentObservability)
[![PowerShell 7.2+](https://img.shields.io/badge/PowerShell-7.2%2B-5391FE?logo=powershell&logoColor=white)](https://learn.microsoft.com/powershell/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Production-grade observability for **Fabric Data Agent (FDA)** NL-to-DAX interactions, backed by a Fabric Eventhouse (KQL) database.

It captures the full interaction trail — **question → reasoning → grounding → generated DAX → answer** — plus user, latency, tokens, downstream execution telemetry, governance events, and cost/usage, into a queryable, retention-managed sink. The module proxies the FDA published-endpoint call (the only first-party path that links the natural-language question to the generated DAX in one call), records the entire payload with optional PII redaction, and correlates it with Workspace Monitoring DAX traces and M365 Unified Audit governance events.

📖 **Full documentation:** <https://patrickgallucci.github.io/PSFabricDataAgentObservability/>

## Requirements

- PowerShell 7.2+ (Windows / Linux / macOS)
- A Fabric workspace with permission to create or point at an Eventhouse
- Permission to enable Workspace Monitoring on the semantic model (for executed-DAX correlation)
- For governance sync: an app registration with `ActivityFeed.Read` on `manage.office.com`
- A Service Principal, Managed Identity, or interactive user that can reach FDA + Eventhouse
- For **UserDelegated** (browser) sign-in: a public client app present in your tenant — see the one-time admin prerequisite below

## Prerequisite — one-time, tenant admin (recommended)

Browser sign-in (`-AuthMethod UserDelegated`) uses a public client app that must exist in your tenant. The least-friction option is to have a **tenant admin** instantiate the Azure CLI well-known app once:

```powershell
Connect-MgGraph -Scopes "Application.ReadWrite.All"
New-MgServicePrincipal -AppId "04b07795-8ddb-461a-bbee-02f9e1bf7b46"   # Azure CLI
```

Once that service principal exists, `Connect-FDAObservability` works with `config.json` `ClientId` left `null`. **Why this is easiest:** the Azure CLI app already carries broad pre-consented delegated permissions (Fabric/Power BI, ARM, Kusto), so there's nothing else to configure.

No admin access? Register your own public-client app (Authentication → **Allow public client flows = Yes**, redirect URI `http://localhost`), grant it the delegated permissions above, and put its app id in `config.json` `ClientId` (or pass `-ClientId`). The symptom of a missing/unprovisioned app is **`AADSTS700016`** at sign-in.

## Install

```powershell
Install-Module PSFabricDataAgentObservability -Scope CurrentUser
```

Or import from source:

```powershell
Import-Module ./PSFabricDataAgentObservability.psd1
```

## Quick start

```powershell
# 1. Sign in. UserDelegated uses the browser (auth-code + PKCE): a window opens,
#    you sign in, the tenant is discovered from the token and returned — no
#    tenant prompt, no code to paste. (See the admin prerequisite above.)
$TenantId = Connect-FDAObservability -AuthMethod UserDelegated

# 2. One-time provisioning (tables, mappings, policies, functions, seed levels).
#    The Workspace / Eventhouse / Database default to config.json
#    (WorkspaceName 'FUAM PUB', EventhouseName 'FDAObservability',
#    DatabaseName 'FDAObs') and are CREATED if they don't already exist.
Initialize-FDAObservability -TenantId $TenantId

#    …or override any of the names (still create-if-missing):
Initialize-FDAObservability -TenantId $TenantId `
    -WorkspaceName 'My WS' -EventhouseName 'FDAObservabilityProd'

#    …or target an existing workspace/Eventhouse explicitly:
Initialize-FDAObservability -WorkspaceId '<workspace-guid>' -EventhouseId '<eventhouse-guid>'

# 3. Replace direct FDA calls with the proxy.
$answer = Invoke-FDAQuery -AgentEndpoint 'https://<fda-endpoint>' `
                          -Question 'Revenue by region last quarter?'

# 4. Query what was captured.
Get-FDAInteraction -Last 24h -Top 20
Get-FDAAuthEvent   -Last 7d -Outcome Failure
New-FDAObservabilityReport -Report DailyOps
```

## Cmdlets

| Area | Cmdlets |
|---|---|
| Setup | `Initialize-FDAObservability`, `Connect-FDAObservability`, `Disconnect-FDAObservability`, `Set-FDAObservabilityConfig`, `Get-FDAObservabilityConfig` |
| Levels | `Register-FDALogLevel`, `Unregister-FDALogLevel`, `Get-FDALogLevel` |
| Capture | `Invoke-FDAQuery`, `Write-FDALog`, `Sync-FDAGovernanceLog` |
| Read | `Search-FDALog`, `Get-FDAInteraction`, `Get-FDAExecutionTelemetry`, `Get-FDAAuthEvent`, `Get-FDACostUsage`, `New-FDAObservabilityReport` |
| Health | `Test-FDAObservability` |

See the [cmdlet index](docs/README.md#cmdlet-index) for details.

## Develop & test

```powershell
Invoke-Pester -Path ./tests
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
Test-ModuleManifest ./PSFabricDataAgentObservability.psd1
```

## Documentation set

- [`docs/README.md`](docs/README.md) — overview, quick start, cmdlet index
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — architecture, design choices, trade-offs
- [`docs/SCHEMA.md`](docs/SCHEMA.md) — Eventhouse table reference
- [`docs/OPERATIONS.md`](docs/OPERATIONS.md) — runbook, dashboards, retention, alerts
- [`CHANGELOG.md`](CHANGELOG.md) — release notes

## License

[MIT](LICENSE) © Patrick Gallucci
