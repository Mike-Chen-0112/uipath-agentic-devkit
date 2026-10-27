[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$pin = Get-Content (Join-Path $root 'graph\config\graphify-version.json') -Raw | ConvertFrom-Json
$fail = $false
$resolverScript = Join-Path $PSScriptRoot 'Resolve-DevKitTool.ps1'
. $resolverScript

function Get-CommandAvailability([string]$Name, [bool]$Required = $true) {
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { Write-Host "[PASS] $Name -> $($cmd.Source)"; return $true }
    if ($Required) { Write-Host "[FAIL] $Name not found"; $script:fail = $true }
    else { Write-Host "[INFO] $Name not found" }
    return $false
}

if (-not (Get-CommandAvailability 'git' $false)) {
    Write-Host '[INFO] Git is optional; without it change review uses file snapshots and kit update checks are skipped.'
}
$currentPowerShell = $PSVersionTable.PSVersion
if ($currentPowerShell -ge [version]'5.1') { Write-Host "[PASS] PowerShell $currentPowerShell" }
else { Write-Host "[FAIL] PowerShell 5.1 or later is required; found $currentPowerShell"; $fail = $true }
Get-CommandAvailability 'pwsh' $false | Out-Null
$uipCommand = Resolve-DevKitTool -Name uip -TargetBotPath $root
$npmCommand = Resolve-DevKitTool -Name npm -TargetBotPath $root
$hasUip = [bool]$uipCommand
if ($hasUip) { Write-Host "[PASS] uip -> $uipCommand" } else { Write-Host '[INFO] uip not found; activation will use discovered per-user npm when available.' }
if ($npmCommand) { Write-Host "[PASS] npm discovered -> $npmCommand" }
if (-not $hasUip -and -not $npmCommand) {
    Write-Host '[INFO] Neither uip nor npm was found; activation will install portable Node.js/npm and official @uipath/cli for this user.'
}

if ($hasUip) {
    & $uipCommand skills --help *> $null
    if ($LASTEXITCODE -eq 0) { Write-Host '[PASS] uip skills' }
    else { Write-Host '[FAIL] uip skills unavailable'; $fail = $true }

    & $uipCommand rpa init --help *> $null
    $hasInit = $LASTEXITCODE -eq 0
    & $uipCommand rpa create-project --help *> $null
    $hasCreateProject = $LASTEXITCODE -eq 0
    if ($hasInit) { Write-Host '[PASS] Greenfield command: uip rpa init' }
    elseif ($hasCreateProject) { Write-Host '[PASS] Greenfield command: uip rpa create-project' }
    else { Write-Host '[FAIL] No supported uip rpa project creation command'; $fail = $true }
}

$graphifyCommand = Resolve-DevKitTool -Name graphify -TargetBotPath $root
$uvCommand = Resolve-DevKitTool -Name uv -TargetBotPath $root
$pipxCommand = Resolve-DevKitTool -Name pipx -TargetBotPath $root
$hasGraphify = [bool]$graphifyCommand
$hasUv = [bool]$uvCommand
$hasPipx = [bool]$pipxCommand
if ($hasGraphify) { Write-Host "[PASS] graphify discovered -> $graphifyCommand (pin verified during activation)" }
if ($hasUv) { Write-Host "[PASS] uv discovered -> $uvCommand" }
if ($hasPipx) { Write-Host "[PASS] pipx discovered -> $pipxCommand" }
if (-not $hasGraphify -and -not $hasUv -and -not $hasPipx) {
    Write-Host '[INFO] Graphify tooling was not found; activation will install portable uv and the pinned Graphify package for this user.'
}

if ($fail) { exit 1 }
Write-Host "Prerequisite check complete."
