function New-FDAObservabilityReport {
    <#
    .SYNOPSIS
        Generate a canned operational report.

    .DESCRIPTION
        Wraps the KQL functions deployed in 06-functions.kql into typed
        objects. Optionally writes Markdown / JSON / CSV to disk.

    .PARAMETER Type
        DailyOps | FailureSummary | TopUsers | Slowest | CostByUser

    .PARAMETER Last
        Time window (default 24h, except CostByUser which defaults to 30d).

    .PARAMETER OutFile
        Path to write the report. Format inferred from extension
        (.md, .json, .csv). When omitted, returns objects to the pipeline.

    .PARAMETER TopN
        Row cap for top-N reports.

    .EXAMPLE
        New-FDAObservabilityReport -Type DailyOps -OutFile ./daily.md

    .EXAMPLE
        New-FDAObservabilityReport -Type Slowest -Last 4h -TopN 10
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('DailyOps', 'FailureSummary', 'TopUsers', 'Slowest', 'CostByUser')]
        [string] $Type,

        [string] $Last,
        [string] $OutFile,
        [int] $TopN = 25
    )
    if (-not $script:FDAState.Connected) {
        throw 'Not connected. Call Connect-FDAObservability first.'
    }

    $rows = switch ($Type) {
        'DailyOps'       { Invoke-KQLQuery -Query ("GetDailyOpsSnapshot({0})"   -f ($Last ?? '24h')) }
        'FailureSummary' { Invoke-KQLQuery -Query ("GetFailureSummary({0})"     -f ($Last ?? '24h')) }
        'Slowest'        { Invoke-KQLQuery -Query ("GetSlowestQueries({0}, {1})" -f ($Last ?? '24h'), $TopN) }
        'CostByUser'     { Invoke-KQLQuery -Query ("GetCostByUser({0})"         -f ($Last ?? '30d')) }
        'TopUsers'       {
            $window = $Last ?? '7d'
            Invoke-KQLQuery -Query @"
FDAInteractions
| where Timestamp > ago($window)
| summarize Calls = count(),
            Errors = countif(Status == 'Error'),
            PartialCaptures = countif(Status == 'PartialCapture'),
            AvgLatencyMs = avg(LatencyMs),
            Tokens = sum(TotalTokens)
          by UserPrincipalName
| top $TopN by Calls desc
"@
        }
    }

    if ($OutFile) {
        $ext = ([System.IO.Path]::GetExtension($OutFile)).ToLower()
        switch ($ext) {
            '.json' { $rows | ConvertTo-Json -Depth 20 | Set-Content -Path $OutFile -Encoding UTF8 }
            '.csv'  { $rows | Export-Csv -Path $OutFile -NoTypeInformation -Encoding UTF8 }
            '.md'   {
                $md = New-FDAReportMarkdown -Type $Type -Rows $rows
                Set-Content -Path $OutFile -Value $md -Encoding UTF8
            }
            default { $rows | ConvertTo-Json -Depth 20 | Set-Content -Path $OutFile -Encoding UTF8 }
        }
        Write-Host "Report written: $OutFile"
    }
    return $rows
}

function New-FDAReportMarkdown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Type,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Rows
    )
    $title = switch ($Type) {
        'DailyOps'       { 'Daily Ops Snapshot' }
        'FailureSummary' { 'Failure Summary' }
        'TopUsers'       { 'Top Users by Activity' }
        'Slowest'        { 'Slowest Interactions' }
        'CostByUser'     { 'Cost / Usage by User' }
    }
    $now = (Get-Date).ToString('u')
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("# FDA Observability — $title")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("Generated: $now")
    [void]$sb.AppendLine()
    if (-not $Rows -or $Rows.Count -eq 0) {
        [void]$sb.AppendLine('_No rows in window._')
        return $sb.ToString()
    }
    $cols = $Rows[0].PSObject.Properties.Name
    [void]$sb.AppendLine('| ' + ($cols -join ' | ') + ' |')
    [void]$sb.AppendLine('| ' + ((1..$cols.Count | ForEach-Object { '---' }) -join ' | ') + ' |')
    foreach ($r in $Rows) {
        $vals = foreach ($c in $cols) {
            $v = $r.$c
            if ($null -eq $v) { '' } elseif ($v -is [string]) { $v.Replace('|','\|').Replace("`n",' ') } else { [string]$v }
        }
        [void]$sb.AppendLine('| ' + ($vals -join ' | ') + ' |')
    }
    return $sb.ToString()
}
