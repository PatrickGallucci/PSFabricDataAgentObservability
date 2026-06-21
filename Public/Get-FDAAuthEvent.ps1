function Get-FDAAuthEvent {
    <#
    .SYNOPSIS
        Retrieve governance / authentication events from the FDAAuthEvents table.
    .DESCRIPTION
        Queries the curated FDAAuthEvents table populated by Sync-FDAGovernanceLog
        (M365 Unified Audit / Purview) and by module-emitted auth events. Supports
        single-record lookup by EventId or filtered windowed queries.
    .PARAMETER EventId
        Single-record lookup by event id.
    .PARAMETER CorrelationId
        Limit to events sharing a correlation id (e.g. correlate to an interaction).
    .PARAMETER UserPrincipalName
        Filter by UPN (case-insensitive).
    .PARAMETER Outcome
        Success | Failure
    .PARAMETER Source
        Purview | M365Audit | Module
    .PARAMETER Last
        Time window as a KQL timespan literal (default 24h).
    .PARAMETER Top
        Result cap (default 100).
    .EXAMPLE
        Get-FDAAuthEvent -Last 7d -Outcome Failure -Top 50
    .EXAMPLE
        Get-FDAAuthEvent -CorrelationId $interaction.CorrelationId
    #>
    [CmdletBinding(DefaultParameterSetName = 'Filter')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ById')]
        [string] $EventId,

        [Parameter(ParameterSetName = 'Filter')]
        [string] $CorrelationId,

        [Parameter(ParameterSetName = 'Filter')]
        [string] $UserPrincipalName,

        [Parameter(ParameterSetName = 'Filter')]
        [ValidateSet('Success', 'Failure')]
        [string] $Outcome,

        [Parameter(ParameterSetName = 'Filter')]
        [ValidateSet('Purview', 'M365Audit', 'Module')]
        [string] $Source,

        [Parameter(ParameterSetName = 'Filter')]
        [string] $Last = '24h',

        [Parameter(ParameterSetName = 'Filter')]
        [int] $Top = 100
    )

    if ($PSCmdlet.ParameterSetName -eq 'ById') {
        $eid = $EventId.Replace("'", "''")
        return Invoke-KQLQuery -Query "FDAAuthEvents | where EventId == '$eid'"
    }

    $clauses = @("Timestamp > ago($Last)")
    if ($CorrelationId)     { $clauses += "CorrelationId == '$($CorrelationId.Replace("'","''"))'" }
    if ($UserPrincipalName) { $clauses += "UserPrincipalName =~ '$($UserPrincipalName.Replace("'","''"))'" }
    if ($Outcome)           { $clauses += "Outcome == '$Outcome'" }
    if ($Source)            { $clauses += "Source == '$Source'" }
    $where = 'where ' + ($clauses -join ' and ')

    Invoke-KQLQuery -Query "FDAAuthEvents | $where | top $Top by Timestamp desc"
}
