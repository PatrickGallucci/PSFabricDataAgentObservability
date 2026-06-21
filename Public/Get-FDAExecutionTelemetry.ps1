function Get-FDAExecutionTelemetry {
    <#
    .SYNOPSIS
        Retrieve downstream semantic-model execution telemetry, optionally
        joined to the originating interaction.
    .PARAMETER InteractionId
        Limit to executions correlated to a specific interaction.
    .PARAMETER Last
        Time window.
    .PARAMETER MinDurationMs
        Filter to executions slower than this.
    .PARAMETER Status
        Success | Error
    .PARAMETER Top
        Result cap.
    .PARAMETER JoinInteractions
        When set, left-joins to FDAInteractions on CorrelationId so callers
        get the originating question + generated DAX alongside the executed
        DAX.
    #>
    [CmdletBinding()]
    param(
        [string] $InteractionId,
        [string] $Last = '24h',
        [Nullable[long]] $MinDurationMs,
        [ValidateSet('Success', 'Error')]
        [string] $Status,
        [int] $Top = 100,
        [switch] $JoinInteractions
    )
    $clauses = @("Timestamp > ago($Last)")
    if ($InteractionId) { $clauses += "InteractionId == '$($InteractionId.Replace("'","''"))'" }
    if ($MinDurationMs) { $clauses += "DurationMs >= $MinDurationMs" }
    if ($Status)        { $clauses += "Status == '$Status'" }
    $where = 'where ' + ($clauses -join ' and ')
    if ($JoinInteractions) {
        $kql = @"
FDAExecutions
| $where
| top $Top by Timestamp desc
| join kind=leftouter (FDAInteractions | project InteractionCorrelationId = CorrelationId, Question, GeneratedDAX, AgentName, InteractionId_link = InteractionId) on `$left.CorrelationId == `$right.InteractionCorrelationId
"@
    } else {
        $kql = "FDAExecutions | $where | top $Top by Timestamp desc"
    }
    Invoke-KQLQuery -Query $kql
}
