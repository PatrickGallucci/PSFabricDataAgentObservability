function Get-FDAAccessToken {
    <#
    .SYNOPSIS
        Resolve an access token for the requested resource/scope.
    .DESCRIPTION
        Internal helper. Uses the token-provider closure that Connect-FDAObservability
        installed in module-scope state. Caches tokens until 60 seconds before
        their stated expiry, then refreshes via the provider.
    .PARAMETER Scope
        The scope/resource id. Common values:
          - https://api.fabric.microsoft.com/.default       (Fabric REST + FDA endpoints)
          - https://kusto.fabric.microsoft.com/.default     (Eventhouse / Kusto)
          - https://analysis.windows.net/powerbi/api/.default (Power BI / semantic model)
          - https://manage.office.com/.default              (M365 audit / governance)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Scope
    )

    if (-not $script:FDAState.Connected) {
        throw 'Not connected. Call Connect-FDAObservability first.'
    }

    # Cached?
    $cached = $script:FDAState.TokenCache[$Scope]
    if ($cached -and $cached.ExpiresOn -gt (Get-Date).AddSeconds(60)) {
        return $cached.Token
    }

    # Need a fresh token. Resolve provider.
    $provider = $script:FDAState.TokenProviders[$Scope]
    if (-not $provider) {
        # Fall back to the wildcard provider that Connect-FDAObservability registers.
        $provider = $script:FDAState.TokenProviders['*']
    }
    if (-not $provider) {
        throw "No token provider registered for scope '$Scope'."
    }

    $tokenResult = & $provider $Scope
    if (-not $tokenResult -or -not $tokenResult.Token) {
        throw "Token provider returned an empty token for scope '$Scope'."
    }

    $script:FDAState.TokenCache[$Scope] = [pscustomobject]@{
        Token     = $tokenResult.Token
        ExpiresOn = $tokenResult.ExpiresOn
    }
    return $tokenResult.Token
}
