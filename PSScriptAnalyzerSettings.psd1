@{
    # PSScriptAnalyzer configuration for FabricDataAgentObservability.
    # Run:  Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
    #
    # Severity gate: CI treats Error as blocking. Warnings are reviewed.
    Severity     = @('Error', 'Warning')

    # Rules excluded below are intentional design choices, documented here for transparency.
    ExcludeRules = @(
        # Console-facing renderers (New-FDAObservabilityReport) and the examples/
        # scripts deliberately use Write-Host for human-readable, colored output.
        'PSAvoidUsingWriteHost',

        # Session/connection lifecycle cmdlets (Connect/Disconnect/Set/New/Invoke/Start)
        # are not destructive to user data; ShouldProcess is deferred to avoid changing
        # established call sites in this release.
        'PSUseShouldProcessForStateChangingFunctions',

        # Domain nouns such as "LogLevel(s)" are intentionally plural in helpers that
        # return collections.
        'PSUseSingularNouns',

        # Several parameters are consumed indirectly via $PSBoundParameters / splatting,
        # which this rule cannot see (false positives).
        'PSReviewUnusedParameter',

        # Source files are UTF-8 without BOM by deliberate cross-platform / git convention.
        'PSUseBOMForUnicodeEncodedFile'
    )
}
