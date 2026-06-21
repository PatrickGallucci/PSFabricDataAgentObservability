function Register-FDALogLevel {
    <#
    .SYNOPSIS
        Register a custom logging level (or override a built-in).

    .DESCRIPTION
        Adds a row to FDALogLevels (versioned, latest-wins per Name). After
        registration, the level resolves through Resolve-LogLevel and can be
        used anywhere a level is accepted:
            Write-FDALog -Level 'Audit' -Message ...
            Search-FDALog -MinLevel 'Audit'

    .PARAMETER Name
        Level name (e.g., 'Audit', 'Compliance').

    .PARAMETER Numeric
        Numeric weight (typically 0-100; built-ins use 10/30/50/70/90).
        Threshold comparisons use this number.

    .PARAMETER Category
        Logical grouping (e.g., 'Compliance', 'Cost', 'Security').

    .PARAMETER Description
        Free-text description shown by Get-FDALogLevel.

    .EXAMPLE
        Register-FDALogLevel -Name 'Audit' -Numeric 60 -Category 'Compliance' `
            -Description 'Recordable governance events for SOX/SOC2.'

    .EXAMPLE
        Register-FDALogLevel -Name 'Trace' -Numeric 5 -Category 'Diagnostics'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter(Mandatory)]
        [ValidateRange(0, 1000)]
        [int] $Numeric,

        [string] $Category = 'Custom',
        [string] $Description = '',
        [string] $RegisteredBy = ($env:USERNAME ?? 'system')
    )

    if (-not $script:FDAState.Connected) {
        throw 'Not connected. Call Connect-FDAObservability first.'
    }

    $record = [pscustomobject]@{
        Timestamp    = (Get-Date).ToUniversalTime().ToString('o')
        Name         = $Name
        Numeric      = $Numeric
        Category     = $Category
        Description  = $Description
        IsBuiltIn    = $false
        IsActive     = $true
        RegisteredBy = $RegisteredBy
    }
    Invoke-EventhouseIngest -TableName 'FDALogLevels' -MappingName 'FDALogLevelsMapping' -Records @($record) | Out-Null

    # Refresh cache.
    Get-FDALogLevel -Force | Out-Null
    [pscustomobject]@{ Registered = $Name; Numeric = $Numeric; Category = $Category }
}
