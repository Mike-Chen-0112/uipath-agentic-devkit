[CmdletBinding()]
param(
    [string]$TargetBotPath = (Get-Location).Path,
    [ValidateSet('Auto','Uv','Pipx')]
    [string]$Installer = 'Auto',
    [switch]$ForceGraphifyReinstall,
    [switch]$EnableGraphify,
    [string[]]$RuntimeConfigPath = @(),
    [string]$CompilerPath,
    [ValidateSet('x64','x86','arm64')]
    [string]$RuntimeArchitecture = 'x64',
    [switch]$NoRuntimeInstall,
    [switch]$SkipDependencyRestore
)

$ErrorActionPreference = 'Stop'
$TargetBotPath = (Resolve-Path $TargetBotPath).Path
$scriptRoot = Join-Path $TargetBotPath '.rpa-ai\scripts'
$integrityScript = Join-Path $scriptRoot 'Test-ManagedFileIntegrity.ps1'
$resolverScript = Join-Path $scriptRoot 'Resolve-DevKitTool.ps1'
$prerequisiteScript = Join-Path $scriptRoot 'Install-DevKitPrerequisites.ps1'
$installScript = Join-Path $scriptRoot 'Install-Graphify.ps1'
$refreshScript = Join-Path $scriptRoot 'Refresh-BotGraph.ps1'
$skillsScript = Join-Path $scriptRoot 'Install-UiPathSkills.ps1'
$diagnosticsScript = Join-Path $scriptRoot 'Get-DevKitDiagnostics.ps1'

foreach ($requiredScript in @($integrityScript,$resolverScript,$prerequisiteScript,$installScript,$refreshScript,$skillsScript,$diagnosticsScript)) {
    if (-not (Test-Path $requiredScript -PathType Leaf)) {
        throw "Activation dependency is missing: $requiredScript"
    }
}

& $integrityScript -TargetBotPath $TargetBotPath
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host '[WARN] Git not found. The kit still works; change review falls back to file snapshots and update checks are skipped.'
}
& $prerequisiteScript -TargetBotPath $TargetBotPath -IncludeGraphify:$EnableGraphify
. $resolverScript
$uipCommand = Resolve-DevKitTool -Name uip -TargetBotPath $TargetBotPath
$uipReady = $false
if ($uipCommand) {
    try {
        & $uipCommand --help *> $null
        $uipReady = $LASTEXITCODE -eq 0
    } catch {
        $uipReady = $false
    }
}
if (-not $uipReady) {
    $npmCommand = Resolve-DevKitTool -Name npm -TargetBotPath $TargetBotPath
    if (-not $npmCommand) {
        throw 'UiPath CLI bootstrap did not produce either uip or npm in the current user profile.'
    }
    $npmPrefix = Join-Path $env:LOCALAPPDATA 'RpaAiDevKit\tools\npm'
    New-Item -ItemType Directory -Force -Path $npmPrefix | Out-Null
    & $npmCommand install --global --prefix $npmPrefix '@uipath/cli'
    if ($LASTEXITCODE -ne 0) {
        Write-Host '[INFO] Retrying @uipath/cli installation once.'
        & $npmCommand install --global --prefix $npmPrefix '@uipath/cli'
    }
    if ($LASTEXITCODE -ne 0) { throw "User-scoped @uipath/cli installation failed with exit code $LASTEXITCODE. Check network access to the npm registry." }
    $uipCommand = Resolve-DevKitTool -Name uip -TargetBotPath $TargetBotPath -Required
}
& $uipCommand --help *> $null
if ($LASTEXITCODE -ne 0) { throw "UiPath CLI verification failed with exit code $LASTEXITCODE." }
if($RuntimeConfigPath.Count){
    $runtimeParameters=@{TargetBotPath=$TargetBotPath;RuntimeConfigPath=$RuntimeConfigPath;Architecture=$RuntimeArchitecture;NoInstall=$NoRuntimeInstall;Json=$true}
    if($CompilerPath){$runtimeParameters.CompilerPath=$CompilerPath}
    $runtimeResult=& (Join-Path $scriptRoot 'Initialize-UiPathRuntime.ps1') @runtimeParameters | ConvertFrom-Json
    if($runtimeResult.status -ne 'PASS'){throw "BLOCKED_DEPENDENCY: runtime readiness failed ($($runtimeResult.cause)). Inspect .rpa-ai\local\dotnet-runtime.json."}
}elseif($CompilerPath){
    throw 'RuntimeConfigPath is required for compiler/runtime verification; do not infer requirements from CLI help.'
}else{
    Write-Host '[INFO] Compiler runtime is verified on first restore/build; a missing .NET runtime is installed automatically for this user.'
}
& $skillsScript -TargetBotPath $TargetBotPath -Scope Local
if ($EnableGraphify) {
    try {
        & $installScript -TargetBotPath $TargetBotPath -Installer $Installer -ForceReinstall:$ForceGraphifyReinstall
    } catch {
        Write-Host "[INFO] Graphify installation failed ($($_.Exception.Message)); retrying with a clean reinstall."
        & $installScript -TargetBotPath $TargetBotPath -Installer $Installer -ForceReinstall
    }
} else {
    Write-Host '[INFO] Graphify is on-demand; skipping its installation and graph extraction.'
}

$graphPath = Join-Path $TargetBotPath 'graphify-out\graph.json'
function Test-BotGraph {
    if (-not (Test-Path $graphPath -PathType Leaf) -or (Get-Item $graphPath).Length -eq 0) { return $false }
    try { Get-Content $graphPath -Raw | ConvertFrom-Json | Out-Null; return $true } catch { return $false }
}
if ($EnableGraphify -and (Test-Path (Join-Path $TargetBotPath 'project.json') -PathType Leaf)) {
    $graphError = $null
    try { & $refreshScript -TargetBotPath $TargetBotPath -Mode Update } catch { $graphError = $_.Exception.Message }
    if ($graphError -or -not (Test-BotGraph)) {
        Write-Host '[INFO] Bot graph missing or invalid; rebuilding it from scratch.'
        & $refreshScript -TargetBotPath $TargetBotPath -Mode Update -Force
        if (-not (Test-BotGraph)) { throw "Graphify activation did not create a valid non-empty bot graph: $graphPath" }
    }
}
if (Test-Path (Join-Path $TargetBotPath 'project.json') -PathType Leaf) {
    if (-not $SkipDependencyRestore) {
        Write-Host '[INFO] Restoring UiPath project dependencies.'
        # The CLI writes warnings to stderr; do not let them become terminating errors under 'Stop'.
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & $uipCommand rpa restore $TargetBotPath 2>&1 | ForEach-Object { Write-Host ([string]$_) }
            $restoreExit = $LASTEXITCODE
            $uipVersion = if ($restoreExit -eq 0) { (& $uipCommand --version 2>$null | Out-String).Trim() } else { '' }
        } finally { $ErrorActionPreference = $previousPreference }
        if ($restoreExit -eq 0) {
            if (-not $uipVersion) { $uipVersion = 'UNKNOWN' }
            $dependencyStatePath = Join-Path $TargetBotPath '.ai\evidence\dependency-state.json'
            & (Join-Path $scriptRoot 'Get-DependencyState.ps1') -ProjectPath $TargetBotPath -StatePath $dependencyStatePath -CliVersion $uipVersion -AvailabilityStatus VERIFIED -Record -Json | Out-Null
            Write-Host '[PASS] Project dependencies restored.'
        } else {
            Write-Host "[WARN] Dependency restore exited with $restoreExit; the Developer agent will diagnose and repair it during validation."
        }
    }
} else {
    Write-Host '[INFO] New-bot workspace detected; Graphify extraction deferred until the scaffold is stable when requested.'
}

& $diagnosticsScript -TargetBotPath $TargetBotPath -CheckGraphify:$EnableGraphify
if ($LASTEXITCODE -ne 0) { throw "Dev Kit diagnostics failed with exit code $LASTEXITCODE." }
Write-Host ''
Write-Host '+------------------------------------------------------+'
Write-Host '|              RPA AI DEV KIT IS READY                 |'
Write-Host '|  Open Copilot Chat and select: RPA Coordinator       |'
Write-Host '+------------------------------------------------------+'
Write-Host "Bot: $TargetBotPath"