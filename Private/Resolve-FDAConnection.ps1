function Read-FDASelection {
    <#
    .SYNOPSIS
        Prompt for a numeric menu choice and re-prompt until it is in range.
    .PARAMETER Max
        Highest valid number.
    .PARAMETER Prompt
        Text shown to the user.
    .PARAMETER AllowZero
        Permit 0 (used for the '<create new>' menu entry).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int] $Max,
        [Parameter(Mandatory)] [string] $Prompt,
        [switch] $AllowZero
    )
    $low = if ($AllowZero) { 0 } else { 1 }
    while ($true) {
        $raw = Read-Host $Prompt
        if ($raw -match '^\s*\d+\s*$') {
            $n = [int]$raw.Trim()
            if ($n -ge $low -and $n -le $Max) { return $n }
        }
        Write-Host "Please enter a number between $low and $Max." -ForegroundColor Red
    }
}

function Get-FDATokenTenantId {
    <#
    .SYNOPSIS
        Best-effort: read the 'tid' (tenant) claim out of a Fabric access token.
        Used as a fallback when ARM tenant enumeration is unavailable.
    #>
    [CmdletBinding()]
    param()
    try {
        $token = Get-FDAAccessToken -Scope 'https://api.fabric.microsoft.com/.default'
        $parts = $token.Split('.')
        if ($parts.Count -lt 2) { return $null }
        $payload = $parts[1].Replace('-', '+').Replace('_', '/')
        switch ($payload.Length % 4) {
            2 { $payload += '==' }
            3 { $payload += '=' }
        }
        $json = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($payload))
        $claims = $json | ConvertFrom-Json
        if ($claims.PSObject.Properties.Name -contains 'tid') { return $claims.tid }
        return $null
    } catch {
        Write-Verbose "Could not decode tenant from token: $($_.Exception.Message)"
        return $null
    }
}

function Resolve-FDATenant {
    <#
    .SYNOPSIS
        Determine which tenant to operate against after an interactive sign-in.
    .DESCRIPTION
        Enumerates the tenants the signed-in user can access via Azure Resource
        Manager. If exactly one is found it is used automatically; if several
        are found the user is prompted to pick one. If ARM is inaccessible
        (e.g. the user has no Azure RBAC), falls back to the tenant ('tid')
        claim on a Fabric token.
    #>
    [CmdletBinding()]
    param()

    $tenants = @()
    try {
        $armToken = Get-FDAAccessToken -Scope 'https://management.azure.com/.default'
        $resp = Invoke-RestMethod -Method Get `
            -Uri 'https://management.azure.com/tenants?api-version=2020-01-01' `
            -Headers @{ Authorization = "Bearer $armToken" } -ErrorAction Stop
        if (($resp.PSObject.Properties.Name -contains 'value') -and $resp.value) {
            $tenants = @($resp.value)
        }
    } catch {
        Write-Verbose "ARM tenant enumeration unavailable: $($_.Exception.Message)"
    }

    if ($tenants.Count -eq 0) {
        $tid = Get-FDATokenTenantId
        if ($tid) {
            Write-Verbose "Falling back to token tenant claim: $tid"
            return $tid
        }
        throw 'Unable to determine a tenant automatically. Re-run with -TenantId.'
    }

    if ($tenants.Count -eq 1) {
        return $tenants[0].tenantId
    }

    Write-Host ''
    Write-Host 'You have access to multiple tenants:' -ForegroundColor Yellow
    for ($i = 0; $i -lt $tenants.Count; $i++) {
        $t = $tenants[$i]
        $name = if ($t.PSObject.Properties.Name -contains 'displayName' -and $t.displayName) {
            $t.displayName
        } elseif ($t.PSObject.Properties.Name -contains 'defaultDomain' -and $t.defaultDomain) {
            $t.defaultDomain
        } else {
            '(unnamed)'
        }
        Write-Host ('  [{0}] {1}  ({2})' -f ($i + 1), $name, $t.tenantId)
    }
    $sel = Read-FDASelection -Max $tenants.Count -Prompt 'Select tenant number'
    return $tenants[$sel - 1].tenantId
}

function Resolve-FDAWorkspace {
    <#
    .SYNOPSIS
        Prompt the user to select an existing Fabric workspace or create one.
        Returns the chosen workspace id.
    #>
    [CmdletBinding()]
    param()

    $workspaces = @(Get-FDAWorkspaceList)

    Write-Host ''
    Write-Host 'Fabric workspaces:' -ForegroundColor Yellow
    Write-Host '  [0] <Create a new workspace>'
    for ($i = 0; $i -lt $workspaces.Count; $i++) {
        Write-Host ('  [{0}] {1}  ({2})' -f ($i + 1), $workspaces[$i].displayName, $workspaces[$i].id)
    }

    $sel = Read-FDASelection -Max $workspaces.Count -Prompt 'Select workspace number (0 to create new)' -AllowZero
    if ($sel -eq 0) {
        $name = Read-Host 'New workspace display name'
        if (-not $name) { throw 'A workspace display name is required.' }
        Write-Verbose "Creating workspace '$name'..."
        $ws = New-FDAWorkspace -DisplayName $name
        if (-not $ws -or -not $ws.id) { throw "Workspace '$name' was not created." }
        Write-Host "Created workspace: $($ws.displayName) ($($ws.id))" -ForegroundColor Green
        return $ws.id
    }
    return $workspaces[$sel - 1].id
}

function Resolve-FDAEventhouse {
    <#
    .SYNOPSIS
        Prompt the user to select an existing Eventhouse in the workspace or
        create one. Returns the chosen Eventhouse id, waiting for endpoints to
        materialize when a new Eventhouse is provisioned.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $WorkspaceId)

    $eventhouses = @(Get-FDAEventhouseList -WorkspaceId $WorkspaceId)

    Write-Host ''
    Write-Host 'Eventhouses in the selected workspace:' -ForegroundColor Yellow
    Write-Host '  [0] <Create a new Eventhouse>'
    for ($i = 0; $i -lt $eventhouses.Count; $i++) {
        Write-Host ('  [{0}] {1}  ({2})' -f ($i + 1), $eventhouses[$i].displayName, $eventhouses[$i].id)
    }

    $sel = Read-FDASelection -Max $eventhouses.Count -Prompt 'Select Eventhouse number (0 to create new)' -AllowZero
    if ($sel -ne 0) {
        return $eventhouses[$sel - 1].id
    }

    $name = Read-Host 'New Eventhouse display name'
    if (-not $name) { throw 'An Eventhouse display name is required.' }
    Write-Verbose "Creating Eventhouse '$name' in workspace $WorkspaceId..."
    $eh = New-FDAEventhouse -WorkspaceId $WorkspaceId -DisplayName $name
    if (-not $eh -or -not $eh.id) { throw "Eventhouse '$name' was not created." }
    $eventhouseId = $eh.id

    # Endpoints are provisioned asynchronously; wait for them so the caller can
    # immediately resolve the query/ingest URIs.
    Write-Host 'Waiting for Eventhouse endpoints to become available...' -ForegroundColor DarkGray
    $deadline = (Get-Date).AddMinutes(5)
    do {
        Start-Sleep -Seconds 5
        $endpoints = Get-FDAEventhouseEndpoint -WorkspaceId $WorkspaceId -EventhouseId $eventhouseId
        if ($endpoints.QueryServiceUri) { break }
    } while ((Get-Date) -lt $deadline)
    if (-not $endpoints.QueryServiceUri) {
        throw 'Eventhouse created but endpoints did not materialize within 5 minutes.'
    }
    Write-Host "Created Eventhouse: $($endpoints.DisplayName) ($eventhouseId)" -ForegroundColor Green
    return $eventhouseId
}
