function Write-FDALog {
    <#
    .SYNOPSIS
        Emit a structured log event at the specified level (built-in or custom).
    .DESCRIPTION
        Honors the configured minimum log level (global and per-category).
        Critical-level entries flush synchronously; the rest batch.

    .PARAMETER Level
        Name (e.g. 'Information', 'Audit') or numeric weight.

    .PARAMETER Message
        Log message text.

    .PARAMETER Category
        Logical grouping. Per-category MinLevel overrides apply.

    .PARAMETER Source
        Originating subsystem / cmdlet name.

    .PARAMETER Properties
        Hashtable of structured properties.

    .PARAMETER Exception
        Exception object (or error record) for error/critical events.

    .PARAMETER CorrelationId
        Optional correlation id for cross-event linkage.

    .EXAMPLE
        Write-FDALog -Level Warning -Message 'Slow query' -Category 'Performance' `
                     -Properties @{ DurationMs = 8200 }

    .EXAMPLE
        Write-FDALog -Level 'Audit' -Message 'PII payload preserved' `
                     -Category 'Compliance' -Properties @{ ConsentClaim = $claim }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Level,

        [Parameter(Mandatory)]
        [string] $Message,

        [string] $Category = 'General',
        [string] $Source = 'Write-FDALog',
        [hashtable] $Properties,
        [object] $Exception,
        [string] $CorrelationId
    )
    if (-not $script:FDAState.Connected) {
        throw 'Not connected. Call Connect-FDAObservability first.'
    }
    $resolved = Resolve-LogLevel -Level $Level

    # Apply min-level filter (global + per-category).
    $config = Get-FDAObservabilityConfig
    $minNumeric = 0
    if ($config -and $config.PSObject.Properties['MinLevelNumeric']) {
        $minNumeric = [int]$config.MinLevelNumeric
    }
    $catKey = 'MinLevelByCategory.' + $Category
    if ($config -and $config.PSObject.Properties[$catKey]) {
        $catCfg = $config.$catKey
        if ($null -ne $catCfg.Numeric) { $minNumeric = [int]$catCfg.Numeric }
    }
    if ($resolved.Numeric -lt $minNumeric) {
        Write-Verbose "Suppressed: level $($resolved.Name)($($resolved.Numeric)) below threshold $minNumeric"
        return
    }

    $caller = Get-FDACallerIdentity
    if (-not $CorrelationId) { $CorrelationId = [guid]::NewGuid().ToString() }

    $exceptionObj = $null
    if ($Exception) {
        $exceptionObj = if ($Exception -is [System.Management.Automation.ErrorRecord]) {
            @{
                Type        = $Exception.Exception.GetType().FullName
                Message     = $Exception.Exception.Message
                StackTrace  = $Exception.ScriptStackTrace
                CategoryInfo= [string]$Exception.CategoryInfo
            }
        } elseif ($Exception -is [Exception]) {
            @{
                Type       = $Exception.GetType().FullName
                Message    = $Exception.Message
                StackTrace = $Exception.StackTrace
            }
        } else { $Exception }
    }

    $record = [pscustomobject]@{
        Timestamp         = (Get-Date).ToUniversalTime().ToString('o')
        EventId           = [guid]::NewGuid().ToString()
        CorrelationId     = $CorrelationId
        SessionId         = $script:FDAState.SessionId
        TenantId          = $caller.TenantId
        UserPrincipalName = $caller.UserPrincipalName
        Source            = $Source
        Category          = $Category
        LevelName         = $resolved.Name
        LevelNumeric      = $resolved.Numeric
        Message           = $Message
        Properties        = $Properties
        Exception         = $exceptionObj
    }
    Add-FDAFlushEntry -TableName 'FDALogEventsRaw' -MappingName 'FDALogEventsRawMapping' -Record $record -LevelNumeric $resolved.Numeric
}
