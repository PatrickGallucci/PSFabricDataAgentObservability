function ConvertTo-EventhouseRecord {
    <#
    .SYNOPSIS
        Normalize a PowerShell object into a JSON-shaped record suitable for
        the *Raw landing tables. Wraps the payload with an IngestTime field.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object] $InputObject
    )
    process {
        $payload = $InputObject
        if ($payload -is [System.Collections.IDictionary]) {
            $payload = [pscustomobject]$payload
        }
        # Add IngestTime; the rest of the payload is preserved verbatim under "$".
        # We expand the payload fields to the top level for raw-table mapping.
        $ht = [ordered]@{
            IngestTime = (Get-Date).ToUniversalTime().ToString('o')
        }
        foreach ($p in $payload.PSObject.Properties) {
            $ht[$p.Name] = $p.Value
        }
        [pscustomobject]$ht
    }
}

function ConvertTo-FDARedactedText {
    <#
    .SYNOPSIS
        Apply the configured redaction patterns to a string and return both
        the redacted output and a bool indicating whether anything was redacted.
    #>
    [CmdletBinding()]
    param(
        [string] $InputText,
        [hashtable] $Patterns
    )
    if ([string]::IsNullOrEmpty($InputText)) {
        return [pscustomobject]@{ Text = $InputText; Redacted = $false }
    }
    if (-not $Patterns -or $Patterns.Count -eq 0) {
        $Patterns = $script:DefaultRedactionPatterns
    }
    $redacted = $false
    $out = $InputText
    foreach ($key in $Patterns.Keys) {
        $regex = [string] $Patterns[$key]
        if ([string]::IsNullOrWhiteSpace($regex)) { continue }
        $before = $out
        $out = [regex]::Replace($out, $regex, ('[REDACTED:{0}]' -f $key))
        if ($out -ne $before) { $redacted = $true }
    }
    [pscustomobject]@{ Text = $out; Redacted = $redacted }
}
