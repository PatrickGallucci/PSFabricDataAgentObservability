function Disconnect-FDAObservability {
    <#
    .SYNOPSIS
        Tear down the observability session: flush pending logs, stop the
        background timer, and clear cached tokens.
    #>
    [CmdletBinding()]
    param()
    try { Stop-FDAFlushTimer } catch { Write-Verbose "Stop-FDAFlushTimer during disconnect: $($_.Exception.Message)" }
    $script:FDAState.TokenCache = @{}
    $script:FDAState.TokenProviders = @{}
    $script:FDAState.Connected = $false
    $script:FDAState.AuthMethod = $null
    $script:FDAState.EventhouseClusterUri = $null
    $script:FDAState.EventhouseIngestUri = $null
    [pscustomobject]@{ Disconnected = $true; At = (Get-Date) }
}
