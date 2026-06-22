function Get-FDAServicePrincipalToken {
    <#
    .SYNOPSIS
        Acquire an app-only (client-credentials) token for a scope using the
        Service Principal configuration in module state.
    .DESCRIPTION
        Supports both secret-based and certificate-based (client-assertion)
        auth. Reads ClientId / ClientSecret / Certificate / TenantId from
        $script:FDAState so the provider scriptblock stays a plain,
        module-affiliated block (see Connect-FDAObservability for why this
        matters — closures cannot resolve module-private functions such as
        New-FDAClientAssertion).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Scope)

    $tenant = $script:FDAState.TenantId
    $cid    = $script:FDAState.ClientId
    $sec    = $script:FDAState.ClientSecret
    $cert   = $script:FDAState.Certificate

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
}

function Get-FDAManagedIdentityToken {
    <#
    .SYNOPSIS
        Acquire a Managed Identity token for a scope via IMDS, honoring the
        App Service / Azure Arc IDENTITY_ENDPOINT variant when present.
    .DESCRIPTION
        Reads the optional user-assigned MI client id from module state.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Scope)

    $miCid = $script:FDAState.ManagedIdentityClientId
    # IMDS endpoint. resource = scope-without-/.default suffix.
    $resource = $Scope -replace '/\.default$', ''
    $imds = 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource={0}' -f [uri]::EscapeDataString($resource)
    if ($miCid) {
        $imds += '&client_id=' + [uri]::EscapeDataString($miCid)
    }
    $headers = @{ Metadata = 'true' }
    # Azure Arc / App Service variants use env-supplied endpoints. Detect:
    if ($env:IDENTITY_ENDPOINT -and $env:IDENTITY_HEADER) {
        $imds = '{0}?resource={1}&api-version=2019-08-01' -f $env:IDENTITY_ENDPOINT, [uri]::EscapeDataString($resource)
        if ($miCid) { $imds += '&client_id=' + [uri]::EscapeDataString($miCid) }
        $headers = @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER }
    }
    $resp = Invoke-RestMethod -Method Get -Uri $imds -Headers $headers -ErrorAction Stop
    $expires = if (($resp.PSObject.Properties.Name -contains 'expires_on') -and $resp.expires_on) {
        [DateTimeOffset]::FromUnixTimeSeconds([long]$resp.expires_on).LocalDateTime
    } else {
        (Get-Date).AddSeconds([int]$resp.expires_in)
    }
    [pscustomobject]@{
        Token     = $resp.access_token
        ExpiresOn = $expires
    }
}
