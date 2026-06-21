# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
