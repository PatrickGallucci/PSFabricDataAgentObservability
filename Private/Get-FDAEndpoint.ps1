function Get-FDAEventhouseEndpoint {
    <#
    .SYNOPSIS
        Resolve the query+ingest endpoints for an Eventhouse via Fabric REST.
    .DESCRIPTION
        Calls GET /v1/workspaces/{workspaceId}/eventhouses/{eventhouseId}
        and parses out queryServiceUri / ingestionServiceUri.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $WorkspaceId,
        [Parameter(Mandatory)] [string] $EventhouseId
    )

    $url = 'https://api.fabric.microsoft.com/v1/workspaces/{0}/eventhouses/{1}' -f $WorkspaceId, $EventhouseId
    $token = Get-FDAAccessToken -Scope 'https://api.fabric.microsoft.com/.default'
    $headers = @{ Authorization = "Bearer $token" }
    $resp = Invoke-RestMethod -Method Get -Uri $url -Headers $headers -ErrorAction Stop

    $props = $resp.properties
    if (-not $props) {
        throw "Eventhouse $EventhouseId in workspace $WorkspaceId returned no properties."
    }

    [pscustomobject]@{
        EventhouseId        = $EventhouseId
        DisplayName         = $resp.displayName
        QueryServiceUri     = $props.queryServiceUri
        IngestionServiceUri = $props.ingestionServiceUri
        MinimumConsumptionUnits = $props.minimumConsumptionUnits
    }
}

function Get-FDAFabricCollection {
    <#
    .SYNOPSIS
        GET a paged Fabric REST collection, following continuationUri until
        the list is exhausted. Returns the flattened 'value' items.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Url)

    $token = Get-FDAAccessToken -Scope 'https://api.fabric.microsoft.com/.default'
    $headers = @{ Authorization = "Bearer $token" }
    $all = [System.Collections.Generic.List[object]]::new()
    $next = $Url
    while ($next) {
        $resp = Invoke-RestMethod -Method Get -Uri $next -Headers $headers -ErrorAction Stop
        if (($resp.PSObject.Properties.Name -contains 'value') -and $resp.value) {
            $all.AddRange(@($resp.value))
        }
        # continuationUri is only present while more pages remain.
        $next = $null
        if (($resp.PSObject.Properties.Name -contains 'continuationUri') -and $resp.continuationUri) {
            $next = $resp.continuationUri
        }
    }
    return $all
}

function Get-FDAWorkspaceList {
    <#
    .SYNOPSIS
        List the Fabric workspaces the caller can access.
    #>
    [CmdletBinding()]
    param()
    return Get-FDAFabricCollection -Url 'https://api.fabric.microsoft.com/v1/workspaces'
}

function Get-FDAEventhouseList {
    <#
    .SYNOPSIS
        List the Eventhouses in a Fabric workspace.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $WorkspaceId)
    $url = 'https://api.fabric.microsoft.com/v1/workspaces/{0}/eventhouses' -f $WorkspaceId
    return Get-FDAFabricCollection -Url $url
}

function Get-FDACapacityList {
    <#
    .SYNOPSIS
        List the Fabric capacities the caller can see (via Fabric REST).
    #>
    [CmdletBinding()]
    param()
    return Get-FDAFabricCollection -Url 'https://api.fabric.microsoft.com/v1/capacities'
}

function Resolve-FDACapacity {
    <#
    .SYNOPSIS
        Resolve a Fabric capacity to assign to a created / capacity-less
        workspace. An Eventhouse (Real-Time Intelligence) cannot be created in a
        workspace with no Fabric capacity (Fabric returns FeatureNotAvailable).
    .DESCRIPTION
        Resolution order:
          1. -CapacityId, if given (matched against the visible capacities).
          2. -CapacityName, if given (matched on displayName).
          3. The single Active capacity, when exactly one is visible.
        Otherwise throws with the list of candidates so the caller can set
        CapacityName in config.json (or pass -CapacityName / -CapacityId).
    #>
    [CmdletBinding()]
    param(
        [string] $CapacityId,
        [string] $CapacityName
    )

    $all    = @(Get-FDACapacityList)
    # Prefer Active capacities; fall back to the full list if state is absent.
    $active = @($all | Where-Object { -not ($_.PSObject.Properties.Name -contains 'state') -or $_.state -eq 'Active' })

    if ($CapacityId) {
        $hit = $all | Where-Object { $_.id -eq $CapacityId } | Select-Object -First 1
        if (-not $hit) { throw "Capacity id '$CapacityId' was not found among the capacities you can access." }
        return $hit
    }
    if ($CapacityName) {
        $hit = $all | Where-Object { $_.displayName -eq $CapacityName } | Select-Object -First 1
        if (-not $hit) {
            $names = ($all | ForEach-Object displayName) -join ', '
            throw "Capacity '$CapacityName' was not found. Available: $names"
        }
        return $hit
    }
    if ($active.Count -eq 1) { return $active[0] }
    if ($active.Count -eq 0) {
        throw 'No Fabric capacity is available to host the workspace. An Eventhouse requires a workspace on a Fabric (F-SKU) or Trial capacity. Assign a capacity in the Fabric portal, then retry.'
    }
    $names = ($active | ForEach-Object displayName) -join ', '
    throw "Multiple Fabric capacities are available ($names). Set 'CapacityName' in config.json or pass -CapacityName to choose one."
}

function Set-FDAWorkspaceCapacity {
    <#
    .SYNOPSIS
        Assign a Fabric workspace to a capacity (POST .../assignToCapacity).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $WorkspaceId,
        [Parameter(Mandatory)] [string] $CapacityId
    )
    $url = 'https://api.fabric.microsoft.com/v1/workspaces/{0}/assignToCapacity' -f $WorkspaceId
    $token = Get-FDAAccessToken -Scope 'https://api.fabric.microsoft.com/.default'
    $headers = @{
        Authorization  = "Bearer $token"
        'Content-Type' = 'application/json; charset=utf-8'
    }
    $body = @{ capacityId = $CapacityId } | ConvertTo-Json
    if ($PSCmdlet.ShouldProcess($WorkspaceId, "Assign to capacity $CapacityId")) {
        Invoke-RestMethod -Method Post -Uri $url -Headers $headers -Body $body -ErrorAction Stop | Out-Null
    }
}

function New-FDAWorkspace {
    <#
    .SYNOPSIS
        Create a new Fabric workspace, optionally on a specific capacity.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $DisplayName,
        [string] $Description = 'Created by PSFabricDataAgentObservability.',
        [string] $CapacityId
    )
    $url = 'https://api.fabric.microsoft.com/v1/workspaces'
    $token = Get-FDAAccessToken -Scope 'https://api.fabric.microsoft.com/.default'
    $headers = @{
        Authorization  = "Bearer $token"
        'Content-Type' = 'application/json; charset=utf-8'
    }
    $payload = @{ displayName = $DisplayName; description = $Description }
    # Create the workspace directly on a capacity so it can host an Eventhouse.
    if ($CapacityId) { $payload.capacityId = $CapacityId }
    $body = $payload | ConvertTo-Json
    if ($PSCmdlet.ShouldProcess($DisplayName, 'Create Fabric workspace')) {
        return Invoke-RestMethod -Method Post -Uri $url -Headers $headers -Body $body -ErrorAction Stop
    }
}

function New-FDAEventhouse {
    <#
    .SYNOPSIS
        Provision a new Eventhouse in the given Fabric workspace.
    .DESCRIPTION
        Used by Initialize-FDAObservability -CreateEventhouse.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $WorkspaceId,
        [Parameter(Mandatory)] [string] $DisplayName,
        [string] $Description = 'Created by PSFabricDataAgentObservability for FDA capture logging.'
    )

    $url = 'https://api.fabric.microsoft.com/v1/workspaces/{0}/eventhouses' -f $WorkspaceId
    $token = Get-FDAAccessToken -Scope 'https://api.fabric.microsoft.com/.default'
    $headers = @{
        Authorization  = "Bearer $token"
        'Content-Type' = 'application/json; charset=utf-8'
    }
    $body = @{ displayName = $DisplayName; description = $Description } | ConvertTo-Json
    if ($PSCmdlet.ShouldProcess("Workspace $WorkspaceId", "Create Eventhouse '$DisplayName'")) {
        $resp = Invoke-RestMethod -Method Post -Uri $url -Headers $headers -Body $body -ErrorAction Stop
        return $resp
    }
}

function Invoke-KustoManagementCommand {
    <#
    .SYNOPSIS
        Execute a Kusto management ("dot") command against the Eventhouse
        cluster endpoint. Used by Initialize-FDAObservability to apply schema.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Command,
        [string] $Database = $script:FDAState.DatabaseName
    )
    if (-not $script:FDAState.EventhouseClusterUri) {
        throw 'Eventhouse cluster URI is not set. Call Connect-FDAObservability first.'
    }
    $url = '{0}/v1/rest/mgmt' -f $script:FDAState.EventhouseClusterUri.TrimEnd('/')
    $token = Get-FDAAccessToken -Scope 'https://kusto.fabric.microsoft.com/.default'
    $headers = @{
        Authorization  = "Bearer $token"
        'Content-Type' = 'application/json; charset=utf-8'
        'x-ms-client-request-id' = [guid]::NewGuid().ToString()
    }
    $body = @{ db = $Database; csl = $Command } | ConvertTo-Json -Depth 10
    return Invoke-RestMethod -Method Post -Uri $url -Headers $headers -Body $body -ErrorAction Stop
}
