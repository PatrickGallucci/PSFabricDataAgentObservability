# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.3.0] - 2026-06-22

### Changed

- **UserDelegated now uses the browser-based authorization-code + PKCE flow** instead of device code. `Connect-FDAObservability -AuthMethod UserDelegated` opens the default browser, captures the redirect on an ephemeral `http://localhost:<port>` listener (no code to paste), and exchanges the code with a PKCE verifier. It signs in against the tenant-less `organizations` authority when no `-TenantId` is supplied, **discovers the tenant from the returned token**, and **returns the `TenantId`** — enabling the workflow `$TenantId = Connect-FDAObservability; Initialize-FDAObservability -TenantId $TenantId`. The `Connect-FDAObservability` return value is the tenant id string decorated with the usual status properties (`.Connected`, `.ClusterUri`, …).
- **Connect no longer resolves Workspace/Eventhouse unless both ids are passed.** A bare UserDelegated connect is now a pure auth bootstrap; resource resolution moves to `Initialize-FDAObservability`.
- The default public client id for browser sign-in is the Azure CLI well-known app (was the Power BI app), overridable via `config.json` `ClientId`.

### Added

- **Config-driven setup.** A `config.json` in the module root supplies the bootstrap defaults `WorkspaceName` (`FUAM PUB`), `EventhouseName` (`FDAObservability`), `DatabaseName` (`FDAObs`), and `ClientId` (null → Azure CLI). Read at runtime via the new private `Get-FDAModuleConfig`, with built-in fallbacks when the file or a key is absent.
- **`Initialize-FDAObservability` resolves Workspace/Eventhouse/Database by name and creates anything missing.** New `-TenantId`, `-WorkspaceName`, and `-EventhouseName` parameters (names default from `config.json`); `-DatabaseName` now also defaults from config. New private helpers `Resolve-FDAWorkspaceByName` and `Resolve-FDAEventhouseByName` (`-CreateIfMissing`). Explicit `-WorkspaceId`/`-EventhouseId`/`-CreateEventhouse` still work.
- **Fabric capacity handling for created workspaces.** An Eventhouse cannot be created in a workspace without a Fabric capacity (Fabric returns `FeatureNotAvailable`). A workspace that is created — or matched but found capacity-less — is now placed on a capacity: `-CapacityName`/`-CapacityId` (default `config.json` `CapacityName`), auto-selecting the single visible capacity or erroring with the list when ambiguous. New private helpers `Get-FDACapacityList`, `Resolve-FDACapacity`, and `Set-FDAWorkspaceCapacity`; `New-FDAWorkspace` gained `-CapacityId`. The admin prerequisite (instantiating the Azure CLI public client) is now documented in the README/Operations runbook and `examples/01-setup-eventhouse.ps1`.
- Tests for the browser auth-code flow (mocked listener), tenant discovery from the id_token, `Get-FDAModuleConfig`, the name-based resolvers, and the config-driven `Initialize` path.

### Fixed

- **`examples/01-setup-eventhouse.ps1` dropped `-ClientId` for UserDelegated** (it was only forwarded for ServicePrincipal), so the well-known-app override never took effect and sign-in always used the default client. The script was rewritten around the new `Connect` → `Initialize -TenantId` flow and forwards overrides correctly.

## [1.2.1] - 2026-06-22

### Fixed

- **Fatal `The term 'Get-FDAUserDelegatedToken' is not recognized` on interactive connect.** The token providers were installed with `.GetNewClosure()`, which rebinds a scriptblock to a new dynamic module and severs access to the defining module's private functions. Providers are now plain, module-affiliated scriptblocks that read per-connection auth config (client id, secret, certificate, MI client id) from module state, so they resolve `Get-FDAUserDelegatedToken` / `Get-FDAServicePrincipalToken` / `Get-FDAManagedIdentityToken` / `New-FDAClientAssertion` correctly. This also fixes the same latent break in the **certificate-based Service Principal** path.
- **Certificate-based Service Principal auth could not sign.** `New-FDAClientAssertion` called `$Certificate.GetRSAPrivateKey()`, but that is a C# extension method PowerShell does not expose as an instance method (it threw "method not found"). It now calls the static `RSACertificateExtensions::GetRSAPrivateKey` form.
- **`Set-StrictMode -Version Latest` crashes on several edge cases** surfaced by the new test suite:
  - `Invoke-KQLQuery` threw on single-column results (e.g. `… | count`) because `$cols.Count` was read on a scalar — now array-coerced.
  - `Invoke-KQLQuery` / `Invoke-EventhouseIngest` threw inside their retry handlers when the error was not an HTTP response error (e.g. a `WebException` with a null `Response`). Status-code extraction is now centralized in a guarded `Get-FDAHttpStatusCode` helper.
  - `Test-FDAObservability` reported a false **Warning** for the Schema check when *no* tables were missing (`$missing.Count` on `$null`), and could throw on the spool check with a single spooled file — both array-coerced.
  - `New-FDAReportMarkdown` rejected an empty result set (`[Parameter(Mandatory)] [object[]]`), so writing a Markdown report over an empty window failed — now `[AllowEmptyCollection()]`.

### Added

- Comprehensive Pester suite: **113 tests, ~89% command coverage** (up from ~27%), covering every token provider, the cache/dispatch layer, interactive resolvers, the KQL/ingest primitives, the flush buffer/spool, all read cmdlets, config/levels, `Invoke-FDAQuery`, reports, the health check, and governance sync. Includes a regression test that connects and resolves a token end-to-end through an installed provider (the exact path that failed).

## [1.2.0] - 2026-06-22

### Added

- **Single interactive sign-in covers every scope.** The UserDelegated device-code flow now requests `offline_access` and caches the returned refresh token in module state. Subsequent scopes (Kusto, ARM, Power BI, M365 audit) are obtained silently via the refresh-token grant instead of prompting for a new device code each time. The refresh token rotates on each use and is cleared by `Disconnect-FDAObservability`. Token acquisition is factored into a new private `Get-FDAUserDelegatedToken` helper.

### Changed

- `Connect-FDAObservability` resets any prior refresh token at the start of a new UserDelegated connection.

## [1.1.1] - 2026-06-22

### Fixed

- **Interactive UserDelegated sign-in failed with `AADSTS50059` ("No tenant-identifying information found").** The raw v2.0 device-code endpoint rejects the tenant-less `organizations`/`common` authorities, so the 1.1.0 "discover the tenant after sign-in" approach could never bootstrap. When `-TenantId` is omitted for UserDelegated you are now prompted for a tenant ID (GUID) or verified domain (e.g. `contoso.onmicrosoft.com`) — both valid sign-in authorities — before the device-code flow starts. The token provider now raises a clear error instead of falling back to the unusable `organizations` authority.
- `examples/01-setup-eventhouse.ps1` no longer forwards an empty `-TenantId` (e.g. from an unset `$ENV:AZURE_TENANT_ID`) into the auth flow; `TenantId` is optional and only passed when supplied.

### Changed

- Removed the pre-sign-in Azure Resource Manager tenant enumeration (incompatible with the raw device-code flow). Multi-tenant users specify the target tenant at the prompt (or via `-TenantId`).

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
