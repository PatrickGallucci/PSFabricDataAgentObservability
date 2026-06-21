@{
    RootModule           = 'FabricDataAgentObservability.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = 'a2c4e6b8-1d3f-4a5b-9c8d-7e6f5a4b3c2d'
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
            ReleaseNotes = 'Initial release. Proxy capture for FDA NL->DAX, Eventhouse sink, SP/MI/User auth, dynamic custom log levels, governance + cost/usage capture. See CHANGELOG.md for full notes.'
        }
    }
}
