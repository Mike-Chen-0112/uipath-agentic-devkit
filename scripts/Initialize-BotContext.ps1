[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$TargetBotPath = (Get-Location).Path,

    [Parameter(Mandatory=$false)]
    [string]$TemplateRoot
)

$ErrorActionPreference = 'Stop'
$TargetBotPath = (Resolve-Path $TargetBotPath).Path

if (-not $TemplateRoot) {
    $TemplateRoot = Join-Path $PSScriptRoot '..\templates\bot-context'
}
$TemplateRoot = (Resolve-Path $TemplateRoot).Path

$contextDir = Join-Path $TargetBotPath '.ai\context'
$evidenceDir = Join-Path $TargetBotPath '.ai\evidence'
$graphDir = Join-Path $TargetBotPath '.ai\graph'

New-Item -ItemType Directory -Force -Path $contextDir,$evidenceDir,$graphDir | Out-Null

Get-ChildItem $TemplateRoot -File | ForEach-Object {
    $dest = Join-Path $contextDir $_.Name
    if (-not (Test-Path $dest)) {
        Copy-Item $_.FullName $dest
        Write-Host "Created $dest"
    } else {
        Write-Host "Preserved existing $dest"
    }
}
