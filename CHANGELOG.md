# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-06-21

### Added

- **Interactive connect & provisioning.** `Connect-FDAObservability` no longer requires `-TenantId`, `-WorkspaceId`, or `-EventhouseId`. When omitted (UserDelegated), you sign in with the device-code flow, the module enumerates the tenants you can access — prompting only when there is more than one (falling back to the token's tenant claim if Azure Resource Manager is unreachable) — then lists Fabric workspaces and Eventhouses so you can select an existing one or create a new one from a menu.
- `Initialize-FDAObservability` likewise makes `-WorkspaceId` and `-EventhouseId` optional; omit them to select or create the target workspace and Eventhouse interactively before provisioning. The explicit `-EventhouseId` and `-CreateEventhouse -EventhouseName` paths are unchanged.
- New internal Fabric REST helpers: `Get-FDAWorkspaceList`, `Get-FDAEventhouseList`, `New-FDAWorkspace` (paged via `continuationUri`), plus the interactive resolvers `Resolve-FDATenant`, `Resolve-FDAWorkspace`, and `Resolve-FDAEventhouse`.

### Changed

- The UserDelegated token provider now resolves its authority at call time (`organizations` until a tenant is selected, then the chosen tenant), so sign-in can complete before the tenant is known.

> **Compatibility:** fully backward compatible — existing scripts that pass `-TenantId`/`-WorkspaceId`/`-EventhouseId` behave exactly as before. ServicePrincipal still requires `-TenantId`; ManagedIdentity still takes it from IMDS.

## [1.0.1] - 2026-06-21

### Changed

- **Renamed the module from `FabricDataAgentObservability` to `PSFabricDataAgentObservability`** so the module, repository, and PowerShell Gallery package names all match. Renamed `FabricDataAgentObservability.psd1`/`.psm1` accordingly and assigned a new module GUID for the new package identity.
- Updated the module manifest, manifest version, `x-ms-client-version` ingest header, install/import instructions, CI/publish workflows, MkDocs site name, README badges, and tests to the new name. No functional/behavioural changes from 1.0.0.

> **Migration:** the previous `FabricDataAgentObservability` 1.0.0 package on the PowerShell Gallery is superseded by `PSFabricDataAgentObservability`. Switch with `Install-Module PSFabricDataAgentObservability`.

## [1.0.0] - 2026-06-21

### Added

- `Invoke-FDAQuery` proxy capture for FDA published endpoints (question, reasoning, grounding, generated DAX, answer, user, latency, tokens).
- Fabric Eventhouse sink — raw landing + typed curated tables via update policies; streaming ingestion; configurable retention; caching policy on hot range.
- Auth abstraction supporting Service Principal (secret + cert), Managed Identity (IMDS + IDENTITY_ENDPOINT), and user-delegated device-code flow.
- Built-in log levels (`Verbose`, `Information`, `Warning`, `Error`, `Critical`) plus dynamic user-defined custom levels via `Register-FDALogLevel`, with per-category min-level overrides.
- PII redaction by default with `-PreservePII` opt-in gated by `-ConsentClaim`.
- Configurable schema-drift policy: graceful (default) or strict.
- Cost / usage metering with configurable rate table.
- `Sync-FDAGovernanceLog` for M365 Unified Audit ingest into `FDAAuthEvents`.
- `Get-FDAAuthEvent` query cmdlet for governance / authentication events (by id, or filtered by correlation, user, outcome, source, and time window).
- Canned reports: `DailyOps | FailureSummary | TopUsers | Slowest | CostByUser`.
- `Test-FDAObservability` end-to-end health check.
- Disk spool fallback + exponential-backoff retry on ingest and query.
- Pester smoke tests for offline-safe units (level resolution, redaction, cost, KQL splitter, record shape) plus parameter-contract coverage for public cmdlets.
- `PSScriptAnalyzerSettings.psd1`, MkDocs (Material) documentation site, and GitHub Actions workflows for CI (Pester + ScriptAnalyzer) and GitHub Pages.

### Fixed

- Implemented the previously-exported-but-missing `Get-FDAAuthEvent` function so the manifest export surface matches the shipped code.
- Corrected a null-comparison (`$null` on the left) in `Write-FDALog` per PowerShell best practice.
- Replaced silent empty `catch` blocks with verbose diagnostics in best-effort cleanup paths.
