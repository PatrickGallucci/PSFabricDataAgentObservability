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

        For UserDelegated, the device-code sign-in requests offline_access and
        the resulting refresh token is reused across scopes, so a single
        interactive sign-in covers Fabric, Kusto, ARM and Power BI.

    .PARAMETER AuthMethod
        ServicePrincipal | ManagedIdentity | UserDelegated

    .PARAMETER TenantId
        Required for ServicePrincipal. Optional for ManagedIdentity (taken
        from IMDS metadata) and UserDelegated. When omitted for UserDelegated
        you are prompted for a tenant ID (GUID) or verified domain
        (e.g. contoso.onmicrosoft.com) to sign in to — the device-code flow
        needs a concrete tenant, so it cannot be discovered after sign-in.

    .PARAMETER ClientId
        Required for ServicePrincipal. For UserDelegated, defaults to the
        well-known Power BI public client id.

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
        # Fully interactive: sign in, pick (or create) tenant / workspace / Eventhouse.
        Connect-FDAObservability -AuthMethod UserDelegated

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
            # Default to the Power BI / Azure PowerShell well-known public client
            # if no ClientId was supplied. Device-code flow on first use, then
            # silent refresh-token reuse across scopes (see Get-FDAUserDelegatedToken).
            if (-not $ClientId) { $ClientId = '1950a258-227b-4e31-a9cf-717495945fc8' }
            $script:FDAState.ClientId = $ClientId
            # New sign-in: drop any refresh token from a previous connection.
            $script:FDAState.RefreshToken = $null
            $script:FDAState.TokenProviders['*'] = { param($Scope) Get-FDAUserDelegatedToken -ClientId $script:FDAState.ClientId -Scope $Scope }
        }
    }

    $script:FDAState.Connected = $true

    # ---------------------------------------------------------------------
    # Resolve tenant / workspace / Eventhouse. Anything not supplied as a
    # parameter is selected interactively (this is where the device-code
    # sign-in happens for UserDelegated).
    # ---------------------------------------------------------------------

    # Tenant: only UserDelegated needs an interactive prompt. SP uses the
    # supplied -TenantId; ManagedIdentity takes it from IMDS. The device-code
    # flow can't bootstrap without a concrete tenant, so ask for one up front.
    if (-not $script:FDAState.TenantId -and $AuthMethod -eq 'UserDelegated') {
        $script:FDAState.TenantId = Resolve-FDATenant
        Write-Host "Signing in to tenant: $($script:FDAState.TenantId)" -ForegroundColor Green
    }

    # Workspace.
    if (-not $WorkspaceId) {
        $WorkspaceId = Resolve-FDAWorkspace
    }
    $script:FDAState.WorkspaceId = $WorkspaceId

    # Eventhouse.
    if (-not $EventhouseId) {
        $EventhouseId = Resolve-FDAEventhouse -WorkspaceId $WorkspaceId
    }
    $script:FDAState.EventhouseId = $EventhouseId

    # Resolve Eventhouse endpoints.
    $endpoints = Get-FDAEventhouseEndpoint -WorkspaceId $WorkspaceId -EventhouseId $EventhouseId
    $script:FDAState.EventhouseClusterUri = $endpoints.QueryServiceUri
    $script:FDAState.EventhouseIngestUri = $endpoints.IngestionServiceUri

    # Load config & log levels from the database (best-effort; empty on new install).
    try { Get-FDAObservabilityConfig | Out-Null } catch { Write-Verbose "Config load skipped: $($_.Exception.Message)" }
    try { Get-FDALogLevel | Out-Null }            catch { Write-Verbose "Log levels load skipped: $($_.Exception.Message)" }

    # Drain any spooled events from the previous session.
    try { Restore-FDASpool } catch { Write-Verbose "Spool restore skipped: $($_.Exception.Message)" }

    # Start the background flush timer.
    Start-FDAFlushTimer

    [pscustomobject]@{
        Connected           = $true
        AuthMethod          = $AuthMethod
        WorkspaceId         = $WorkspaceId
        EventhouseId        = $EventhouseId
        EventhouseDisplay   = $endpoints.DisplayName
        DatabaseName        = $DatabaseName
        ClusterUri          = $endpoints.QueryServiceUri
        IngestionUri        = $endpoints.IngestionServiceUri
        SessionId           = $script:FDAState.SessionId
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
