function Invoke-KQLQuery {
    <#
    .SYNOPSIS
        Execute a KQL query against the FDAObs Eventhouse database.
    .DESCRIPTION
        Returns rows as a PSCustomObject array. The Kusto query response is
        translated from its native "Tables" shape into a flat object array
        matching the primary result table (Table_0 / "PrimaryResult").
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Query,
        [hashtable] $Parameters,
        [string] $Database = $script:FDAState.DatabaseName,
        [int] $MaxRetries = 3
    )

    if (-not $script:FDAState.EventhouseClusterUri) {
        throw 'Eventhouse cluster URI is not set. Call Initialize-FDAObservability and Connect-FDAObservability.'
    }

    $url = '{0}/v1/rest/query' -f $script:FDAState.EventhouseClusterUri.TrimEnd('/')
    $bodyObj = @{
        db  = $Database
        csl = $Query
    }
    if ($Parameters) {
        # Kusto query parameters are passed via "Properties.Parameters" as a
        # JSON-encoded string. The KQL itself must start with
        # "declare query_parameters(name:type, ...);"
        $declared = ($Parameters.Keys | ForEach-Object { "$_:string" }) -join ', '
        $bodyObj.csl = "declare query_parameters($declared);`n$Query"
        $bodyObj.properties = @{
            Parameters = $Parameters
        }
    }
    $body = $bodyObj | ConvertTo-Json -Depth 10 -Compress

    $attempt = 0
    $delaySec = 1
    while ($true) {
        $attempt++
        try {
            $token = Get-FDAAccessToken -Scope 'https://kusto.fabric.microsoft.com/.default'
            $headers = @{
                Authorization            = "Bearer $token"
                'Content-Type'           = 'application/json; charset=utf-8'
                'x-ms-client-request-id' = [guid]::NewGuid().ToString()
            }
            $resp = Invoke-RestMethod -Method Post -Uri $url -Headers $headers -Body $body -ErrorAction Stop
            break
        } catch {
            $sc = Get-FDAHttpStatusCode -ErrorRecord $_
            $isTransient = ($sc -in 408, 429, 500, 502, 503, 504) -or
                           ($_.Exception -is [System.Net.WebException])
            if ($attempt -ge $MaxRetries -or -not $isTransient) {
                throw "KQL query failed after $attempt attempts: $($_.Exception.Message)"
            }
            Start-Sleep -Seconds $delaySec
            $delaySec = [Math]::Min($delaySec * 2, 30)
        }
    }

    # Translate Kusto response to PSCustomObject[].
    $primary = $resp.Tables | Where-Object { $_.TableName -in 'PrimaryResult', 'Table_0' } | Select-Object -First 1
    if (-not $primary) {
        $primary = $resp.Tables | Select-Object -First 1
    }
    if (-not $primary -or -not $primary.Rows) {
        return @()
    }
    # Force array so .Count is safe for single-column results (e.g. "... | count").
    $cols = @($primary.Columns | ForEach-Object { $_.ColumnName })
    $out = foreach ($row in $primary.Rows) {
        $ht = [ordered]@{}
        for ($i = 0; $i -lt $cols.Count; $i++) {
            $ht[$cols[$i]] = $row[$i]
        }
        [pscustomobject]$ht
    }
    return $out
}
