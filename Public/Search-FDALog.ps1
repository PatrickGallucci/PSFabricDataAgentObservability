function Search-FDALog {
    <#
    .SYNOPSIS
        Search captured logs by level, time window, user, text, or raw KQL.

    .DESCRIPTION
        Runs against the curated tables. Either pass a structured filter set
        or supply -KQL for an arbitrary query.

    .PARAMETER Table
        Which curated table to search. Default: FDAInteractions.
        Use 'FDALogEvents' for generic / custom-level events,
        'FDAExecutions' for downstream telemetry,
        'FDAAuthEvents' for governance,
        'FDACostMetering' for usage.

    .PARAMETER MinLevel
        Filter to entries at or above this level (built-in or custom).

    .PARAMETER MaxLevel
        Filter to entries at or below this level.

    .PARAMETER Last
        Time window expression accepted by KQL (1h, 24h, 7d, 30d, etc.).

    .PARAMETER UserPrincipalName
        Filter by UPN.

    .PARAMETER Contains
        Substring search across the primary text columns of the chosen table.

    .PARAMETER CorrelationId
        Exact match.

    .PARAMETER InteractionId
        Exact match.

    .PARAMETER Top
        Row cap. Default 100.

    .PARAMETER KQL
        Raw KQL to execute. Bypasses all other filters.

    .EXAMPLE
        Search-FDALog -MinLevel Warning -Last 1h

    .EXAMPLE
        Search-FDALog -Table FDAInteractions -UserPrincipalName 'p@m.com' -Contains 'revenue'

    .EXAMPLE
        Search-FDALog -KQL 'FDAInteractions | where Status == "Error" | top 10 by Timestamp desc'
    #>
    [CmdletBinding(DefaultParameterSetName = 'Filter')]
    param(
        [Parameter(ParameterSetName = 'Filter')]
        [ValidateSet('FDAInteractions', 'FDAExecutions', 'FDAAuthEvents', 'FDACostMetering', 'FDALogEvents')]
        [string] $Table = 'FDAInteractions',

        [Parameter(ParameterSetName = 'Filter')]
        [object] $MinLevel,

        [Parameter(ParameterSetName = 'Filter')]
        [object] $MaxLevel,

        [Parameter(ParameterSetName = 'Filter')]
        [string] $Last = '24h',

        [Parameter(ParameterSetName = 'Filter')]
        [string] $UserPrincipalName,

        [Parameter(ParameterSetName = 'Filter')]
        [string] $Contains,

        [Parameter(ParameterSetName = 'Filter')]
        [string] $CorrelationId,

        [Parameter(ParameterSetName = 'Filter')]
        [string] $InteractionId,

        [Parameter(ParameterSetName = 'Filter')]
        [int] $Top = 100,

        [Parameter(Mandatory, ParameterSetName = 'KQL')]
        [string] $KQL
    )

    if (-not $script:FDAState.Connected) {
        throw 'Not connected. Call Connect-FDAObservability first.'
    }

    if ($PSCmdlet.ParameterSetName -eq 'KQL') {
        return Invoke-KQLQuery -Query $KQL
    }

    $clauses = @()
    if ($Last) {
        $clauses += "Timestamp > ago($Last)"
    }
    if ($MinLevel) {
        $lvl = Resolve-LogLevel -Level $MinLevel
        $clauses += "LevelNumeric >= $($lvl.Numeric)"
    }
    if ($MaxLevel) {
        $lvl = Resolve-LogLevel -Level $MaxLevel
        $clauses += "LevelNumeric <= $($lvl.Numeric)"
    }
    if ($UserPrincipalName) {
        $upn = $UserPrincipalName.Replace("'", "''")
        $clauses += "UserPrincipalName =~ '$upn'"
    }
    if ($CorrelationId) {
        $c = $CorrelationId.Replace("'", "''")
        $clauses += "CorrelationId == '$c'"
    }
    if ($InteractionId -and $Table -in 'FDAInteractions', 'FDAExecutions', 'FDACostMetering') {
        $c = $InteractionId.Replace("'", "''")
        $clauses += "InteractionId == '$c'"
    }
    if ($Contains) {
        $needle = $Contains.Replace("'", "''")
        switch ($Table) {
            'FDAInteractions'  { $clauses += "(Question contains_cs '$needle' or GeneratedDAX contains_cs '$needle' or Answer contains_cs '$needle')" }
            'FDAExecutions'    { $clauses += "ExecutedDAX contains_cs '$needle'" }
            'FDAAuthEvents'    { $clauses += "(UserPrincipalName contains_cs '$needle' or ClientApp contains_cs '$needle')" }
            'FDACostMetering'  { $clauses += "UserPrincipalName contains_cs '$needle'" }
            'FDALogEvents'     { $clauses += "Message contains_cs '$needle'" }
        }
    }

    $where = if ($clauses.Count -gt 0) { 'where ' + ($clauses -join ' and ') } else { '' }
    $kql = "$Table | $where | top $Top by Timestamp desc"
    Invoke-KQLQuery -Query $kql
}
