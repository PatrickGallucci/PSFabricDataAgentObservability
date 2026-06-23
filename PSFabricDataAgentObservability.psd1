@{
    RootModule           = 'PSFabricDataAgentObservability.psm1'
    ModuleVersion        = '1.3.0'
    GUID                 = 'c3fc66d1-7bc4-46c3-828f-85333a64697b'
    Author               = 'Patrick Gallucci'
    CompanyName          = 'Microsoft'
    Copyright            = '(c) Microsoft. All rights reserved.'
    Description          = 'Production-grade observability for Fabric Data Agent (FDA) NL-to-DAX interactions. Captures question, reasoning, grounding, generated DAX, response, user, latency, tokens, downstream execution telemetry, governance, and cost/usage into a Fabric Eventhouse KQL database. Supports built-in and user-defined dynamic logging levels.'
    PowerShellVersion    = '7.2'
    CompatiblePSEditions = @('Core', 'Desktop')

    FunctionsToExport    = @(
        'Initialize-FDAObservability',
        'Connect-FDAObservability',
        'Disconnect-FDAObservability',
        'Set-FDAObservabilityConfig',
        'Get-FDAObservabilityConfig',
        'Register-FDALogLevel',
        'Unregister-FDALogLevel',
        'Get-FDALogLevel',
        'Invoke-FDAQuery',
        'Write-FDALog',
        'Search-FDALog',
        'Get-FDAInteraction',
        'Get-FDAExecutionTelemetry',
        'Get-FDAAuthEvent',
        'Get-FDACostUsage',
        'Sync-FDAGovernanceLog',
        'New-FDAObservabilityReport',
        'Test-FDAObservability'
    )
    CmdletsToExport      = @()
    AliasesToExport      = @()
    VariablesToExport    = @()

    PrivateData          = @{
        PSData = @{
            Tags         = @('Fabric', 'PowerBI', 'DataAgent', 'NL2DAX', 'Observability', 'Logging', 'Eventhouse', 'KQL', 'Telemetry', 'Microsoft365')
            ProjectUri   = 'https://github.com/PatrickGallucci/PSFabricDataAgentObservability'
            LicenseUri   = 'https://github.com/PatrickGallucci/PSFabricDataAgentObservability/blob/main/LICENSE'
            ReleaseNotes = '1.3.0: UserDelegated now uses the browser-based authorization-code + PKCE flow (loopback redirect, no code to paste) instead of device code. It signs in against the "organizations" authority when no tenant is given and discovers the tenant from the returned token, so Connect-FDAObservability returns the TenantId. Setup is now config-driven: WorkspaceName/EventhouseName/DatabaseName/CapacityName (and the sign-in ClientId) are read from config.json and the Workspace/Eventhouse/Database are created by name if missing. A created or capacity-less workspace is placed on a Fabric capacity (auto-selected, or via CapacityName) so it can host the Eventhouse (avoids FeatureNotAvailable). New workflow: $TenantId = Connect-FDAObservability; Initialize-FDAObservability -TenantId $TenantId. UserDelegated needs a public client in the tenant — see the README admin prerequisite. 1.2.1: Fixes a fatal "Get-FDAUserDelegatedToken is not recognized" error on interactive connect — token providers were closures that could not resolve module-private helpers; they are now plain module-affiliated scriptblocks reading config from state. Also fixes several latent bugs surfaced by a new comprehensive test suite (113 tests, ~89% coverage): cert-based Service Principal auth (GetRSAPrivateKey), and StrictMode crashes in single-column KQL results, ingest/query error handling, the health check, and empty Markdown reports. 1.2.0: single interactive sign-in covers all scopes (offline_access + refresh-token reuse). See CHANGELOG.md.'
        }
    }
}
