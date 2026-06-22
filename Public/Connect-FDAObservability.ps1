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

    .PARAMETER AuthMethod
        ServicePrincipal | ManagedIdentity | UserDelegated

    .PARAMETER TenantId
        Required for ServicePrincipal. Optional for ManagedIdentity (taken
        from IMDS metadata) and UserDelegated. When omitted for
        UserDelegated, you sign in interactively (device code), the module
        enumerates the tenants you can access and — if there is more than
        one — prompts you to pick one.

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

    # Install token-provider closures keyed by scope. '*' is the fallback.
    switch ($AuthMethod) {
        'ServicePrincipal' {
            if (-not $TenantId -or -not $ClientId) {
                throw 'ServicePrincipal requires -TenantId and -ClientId.'
            }
            if (-not $ClientSecret -and -not $Certificate) {
                throw 'ServicePrincipal requires either -ClientSecret or -Certificate.'
            }
            $tenant = $TenantId
            $cid = $ClientId
            $sec = $ClientSecret
            $cert = $Certificate
            $provider = {
                param($Scope)
                $tokenUrl = "https://login.microsoftonline.com/$tenant/oauth2/v2.0/token"
                $form = @{
                    client_id  = $cid
                    grant_type = 'client_credentials'
                    scope      = $Scope
                }
                if ($cert) {
                    # Client assertion (cert) flow.
                    $jwt = New-FDAClientAssertion -ClientId $cid -TenantId $tenant -Certificate $cert
                    $form['client_assertion_type'] = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
                    $form['client_assertion'] = $jwt
                } else {
                    $plain = [System.Net.NetworkCredential]::new('', $sec).Password
                    $form['client_secret'] = $plain
                }
                $resp = Invoke-RestMethod -Method Post -Uri $tokenUrl -Body $form -ErrorAction Stop
                [pscustomobject]@{
                    Token     = $resp.access_token
                    ExpiresOn = (Get-Date).AddSeconds([int]$resp.expires_in)
                }
            }.GetNewClosure()
            $script:FDAState.TokenProviders['*'] = $provider
        }
        'ManagedIdentity' {
            $miCid = $ManagedIdentityClientId
            $provider = {
                param($Scope)
                # IMDS endpoint. resource = scope-without-/.default suffix.
                $resource = $Scope -replace '/\.default$', ''
                $imds = 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource={0}' -f [uri]::EscapeDataString($resource)
                if ($miCid) {
                    $imds += '&client_id=' + [uri]::EscapeDataString($miCid)
                }
                $headers = @{ Metadata = 'true' }
                # Azure Arc / App Service variants would use env-supplied endpoints. Detect:
                if ($env:IDENTITY_ENDPOINT -and $env:IDENTITY_HEADER) {
                    $imds = '{0}?resource={1}&api-version=2019-08-01' -f $env:IDENTITY_ENDPOINT, [uri]::EscapeDataString($resource)
                    if ($miCid) { $imds += '&client_id=' + [uri]::EscapeDataString($miCid) }
                    $headers = @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER }
                }
                $resp = Invoke-RestMethod -Method Get -Uri $imds -Headers $headers -ErrorAction Stop
                $expires = if ($resp.expires_on) {
                    [DateTimeOffset]::FromUnixTimeSeconds([long]$resp.expires_on).LocalDateTime
                } else {
                    (Get-Date).AddSeconds([int]$resp.expires_in)
                }
                [pscustomobject]@{
                    Token     = $resp.access_token
                    ExpiresOn = $expires
                }
            }.GetNewClosure()
            $script:FDAState.TokenProviders['*'] = $provider
        }
        'UserDelegated' {
            # Default to the Power BI / Azure PowerShell well-known public client
            # if no ClientId was supplied. Device code flow.
            if (-not $ClientId) { $ClientId = '1950a258-227b-4e31-a9cf-717495945fc8' }
            $cid = $ClientId
            $provider = {
                param($Scope)
                # Resolve the authority at call time: a specific tenant once one
                # has been selected, else 'organizations' so sign-in can proceed
                # before the tenant is known.
                $tenant = if ($script:FDAState.TenantId) { $script:FDAState.TenantId } else { 'organizations' }
                $deviceUrl = "https://login.microsoftonline.com/$tenant/oauth2/v2.0/devicecode"
                $form = @{ client_id = $cid; scope = $Scope }
                $dc = Invoke-RestMethod -Method Post -Uri $deviceUrl -Body $form -ErrorAction Stop
                Write-Host ''
                Write-Host '====================================================================='
                Write-Host 'Open a browser to:' -ForegroundColor Yellow
                Write-Host "    $($dc.verification_uri)" -ForegroundColor Cyan
                Write-Host 'And enter code:' -ForegroundColor Yellow
                Write-Host "    $($dc.user_code)" -ForegroundColor Cyan
                Write-Host '====================================================================='
                Write-Host ''
                $tokenUrl = "https://login.microsoftonline.com/$tenant/oauth2/v2.0/token"
                $deadline = (Get-Date).AddSeconds([int]$dc.expires_in)
                while ((Get-Date) -lt $deadline) {
                    Start-Sleep -Seconds ([int]$dc.interval)
                    $tokenForm = @{
                        client_id   = $cid
                        grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
                        device_code = $dc.device_code
                    }
                    try {
                        $resp = Invoke-RestMethod -Method Post -Uri $tokenUrl -Body $tokenForm -ErrorAction Stop
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
            }.GetNewClosure()
            $script:FDAState.TokenProviders['*'] = $provider
        }
    }

    $script:FDAState.Connected = $true

    # ---------------------------------------------------------------------
    # Resolve tenant / workspace / Eventhouse. Anything not supplied as a
    # parameter is selected interactively (this is where the device-code
    # sign-in happens for UserDelegated).
    # ---------------------------------------------------------------------

    # Tenant: only UserDelegated can discover/select interactively. SP uses
    # the supplied -TenantId; ManagedIdentity takes it from IMDS.
    if (-not $script:FDAState.TenantId -and $AuthMethod -eq 'UserDelegated') {
        Write-Verbose 'No TenantId supplied; signing in to resolve tenant...'
        $resolvedTenant = Resolve-FDATenant
        $script:FDAState.TenantId = $resolvedTenant
        # Drop any tokens acquired against the 'organizations' authority so
        # subsequent calls are issued against the selected tenant.
        $script:FDAState.TokenCache = @{}
        Write-Host "Using tenant: $resolvedTenant" -ForegroundColor Green
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
    $rsa = $Certificate.GetRSAPrivateKey()
    if (-not $rsa) { throw 'Certificate does not expose an RSA private key.' }
    $signature = $rsa.SignData([Text.Encoding]::UTF8.GetBytes($signingInput), [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $sigB64 = _b64url_bytes $signature
    "$signingInput.$sigB64"
}
