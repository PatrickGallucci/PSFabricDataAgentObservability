# Schema reference

All tables live in the KQL database **FDAObs** in the target Eventhouse. Raw landing tables receive JSON; update policies reshape into typed curated tables on commit.

## FDAInteractions (curated)

| Column | Type | Notes |
|---|---|---|
| `Timestamp` | datetime | UTC, set by the proxy at request time |
| `InteractionId` | string | GUID, unique per `Invoke-FDAQuery` call |
| `CorrelationId` | string | Caller-supplied or generated; shared with `FDAExecutions` and `FDALogEvents` |
| `SessionId` | string | FDA-side conversational session, optional |
| `TenantId` | string | From the access-token `tid` claim |
| `UserPrincipalName` | string | From the token (`upn` / `appid`) or OS user |
| `ClientApp` | string | From token `app_displayname` when SP, else `PowerShell` |
| `AgentId` / `AgentName` | string | From the FDA response |
| `AgentEndpoint` | string | The URI the proxy hit |
| `Question` | string | NL question (redacted unless `-PreservePII`) |
| `QuestionRedacted` | bool | Whether redaction modified the text |
| `Reasoning` | dynamic | Array of step objects from `response.steps` |
| `Grounding` | dynamic | Array of grounding/citation objects |
| `GeneratedDAX` | string | From `response.generatedQuery` / `dax` / `query` |
| `Answer` | string | From `response.answer` / `response.response` (redacted unless `-PreservePII`) |
| `AnswerRedacted` | bool | |
| `Status` | string | `Success` \| `PartialCapture` \| `Error` |
| `ErrorMessage` | string | When Status != Success |
| `LatencyMs` | long | Wall time of the FDA call |
| `PromptTokens` / `CompletionTokens` / `TotalTokens` | long | From `response.usage` |
| `LevelName` / `LevelNumeric` / `LevelCategory` | string/int | Resolved level for the record |
| `PartialCaptureNotes` | dynamic | Field names that were missing when status is `PartialCapture` |
| `Metadata` | dynamic | Caller-supplied tags |
| `ConsentClaim` | string | Set only when `-PreservePII` was used |
| `SchemaVersion` | int | Bumped when the typed shape changes |

## FDAExecutions (curated)

| Column | Type | Notes |
|---|---|---|
| `Timestamp` | datetime | Execution start (Workspace Monitoring) or capture time (manual) |
| `ExecutionId` | string | Source-system id |
| `InteractionId` | string | Best-effort link back to `FDAInteractions`; may be empty for non-proxy callers |
| `CorrelationId` | string | When the source provides it; primary join key for non-proxy callers |
| `TenantId` / `UserPrincipalName` | string | |
| `SemanticModelId` / `SemanticModelName` | string | |
| `ExecutedDAX` | string | The DAX actually sent to the engine |
| `DurationMs` | long | |
| `RowsReturned` / `BytesProcessed` | long | |
| `CacheHit` | bool | |
| `Status` / `ErrorMessage` | string | |
| `Source` | string | `WorkspaceMonitoring` \| `XMLA` \| `Manual` |
| `LevelName` / `LevelNumeric` | string/int | |
| `Metadata` | dynamic | |

## FDAAuthEvents (curated)

| Column | Type | Notes |
|---|---|---|
| `Timestamp` | datetime | Event time from the source system |
| `EventId` | string | Source-system event id |
| `CorrelationId` | string | When available |
| `TenantId` / `UserPrincipalName` | string | |
| `ClientApp` | string | |
| `AuthMethod` | string | `Member`, `Guest`, `ServicePrincipal`, etc. from M365 audit |
| `Outcome` | string | `Success` \| `Failure` \| `Denied` |
| `ConsentStatus` | string | When applicable |
| `RLSContext` | dynamic | RLS principals/roles in effect |
| `IPAddress` / `UserAgent` | string | |
| `Source` | string | `M365Audit` \| `Purview` \| `Module` |
| `LevelName` / `LevelNumeric` | string/int | |
| `Metadata` | dynamic | `Operation`, `Workload`, etc. |

## FDACostMetering (curated)

| Column | Type | Notes |
|---|---|---|
| `Timestamp` | datetime | |
| `MeterId` | string | GUID per cost row |
| `InteractionId` | string | FK to `FDAInteractions` |
| `UserPrincipalName` / `TenantId` | string | |
| `ModelName` | string | From `response.model` |
| `PromptTokens` / `CompletionTokens` / `TotalTokens` | long | |
| `EstimatedCapacityUnits` | real | `(prompt + completion) / TokensPerCU` |
| `EstimatedCostUSD` | real | `CapacityUnits * USDPerCU` |
| `RateTableVersion` | string | Pinned to the rate table in effect at write time |
| `Metadata` | dynamic | |

## FDALogEvents (curated)

| Column | Type | Notes |
|---|---|---|
| `Timestamp` | datetime | |
| `EventId` | string | GUID |
| `CorrelationId` / `SessionId` | string | |
| `TenantId` / `UserPrincipalName` | string | |
| `Source` | string | Cmdlet or caller name |
| `Category` | string | Logical grouping; honored by per-category min-level overrides |
| `LevelName` / `LevelNumeric` | string/int | |
| `Message` | string | |
| `Properties` | dynamic | Hashtable supplied by the caller |
| `Exception` | dynamic | When supplied |

## FDALogLevels (operational, versioned)

`latest-by-Name` is the active set. `Unregister-FDALogLevel` writes `IsActive=false`. Built-in levels are seeded with `IsBuiltIn=true` at provisioning time.

| Column | Type |
|---|---|
| `Timestamp` | datetime |
| `Name` | string |
| `Numeric` | int |
| `Category` | string |
| `Description` | string |
| `IsBuiltIn` | bool |
| `IsActive` | bool |
| `RegisteredBy` | string |

## FDAConfiguration (operational, versioned)

`latest-by-Key` wins. Keys used by the module:

| Key | Type |
|---|---|
| `MinLevelName` / `MinLevelNumeric` | string / int |
| `MinLevelByCategory.<Category>` | dynamic `{Name, Numeric}` |
| `StrictSchema` | bool |
| `BatchMaxEvents` | int |
| `BatchFlushSeconds` | int |
| `RedactionPatterns` | dynamic (hashtable of name → regex) |
| `CapacityRates` | dynamic `{TokensPerCU, USDPerCU, Version?}` |
| `FDAResourceScope` | string |
| `RetentionDays.<Table>` | int |

## Raw landing tables

Each `FDA*Raw` table has the same shape:

| Column | Type |
|---|---|
| `IngestTime` | datetime |
| `Payload` | dynamic |

Ingestion mappings are named `<Table>Mapping`. Streaming ingestion is enabled on every raw table.
