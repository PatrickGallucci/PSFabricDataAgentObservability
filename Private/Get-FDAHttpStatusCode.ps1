function Get-FDAHttpStatusCode {
    <#
    .SYNOPSIS
        Safely extract an HTTP status code from an error record, returning $null
        when the exception is not an HTTP response error.
    .DESCRIPTION
        Under Set-StrictMode -Version Latest, blindly reading
        $_.Exception.Response.StatusCode throws "property cannot be found" for
        non-HTTP exceptions (e.g. a WebException with a null Response, or a
        generic error). This helper guards every hop so retry/transient logic
        can treat a missing status as "unknown".
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $ErrorRecord)

    $ex = $ErrorRecord.Exception
    if (-not $ex) { return $null }
    $respProp = $ex.PSObject.Properties['Response']
    if (-not $respProp -or -not $respProp.Value) { return $null }
    $scProp = $respProp.Value.PSObject.Properties['StatusCode']
    if (-not $scProp -or $null -eq $scProp.Value) { return $null }
    try { return [int]$scProp.Value } catch { return $null }
}
