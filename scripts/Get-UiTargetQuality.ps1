[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Selector,
    [ValidateSet('StrictSelector','DomSelector','AnchorSelector','FuzzySelector','SemanticDom','SemanticImage','ComputerVision','Image','Coordinate','ObjectRepository')]
    [string]$Strategy = 'StrictSelector',
    [string]$AnchorSelector = '',
    [int]$MatchCount = -1,
    [string]$ExpectedRole = '',
    [string]$ActualRole = '',
    [string]$PolicyPath = '',
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'UiTargeting.psm1') -Force -DisableNameChecking
$policy = Get-UiTargetPolicy $PolicyPath
if ($Selector.Length -gt [int]$policy.artifacts.maxDescriptorCharacters -or $AnchorSelector.Length -gt [int]$policy.artifacts.maxDescriptorCharacters) { throw 'Selector or anchor exceeds the configured compact descriptor limit.' }
$result = Get-UiTargetQuality -Selector $Selector -Strategy $Strategy -AnchorSelector $AnchorSelector -MatchCount $MatchCount -ExpectedRole $ExpectedRole -ActualRole $ActualRole -PolicyPath $PolicyPath
if ($Json) { $result | ConvertTo-Json -Depth 8 } else { $result }
