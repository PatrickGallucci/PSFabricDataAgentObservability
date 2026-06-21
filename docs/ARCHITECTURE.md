# Architecture

## Why a proxy

The platform exposes several places where pieces of an FDA interaction live, but only the **published-endpoint response** ties the natural-language question, the reasoning steps, the grounding citations, and the generated DAX together in a single call.

| Source | What it shows | What it misses |
|---|---|---|
| FDA published endpoint response (the proxy path) | Question + reasoning + grounding + generated DAX + answer + tokens | Nothing — full provenance, but only for calls that go through the proxy |
| Workspace Monitoring on the semantic model | Executed DAX, duration, rows, cache hit, errors, user | NL question, reasoning, grounding |
| Power BI Log Analytics | Same DAX-execution surface as Workspace Monitoring | Same gaps |
| Admin Monitoring page | Aggregate counters and per-call breakdowns (UI only) | No bulk export of raw DAX |
| Purview / M365 Unified Audit | Who/when/from-where/with-what-app, consent, RLS context | DAX text only in summary form |

The proxy is the only place to get full fidelity. Workspace Monitoring + Purview provide independent corroboration of the executed-DAX and governance dimensions, and we ingest them alongside.

## Module shape

```
caller (app / notebook / scheduled job)
   │
   ▼
PowerShell module PSFabricDataAgentObservability
   │   Invoke-FDAQuery   ← proxy: wrap, time, parse, redact, persist
   │   Write-FDALog      ← manual structured event
   │   Sync-...          ← Purview / M365 audit pull
   │   Search-/Get-...   ← typed reads
   │
   ▼   batched async (5s / 100 events) + Critical sync + disk spool
Fabric Eventhouse (KQL DB: FDAObs)
   │   *Raw landing tables → update policies → curated typed tables
   │   FDALogLevels (versioned)            ← Register-FDALogLevel
   │   FDAConfiguration (versioned)        ← Set-FDAObservabilityConfig
```

## Auth abstraction

`Connect-FDAObservability -AuthMethod <SP|MI|User>` installs a token-provider closure into module-scope state. Every downstream tool resolves tokens through `Get-FDAAccessToken -Scope <scope>`; the provider is responsible for fetching, the helper for caching (refresh 60 s before expiry).

Scopes used:

| Scope | Purpose |
|---|---|
| `https://api.fabric.microsoft.com/.default` | Fabric REST + FDA endpoint |
| `https://kusto.fabric.microsoft.com/.default` | Eventhouse query + ingest |
| `https://manage.office.com/.default` | M365 Unified Audit (governance sync) |

Provider implementations:
- **ServicePrincipal:** v2.0 token endpoint with client secret OR JWT client assertion (cert-based)
- **ManagedIdentity:** IMDS for IaaS; `IDENTITY_ENDPOINT`/`IDENTITY_HEADER` for App Service / Functions / Arc
- **UserDelegated:** Device-code flow against the well-known Power BI public client (override `-ClientId` for your own AAD app)

## Data flow — interaction capture

1. Caller invokes `Invoke-FDAQuery -AgentEndpoint <uri> -Question <text>`.
2. The module mints a `CorrelationId` (and reuses or generates an `InteractionId`).
3. The FDA endpoint is called with a stopwatch around it.
4. The response is parsed against the expected v1 contract:
   - `answer`, `steps[]`, `grounding[]`, `generatedQuery`, `usage{prompt_tokens,completion_tokens,total_tokens}`.
   - Each missing field is added to `PartialCaptureNotes`. With `StrictSchema=false` (default) the record is tagged `PartialCapture` and a `Warning` event is emitted. With `StrictSchema=true` the call hard-fails.
5. Redaction (default): question / grounding / answer text are scrubbed against the configurable regex set. `Invoke-FDAQuery -PreservePII -ConsentClaim '<id>'` bypasses redaction; the consent claim is persisted alongside the raw text so audit can reconstruct who authorized it.
6. The interaction is appended to the in-memory flush buffer with the resolved level. **Critical** flushes synchronously. The background timer drains the rest.
7. A cost-metering record is appended in parallel using the configured rate table (`CapacityRates.TokensPerCU`, `CapacityRates.USDPerCU`).

## Raw → curated

All capture goes through `*Raw` landing tables (single `Payload:dynamic` column + `IngestTime`) with streaming ingestion enabled. **Update policies** reshape into the curated `FDA*` tables on commit — typed columns, lossless. This keeps:

- Sub-second freshness in the curated tables
- A tamper-evident landing zone you can re-process if the schema evolves
- Cheap schema migration: add a new column to a curated table and the next deployment of the `ExpandFDA*Raw()` function backfills it on subsequent rows

## Dynamic log levels

Built-in levels: `Verbose=10, Information=30, Warning=50, Error=70, Critical=90`.

`Register-FDALogLevel -Name 'Audit' -Numeric 60 -Category 'Compliance'` writes a new versioned row to `FDALogLevels`. `Resolve-LogLevel` merges built-ins with the latest active rows (custom wins on duplicate name). Filtering honors:

- the global threshold (`MinLevelName`)
- per-category overrides (`MinLevelByCategory.<Category>`)
- query-side comparison via `LevelNumeric`

Numeric values that fall between bands resolve to a synthetic `Custom_<n>` level so non-band-aligned weights still log.

## Resilience

- **Retries** on ingest and KQL query with exponential backoff (3 attempts; 1 s → 30 s).
- **Disk spool** at `~/.fda-observability/spool/` when the Eventhouse is unreachable. `Connect-FDAObservability` calls `Restore-FDASpool` to drain on reconnect.
- **Background flush** runs every 5 s by default; tunable via `Set-FDAObservabilityConfig -BatchFlushSeconds <n>`.
- **`Disconnect-FDAObservability`** flushes synchronously, stops the timer, and disposes the lock.

## Trust boundary

- Tokens are stored only in module memory and never persisted to disk.
- The spool contains the records you were about to ingest — if it includes PII (because the caller used `-PreservePII`), the file inherits the OS-user profile permissions. Operate the spool path under user-only ACLs in regulated tenants.
- Min-level enforcement is client-side. A caller that bypasses this module (e.g., calls the FDA endpoint directly) is invisible to it. Use Workspace Monitoring + Purview for an out-of-band view.

## Performance shape

A typical `Invoke-FDAQuery` adds:

- One HTTP call to FDA (the unavoidable cost)
- One token cache lookup (memory)
- Async append to the in-memory ring buffer
- Background-timer batched ingest (one HTTP call per ≤100 events per 5 s)

The proxy overhead on the hot path is sub-millisecond. The visible latency is the FDA call itself.

## Out of scope

| Out | Why |
|---|---|
| Intercepting NL question text for M365 Copilot-originated FDA calls | No public hook; only the proxy path sees the question. Doc the correlation by Workspace Monitoring + Purview. |
| Service-side enforcement of log levels | The module gates at the client. Bypass-resistant logging requires the service-tier hook FDA does not yet expose. |
| True Premium capacity-unit metering | The public API does not expose per-call CU consumption. We compute estimates from the rate table. |
