function Initialize-FDAObservability {
    <#
    .SYNOPSIS
        Provision the FDAObs Eventhouse database, tables, mappings, policies,
        functions, and seed levels in one call.
    .DESCRIPTION
        Idempotent. Safe to re-run after schema changes — uses
        .create-merge / .create-or-alter throughout.

        Three modes:
          1. Use an existing Eventhouse:   -EventhouseId <guid>
          2. Provision the Eventhouse:     -CreateEventhouse -EventhouseName <name>
          3. Interactive: omit -WorkspaceId and/or -EventhouseId and you are
             prompted to select an existing Fabric workspace / Eventhouse or
             create a new one.

    .PARAMETER WorkspaceId
        Target Fabric workspace id. Optional — when omitted you are prompted to
        select an existing workspace or create a new one.

    .PARAMETER EventhouseId
        Existing Eventhouse item id. Omit when -CreateEventhouse is set. When
        omitted without -CreateEventhouse you are prompted to select an
        existing Eventhouse or create a new one.

    .PARAMETER CreateEventhouse
        Provision a new Eventhouse in -WorkspaceId.

    .PARAMETER EventhouseName
        Display name for the new Eventhouse. Required with -CreateEventhouse.

    .PARAMETER DatabaseName
        KQL database name. Defaults to 'FDAObs'.

    .PARAMETER SchemaPath
        Folder containing the numbered .kql files. Defaults to the module's
        Schema/ folder.

    .EXAMPLE
        Initialize-FDAObservability -WorkspaceId 'w...' -EventhouseId 'e...'

    .EXAMPLE
        Initialize-FDAObservability -WorkspaceId 'w...' -CreateEventhouse `
            -EventhouseName 'FDAObservabilityProd'

    .EXAMPLE
        # Interactive: pick (or create) the workspace and Eventhouse, then provision.
        Initialize-FDAObservability
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Existing')]
    param(
        [string] $WorkspaceId,

        [Parameter(ParameterSetName = 'Existing')]
        [string] $EventhouseId,

        [Parameter(Mandatory, ParameterSetName = 'Create')]
        [switch] $CreateEventhouse,

        [Parameter(Mandatory, ParameterSetName = 'Create')]
        [string] $EventhouseName,

        [string] $DatabaseName = 'FDAObs',

        [string] $SchemaPath = (Join-Path $PSScriptRoot '..' 'Schema')
    )

    if (-not $script:FDAState.Connected) {
        throw 'Not connected. Call Connect-FDAObservability first (you can connect against any Eventhouse in the workspace, then Initialize will resolve / create the target).'
    }

    # Resolve the workspace — select or create interactively when not supplied.
    if (-not $WorkspaceId) {
        $WorkspaceId = Resolve-FDAWorkspace
    }

    # Resolve or create the Eventhouse.
    if ($PSCmdlet.ParameterSetName -eq 'Create') {
        Write-Verbose "Creating Eventhouse '$EventhouseName' in workspace $WorkspaceId..."
        $eh = New-FDAEventhouse -WorkspaceId $WorkspaceId -DisplayName $EventhouseName
        $EventhouseId = $eh.id
        # Wait for endpoints to materialize.
        $deadline = (Get-Date).AddMinutes(5)
        do {
            Start-Sleep -Seconds 5
            $endpoints = Get-FDAEventhouseEndpoint -WorkspaceId $WorkspaceId -EventhouseId $EventhouseId
            if ($endpoints.QueryServiceUri) { break }
        } while ((Get-Date) -lt $deadline)
        if (-not $endpoints.QueryServiceUri) {
            throw 'Eventhouse created but endpoints did not materialize within 5 minutes.'
        }
        Write-Verbose "Eventhouse created: $($endpoints.DisplayName) ($EventhouseId)"
    } else {
        # Select an existing Eventhouse or create one interactively when not supplied.
        if (-not $EventhouseId) {
            $EventhouseId = Resolve-FDAEventhouse -WorkspaceId $WorkspaceId
        }
        $endpoints = Get-FDAEventhouseEndpoint -WorkspaceId $WorkspaceId -EventhouseId $EventhouseId
    }

    # Switch the module to point at the resolved Eventhouse.
    $script:FDAState.WorkspaceId = $WorkspaceId
    $script:FDAState.EventhouseId = $EventhouseId
    $script:FDAState.EventhouseClusterUri = $endpoints.QueryServiceUri
    $script:FDAState.EventhouseIngestUri = $endpoints.IngestionServiceUri
    $script:FDAState.DatabaseName = $DatabaseName

    # Create the KQL database via Fabric REST.
    $dbUrl = 'https://api.fabric.microsoft.com/v1/workspaces/{0}/eventhouses/{1}/databases' -f $WorkspaceId, $EventhouseId
    $token = Get-FDAAccessToken -Scope 'https://api.fabric.microsoft.com/.default'
    $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json; charset=utf-8' }
    $createDb = $true
    try {
        $existing = Invoke-RestMethod -Method Get -Uri $dbUrl -Headers $headers -ErrorAction Stop
        if ($existing.value | Where-Object { $_.displayName -eq $DatabaseName }) {
            $createDb = $false
            Write-Verbose "Database '$DatabaseName' already exists."
        }
    } catch {
        Write-Verbose "Could not list databases: $($_.Exception.Message)"
    }
    if ($createDb -and $PSCmdlet.ShouldProcess($EventhouseId, "Create KQL database '$DatabaseName'")) {
        $body = @{ displayName = $DatabaseName; properties = @{ databaseType = 'ReadWrite' } } | ConvertTo-Json
        try {
            Invoke-RestMethod -Method Post -Uri $dbUrl -Headers $headers -Body $body -ErrorAction Stop | Out-Null
            Start-Sleep -Seconds 5  # allow propagation
        } catch {
            Write-Warning "Database create returned non-success (may already exist): $($_.Exception.Message)"
        }
    }

    # Apply schema. Skip 01 (database creation; handled above) and 07 (seed levels) here;
    # we ingest seed levels via the operational ingest path so timestamps are current.
    $scriptOrder = @(
        '02-create-tables.kql',
        '03-ingestion-mappings.kql',
        '04-update-policies.kql',
        '05-retention-policies.kql',
        '06-functions.kql'
    )
    foreach ($name in $scriptOrder) {
        $path = Join-Path $SchemaPath $name
        if (-not (Test-Path $path)) {
            Write-Warning "Schema file not found: $path"
            continue
        }
        $script = Get-Content -Path $path -Raw
        $statements = Split-FDAKqlStatements -Script $script
        foreach ($stmt in $statements) {
            $trimmed = $stmt.Trim()
            if (-not $trimmed) { continue }
            if ($PSCmdlet.ShouldProcess("$DatabaseName", "Apply $name statement")) {
                try {
                    Invoke-KustoManagementCommand -Command $trimmed -Database $DatabaseName | Out-Null
                } catch {
                    Write-Warning "Statement in $name failed: $($_.Exception.Message)"
                }
            }
        }
        Write-Verbose "Applied $name"
    }

    # Seed built-in log levels.
    Write-Verbose 'Seeding built-in log levels...'
    foreach ($lvl in $script:BuiltInLogLevels) {
        $record = [pscustomobject]@{
            Timestamp    = (Get-Date).ToUniversalTime().ToString('o')
            Name         = $lvl.Name
            Numeric      = $lvl.Numeric
            Category     = $lvl.Category
            Description  = "Built-in log level: $($lvl.Name)"
            IsBuiltIn    = $true
            IsActive     = $true
            RegisteredBy = 'Initialize-FDAObservability'
        }
        try {
            Invoke-EventhouseIngest -TableName 'FDALogLevels' -MappingName 'FDALogLevelsMapping' -Records @($record) | Out-Null
        } catch {
            Write-Warning "Could not seed level $($lvl.Name): $($_.Exception.Message)"
        }
    }

    # Default config.
    $defaultConfig = @{
        MinLevelName         = 'Information'
        StrictSchema         = $false
        BatchMaxEvents       = 100
        BatchFlushSeconds    = 5
        RedactionPatterns    = $script:DefaultRedactionPatterns
        CapacityRates        = @{ TokensPerCU = 1000; USDPerCU = 0.18 }   # configurable placeholders
        FDAResourceScope     = 'https://api.fabric.microsoft.com/.default'
    }
    foreach ($k in $defaultConfig.Keys) {
        $cfgRecord = [pscustomobject]@{
            Timestamp = (Get-Date).ToUniversalTime().ToString('o')
            Key       = $k
            Value     = $defaultConfig[$k]
            UpdatedBy = 'Initialize-FDAObservability'
            Notes     = 'default'
        }
        try {
            Invoke-EventhouseIngest -TableName 'FDAConfiguration' -MappingName 'FDAConfigurationMapping' -Records @($cfgRecord) | Out-Null
        } catch {
            Write-Warning "Could not seed config key $k : $($_.Exception.Message)"
        }
    }

    [pscustomobject]@{
        Initialized   = $true
        WorkspaceId   = $WorkspaceId
        EventhouseId  = $EventhouseId
        Database      = $DatabaseName
        ClusterUri    = $endpoints.QueryServiceUri
        IngestionUri  = $endpoints.IngestionServiceUri
    }
}

function Split-FDAKqlStatements {
    <#
    .SYNOPSIS
        Split a multi-statement KQL script into individual statements.
        Statements are separated by blank lines OR by control-command markers.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Script)
    # Remove // line comments.
    $clean = ($Script -split "`r?`n" | ForEach-Object {
        $line = $_
        $ix = $line.IndexOf('//')
        if ($ix -ge 0) { $line = $line.Substring(0, $ix) }
        $line
    }) -join "`n"
    # Split on blank lines.
    $blocks = [regex]::Split($clean, '(?:\r?\n){2,}') | Where-Object { $_.Trim() }
    return $blocks
}
