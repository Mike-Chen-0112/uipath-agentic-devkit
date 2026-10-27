[CmdletBinding()]
param(
    [string]$ProjectPath = (Get-Location).Path,
    [string]$RegistryPath = '.devkit/ui-targets/registry.json',
    [Parameter(Mandatory=$true)][string]$TargetId,
    [Parameter(Mandatory=$true)][string]$LogicalName,
    [ValidateSet('Web','Native')][string]$ContextKind = 'Web',
    [string]$Browser = 'Chrome',
    [string]$Application = '',
    [string]$Domain = '',
    [string]$Page = '',
    [string]$Window = '',
    [string]$ExpectedRole = '',
    [string]$SourceLocation = '',
    [string]$DiscoveryCandidatesJson = '[]',
    [ValidateSet('NOT_RUN','PASS','FAIL','UNAVAILABLE')][string]$ReuseValidationStatus = 'NOT_RUN',
    [string]$ReuseValidationMethod = '',
    [double]$ReuseValidationDurationMs = 0,
    [int]$ReuseMatchCount = -1,
    [string]$ReuseActualRole = '',
    [string]$ExpectedTargetFingerprint = '',
    [string[]]$FeatureEvidencePath = @(),
    [string]$PolicyPath = '',
    [int]$MaxAttempts = 0,
    [switch]$ForceRediscovery,
    [switch]$AllowCoordinateFallback,
    [string]$EvidencePath = '.ai/evidence/ui-target-resolution.json',
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'UiTargeting.psm1') -DisableNameChecking
$totalWatch = [Diagnostics.Stopwatch]::StartNew()
$totalStartedUtc = [DateTime]::UtcNow
$ProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path
$telemetryEnabled = Test-Path -LiteralPath (Join-Path $ProjectPath '.ai\evidence\execution-state.json') -PathType Leaf
$resolveEvent = $null
if ($telemetryEnabled) {
    Import-Module (Join-Path $PSScriptRoot 'DeveloperTelemetry.psm1') -Force -DisableNameChecking
    $resolveEvent = Start-DeveloperEvent -ProjectPath $ProjectPath -Category UI_TARGET -Subcategory resolve -Operation 'ui.target.resolve' -NowUtc $totalStartedUtc.ToString('o')
}
$prefix = $ProjectPath.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
function Resolve-ProjectPath {
    param([string]$Path)
    $full = if ([IO.Path]::IsPathRooted($Path)) { [IO.Path]::GetFullPath($Path) } else { [IO.Path]::GetFullPath((Join-Path $ProjectPath $Path)) }
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "UI targeting path must stay within the project: $Path" }
    return $full
}
function Get-Value {
    param($Object, [string]$Name, $Default = $null)
    if ($Object -and $Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $Default
}
function Test-StrategySupported {
    param([string]$Strategy, $Capabilities, [string]$Kind)
    switch ($Strategy) {
        'ObjectRepository' { return [bool]$Capabilities.objectRepository }
        'StrictSelector' { return [bool]$Capabilities.strictSelector }
        'DomSelector' { return $Kind -eq 'Web' -and [bool]$Capabilities.domSelector }
        'AnchorSelector' { return [bool]$Capabilities.anchors }
        'FuzzySelector' { return [bool]$Capabilities.fuzzySelector }
        'SemanticDom' { return $Kind -eq 'Web' -and [bool]$Capabilities.semanticDom }
        'SemanticImage' { return [bool]$Capabilities.semanticImage }
        'ComputerVision' { return [bool]$Capabilities.computerVision }
        'Image' { return [bool]$Capabilities.imageTarget }
        'Coordinate' { return [bool]$Capabilities.coordinateTarget -and [bool]$AllowCoordinateFallback }
        default { return $false }
    }
}
function Write-AtomicEvidence {
    param([string]$Path, $Value)
    $directory = Split-Path $Path -Parent
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $backup = "$Path.$([guid]::NewGuid().ToString('N')).bak"
    try {
        [IO.File]::WriteAllText($temporary, (($Value | ConvertTo-Json -Depth 20) + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            try { [IO.File]::Replace($temporary, $Path, $backup) }
            catch [UnauthorizedAccessException] { Move-Item -LiteralPath $temporary -Destination $Path -Force }
        } else { [IO.File]::Move($temporary, $Path) }
    } finally { Remove-Item -LiteralPath $temporary,$backup -Force -ErrorAction SilentlyContinue }
}

if ($TargetId -notmatch '^[a-z0-9][a-z0-9._-]{2,127}$') { throw 'TargetId must be a stable lowercase identifier.' }
$fullRegistryPath = Resolve-ProjectPath $RegistryPath
$fullEvidencePath = Resolve-ProjectPath $EvidencePath
$policy = Get-UiTargetPolicy $PolicyPath
if ([Text.Encoding]::UTF8.GetByteCount($DiscoveryCandidatesJson) -gt [int]$policy.artifacts.maxInputBytes) { throw 'DiscoveryCandidatesJson exceeds the configured compact input limit.' }
if ($MaxAttempts -le 0) { $MaxAttempts = [int]$policy.exploration.maxStrategiesPerTarget }
$MaxAttempts = [Math]::Min($MaxAttempts, [int]$policy.exploration.maxStrategiesPerTarget)
$context = Normalize-UiTargetContext -Kind $ContextKind -Browser $Browser -Application $Application -Domain $Domain -Page $Page -Window $Window
$capabilities = Get-UiTargetCapabilities -ProjectPath $ProjectPath -FeatureEvidencePath $FeatureEvidencePath
try { $parsedCandidates = $DiscoveryCandidatesJson | ConvertFrom-Json; $candidates = @($parsedCandidates | ForEach-Object { $_ }) } catch { throw "DiscoveryCandidatesJson is invalid: $($_.Exception.Message)" }
if ($DiscoveryCandidatesJson.Trim() -eq '[]') { $candidates = @() }
$attempts = New-Object System.Collections.Generic.List[object]
$warnings = New-Object System.Collections.Generic.List[string]
$lookupStartedUtc = [DateTime]::UtcNow
$lookupWatch = [Diagnostics.Stopwatch]::StartNew()
$lock = Enter-UiTargetRegistryLock -RegistryPath $fullRegistryPath
try {
    $registryExisted = Test-Path -LiteralPath $fullRegistryPath -PathType Leaf
    $registry = Read-UiTargetRegistry -RegistryPath $fullRegistryPath -ProjectPath $ProjectPath
    $registryDirty = -not $registryExisted
    $metrics = New-UiTargetMetrics
    $ledgerRecords = New-Object System.Collections.Generic.List[object]
    $contextFingerprint = Get-UiSha256 (($context | ConvertTo-Json -Compress))
    $priorAttemptHashes = @{}
    foreach ($ledgerEntry in @($registry.attemptLedger | Where-Object { $_.targetId -eq $TargetId -and $_.contextFingerprint -eq $contextFingerprint })) { $priorAttemptHashes[[string]$ledgerEntry.attemptHash] = $ledgerEntry }
    Add-UiMetric $metrics targetsRequired
    $target = @($registry.targets | Where-Object targetId -eq $TargetId) | Select-Object -First 1
    if (-not $target) {
        $target = @($registry.targets | Where-Object { $_.logicalName -eq $LogicalName -and (Test-UiTargetContextMatch $_.context $context) }) | Select-Object -First 1
    }
    $lookupWatch.Stop()
    $lookupEndedUtc = [DateTime]::UtcNow
    $lookupMs = [Math]::Round($lookupWatch.Elapsed.TotalMilliseconds,3)
    if ($telemetryEnabled) {
        $lookupEvent = Start-DeveloperEvent -ProjectPath $ProjectPath -Category UI_TARGET -Subcategory registry_lookup -Operation 'ui.target.registry_lookup' -ParentEventId $resolveEvent.eventId -NowUtc $lookupStartedUtc.ToString('o')
        Stop-DeveloperEvent -ProjectPath $ProjectPath -EventId $lookupEvent.eventId -Status PASS -NowUtc $lookupEndedUtc.ToString('o') | Out-Null
    }
    Add-UiMetric $metrics registryLookupMs $lookupMs
    $status = 'UNRESOLVED_TARGET'
    $resolution = 'NONE'
    $selected = $null
    $reuseAttempted = $false
    $reuseSucceeded = $false
    $reuseFailureReason = ''
    $validationMs = 0.0
    $discoveryMs = 0.0

    if ($target) {
        Add-UiMetric $metrics registryHits
        Add-UiMetric $metrics reuseAttempts
        $reuseAttempted = $true
        $contextMatches = Test-UiTargetContextMatch $target.context $context
        $recordedEnvironment = if ($target.validation) { [string](Get-Value $target.validation 'environmentFingerprint' '') } else { '' }
        $fresh = -not $ForceRediscovery -and $contextMatches -and (-not $ExpectedTargetFingerprint -or [string]$target.fingerprint -eq $ExpectedTargetFingerprint) -and ($recordedEnvironment -match '^[0-9a-fA-F]{64}$') -and $recordedEnvironment -eq [string]$capabilities.environmentFingerprint
        $validationWatch = [Diagnostics.Stopwatch]::StartNew()
        if ($ReuseValidationStatus -eq 'FAIL') {
            $fresh = $false; $reuseFailureReason = 'LIVE_VALIDATION_FAILED'; $target.lifecycle = 'STALE'
            if ($target.validation) { $target.validation.status = 'FAIL' }
            Add-UiMetric $metrics validationCount; Add-UiMetric $metrics failedValidationCount; $registryDirty = $true
        } elseif ($ReuseValidationStatus -eq 'PASS') {
            Add-UiMetric $metrics validationCount; $registryDirty = $true
            $reuseSpecific = $ReuseMatchCount -eq 1 -and (-not $ExpectedRole -or ($ReuseActualRole -and $ExpectedRole.Equals($ReuseActualRole,[StringComparison]::OrdinalIgnoreCase)))
            $target.validation = [pscustomobject][ordered]@{ status=$(if ($reuseSpecific) { 'PASS' } else { 'FAIL' }); level='LIVE'; method=$ReuseValidationMethod; validatedAtUtc=[DateTime]::UtcNow.ToString('o'); environmentFingerprint=[string]$capabilities.environmentFingerprint; matchCount=$ReuseMatchCount; actualRole=$ReuseActualRole; failureReason=$(if ($reuseSpecific) { '' } else { 'SPECIFICITY_OR_ROLE_VALIDATION_FAILED' }) }
            if ($reuseSpecific) { $target.lifecycle = 'REUSABLE'; $fresh = $contextMatches -and -not $ForceRediscovery -and (-not $ExpectedTargetFingerprint -or [string]$target.fingerprint -eq $ExpectedTargetFingerprint) }
            else { $target.lifecycle = 'STALE'; $fresh = $false; $reuseFailureReason='SPECIFICITY_OR_ROLE_VALIDATION_FAILED'; Add-UiMetric $metrics failedValidationCount }
        } elseif ($ReuseValidationStatus -eq 'UNAVAILABLE') {
            $fresh = $false; $reuseFailureReason = 'LIVE_VALIDATION_UNAVAILABLE'
        }
        $validationWatch.Stop(); $validationMs += $validationWatch.Elapsed.TotalMilliseconds
        $validationMs += [Math]::Max(0.0, $ReuseValidationDurationMs)
        $isLiveReusable = $target.validation -and [string](Get-Value $target.validation 'status' '') -eq 'PASS' -and [string](Get-Value $target.validation 'level' '') -eq 'LIVE' -and [int](Get-Value $target.validation 'matchCount' -1) -eq 1 -and [string](Get-Value $target.validation 'environmentFingerprint' '') -eq [string]$capabilities.environmentFingerprint -and [string]$target.lifecycle -eq 'REUSABLE'
        if ($fresh -and $isLiveReusable) {
            $status='REUSED'; $resolution='REGISTRY'; $selected=$target; $reuseSucceeded=$true
            Add-UiMetric $metrics reuseSuccesses; Add-UiStrategyMetric $metrics Registry
        } else {
            if (-not $reuseFailureReason) {
                if (-not $contextMatches) { $reuseFailureReason='APPLICATION_OR_PAGE_MISMATCH' }
                elseif ($ForceRediscovery) { $reuseFailureReason='REDISCOVERY_REQUESTED' }
                elseif ($ExpectedTargetFingerprint -and [string]$target.fingerprint -ne $ExpectedTargetFingerprint) { $reuseFailureReason='TARGET_DEFINITION_CHANGED' }
                elseif (-not $recordedEnvironment -or $recordedEnvironment -ne [string]$capabilities.environmentFingerprint) { $reuseFailureReason='CAPABILITY_ENVIRONMENT_CHANGED' }
                else { $reuseFailureReason='LIVE_VALIDATION_REQUIRED' }
            }
            Add-UiMetric $metrics reuseFailures
            [void]$attempts.Add([ordered]@{ source='Registry'; strategy='Registry'; status='FAILED'; reason=$reuseFailureReason; targetId=[string]$target.targetId })
        }
    } else { Add-UiMetric $metrics registryMisses }

    if (-not $reuseSucceeded) {
        $discoveryStartedUtc = [DateTime]::UtcNow
        $discoveryWatch = [Diagnostics.Stopwatch]::StartNew()
        $order = @($policy.strategyOrder.$ContextKind)
        $orderedCandidates = @($candidates | Sort-Object @{ Expression={ $index=[Array]::IndexOf($order,[string](Get-Value $_ 'strategy' '')); if ($index -lt 0) { 999 } else { $index } } })
        $seenAttempts = @{}
        $attemptCount = 0
        $discoveredButUnvalidated = $null
        foreach ($candidate in $orderedCandidates) {
            if ($attemptCount -ge $MaxAttempts) { [void]$warnings.Add('EXPLORATION_BUDGET_EXHAUSTED'); break }
            $strategy = [string](Get-Value $candidate 'strategy' '')
            $descriptor = [string](Get-Value $candidate 'descriptor' '')
            $anchorDescriptor = [string](Get-Value $candidate 'anchorDescriptor' '')
            $candidateIsLiveProof = [string](Get-Value $candidate 'validationLevel' 'NONE') -eq 'LIVE' -and [string](Get-Value $candidate 'validationStatus' 'NOT_RUN') -eq 'PASS'
            if ($descriptor.Length -gt [int]$policy.artifacts.maxDescriptorCharacters -or $anchorDescriptor.Length -gt [int]$policy.artifacts.maxDescriptorCharacters) {
                [void]$attempts.Add([ordered]@{ source='Discovery'; strategy=$strategy; status='FAILED'; reason='DESCRIPTOR_TOO_LARGE' }); continue
            }
            if (($descriptor + $anchorDescriptor) -match '(?i)(authorization\s*[:=]|bearer\s+[a-z0-9._-]{16,}|password\s*=\s*["''][^"'']+["'']|secret\s*=|token\s*=)') {
                [void]$attempts.Add([ordered]@{ source='Discovery'; strategy=$strategy; status='FAILED'; reason='SENSITIVE_DESCRIPTOR_REJECTED' }); continue
            }
            $attemptKey = Get-UiSha256 "$strategy|$(ConvertTo-NormalizedSelector $descriptor)|$(ConvertTo-NormalizedSelector $anchorDescriptor)|$($context.kind)|$($context.domain)|$($context.page)|$($context.application)|$($context.window)|$($capabilities.environmentFingerprint)"
            if ($seenAttempts.ContainsKey($attemptKey)) {
                Add-UiMetric $metrics duplicatedTargetsPrevented
                [void]$attempts.Add([ordered]@{ source='Discovery'; strategy=$strategy; status='SKIPPED'; reason='DUPLICATE_ATTEMPT_PREVENTED' })
                continue
            }
            $validationProgression = $ReuseValidationStatus -ne 'FAIL' -and $priorAttemptHashes.ContainsKey($attemptKey) -and [string]$priorAttemptHashes[$attemptKey].status -eq 'VALIDATION_REQUIRED' -and $candidateIsLiveProof
            if (-not $ForceRediscovery -and $priorAttemptHashes.ContainsKey($attemptKey) -and -not $validationProgression) {
                Add-UiMetric $metrics duplicatedTargetsPrevented
                [void]$attempts.Add([ordered]@{ source='Discovery'; strategy=$strategy; status='SKIPPED'; reason='PREVIOUS_IDENTICAL_ATTEMPT_PREVENTED' })
                continue
            }
            $seenAttempts[$attemptKey] = $true
            if (-not (Test-StrategySupported $strategy $capabilities $ContextKind)) {
                $reason = if ($ContextKind -eq 'Native' -and $strategy -in @('DomSelector','SemanticDom')) { 'DOM_NOT_VALID_FOR_NATIVE_CONTEXT' } else { 'CAPABILITY_UNSUPPORTED' }
                [void]$attempts.Add([ordered]@{ source='Discovery'; strategy=$strategy; status='SKIPPED'; reason=$reason })
                continue
            }
            $attemptCount++
            Add-UiMetric $metrics discoveryCount; Add-UiMetric $metrics candidateEvaluationCount
            Add-UiStrategyMetric $metrics $strategy
            if ($strategy -in @('SemanticDom','SemanticImage')) { Add-UiMetric $metrics semanticSelectorCount }
            if ($strategy -in @('SemanticImage','ComputerVision','Image')) { Add-UiMetric $metrics cvImageFallbackCount }
            if ($strategy -eq 'Coordinate') { Add-UiMetric $metrics coordinateFallbackCount }
            $ledgerRecord = [ordered]@{ targetId=$TargetId; contextFingerprint=$contextFingerprint; attemptHash=$attemptKey; strategy=$strategy; status='ATTEMPTED'; reason=''; attemptedAtUtc=[DateTime]::UtcNow.ToString('o') }
            [void]$ledgerRecords.Add($ledgerRecord)
            $candidateContextInput = Get-Value $candidate 'context'
            if ($candidateContextInput) {
                $candidateContext = Normalize-UiTargetContext -Kind ([string](Get-Value $candidateContextInput 'kind' $ContextKind)) -Browser ([string](Get-Value $candidateContextInput 'browser' $Browser)) -Application ([string](Get-Value $candidateContextInput 'application' $Application)) -Domain ([string](Get-Value $candidateContextInput 'domain' $Domain)) -Page ([string](Get-Value $candidateContextInput 'page' $Page)) -Window ([string](Get-Value $candidateContextInput 'window' $Window))
                if (-not (Test-UiTargetContextMatch $candidateContext $context)) { $ledgerRecord.status='FAILED'; $ledgerRecord.reason='APPLICATION_OR_PAGE_MISMATCH'; [void]$attempts.Add([ordered]@{ source='Discovery'; strategy=$strategy; status='FAILED'; reason='APPLICATION_OR_PAGE_MISMATCH' }); continue }
            }
            $matchCount = [int](Get-Value $candidate 'matchCount' -1)
            $actualRole = [string](Get-Value $candidate 'actualRole' '')
            $quality = Get-UiTargetQuality -Selector $(if ($descriptor) { $descriptor } else { [string](Get-Value $candidate 'objectRepositoryReference' '') }) -Strategy $strategy -AnchorSelector $anchorDescriptor -MatchCount $matchCount -ExpectedRole $ExpectedRole -ActualRole $actualRole -PolicyPath $PolicyPath
            $validationLevel = [string](Get-Value $candidate 'validationLevel' 'NONE')
            $validationStatus = [string](Get-Value $candidate 'validationStatus' 'NOT_RUN')
            $validationMethod = [string](Get-Value $candidate 'validationMethod' '')
            $validationMs += [Math]::Max(0.0, [double](Get-Value $candidate 'validationDurationMs' 0))
            Add-UiMetric $metrics validationCount
            if ($validationStatus -ne 'PASS' -or $matchCount -ne 1 -or ($ExpectedRole -and (-not $actualRole -or -not $ExpectedRole.Equals($actualRole,[StringComparison]::OrdinalIgnoreCase)))) {
                Add-UiMetric $metrics failedValidationCount
                $ledgerRecord.status='FAILED'; $ledgerRecord.reason=$(if ($validationStatus -eq 'PASS') { 'SPECIFICITY_OR_ROLE_VALIDATION_FAILED' } else { "VALIDATION_$validationStatus" })
                [void]$attempts.Add([ordered]@{ source='Discovery'; strategy=$strategy; status='FAILED'; reason=$(if ($validationStatus -eq 'PASS') { 'SPECIFICITY_OR_ROLE_VALIDATION_FAILED' } else { "VALIDATION_$validationStatus" }); quality=$quality.classification })
                continue
            }
            if ($quality.classification -eq 'REJECT' -and $strategy -ne 'Coordinate') {
                Add-UiMetric $metrics failedValidationCount
                $ledgerRecord.status='FAILED'; $ledgerRecord.reason='SELECTOR_QUALITY_REJECT'
                [void]$attempts.Add([ordered]@{ source='Discovery'; strategy=$strategy; status='FAILED'; reason='SELECTOR_QUALITY_REJECT'; quality=$quality.classification })
                continue
            }
            $artifact = Resolve-UiArtifactReference -ProjectPath $ProjectPath -ArtifactPath ([string](Get-Value $candidate 'artifactPath' '')) -MaxBytes ([int64]$policy.artifacts.maxReferencedArtifactBytes)
            $lifecycle = if ($validationLevel -eq 'LIVE' -and $validationStatus -eq 'PASS' -and $strategy -ne 'Coordinate') { 'REUSABLE' } elseif ($validationStatus -eq 'PASS') { 'VALIDATED' } else { 'DISCOVERED' }
            $candidateTarget = [pscustomobject][ordered]@{
                targetId=$TargetId; logicalName=$LogicalName; context=$context; elementRole=$ExpectedRole
                primary=[ordered]@{ strategy=$strategy; descriptor=$descriptor; objectRepositoryReference=[string](Get-Value $candidate 'objectRepositoryReference' '') }
                anchors=if ($anchorDescriptor) { @([ordered]@{ strategy='StrictSelector'; descriptor=$anchorDescriptor; quality=(Get-UiTargetQuality -Selector $anchorDescriptor -MatchCount 1 -PolicyPath $PolicyPath) }) } else { @() }
                fallbacks=@(Get-Value $candidate 'fallbacks' @()); semanticDescription=[string](Get-Value $candidate 'semanticDescription' '')
                objectRepositoryReference=[string](Get-Value $candidate 'objectRepositoryReference' ''); quality=$quality; lifecycle=$lifecycle
                validation=[pscustomobject][ordered]@{ status=$validationStatus; level=$validationLevel; method=$validationMethod; validatedAtUtc=[DateTime]::UtcNow.ToString('o'); environmentFingerprint=[string]$capabilities.environmentFingerprint; matchCount=$matchCount; actualRole=$actualRole; failureReason='' }
                capability=[ordered]@{ uiAutomationVersion=[string]$capabilities.uiAutomationVersion; environmentFingerprint=[string]$capabilities.environmentFingerprint; targetValidation=[bool]$capabilities.targetValidation; semanticDom=[bool]$capabilities.semanticDom; semanticImage=[bool]$capabilities.semanticImage; computerVision=[bool]$capabilities.computerVision; objectRepository=[bool]$capabilities.objectRepository }
                sourceLocations=if ($SourceLocation) { @($SourceLocation) } else { @() }; artifact=$artifact
                warnings=@($quality.warnings); fingerprint=''; createdAtUtc=[DateTime]::UtcNow.ToString('o'); updatedAtUtc=[DateTime]::UtcNow.ToString('o')
            }
            $candidateTarget.fingerprint = Get-UiTargetFingerprint $candidateTarget
            if ($validationLevel -ne 'LIVE') {
                $ledgerRecord.status='VALIDATION_REQUIRED'; $ledgerRecord.reason=$(if ($validationLevel -eq 'UNSUPPORTED') { 'LIVE_VALIDATION_UNSUPPORTED' } else { 'STATIC_VALIDATION_IS_NOT_LIVE_PROOF' })
                $discoveredButUnvalidated = $candidateTarget
                [void]$attempts.Add([ordered]@{ source='Discovery'; strategy=$strategy; status='VALIDATION_REQUIRED'; reason=$(if ($validationLevel -eq 'UNSUPPORTED') { 'LIVE_VALIDATION_UNSUPPORTED' } else { 'STATIC_VALIDATION_IS_NOT_LIVE_PROOF' }); quality=$quality.classification })
                break
            }
            if ($strategy -eq 'Coordinate') {
                $ledgerRecord.status='RESOLVED_NONREUSABLE'; $ledgerRecord.reason='COORDINATE_LAST_RESORT'
                $discoveredButUnvalidated = $candidateTarget
                [void]$attempts.Add([ordered]@{ source='Discovery'; strategy=$strategy; status='RESOLVED_NONREUSABLE'; reason='COORDINATE_LAST_RESORT'; quality=$quality.classification })
                $status='RESOLVED_NONREUSABLE'; $resolution='DISCOVERY'; $selected=$candidateTarget
                break
            }
            $duplicate = @($registry.targets | Where-Object { $_.targetId -ne $TargetId -and [string]$_.fingerprint -eq $candidateTarget.fingerprint }) | Select-Object -First 1
            if ($duplicate) {
                Add-UiMetric $metrics duplicatedTargetsPrevented
                $candidateTarget = $duplicate
                [void]$attempts.Add([ordered]@{ source='Discovery'; strategy=$strategy; status='DUPLICATE_PREVENTED'; reason="Equivalent to $($duplicate.targetId)"; quality=$quality.classification })
                $ledgerRecord.status='DUPLICATE_PREVENTED'; $ledgerRecord.reason="Equivalent to $($duplicate.targetId)"
            } else { $ledgerRecord.status='PASS'; $ledgerRecord.reason='LIVE_VALIDATION_PASS'; [void]$attempts.Add([ordered]@{ source='Discovery'; strategy=$strategy; status='PASS'; reason='LIVE_VALIDATION_PASS'; quality=$quality.classification }) }
            $registry.targets = @($registry.targets | Where-Object targetId -ne $candidateTarget.targetId) + @($candidateTarget)
            $registryDirty = $true
            $status='RESOLVED'; $resolution='DISCOVERY'; $selected=$candidateTarget
            if ($attemptCount -gt 1 -or $strategy -notin @('ObjectRepository','StrictSelector','DomSelector')) { Add-UiMetric $metrics fallbackCount }
            break
        }
        if (-not $selected -and $discoveredButUnvalidated) {
            $registry.targets = @($registry.targets | Where-Object targetId -ne $discoveredButUnvalidated.targetId) + @($discoveredButUnvalidated)
            $registryDirty = $true
            $status = if ([string]$discoveredButUnvalidated.validation.level -eq 'UNSUPPORTED') { 'BLOCKED_UI_CAPTURE' } else { 'VALIDATION_REQUIRED' }
            $resolution='DISCOVERY'; $selected=$discoveredButUnvalidated
        }
        $discoveryWatch.Stop(); $discoveryEndedUtc = [DateTime]::UtcNow; $discoveryMs = [Math]::Round($discoveryWatch.Elapsed.TotalMilliseconds,3)
        if ($telemetryEnabled) {
            $discoveryEvent = Start-DeveloperEvent -ProjectPath $ProjectPath -Category UI_TARGET -Subcategory generate -Operation 'ui.target.generate' -ParentEventId $resolveEvent.eventId -NowUtc $discoveryStartedUtc.ToString('o')
            Stop-DeveloperEvent -ProjectPath $ProjectPath -EventId $discoveryEvent.eventId -Status $(if ($selected) { 'PASS' } else { 'BLOCKED' }) -NowUtc $discoveryEndedUtc.ToString('o') | Out-Null
        }
    }

    if ($ledgerRecords.Count -gt 0) {
        $registry.attemptLedger = @($registry.attemptLedger) + @($ledgerRecords.ToArray())
        $maxLedgerEntries = [int]$policy.exploration.maxAttemptLedgerEntries
        if (@($registry.attemptLedger).Count -gt $maxLedgerEntries) { $registry.attemptLedger = @($registry.attemptLedger | Select-Object -Last $maxLedgerEntries) }
        $registryDirty = $true
    }

    $validationMs = [Math]::Round($validationMs,3)
    Add-UiMetric $metrics targetDiscoveryMs $discoveryMs
    Add-UiMetric $metrics targetValidationMs $validationMs
    $registryWriteMs = 0.0
    if ($registryDirty) {
        $registryWriteStartedUtc = [DateTime]::UtcNow
        $registryWriteWatch = [Diagnostics.Stopwatch]::StartNew()
        Write-UiTargetRegistry -RegistryPath $fullRegistryPath -Registry $registry
        $registryWriteWatch.Stop(); $registryWriteEndedUtc = [DateTime]::UtcNow; $registryWriteMs=[Math]::Round($registryWriteWatch.Elapsed.TotalMilliseconds,3)
        if ($telemetryEnabled) {
            $persistEvent = Start-DeveloperEvent -ProjectPath $ProjectPath -Category UI_TARGET -Subcategory persist -Operation 'ui.target.persist' -ParentEventId $resolveEvent.eventId -NowUtc $registryWriteStartedUtc.ToString('o')
            Stop-DeveloperEvent -ProjectPath $ProjectPath -EventId $persistEvent.eventId -Status PASS -NowUtc $registryWriteEndedUtc.ToString('o') | Out-Null
        }
    }
    Add-UiMetric $metrics registryWriteMs $registryWriteMs
    $totalWatch.Stop(); $totalMs=[Math]::Round($totalWatch.Elapsed.TotalMilliseconds,3)
    Add-UiMetric $metrics totalTargetResolutionMs $totalMs
    $result = [ordered]@{
        schemaVersion=1; status=$status; targetId=if ($selected) { [string]$selected.targetId } else { $TargetId }; logicalName=$LogicalName
        targetReuseAttempted=$reuseAttempted; targetReuseSucceeded=$reuseSucceeded; targetReuseFailed=($reuseAttempted -and -not $reuseSucceeded); targetReuseFailureReason=$reuseFailureReason
        resolution=$resolution; strategy=if ($selected) { [string]$selected.primary.strategy } else { '' }; lifecycle=if ($selected) { [string]$selected.lifecycle } else { 'UNRESOLVED' }
        selectorQuality=if ($selected) { $selected.quality } else { $null }; validation=if ($selected) { $selected.validation } else { $null }
        context=$context; capability=$capabilities; targetFingerprint=if ($selected) { [string]$selected.fingerprint } else { '' }
        binding=if ($selected -and $status -in @('REUSED','RESOLVED')) { [ordered]@{ targetId=[string]$selected.targetId; primary=$selected.primary; anchors=@($selected.anchors); targetFingerprint=[string]$selected.fingerprint } } else { $null }
        attempts=$attempts.ToArray(); warnings=$warnings.ToArray(); unresolved=($status -in @('UNRESOLVED_TARGET','BLOCKED_UI_CAPTURE','VALIDATION_REQUIRED'))
        evidencePath=$fullEvidencePath.Substring($prefix.Length) -replace '\\','/'; registryPath=$fullRegistryPath.Substring($prefix.Length) -replace '\\','/'
        timingScope='RESOLVER_ONLY_NOT_END_TO_END_UI_CAPTURE'
        timings=[ordered]@{ registryLookupMs=$lookupMs; validationMs=$validationMs; discoveryMs=$discoveryMs; candidateProcessingMs=$discoveryMs; registryWriteMs=$registryWriteMs; targetResolutionMs=$totalMs }
        metrics=$metrics; telemetryEventId=if($resolveEvent){[string]$resolveEvent.eventId}else{$null}
    }
    Write-AtomicEvidence -Path $fullEvidencePath -Value $result
    if ($telemetryEnabled) {
        Add-DeveloperInstantEvent -ProjectPath $ProjectPath -Category UI_TARGET -Subcategory $(if($reuseSucceeded){'reuse'}else{'live_validation'}) -Operation $(if($reuseSucceeded){'ui.target.reuse'}else{'ui.target.live_validation'}) -ParentEventId $resolveEvent.eventId -Status $(if($status -in @('REUSED','RESOLVED')){'PASS'}elseif($status -eq 'RESOLVED_NONREUSABLE'){'UNAVAILABLE'}else{'BLOCKED'}) | Out-Null
        $objectRepositoryStatus = if ($selected -and ([string]$selected.primary.strategy -eq 'ObjectRepository' -or [string]$selected.objectRepositoryReference)) { 'PASS' } elseif ([bool]$capabilities.objectRepository) { 'SKIPPED' } else { 'UNAVAILABLE' }
        Add-DeveloperInstantEvent -ProjectPath $ProjectPath -Category OBJECT_REPOSITORY -Subcategory usage -Operation 'object_repository.status' -ParentEventId $resolveEvent.eventId -Status $objectRepositoryStatus | Out-Null
        Stop-DeveloperEvent -ProjectPath $ProjectPath -EventId $resolveEvent.eventId -Status $(if($status -in @('REUSED','RESOLVED','RESOLVED_NONREUSABLE')){'PASS'}else{'BLOCKED'}) | Out-Null
    }
    if ($Json) { $result | ConvertTo-Json -Depth 20 } else { [pscustomobject]$result }
} finally { Exit-UiTargetRegistryLock -Lock $lock -RegistryPath $fullRegistryPath }
