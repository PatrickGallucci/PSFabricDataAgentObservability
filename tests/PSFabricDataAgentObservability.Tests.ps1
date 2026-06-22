<#
    Pester v5 smoke tests. These cover the units that do NOT require live
    Eventhouse / FDA endpoints: level resolution, redaction, KQL statement
    splitting, cost estimation, record shape. Integration tests live in
    examples/ — run them against a sandbox workspace.

    Run:
        Invoke-Pester -Path ./tests
#>

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'PSFabricDataAgentObservability.psd1'
    Import-Module $modulePath -Force
}

Describe 'Log level resolution' {
    It 'resolves built-in by name' {
        $r = & (Get-Module PSFabricDataAgentObservability) { Resolve-LogLevel -Level 'Warning' }
        $r.Name      | Should -Be 'Warning'
        $r.Numeric   | Should -Be 50
        $r.IsBuiltIn | Should -BeTrue
    }
    It 'resolves built-in by numeric (exact)' {
        $r = & (Get-Module PSFabricDataAgentObservability) { Resolve-LogLevel -Level 70 }
        $r.Name | Should -Be 'Error'
    }
    It 'resolves numeric between bands as Custom synthetic' {
        $r = & (Get-Module PSFabricDataAgentObservability) { Resolve-LogLevel -Level 42 }
        $r.Numeric | Should -Be 42
        $r.Name    | Should -Match '^Custom_'
    }
    It 'throws on unknown name' {
        { & (Get-Module PSFabricDataAgentObservability) { Resolve-LogLevel -Level 'Nope' } } |
            Should -Throw -ExpectedMessage 'Unknown log level*'
    }
}

Describe 'Redaction' {
    It 'redacts default PII patterns' {
        $r = & (Get-Module PSFabricDataAgentObservability) {
            ConvertTo-FDARedactedText -InputText 'SSN 123-45-6789, email a@b.com' -Patterns $script:DefaultRedactionPatterns
        }
        $r.Redacted | Should -BeTrue
        $r.Text     | Should -Match '\[REDACTED:SSN\]'
        $r.Text     | Should -Match '\[REDACTED:Email\]'
    }
    It 'leaves clean text untouched' {
        $r = & (Get-Module PSFabricDataAgentObservability) {
            ConvertTo-FDARedactedText -InputText 'Revenue by region last quarter' -Patterns $script:DefaultRedactionPatterns
        }
        $r.Redacted | Should -BeFalse
        $r.Text     | Should -Be 'Revenue by region last quarter'
    }
}

Describe 'KQL statement splitter' {
    It 'splits on blank lines' {
        $r = & (Get-Module PSFabricDataAgentObservability) {
            Split-FDAKqlStatements -Script @"
.show tables

.show database FDAObs principals


print x=1
"@
        }
        $r.Count | Should -Be 3
    }
    It 'strips // comments' {
        $r = & (Get-Module PSFabricDataAgentObservability) {
            Split-FDAKqlStatements -Script @"
// banner
print x=1   // trailing
"@
        }
        ($r -join '').Trim() | Should -Be 'print x=1'
    }
}

Describe 'Cost estimation' {
    It 'rounds CU and USD' {
        $r = & (Get-Module PSFabricDataAgentObservability) {
            Get-FDACostEstimate -PromptTokens 1500 -CompletionTokens 500 -Config $null
        }
        $r.CapacityUnits | Should -Be 2.0
        $r.USD           | Should -Be 0.36
    }
    It 'honors config-supplied rates' {
        $cfg = [pscustomobject]@{
            CapacityRates = [pscustomobject]@{ TokensPerCU = 2000; USDPerCU = 0.10; Version = 'test' }
        }
        $r = & (Get-Module PSFabricDataAgentObservability) {
            param($cfg) Get-FDACostEstimate -PromptTokens 4000 -CompletionTokens 0 -Config $cfg
        } $cfg
        $r.CapacityUnits    | Should -Be 2.0
        $r.USD              | Should -Be 0.2
        $r.RateTableVersion | Should -Be 'test'
    }
}

Describe 'Record shape — Eventhouse landing wrapper' {
    It 'adds IngestTime and preserves fields' {
        $r = & (Get-Module PSFabricDataAgentObservability) {
            ConvertTo-EventhouseRecord -InputObject ([pscustomobject]@{ A = 1; B = 'x' })
        }
        $r.IngestTime | Should -Not -BeNullOrEmpty
        $r.A          | Should -Be 1
        $r.B          | Should -Be 'x'
    }
}

Describe 'Level registry merge (offline)' {
    It 'returns built-ins when no DB connection' {
        $r = Get-FDALogLevel
        ($r | Where-Object Name -eq 'Critical').Numeric | Should -Be 90
    }
}

Describe 'Get-FDAAuthEvent contract' {
    It 'is exported by the module' {
        Get-Command Get-FDAAuthEvent -Module PSFabricDataAgentObservability |
            Should -Not -BeNullOrEmpty
    }
    It 'constrains Outcome to Success/Failure' {
        $vv = (Get-Command Get-FDAAuthEvent).Parameters['Outcome'].Attributes.ValidValues
        $vv | Should -Contain 'Success'
        $vv | Should -Contain 'Failure'
    }
    It 'constrains Source to known origins' {
        $vv = (Get-Command Get-FDAAuthEvent).Parameters['Source'].Attributes.ValidValues
        (($vv | Sort-Object) -join ',') | Should -Be 'M365Audit,Module,Purview'
    }
    It 'makes EventId mandatory in the ById parameter set' {
        $attrs = (Get-Command Get-FDAAuthEvent).Parameters['EventId'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] }
        ($attrs | Where-Object ParameterSetName -eq 'ById').Mandatory | Should -BeTrue
    }
}

Describe 'Interactive tenant resolution' {
    It 'returns the tenant ID/domain entered at the prompt (no organizations fallback)' {
        Mock -ModuleName PSFabricDataAgentObservability Read-Host { 'contoso.onmicrosoft.com' }
        Mock -ModuleName PSFabricDataAgentObservability Write-Host { }
        $r = InModuleScope PSFabricDataAgentObservability { Resolve-FDATenant }
        $r | Should -Be 'contoso.onmicrosoft.com'
    }
}

Describe 'User-delegated refresh-token reuse' {
    It 'redeems the stored refresh token silently (no device code) and rotates it' {
        Mock -ModuleName PSFabricDataAgentObservability Invoke-RestMethod {
            if ($Uri -like '*devicecode*') { throw 'device-code endpoint must not be called when a refresh token exists' }
            [pscustomobject]@{ access_token = 'at-new'; expires_in = 3600; refresh_token = 'rt-rotated' }
        }
        $result = InModuleScope PSFabricDataAgentObservability {
            $script:FDAState.TenantId     = 'contoso.onmicrosoft.com'
            $script:FDAState.RefreshToken = 'rt-initial'
            try {
                $tok = Get-FDAUserDelegatedToken -ClientId 'cid' -Scope 'https://api.fabric.microsoft.com/.default'
                [pscustomobject]@{ Token = $tok.Token; Rotated = $script:FDAState.RefreshToken }
            } finally {
                $script:FDAState.RefreshToken = $null
                $script:FDAState.TenantId     = $null
            }
        }
        $result.Token   | Should -Be 'at-new'
        $result.Rotated | Should -Be 'rt-rotated'
        Should -Invoke -ModuleName PSFabricDataAgentObservability Invoke-RestMethod -Exactly -Times 1 `
            -ParameterFilter { $Body.grant_type -eq 'refresh_token' }
        Should -Invoke -ModuleName PSFabricDataAgentObservability Invoke-RestMethod -Exactly -Times 0 `
            -ParameterFilter { $Uri -like '*devicecode*' }
    }
}

Describe 'Get-FDAAccessToken cache & dispatch' {
    It 'throws when not connected' {
        { InModuleScope PSFabricDataAgentObservability {
            $script:FDAState.Connected = $false
            Get-FDAAccessToken -Scope 'https://api.fabric.microsoft.com/.default'
        } } | Should -Throw -ExpectedMessage '*Not connected*'
    }
    It 'returns a cached token while it is still valid (no provider call)' {
        $tok = InModuleScope PSFabricDataAgentObservability {
            $script:FDAState.Connected = $true
            $script:FDAState.TokenCache = @{ 'scopeA' = [pscustomobject]@{ Token = 'CACHED'; ExpiresOn = (Get-Date).AddMinutes(30) } }
            $script:FDAState.TokenProviders = @{ '*' = { param($s) throw 'provider should not be called' } }
            try { Get-FDAAccessToken -Scope 'scopeA' } finally {
                $script:FDAState.Connected = $false; $script:FDAState.TokenCache = @{}; $script:FDAState.TokenProviders = @{}
            }
        }
        $tok | Should -Be 'CACHED'
    }
    It 'calls the wildcard provider on a cache miss and caches the result' {
        $r = InModuleScope PSFabricDataAgentObservability {
            $script:FDAState.Connected = $true
            $script:FDAState.TokenCache = @{}
            $script:FDAState.TokenProviders = @{ '*' = { param($s) [pscustomobject]@{ Token = "T:$s"; ExpiresOn = (Get-Date).AddHours(1) } } }
            try {
                $first = Get-FDAAccessToken -Scope 'scopeB'
                [pscustomobject]@{ Token = $first; Cached = $script:FDAState.TokenCache['scopeB'].Token }
            } finally {
                $script:FDAState.Connected = $false; $script:FDAState.TokenCache = @{}; $script:FDAState.TokenProviders = @{}
            }
        }
        $r.Token  | Should -Be 'T:scopeB'
        $r.Cached | Should -Be 'T:scopeB'
    }
    It 'throws when the provider returns an empty token' {
        { InModuleScope PSFabricDataAgentObservability {
            $script:FDAState.Connected = $true
            $script:FDAState.TokenCache = @{}
            $script:FDAState.TokenProviders = @{ '*' = { param($s) [pscustomobject]@{ Token = $null; ExpiresOn = (Get-Date) } } }
            try { Get-FDAAccessToken -Scope 'scopeC' } finally {
                $script:FDAState.Connected = $false; $script:FDAState.TokenProviders = @{}
            }
        } } | Should -Throw -ExpectedMessage '*empty token*'
    }
}

Describe 'Service Principal token provider' {
    It 'requests a client_credentials token using the client secret' {
        Mock -ModuleName PSFabricDataAgentObservability Invoke-RestMethod { [pscustomobject]@{ access_token = 'SP-SECRET'; expires_in = 3600 } }
        $tok = InModuleScope PSFabricDataAgentObservability {
            $script:FDAState.TenantId = 't'; $script:FDAState.ClientId = 'c'
            $script:FDAState.ClientSecret = ([System.Net.NetworkCredential]::new('', 'sek').SecurePassword); $script:FDAState.Certificate = $null
            try { (Get-FDAServicePrincipalToken -Scope 'https://api.fabric.microsoft.com/.default').Token }
            finally { $script:FDAState.TenantId = $null; $script:FDAState.ClientId = $null; $script:FDAState.ClientSecret = $null }
        }
        $tok | Should -Be 'SP-SECRET'
        Should -Invoke -ModuleName PSFabricDataAgentObservability Invoke-RestMethod -ParameterFilter {
            $Body.grant_type -eq 'client_credentials' -and $Body.client_secret -eq 'sek'
        }
    }
    It 'uses a signed client assertion when a certificate is configured' {
        Mock -ModuleName PSFabricDataAgentObservability Invoke-RestMethod { [pscustomobject]@{ access_token = 'SP-CERT'; expires_in = 3600 } }
        Mock -ModuleName PSFabricDataAgentObservability New-FDAClientAssertion { 'ASSERTION-JWT' }
        # The (mocked) New-FDAClientAssertion still type-checks its [X509Certificate2] param, so pass a real cert.
        $req2 = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
            'CN=FDASpCert', [System.Security.Cryptography.RSA]::Create(2048),
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $spCert = $req2.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(1))
        $tok = InModuleScope PSFabricDataAgentObservability -Parameters @{ Cert = $spCert } {
            param($Cert)
            $script:FDAState.TenantId = 't'; $script:FDAState.ClientId = 'c'
            $script:FDAState.ClientSecret = $null; $script:FDAState.Certificate = $Cert
            try { (Get-FDAServicePrincipalToken -Scope 's').Token }
            finally { $script:FDAState.TenantId = $null; $script:FDAState.ClientId = $null; $script:FDAState.Certificate = $null }
        }
        $tok | Should -Be 'SP-CERT'
        Should -Invoke -ModuleName PSFabricDataAgentObservability Invoke-RestMethod -ParameterFilter {
            $Body.client_assertion -eq 'ASSERTION-JWT' -and $Body.client_assertion_type -like '*jwt-bearer*'
        }
    }
}

Describe 'Managed Identity token provider' {
    It 'calls IMDS with the resource derived from the scope (expires_on branch)' {
        Mock -ModuleName PSFabricDataAgentObservability Invoke-RestMethod {
            [pscustomobject]@{ access_token = 'MI-IMDS'; expires_on = ([DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds()) }
        }
        $tok = InModuleScope PSFabricDataAgentObservability {
            $script:FDAState.ManagedIdentityClientId = $null
            Get-FDAManagedIdentityToken -Scope 'https://api.fabric.microsoft.com/.default'
        }
        $tok.Token | Should -Be 'MI-IMDS'
        Should -Invoke -ModuleName PSFabricDataAgentObservability Invoke-RestMethod -ParameterFilter {
            $Uri -like 'http://169.254.169.254/*' -and $Uri -like '*resource=https%3A%2F%2Fapi.fabric.microsoft.com*'
        }
    }
    It 'honors the IDENTITY_ENDPOINT / IDENTITY_HEADER variant (expires_in branch)' {
        Mock -ModuleName PSFabricDataAgentObservability Invoke-RestMethod { [pscustomobject]@{ access_token = 'MI-APPSVC'; expires_in = 3600 } }
        $tok = InModuleScope PSFabricDataAgentObservability {
            $o1 = $env:IDENTITY_ENDPOINT; $o2 = $env:IDENTITY_HEADER
            $env:IDENTITY_ENDPOINT = 'https://app.identity/token'; $env:IDENTITY_HEADER = 'secret-hdr'
            try { Get-FDAManagedIdentityToken -Scope 'https://kusto.fabric.microsoft.com/.default' }
            finally { $env:IDENTITY_ENDPOINT = $o1; $env:IDENTITY_HEADER = $o2 }
        }
        $tok.Token | Should -Be 'MI-APPSVC'
        Should -Invoke -ModuleName PSFabricDataAgentObservability Invoke-RestMethod -ParameterFilter {
            $Uri -like 'https://app.identity/token*' -and $Headers['X-IDENTITY-HEADER'] -eq 'secret-hdr'
        }
    }
}

Describe 'User-delegated device-code flow' {
    It 'completes the device-code flow and stores the refresh token' {
        Mock -ModuleName PSFabricDataAgentObservability Start-Sleep { }
        Mock -ModuleName PSFabricDataAgentObservability Write-Host { }
        Mock -ModuleName PSFabricDataAgentObservability Invoke-RestMethod {
            if ($Uri -like '*devicecode*') {
                [pscustomobject]@{ verification_uri = 'https://aka.ms/devicelogin'; user_code = 'ABC-123'; expires_in = 900; interval = 0; device_code = 'DC' }
            } else {
                [pscustomobject]@{ access_token = 'AT-DEVICE'; expires_in = 3600; refresh_token = 'RT-FIRST' }
            }
        }
        $r = InModuleScope PSFabricDataAgentObservability {
            $script:FDAState.TenantId = 't'; $script:FDAState.RefreshToken = $null
            try {
                $tok = Get-FDAUserDelegatedToken -ClientId 'cid' -Scope 'https://api.fabric.microsoft.com/.default'
                [pscustomobject]@{ Token = $tok.Token; RT = $script:FDAState.RefreshToken }
            } finally { $script:FDAState.TenantId = $null; $script:FDAState.RefreshToken = $null }
        }
        $r.Token | Should -Be 'AT-DEVICE'
        $r.RT    | Should -Be 'RT-FIRST'
    }
    It 'throws a clear error when no tenant is set' {
        { InModuleScope PSFabricDataAgentObservability {
            $script:FDAState.TenantId = $null
            Get-FDAUserDelegatedToken -ClientId 'cid' -Scope 's'
        } } | Should -Throw -ExpectedMessage '*requires a tenant*'
    }
    It 'falls back to device code when the stored refresh token is rejected' {
        Mock -ModuleName PSFabricDataAgentObservability Start-Sleep { }
        Mock -ModuleName PSFabricDataAgentObservability Write-Host { }
        Mock -ModuleName PSFabricDataAgentObservability Invoke-RestMethod {
            if ($Body.grant_type -eq 'refresh_token') { throw 'invalid_grant' }
            if ($Uri -like '*devicecode*') {
                [pscustomobject]@{ verification_uri = 'u'; user_code = 'c'; expires_in = 900; interval = 0; device_code = 'DC' }
            } else {
                [pscustomobject]@{ access_token = 'AT-FALLBACK'; expires_in = 3600; refresh_token = 'RT-NEW' }
            }
        }
        $tok = InModuleScope PSFabricDataAgentObservability {
            $script:FDAState.TenantId = 't'; $script:FDAState.RefreshToken = 'stale'
            try { (Get-FDAUserDelegatedToken -ClientId 'cid' -Scope 's').Token }
            finally { $script:FDAState.TenantId = $null; $script:FDAState.RefreshToken = $null }
        }
        $tok | Should -Be 'AT-FALLBACK'
        Should -Invoke -ModuleName PSFabricDataAgentObservability Invoke-RestMethod -ParameterFilter { $Uri -like '*devicecode*' } -Times 1
    }
}

Describe 'Set-FDARefreshToken' {
    It 'rotates the refresh token when one is returned, and is a no-op otherwise' {
        InModuleScope PSFabricDataAgentObservability {
            $script:FDAState.RefreshToken = 'old'
            Set-FDARefreshToken -Response ([pscustomobject]@{ refresh_token = 'rotated' })
            $script:FDAState.RefreshToken | Should -Be 'rotated'
            Set-FDARefreshToken -Response ([pscustomobject]@{ access_token = 'only-access' })
            $script:FDAState.RefreshToken | Should -Be 'rotated'
            $script:FDAState.RefreshToken = $null
        }
    }
}

Describe 'Fabric REST pagination' {
    It 'follows continuationUri across pages and flattens the values' {
        Mock -ModuleName PSFabricDataAgentObservability Get-FDAAccessToken { 'tok' }
        Mock -ModuleName PSFabricDataAgentObservability Invoke-RestMethod {
            if ($Uri -eq 'https://next') { [pscustomobject]@{ value = @([pscustomobject]@{ id = 2 }) } }
            else { [pscustomobject]@{ value = @([pscustomobject]@{ id = 1 }); continuationUri = 'https://next' } }
        }
        $all = InModuleScope PSFabricDataAgentObservability { @(Get-FDAFabricCollection -Url 'https://base') }
        $all.Count | Should -Be 2
        ($all.id -join ',') | Should -Be '1,2'
    }
}

Describe 'Get-FDAEventhouseEndpoint' {
    It 'parses query and ingestion URIs from the Fabric response' {
        Mock -ModuleName PSFabricDataAgentObservability Get-FDAAccessToken { 'tok' }
        Mock -ModuleName PSFabricDataAgentObservability Invoke-RestMethod {
            [pscustomobject]@{ displayName = 'EH'; properties = [pscustomobject]@{ queryServiceUri = 'https://q'; ingestionServiceUri = 'https://i'; minimumConsumptionUnits = 0 } }
        }
        $e = InModuleScope PSFabricDataAgentObservability { Get-FDAEventhouseEndpoint -WorkspaceId 'w' -EventhouseId 'e' }
        $e.QueryServiceUri     | Should -Be 'https://q'
        $e.IngestionServiceUri | Should -Be 'https://i'
    }
    It 'throws when the Eventhouse has no properties' {
        Mock -ModuleName PSFabricDataAgentObservability Get-FDAAccessToken { 'tok' }
        Mock -ModuleName PSFabricDataAgentObservability Invoke-RestMethod { [pscustomobject]@{ displayName = 'EH'; properties = $null } }
        { InModuleScope PSFabricDataAgentObservability { Get-FDAEventhouseEndpoint -WorkspaceId 'w' -EventhouseId 'e' } } |
            Should -Throw -ExpectedMessage '*no properties*'
    }
}

Describe 'New-FDAWorkspace' {
    It 'POSTs the display name and returns the created workspace' {
        Mock -ModuleName PSFabricDataAgentObservability Get-FDAAccessToken { 'tok' }
        Mock -ModuleName PSFabricDataAgentObservability Invoke-RestMethod {
            [pscustomobject]@{ id = 'w-new'; displayName = ($Body | ConvertFrom-Json).displayName }
        }
        $ws = InModuleScope PSFabricDataAgentObservability { New-FDAWorkspace -DisplayName 'My WS' }
        $ws.id          | Should -Be 'w-new'
        $ws.displayName | Should -Be 'My WS'
    }
}

Describe 'Interactive workspace / Eventhouse resolvers' {
    It 'Resolve-FDAWorkspace returns the id of the selected existing workspace' {
        Mock -ModuleName PSFabricDataAgentObservability Write-Host { }
        Mock -ModuleName PSFabricDataAgentObservability Get-FDAWorkspaceList {
            @([pscustomobject]@{ displayName = 'WS1'; id = 'w1' }, [pscustomobject]@{ displayName = 'WS2'; id = 'w2' })
        }
        Mock -ModuleName PSFabricDataAgentObservability Read-Host { '2' }
        $id = InModuleScope PSFabricDataAgentObservability { Resolve-FDAWorkspace }
        $id | Should -Be 'w2'
    }
    It 'Resolve-FDAWorkspace creates a new workspace when 0 is chosen' {
        Mock -ModuleName PSFabricDataAgentObservability Write-Host { }
        Mock -ModuleName PSFabricDataAgentObservability Get-FDAWorkspaceList { @() }
        Mock -ModuleName PSFabricDataAgentObservability Read-Host -ParameterFilter { $Prompt -like 'Select*' } { '0' }
        Mock -ModuleName PSFabricDataAgentObservability Read-Host -ParameterFilter { $Prompt -like 'New workspace*' } { 'Created WS' }
        Mock -ModuleName PSFabricDataAgentObservability New-FDAWorkspace { [pscustomobject]@{ displayName = 'Created WS'; id = 'w-created' } }
        $id = InModuleScope PSFabricDataAgentObservability { Resolve-FDAWorkspace }
        $id | Should -Be 'w-created'
        Should -Invoke -ModuleName PSFabricDataAgentObservability New-FDAWorkspace -Times 1
    }
    It 'Resolve-FDAEventhouse returns the id of the selected existing Eventhouse' {
        Mock -ModuleName PSFabricDataAgentObservability Write-Host { }
        Mock -ModuleName PSFabricDataAgentObservability Get-FDAEventhouseList {
            @([pscustomobject]@{ displayName = 'EH1'; id = 'e1' })
        }
        Mock -ModuleName PSFabricDataAgentObservability Read-Host { '1' }
        $id = InModuleScope PSFabricDataAgentObservability { Resolve-FDAEventhouse -WorkspaceId 'w' }
        $id | Should -Be 'e1'
    }
    It 'Resolve-FDAEventhouse creates a new Eventhouse and waits for endpoints' {
        Mock -ModuleName PSFabricDataAgentObservability Write-Host { }
        Mock -ModuleName PSFabricDataAgentObservability Start-Sleep { }
        Mock -ModuleName PSFabricDataAgentObservability Get-FDAEventhouseList { @() }
        Mock -ModuleName PSFabricDataAgentObservability Read-Host -ParameterFilter { $Prompt -like 'Select*' } { '0' }
        Mock -ModuleName PSFabricDataAgentObservability Read-Host -ParameterFilter { $Prompt -like 'New Eventhouse*' } { 'Created EH' }
        Mock -ModuleName PSFabricDataAgentObservability New-FDAEventhouse { [pscustomobject]@{ id = 'e-created' } }
        Mock -ModuleName PSFabricDataAgentObservability Get-FDAEventhouseEndpoint {
            [pscustomobject]@{ DisplayName = 'Created EH'; QueryServiceUri = 'https://q'; IngestionServiceUri = 'https://i' }
        }
        $id = InModuleScope PSFabricDataAgentObservability { Resolve-FDAEventhouse -WorkspaceId 'w' }
        $id | Should -Be 'e-created'
    }
}

Describe 'Read-FDASelection input validation' {
    It 'rejects out-of-range input then accepts a valid choice' {
        Mock -ModuleName PSFabricDataAgentObservability Write-Host { }
        $script:rsAnswers = @('99', '2'); $script:rsIndex = 0
        Mock -ModuleName PSFabricDataAgentObservability Read-Host { $v = $script:rsAnswers[$script:rsIndex]; $script:rsIndex++; $v }
        $n = InModuleScope PSFabricDataAgentObservability { Read-FDASelection -Max 3 -Prompt 'pick' }
        $n | Should -Be 2
    }
    It 'accepts 0 only when -AllowZero is set' {
        Mock -ModuleName PSFabricDataAgentObservability Write-Host { }
        Mock -ModuleName PSFabricDataAgentObservability Read-Host { '0' }
        $n = InModuleScope PSFabricDataAgentObservability { Read-FDASelection -Max 3 -Prompt 'pick' -AllowZero }
        $n | Should -Be 0
    }
}

Describe 'New-FDAClientAssertion' {
    It 'builds a signed three-segment JWT with an RS256 header' {
        $rsa = [System.Security.Cryptography.RSA]::Create(2048)
        $req = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
            'CN=FDATest', $rsa,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $cert = $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(1))
        $jwt = & (Get-Module PSFabricDataAgentObservability) {
            param($c) New-FDAClientAssertion -ClientId 'cid' -TenantId 'tid' -Certificate $c
        } $cert
        $parts = $jwt.Split('.')
        $parts.Count | Should -Be 3
        $h = $parts[0].Replace('-', '+').Replace('_', '/')
        switch ($h.Length % 4) { 2 { $h += '==' } 3 { $h += '=' } }
        $header = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($h)) | ConvertFrom-Json
        $header.alg | Should -Be 'RS256'
        $header.typ | Should -Be 'JWT'
    }
}

Describe 'Connect installs a working provider (closure-scope regression)' {
    AfterEach {
        & (Get-Module PSFabricDataAgentObservability) { try { Disconnect-FDAObservability | Out-Null } catch { Write-Verbose "disconnect cleanup: $_" } }
    }
    It 'ServicePrincipal: Get-FDAAccessToken resolves through the installed provider into the private helper' {
        Mock -ModuleName PSFabricDataAgentObservability Start-FDAFlushTimer { }
        Mock -ModuleName PSFabricDataAgentObservability Get-FDAObservabilityConfig { }
        Mock -ModuleName PSFabricDataAgentObservability Get-FDALogLevel { }
        Mock -ModuleName PSFabricDataAgentObservability Restore-FDASpool { }
        Mock -ModuleName PSFabricDataAgentObservability Invoke-RestMethod {
            if ($Uri -like '*oauth2/v2.0/token*') { return [pscustomobject]@{ access_token = 'SP-TOKEN'; expires_in = 3600 } }
            if ($Uri -like '*/eventhouses/*') {
                return [pscustomobject]@{ displayName = 'EH'; properties = [pscustomobject]@{ queryServiceUri = 'https://q.kusto'; ingestionServiceUri = 'https://i.kusto'; minimumConsumptionUnits = 0 } }
            }
            throw "unexpected URI: $Uri"
        }
        $sec  = [System.Net.NetworkCredential]::new('', 'sek').SecurePassword
        $conn = Connect-FDAObservability -AuthMethod ServicePrincipal -TenantId 't' -ClientId 'c' -ClientSecret $sec -WorkspaceId 'w' -EventhouseId 'e'
        $conn.Connected | Should -BeTrue
        # A fresh scope forces the provider to run — the exact path that failed
        # when the provider was a closure that could not see Get-FDAServicePrincipalToken.
        $tok = InModuleScope PSFabricDataAgentObservability { Get-FDAAccessToken -Scope 'https://kusto.fabric.microsoft.com/.default' }
        $tok | Should -Be 'SP-TOKEN'
    }
}

Describe 'ConvertTo-FDARedactedText edge cases' {
    It 'returns unchanged for empty input' {
        $r = & (Get-Module PSFabricDataAgentObservability) { ConvertTo-FDARedactedText -InputText '' -Patterns @{} }
        $r.Redacted | Should -BeFalse
        $r.Text     | Should -Be ''
    }
    It 'falls back to default patterns when none supplied' {
        $r = & (Get-Module PSFabricDataAgentObservability) { ConvertTo-FDARedactedText -InputText 'SSN 123-45-6789' -Patterns @{} }
        $r.Redacted | Should -BeTrue
        $r.Text     | Should -Match '\[REDACTED:SSN\]'
    }
}

Describe 'ConvertTo-EventhouseRecord dictionary input' {
    It 'normalizes a hashtable and adds IngestTime' {
        $r = & (Get-Module PSFabricDataAgentObservability) {
            ConvertTo-EventhouseRecord -InputObject @{ A = 1; B = 'x' }
        }
        $r.IngestTime | Should -Not -BeNullOrEmpty
        $r.A          | Should -Be 1
    }
}

Describe 'Resolve-LogLevel custom merge' {
    It 'resolves a registered custom level by name and clears the cache afterward' {
        $r = InModuleScope PSFabricDataAgentObservability {
            $script:FDAState.LogLevels = @([pscustomobject]@{ Name = 'Audit'; Numeric = 60; Category = 'Compliance'; IsBuiltIn = $false })
            try { Resolve-LogLevel -Level 'Audit' } finally { $script:FDAState.LogLevels = $null }
        }
        $r.Numeric  | Should -Be 60
        $r.Category | Should -Be 'Compliance'
    }
}

Describe 'Read cmdlets build KQL and call Invoke-KQLQuery' {
    BeforeAll { InModuleScope PSFabricDataAgentObservability { $script:FDAState.Connected = $true } }
    AfterAll  { InModuleScope PSFabricDataAgentObservability { $script:FDAState.Connected = $false } }
    BeforeEach { Mock -ModuleName PSFabricDataAgentObservability Invoke-KQLQuery { @([pscustomobject]@{ Q = $Query }) } }

    It 'Search-FDALog -KQL passes the raw query through' {
        $r = Search-FDALog -KQL 'FDAInteractions | take 1'
        $r.Q | Should -Be 'FDAInteractions | take 1'
    }
    It 'Search-FDALog filter set builds a where/top query with all clauses' {
        $r = Search-FDALog -Table FDAInteractions -MinLevel Warning -MaxLevel Critical -Last 1h `
            -UserPrincipalName "a'b@c.com" -Contains 'rev' -CorrelationId 'cid' -InteractionId 'iid' -Top 5
        $r.Q | Should -Match 'FDAInteractions \|'
        $r.Q | Should -Match 'LevelNumeric >= 50'
        $r.Q | Should -Match 'top 5 by Timestamp desc'
        $r.Q | Should -Match "a''b@c.com"
    }
    It 'Get-FDAInteraction by id escapes quotes' {
        $r = Get-FDAInteraction -InteractionId "x'y"
        $r.Q | Should -Match "InteractionId == 'x''y'"
    }
    It 'Get-FDAInteraction filter set applies status' {
        (Get-FDAInteraction -Status Error -Top 3).Q | Should -Match "Status == 'Error'"
    }
    It 'Get-FDAExecutionTelemetry -JoinInteractions emits a join' {
        (Get-FDAExecutionTelemetry -JoinInteractions -MinDurationMs 100).Q | Should -Match 'join kind=leftouter'
    }
    It 'Get-FDAAuthEvent filter set includes outcome and source' {
        (Get-FDAAuthEvent -Outcome Failure -Source M365Audit).Q | Should -Match "Outcome == 'Failure'"
    }
    It 'Get-FDAAuthEvent by id' {
        (Get-FDAAuthEvent -EventId 'e1').Q | Should -Match "EventId == 'e1'"
    }
    It 'Get-FDACostUsage groups by day' {
        (Get-FDACostUsage -GroupBy Day).Q | Should -Match 'bin\(Timestamp, 1d\)'
    }
    It 'Get-FDACostUsage None omits grouping' {
        (Get-FDACostUsage -GroupBy None).Q | Should -Not -Match ' by '
    }
}

Describe 'Configuration read/write' {
    AfterEach { InModuleScope PSFabricDataAgentObservability { $script:FDAState.Connected = $false; $script:FDAState.Config = $null } }
    It 'Get-FDAObservabilityConfig throws when not connected' {
        { Get-FDAObservabilityConfig } | Should -Throw -ExpectedMessage '*Not connected*'
    }
    It 'Get-FDAObservabilityConfig collapses rows and caches' {
        Mock -ModuleName PSFabricDataAgentObservability Invoke-KQLQuery {
            @([pscustomobject]@{ Key = 'MinLevelName'; Value = 'Information' }, [pscustomobject]@{ Key = 'StrictSchema'; Value = $false })
        }
        InModuleScope PSFabricDataAgentObservability { $script:FDAState.Connected = $true; $script:FDAState.Config = $null }
        $cfg = Get-FDAObservabilityConfig
        $cfg.MinLevelName | Should -Be 'Information'
        Get-FDAObservabilityConfig | Out-Null   # cached path
        Should -Invoke -ModuleName PSFabricDataAgentObservability Invoke-KQLQuery -Times 1 -Exactly
    }
    It 'Set-FDAObservabilityConfig persists updates and refreshes' {
        Mock -ModuleName PSFabricDataAgentObservability Invoke-EventhouseIngest { }
        Mock -ModuleName PSFabricDataAgentObservability Get-FDAObservabilityConfig { [pscustomobject]@{ MinLevelNumeric = 50 } }
        InModuleScope PSFabricDataAgentObservability { $script:FDAState.Connected = $true }
        $r = Set-FDAObservabilityConfig -MinLevel Warning -StrictSchema $true -BatchMaxEvents 50
        $r.Updated | Should -Contain 'MinLevelName'
        $r.Updated | Should -Contain 'StrictSchema'
        Should -Invoke -ModuleName PSFabricDataAgentObservability Invoke-EventhouseIngest -Times 1
    }
    It 'Set-FDAObservabilityConfig warns when no parameters given' {
        InModuleScope PSFabricDataAgentObservability { $script:FDAState.Connected = $true }
        Set-FDAObservabilityConfig -WarningAction SilentlyContinue -WarningVariable w
        $w | Should -Not -BeNullOrEmpty
    }
    It 'Set-FDAObservabilityConfig with -Category writes a per-category override' {
        Mock -ModuleName PSFabricDataAgentObservability Invoke-EventhouseIngest { }
        Mock -ModuleName PSFabricDataAgentObservability Get-FDAObservabilityConfig { [pscustomobject]@{} }
        InModuleScope PSFabricDataAgentObservability { $script:FDAState.Connected = $true }
        (Set-FDAObservabilityConfig -Category 'Cost' -MinLevel 'Verbose').Updated | Should -Contain 'MinLevelByCategory.Cost'
    }
}

Describe 'Log level registry (connected)' {
    AfterEach { InModuleScope PSFabricDataAgentObservability { $script:FDAState.Connected = $false; $script:FDAState.LogLevels = $null } }
    It 'Get-FDALogLevel merges DB rows with built-ins' {
        Mock -ModuleName PSFabricDataAgentObservability Invoke-KQLQuery {
            @([pscustomobject]@{ Name = 'Audit'; Numeric = 60; Category = 'Compliance'; Description = 'd'; IsBuiltIn = $false })
        }
        InModuleScope PSFabricDataAgentObservability { $script:FDAState.Connected = $true; $script:FDAState.LogLevels = $null }
        $levels = Get-FDALogLevel -Force
        ($levels | Where-Object Name -eq 'Audit').Numeric    | Should -Be 60
        ($levels | Where-Object Name -eq 'Critical').Numeric | Should -Be 90
    }
    It 'Get-FDALogLevel falls back to built-ins on DB error' {
        Mock -ModuleName PSFabricDataAgentObservability Invoke-KQLQuery { throw 'kql down' }
        InModuleScope PSFabricDataAgentObservability { $script:FDAState.Connected = $true; $script:FDAState.LogLevels = $null }
        (Get-FDALogLevel -Force | Where-Object Name -eq 'Error').Numeric | Should -Be 70
    }
    It 'Register-FDALogLevel ingests a custom level' {
        Mock -ModuleName PSFabricDataAgentObservability Invoke-EventhouseIngest { }
        Mock -ModuleName PSFabricDataAgentObservability Get-FDALogLevel { }
        InModuleScope PSFabricDataAgentObservability { $script:FDAState.Connected = $true }
        (Register-FDALogLevel -Name 'Trace' -Numeric 5 -Category 'Diagnostics').Registered | Should -Be 'Trace'
        Should -Invoke -ModuleName PSFabricDataAgentObservability Invoke-EventhouseIngest -Times 1
    }
    It 'Unregister-FDALogLevel refuses built-ins' {
        { Unregister-FDALogLevel -Name 'Warning' } | Should -Throw -ExpectedMessage '*built-in*'
    }
    It 'Unregister-FDALogLevel throws for an unknown level' {
        Mock -ModuleName PSFabricDataAgentObservability Get-FDALogLevel { @() }
        { Unregister-FDALogLevel -Name 'Nope' } | Should -Throw -ExpectedMessage '*not registered*'
    }
    It 'Unregister-FDALogLevel deactivates a registered custom level' {
        Mock -ModuleName PSFabricDataAgentObservability Invoke-EventhouseIngest { }
        Mock -ModuleName PSFabricDataAgentObservability Get-FDALogLevel {
            @([pscustomobject]@{ Name = 'Audit'; Numeric = 60; Category = 'Compliance'; Description = 'd' })
        }
        (Unregister-FDALogLevel -Name 'Audit').Unregistered | Should -Be 'Audit'
        Should -Invoke -ModuleName PSFabricDataAgentObservability Invoke-EventhouseIngest -Times 1
    }
}

Describe 'Write-FDALog' {
    AfterEach { InModuleScope PSFabricDataAgentObservability { $script:FDAState.Connected = $false } }
    It 'throws when not connected' {
        { Write-FDALog -Level Information -Message 'x' } | Should -Throw -ExpectedMessage '*Not connected*'
    }
    It 'suppresses entries below the configured threshold' {
        Mock -ModuleName PSFabricDataAgentObservability Get-FDAObservabilityConfig { [pscustomobject]@{ MinLevelNumeric = 50 } }
        Mock -ModuleName PSFabricDataAgentObservability Add-FDAFlushEntry { }
        InModuleScope PSFabricDataAgentObservability { $script:FDAState.Connected = $true }
        Write-FDALog -Level Information -Message 'below threshold'
        Should -Invoke -ModuleName PSFabricDataAgentObservability Add-FDAFlushEntry -Times 0
    }
    It 'enqueues entries at or above the threshold' {
        Mock -ModuleName PSFabricDataAgentObservability Get-FDAObservabilityConfig { [pscustomobject]@{ MinLevelNumeric = 30 } }
        Mock -ModuleName PSFabricDataAgentObservability Add-FDAFlushEntry { }
        InModuleScope PSFabricDataAgentObservability { $script:FDAState.Connected = $true }
        Write-FDALog -Level Error -Message 'boom' -Category 'Test' -Exception ([System.InvalidOperationException]::new('bad'))
        Should -Invoke -ModuleName PSFabricDataAgentObservability Add-FDAFlushEntry -Times 1
    }
}

Describe 'Invoke-KQLQuery primitive' {
    AfterEach { InModuleScope PSFabricDataAgentObservability { $script:FDAState.EventhouseClusterUri = $null } }
    It 'throws when the cluster URI is not set' {
        { InModuleScope PSFabricDataAgentObservability { $script:FDAState.EventhouseClusterUri = $null; Invoke-KQLQuery -Query 'print x=1' } } |
            Should -Throw -ExpectedMessage '*cluster URI is not set*'
    }
    It 'parses the Kusto Tables response into objects' {
        Mock -ModuleName PSFabricDataAgentObservability Get-FDAAccessToken { 'tok' }
        Mock -ModuleName PSFabricDataAgentObservability Invoke-RestMethod {
            [pscustomobject]@{ Tables = @([pscustomobject]@{ TableName = 'PrimaryResult'; Columns = @([pscustomobject]@{ ColumnName = 'x' }); Rows = @(, @(42)) }) }
        }
        $rows = InModuleScope PSFabricDataAgentObservability {
            $script:FDAState.EventhouseClusterUri = 'https://cluster'
            Invoke-KQLQuery -Query 'print x=42' -Parameters @{ p = 'v' }
        }
        $rows[0].x | Should -Be 42
        Should -Invoke -ModuleName PSFabricDataAgentObservability Invoke-RestMethod -ParameterFilter { $Body -like '*declare query_parameters*' }
    }
    It 'returns empty when the response has no rows' {
        Mock -ModuleName PSFabricDataAgentObservability Get-FDAAccessToken { 'tok' }
        Mock -ModuleName PSFabricDataAgentObservability Invoke-RestMethod { [pscustomobject]@{ Tables = @() } }
        $rows = InModuleScope PSFabricDataAgentObservability {
            $script:FDAState.EventhouseClusterUri = 'https://cluster'
            @(Invoke-KQLQuery -Query 'x')
        }
        $rows.Count | Should -Be 0
    }
}

Describe 'Invoke-EventhouseIngest primitive' {
    AfterEach { InModuleScope PSFabricDataAgentObservability { $script:FDAState.EventhouseIngestUri = $null } }
    It 'throws when the ingest URI is not set' {
        { InModuleScope PSFabricDataAgentObservability { $script:FDAState.EventhouseIngestUri = $null; Invoke-EventhouseIngest -TableName T -MappingName M -Records @(1) } } |
            Should -Throw -ExpectedMessage '*ingest URI is not set*'
    }
    It 'posts JSONL and returns the response' {
        Mock -ModuleName PSFabricDataAgentObservability Get-FDAAccessToken { 'tok' }
        Mock -ModuleName PSFabricDataAgentObservability Invoke-RestMethod { 'ingest-ok' }
        $res = InModuleScope PSFabricDataAgentObservability {
            $script:FDAState.EventhouseIngestUri = 'https://ingest'
            Invoke-EventhouseIngest -TableName 'FDALogEventsRaw' -MappingName 'M' -Records @([pscustomobject]@{ A = 1 })
        }
        $res | Should -Be 'ingest-ok'
    }
    It 'spools to disk and rethrows after exhausting retries' {
        Mock -ModuleName PSFabricDataAgentObservability Get-FDAAccessToken { 'tok' }
        Mock -ModuleName PSFabricDataAgentObservability Start-Sleep { }
        Mock -ModuleName PSFabricDataAgentObservability Invoke-RestMethod { throw [System.Net.WebException]::new('transient') }
        $spool = Join-Path $TestDrive 'spool'
        New-Item -ItemType Directory -Path $spool -Force | Out-Null
        { InModuleScope PSFabricDataAgentObservability -Parameters @{ Spool = $spool } {
            param($Spool)
            $script:FDAState.EventhouseIngestUri = 'https://ingest'
            $script:FDAState.SpoolPath = $Spool
            Invoke-EventhouseIngest -TableName 'FDALogEventsRaw' -MappingName 'M' -Records @([pscustomobject]@{ A = 1 })
        } } | Should -Throw -ExpectedMessage '*ingest failed after*'
        (Get-ChildItem -Path $spool -Filter '*.spool.json').Count | Should -BeGreaterThan 0
    }
}

Describe 'Flush buffer & spool drain' {
    It 'Add-FDAFlushEntry ingests synchronously for Critical level' {
        Mock -ModuleName PSFabricDataAgentObservability Invoke-EventhouseIngest { }
        InModuleScope PSFabricDataAgentObservability {
            Add-FDAFlushEntry -TableName 'T' -MappingName 'M' -Record ([pscustomobject]@{ A = 1 }) -LevelNumeric 90
        }
        Should -Invoke -ModuleName PSFabricDataAgentObservability Invoke-EventhouseIngest -Times 1
    }
    It 'Add-FDAFlushEntry buffers non-critical, Invoke-FDAFlush groups and ingests' {
        Mock -ModuleName PSFabricDataAgentObservability Invoke-EventhouseIngest { }
        InModuleScope PSFabricDataAgentObservability {
            $script:FDAState.FlushBuffer.Clear()
            Add-FDAFlushEntry -TableName 'T' -MappingName 'M' -Record ([pscustomobject]@{ A = 1 }) -LevelNumeric 30
            $script:FDAState.FlushBuffer.Count | Should -Be 1
            Invoke-FDAFlush
            $script:FDAState.FlushBuffer.Count | Should -Be 0
        }
        Should -Invoke -ModuleName PSFabricDataAgentObservability Invoke-EventhouseIngest -Times 1
    }
    It 'Save-FDASpool then Restore-FDASpool drains and removes the file' {
        Mock -ModuleName PSFabricDataAgentObservability Invoke-EventhouseIngest { }
        $spool = Join-Path $TestDrive 'spool2'
        $remaining = InModuleScope PSFabricDataAgentObservability -Parameters @{ Spool = $spool } {
            param($Spool)
            $script:FDAState.SpoolPath = $Spool
            Save-FDASpool -TableName 'T' -MappingName 'M' -Records @([pscustomobject]@{ A = 1 })
            Restore-FDASpool
            @(Get-ChildItem -Path $Spool -Filter '*.spool.json' -ErrorAction SilentlyContinue).Count
        }
        $remaining | Should -Be 0
        Should -Invoke -ModuleName PSFabricDataAgentObservability Invoke-EventhouseIngest -Times 1
    }
}

Describe 'Invoke-FDAQuery proxy capture' {
    AfterEach { InModuleScope PSFabricDataAgentObservability { $script:FDAState.Connected = $false } }
    BeforeEach {
        Mock -ModuleName PSFabricDataAgentObservability Get-FDAObservabilityConfig {
            [pscustomobject]@{ StrictSchema = $false; FDAResourceScope = 'https://api.fabric.microsoft.com/.default' }
        }
        Mock -ModuleName PSFabricDataAgentObservability Get-FDAAccessToken { 'tok' }
        Mock -ModuleName PSFabricDataAgentObservability Add-FDAFlushEntry { }
        InModuleScope PSFabricDataAgentObservability { $script:FDAState.Connected = $true }
    }
    It 'requires -ConsentClaim with -PreservePII' {
        { Invoke-FDAQuery -AgentEndpoint 'https://fda' -Question 'q' -PreservePII } |
            Should -Throw -ExpectedMessage '*requires -ConsentClaim*'
    }
    It 'captures a successful interaction and returns the answer' {
        Mock -ModuleName PSFabricDataAgentObservability Invoke-RestMethod {
            [pscustomobject]@{
                answer = '42'; steps = @('reason'); grounding = @('g'); generatedQuery = 'EVALUATE'
                usage = [pscustomobject]@{ prompt_tokens = 10; completion_tokens = 5; total_tokens = 15 }
                model = 'gpt'; agentName = 'A'; agentId = 'id'
            }
        }
        $ans = Invoke-FDAQuery -AgentEndpoint 'https://fda' -Question 'What is the answer?'
        $ans | Should -Be '42'
        Should -Invoke -ModuleName PSFabricDataAgentObservability Add-FDAFlushEntry -Times 2  # interaction + cost meter
    }
    It 'marks PartialCapture and returns object via -PassThru when fields are missing' {
        Mock -ModuleName PSFabricDataAgentObservability Invoke-RestMethod { [pscustomobject]@{ answer = 'only-answer' } }
        $obj = Invoke-FDAQuery -AgentEndpoint 'https://fda' -Question 'q' -PassThru
        $obj.Status | Should -Be 'PartialCapture'
        $obj.Answer | Should -Be 'only-answer'
    }
    It 'records the error and rethrows when the FDA call fails' {
        Mock -ModuleName PSFabricDataAgentObservability Invoke-RestMethod { throw 'fda down' }
        { Invoke-FDAQuery -AgentEndpoint 'https://fda' -Question 'q' } | Should -Throw
        Should -Invoke -ModuleName PSFabricDataAgentObservability Add-FDAFlushEntry -ParameterFilter { $Synchronous } -Times 1
    }
}

Describe 'New-FDAObservabilityReport' {
    AfterEach { InModuleScope PSFabricDataAgentObservability { $script:FDAState.Connected = $false } }
    BeforeEach {
        Mock -ModuleName PSFabricDataAgentObservability Invoke-KQLQuery { @([pscustomobject]@{ User = 'a@b.com'; Calls = 3 }) }
        InModuleScope PSFabricDataAgentObservability { $script:FDAState.Connected = $true }
    }
    It 'throws when not connected' {
        InModuleScope PSFabricDataAgentObservability { $script:FDAState.Connected = $false }
        { New-FDAObservabilityReport -Type DailyOps } | Should -Throw -ExpectedMessage '*Not connected*'
    }
    It 'returns rows for each report type' {
        foreach ($t in 'DailyOps', 'FailureSummary', 'TopUsers', 'Slowest', 'CostByUser') {
            (New-FDAObservabilityReport -Type $t).Calls | Should -Be 3
        }
    }
    It 'writes a Markdown report to disk' {
        $out = Join-Path $TestDrive 'report.md'
        New-FDAObservabilityReport -Type TopUsers -OutFile $out -InformationAction SilentlyContinue | Out-Null
        Test-Path $out | Should -BeTrue
        (Get-Content $out -Raw) | Should -Match 'Top Users by Activity'
    }
    It 'writes JSON and CSV reports to disk' {
        $json = Join-Path $TestDrive 'report.json'; $csv = Join-Path $TestDrive 'report.csv'
        New-FDAObservabilityReport -Type DailyOps -OutFile $json -InformationAction SilentlyContinue | Out-Null
        New-FDAObservabilityReport -Type DailyOps -OutFile $csv  -InformationAction SilentlyContinue | Out-Null
        (Test-Path $json) -and (Test-Path $csv) | Should -BeTrue
    }
    It 'New-FDAReportMarkdown renders an empty-window note' {
        $md = & (Get-Module PSFabricDataAgentObservability) { New-FDAReportMarkdown -Type DailyOps -Rows @() }
        $md | Should -Match '_No rows in window._'
    }
}

Describe 'Test-FDAObservability health check' {
    AfterEach { InModuleScope PSFabricDataAgentObservability { $script:FDAState.Connected = $false } }
    It 'reports a single Fail when not connected' {
        InModuleScope PSFabricDataAgentObservability { $script:FDAState.Connected = $false }
        $r = Test-FDAObservability
        @($r).Where({ $_.Check -eq 'Connection' }).Status | Should -Be 'Fail'
    }
    It 'runs all checks and passes on a healthy environment' {
        Mock -ModuleName PSFabricDataAgentObservability Get-FDAAccessToken { 'tok' }
        Mock -ModuleName PSFabricDataAgentObservability Write-FDALog { }
        Mock -ModuleName PSFabricDataAgentObservability Invoke-FDAFlush { }
        Mock -ModuleName PSFabricDataAgentObservability Start-Sleep { }
        Mock -ModuleName PSFabricDataAgentObservability Invoke-KQLQuery {
            if ($Query -like '*.show tables*') {
                'FDAInteractions','FDAInteractionsRaw','FDAExecutions','FDAExecutionsRaw','FDAAuthEvents','FDAAuthEventsRaw','FDACostMetering','FDACostMeteringRaw','FDALogEvents','FDALogEventsRaw','FDALogLevels','FDAConfiguration' |
                    ForEach-Object { [pscustomobject]@{ TableName = $_ } }
            } elseif ($Query -like '*GetActiveLogLevels*') { @([pscustomobject]@{ Count = 5 }) }
            elseif ($Query -like '*Properties.Marker*')     { @([pscustomobject]@{ Count = 1 }) }
            else { @([pscustomobject]@{ x = 1 }) }
        }
        $spool = Join-Path $TestDrive 'healthspool'; New-Item -ItemType Directory -Path $spool -Force | Out-Null
        $r = InModuleScope PSFabricDataAgentObservability -Parameters @{ Spool = $spool } {
            param($Spool)
            $script:FDAState.Connected = $true; $script:FDAState.AuthMethod = 'ServicePrincipal'
            $script:FDAState.WorkspaceId = 'w'; $script:FDAState.SpoolPath = $Spool
            Test-FDAObservability
        }
        @($r).Where({ $_.Check -eq 'Connection' }).Status      | Should -Be 'Pass'
        @($r).Where({ $_.Check -eq 'Schema' }).Status          | Should -Be 'Pass'
        @($r).Where({ $_.Check -eq 'Round-trip ingest' }).Status | Should -Be 'Pass'
    }
}

Describe 'Sync-FDAGovernanceLog' {
    AfterEach { InModuleScope PSFabricDataAgentObservability { $script:FDAState.Connected = $false; $script:FDAState.TenantId = $null } }
    It 'throws when no tenant is set' {
        InModuleScope PSFabricDataAgentObservability { $script:FDAState.Connected = $true; $script:FDAState.TenantId = $null }
        { Sync-FDAGovernanceLog } | Should -Throw -ExpectedMessage '*TenantId is required*'
    }
    It 'pulls audit content, filters operations, and ingests matching events' {
        Mock -ModuleName PSFabricDataAgentObservability Get-FDAAccessToken { 'tok' }
        Mock -ModuleName PSFabricDataAgentObservability Invoke-WebRequest {
            [pscustomobject]@{ Content = (@(@{ contentUri = 'https://content/1' }) | ConvertTo-Json); Headers = @{} }
        }
        Mock -ModuleName PSFabricDataAgentObservability Invoke-RestMethod {
            if ($Uri -like '*subscriptions/start*') { return $null }
            @(
                [pscustomobject]@{ Operation = 'GetDataAgent'; Id = 'e1'; CorrelationId = 'c1'; OrganizationId = 't'; UserId = 'u@x'; ResultStatus = 'Succeeded'; CreationTime = '2026-01-01T00:00:00Z'; ClientIP = '1.2.3.4'; UserType = 'Member'; ConsentStatus = 'Granted'; RLSContext = $null; UserAgent = 'ua'; Workload = 'PowerBI' },
                [pscustomobject]@{ Operation = 'IgnoredOp';   Id = 'e2'; CorrelationId = 'c2'; OrganizationId = 't'; UserId = 'u@x'; ResultStatus = 'Failed';    CreationTime = '2026-01-01T00:00:00Z'; ClientIP = '1.2.3.4'; UserType = 'Member'; ConsentStatus = 'n/a';     RLSContext = $null; UserAgent = 'ua'; Workload = 'PowerBI' }
            )
        }
        Mock -ModuleName PSFabricDataAgentObservability Invoke-EventhouseIngest { }
        $r = InModuleScope PSFabricDataAgentObservability {
            $script:FDAState.Connected = $true; $script:FDAState.TenantId = 'tid'
            Sync-FDAGovernanceLog -LookbackHours 1
        }
        $r.Synced | Should -Be 1   # only GetDataAgent passes the operation filter
        Should -Invoke -ModuleName PSFabricDataAgentObservability Invoke-EventhouseIngest -Times 1
    }
}

Describe 'Get-FDAHttpStatusCode' {
    It 'returns null for a non-HTTP exception' {
        $code = & (Get-Module PSFabricDataAgentObservability) {
            try { throw 'plain' } catch { Get-FDAHttpStatusCode -ErrorRecord $_ }
        }
        $code | Should -BeNullOrEmpty
    }
}

Describe 'Eventhouse / Kusto management helpers' {
    It 'New-FDAEventhouse POSTs displayName and returns the item' {
        Mock -ModuleName PSFabricDataAgentObservability Get-FDAAccessToken { 'tok' }
        Mock -ModuleName PSFabricDataAgentObservability Invoke-RestMethod { [pscustomobject]@{ id = 'eh-new'; displayName = ($Body | ConvertFrom-Json).displayName } }
        $eh = InModuleScope PSFabricDataAgentObservability { New-FDAEventhouse -WorkspaceId 'w' -DisplayName 'EH1' }
        $eh.id | Should -Be 'eh-new'
    }
    It 'Invoke-KustoManagementCommand throws when cluster URI unset' {
        { InModuleScope PSFabricDataAgentObservability { $script:FDAState.EventhouseClusterUri = $null; Invoke-KustoManagementCommand -Command '.show tables' } } |
            Should -Throw -ExpectedMessage '*cluster URI is not set*'
    }
    It 'Invoke-KustoManagementCommand posts the control command' {
        Mock -ModuleName PSFabricDataAgentObservability Get-FDAAccessToken { 'tok' }
        Mock -ModuleName PSFabricDataAgentObservability Invoke-RestMethod { 'mgmt-ok' }
        $r = InModuleScope PSFabricDataAgentObservability {
            $script:FDAState.EventhouseClusterUri = 'https://cluster'
            try { Invoke-KustoManagementCommand -Command '.create table T (A:string)' -Database 'FDAObs' }
            finally { $script:FDAState.EventhouseClusterUri = $null }
        }
        $r | Should -Be 'mgmt-ok'
    }
}

Describe 'Search-FDALog Contains across table variants' {
    BeforeAll { InModuleScope PSFabricDataAgentObservability { $script:FDAState.Connected = $true } }
    AfterAll  { InModuleScope PSFabricDataAgentObservability { $script:FDAState.Connected = $false } }
    BeforeEach { Mock -ModuleName PSFabricDataAgentObservability Invoke-KQLQuery { @([pscustomobject]@{ Q = $Query }) } }
    It 'builds the right contains clause per table' {
        (Search-FDALog -Table FDAExecutions -Contains 'x').Q   | Should -Match 'ExecutedDAX contains_cs'
        (Search-FDALog -Table FDAAuthEvents -Contains 'x').Q   | Should -Match 'ClientApp contains_cs'
        (Search-FDALog -Table FDACostMetering -Contains 'x').Q | Should -Match 'UserPrincipalName contains_cs'
        (Search-FDALog -Table FDALogEvents -Contains 'x').Q    | Should -Match 'Message contains_cs'
    }
}

Describe 'Invoke-FDAQuery redaction paths' {
    AfterEach { InModuleScope PSFabricDataAgentObservability { $script:FDAState.Connected = $false } }
    BeforeEach {
        Mock -ModuleName PSFabricDataAgentObservability Get-FDAObservabilityConfig {
            [pscustomobject]@{ StrictSchema = $false; FDAResourceScope = 'https://api.fabric.microsoft.com/.default' }
        }
        Mock -ModuleName PSFabricDataAgentObservability Get-FDAAccessToken { 'tok' }
        Mock -ModuleName PSFabricDataAgentObservability Add-FDAFlushEntry { }
        Mock -ModuleName PSFabricDataAgentObservability Invoke-RestMethod {
            [pscustomobject]@{
                answer = 'Contact a@b.com'; steps = @('s'); grounding = @('SSN 123-45-6789', [pscustomobject]@{ note = 'email x@y.com' })
                generatedQuery = 'EVALUATE'; usage = [pscustomobject]@{ prompt_tokens = 1; completion_tokens = 1; total_tokens = 2 }
            }
        }
        InModuleScope PSFabricDataAgentObservability { $script:FDAState.Connected = $true }
    }
    It 'redacts PII in answer and grounding by default' {
        $obj = Invoke-FDAQuery -AgentEndpoint 'https://fda' -Question 'Email me at a@b.com' -PassThru
        $obj.Status | Should -BeIn @('Success', 'PartialCapture')
        Should -Invoke -ModuleName PSFabricDataAgentObservability Add-FDAFlushEntry -Times 2
    }
    It 'skips redaction with -PreservePII and a consent claim' {
        $obj = Invoke-FDAQuery -AgentEndpoint 'https://fda' -Question 'q' -PreservePII -ConsentClaim 'consent-123' -PassThru
        $obj | Should -Not -BeNullOrEmpty
    }
}

Describe 'Initialize-FDAObservability provisioning' {
    AfterEach { InModuleScope PSFabricDataAgentObservability { $script:FDAState.Connected = $false } }
    It 'throws when not connected' {
        InModuleScope PSFabricDataAgentObservability { $script:FDAState.Connected = $false }
        { Initialize-FDAObservability -WorkspaceId 'w' -EventhouseId 'e' } | Should -Throw -ExpectedMessage '*Not connected*'
    }
    It 'provisions database, applies schema, and seeds levels/config (existing Eventhouse)' {
        Mock -ModuleName PSFabricDataAgentObservability Get-FDAEventhouseEndpoint {
            [pscustomobject]@{ DisplayName = 'EH'; QueryServiceUri = 'https://q'; IngestionServiceUri = 'https://i' }
        }
        Mock -ModuleName PSFabricDataAgentObservability Get-FDAAccessToken { 'tok' }
        Mock -ModuleName PSFabricDataAgentObservability Invoke-RestMethod {
            if ($Method -eq 'Get') { return [pscustomobject]@{ value = @() } }   # no existing DB
            return [pscustomobject]@{ id = 'db' }                                 # create DB
        }
        Mock -ModuleName PSFabricDataAgentObservability Invoke-KustoManagementCommand { }
        Mock -ModuleName PSFabricDataAgentObservability Invoke-EventhouseIngest { }
        Mock -ModuleName PSFabricDataAgentObservability Start-Sleep { }
        $res = InModuleScope PSFabricDataAgentObservability {
            $script:FDAState.Connected = $true
            Initialize-FDAObservability -WorkspaceId 'w' -EventhouseId 'e' -Confirm:$false
        }
        $res.Initialized | Should -BeTrue
        $res.EventhouseId | Should -Be 'e'
        Should -Invoke -ModuleName PSFabricDataAgentObservability Invoke-KustoManagementCommand -Times 1 -Because 'schema statements should be applied'
        Should -Invoke -ModuleName PSFabricDataAgentObservability Invoke-EventhouseIngest -Times 1 -Because 'levels and config should be seeded'
    }
}

Describe 'Connect-FDAObservability ManagedIdentity orchestration' {
    AfterEach { & (Get-Module PSFabricDataAgentObservability) { try { Disconnect-FDAObservability | Out-Null } catch { Write-Verbose "disconnect cleanup: $_" } } }
    It 'connects via IMDS and resolves endpoints' {
        Mock -ModuleName PSFabricDataAgentObservability Start-FDAFlushTimer { }
        Mock -ModuleName PSFabricDataAgentObservability Get-FDAObservabilityConfig { }
        Mock -ModuleName PSFabricDataAgentObservability Get-FDALogLevel { }
        Mock -ModuleName PSFabricDataAgentObservability Restore-FDASpool { }
        Mock -ModuleName PSFabricDataAgentObservability Invoke-RestMethod {
            if ($Uri -like '*169.254.169.254*') { return [pscustomobject]@{ access_token = 'MI-TOK'; expires_in = 3600 } }
            if ($Uri -like '*/eventhouses/*')    { return [pscustomobject]@{ displayName = 'EH'; properties = [pscustomobject]@{ queryServiceUri = 'https://q'; ingestionServiceUri = 'https://i'; minimumConsumptionUnits = 0 } } }
            throw "unexpected URI: $Uri"
        }
        $conn = Connect-FDAObservability -AuthMethod ManagedIdentity -WorkspaceId 'w' -EventhouseId 'e'
        $conn.Connected   | Should -BeTrue
        $conn.ClusterUri  | Should -Be 'https://q'
    }
}

Describe 'Flush timer lifecycle' {
    It 'starts and stops the background flush timer' {
        InModuleScope PSFabricDataAgentObservability {
            $script:FDAState.FlushTimer = $null
            Start-FDAFlushTimer -IntervalSeconds 60
            $script:FDAState.FlushTimer | Should -Not -BeNullOrEmpty
            Stop-FDAFlushTimer
            $script:FDAState.FlushTimer | Should -BeNullOrEmpty
        }
    }
}

Describe 'Invoke-FDAQuery extra branches' {
    AfterEach { InModuleScope PSFabricDataAgentObservability { $script:FDAState.Connected = $false } }
    BeforeEach {
        Mock -ModuleName PSFabricDataAgentObservability Get-FDAAccessToken { 'tok' }
        Mock -ModuleName PSFabricDataAgentObservability Add-FDAFlushEntry { }
        InModuleScope PSFabricDataAgentObservability { $script:FDAState.Connected = $true }
    }
    It 'throws under StrictSchema when the response shape diverges' {
        Mock -ModuleName PSFabricDataAgentObservability Get-FDAObservabilityConfig { [pscustomobject]@{ StrictSchema = $true; FDAResourceScope = 'https://api.fabric.microsoft.com/.default' } }
        Mock -ModuleName PSFabricDataAgentObservability Invoke-RestMethod { [pscustomobject]@{ answer = 'a' } }
        { Invoke-FDAQuery -AgentEndpoint 'https://fda' -Question 'q' } | Should -Throw
    }
    It 'parses the alternate response/citations/dax/modelName field names' {
        Mock -ModuleName PSFabricDataAgentObservability Get-FDAObservabilityConfig { [pscustomobject]@{ StrictSchema = $false; FDAResourceScope = 'https://api.fabric.microsoft.com/.default' } }
        Mock -ModuleName PSFabricDataAgentObservability Invoke-RestMethod {
            [pscustomobject]@{
                response = 'alt-answer'; reasoning = @('r'); citations = @('c'); dax = 'DAX'
                modelName = 'm'; usage = [pscustomobject]@{ prompt_tokens = 1; completion_tokens = 1; total_tokens = 2 }
            }
        }
        Invoke-FDAQuery -AgentEndpoint 'https://fda' -Question 'q' | Should -Be 'alt-answer'
    }
}

Describe 'Write-FDALog per-category threshold' {
    AfterEach { InModuleScope PSFabricDataAgentObservability { $script:FDAState.Connected = $false } }
    It 'applies a per-category minimum override' {
        Mock -ModuleName PSFabricDataAgentObservability Get-FDAObservabilityConfig {
            $c = [pscustomobject]@{ MinLevelNumeric = 10 }
            $c | Add-Member -NotePropertyName 'MinLevelByCategory.Quiet' -NotePropertyValue ([pscustomobject]@{ Numeric = 70 }) -PassThru
        }
        Mock -ModuleName PSFabricDataAgentObservability Add-FDAFlushEntry { }
        InModuleScope PSFabricDataAgentObservability { $script:FDAState.Connected = $true }
        Write-FDALog -Level Information -Message 'quiet' -Category 'Quiet'
        Should -Invoke -ModuleName PSFabricDataAgentObservability Add-FDAFlushEntry -Times 0
    }
}

Describe 'Invoke-KQLQuery non-transient failure' {
    It 'rethrows immediately on a non-transient error' {
        Mock -ModuleName PSFabricDataAgentObservability Get-FDAAccessToken { 'tok' }
        Mock -ModuleName PSFabricDataAgentObservability Invoke-RestMethod { throw 'hard failure' }
        { InModuleScope PSFabricDataAgentObservability {
            $script:FDAState.EventhouseClusterUri = 'https://cluster'
            try { Invoke-KQLQuery -Query 'x' } finally { $script:FDAState.EventhouseClusterUri = $null }
        } } | Should -Throw -ExpectedMessage '*failed after 1 attempts*'
    }
}

Describe 'Initialize-FDAObservability create-Eventhouse path' {
    AfterEach { InModuleScope PSFabricDataAgentObservability { $script:FDAState.Connected = $false } }
    It 'creates the Eventhouse, waits for endpoints, and provisions' {
        Mock -ModuleName PSFabricDataAgentObservability New-FDAEventhouse { [pscustomobject]@{ id = 'eh-created' } }
        Mock -ModuleName PSFabricDataAgentObservability Get-FDAEventhouseEndpoint {
            [pscustomobject]@{ DisplayName = 'EH'; QueryServiceUri = 'https://q'; IngestionServiceUri = 'https://i' }
        }
        Mock -ModuleName PSFabricDataAgentObservability Get-FDAAccessToken { 'tok' }
        Mock -ModuleName PSFabricDataAgentObservability Invoke-RestMethod {
            if ($Method -eq 'Get') { return [pscustomobject]@{ value = @([pscustomobject]@{ displayName = 'FDAObs' }) } }  # DB exists
            return [pscustomobject]@{ id = 'db' }
        }
        Mock -ModuleName PSFabricDataAgentObservability Invoke-KustoManagementCommand { }
        Mock -ModuleName PSFabricDataAgentObservability Invoke-EventhouseIngest { }
        Mock -ModuleName PSFabricDataAgentObservability Start-Sleep { }
        $res = InModuleScope PSFabricDataAgentObservability {
            $script:FDAState.Connected = $true
            Initialize-FDAObservability -WorkspaceId 'w' -CreateEventhouse -EventhouseName 'NewEH' -Confirm:$false
        }
        $res.EventhouseId | Should -Be 'eh-created'
        Should -Invoke -ModuleName PSFabricDataAgentObservability New-FDAEventhouse -Times 1
    }
}

Describe 'Test-FDAObservability failure branches' {
    AfterEach { InModuleScope PSFabricDataAgentObservability { $script:FDAState.Connected = $false } }
    It 'records Fail/Warning when token and queries error' {
        Mock -ModuleName PSFabricDataAgentObservability Get-FDAAccessToken { throw 'no token' }
        Mock -ModuleName PSFabricDataAgentObservability Invoke-KQLQuery { throw 'kql down' }
        Mock -ModuleName PSFabricDataAgentObservability Write-FDALog { }
        Mock -ModuleName PSFabricDataAgentObservability Invoke-FDAFlush { }
        Mock -ModuleName PSFabricDataAgentObservability Start-Sleep { }
        $spool = Join-Path $TestDrive 'fspool'; New-Item -ItemType Directory -Path $spool -Force | Out-Null
        $r = InModuleScope PSFabricDataAgentObservability -Parameters @{ Spool = $spool } {
            param($Spool)
            $script:FDAState.Connected = $true; $script:FDAState.AuthMethod = 'MI'; $script:FDAState.WorkspaceId = 'w'; $script:FDAState.SpoolPath = $Spool
            Test-FDAObservability
        }
        @($r).Where({ $_.Check -eq 'Token (Kusto)' }).Status | Should -Be 'Fail'
        @($r).Where({ $_.Check -eq 'Cluster Query' }).Status | Should -Be 'Fail'
    }
}

Describe 'Public function parameter contracts' {
    It 'Invoke-FDAQuery requires AgentEndpoint and Question' {
        $p = (Get-Command Invoke-FDAQuery).Parameters
        ($p['AgentEndpoint'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] }).Mandatory |
            Should -Contain $true
        ($p['Question'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] }).Mandatory |
            Should -Contain $true
    }
    It 'Connect-FDAObservability makes TenantId, WorkspaceId and EventhouseId optional' {
        $p = (Get-Command Connect-FDAObservability).Parameters
        foreach ($name in 'TenantId', 'WorkspaceId', 'EventhouseId') {
            $mandatory = $p[$name].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
                ForEach-Object Mandatory
            $mandatory | Should -Not -Contain $true -Because "$name must be optional for interactive selection"
        }
    }
    It 'Initialize-FDAObservability makes WorkspaceId and EventhouseId optional' {
        $p = (Get-Command Initialize-FDAObservability).Parameters
        foreach ($name in 'WorkspaceId', 'EventhouseId') {
            $mandatory = $p[$name].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
                ForEach-Object Mandatory
            $mandatory | Should -Not -Contain $true -Because "$name must be optional for interactive selection"
        }
    }
    It 'exposes interactive resolver helpers for connect/initialize' {
        & (Get-Module PSFabricDataAgentObservability) {
            foreach ($fn in 'Resolve-FDAWorkspace', 'Resolve-FDAEventhouse', 'Resolve-FDATenant',
                            'Get-FDAWorkspaceList', 'Get-FDAEventhouseList', 'New-FDAWorkspace') {
                Get-Command $fn -ErrorAction Stop | Should -Not -BeNullOrEmpty
            }
        }
    }
    It 'every exported function is resolvable' {
        $exported = (Get-Module PSFabricDataAgentObservability).ExportedFunctions.Keys
        $exported.Count | Should -BeGreaterThan 0
        foreach ($f in $exported) {
            Get-Command $f -ErrorAction Stop | Should -Not -BeNullOrEmpty
        }
    }
}
