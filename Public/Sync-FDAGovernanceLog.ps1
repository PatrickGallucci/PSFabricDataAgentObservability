function Sync-FDAGovernanceLog {
    <#
    .SYNOPSIS
        Pull recent Fabric/Power BI activity events from the M365 Unified
        Audit Log and persist as FDAAuthEvents.

    .DESCRIPTION
        Uses Office 365 Management Activity API
        (https://manage.office.com/api/v1.0/{tenantId}/activity/feed/...).
        Filters to Fabric/Power BI operations. Designed to be invoked on a
        schedule (Azure Function, Automation Runbook, or Register-ScheduledJob).

        Per-tenant subscription to the Audit.General content type must be
        enabled. This cmdlet will subscribe if absent.

    .PARAMETER LookbackHours
        How far back to pull. Default 24.
    #>
    [CmdletBinding()]
    param(
        [int] $LookbackHours = 24,
        [string[]] $Operations = @(
            'GetDataAgent', 'CreateDataAgent', 'UpdateDataAgent', 'DeleteDataAgent',
            'GetDataset', 'ExecuteQueryOnDataset',
            'AnalyzedByExternalApplication'
        )
    )
    if (-not $script:FDAState.Connected) {
        throw 'Not connected. Call Connect-FDAObservability first.'
    }
    $tenantId = $script:FDAState.TenantId
    if (-not $tenantId) { throw 'TenantId is required (set during Connect-FDAObservability).' }

    $base = "https://manage.office.com/api/v1.0/$tenantId/activity/feed"
    $token = Get-FDAAccessToken -Scope 'https://manage.office.com/.default'
    $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }

    # Ensure subscription exists.
    $startUrl = "$base/subscriptions/start?contentType=Audit.General"
    try { Invoke-RestMethod -Method Post -Uri $startUrl -Headers $headers -ErrorAction Stop | Out-Null }
    catch { Write-Verbose "Subscription start returned: $($_.Exception.Message) (may already be active)." }

    $startTime = (Get-Date).ToUniversalTime().AddHours(-1 * $LookbackHours).ToString('yyyy-MM-ddTHH:mm:ss')
    $endTime   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss')
    $contentUrl = "$base/subscriptions/content?contentType=Audit.General&startTime=$startTime&endTime=$endTime"

    $pages = @()
    do {
        $resp = Invoke-WebRequest -Method Get -Uri $contentUrl -Headers $headers -ErrorAction Stop
        $pageItems = $resp.Content | ConvertFrom-Json
        if ($pageItems) { $pages += $pageItems }
        $nextLink = $resp.Headers['NextPageUri']
        $contentUrl = if ($nextLink) { [string]$nextLink } else { $null }
    } while ($contentUrl)

    $count = 0
    foreach ($contentRef in $pages) {
        try {
            $events = Invoke-RestMethod -Method Get -Uri $contentRef.contentUri -Headers $headers -ErrorAction Stop
        } catch {
            Write-Warning "Failed to download $($contentRef.contentUri): $($_.Exception.Message)"
            continue
        }
        $batch = foreach ($e in $events) {
            if ($Operations -and $Operations.Count -gt 0 -and ($e.Operation -notin $Operations)) { continue }
            [pscustomobject]@{
                Timestamp         = ([datetime]$e.CreationTime).ToUniversalTime().ToString('o')
                EventId           = [string]$e.Id
                CorrelationId     = [string]$e.CorrelationId
                TenantId          = [string]$e.OrganizationId
                UserPrincipalName = [string]$e.UserId
                ClientApp         = [string]$e.ClientIP
                AuthMethod        = [string]$e.UserType
                Outcome           = if ($e.ResultStatus -in 'Succeeded', 'Success') { 'Success' } else { 'Failure' }
                ConsentStatus     = [string]$e.ConsentStatus
                RLSContext        = $e.RLSContext
                IPAddress         = [string]$e.ClientIP
                UserAgent         = [string]$e.UserAgent
                Source            = 'M365Audit'
                LevelName         = if ($e.ResultStatus -in 'Succeeded', 'Success') { 'Information' } else { 'Warning' }
                LevelNumeric      = if ($e.ResultStatus -in 'Succeeded', 'Success') { 30 } else { 50 }
                Metadata          = @{ Operation = $e.Operation; Workload = $e.Workload }
            }
        }
        if ($batch -and $batch.Count -gt 0) {
            Invoke-EventhouseIngest -TableName 'FDAAuthEventsRaw' -MappingName 'FDAAuthEventsRawMapping' -Records $batch | Out-Null
            $count += $batch.Count
        }
    }

    [pscustomobject]@{
        Synced       = $count
        WindowHours  = $LookbackHours
        StartTimeUtc = $startTime
        EndTimeUtc   = $endTime
    }
}
