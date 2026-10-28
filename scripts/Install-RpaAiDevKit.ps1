[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$TargetBotPath,

    [switch]$InstallUiPathSkills,
    [switch]$UpdateUiPathSkills,
    [switch]$InstallGraphify,
    [switch]$SlimPayload,
    [switch]$EnableGraphifyHooks,
    [switch]$Upgrade,
    [switch]$ForceManagedFiles,
    [string[]]$RuntimeConfigPath = @(),
    [string]$CompilerPath,
    [ValidateSet('x64','x86','arm64')]
    [string]$RuntimeArchitecture = 'x64',
    [switch]$NoRuntimeInstall
)

$ErrorActionPreference = 'Stop'
$kitRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$TargetBotPath = (Resolve-Path $TargetBotPath).Path
$kitVersionPath = Join-Path $kitRoot 'VERSION'
$kitVersion = (Get-Content $kitVersionPath -Raw).Trim()

$temporaryExport = Join-Path $env:TEMP ('rpa-ai-devkit-install-' + [guid]::NewGuid().ToString('N'))
try {
    & (Join-Path $kitRoot 'scripts\Export-RpaAiDevKit.ps1') -OutputDirectory $temporaryExport -NoZip -SlimPayload:$SlimPayload
    $payload = Get-ChildItem $temporaryExport -Directory | Select-Object -First 1
    if (-not $payload) { throw 'Payload export did not produce a directory.' }

    & (Join-Path $kitRoot 'scripts\Import-RpaAiDevKit.ps1') `
        -PayloadPath $payload.FullName `
        -TargetBotPath $TargetBotPath `
        -Upgrade `
        -OverwriteManaged:$ForceManagedFiles `
        -EnableGraphify:$InstallGraphify
}
finally {
    Remove-Item $temporaryExport -Recurse -Force -ErrorAction SilentlyContinue
}

$botScriptDir = Join-Path $TargetBotPath '.rpa-ai\scripts'
if (-not (Test-Path (Join-Path $botScriptDir 'Activate-RpaAiDevKit.ps1') -PathType Leaf)) {
    throw "Installed Dev Kit activation script is missing: $botScriptDir"
}
if($RuntimeConfigPath.Count -or $CompilerPath){
    if(-not $RuntimeConfigPath.Count){throw 'RuntimeConfigPath is required for compiler/runtime verification.'}
    $runtimeParameters=@{TargetBotPath=$TargetBotPath;RuntimeConfigPath=$RuntimeConfigPath;Architecture=$RuntimeArchitecture;NoInstall=$NoRuntimeInstall;Json=$true}
    if($CompilerPath){$runtimeParameters.CompilerPath=$CompilerPath}
    $runtimeResult=& (Join-Path $botScriptDir 'Initialize-UiPathRuntime.ps1') @runtimeParameters | ConvertFrom-Json
    if($runtimeResult.status -ne 'PASS'){throw 'BLOCKED_DEPENDENCY: runtime readiness failed; inspect .rpa-ai\local\dotnet-runtime.json.'}
}

if ($Upgrade) {
    Write-Host '[INFO] -Upgrade is retained for command compatibility; unchanged managed files are now upgraded automatically.'
}
if ($EnableGraphifyHooks) {
    throw "-EnableGraphifyHooks is disabled by the v$kitVersion local-only policy. Graph refreshes run through hardened Dev Kit wrappers."
}

if ($InstallUiPathSkills) {
    Write-Host '[INFO] -InstallUiPathSkills is retained for command compatibility; activation now installs local UiPath skills automatically.'
}
if ($UpdateUiPathSkills) {
    & (Join-Path $kitRoot 'scripts\Install-UiPathSkills.ps1') -TargetBotPath $TargetBotPath -Scope Local -Update:$UpdateUiPathSkills
}

Write-Host ""
Write-Host "RPA AI Dev Kit installation complete."
Write-Host "Next:"
Write-Host "  1. Open the bot repo in VS Code."
Write-Host "  2. Put available source documents in .ai/intake/."
Write-Host "  3. Select 'RPA Coordinator' in Copilot Chat and describe the change you want."
