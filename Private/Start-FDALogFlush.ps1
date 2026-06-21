function Add-FDAFlushEntry {
    <#
    .SYNOPSIS
        Append a record to the in-memory flush buffer. Critical-level entries
        are flushed synchronously; everything else respects the batch policy.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $TableName,
        [Parameter(Mandatory)] [string] $MappingName,
        [Parameter(Mandatory)] [object] $Record,
        [int] $LevelNumeric = 30,
        [switch] $Synchronous
    )

    $entry = [pscustomobject]@{
        TableName    = $TableName
        MappingName  = $MappingName
        Record       = $Record
        LevelNumeric = $LevelNumeric
        QueuedAt     = (Get-Date)
    }

    if ($Synchronous -or $LevelNumeric -ge 90) {
        # Synchronous path for Critical and explicit override.
        Invoke-EventhouseIngest -TableName $TableName -MappingName $MappingName -Records @($Record) | Out-Null
        return
    }

    $script:FDAState.FlushLock.Wait()
    try {
        $script:FDAState.FlushBuffer.Add($entry)
        $bufferCount = $script:FDAState.FlushBuffer.Count
    } finally {
        $script:FDAState.FlushLock.Release() | Out-Null
    }

    # Honor BatchMaxEvents threshold.
    $batchMax = 100
    if ($script:FDAState.Config -and $script:FDAState.Config.BatchMaxEvents) {
        $batchMax = [int]$script:FDAState.Config.BatchMaxEvents
    }
    if ($bufferCount -ge $batchMax) {
        Invoke-FDAFlush
    }
}

function Invoke-FDAFlush {
    <#
    .SYNOPSIS
        Drain the flush buffer, grouping by (TableName, MappingName) into
        single ingest calls per table.
    #>
    [CmdletBinding()]
    param()
    $script:FDAState.FlushLock.Wait()
    try {
        $entries = @($script:FDAState.FlushBuffer.ToArray())
        $script:FDAState.FlushBuffer.Clear()
    } finally {
        $script:FDAState.FlushLock.Release() | Out-Null
    }
    if (-not $entries -or $entries.Count -eq 0) { return }

    $groups = $entries | Group-Object -Property TableName, MappingName
    foreach ($g in $groups) {
        $first = $g.Group | Select-Object -First 1
        $records = $g.Group | ForEach-Object { $_.Record }
        try {
            Invoke-EventhouseIngest -TableName $first.TableName -MappingName $first.MappingName -Records $records | Out-Null
        } catch {
            Write-Warning "Flush failed for $($first.TableName): $($_.Exception.Message)"
        }
    }
}

function Start-FDAFlushTimer {
    <#
    .SYNOPSIS
        Start a background timer that drains the flush buffer at a fixed cadence.
    #>
    [CmdletBinding()]
    param(
        [int] $IntervalSeconds = 5
    )
    if ($script:FDAState.FlushTimer) { return }

    $timer = New-Object System.Timers.Timer
    $timer.Interval = $IntervalSeconds * 1000
    $timer.AutoReset = $true
    $action = {
        try { Invoke-FDAFlush } catch { }
    }
    Register-ObjectEvent -InputObject $timer -EventName Elapsed -Action $action | Out-Null
    $timer.Start()
    $script:FDAState.FlushTimer = $timer
}

function Stop-FDAFlushTimer {
    [CmdletBinding()]
    param()
    if ($script:FDAState.FlushTimer) {
        try {
            $script:FDAState.FlushTimer.Stop()
            $script:FDAState.FlushTimer.Dispose()
        } catch { }
        $script:FDAState.FlushTimer = $null
    }
    # One final synchronous drain so we don't lose anything on disconnect.
    Invoke-FDAFlush
}
