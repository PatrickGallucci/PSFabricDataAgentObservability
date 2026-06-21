function Get-FDACostUsage {
    <#
    .SYNOPSIS
        Cost & token usage rollups.
    .PARAMETER GroupBy
        User | Day | Model | Agent | None
    .PARAMETER Last
        Window (default 30d).
    .PARAMETER UserPrincipalName
        Limit to one user.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('User', 'Day', 'Model', 'Agent', 'None')]
        [string] $GroupBy = 'User',
        [string] $Last = '30d',
        [string] $UserPrincipalName,
        [int] $Top = 50
    )
    $clauses = @("Timestamp > ago($Last)")
    if ($UserPrincipalName) { $clauses += "UserPrincipalName =~ '$($UserPrincipalName.Replace("'","''"))'" }
    $where = 'where ' + ($clauses -join ' and ')

    $groupExpr = switch ($GroupBy) {
        'User'  { 'UserPrincipalName' }
        'Day'   { 'bin(Timestamp, 1d)' }
        'Model' { 'ModelName' }
        'Agent' { 'InteractionId' }
        'None'  { $null }
    }
    if ($groupExpr) {
        $kql = "FDACostMetering | $where | summarize Calls = count(), Tokens = sum(TotalTokens), EstCU = sum(EstimatedCapacityUnits), EstUSD = sum(EstimatedCostUSD) by $groupExpr | top $Top by EstUSD desc"
    } else {
        $kql = "FDACostMetering | $where | summarize Calls = count(), Tokens = sum(TotalTokens), EstCU = sum(EstimatedCapacityUnits), EstUSD = sum(EstimatedCostUSD)"
    }
    Invoke-KQLQuery -Query $kql
}
