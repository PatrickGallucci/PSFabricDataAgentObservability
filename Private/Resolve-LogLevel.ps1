function Resolve-LogLevel {
    <#
    .SYNOPSIS
        Resolve a log level (Name or Numeric) into a normalized level object.
    .DESCRIPTION
        Merges built-in levels with custom levels registered via
        Register-FDALogLevel. Custom registrations override built-in names so
        operators can re-categorize or change numeric weights.
    #>
    [CmdletBinding()]
    param(
        # Level can be a string (Name) or an int (Numeric).
        [Parameter(Mandatory)]
        [object] $Level
    )

    $levels = Get-MergedLogLevels

    if ($Level -is [int] -or ($Level -is [string] -and $Level -match '^\d+$')) {
        $num = [int] $Level
        # Find an exact numeric match if present; otherwise return a
        # synthetic level pinned to the nearest registered band.
        $exact = $levels | Where-Object { $_.Numeric -eq $num } | Select-Object -First 1
        if ($exact) { return $exact }
        $nearest = $levels | Sort-Object { [Math]::Abs($_.Numeric - $num) } | Select-Object -First 1
        return [pscustomobject]@{
            Name      = ('Custom_{0}' -f $num)
            Numeric   = $num
            Category  = ($nearest.Category ?? 'Custom')
            IsBuiltIn = $false
        }
    }

    $name = [string] $Level
    $match = $levels | Where-Object { $_.Name -ieq $name } | Select-Object -First 1
    if (-not $match) {
        throw "Unknown log level '$name'. Use Get-FDALogLevel to list registered levels or Register-FDALogLevel to add one."
    }
    return $match
}

function Get-MergedLogLevels {
    <#
    .SYNOPSIS
        Return the merged built-in + custom level list.
    .DESCRIPTION
        Reads from the in-memory cache populated by Get-FDALogLevel. If the
        cache is empty (e.g., not connected yet), returns the built-ins only.
    #>
    [CmdletBinding()]
    param()
    $builtIn = $script:BuiltInLogLevels
    $custom = $script:FDAState.LogLevels
    if (-not $custom) { return $builtIn }
    # Latest-by-Name semantics: custom wins on duplicate Name.
    $byName = @{}
    foreach ($lvl in $builtIn) { $byName[$lvl.Name] = $lvl }
    foreach ($lvl in $custom) { $byName[$lvl.Name] = $lvl }
    return $byName.Values | Sort-Object Numeric
}
