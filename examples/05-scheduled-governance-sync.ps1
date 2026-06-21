<#
    05-scheduled-governance-sync.ps1
    Run on a schedule (Azure Function, Automation Runbook, Task Scheduler).
    Pulls M365 Unified Audit events for Fabric/FDA and lands them in
    FDAAuthEvents for correlation with interactions.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $TenantId,
    [Parameter(Mandatory)] [string] $WorkspaceId,
    [Parameter(Mandatory)] [string] $EventhouseId,
    [Parameter(Mandatory)] [string] $ClientId,
    [Parameter(Mandatory)] [securestring] $ClientSecret,
    [int] $LookbackHours = 24
)

Import-Module (Join-Path $PSScriptRoot '..' 'PSFabricDataAgentObservability.psd1') -Force
Connect-FDAObservability -AuthMethod ServicePrincipal -TenantId $TenantId `
    -ClientId $ClientId -ClientSecret $ClientSecret `
    -WorkspaceId $WorkspaceId -EventhouseId $EventhouseId

$result = Sync-FDAGovernanceLog -LookbackHours $LookbackHours
$result | Format-List

# Optional: chain with a health check so the schedule alerts when broken.
Test-FDAObservability | Where-Object Status -ne 'Pass' | ForEach-Object {
    Write-Warning ('Health: {0} [{1}] {2}' -f $_.Check, $_.Status, $_.Detail)
}
