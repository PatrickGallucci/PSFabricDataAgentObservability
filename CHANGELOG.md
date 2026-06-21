# Changelog

## 1.0.0 — Initial release

- `Invoke-FDAQuery` proxy capture for FDA published endpoints (question, reasoning, grounding, generated DAX, answer, user, latency, tokens).
- Fabric Eventhouse sink — raw landing + typed curated tables via update policies; streaming ingestion; configurable retention; caching policy on hot range.
- Auth abstraction supporting Service Principal (secret + cert), Managed Identity (IMDS + IDENTITY_ENDPOINT), and user-delegated device-code flow.
- Built-in log levels (`Verbose`, `Information`, `Warning`, `Error`, `Critical`) plus dynamic user-defined custom levels via `Register-FDALogLevel`, with per-category min-level overrides.
- PII redaction by default with `-PreservePII` opt-in gated by `-ConsentClaim`.
- Configurable schema-drift policy: graceful (default) or strict.
- Cost / usage metering with configurable rate table.
- `Sync-FDAGovernanceLog` for M365 Unified Audit ingest into `FDAAuthEvents`.
- Canned reports: `DailyOps | FailureSummary | TopUsers | Slowest | CostByUser`.
- `Test-FDAObservability` end-to-end health check.
- Disk spool fallback + exponential-backoff retry on ingest and query.
- Pester smoke tests for offline-safe units (level resolution, redaction, cost, KQL splitter, record shape).
