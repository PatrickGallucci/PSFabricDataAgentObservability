function Get-FDALogLevel {
    <#
    .SYNOPSIS
        Return the merged active log levels (built-in + custom).
    .PARAMETER Force
        Bypass the in-memory cache and re-query.
    #>
    [CmdletBinding()]
    param([switch] $Force)

    if (-not $script:FDAState.Connected) {
        # Without a connection, still return the built-ins so the module is
        # usable offline (e.g., in unit tests).
        return $script:BuiltInLogLevels
    }
    if ($script:FDAState.LogLevels -and -not $Force) {
        return $script:FDAState.LogLevels
    }

    $rows = @()
    try {
        $rows = Invoke-KQLQuery -Query @'
GetActiveLogLevels()
'@
    } catch {
        Write-Verbose "Could not read log levels from DB: $($_.Exception.Message). Returning built-ins."
        return $script:BuiltInLogLevels
    }

    # Merge with built-ins so callers always see the full standard set.
    $byName = @{}
    foreach ($lvl in $script:BuiltInLogLevels) { $byName[$lvl.Name] = $lvl }
    foreach ($r in $rows) {
        $byName[$r.Name] = [pscustomobject]@{
            Name      = $r.Name
            Numeric   = [int]$r.Numeric
            Category  = $r.Category
            Description = $r.Description
            IsBuiltIn = [bool]$r.IsBuiltIn
        }
    }
    $merged = $byName.Values | Sort-Object Numeric
    $script:FDAState.LogLevels = $merged
    return $merged
}
