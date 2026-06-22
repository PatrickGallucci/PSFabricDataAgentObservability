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

function Resolve-FDATenant {
    <#
    .SYNOPSIS
        Prompt for the Entra tenant to sign in to and return it.
    .DESCRIPTION
        The device-code flow used by UserDelegated auth must target a concrete
        tenant: the raw v2.0 /devicecode endpoint rejects the tenant-less
        'organizations' and 'common' authorities with AADSTS50059 ("No
        tenant-identifying information found"). Tenant discovery therefore can't
        happen before sign-in (it would itself need a token), so when no tenant
        was supplied we ask for one here.

        Accepts either a tenant ID (GUID) or a verified domain
        (e.g. contoso.onmicrosoft.com) — both are valid sign-in authorities.
    #>
    [CmdletBinding()]
    param()

    Write-Host ''
    Write-Host 'No tenant was specified. Enter the tenant to sign in to:' -ForegroundColor Yellow
    Write-Host '  - a tenant ID (GUID), or' -ForegroundColor Yellow
    Write-Host '  - a verified domain, e.g. contoso.onmicrosoft.com' -ForegroundColor Yellow

    $tenant = ''
    while (-not $tenant) {
        $tenant = (Read-Host 'Tenant ID or domain').Trim()
    }
    return $tenant
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
