<#
    Pester v5 smoke tests. These cover the units that do NOT require live
    Eventhouse / FDA endpoints: level resolution, redaction, KQL statement
    splitting, cost estimation, record shape. Integration tests live in
    examples/ — run them against a sandbox workspace.

    Run:
        Invoke-Pester -Path ./tests
#>

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'FabricDataAgentObservability.psd1'
    Import-Module $modulePath -Force
}

Describe 'Log level resolution' {
    It 'resolves built-in by name' {
        $r = & (Get-Module FabricDataAgentObservability) { Resolve-LogLevel -Level 'Warning' }
        $r.Name      | Should -Be 'Warning'
        $r.Numeric   | Should -Be 50
        $r.IsBuiltIn | Should -BeTrue
    }
    It 'resolves built-in by numeric (exact)' {
        $r = & (Get-Module FabricDataAgentObservability) { Resolve-LogLevel -Level 70 }
        $r.Name | Should -Be 'Error'
    }
    It 'resolves numeric between bands as Custom synthetic' {
        $r = & (Get-Module FabricDataAgentObservability) { Resolve-LogLevel -Level 42 }
        $r.Numeric | Should -Be 42
        $r.Name    | Should -Match '^Custom_'
    }
    It 'throws on unknown name' {
        { & (Get-Module FabricDataAgentObservability) { Resolve-LogLevel -Level 'Nope' } } |
            Should -Throw -ExpectedMessage 'Unknown log level*'
    }
}

Describe 'Redaction' {
    It 'redacts default PII patterns' {
        $r = & (Get-Module FabricDataAgentObservability) {
            ConvertTo-FDARedactedText -InputText 'SSN 123-45-6789, email a@b.com' -Patterns $script:DefaultRedactionPatterns
        }
        $r.Redacted | Should -BeTrue
        $r.Text     | Should -Match '\[REDACTED:SSN\]'
        $r.Text     | Should -Match '\[REDACTED:Email\]'
    }
    It 'leaves clean text untouched' {
        $r = & (Get-Module FabricDataAgentObservability) {
            ConvertTo-FDARedactedText -InputText 'Revenue by region last quarter' -Patterns $script:DefaultRedactionPatterns
        }
        $r.Redacted | Should -BeFalse
        $r.Text     | Should -Be 'Revenue by region last quarter'
    }
}

Describe 'KQL statement splitter' {
    It 'splits on blank lines' {
        $r = & (Get-Module FabricDataAgentObservability) {
            Split-FDAKqlStatements -Script @"
.show tables

.show database FDAObs principals


print x=1
"@
        }
        $r.Count | Should -Be 3
    }
    It 'strips // comments' {
        $r = & (Get-Module FabricDataAgentObservability) {
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
        $r = & (Get-Module FabricDataAgentObservability) {
            Get-FDACostEstimate -PromptTokens 1500 -CompletionTokens 500 -Config $null
        }
        $r.CapacityUnits | Should -Be 2.0
        $r.USD           | Should -Be 0.36
    }
    It 'honors config-supplied rates' {
        $cfg = [pscustomobject]@{
            CapacityRates = [pscustomobject]@{ TokensPerCU = 2000; USDPerCU = 0.10; Version = 'test' }
        }
        $r = & (Get-Module FabricDataAgentObservability) `
            -ArgumentList $cfg {
                param($cfg) Get-FDACostEstimate -PromptTokens 4000 -CompletionTokens 0 -Config $cfg
            }
        $r.CapacityUnits    | Should -Be 2.0
        $r.USD              | Should -Be 0.2
        $r.RateTableVersion | Should -Be 'test'
    }
}

Describe 'Record shape — Eventhouse landing wrapper' {
    It 'adds IngestTime and preserves fields' {
        $r = & (Get-Module FabricDataAgentObservability) {
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
