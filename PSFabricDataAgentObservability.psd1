@{
    RootModule           = 'PSFabricDataAgentObservability.psm1'
    ModuleVersion        = '1.0.1'
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
            ReleaseNotes = 'Renamed module to PSFabricDataAgentObservability to align with the repository and published package name (new GUID). Functionally identical to 1.0.0: proxy capture for FDA NL->DAX, Eventhouse sink, SP/MI/User auth, dynamic custom log levels, governance + cost/usage capture. See CHANGELOG.md for full notes.'
        }
    }
}
