[CmdletBinding()]
param([string]$ProjectPath=(Get-Location).Path,[string]$StatePath,[string]$LedgerPath,[string]$NowUtc,[string]$OutputPath,[switch]$Json)
$ErrorActionPreference='Stop'
$ProjectPath=(Resolve-Path -LiteralPath $ProjectPath).Path
Import-Module (Join-Path $PSScriptRoot 'DeveloperTelemetry.psm1') -Force
$result=Get-DeveloperRuntimeBreakdownData -ProjectPath $ProjectPath -StatePath $StatePath -LedgerPath $LedgerPath -NowUtc $NowUtc
if($OutputPath){
    $full=if([IO.Path]::IsPathRooted($OutputPath)){[IO.Path]::GetFullPath($OutputPath)}else{[IO.Path]::GetFullPath((Join-Path $ProjectPath $OutputPath))}
    $prefix=$ProjectPath.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'OutputPath must stay within the project.'}
    New-Item -ItemType Directory -Force -Path (Split-Path $full -Parent)|Out-Null
    [IO.File]::WriteAllText($full,(($result|ConvertTo-Json -Depth 15)+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))
}
if($Json){$result|ConvertTo-Json -Depth 15}else{$result}
