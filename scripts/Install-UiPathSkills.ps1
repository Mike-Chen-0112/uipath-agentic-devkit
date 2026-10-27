[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$TargetBotPath = (Get-Location).Path,

    [ValidateSet('Local','Global')]
    [string]$Scope = 'Local',

    [switch]$Update
)

$ErrorActionPreference = 'Stop'
$TargetBotPath = (Resolve-Path $TargetBotPath).Path
$resolverScript = Join-Path $PSScriptRoot 'Resolve-DevKitTool.ps1'
if (-not (Test-Path $resolverScript -PathType Leaf)) { throw "Tool resolver is missing: $resolverScript" }
. $resolverScript
$uipCommand = Resolve-DevKitTool -Name uip -TargetBotPath $TargetBotPath -Required

Push-Location $TargetBotPath
try {
    $arguments = @('skills', $(if ($Update) { 'update' } else { 'install' }), '--agent', 'copilot')
    if ($Scope -eq 'Local') { $arguments += '--local' }

    if ($Update) {
        Write-Host "Updating UiPath Copilot skills at $Scope scope from $TargetBotPath"
    } else {
        Write-Host "Installing UiPath Copilot skills at $Scope scope from $TargetBotPath"
    }
    & $uipCommand @arguments
    if ($LASTEXITCODE -ne 0) { throw "UiPath skills command failed with exit code $LASTEXITCODE" }
}
finally {
    Pop-Location
}
