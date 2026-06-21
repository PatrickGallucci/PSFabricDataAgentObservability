function Set-FDAObservabilityConfig {
    <#
    .SYNOPSIS
        Update runtime configuration. Changes are persisted to the
        FDAConfiguration table (latest-by-Key wins) and applied to the
        in-memory module state immediately.

    .PARAMETER MinLevel
        Minimum log level (name or numeric). Events below this threshold are
        dropped on the client side.

    .PARAMETER StrictSchema
        $true => Invoke-FDAQuery fails when FDA response doesn't match the
        v1 contract. $false (default) => log what is available, mark
        PartialCapture.

    .PARAMETER BatchMaxEvents
        Buffer threshold before forcing an async flush.

    .PARAMETER BatchFlushSeconds
        Background flush cadence.

    .PARAMETER RedactionPatterns
        Hashtable of Name->Regex applied to question / grounding / answer
        when -PreservePII is not used.

    .PARAMETER CapacityRates
        Hashtable: TokensPerCU, USDPerCU. Used by cost estimation.

    .PARAMETER Category
        Per-category override. When set with -MinLevel, applies only to that
        category (e.g., 'Cost', 'Auth').

    .EXAMPLE
        Set-FDAObservabilityConfig -MinLevel Warning

    .EXAMPLE
        Set-FDAObservabilityConfig -Category 'Cost' -MinLevel 'Verbose'

    .EXAMPLE
        Set-FDAObservabilityConfig -StrictSchema $true
    #>
    [CmdletBinding()]
    param(
        [object] $MinLevel,
        [Nullable[bool]] $StrictSchema,
        [Nullable[int]]  $BatchMaxEvents,
        [Nullable[int]]  $BatchFlushSeconds,
        [hashtable] $RedactionPatterns,
        [hashtable] $CapacityRates,
        [string] $Category,
        [string] $UpdatedBy = ($env:USERNAME ?? 'system')
    )

    if (-not $script:FDAState.Connected) {
        throw 'Not connected. Call Connect-FDAObservability first.'
    }

    $updates = [ordered]@{}
    if ($PSBoundParameters.ContainsKey('MinLevel')) {
        $resolved = Resolve-LogLevel -Level $MinLevel
        if ($Category) {
            $updates['MinLevelByCategory.' + $Category] = @{ Name = $resolved.Name; Numeric = $resolved.Numeric }
        } else {
            $updates['MinLevelName']    = $resolved.Name
            $updates['MinLevelNumeric'] = $resolved.Numeric
        }
    }
    if ($PSBoundParameters.ContainsKey('StrictSchema'))      { $updates['StrictSchema']      = [bool] $StrictSchema }
    if ($PSBoundParameters.ContainsKey('BatchMaxEvents'))    { $updates['BatchMaxEvents']    = [int]  $BatchMaxEvents }
    if ($PSBoundParameters.ContainsKey('BatchFlushSeconds')) { $updates['BatchFlushSeconds'] = [int]  $BatchFlushSeconds }
    if ($PSBoundParameters.ContainsKey('RedactionPatterns')) { $updates['RedactionPatterns'] = $RedactionPatterns }
    if ($PSBoundParameters.ContainsKey('CapacityRates'))     { $updates['CapacityRates']     = $CapacityRates }

    if ($updates.Count -eq 0) {
        Write-Warning 'No configuration parameters were provided.'
        return
    }

    $records = foreach ($k in $updates.Keys) {
        [pscustomobject]@{
            Timestamp = (Get-Date).ToUniversalTime().ToString('o')
            Key       = $k
            Value     = $updates[$k]
            UpdatedBy = $UpdatedBy
            Notes     = ''
        }
    }
    Invoke-EventhouseIngest -TableName 'FDAConfiguration' -MappingName 'FDAConfigurationMapping' -Records $records | Out-Null

    # Refresh in-memory.
    Get-FDAObservabilityConfig -Force | Out-Null

    [pscustomobject]@{ Updated = @($updates.Keys); At = (Get-Date) }
}
