function Unregister-FDALogLevel {
    <#
    .SYNOPSIS
        Deactivate a custom log level. Does not delete history.
    .DESCRIPTION
        Writes a new versioned row with IsActive=false. Get-FDALogLevel will
        omit the level from the active set; existing log entries that already
        referenced the level remain searchable.

        Built-in levels cannot be unregistered.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Name
    )
    if ($script:BuiltInLogLevels.Name -contains $Name) {
        throw "Cannot unregister built-in level '$Name'."
    }
    $existing = Get-FDALogLevel | Where-Object Name -eq $Name | Select-Object -First 1
    if (-not $existing) { throw "Log level '$Name' is not registered." }

    $record = [pscustomobject]@{
        Timestamp    = (Get-Date).ToUniversalTime().ToString('o')
        Name         = $existing.Name
        Numeric      = $existing.Numeric
        Category     = $existing.Category
        Description  = $existing.Description
        IsBuiltIn    = $false
        IsActive     = $false
        RegisteredBy = ($env:USERNAME ?? 'system')
    }
    Invoke-EventhouseIngest -TableName 'FDALogLevels' -MappingName 'FDALogLevelsMapping' -Records @($record) | Out-Null
    Get-FDALogLevel -Force | Out-Null
    [pscustomobject]@{ Unregistered = $Name }
}
