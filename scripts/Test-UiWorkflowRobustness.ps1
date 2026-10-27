[CmdletBinding()]
param(
    [string]$ProjectPath = (Get-Location).Path,
    [string[]]$ChangedFiles = @(),
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'UiWorkflowRobustness.psm1') -Force -DisableNameChecking
$ProjectPath = (Resolve-Path $ProjectPath).Path
$results = foreach ($file in @($ChangedFiles | Where-Object { [IO.Path]::GetExtension($_) -ieq '.xaml' } | Select-Object -Unique)) {
    $full = [IO.Path]::GetFullPath((Join-Path $ProjectPath $file))
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = [System.Xml.XmlReader]::Create($full, $settings)
    try { $document = New-Object System.Xml.XmlDocument; $document.XmlResolver = $null; $document.Load($reader) } finally { $reader.Dispose() }
    [ordered]@{ path = ($file -replace '\\','/'); findings = @(Get-UiWorkflowRobustnessFindings $document) }
}
$flat = @($results | ForEach-Object { $_.findings })
$output = [ordered]@{
    schemaVersion = 1
    status = if (@($flat | Where-Object { $_.severity -eq 'ERROR' }).Count) { 'FAIL' } else { 'PASS' }
    workflows = @($results)
}
if ($Json) { $output | ConvertTo-Json -Depth 8 } else { $output }
