function Get-FDAUserDelegatedToken {
    <#
    .SYNOPSIS
        Acquire a user-delegated access token for a scope using the browser-based
        authorization-code + PKCE flow, reusing a cached refresh token so a
        single interactive sign-in covers every scope.
    .DESCRIPTION
        Strategy:
          1. If a refresh token from a prior sign-in is in module state, redeem
             it silently for the requested scope (AAD refresh tokens are not
             audience-bound, so one sign-in for, say, Fabric also yields Kusto /
             ARM / Power BI tokens without re-prompting).
          2. Otherwise — or if the silent refresh fails (expired/revoked) — run
             the interactive authorization-code flow with PKCE: open the default
             browser, capture the redirect on a loopback (http://localhost:<port>)
             listener, then exchange the code for tokens (offline_access is
             requested so the response carries a refresh token).

        Unlike device code, the auth-code flow can target the tenant-less
        'organizations' authority, so the tenant does not have to be known up
        front: it is discovered from the returned id_token's `tid` claim and
        stored in module state (see Set-FDATenantFromTokenResponse). This is why
        Connect-FDAObservability can return the TenantId from a bare sign-in.

        Refresh tokens rotate: every response that includes a new one replaces
        the stored token.
    .PARAMETER ClientId
        The public client id used for the auth-code / refresh-token grants.
    .PARAMETER Scope
        Resource scope, e.g. 'https://api.fabric.microsoft.com/.default'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ClientId,
        [Parameter(Mandatory)] [string] $Scope
    )

    # Authority: use the known tenant once we have one (set on the first sign-in
    # or supplied by the caller); otherwise sign in against 'organizations' and
    # discover the tenant from the returned token.
    $authority = if ($script:FDAState.TenantId) { $script:FDAState.TenantId } else { 'organizations' }
    $tokenUrl  = "https://login.microsoftonline.com/$authority/oauth2/v2.0/token"
    # offline_access -> refresh token; openid/profile -> id_token carrying `tid`.
    $scopeWithExtras = "$Scope offline_access openid profile"

    # 1. Silent refresh from a prior sign-in, if we have a refresh token.
    if ($script:FDAState.RefreshToken) {
        $refreshForm = @{
            client_id     = $ClientId
            grant_type    = 'refresh_token'
            refresh_token = $script:FDAState.RefreshToken
            scope         = $scopeWithExtras
        }
        try {
            $resp = Invoke-RestMethod -Method Post -Uri $tokenUrl -Body $refreshForm -ErrorAction Stop
            Set-FDARefreshToken -Response $resp
            Set-FDATenantFromTokenResponse -Response $resp
            Write-Verbose "Acquired token for '$Scope' via silent refresh."
            return [pscustomobject]@{
                Token     = $resp.access_token
                ExpiresOn = (Get-Date).AddSeconds([int]$resp.expires_in)
            }
        } catch {
            Write-Verbose "Silent refresh failed for '$Scope'; falling back to interactive sign-in: $($_.Exception.Message)"
        }
    }

    # 2. Interactive authorization-code + PKCE flow (first sign-in, or refresh
    #    token expired). The browser/listener mechanics live in a separate helper
    #    so they can be mocked in tests; here we just exchange the returned code.
    $auth = Get-FDAInteractiveAuthCode -ClientId $ClientId -Authority $authority -Scope $scopeWithExtras

    $tokenForm = @{
        client_id     = $ClientId
        grant_type    = 'authorization_code'
        code          = $auth.Code
        redirect_uri  = $auth.RedirectUri
        code_verifier = $auth.CodeVerifier
        scope         = $scopeWithExtras
    }
    $resp = Invoke-RestMethod -Method Post -Uri $tokenUrl -Body $tokenForm -ErrorAction Stop
    Set-FDARefreshToken -Response $resp
    Set-FDATenantFromTokenResponse -Response $resp
    return [pscustomobject]@{
        Token     = $resp.access_token
        ExpiresOn = (Get-Date).AddSeconds([int]$resp.expires_in)
    }
}

function Get-FDAInteractiveAuthCode {
    <#
    .SYNOPSIS
        Run the interactive part of the auth-code + PKCE flow: generate the PKCE
        pair, open the browser to the authorize endpoint, and capture the code
        from the loopback redirect. Returns Code / RedirectUri / CodeVerifier.
    .DESCRIPTION
        Isolated from Get-FDAUserDelegatedToken so the (untestable) HttpListener
        / browser interaction can be mocked. Binds an ephemeral loopback port;
        AAD treats http://localhost as matching any port for public clients.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ClientId,
        [Parameter(Mandatory)] [string] $Authority,
        [Parameter(Mandatory)] [string] $Scope,
        [int] $TimeoutSeconds = 300
    )

    # --- PKCE: high-entropy verifier + S256 challenge ---------------------------
    $verifierBytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($verifierBytes)
    $codeVerifier = ConvertTo-FDABase64Url -Bytes $verifierBytes
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $challengeBytes = $sha.ComputeHash([Text.Encoding]::ASCII.GetBytes($codeVerifier))
    } finally {
        $sha.Dispose()
    }
    $codeChallenge = ConvertTo-FDABase64Url -Bytes $challengeBytes

    # --- anti-forgery state ----------------------------------------------------
    $stateBytes = [byte[]]::new(16)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($stateBytes)
    $state = ConvertTo-FDABase64Url -Bytes $stateBytes

    # --- ephemeral loopback redirect ------------------------------------------
    # Grab a free port via a throwaway TcpListener, then hand it to HttpListener.
    $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $probe.Start()
    $port = ([System.Net.IPEndPoint]$probe.LocalEndpoint).Port
    $probe.Stop()
    $redirectUri = "http://localhost:$port"

    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add("http://localhost:$port/")
    $listener.Start()

    try {
        $query = @(
            'client_id='             + [uri]::EscapeDataString($ClientId)
            'response_type=code'
            'redirect_uri='          + [uri]::EscapeDataString($redirectUri)
            'response_mode=query'
            'scope='                 + [uri]::EscapeDataString($Scope)
            'state='                 + [uri]::EscapeDataString($state)
            'code_challenge='        + [uri]::EscapeDataString($codeChallenge)
            'code_challenge_method=S256'
            'prompt=select_account'
        ) -join '&'
        $authUrl = "https://login.microsoftonline.com/$Authority/oauth2/v2.0/authorize?$query"

        Write-Host ''
        Write-Host 'Opening your browser to sign in...' -ForegroundColor Cyan
        Write-Host 'If it does not open automatically, browse to:' -ForegroundColor Yellow
        Write-Host "    $authUrl" -ForegroundColor DarkGray
        Start-Process $authUrl | Out-Null

        # Wait for the redirect (async so we can enforce a timeout).
        $contextTask = $listener.GetContextAsync()
        if (-not $contextTask.Wait([TimeSpan]::FromSeconds($TimeoutSeconds))) {
            throw "Browser sign-in timed out after $TimeoutSeconds seconds."
        }
        $context  = $contextTask.Result
        $request  = $context.Request
        $code      = $request.QueryString['code']
        $respState = $request.QueryString['state']
        $oauthErr  = $request.QueryString['error']
        $oauthDesc = $request.QueryString['error_description']

        # Acknowledge in the browser before we evaluate, so the window always closes.
        $html = if ($code) {
            '<html><head><title>Sign-in complete</title></head><body style="font-family:Segoe UI,sans-serif"><h3>Sign-in complete.</h3><p>You can close this window and return to the terminal.</p></body></html>'
        } else {
            '<html><head><title>Sign-in failed</title></head><body style="font-family:Segoe UI,sans-serif"><h3>Sign-in failed.</h3><p>Return to the terminal for details.</p></body></html>'
        }
        $buffer = [Text.Encoding]::UTF8.GetBytes($html)
        $context.Response.ContentType = 'text/html; charset=utf-8'
        $context.Response.ContentLength64 = $buffer.Length
        $context.Response.OutputStream.Write($buffer, 0, $buffer.Length)
        $context.Response.OutputStream.Close()

        if ($oauthErr) { throw "Authorization failed: $oauthErr - $oauthDesc" }
        if (-not $code) { throw 'Authorization redirect did not include a code.' }
        if ($respState -ne $state) { throw 'Authorization state mismatch (possible CSRF); aborting.' }

        return [pscustomobject]@{
            Code         = $code
            RedirectUri  = $redirectUri
            CodeVerifier = $codeVerifier
        }
    } finally {
        if ($listener.IsListening) { $listener.Stop() }
        $listener.Close()
    }
}

function ConvertTo-FDABase64Url {
    <#
    .SYNOPSIS
        Base64url-encode a byte array (no padding) per RFC 7636 / JWT.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [byte[]] $Bytes)
    [System.Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function ConvertFrom-FDAJwtPayload {
    <#
    .SYNOPSIS
        Decode the payload (claims) of a JWT into an object. Returns $null when
        the token is absent or not a well-formed JWT.
    #>
    [CmdletBinding()]
    param([string] $Jwt)
    if (-not $Jwt) { return $null }
    $parts = $Jwt.Split('.')
    if ($parts.Count -lt 2) { return $null }
    $payload = $parts[1].Replace('-', '+').Replace('_', '/')
    switch ($payload.Length % 4) { 2 { $payload += '==' } 3 { $payload += '=' } }
    try {
        $json = [Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($payload))
        return $json | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Verbose "Could not decode JWT payload: $($_.Exception.Message)"
        return $null
    }
}

function Set-FDATenantFromTokenResponse {
    <#
    .SYNOPSIS
        Discover and store the tenant id from a token response when it is not
        already known. Prefers the id_token's `tid` claim, falling back to the
        access token. No-op when a tenant is already set.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Response)
    if ($script:FDAState.TenantId) { return }
    $claims = $null
    if (($Response.PSObject.Properties.Name -contains 'id_token') -and $Response.id_token) {
        $claims = ConvertFrom-FDAJwtPayload -Jwt $Response.id_token
    }
    if ((-not $claims -or -not $claims.tid) -and ($Response.PSObject.Properties.Name -contains 'access_token') -and $Response.access_token) {
        $claims = ConvertFrom-FDAJwtPayload -Jwt $Response.access_token
    }
    if ($claims -and ($claims.PSObject.Properties.Name -contains 'tid') -and $claims.tid) {
        $script:FDAState.TenantId = $claims.tid
        Write-Verbose "Discovered tenant from token: $($claims.tid)"
    }
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
