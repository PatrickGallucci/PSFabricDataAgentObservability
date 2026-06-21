<#
    02-connect-and-query.ps1
    Day-to-day usage. Replace direct FDA HTTP calls with Invoke-FDAQuery.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $TenantId,
    [Parameter(Mandatory)] [string] $WorkspaceId,
    [Parameter(Mandatory)] [string] $EventhouseId,
    [Parameter(Mandatory)] [uri]    $AgentEndpoint,
    [string] $Question = 'What was total revenue by region last quarter?'
)

Import-Module (Join-Path $PSScriptRoot '..' 'PSFabricDataAgentObservability.psd1') -Force

Connect-FDAObservability -AuthMethod UserDelegated -TenantId $TenantId `
    -WorkspaceId $WorkspaceId -EventhouseId $EventhouseId

# The full interaction is captured automatically. Answer is returned by default.
$answer = Invoke-FDAQuery -AgentEndpoint $AgentEndpoint -Question $Question
Write-Host "Answer: $answer" -ForegroundColor Green

# Get the typed object back too (raw response + parsed fields).
$result = Invoke-FDAQuery -AgentEndpoint $AgentEndpoint -Question $Question -PassThru
Write-Host ('Generated DAX:' )
Write-Host $result.GeneratedDAX -ForegroundColor Cyan
Write-Host ('Tokens used: prompt={0}, completion={1}, total={2}' -f $result.PromptTokens, $result.CompletionTokens, $result.TotalTokens)

# Confirm the interaction landed.
Start-Sleep -Seconds 6   # allow batch flush
Get-FDAInteraction -InteractionId $result.InteractionId | Format-List
