[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$temp=Join-Path $env:TEMP ('rpa-autonomy-'+[guid]::NewGuid().ToString('N'))
function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
try{
    New-Item -ItemType Directory -Path $temp | Out-Null
    $stateScript=Join-Path $root 'scripts\ExecutionState.ps1'
    & $stateScript -Action Start -TaskType modification -TargetBotPath $temp -NowUtc '2026-10-20T10:00:00Z' -Json | Out-Null
    & $stateScript -Action EnvironmentStart -Reason 'Automatic runtime repair' -TargetBotPath $temp -NowUtc '2026-10-20T10:00:10Z' -Json | Out-Null
    & $stateScript -Action Pause -TargetBotPath $temp -Reason 'Explicit user wait' -NowUtc '2026-10-20T10:01:00Z' -Json | Out-Null
    & $stateScript -Action Resume -TargetBotPath $temp -NowUtc '2026-10-20T10:02:00Z' -Json | Out-Null
    $setup=& $stateScript -Action EnvironmentEnd -TargetBotPath $temp -NowUtc '2026-10-20T10:05:10Z' -Json | ConvertFrom-Json
    Assert-True ($setup.execution.environment_setup_seconds -eq 240 -and $setup.execution.implementation_seconds -eq 10 -and $setup.execution.active_execution_seconds -eq 250 -and $setup.execution.total_wall_seconds -eq 310) 'Setup/wall/wait/implementation clocks did not reconcile.'
    Assert-True ($null -eq $setup.execution.remaining_hard_limit_seconds -and $null -eq $setup.execution.hard_limit_reached) 'Execution state still exposes a time budget.'
    $resume=& $stateScript -Action Start -Resume -TaskType modification -TargetBotPath $temp -NowUtc '2026-10-20T10:05:11Z' -Json | ConvertFrom-Json
    Assert-True ($resume.execution_id -eq $setup.execution_id -and $resume.environment_setup.active_seconds -eq 240) 'Resume reset execution identity or setup history.'
    $again=& $stateScript -Action EnvironmentStart -Reason 'second setup' -TargetBotPath $temp -NowUtc '2026-10-20T10:05:12Z' -Json | ConvertFrom-Json
    Assert-True ($again.environment_setup.active_seconds -eq 240 -and $again.environment_setup.status -eq 'PASS') 'Repeated environment setup reset the recorded setup interval.'
    $legacy=Join-Path $temp 'legacy';New-Item -ItemType Directory -Path $legacy | Out-Null
    & $stateScript -Action Start -TaskType modification -TargetBotPath $legacy -NowUtc '2026-10-20T10:00:00Z' -Json | Out-Null
    $legacyPath=Join-Path $legacy '.ai\evidence\execution-state.json'
    $legacyState=Get-Content $legacyPath -Raw|ConvertFrom-Json
    $legacyState.PSObject.Properties.Remove('environment_setup')
    $legacyState.execution.PSObject.Properties.Remove('environment_setup_seconds')
    $legacyState.execution.PSObject.Properties.Remove('implementation_seconds')
    $legacyState.execution | Add-Member -NotePropertyName hard_limit_reached -NotePropertyValue $true
    $legacyState.execution | Add-Member -NotePropertyName remaining_hard_limit_seconds -NotePropertyValue 0
    $legacyState.max_repair_loops = 2
    $legacyState|ConvertTo-Json -Depth 15|Set-Content $legacyPath -Encoding UTF8
    $legacyResume=& $stateScript -Action Start -Resume -TaskType modification -TargetBotPath $legacy -NowUtc '2026-10-20T10:00:01Z' -Json|ConvertFrom-Json
    Assert-True ($legacyResume.environment_setup.status -eq 'NOT_STARTED' -and $legacyResume.execution.implementation_seconds -eq 1) 'Older active execution could not resume with additive setup fields.'
    Assert-True ($null -eq $legacyResume.execution.hard_limit_reached -and $legacyResume.max_repair_loops -eq 3) 'Legacy budget fields or repair cap were not migrated on resume.'
    $longRun=& $stateScript -Action RepairStart -TargetBotPath $legacy -NowUtc '2026-10-20T14:00:00Z' -Json | ConvertFrom-Json
    Assert-True ($longRun.repair_loops -eq 1) 'A long-running execution was blocked by elapsed time.'

    Import-Module (Join-Path $root 'scripts\UiPathCompatibility.psm1') -Force
    & (Get-Module UiPathCompatibility) {function script:Get-InstalledProductVersion {param($ProductPattern) return 'UNKNOWN'}}
    [ordered]@{name='Recovery';studioVersion='26.0.204.0';targetFramework='Windows';dependencies=@{}} | ConvertTo-Json | Set-Content (Join-Path $temp 'project.json') -Encoding UTF8
    $unknown=Get-UiPathEnvironmentCompatibility -ProjectPath $temp -AvailableUiAutomationVersion '26.10.6'
    Assert-True ($unknown.detectedStudioVersion -eq 'UNKNOWN' -and $unknown.projectGeneratorStudioVersion -eq '26.0.204.0' -and $unknown.selectedUiAutomationVersion -eq 'UNKNOWN') 'Generator metadata was mistaken for the installed authoring host.'
    $evidence=Join-Path $temp 'compatibility.json'
    @{schemaVersion=1;studioVersion='26.0.204.0';cliVersion='1.2.3';packages=@(@{version='26.10.6';reference='https://docs.uipath.com/activities/other/latest/ui-automation/about-the-ui-automation-activities-package'})} | ConvertTo-Json -Depth 5 | Set-Content $evidence -Encoding UTF8
    $selected=Get-UiPathEnvironmentCompatibility -ProjectPath $temp -StudioVersion '26.0.204.0' -CliVersion '1.2.3' -AvailableUiAutomationVersion '26.10.6' -CompatibilityEvidencePath $evidence
    Assert-True ($selected.compatibilityDecision -eq 'SELECT_DOCUMENTED_COMPATIBLE' -and $selected.selectedUiAutomationVersion -eq '26.10.6' -and $selected.compatibilityEvidence.documentation.sha256) 'Documented cross-release candidate was not selected.'
    $staleDenied=$false
    try{Get-UiPathEnvironmentCompatibility -ProjectPath $temp -StudioVersion '26.0.204.0' -CliVersion '2.0.0' -CompatibilityEvidencePath $evidence | Out-Null}catch{$staleDenied=$true}
    Assert-True $staleDenied 'Mismatched CLI compatibility evidence was accepted.'
    @{name='Recovery';targetFramework='Windows';dependencies=@{'UiPath.UIAutomation.Activities'='[25.10.5]'}} | ConvertTo-Json | Set-Content (Join-Path $temp 'project.json') -Encoding UTF8
    $pin=Get-UiPathEnvironmentCompatibility -ProjectPath $temp -ProjectKind New -StudioVersion '26.0.204.0' -CliVersion '1.2.3' -AvailableUiAutomationVersion '26.10.6' -NewerReleaseCompatibilityEstablished
    Assert-True ($pin.selectedUiAutomationVersion -eq '25.10.5' -and $pin.compatibilityDecision -eq 'INCOMPATIBLE_RELEASE_TRAIN') 'Existing pin changed or an unsupported boolean asserted compatibility.'
    $packageRoot=Join-Path $temp 'package-cache'
    $packageDir=Join-Path $packageRoot '26.10.6'
    New-Item -ItemType Directory -Force -Path $packageDir | Out-Null
    $nuspec=Join-Path $packageDir 'uipath.uiautomation.activities.nuspec'
    '<package xmlns="http://schemas.microsoft.com/packaging/2013/05/nuspec.xsd"><metadata><id>UiPath.UIAutomation.Activities</id><version>26.10.6</version><description>IMPORTANT: This package version requires Studio 24.10 or higher.</description></metadata></package>' | Set-Content $nuspec -Encoding UTF8
    @{name='Minimum';targetFramework='Windows';dependencies=@{'UiPath.UIAutomation.Activities'='[26.10.6]'}} | ConvertTo-Json | Set-Content (Join-Path $temp 'project.json') -Encoding UTF8
    $met=Get-UiPathEnvironmentCompatibility -ProjectPath $temp -StudioVersion '26.0.204.0' -AdditionalPackageRoots $packageRoot -RequiredCapability ui
    Assert-True ($met.compatibilityDecision -eq 'PRESERVE_MINIMUM_REQUIREMENT_MET' -and $met.selectedUiAutomationVersion -eq '26.10.6' -and -not $met.capabilityFallbackRequired -and -not $met.automaticPackageUpgrade) 'Studio above the declared minimum was blocked by a different release line.'
    Assert-True ([bool]$met.compatibilityEvidence.packageMinimumRequirements['26.10.6'].sha256) 'Package minimum requirement provenance was not hashed.'
    $boundary=Get-UiPathEnvironmentCompatibility -ProjectPath $temp -StudioVersion '24.10.0.0' -AdditionalPackageRoots $packageRoot
    Assert-True ($boundary.compatibilityDecision -eq 'PRESERVE_MINIMUM_REQUIREMENT_MET') 'Exact minimum version was rejected.'
    $below=Get-UiPathEnvironmentCompatibility -ProjectPath $temp -StudioVersion '24.4.9' -AdditionalPackageRoots $packageRoot -RequiredCapability ui
    Assert-True ($below.compatibilityDecision -eq 'INCOMPATIBLE_STUDIO_MINIMUM' -and $below.capabilityFallbackRequired) 'Studio below the package minimum was accepted.'
    $unknownHost=Get-UiPathEnvironmentCompatibility -ProjectPath $temp -StudioVersion UNKNOWN -AdditionalPackageRoots $packageRoot
    Assert-True ($unknownHost.compatibilityDecision -eq 'PRESERVE_EXISTING_UNKNOWN_ENVIRONMENT') 'Unknown Studio was treated as meeting a package minimum.'
    $missing=Get-UiPathEnvironmentCompatibility -ProjectPath $temp -StudioVersion '26.0.204.0'
    Assert-True ($missing.compatibilityDecision -eq 'INCOMPATIBLE_RELEASE_TRAIN') 'Missing package metadata established minimum compatibility.'
    @{name='Minimum';targetFramework='Windows';dependencies=@{}} | ConvertTo-Json | Set-Content (Join-Path $temp 'project.json') -Encoding UTF8
    $newMinimum=Get-UiPathEnvironmentCompatibility -ProjectPath $temp -ProjectKind New -StudioVersion '26.0.204.0' -AdditionalPackageRoots $packageRoot
    Assert-True ($newMinimum.compatibilityDecision -eq 'SELECT_MINIMUM_REQUIREMENT_MET' -and $newMinimum.selectedUiAutomationVersion -eq '26.10.6') 'New project did not select the available minimum-compatible package.'
    $runner=Join-Path $root 'scripts\Invoke-DevKitCommand.ps1'
    $runtimeBot=Join-Path $temp 'runtime-child';$local=Join-Path $runtimeBot '.rpa-ai\local'
    New-Item -ItemType Directory -Force -Path $local | Out-Null
    $dotnet=Join-Path $runtimeBot 'dotnet.exe';$config=Join-Path $runtimeBot 'compiler.runtimeconfig.json'
    'fixture host' | Set-Content $dotnet -Encoding ASCII
    '{}' | Set-Content $config -Encoding ASCII
    $record=Join-Path $local 'dotnet-runtime.json'
    @{status='PASS';architecture='x64';dotnetRoot=$runtimeBot;dotnetPath=$dotnet;dotnetSha256=(Get-FileHash $dotnet).Hash;runtimeConfigSources=@(@{path=$config;sha256=(Get-FileHash $config).Hash})} | ConvertTo-Json -Depth 5 | Set-Content $record -Encoding UTF8
    $hostExe=(Get-Process -Id $PID).Path
    $child=& $runner -FilePath $hostExe -ArgumentList @('-NoProfile','-Command','[Console]::Write($env:DOTNET_ROOT_X64)') -TargetBotPath $runtimeBot -Json | ConvertFrom-Json
    Assert-True ($child.status -eq 'PASS' -and $child.output -eq $runtimeBot) 'Verified runtime was not propagated to the compiler child environment.'
    'changed' | Set-Content $config
    $staleRuntimeDenied=$false
    try{& $runner -FilePath $hostExe -ArgumentList @('-NoProfile','-Command','exit 0') -TargetBotPath $runtimeBot -Json | Out-Null}catch{$staleRuntimeDenied=$true}
    Assert-True $staleRuntimeDenied 'Stale runtimeconfig evidence was reused.'
    $bypassDenied=$false
    try{& $runner -FilePath $hostExe -SkipRuntimeSelection -TargetBotPath $runtimeBot -Json | Out-Null}catch{$bypassDenied=$true}
    Assert-True $bypassDenied 'Ordinary commands bypassed runtime verification.'
    Write-Host '[PASS] Autonomous setup clocks, limits, approval, resume, reserve and compatibility evidence.'
}
finally{
    Remove-Module UiPathCompatibility -ErrorAction SilentlyContinue
    if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}
}
