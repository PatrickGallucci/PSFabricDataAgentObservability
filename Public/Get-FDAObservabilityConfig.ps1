function Get-FDAObservabilityConfig {
    <#
    .SYNOPSIS
        Read the latest effective configuration (collapses versioned rows
        in FDAConfiguration to the latest value per key).
    .PARAMETER Force
        Bypass the in-memory cache.
    #>
    [CmdletBinding()]
    param([switch] $Force)

    if (-not $script:FDAState.Connected) {
        throw 'Not connected. Call Connect-FDAObservability first.'
    }
    if ($script:FDAState.Config -and -not $Force) {
        return $script:FDAState.Config
    }

    $rows = Invoke-KQLQuery -Query @'
FDAConfiguration
| summarize arg_max(Timestamp, *) by Key
| project Key, Value, Timestamp, UpdatedBy, Notes
'@

    $cfg = [ordered]@{}
    foreach ($r in $rows) {
        $cfg[$r.Key] = $r.Value
    }
    $obj = [pscustomobject]$cfg
    $script:FDAState.Config = $obj
    return $obj
}
