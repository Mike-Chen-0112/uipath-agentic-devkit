[CmdletBinding()]
param(
    [string]$ProjectPath = (Get-Location).Path,
    [string[]]$FeatureEvidencePath = @(),
    [string]$OutputPath = '',
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'UiTargeting.psm1') -DisableNameChecking
$ProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path
$telemetryEvent = $null
if (Test-Path -LiteralPath (Join-Path $ProjectPath '.ai\evidence\execution-state.json') -PathType Leaf) {
    Import-Module (Join-Path $PSScriptRoot 'DeveloperTelemetry.psm1') -Force -DisableNameChecking
    $telemetryEvent = Start-DeveloperEvent -ProjectPath $ProjectPath -Category PACKAGE -Subcategory capability_detection -Operation 'package.capability_detection'
}
$result = Get-UiTargetCapabilities -ProjectPath $ProjectPath -FeatureEvidencePath $FeatureEvidencePath
if ($OutputPath) {
    $prefix = $ProjectPath.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    $fullOutput = if ([IO.Path]::IsPathRooted($OutputPath)) { [IO.Path]::GetFullPath($OutputPath) } else { [IO.Path]::GetFullPath((Join-Path $ProjectPath $OutputPath)) }
    if (-not $fullOutput.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Capability output path must stay within the project.' }
    New-Item -ItemType Directory -Force -Path (Split-Path $fullOutput -Parent) | Out-Null
    [IO.File]::WriteAllText($fullOutput, (($result | ConvertTo-Json -Depth 10) + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
}
if ($telemetryEvent) { Stop-DeveloperEvent -ProjectPath $ProjectPath -EventId $telemetryEvent.eventId -Status PASS -Artifacts $(if($OutputPath){@([ordered]@{path=$OutputPath})}else{@()}) | Out-Null }
if ($Json) { $result | ConvertTo-Json -Depth 10 } else { $result }
