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
        [string] $Description = 'Created by FabricDataAgentObservability for FDA capture logging.'
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
