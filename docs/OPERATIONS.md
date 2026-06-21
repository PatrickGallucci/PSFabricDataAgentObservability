# Operations runbook

## Deployment checklist

1. **Provision the Eventhouse** — either point at an existing one or pass `-CreateEventhouse -EventhouseName <name>` to `Initialize-FDAObservability`.
2. **Run `Initialize-FDAObservability`** — creates tables, ingestion mappings, update policies, retention policies, and seed levels. Idempotent.
3. **Wire the proxy** — replace every direct call to the FDA published endpoint with `Invoke-FDAQuery`. App teams should not call FDA directly.
4. **Enable Workspace Monitoring** on the underlying semantic model (Power BI workspace settings). Direct the export to the same Eventhouse, or to an Eventhouse you can query from KQL. Then point downstream telemetry into the `FDAExecutionsRaw` table via a scheduled `.set-or-append` from the Workspace Monitoring source table.
5. **Configure governance sync** — schedule `Sync-FDAGovernanceLog` (see `examples/05-scheduled-governance-sync.ps1`). Run hourly to stay within the M365 audit feed's 7-day retention window.
6. **Set retention** — defaults: 90 d on `FDAInteractions`, `FDAExecutions`, `FDALogEvents`; 365 d on `FDAAuthEvents` and `FDACostMetering`. Override per-table via the schema file or `Set-FDAObservabilityConfig -RetentionDays`.
7. **Set min-level** — `Set-FDAObservabilityConfig -MinLevel Information` (default). Use `Verbose` only in dev.
8. **Tune the rate table** for cost estimation: `Set-FDAObservabilityConfig -CapacityRates @{ TokensPerCU = 1000; USDPerCU = 0.18; Version = 'v1' }`.
9. **Run `Test-FDAObservability`** — every check should return Pass.

## Monitoring

Wire a Fabric Activator or Azure Monitor alert against these KQL queries (snippets; full library in `Schema/08-sample-queries.kql`):

```kusto
// Error rate spike
FDAInteractions
| where Timestamp > ago(15m)
| summarize Total = count(), Errors = countif(Status == 'Error')
| extend ErrRate = todouble(Errors) / iff(Total == 0, 1.0, todouble(Total))
| where ErrRate > 0.05

// Latency regression
FDAInteractions
| where Timestamp > ago(15m)
| summarize p95 = percentile(LatencyMs, 95)
| where p95 > 8000

// Auth failure spike
FDAAuthEvents
| where Timestamp > ago(15m) and Outcome != 'Success'
| summarize Failures = count()
| where Failures > 10

// Token-cost surge
FDACostMetering
| where Timestamp > ago(1h)
| summarize EstUSD = sum(EstimatedCostUSD)
| where EstUSD > 50
```

Daily ops digest: schedule `New-FDAObservabilityReport -Type DailyOps -OutFile ...` and email the markdown.

## Capturing M365 Copilot-originated calls

Copilot calls the FDA published endpoint directly — the NL question is not visible to this module for those calls. Use the correlation pattern instead:

1. **Workspace Monitoring** on the semantic model captures the executed DAX, user, ActivityID, timestamp, duration.
2. **`Sync-FDAGovernanceLog`** captures the Copilot operation (`AnalyzedByExternalApplication` / `GetDataAgent`) with consent, RLS, client app.
3. Join `FDAExecutions` and `FDAAuthEvents` on `CorrelationId` (M365 audit's `CorrelationId` matches the Workspace Monitoring ActivityID for the same request).

You will have *user → DAX → result → consent* end-to-end. You will not have the natural-language question text — that lives only with Copilot.

## Common operator queries

```kusto
// Tail the last hour of warnings or worse.
Search-FDALog -MinLevel Warning -Last 1h

// Find a specific user's failures today.
Search-FDALog -UserPrincipalName 'p@m.com' -Last 1d -KQL @'
FDAInteractions
| where Timestamp > ago(1d) and UserPrincipalName == "p@m.com" and Status != "Success"
'@

// Full timeline for one interaction (uses helper function from 06-functions.kql).
Search-FDALog -KQL "GetInteractionTimeline('<interactionId>')"

// Custom-level filter (e.g., Audit).
Search-FDALog -Table FDALogEvents -MinLevel 'Audit' -Last 7d
```

## Retention tuning

Default retention is encoded in `Schema/05-retention-policies.kql`. To override at runtime:

```powershell
Set-FDAObservabilityConfig -Notes 'extend FDAInteractions to 180d'   # writes config history
# Then alter via KQL admin command:
Invoke-KustoManagementCommand -Command '.alter table FDAInteractions policy retention softdelete = 180d recoverability = enabled'
```

(Or re-run `Initialize-FDAObservability` after editing the schema file.)

## Schema migration

Adding a column to a curated table:

1. Edit `Schema/02-create-tables.kql` to add the column with `.create-merge`.
2. Edit `Schema/04-update-policies.kql` so `ExpandFDA*Raw()` projects the new column.
3. Re-run `Initialize-FDAObservability` — both files are idempotent.

The raw landing rows already contain everything in the `Payload` dynamic column, so historical rows reshape into the new column on next ingest. To backfill historical curated rows, re-run the update-policy projection on the raw table:

```kusto
.set-or-append FDAInteractions <| ExpandFDAInteractionsRaw() | where Timestamp > ago(90d)
```

## Token & secret hygiene

- Tokens are kept only in module memory and cleared by `Disconnect-FDAObservability`.
- For SP auth, prefer certificate-based auth (`-Certificate $cert`) over secret-based.
- For MI on App Service / Functions, the module honors `IDENTITY_ENDPOINT` / `IDENTITY_HEADER` — no extra config required.
- The disk spool at `~/.fda-observability/spool/` holds records you were about to ingest. If a caller used `-PreservePII`, those records contain raw PII. Lock the spool directory to the runner's user.

## Disaster recovery

| Failure | Behavior |
|---|---|
| Eventhouse unreachable | Records spool to disk; drained by `Restore-FDASpool` on next connect |
| Token refresh fails | Subsequent calls throw; reconnect re-installs the provider |
| Update policy throws on a record | The raw row is still ingested; the curated row is skipped. Inspect via `.show ingestion failures` |
| Cluster throttles | Exponential backoff, then spool |
| Process dies | In-memory buffer is lost; spool is on disk so anything written there is recovered. Recommend `BatchMaxEvents = 50` for higher-criticality workloads |
