<#
    01-setup-eventhouse.ps1
    One-time setup. Run as an account that can provision Fabric items in
    the target workspace.
#>
[CmdletBinding()]
param(
    # Optional for UserDelegated/ManagedIdentity — omit to be prompted (or to
    # use IMDS). Required for ServicePrincipal.
    [string] $TenantId,
    [Parameter(Mandatory)] [string] $WorkspaceId,
    [string] $EventhouseId,
    [string] $EventhouseName = 'FDAObservability',
    [string] $DatabaseName   = 'FDAObs',
    # Auth: pick one of the three.
    [ValidateSet('ServicePrincipal','ManagedIdentity','UserDelegated')] [string] $AuthMethod = 'UserDelegated',
    [string] $ClientId,
    [securestring] $ClientSecret
)

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'PSFabricDataAgentObservability.psd1') -Force

$connectArgs = @{
    AuthMethod   = $AuthMethod
    WorkspaceId  = $WorkspaceId
    EventhouseId = ($EventhouseId ?? '00000000-0000-0000-0000-000000000000')
    DatabaseName = $DatabaseName
}
# Only pass TenantId when supplied — an empty value would otherwise reach the
# auth flow. Omitting it lets UserDelegated prompt and ManagedIdentity use IMDS.
if ($TenantId) { $connectArgs.TenantId = $TenantId }
if ($AuthMethod -eq 'ServicePrincipal') {
    $connectArgs.ClientId     = $ClientId
    $connectArgs.ClientSecret = $ClientSecret
}

# If we have no Eventhouse yet, connect against the workspace and let Initialize
# create one. A throwaway connect to acquire the token cache is sufficient.
if (-not $EventhouseId) {
    Write-Host 'Connecting to acquire tokens for Eventhouse provisioning...' -ForegroundColor Cyan
    # Connect-FDAObservability requires an EventhouseId; provide a placeholder.
    # Initialize -CreateEventhouse will provision and re-bind endpoints.
    try { Connect-FDAObservability @connectArgs | Out-Null } catch { Write-Verbose 'Placeholder connect (expected to be re-bound).' }
    Initialize-FDAObservability -WorkspaceId $WorkspaceId -CreateEventhouse -EventhouseName $EventhouseName -DatabaseName $DatabaseName
} else {
    Connect-FDAObservability @connectArgs
    Initialize-FDAObservability -WorkspaceId $WorkspaceId -EventhouseId $EventhouseId -DatabaseName $DatabaseName
}

Test-FDAObservability | Format-Table -AutoSize
