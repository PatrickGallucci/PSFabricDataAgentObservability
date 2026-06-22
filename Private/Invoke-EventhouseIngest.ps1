function Invoke-EventhouseIngest {
    <#
    .SYNOPSIS
        Stream a single record (or an array of records) to an Eventhouse table.
    .DESCRIPTION
        Internal helper. Uses the Kusto streaming ingest REST endpoint with the
        JSON ingestion mapping configured in 03-ingestion-mappings.kql.
        Retries on transient failures with exponential backoff. Falls back to
        the disk spool when the cluster is unreachable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $TableName,
        [Parameter(Mandatory)]
        [string] $MappingName,
        [Parameter(Mandatory)]
        [object[]] $Records,
        [int] $MaxRetries = 3
    )

    if (-not $script:FDAState.EventhouseIngestUri) {
        throw 'Eventhouse ingest URI is not set. Call Initialize-FDAObservability and Connect-FDAObservability.'
    }

    # Serialize as multi-line JSON (JSONL).
    $body = ($Records | ForEach-Object {
        $_ | ConvertTo-Json -Compress -Depth 100
    }) -join "`n"

    $database = [uri]::EscapeDataString($script:FDAState.DatabaseName)
    $table = [uri]::EscapeDataString($TableName)
    $mapping = [uri]::EscapeDataString($MappingName)
    $url = '{0}/v1/rest/ingest/{1}/{2}?streamFormat=multijson&mappingName={3}' -f `
        $script:FDAState.EventhouseIngestUri.TrimEnd('/'), $database, $table, $mapping

    $attempt = 0
    $delaySec = 1
    while ($true) {
        $attempt++
        try {
            $token = Get-FDAAccessToken -Scope 'https://kusto.fabric.microsoft.com/.default'
            $headers = @{
                Authorization       = "Bearer $token"
                'Content-Type'      = 'application/json; charset=utf-8'
                'x-ms-client-version' = 'PSFabricDataAgentObservability/1.0.0'
                'x-ms-client-request-id' = [guid]::NewGuid().ToString()
            }
            $resp = Invoke-RestMethod -Method Post -Uri $url -Headers $headers -Body $body -ErrorAction Stop
            return $resp
        } catch {
            $sc = Get-FDAHttpStatusCode -ErrorRecord $_
            $isTransient = ($sc -in 408, 429, 500, 502, 503, 504) -or
                           ($_.Exception -is [System.Net.WebException]) -or
                           ($_.Exception.Message -match 'transient|timeout|temporarily')
            if ($attempt -ge $MaxRetries -or -not $isTransient) {
                # Spool to disk so we don't lose the events.
                try { Save-FDASpool -TableName $TableName -MappingName $MappingName -Records $Records } catch { Write-Verbose "Spool fallback failed: $($_.Exception.Message)" }
                throw "Eventhouse ingest failed after $attempt attempts: $($_.Exception.Message)"
            }
            Start-Sleep -Seconds $delaySec
            $delaySec = [Math]::Min($delaySec * 2, 30)
        }
    }
}

function Save-FDASpool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $TableName,
        [Parameter(Mandatory)] [string] $MappingName,
        [Parameter(Mandatory)] [object[]] $Records
    )
    $spoolDir = $script:FDAState.SpoolPath
    if (-not (Test-Path $spoolDir)) {
        New-Item -ItemType Directory -Path $spoolDir -Force | Out-Null
    }
    $fileName = '{0}_{1}_{2}.spool.json' -f `
        $TableName, $MappingName, [guid]::NewGuid().ToString()
    $path = Join-Path $spoolDir $fileName
    @{
        TableName   = $TableName
        MappingName = $MappingName
        Records     = $Records
        SpooledAt   = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json -Depth 100 | Set-Content -Path $path -Encoding UTF8
    Write-Verbose "Spooled $($Records.Count) records to $path"
}

function Restore-FDASpool {
    <#
    .SYNOPSIS
        Drain the local spool directory after connectivity is restored.
    #>
    [CmdletBinding()]
    param()
    $spoolDir = $script:FDAState.SpoolPath
    if (-not (Test-Path $spoolDir)) { return }
    $files = Get-ChildItem -Path $spoolDir -Filter '*.spool.json' -File -ErrorAction SilentlyContinue
    foreach ($f in $files) {
        try {
            $payload = Get-Content -Path $f.FullName -Raw | ConvertFrom-Json -Depth 100
            Invoke-EventhouseIngest -TableName $payload.TableName -MappingName $payload.MappingName -Records $payload.Records | Out-Null
            Remove-Item -Path $f.FullName -Force -ErrorAction SilentlyContinue
            Write-Verbose "Drained spool file $($f.Name)"
        } catch {
            Write-Warning "Could not drain spool file $($f.Name): $($_.Exception.Message)"
        }
    }
}
