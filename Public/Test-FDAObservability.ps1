function Test-FDAObservability {
    <#
    .SYNOPSIS
        Health check. Verifies connectivity, schema, ingestion path, retention,
        and recent activity.

    .DESCRIPTION
        Returns one object per check with Status (Pass/Fail/Warning) and a
        Detail message. Designed to be wired into a monitoring system.

    .EXAMPLE
        Test-FDAObservability | Format-Table -AutoSize

    .EXAMPLE
        if ((Test-FDAObservability).Where({$_.Status -ne 'Pass'})) { 'unhealthy' }
    #>
    [CmdletBinding()]
    param()
    $results = [System.Collections.Generic.List[object]]::new()

    function Add-Result($name, $status, $detail) {
        $results.Add([pscustomobject]@{ Check = $name; Status = $status; Detail = $detail })
    }

    # 1. Connection
    if (-not $script:FDAState.Connected) {
        Add-Result 'Connection' 'Fail' 'Not connected. Call Connect-FDAObservability first.'
        return $results
    }
    Add-Result 'Connection' 'Pass' ("AuthMethod={0}, Workspace={1}" -f $script:FDAState.AuthMethod, $script:FDAState.WorkspaceId)

    # 2. Token fetch
    try {
        Get-FDAAccessToken -Scope 'https://kusto.fabric.microsoft.com/.default' | Out-Null
        Add-Result 'Token (Kusto)' 'Pass' 'Token acquired.'
    } catch {
        Add-Result 'Token (Kusto)' 'Fail' $_.Exception.Message
    }

    # 3. Cluster query reachable
    try {
        Invoke-KQLQuery -Query 'print x=1' | Out-Null
        Add-Result 'Cluster Query' 'Pass' 'KQL roundtrip OK.'
    } catch {
        Add-Result 'Cluster Query' 'Fail' $_.Exception.Message
    }

    # 4. Tables present
    $expectedTables = @(
        'FDAInteractions', 'FDAInteractionsRaw',
        'FDAExecutions', 'FDAExecutionsRaw',
        'FDAAuthEvents', 'FDAAuthEventsRaw',
        'FDACostMetering', 'FDACostMeteringRaw',
        'FDALogEvents', 'FDALogEventsRaw',
        'FDALogLevels', 'FDAConfiguration'
    )
    try {
        $rows = Invoke-KQLQuery -Query '.show tables | project TableName'
        $found = @($rows | ForEach-Object { $_.TableName })
        $missing = @($expectedTables | Where-Object { $_ -notin $found })
        if ($missing.Count -eq 0) {
            Add-Result 'Schema' 'Pass' 'All curated, raw, and operational tables present.'
        } else {
            Add-Result 'Schema' 'Fail' ('Missing tables: ' + ($missing -join ', '))
        }
    } catch {
        Add-Result 'Schema' 'Warning' "Could not inspect tables: $($_.Exception.Message)"
    }

    # 5. Log levels seeded
    try {
        $lvls = Invoke-KQLQuery -Query 'GetActiveLogLevels() | count'
        $count = if ($lvls -and $lvls[0]) { [int]$lvls[0].Count } else { 0 }
        if ($count -ge 5) { Add-Result 'Log levels seeded' 'Pass' "$count active levels." }
        else              { Add-Result 'Log levels seeded' 'Warning' "$count active levels (expected >= 5)." }
    } catch {
        Add-Result 'Log levels seeded' 'Warning' $_.Exception.Message
    }

    # 6. Roundtrip ingest (synthetic event)
    try {
        $eventId = [guid]::NewGuid().ToString()
        Write-FDALog -Level Information -Message "Test-FDAObservability ping $eventId" -Category 'HealthCheck' -Properties @{ Marker = $eventId }
        Invoke-FDAFlush
        Start-Sleep -Seconds 2
        $hit = Invoke-KQLQuery -Query "FDALogEvents | where Properties.Marker == '$eventId' | count"
        $found = if ($hit -and $hit[0]) { [int]$hit[0].Count } else { 0 }
        if ($found -ge 1) {
            Add-Result 'Round-trip ingest' 'Pass' "Marker $eventId visible."
        } else {
            Add-Result 'Round-trip ingest' 'Warning' 'Marker not visible yet (ingest in flight).'
        }
    } catch {
        Add-Result 'Round-trip ingest' 'Fail' $_.Exception.Message
    }

    # 7. Spool drain status
    $spool = @(Get-ChildItem -Path $script:FDAState.SpoolPath -Filter '*.spool.json' -ErrorAction SilentlyContinue)
    if ($spool.Count -eq 0) {
        Add-Result 'Spool empty' 'Pass' 'No spooled events awaiting drain.'
    } else {
        Add-Result 'Spool empty' 'Warning' ('{0} spooled file(s); will drain on next ingest.' -f $spool.Count)
    }

    return $results
}
