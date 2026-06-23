function Connect-FDAObservability {
    <#
    .SYNOPSIS
        Authenticate the session against Fabric / Eventhouse / FDA endpoints.
    .DESCRIPTION
        Installs a token-provider closure into module-scope state. All
        subsequent cmdlets resolve tokens through this provider, refreshing
        transparently on expiry.

        Three auth methods supported. The caller picks which one their
        environment uses; the module behaves the same after connect.

        For UserDelegated, sign-in uses the browser-based authorization-code +
        PKCE flow (a loopback redirect, no code to paste) and requests
        offline_access; the resulting refresh token is reused across scopes, so a
        single interactive sign-in covers Fabric, Kusto, ARM and Power BI. The
        tenant is discovered from the returned token, so Connect returns the
        TenantId — assign it and pass to Initialize-FDAObservability.

    .PARAMETER AuthMethod
        ServicePrincipal | ManagedIdentity | UserDelegated

    .PARAMETER TenantId
        Required for ServicePrincipal. Optional for ManagedIdentity (taken
        from IMDS metadata) and UserDelegated. When omitted for UserDelegated
        the browser flow signs in against the 'organizations' authority and the
        tenant is discovered from the returned token (and returned to the
        caller). Supply it to pin sign-in to a specific tenant.

    .PARAMETER ClientId
        Required for ServicePrincipal. For UserDelegated, defaults to the
        public client id from config.json (the Azure CLI well-known app unless
        overridden) — set "ClientId" there to use an app registered in your
        tenant.

    .PARAMETER ClientSecret
        Required for ServicePrincipal when not using certificate auth.

    .PARAMETER Certificate
        Optional X509 certificate for ServicePrincipal cert-based auth.

    .PARAMETER ManagedIdentityClientId
        Optional. For user-assigned managed identity, the client id to use.

    .PARAMETER WorkspaceId
        Fabric workspace id where the FDAObs database lives. Optional — when
        omitted, the module lists the workspaces you can access and prompts
        you to select one or create a new workspace.

    .PARAMETER EventhouseId
        Fabric Eventhouse item id. Endpoints are resolved via Fabric REST.
        Optional — when omitted, the module lists the Eventhouses in the
        selected workspace and prompts you to select one or create a new
        Eventhouse.

    .PARAMETER DatabaseName
        KQL database name. Defaults to 'FDAObs'.

    .EXAMPLE
        Connect-FDAObservability -AuthMethod ServicePrincipal `
            -TenantId 'a...' -ClientId 'b...' -ClientSecret $sec `
            -WorkspaceId 'w...' -EventhouseId 'e...'

    .EXAMPLE
        Connect-FDAObservability -AuthMethod ManagedIdentity `
            -WorkspaceId 'w...' -EventhouseId 'e...'

    .EXAMPLE
        # Browser sign-in; tenant discovered and returned. Then provision by
        # name from config.json (creating Workspace/Eventhouse/Database if absent).
        $TenantId = Connect-FDAObservability -AuthMethod UserDelegated
        Initialize-FDAObservability -TenantId $TenantId

    .EXAMPLE
        Connect-FDAObservability -AuthMethod UserDelegated `
            -TenantId 'a...' -WorkspaceId 'w...' -EventhouseId 'e...'
    #>
    [CmdletBinding(DefaultParameterSetName = 'ServicePrincipal')]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('ServicePrincipal', 'ManagedIdentity', 'UserDelegated')]
        [string] $AuthMethod,

        [Parameter(ParameterSetName = 'ServicePrincipal')]
        [Parameter(ParameterSetName = 'UserDelegated')]
        [string] $TenantId,

        [Parameter(ParameterSetName = 'ServicePrincipal')]
        [Parameter(ParameterSetName = 'UserDelegated')]
        [string] $ClientId,

        [Parameter(ParameterSetName = 'ServicePrincipal')]
        [securestring] $ClientSecret,

        [Parameter(ParameterSetName = 'ServicePrincipal')]
        [System.Security.Cryptography.X509Certificates.X509Certificate2] $Certificate,

        [Parameter(ParameterSetName = 'ManagedIdentity')]
        [string] $ManagedIdentityClientId,

        [string] $WorkspaceId,

        [string] $EventhouseId,

        [string] $DatabaseName = 'FDAObs'
    )

    $script:FDAState.AuthMethod = $AuthMethod
    $script:FDAState.TenantId = $TenantId
    $script:FDAState.WorkspaceId = $WorkspaceId
    $script:FDAState.EventhouseId = $EventhouseId
    $script:FDAState.DatabaseName = $DatabaseName

    # Install the token provider keyed by scope ('*' is the fallback). The
    # providers are PLAIN scriptblocks (NOT .GetNewClosure()): a closure is
    # rebound to a new dynamic module and can no longer resolve this module's
    # private helper functions (Get-FDA*Token / New-FDAClientAssertion). Plain
    # module-affiliated blocks keep that access, so all per-connection config is
    # stashed in $script:FDAState and read by the helpers at call time.
    $script:FDAState.ClientId = $null
    $script:FDAState.ClientSecret = $null
    $script:FDAState.Certificate = $null
    $script:FDAState.ManagedIdentityClientId = $null
    switch ($AuthMethod) {
        'ServicePrincipal' {
            if (-not $TenantId -or -not $ClientId) {
                throw 'ServicePrincipal requires -TenantId and -ClientId.'
            }
            if (-not $ClientSecret -and -not $Certificate) {
                throw 'ServicePrincipal requires either -ClientSecret or -Certificate.'
            }
            $script:FDAState.ClientId = $ClientId
            $script:FDAState.ClientSecret = $ClientSecret
            $script:FDAState.Certificate = $Certificate
            $script:FDAState.TokenProviders['*'] = { param($Scope) Get-FDAServicePrincipalToken -Scope $Scope }
        }
        'ManagedIdentity' {
            $script:FDAState.ManagedIdentityClientId = $ManagedIdentityClientId
            $script:FDAState.TokenProviders['*'] = { param($Scope) Get-FDAManagedIdentityToken -Scope $Scope }
        }
        'UserDelegated' {
            # Default the public client id from config.json (Azure CLI well-known
            # app unless overridden) when none was supplied. Browser auth-code +
            # PKCE on first use, then silent refresh-token reuse across scopes
            # (see Get-FDAUserDelegatedToken).
            if (-not $ClientId) { $ClientId = (Get-FDAModuleConfig).ClientId }
            $script:FDAState.ClientId = $ClientId
            # New sign-in: drop any refresh token from a previous connection.
            $script:FDAState.RefreshToken = $null
            $script:FDAState.TokenProviders['*'] = { param($Scope) Get-FDAUserDelegatedToken -ClientId $script:FDAState.ClientId -Scope $Scope }
        }
    }

    $script:FDAState.Connected = $true

    # ---------------------------------------------------------------------
    # Sign in / resolve endpoints.
    #
    # For UserDelegated, perform the browser sign-in now so the tenant is
    # discovered at connect time (not lazily on first log). The auth-code flow
    # targets the 'organizations' authority when no tenant was supplied and
    # reads the tenant from the returned token, so Connect can return it.
    #
    # Workspace / Eventhouse resolution is OPTIONAL here: when both ids are
    # supplied we resolve endpoints (the runtime logging path); otherwise this
    # is a pure auth bootstrap and Initialize-FDAObservability resolves (or
    # creates) the target Workspace / Eventhouse / Database by name from config.
    # ---------------------------------------------------------------------
    if ($AuthMethod -eq 'UserDelegated') {
        # Triggers the browser flow and populates $script:FDAState.TenantId.
        Get-FDAAccessToken -Scope 'https://api.fabric.microsoft.com/.default' | Out-Null
        if ($script:FDAState.TenantId) {
            Write-Host "Signed in to tenant: $($script:FDAState.TenantId)" -ForegroundColor Green
        }
    }

    $endpoints = $null
    if ($WorkspaceId -and $EventhouseId) {
        $script:FDAState.WorkspaceId  = $WorkspaceId
        $script:FDAState.EventhouseId = $EventhouseId
        $endpoints = Get-FDAEventhouseEndpoint -WorkspaceId $WorkspaceId -EventhouseId $EventhouseId
        $script:FDAState.EventhouseClusterUri = $endpoints.QueryServiceUri
        $script:FDAState.EventhouseIngestUri  = $endpoints.IngestionServiceUri

        # Load config & log levels from the database (best-effort; empty on new install).
        try { Get-FDAObservabilityConfig | Out-Null } catch { Write-Verbose "Config load skipped: $($_.Exception.Message)" }
        try { Get-FDALogLevel | Out-Null }            catch { Write-Verbose "Log levels load skipped: $($_.Exception.Message)" }

        # Drain any spooled events from the previous session.
        try { Restore-FDASpool } catch { Write-Verbose "Spool restore skipped: $($_.Exception.Message)" }

        # Start the background flush timer.
        Start-FDAFlushTimer
    }

    # Return the TenantId as the primary value so callers can write
    #   $TenantId = Connect-FDAObservability
    # while still exposing the full connection status as properties (so
    #   $conn.Connected / $conn.ClusterUri  keep working).
    $result = [string]$script:FDAState.TenantId
    $result | Add-Member -PassThru -NotePropertyMembers @{
        Connected         = $true
        AuthMethod        = $AuthMethod
        TenantId          = $script:FDAState.TenantId
        WorkspaceId       = $script:FDAState.WorkspaceId
        EventhouseId      = $script:FDAState.EventhouseId
        EventhouseDisplay = if ($endpoints) { $endpoints.DisplayName } else { $null }
        DatabaseName      = $DatabaseName
        ClusterUri        = if ($endpoints) { $endpoints.QueryServiceUri } else { $null }
        IngestionUri      = if ($endpoints) { $endpoints.IngestionServiceUri } else { $null }
        SessionId         = $script:FDAState.SessionId
    }
}

function New-FDAClientAssertion {
    <#
    .SYNOPSIS
        Build a signed JWT client assertion for cert-based SP auth.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $ClientId,
        [Parameter(Mandatory)] [string] $TenantId,
        [Parameter(Mandatory)] [System.Security.Cryptography.X509Certificates.X509Certificate2] $Certificate
    )
    # Build header.
    $thumbprintBytes = [System.Convert]::FromHexString($Certificate.Thumbprint)
    $x5t = [System.Convert]::ToBase64String($thumbprintBytes).Replace('+','-').Replace('/','_').TrimEnd('=')
    $header = @{ alg = 'RS256'; typ = 'JWT'; x5t = $x5t } | ConvertTo-Json -Compress
    $now = [DateTimeOffset]::UtcNow
    $payload = @{
        aud = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
        iss = $ClientId
        sub = $ClientId
        jti = [guid]::NewGuid().ToString()
        nbf = $now.ToUnixTimeSeconds()
        exp = $now.AddMinutes(10).ToUnixTimeSeconds()
    } | ConvertTo-Json -Compress
    function _b64url([string]$s) {
        [System.Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)).Replace('+','-').Replace('/','_').TrimEnd('=')
    }
    function _b64url_bytes([byte[]]$b) {
        [System.Convert]::ToBase64String($b).Replace('+','-').Replace('/','_').TrimEnd('=')
    }
    $headerB64 = _b64url $header
    $payloadB64 = _b64url $payload
    $signingInput = "$headerB64.$payloadB64"
    # GetRSAPrivateKey is a C# extension method (RSACertificateExtensions);
    # PowerShell does not surface it as an instance method, so call the static
    # form — $Certificate.GetRSAPrivateKey() throws "method not found".
    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
    if (-not $rsa) { throw 'Certificate does not expose an RSA private key.' }
    $signature = $rsa.SignData([Text.Encoding]::UTF8.GetBytes($signingInput), [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $sigB64 = _b64url_bytes $signature
    "$signingInput.$sigB64"
}
