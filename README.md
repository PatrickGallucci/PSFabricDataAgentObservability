# FabricDataAgentObservability

[![CI](https://github.com/PatrickGallucci/PSFabricDataAgentObservability/actions/workflows/ci.yml/badge.svg)](https://github.com/PatrickGallucci/PSFabricDataAgentObservability/actions/workflows/ci.yml)
[![Docs](https://github.com/PatrickGallucci/PSFabricDataAgentObservability/actions/workflows/docs.yml/badge.svg)](https://patrickgallucci.github.io/PSFabricDataAgentObservability/)
[![PowerShell Gallery](https://img.shields.io/powershellgallery/v/FabricDataAgentObservability.svg)](https://www.powershellgallery.com/packages/FabricDataAgentObservability)
[![Downloads](https://img.shields.io/powershellgallery/dt/FabricDataAgentObservability.svg)](https://www.powershellgallery.com/packages/FabricDataAgentObservability)
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

## Install

```powershell
Install-Module FabricDataAgentObservability -Scope CurrentUser
```

Or import from source:

```powershell
Import-Module ./FabricDataAgentObservability.psd1
```

## Quick start

```powershell
# 1. Connect — pick the auth method that fits your runner.
Connect-FDAObservability -AuthMethod UserDelegated `
    -TenantId     '<tenant-guid>' `
    -WorkspaceId  '<workspace-guid>' `
    -EventhouseId '<eventhouse-guid>'

# 2. One-time provisioning (tables, mappings, policies, functions, seed levels).
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
Test-ModuleManifest ./FabricDataAgentObservability.psd1
```

## Documentation set

- [`docs/README.md`](docs/README.md) — overview, quick start, cmdlet index
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — architecture, design choices, trade-offs
- [`docs/SCHEMA.md`](docs/SCHEMA.md) — Eventhouse table reference
- [`docs/OPERATIONS.md`](docs/OPERATIONS.md) — runbook, dashboards, retention, alerts
- [`CHANGELOG.md`](CHANGELOG.md) — release notes

## License

[MIT](LICENSE) © Patrick Gallucci
