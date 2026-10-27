[CmdletBinding()]
param(
    [ValidateSet('Initialize','Get','Upsert','MarkStale','Stats')][string]$Action = 'Get',
    [string]$ProjectPath = (Get-Location).Path,
    [string]$RegistryPath = '.devkit/ui-targets/registry.json',
    [string]$TargetId = '',
    [string]$TargetJson = '',
    [string]$Reason = '',
    [string]$PolicyPath = '',
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'UiTargeting.psm1') -Force -DisableNameChecking
$ProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path
$telemetryEvent = $null
if (Test-Path -LiteralPath (Join-Path $ProjectPath '.ai\evidence\execution-state.json') -PathType Leaf) {
    Import-Module (Join-Path $PSScriptRoot 'DeveloperTelemetry.psm1') -Force -DisableNameChecking
    $telemetryEvent = Start-DeveloperEvent -ProjectPath $ProjectPath -Category UI_TARGET -Subcategory $(if($Action -in @('Get','Stats')){'registry_lookup'}else{'persist'}) -Operation $(if($Action -in @('Get','Stats')){'ui.target.registry_lookup'}else{'ui.target.persist'})
}
$prefix = $ProjectPath.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
$fullRegistryPath = if ([IO.Path]::IsPathRooted($RegistryPath)) { [IO.Path]::GetFullPath($RegistryPath) } else { [IO.Path]::GetFullPath((Join-Path $ProjectPath $RegistryPath)) }
if (-not $fullRegistryPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'UI target registry path must stay within the project.' }
$policy = Get-UiTargetPolicy $PolicyPath
if ($TargetJson -and [Text.Encoding]::UTF8.GetByteCount($TargetJson) -gt [int]$policy.artifacts.maxInputBytes) { throw 'TargetJson exceeds the configured compact input limit.' }

function Get-PropertyValue {
    param($Object, [string]$Name, $Default = $null)
    if ($Object -and $Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $Default
}

function Normalize-TargetInput {
    param($InputTarget)
    $contextInput = Get-PropertyValue $InputTarget 'context'
    $context = if ($contextInput) {
        Normalize-UiTargetContext -Kind ([string](Get-PropertyValue $contextInput 'kind' 'Web')) -Browser ([string](Get-PropertyValue $contextInput 'browser' 'Chrome')) -Application ([string](Get-PropertyValue $contextInput 'application' '')) -Domain ([string](Get-PropertyValue $contextInput 'domain' '')) -Page ([string](Get-PropertyValue $contextInput 'page' '')) -Window ([string](Get-PropertyValue $contextInput 'window' ''))
    } else { Normalize-UiTargetContext }
    $primaryInput = Get-PropertyValue $InputTarget 'primary'
    if (-not $primaryInput) { throw 'TargetJson.primary is required.' }
    $strategy = [string](Get-PropertyValue $primaryInput 'strategy' 'StrictSelector')
    $descriptor = [string](Get-PropertyValue $primaryInput 'descriptor' '')
    $objectReference = [string](Get-PropertyValue $primaryInput 'objectRepositoryReference' '')
    if (-not $descriptor -and -not $objectReference) { throw 'TargetJson primary descriptor or Object Repository reference is required.' }
    if ($descriptor.Length -gt [int]$policy.artifacts.maxDescriptorCharacters) { throw 'Target descriptor exceeds the configured compact descriptor limit.' }
    if ($descriptor -match '(?i)(authorization\s*[:=]|bearer\s+[a-z0-9._-]{16,}|password\s*=\s*["''][^"'']+["'']|secret\s*=|token\s*=)') { throw 'Target descriptor appears to contain secret material and was not stored.' }
    $anchorInputs = @(Get-PropertyValue $InputTarget 'anchors' @())
    $anchorSelector = if ($anchorInputs.Count -gt 0) { [string](Get-PropertyValue $anchorInputs[0] 'descriptor' '') } else { '' }
    $quality = Get-PropertyValue $InputTarget 'quality'
    if (-not $quality) { $quality = Get-UiTargetQuality -Selector $(if ($descriptor) { $descriptor } else { $objectReference }) -Strategy $strategy -AnchorSelector $anchorSelector -PolicyPath $PolicyPath }
    $validation = Get-PropertyValue $InputTarget 'validation'
    if (-not $validation) { $validation = [ordered]@{ status='NOT_RUN'; level='NONE'; method=''; validatedAtUtc=$null; environmentFingerprint='' } }
    $now = [DateTime]::UtcNow.ToString('o')
    $target = [pscustomobject][ordered]@{
        targetId = [string](Get-PropertyValue $InputTarget 'targetId' $TargetId)
        logicalName = [string](Get-PropertyValue $InputTarget 'logicalName' '')
        context = $context
        elementRole = [string](Get-PropertyValue $InputTarget 'elementRole' '')
        primary = [ordered]@{ strategy=$strategy; descriptor=$descriptor; objectRepositoryReference=$objectReference }
        anchors = $anchorInputs
        fallbacks = @(Get-PropertyValue $InputTarget 'fallbacks' @())
        semanticDescription = [string](Get-PropertyValue $InputTarget 'semanticDescription' '')
        objectRepositoryReference = $objectReference
        quality = $quality
        lifecycle = [string](Get-PropertyValue $InputTarget 'lifecycle' 'DISCOVERED')
        validation = $validation
        capability = Get-PropertyValue $InputTarget 'capability'
        sourceLocations = @(Get-PropertyValue $InputTarget 'sourceLocations' @())
        artifact = Get-PropertyValue $InputTarget 'artifact'
        warnings = @(Get-PropertyValue $InputTarget 'warnings' @())
        fingerprint = ''
        createdAtUtc = [string](Get-PropertyValue $InputTarget 'createdAtUtc' $now)
        updatedAtUtc = $now
    }
    $validationStatus = [string](Get-PropertyValue $validation 'status' 'NOT_RUN')
    $validationLevel = [string](Get-PropertyValue $validation 'level' 'NONE')
    $validationMatchCount = [int](Get-PropertyValue $validation 'matchCount' -1)
    $target.lifecycle = if ($validationStatus -eq 'PASS' -and $validationLevel -eq 'LIVE' -and $validationMatchCount -eq 1) { 'REUSABLE' } elseif ($validationStatus -eq 'PASS') { 'VALIDATED' } else { 'DISCOVERED' }
    if ($target.targetId -notmatch '^[a-z0-9][a-z0-9._-]{2,127}$') { throw 'Target ID must be a stable lowercase identifier using letters, numbers, dot, underscore, or hyphen.' }
    if (-not $target.logicalName) { throw 'TargetJson.logicalName is required.' }
    $target.fingerprint = Get-UiTargetFingerprint $target
    return $target
}

$lock = $null
try {
    if ($Action -in @('Initialize','Upsert','MarkStale')) { $lock = Enter-UiTargetRegistryLock -RegistryPath $fullRegistryPath }
    $registry = Read-UiTargetRegistry -RegistryPath $fullRegistryPath -ProjectPath $ProjectPath
    $status = 'PASS'
    $targetResult = $null
    $duplicateTargetId = ''
    $writeMilliseconds = 0.0
    switch ($Action) {
        'Initialize' {
            $watch = [Diagnostics.Stopwatch]::StartNew(); Write-UiTargetRegistry -RegistryPath $fullRegistryPath -Registry $registry; $watch.Stop(); $writeMilliseconds = [Math]::Round($watch.Elapsed.TotalMilliseconds,3)
            $status = if ((Get-Item -LiteralPath $fullRegistryPath).Length -gt 0) { 'INITIALIZED' } else { 'FAIL' }
        }
        'Get' {
            if ($TargetId) { $targetResult = @($registry.targets | Where-Object targetId -eq $TargetId) | Select-Object -First 1; $status = if ($targetResult) { 'FOUND' } else { 'NOT_FOUND' } }
            else { $targetResult = @($registry.targets); $status = 'FOUND' }
        }
        'Stats' { $status = 'PASS' }
        'MarkStale' {
            $targetResult = @($registry.targets | Where-Object targetId -eq $TargetId) | Select-Object -First 1
            if (-not $targetResult) { $status = 'NOT_FOUND'; break }
            $targetResult.lifecycle = 'STALE'
            if (-not $targetResult.validation) { $targetResult.validation = [pscustomobject][ordered]@{} }
            if ($targetResult.validation.PSObject.Properties.Name -notcontains 'status') { $targetResult.validation | Add-Member -NotePropertyName status -NotePropertyValue 'STALE' } else { $targetResult.validation.status = 'STALE' }
            if ($targetResult.validation.PSObject.Properties.Name -notcontains 'failureReason') { $targetResult.validation | Add-Member -NotePropertyName failureReason -NotePropertyValue $Reason } else { $targetResult.validation.failureReason = $Reason }
            $targetResult.updatedAtUtc = [DateTime]::UtcNow.ToString('o')
            $watch = [Diagnostics.Stopwatch]::StartNew(); Write-UiTargetRegistry -RegistryPath $fullRegistryPath -Registry $registry; $watch.Stop(); $writeMilliseconds = [Math]::Round($watch.Elapsed.TotalMilliseconds,3)
            $status = 'STALE'
        }
        'Upsert' {
            if (-not $TargetJson) { throw 'TargetJson is required for Upsert.' }
            try { $inputTarget = $TargetJson | ConvertFrom-Json } catch { throw "TargetJson is invalid: $($_.Exception.Message)" }
            $target = Normalize-TargetInput $inputTarget
            $sameId = @($registry.targets | Where-Object targetId -eq $target.targetId) | Select-Object -First 1
            $duplicate = @($registry.targets | Where-Object { $_.targetId -ne $target.targetId -and [string]$_.fingerprint -eq $target.fingerprint }) | Select-Object -First 1
            if ($duplicate) {
                Add-UiMetric $registry.metrics duplicatedTargetsPrevented
                $status = 'DUPLICATE_PREVENTED'; $targetResult = $duplicate; $duplicateTargetId = [string]$duplicate.targetId
            } elseif ($sameId) {
                $target.createdAtUtc = [string]$sameId.createdAtUtc
                $registry.targets = @($registry.targets | Where-Object targetId -ne $target.targetId) + @($target)
                $status = 'UPDATED'; $targetResult = $target
            } else {
                $registry.targets = @($registry.targets) + @($target)
                $status = 'ADDED'; $targetResult = $target
            }
            $watch = [Diagnostics.Stopwatch]::StartNew(); Write-UiTargetRegistry -RegistryPath $fullRegistryPath -Registry $registry; $watch.Stop(); $writeMilliseconds = [Math]::Round($watch.Elapsed.TotalMilliseconds,3)
        }
    }
    $result = [ordered]@{
        schemaVersion=1; status=$status; registryPath=$fullRegistryPath.Substring($prefix.Length) -replace '\\','/'
        registrySchemaVersion=[int]$registry.schemaVersion; target=$targetResult; duplicateTargetId=$duplicateTargetId
        targetCount=@($registry.targets).Count; metrics=$registry.metrics; registryWriteMs=$writeMilliseconds
    }
    if ($telemetryEvent) { Stop-DeveloperEvent -ProjectPath $ProjectPath -EventId $telemetryEvent.eventId -Status $(if($status -in @('FAIL','NOT_FOUND')){'BLOCKED'}else{'PASS'}) -Artifacts @([ordered]@{path=$result.registryPath}) | Out-Null }
    if ($Json) { $result | ConvertTo-Json -Depth 20 } else { [pscustomobject]$result }
} finally { if ($lock) { Exit-UiTargetRegistryLock -Lock $lock -RegistryPath $fullRegistryPath } }
