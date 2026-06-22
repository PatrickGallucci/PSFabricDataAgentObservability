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
        $r = & (Get-Module PSFabricDataAgentObservability) {
            # Shadow the interactive cmdlets within the module scope.
            function Read-Host { param($Prompt) 'contoso.onmicrosoft.com' }
            function Write-Host { param([Parameter(ValueFromRemainingArguments)]$x) }
            Resolve-FDATenant
        }
        $r | Should -Be 'contoso.onmicrosoft.com'
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
