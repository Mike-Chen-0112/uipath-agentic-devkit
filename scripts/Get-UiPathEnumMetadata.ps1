[CmdletBinding()]
param([string]$ProjectPath=(Get-Location).Path,[string]$PackageVersion='UNKNOWN',[string]$EnumTypeName='UIElementType',[string]$AssemblyPath,[string]$CacheDirectory,[switch]$Force,[switch]$Json)
$ErrorActionPreference='Stop';Import-Module (Join-Path $PSScriptRoot 'UiPathCompatibility.psm1') -Force
$result=Get-UiPathEnumMetadataData -ProjectPath $ProjectPath -PackageVersion $PackageVersion -EnumTypeName $EnumTypeName -AssemblyPath $AssemblyPath -CacheDirectory $CacheDirectory -Force:$Force
if($Json){$result|ConvertTo-Json -Depth 10}else{$result}
