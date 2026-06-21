function Get-FDAInteraction {
    <#
    .SYNOPSIS
        Retrieve typed interaction records.
    .PARAMETER InteractionId
        Single-record lookup by id.
    .PARAMETER Last
        Time window (KQL timespan literal).
    .PARAMETER UserPrincipalName
        Filter by UPN.
    .PARAMETER Status
        Success | PartialCapture | Error
    .PARAMETER Top
        Result cap.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Filter')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ById')]
        [string] $InteractionId,
        [Parameter(ParameterSetName = 'Filter')]
        [string] $Last = '24h',
        [Parameter(ParameterSetName = 'Filter')]
        [string] $UserPrincipalName,
        [Parameter(ParameterSetName = 'Filter')]
        [ValidateSet('Success', 'PartialCapture', 'Error')]
        [string] $Status,
        [Parameter(ParameterSetName = 'Filter')]
        [int] $Top = 100
    )
    if ($PSCmdlet.ParameterSetName -eq 'ById') {
        $cid = $InteractionId.Replace("'", "''")
        return Invoke-KQLQuery -Query "FDAInteractions | where InteractionId == '$cid'"
    }
    $clauses = @("Timestamp > ago($Last)")
    if ($UserPrincipalName) { $clauses += "UserPrincipalName =~ '$($UserPrincipalName.Replace("'","''"))'" }
    if ($Status)            { $clauses += "Status == '$Status'" }
    $where = 'where ' + ($clauses -join ' and ')
    Invoke-KQLQuery -Query "FDAInteractions | $where | top $Top by Timestamp desc"
}
