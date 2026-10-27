[CmdletBinding()]
param(
    [string]$ProjectPath = (Get-Location).Path,
    [Parameter(Mandatory=$true)][string]$TargetsJson,
    [ValidateSet('Web','Native')][string]$ContextKind = 'Web',
    [string]$Browser = 'Chrome',
    [string]$Application = '',
    [string]$Domain = '',
    [string]$Page = '',
    [string]$Window = '',
    [string]$RegistryPath = '.devkit/ui-targets/registry.json',
    [string[]]$FeatureEvidencePath = @(),
    [string]$PolicyPath = '',
    [string]$EvidenceDirectory = '.ai/evidence/ui-targets',
    [switch]$ForceRediscovery,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'UiTargeting.psm1') -DisableNameChecking
$ProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path
$prefix = $ProjectPath.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
$evidenceRoot = [IO.Path]::GetFullPath((Join-Path $ProjectPath $EvidenceDirectory))
if (-not $evidenceRoot.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Batch evidence must stay within the project.' }
$policy = Get-UiTargetPolicy $PolicyPath
if ([Text.Encoding]::UTF8.GetByteCount($TargetsJson) -gt [int]$policy.artifacts.maxInputBytes) { throw 'TargetsJson exceeds the configured compact input limit.' }
try { $requests = @($TargetsJson | ConvertFrom-Json | ForEach-Object { $_ }) }
catch { throw "TargetsJson is invalid: $($_.Exception.Message)" }
if ($requests.Count -lt 1 -or $requests.Count -gt 64) { throw 'TargetsJson must contain 1 to 64 targets for one screen state.' }
$ids = @{}
foreach ($request in $requests) {
    if ([string]$request.targetId -notmatch '^[a-z0-9][a-z0-9._-]{2,127}$' -or -not [string]$request.logicalName) { throw 'Every target requires a stable targetId and logicalName.' }
    if ($ids.ContainsKey([string]$request.targetId)) { throw "Duplicate target ID in screen batch: $($request.targetId)" }
    $ids[[string]$request.targetId] = $true
}

$watch = [Diagnostics.Stopwatch]::StartNew()
$batchId = [guid]::NewGuid().ToString('N')
$results = New-Object System.Collections.Generic.List[object]
foreach ($request in $requests) {
    $arguments = @{
        ProjectPath=$ProjectPath; RegistryPath=$RegistryPath; TargetId=[string]$request.targetId
        LogicalName=[string]$request.logicalName; ContextKind=$ContextKind; Browser=$Browser
        Application=$Application; Domain=$Domain; Page=$Page; Window=$Window
        FeatureEvidencePath=$FeatureEvidencePath; PolicyPath=$PolicyPath; ForceRediscovery=$ForceRediscovery
        EvidencePath=(Join-Path $evidenceRoot "$batchId-$($request.targetId).json"); Json=$true
    }
    foreach ($name in @('ExpectedRole','SourceLocation','ReuseValidationStatus','ReuseValidationMethod','ReuseValidationDurationMs','ReuseMatchCount','ReuseActualRole','ExpectedTargetFingerprint')) {
        $property = @($request.PSObject.Properties | Where-Object Name -ieq $name) | Select-Object -First 1
        if ($property) { $arguments[$name] = $property.Value }
    }
    if ($request.PSObject.Properties.Name -contains 'candidates') {
        $arguments.DiscoveryCandidatesJson = ConvertTo-Json -InputObject @($request.candidates) -Depth 15 -Compress
    }
    $result = & (Join-Path $PSScriptRoot 'Resolve-UiTarget.ps1') @arguments | ConvertFrom-Json
    [void]$results.Add($result)
}
$watch.Stop()
$accepted = @($results | Where-Object { $_.status -in @('REUSED','RESOLVED') })
$summary = [ordered]@{
    schemaVersion=1; batchId=$batchId
    evidencePath=((Join-Path $evidenceRoot "$batchId-summary.json").Substring($prefix.Length) -replace '\\','/')
    status=$(if ($accepted.Count -eq $requests.Count) { 'PASS' } else { 'BLOCKED' })
    context=(Normalize-UiTargetContext -Kind $ContextKind -Browser $Browser -Application $Application -Domain $Domain -Page $Page -Window $Window)
    targetsRequired=$requests.Count; targetsAccepted=$accepted.Count
    uiCaptureComplete=($accepted.Count -eq $requests.Count)
    timingScope='RESOLUTION_BATCH_ONLY_NOT_END_TO_END_UI_CAPTURE'
    resolutionWallMs=[Math]::Round($watch.Elapsed.TotalMilliseconds,3)
    results=@($results | ForEach-Object {
        [ordered]@{ targetId=$_.targetId; logicalName=$_.logicalName; status=$_.status; binding=$_.binding; validation=$_.validation; evidencePath=$_.evidencePath; capabilityCacheStatus=$_.capability.cacheStatus }
    })
}
New-Item -ItemType Directory -Force -Path $evidenceRoot | Out-Null
$summaryPath = Join-Path $evidenceRoot "$batchId-summary.json"
[IO.File]::WriteAllText($summaryPath, (($summary | ConvertTo-Json -Depth 20) + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
if ($Json) { $summary | ConvertTo-Json -Depth 20 } else { [pscustomobject]$summary }
