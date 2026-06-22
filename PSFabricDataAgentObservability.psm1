#Requires -Version 7.2
<#
    PSFabricDataAgentObservability.psm1
    Module loader and shared module-scope state.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Module-scope state container. Anything that must persist between cmdlet
# calls (auth handles, config, the in-memory ring buffer, etc.) lives here.
# ---------------------------------------------------------------------------
$script:FDAState = [pscustomobject]@{
    Connected           = $false
    AuthMethod          = $null            # 'ServicePrincipal' | 'ManagedIdentity' | 'UserDelegated'
    TokenProviders      = @{}              # scope -> [scriptblock] returning a fresh AccessToken
    TokenCache          = @{}              # scope -> @{ Token = '...'; ExpiresOn = [datetime] }
    RefreshToken        = $null            # user-delegated refresh token; one sign-in covers all scopes
    TenantId            = $null
    WorkspaceId         = $null
    EventhouseId        = $null
    EventhouseClusterUri= $null            # https://<cluster>.<region>.kusto.fabric.microsoft.com
    EventhouseIngestUri = $null            # https://ingest-<cluster>.<region>.kusto.fabric.microsoft.com
    DatabaseName        = 'FDAObs'
    Config              = $null            # populated by Get-FDAObservabilityConfig
    LogLevels           = $null            # cached level table; refreshed by Get-FDALogLevel
    SpoolPath           = (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.fda-observability/spool')
    FlushBuffer         = [System.Collections.Generic.List[object]]::new()
    FlushTimer          = $null
    FlushLock           = New-Object System.Threading.SemaphoreSlim(1, 1)
    SessionId           = [guid]::NewGuid().ToString()
}

# Built-in log levels. Custom levels (registered via Register-FDALogLevel)
# are merged on top in Resolve-LogLevel.
$script:BuiltInLogLevels = @(
    [pscustomobject]@{ Name = 'Verbose';     Numeric = 10; Category = 'System';  IsBuiltIn = $true }
    [pscustomobject]@{ Name = 'Information'; Numeric = 30; Category = 'System';  IsBuiltIn = $true }
    [pscustomobject]@{ Name = 'Warning';     Numeric = 50; Category = 'System';  IsBuiltIn = $true }
    [pscustomobject]@{ Name = 'Error';       Numeric = 70; Category = 'System';  IsBuiltIn = $true }
    [pscustomobject]@{ Name = 'Critical';    Numeric = 90; Category = 'System';  IsBuiltIn = $true }
)

# Default redaction patterns applied to question / grounding / response text
# unless -PreservePII is explicitly passed with a consent claim.
$script:DefaultRedactionPatterns = @{
    SSN        = '\b\d{3}-\d{2}-\d{4}\b'
    CreditCard = '\b(?:\d[ -]*?){13,19}\b'
    Email      = '\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b'
    Phone      = '\b\+?\d{1,3}[ .-]?\(?\d{3}\)?[ .-]?\d{3}[ .-]?\d{4}\b'
}

# ---------------------------------------------------------------------------
# Load Private then Public function files.
# ---------------------------------------------------------------------------
$moduleRoot = $PSScriptRoot
foreach ($folder in @('Private', 'Public')) {
    $path = Join-Path $moduleRoot $folder
    if (Test-Path $path) {
        Get-ChildItem -Path $path -Filter '*.ps1' -File | Sort-Object Name | ForEach-Object {
            . $_.FullName
        }
    }
}

# Ensure spool directory exists.
if (-not (Test-Path $script:FDAState.SpoolPath)) {
    New-Item -ItemType Directory -Path $script:FDAState.SpoolPath -Force | Out-Null
}

# Export public functions.
$publicFunctions = Get-ChildItem -Path (Join-Path $moduleRoot 'Public') -Filter '*.ps1' -File |
    ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) }

if ($publicFunctions) {
    Export-ModuleMember -Function $publicFunctions
}
