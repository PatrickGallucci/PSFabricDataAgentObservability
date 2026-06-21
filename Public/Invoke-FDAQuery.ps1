function Invoke-FDAQuery {
    <#
    .SYNOPSIS
        Proxy wrapper around a Fabric Data Agent published endpoint. Captures
        question -> reasoning -> grounding -> generated DAX -> answer with
        latency, tokens, user, and metadata in one call.

    .DESCRIPTION
        This is the only first-party path to log the full NL->DAX interaction
        with provenance linkage. Callers replace direct HTTP calls to the FDA
        endpoint with this cmdlet.

        Workflow:
          1. Build the request, mint CorrelationId if missing.
          2. Call the FDA endpoint with timing.
          3. Parse response per v1 contract; if shape diverges, react per
             StrictSchema config (graceful default emits a Warning with
             PartialCapture).
          4. Apply redaction unless -PreservePII is used (with -ConsentClaim).
          5. Persist the interaction record and emit a CostMetering record.
          6. Return the answer (or full object with -PassThru).

    .PARAMETER AgentEndpoint
        The FDA published query endpoint URL.

    .PARAMETER Question
        Natural-language question to send to the agent.

    .PARAMETER SessionId
        Optional FDA-side conversational session id. A correlation id is
        always generated separately for log linkage.

    .PARAMETER CorrelationId
        Optional caller-supplied correlation id. Generated if absent.

    .PARAMETER Metadata
        Hashtable of caller-supplied tags (e.g., AppName, FeatureFlag, TraceId).

    .PARAMETER Level
        Log level for the interaction record. Default: Information.

    .PARAMETER PreservePII
        Skip redaction on question/grounding/answer text. Requires
        -ConsentClaim. The consent claim is logged with the record.

    .PARAMETER ConsentClaim
        Identifier of the consent grant authorizing raw PII capture.

    .PARAMETER PassThru
        Return the full FDA response object instead of just the answer text.

    .PARAMETER TimeoutSeconds
        HTTP timeout for the FDA call. Default 120.

    .EXAMPLE
        Invoke-FDAQuery -AgentEndpoint $url -Question 'Revenue by region last quarter?'

    .EXAMPLE
        Invoke-FDAQuery -AgentEndpoint $url -Question $q -PassThru -Metadata @{App='Embedded'}
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [uri] $AgentEndpoint,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Question,

        [string] $SessionId,
        [string] $CorrelationId,
        [hashtable] $Metadata,

        [object] $Level = 'Information',

        [switch] $PreservePII,
        [string] $ConsentClaim,

        [switch] $PassThru,
        [int] $TimeoutSeconds = 120
    )

    if (-not $script:FDAState.Connected) {
        throw 'Not connected. Call Connect-FDAObservability first.'
    }
    if ($PreservePII -and [string]::IsNullOrWhiteSpace($ConsentClaim)) {
        throw '-PreservePII requires -ConsentClaim (an identifier referencing the consent grant).'
    }

    $config = Get-FDAObservabilityConfig
    $strictSchema = $false
    if ($config -and $config.PSObject.Properties['StrictSchema']) {
        $strictSchema = [bool]$config.StrictSchema
    }
    $redactionPatterns = $script:DefaultRedactionPatterns
    if ($config -and $config.PSObject.Properties['RedactionPatterns'] -and $config.RedactionPatterns) {
        try { $redactionPatterns = ConvertTo-FDAHashtable $config.RedactionPatterns } catch { Write-Verbose "Falling back to default redaction patterns: $($_.Exception.Message)" }
    }

    $levelObj = Resolve-LogLevel -Level $Level
    if (-not $CorrelationId) { $CorrelationId = [guid]::NewGuid().ToString() }
    $interactionId = [guid]::NewGuid().ToString()
    if (-not $SessionId) { $SessionId = $script:FDAState.SessionId }

    # Resolve calling identity. We capture the UPN/oid claim from the token
    # if we can, otherwise fall back to the OS user.
    $caller = Get-FDACallerIdentity

    # ---- Call FDA -----------------------------------------------------
    $token = Get-FDAAccessToken -Scope ($config.FDAResourceScope ?? 'https://api.fabric.microsoft.com/.default')
    $reqHeaders = @{
        Authorization            = "Bearer $token"
        'Content-Type'           = 'application/json; charset=utf-8'
        'x-ms-client-request-id' = $CorrelationId
        'x-ms-correlation-id'    = $CorrelationId
    }
    $reqBody = @{
        question  = $Question
        sessionId = $SessionId
    } | ConvertTo-Json -Depth 10

    $partialCaptureNotes = [System.Collections.Generic.List[string]]::new()
    $status = 'Success'
    $errorMessage = $null
    $resp = $null
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $resp = Invoke-RestMethod -Method Post -Uri $AgentEndpoint -Headers $reqHeaders -Body $reqBody -TimeoutSec $TimeoutSeconds -ErrorAction Stop
    } catch {
        $sw.Stop()
        $status = 'Error'
        $errorMessage = $_.Exception.Message
        $errLevel = Resolve-LogLevel -Level 'Error'
        $errRecord = New-FDAInteractionRecord -InteractionId $interactionId -CorrelationId $CorrelationId `
            -SessionId $SessionId -AgentEndpoint $AgentEndpoint -Question $Question `
            -Response $null -LatencyMs $sw.ElapsedMilliseconds -Caller $caller `
            -Metadata $Metadata -Level $errLevel -Status 'Error' -ErrorMessage $errorMessage `
            -PreservePII:$PreservePII -ConsentClaim $ConsentClaim -RedactionPatterns $redactionPatterns `
            -PartialCaptureNotes @() -StrictSchema $false
        Add-FDAFlushEntry -TableName 'FDAInteractionsRaw' -MappingName 'FDAInteractionsRawMapping' -Record $errRecord -LevelNumeric $errLevel.Numeric -Synchronous
        throw
    }
    $sw.Stop()
    $latency = $sw.ElapsedMilliseconds

    # ---- Parse v1 contract -------------------------------------------
    $answer       = $null
    $reasoning    = @()
    $grounding    = @()
    $generatedDAX = $null
    $promptTokens = 0
    $completionTokens = 0
    $totalTokens = 0
    $agentName = $null
    $agentId = $null
    $modelName = $null

    if ($resp -and $resp.PSObject.Properties['answer']) { $answer = $resp.answer }
    elseif ($resp -and $resp.PSObject.Properties['response']) { $answer = $resp.response }
    else { $partialCaptureNotes.Add('answer-field-missing') }

    if ($resp.PSObject.Properties['steps']) { $reasoning = @($resp.steps) }
    elseif ($resp.PSObject.Properties['reasoning']) { $reasoning = @($resp.reasoning) }
    else { $partialCaptureNotes.Add('reasoning-missing') }

    if ($resp.PSObject.Properties['grounding']) { $grounding = @($resp.grounding) }
    elseif ($resp.PSObject.Properties['citations']) { $grounding = @($resp.citations) }
    else { $partialCaptureNotes.Add('grounding-missing') }

    if ($resp.PSObject.Properties['generatedQuery']) { $generatedDAX = [string]$resp.generatedQuery }
    elseif ($resp.PSObject.Properties['dax']) { $generatedDAX = [string]$resp.dax }
    elseif ($resp.PSObject.Properties['query']) { $generatedDAX = [string]$resp.query }
    else { $partialCaptureNotes.Add('generatedQuery-missing') }

    if ($resp.PSObject.Properties['usage'] -and $resp.usage) {
        if ($resp.usage.PSObject.Properties['prompt_tokens'])     { $promptTokens     = [long]$resp.usage.prompt_tokens }
        if ($resp.usage.PSObject.Properties['completion_tokens']) { $completionTokens = [long]$resp.usage.completion_tokens }
        if ($resp.usage.PSObject.Properties['total_tokens'])      { $totalTokens      = [long]$resp.usage.total_tokens }
    } else {
        $partialCaptureNotes.Add('usage-missing')
    }

    if ($resp.PSObject.Properties['agentId'])   { $agentId   = [string]$resp.agentId }
    if ($resp.PSObject.Properties['agentName']) { $agentName = [string]$resp.agentName }
    if ($resp.PSObject.Properties['model'])     { $modelName = [string]$resp.model }
    elseif ($resp.PSObject.Properties['modelName']) { $modelName = [string]$resp.modelName }

    if ($partialCaptureNotes.Count -gt 0) {
        if ($strictSchema) {
            $status = 'Error'
            $errorMessage = "Strict-schema violation: $($partialCaptureNotes -join ', ')"
        } else {
            $status = 'PartialCapture'
        }
    }

    if ($status -ne 'Success' -and $status -ne 'PartialCapture') {
        # Force at least Warning level on degraded result.
        if ($levelObj.Numeric -lt 50) { $levelObj = Resolve-LogLevel -Level 'Warning' }
    }
    if ($status -eq 'PartialCapture' -and $levelObj.Numeric -lt 50) {
        $levelObj = Resolve-LogLevel -Level 'Warning'
    }

    # ---- Apply redaction --------------------------------------------
    $questionForPersist = $Question
    $questionRedacted = $false
    $answerForPersist = $answer
    $answerRedacted = $false
    $groundingForPersist = $grounding

    if (-not $PreservePII) {
        $qResult = ConvertTo-FDARedactedText -InputText $Question -Patterns $redactionPatterns
        $questionForPersist = $qResult.Text
        $questionRedacted = $qResult.Redacted

        if ($answer) {
            $aResult = ConvertTo-FDARedactedText -InputText ([string]$answer) -Patterns $redactionPatterns
            $answerForPersist = $aResult.Text
            $answerRedacted = $aResult.Redacted
        }
        # Best-effort redaction of grounding text fields.
        $groundingForPersist = $grounding | ForEach-Object {
            if ($_ -is [string]) {
                (ConvertTo-FDARedactedText -InputText $_ -Patterns $redactionPatterns).Text
            } elseif ($_ -is [System.Collections.IDictionary] -or $_ -is [pscustomobject]) {
                $copy = $_ | ConvertTo-Json -Depth 10 | ConvertFrom-Json
                foreach ($p in $copy.PSObject.Properties) {
                    if ($p.Value -is [string]) {
                        $p.Value = (ConvertTo-FDARedactedText -InputText $p.Value -Patterns $redactionPatterns).Text
                    }
                }
                $copy
            } else { $_ }
        }
    }

    # ---- Build the interaction record --------------------------------
    $record = New-FDAInteractionRecord -InteractionId $interactionId -CorrelationId $CorrelationId `
        -SessionId $SessionId -AgentEndpoint $AgentEndpoint `
        -Question $questionForPersist -QuestionRedacted:$questionRedacted `
        -Response $resp -Answer $answerForPersist -AnswerRedacted:$answerRedacted `
        -GeneratedDAX $generatedDAX -Reasoning $reasoning -Grounding $groundingForPersist `
        -LatencyMs $latency -Caller $caller -Metadata $Metadata -Level $levelObj `
        -Status $status -ErrorMessage $errorMessage `
        -PromptTokens $promptTokens -CompletionTokens $completionTokens -TotalTokens $totalTokens `
        -AgentId $agentId -AgentName $agentName `
        -PreservePII:$PreservePII -ConsentClaim $ConsentClaim `
        -PartialCaptureNotes $partialCaptureNotes.ToArray()

    Add-FDAFlushEntry -TableName 'FDAInteractionsRaw' -MappingName 'FDAInteractionsRawMapping' -Record $record -LevelNumeric $levelObj.Numeric

    # ---- Emit cost meter --------------------------------------------
    $cost = Get-FDACostEstimate -PromptTokens $promptTokens -CompletionTokens $completionTokens -Config $config
    $meter = [pscustomobject]@{
        Timestamp              = (Get-Date).ToUniversalTime().ToString('o')
        MeterId                = [guid]::NewGuid().ToString()
        InteractionId          = $interactionId
        UserPrincipalName      = $caller.UserPrincipalName
        TenantId               = $caller.TenantId
        ModelName              = $modelName
        PromptTokens           = $promptTokens
        CompletionTokens       = $completionTokens
        TotalTokens            = $totalTokens
        EstimatedCapacityUnits = $cost.CapacityUnits
        EstimatedCostUSD       = $cost.USD
        RateTableVersion       = $cost.RateTableVersion
        Metadata               = $Metadata
    }
    Add-FDAFlushEntry -TableName 'FDACostMeteringRaw' -MappingName 'FDACostMeteringRawMapping' -Record $meter -LevelNumeric $levelObj.Numeric

    if ($status -eq 'Error') {
        throw "FDA returned error response: $errorMessage"
    }

    if ($PassThru) {
        return [pscustomobject]@{
            InteractionId    = $interactionId
            CorrelationId    = $CorrelationId
            SessionId        = $SessionId
            Question         = $Question
            Answer           = $answer
            GeneratedDAX     = $generatedDAX
            Reasoning        = $reasoning
            Grounding        = $grounding
            Status           = $status
            LatencyMs        = $latency
            PromptTokens     = $promptTokens
            CompletionTokens = $completionTokens
            TotalTokens      = $totalTokens
            EstimatedUSD     = $cost.USD
            EstimatedCU      = $cost.CapacityUnits
            RawResponse      = $resp
        }
    }
    return $answer
}

function New-FDAInteractionRecord {
    [CmdletBinding()]
    param(
        [string] $InteractionId,
        [string] $CorrelationId,
        [string] $SessionId,
        [uri]    $AgentEndpoint,
        [string] $Question,
        [switch] $QuestionRedacted,
        [object] $Response,
        [object] $Answer,
        [switch] $AnswerRedacted,
        [string] $GeneratedDAX,
        [object[]] $Reasoning,
        [object[]] $Grounding,
        [long]   $LatencyMs,
        [pscustomobject] $Caller,
        [hashtable] $Metadata,
        [pscustomobject] $Level,
        [string] $Status,
        [string] $ErrorMessage,
        [long]   $PromptTokens = 0,
        [long]   $CompletionTokens = 0,
        [long]   $TotalTokens = 0,
        [string] $AgentId,
        [string] $AgentName,
        [switch] $PreservePII,
        [string] $ConsentClaim,
        [string[]] $PartialCaptureNotes,
        [hashtable] $RedactionPatterns,
        [bool]   $StrictSchema = $false
    )
    [pscustomobject]@{
        Timestamp           = (Get-Date).ToUniversalTime().ToString('o')
        InteractionId       = $InteractionId
        CorrelationId       = $CorrelationId
        SessionId           = $SessionId
        TenantId            = $Caller.TenantId
        UserPrincipalName   = $Caller.UserPrincipalName
        ClientApp           = $Caller.ClientApp
        AgentId             = $AgentId
        AgentName           = $AgentName
        AgentEndpoint       = [string]$AgentEndpoint
        Question            = $Question
        QuestionRedacted    = [bool]$QuestionRedacted
        Reasoning           = $Reasoning
        Grounding           = $Grounding
        GeneratedDAX        = $GeneratedDAX
        Answer              = [string]$Answer
        AnswerRedacted      = [bool]$AnswerRedacted
        Status              = $Status
        ErrorMessage        = $ErrorMessage
        LatencyMs           = $LatencyMs
        PromptTokens        = $PromptTokens
        CompletionTokens    = $CompletionTokens
        TotalTokens         = $TotalTokens
        LevelName           = $Level.Name
        LevelNumeric        = $Level.Numeric
        LevelCategory       = $Level.Category
        PartialCaptureNotes = $PartialCaptureNotes
        Metadata            = $Metadata
        ConsentClaim        = $ConsentClaim
        SchemaVersion       = 1
    }
}

function Get-FDACallerIdentity {
    [CmdletBinding()]
    param()
    # Best-effort: peek at the cached access token to extract claims; fall back
    # to OS environment if unavailable. Token-aware path makes service-principal
    # callers correctly attributable.
    $upn = $null; $tenant = $script:FDAState.TenantId; $client = 'PowerShell'
    foreach ($scope in $script:FDAState.TokenCache.Keys) {
        $cached = $script:FDAState.TokenCache[$scope]
        if (-not $cached -or -not $cached.Token) { continue }
        $parts = $cached.Token.Split('.')
        if ($parts.Count -lt 2) { continue }
        $payload = $parts[1]
        # Pad b64url
        $pad = 4 - ($payload.Length % 4)
        if ($pad -lt 4) { $payload += ('=' * $pad) }
        $payload = $payload.Replace('-', '+').Replace('_', '/')
        try {
            $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))
            $obj = $json | ConvertFrom-Json
            if (-not $upn) { $upn = $obj.upn ?? $obj.preferred_username ?? $obj.appid }
            if (-not $tenant -or [string]::IsNullOrEmpty($tenant)) { $tenant = $obj.tid }
            if ($obj.appid -and -not $upn) { $upn = $obj.appid }
            if ($obj.app_displayname) { $client = $obj.app_displayname }
            break
        } catch { continue }
    }
    if (-not $upn) { $upn = $env:USERNAME }
    [pscustomobject]@{
        UserPrincipalName = $upn
        TenantId          = $tenant
        ClientApp         = $client
    }
}

function Get-FDACostEstimate {
    [CmdletBinding()]
    param(
        [long] $PromptTokens,
        [long] $CompletionTokens,
        [object] $Config
    )
    $tokensPerCU = 1000.0
    $usdPerCU = 0.18
    $version = 'default-v1'
    if ($Config -and $Config.PSObject.Properties['CapacityRates'] -and $Config.CapacityRates) {
        if ($Config.CapacityRates.TokensPerCU) { $tokensPerCU = [double]$Config.CapacityRates.TokensPerCU }
        if ($Config.CapacityRates.USDPerCU)    { $usdPerCU    = [double]$Config.CapacityRates.USDPerCU }
        if ($Config.CapacityRates.Version)     { $version     = [string]$Config.CapacityRates.Version }
    }
    $total = $PromptTokens + $CompletionTokens
    if ($tokensPerCU -le 0) { $tokensPerCU = 1000.0 }
    $cu = [double]$total / $tokensPerCU
    [pscustomobject]@{
        CapacityUnits    = [Math]::Round($cu, 4)
        USD              = [Math]::Round($cu * $usdPerCU, 4)
        RateTableVersion = $version
    }
}

function ConvertTo-FDAHashtable {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object] $InputObject)
    if ($InputObject -is [hashtable]) { return $InputObject }
    $ht = @{}
    foreach ($p in $InputObject.PSObject.Properties) { $ht[$p.Name] = $p.Value }
    return $ht
}
