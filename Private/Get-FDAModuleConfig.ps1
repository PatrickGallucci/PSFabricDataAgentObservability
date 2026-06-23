function Get-FDAModuleConfig {
    <#
    .SYNOPSIS
        Read the module-level bootstrap defaults from config.json.
    .DESCRIPTION
        These are the *bootstrap* defaults used by Connect / Initialize to find
        (or create) the target Workspace / Eventhouse / Database and to pick the
        public client id for browser sign-in. This is distinct from
        Get-FDAObservabilityConfig, which reads runtime config from the KQL
        database after a connection exists.

        config.json ships in the module root and is read at runtime. Missing
        file or missing keys fall back to the well-known defaults below, so the
        module still works if the file is absent or partial.

        Recognized keys:
          WorkspaceName  - Fabric workspace display name           (default 'FUAM PUB')
          EventhouseName - Eventhouse display name                 (default 'FDAObservability')
          DatabaseName   - KQL database name                       (default 'FDAObs')
          CapacityName   - Fabric capacity to host a created/empty workspace
                           (default null: auto-pick when exactly one is available)
          ClientId       - public client id for UserDelegated auth (default: Azure CLI)
    .PARAMETER Path
        Override the config file location (defaults to <module>/config.json).
    #>
    [CmdletBinding()]
    param(
        [string] $Path = (Join-Path $script:FDAState.ModuleRoot 'config.json')
    )

    # Azure CLI well-known public client. It registers an http://localhost
    # redirect and allows public client flows, so it works with the auth-code +
    # PKCE browser flow without any app registration in most tenants. Override
    # via config.json "ClientId" when it isn't provisioned in the target tenant.
    $defaults = [pscustomobject]@{
        WorkspaceName  = 'FUAM PUB'
        EventhouseName = 'FDAObservability'
        DatabaseName   = 'FDAObs'
        CapacityName   = $null
        ClientId       = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Verbose "Config file not found at '$Path'; using built-in defaults."
        return $defaults
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        $json = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Warning "Could not parse '$Path' ($($_.Exception.Message)); using built-in defaults."
        return $defaults
    }

    # Merge: a present-but-empty value falls back to the default. ClientId is
    # allowed to be explicitly null in the file to mean "use the default".
    foreach ($key in 'WorkspaceName', 'EventhouseName', 'DatabaseName', 'CapacityName', 'ClientId') {
        if (($json.PSObject.Properties.Name -contains $key) -and $json.$key) {
            $defaults.$key = $json.$key
        }
    }
    return $defaults
}
