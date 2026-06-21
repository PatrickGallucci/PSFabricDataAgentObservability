<#
    03-search-and-report.ps1
    Operator workflows.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $TenantId,
    [Parameter(Mandatory)] [string] $WorkspaceId,
    [Parameter(Mandatory)] [string] $EventhouseId
)

Import-Module (Join-Path $PSScriptRoot '..' 'FabricDataAgentObservability.psd1') -Force
Connect-FDAObservability -AuthMethod UserDelegated -TenantId $TenantId `
    -WorkspaceId $WorkspaceId -EventhouseId $EventhouseId

# Anything Warning-or-above in the last hour.
Write-Host '== Warnings in last hour ==' -ForegroundColor Yellow
Search-FDALog -MinLevel Warning -Last 1h | Format-Table Timestamp, UserPrincipalName, Status, ErrorMessage -AutoSize

# Find a user's failed interactions today.
Write-Host '== Errors for one user ==' -ForegroundColor Yellow
Search-FDALog -UserPrincipalName 'patrick.gallucci@microsoft.com' -Last 1d -Contains 'revenue'

# Raw KQL when you need it.
Write-Host '== Raw KQL ==' -ForegroundColor Yellow
Search-FDALog -KQL 'FDAInteractions | where Timestamp > ago(2h) | summarize avg(LatencyMs) by bin(Timestamp, 5m)'

# Canned reports.
Write-Host '== Daily ops snapshot ==' -ForegroundColor Yellow
New-FDAObservabilityReport -Type DailyOps | Format-List

New-FDAObservabilityReport -Type FailureSummary -Last 24h -OutFile (Join-Path $PWD 'failure-summary.md')
New-FDAObservabilityReport -Type Slowest      -Last 4h  -TopN 10 -OutFile (Join-Path $PWD 'slowest.csv')
New-FDAObservabilityReport -Type CostByUser   -Last 30d -OutFile (Join-Path $PWD 'cost-by-user.json')
