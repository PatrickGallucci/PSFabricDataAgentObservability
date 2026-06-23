<#
    01-setup-eventhouse.ps1
    One-time setup. Run as an account that can provision Fabric items in
    the target workspace.

    Defaults for the Workspace / Eventhouse / Database come from the module's
    config.json and are created if they don't already exist. Override any of
    them with the parameters below.

    PREREQUISITE (one-time, tenant admin — recommended)
    ---------------------------------------------------
    Browser sign-in uses a public client app that must exist in your tenant.
    The least-friction option is to have a TENANT ADMIN instantiate the Azure
    CLI well-known app once:

        Connect-MgGraph -Scopes "Application.ReadWrite.All"
        New-MgServicePrincipal -AppId "04b07795-8ddb-461a-bbee-02f9e1bf7b46"   # Azure CLI

    Once that service principal exists, this script works with config.json
    ClientId left null — the Azure CLI app already carries broad pre-consented
    delegated permissions (Fabric/Power BI, ARM, Kusto), so nothing else is
    needed. No admin access? Register your own public-client app (Allow public
    client flows = Yes, http://localhost redirect) and pass its id via -ClientId
    or config.json. A missing/unprovisioned app shows as AADSTS700016.
#>
[CmdletBinding()]
param(
    # Override the config.json defaults (WorkspaceName 'FUAM PUB',
    # EventhouseName 'FDAObservability', DatabaseName 'FDAObs'). Omit to use them.
    [string] $WorkspaceName,
    [string] $EventhouseName,
    [string] $DatabaseName,
    # Fabric capacity for a created / capacity-less workspace (an Eventhouse
    # requires one). Omit to auto-pick when exactly one capacity is visible, or
    # set CapacityName in config.json.
    [string] $CapacityName,
    [string] $CapacityId,
    # Optional public client id for browser sign-in (defaults to config.json /
    # the Azure CLI well-known app). Set this to an app registered in your tenant
    # if the default isn't provisioned there (AADSTS700016).
    [string] $ClientId
)

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'PSFabricDataAgentObservability.psd1') -Force

# 1. Browser-based sign-in. The auth-code + PKCE flow opens your browser,
#    captures the redirect locally, and discovers the tenant from the token —
#    Connect returns the TenantId.
Write-Host 'Signing in (a browser window will open)...' -ForegroundColor Cyan
$connectArgs = @{ AuthMethod = 'UserDelegated' }
if ($ClientId) { $connectArgs.ClientId = $ClientId }
$TenantId = Connect-FDAObservability @connectArgs

# 2. Provision: find or create the Workspace / Eventhouse / Database (names from
#    config.json unless overridden), then apply schema and seed levels/config.
$initArgs = @{ TenantId = [string]$TenantId }
if ($WorkspaceName)  { $initArgs.WorkspaceName  = $WorkspaceName }
if ($EventhouseName) { $initArgs.EventhouseName = $EventhouseName }
if ($DatabaseName)   { $initArgs.DatabaseName   = $DatabaseName }
if ($CapacityName)   { $initArgs.CapacityName   = $CapacityName }
if ($CapacityId)     { $initArgs.CapacityId     = $CapacityId }
Initialize-FDAObservability @initArgs

Test-FDAObservability | Format-Table -AutoSize
