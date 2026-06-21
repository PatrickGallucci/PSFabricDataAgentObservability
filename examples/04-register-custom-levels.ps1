<#
    04-register-custom-levels.ps1
    Demonstrates user-defined log levels with category-scoped thresholds.
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

# Show built-ins first.
Get-FDALogLevel | Format-Table -AutoSize

# Register a few custom levels.
Register-FDALogLevel -Name 'Trace'      -Numeric 5   -Category 'Diagnostics' `
    -Description 'Per-token / per-step traces. Off by default in prod.'
Register-FDALogLevel -Name 'Audit'      -Numeric 60  -Category 'Compliance' `
    -Description 'Governance-grade events (SOX/SOC2).'
Register-FDALogLevel -Name 'Forensic'   -Numeric 95  -Category 'Security' `
    -Description 'Incident response. Always flushed sync.'

Get-FDALogLevel | Sort-Object Numeric | Format-Table Name, Numeric, Category, IsBuiltIn -AutoSize

# Write at the new levels.
Write-FDALog -Level 'Audit'    -Message 'PII export approved' -Category 'Compliance' -Properties @{ ConsentClaim = 'CC-1234' }
Write-FDALog -Level 'Trace'    -Message 'token boundary'      -Category 'Diagnostics'
Write-FDALog -Level 'Forensic' -Message 'Suspicious DAX'      -Category 'Security'   -Properties @{ Indicator = 'union ALL' }

# Filter at query time.
Write-Host '== Compliance trail ==' -ForegroundColor Cyan
Search-FDALog -Table FDALogEvents -MinLevel 'Audit' -Last 1d | Format-Table Timestamp, UserPrincipalName, Message -AutoSize

# Per-category min-level: keep Diagnostics quiet in prod but allow Cost telemetry chatty.
Set-FDAObservabilityConfig -Category 'Diagnostics' -MinLevel 'Warning'
Set-FDAObservabilityConfig -Category 'Cost'        -MinLevel 'Verbose'

# A custom level can also be deactivated; history remains searchable.
Unregister-FDALogLevel -Name 'Trace'
