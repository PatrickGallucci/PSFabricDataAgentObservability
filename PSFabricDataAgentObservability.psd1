@{
    RootModule           = 'PSFabricDataAgentObservability.psm1'
    ModuleVersion        = '1.2.0'
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
            ReleaseNotes = '1.2.0: UserDelegated device-code sign-in now requests offline_access and reuses the resulting refresh token across scopes, so a single interactive sign-in covers Fabric, Kusto, ARM and Power BI instead of prompting per scope. 1.1.1: Fixes AADSTS50059 — prompts for a tenant ID/domain when -TenantId is omitted. 1.1.0: Interactive connect & provisioning — Connect/Initialize no longer require TenantId/WorkspaceId/EventhouseId; select or create the Fabric workspace/Eventhouse from a menu. Fully backward compatible. See CHANGELOG.md.'
        }
    }
}
