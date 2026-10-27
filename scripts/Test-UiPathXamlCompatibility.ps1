[CmdletBinding()]
param([string]$ProjectPath=(Get-Location).Path,[Parameter(Mandatory=$true)][string[]]$Workflow,[string]$EnvironmentJson,[string]$PolicyPath,[string]$AssemblyPath,[string[]]$ResolvedUiElementTypeValue=@(),[string]$ParentEventId='',[switch]$OmitUnsupportedOptionalProperty,[switch]$Json)
$ErrorActionPreference='Stop';Import-Module (Join-Path $PSScriptRoot 'UiPathCompatibility.psm1') -Force
$environment=if($EnvironmentJson){$EnvironmentJson|ConvertFrom-Json}else{Get-UiPathEnvironmentCompatibility -ProjectPath $ProjectPath}
$result=Test-UiPathXamlCompatibilityData -ProjectPath $ProjectPath -Workflow $Workflow -Environment $environment -PolicyPath $PolicyPath -AssemblyPath $AssemblyPath -ResolvedUiElementTypeValue $ResolvedUiElementTypeValue -ParentEventId $ParentEventId -OmitUnsupportedOptionalProperty:$OmitUnsupportedOptionalProperty
if($Json){$result|ConvertTo-Json -Depth 15}else{$result}
