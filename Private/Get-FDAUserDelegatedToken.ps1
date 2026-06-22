function Get-FDAUserDelegatedToken {
    <#
    .SYNOPSIS
        Acquire a user-delegated access token for a scope, reusing a cached
        refresh token so a single interactive sign-in covers every scope.
    .DESCRIPTION
        Strategy:
          1. If a refresh token from a prior sign-in is in module state, redeem
             it silently for the requested scope (AAD refresh tokens are not
             audience-bound, so one device-code sign-in for, say, Fabric also
             yields Kusto / ARM / Power BI tokens without re-prompting).
          2. Otherwise — or if the silent refresh fails (expired/revoked) — run
             the device-code flow, requesting `offline_access` so the response
             carries a refresh token for subsequent scopes.

        Refresh tokens rotate: every response that includes a new one replaces
        the stored token.
    .PARAMETER ClientId
        The public client id used for the device-code / refresh-token grants.
    .PARAMETER Scope
        Resource scope, e.g. 'https://api.fabric.microsoft.com/.default'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ClientId,
        [Parameter(Mandatory)] [string] $Scope
    )

    # The raw device-code endpoint needs a concrete tenant: the tenant-less
    # 'organizations'/'common' authorities are rejected with AADSTS50059.
    # Connect-FDAObservability resolves a tenant before any token is fetched.
    $tenant = $script:FDAState.TenantId
    if (-not $tenant) {
        throw 'UserDelegated sign-in requires a tenant. Pass -TenantId, or supply a tenant ID/domain when prompted.'
    }
    $tokenUrl = "https://login.microsoftonline.com/$tenant/oauth2/v2.0/token"
    # offline_access asks AAD to return a refresh token alongside the access token.
    $scopeWithOffline = "$Scope offline_access"

    # 1. Silent refresh from a prior sign-in, if we have a refresh token.
    if ($script:FDAState.RefreshToken) {
        $refreshForm = @{
            client_id     = $ClientId
            grant_type    = 'refresh_token'
            refresh_token = $script:FDAState.RefreshToken
            scope         = $scopeWithOffline
        }
        try {
            $resp = Invoke-RestMethod -Method Post -Uri $tokenUrl -Body $refreshForm -ErrorAction Stop
            Set-FDARefreshToken -Response $resp
            Write-Verbose "Acquired token for '$Scope' via silent refresh."
            return [pscustomobject]@{
                Token     = $resp.access_token
                ExpiresOn = (Get-Date).AddSeconds([int]$resp.expires_in)
            }
        } catch {
            Write-Verbose "Silent refresh failed for '$Scope'; falling back to device code: $($_.Exception.Message)"
        }
    }

    # 2. Interactive device-code flow (first sign-in, or refresh token expired).
    $deviceUrl = "https://login.microsoftonline.com/$tenant/oauth2/v2.0/devicecode"
    $dc = Invoke-RestMethod -Method Post -Uri $deviceUrl -Body @{ client_id = $ClientId; scope = $scopeWithOffline } -ErrorAction Stop
    Write-Host ''
    Write-Host '====================================================================='
    Write-Host 'Open a browser to:' -ForegroundColor Yellow
    Write-Host "    $($dc.verification_uri)" -ForegroundColor Cyan
    Write-Host 'And enter code:' -ForegroundColor Yellow
    Write-Host "    $($dc.user_code)" -ForegroundColor Cyan
    Write-Host '====================================================================='
    Write-Host ''
    $deadline = (Get-Date).AddSeconds([int]$dc.expires_in)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds ([int]$dc.interval)
        $tokenForm = @{
            client_id   = $ClientId
            grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
            device_code = $dc.device_code
        }
        try {
            $resp = Invoke-RestMethod -Method Post -Uri $tokenUrl -Body $tokenForm -ErrorAction Stop
            Set-FDARefreshToken -Response $resp
            return [pscustomobject]@{
                Token     = $resp.access_token
                ExpiresOn = (Get-Date).AddSeconds([int]$resp.expires_in)
            }
        } catch {
            $err = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($err -and $err.error -eq 'authorization_pending') { continue }
            throw
        }
    }
    throw 'Device code flow timed out before user completed sign-in.'
}

function Set-FDARefreshToken {
    <#
    .SYNOPSIS
        Persist a rotated refresh token from a token response into module state,
        if one was returned. Refresh tokens rotate on each redemption.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Response)
    if (($Response.PSObject.Properties.Name -contains 'refresh_token') -and $Response.refresh_token) {
        $script:FDAState.RefreshToken = $Response.refresh_token
    }
}
