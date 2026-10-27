[CmdletBinding()]
param(
    [string]$ProjectPath = (Get-Location).Path,
    [Parameter(Mandatory=$true)]
    [string]$TaskId,
    [ValidateSet('R0','R1','R2','R3')]
    [string]$RiskClass = 'R1',
    [ValidateSet('NONE','LIGHT','FULL')]
    [string]$RequestedAuditMode = 'LIGHT',
    [string[]]$SelectedWorkflow = @(),
    [string[]]$InspectedWorkflow = @(),
    [string[]]$ModifiedFile = @(),
    [Parameter(Mandatory=$true)]
    [string]$ValidationResultPath,
    [string]$ContextPackagePath = '.ai/evidence/developer-context-package.json',
    [string]$ProjectMapPath = '.ai/evidence/project-map.json',
    [string]$GraphSummaryPath = '',
    [string[]]$UiTargetEvidencePath = @(),
    [string]$ExecutionStatePath,
    [string]$DeveloperSummary = '',
    [string]$ExpectedSourceFingerprint = '',
    [switch]$Uncertainty,
    [string]$EvidencePath = '.ai/evidence/developer-evidence.json',
    [string]$HandoffPath = '.ai/evidence/developer-handoff.json',
    [string]$ResultPath = '.ai/evidence/developer-finalization.json',
    [switch]$SimulateEvidenceWriteFailure,
    [switch]$SimulateStateWriteFailure,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$helperStarted = [DateTime]::UtcNow
$ProjectPath = (Resolve-Path $ProjectPath).Path
$projectPrefix = $ProjectPath.TrimEnd('\','/') + [System.IO.Path]::DirectorySeparatorChar
$utf8 = New-Object System.Text.UTF8Encoding($false)
$fingerprintScript = Join-Path $PSScriptRoot 'SourceFingerprint.ps1'
$stateScript = Join-Path $PSScriptRoot 'ExecutionState.ps1'
$telemetryModule = Join-Path $PSScriptRoot 'DeveloperTelemetry.psm1'
$breakdownScript = Join-Path $PSScriptRoot 'Get-DeveloperRuntimeBreakdown.ps1'
$ExecutionStatePath = if ($ExecutionStatePath) { [System.IO.Path]::GetFullPath($ExecutionStatePath) } else { Join-Path $ProjectPath '.ai\evidence\execution-state.json' }

function Resolve-ProjectFile {
    param([string]$Path, [bool]$Required = $false)
    if (-not $Path) { return $null }
    $candidate = if ([System.IO.Path]::IsPathRooted($Path)) { [System.IO.Path]::GetFullPath($Path) } else { [System.IO.Path]::GetFullPath((Join-Path $ProjectPath ($Path -replace '/','\'))) }
    if (-not $candidate.StartsWith($projectPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Path must stay within the project: $Path" }
    if ($Required -and -not (Test-Path -LiteralPath $candidate -PathType Leaf)) { throw "Required finalization input was not found: $Path" }
    return $candidate
}

function Get-RelativePath {
    param([string]$FullPath)
    return $FullPath.Substring($projectPrefix.Length) -replace '\\','/'
}

function Normalize-ProjectPath {
    param([string]$Path)
    return Get-RelativePath (Resolve-ProjectFile $Path)
}

function Write-AtomicJson {
    param([string]$Path, $Value, [switch]$SimulateFailure)
    New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null
    $tempPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $backupPath = "$Path.$([guid]::NewGuid().ToString('N')).bak"
    try {
        [System.IO.File]::WriteAllText($tempPath, (($Value | ConvertTo-Json -Depth 15) + [Environment]::NewLine), $utf8)
        if ($SimulateFailure) { throw 'Simulated Developer evidence write failure.' }
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            try { [System.IO.File]::Replace($tempPath, $Path, $backupPath) }
            catch [System.UnauthorizedAccessException] { Move-Item -LiteralPath $tempPath -Destination $Path -Force -ErrorAction Stop }
            if (Test-Path -LiteralPath $backupPath -PathType Leaf) { Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue }
        } else { [System.IO.File]::Move($tempPath, $Path) }
    } finally {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $backupPath -PathType Leaf) { Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue }
    }
}

function Get-ArtifactReference {
    param([string]$Path, [string]$Kind, [bool]$Required = $false)
    $fullPath = Resolve-ProjectFile $Path
    if (-not $fullPath -or -not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        if ($Required) { throw "Required $Kind artifact was not found: $Path" }
        return $null
    }
    $item = Get-Item -LiteralPath $fullPath
    return [ordered]@{
        kind = $Kind
        path = Get-RelativePath $fullPath
        bytes = [int64]$item.Length
        sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Add-RetroactiveEvent {
    param([string]$Category,[string]$Subcategory,[string]$Operation,[DateTime]$Started,[DateTime]$Ended,[object[]]$Artifacts=@())
    $event=Start-DeveloperEvent -ProjectPath $ProjectPath -Category $Category -Subcategory $Subcategory -Operation $Operation -Artifacts $Artifacts -NowUtc $Started.ToString('o')
    Stop-DeveloperEvent -ProjectPath $ProjectPath -EventId $event.eventId -Status PASS -Artifacts $Artifacts -NowUtc $Ended.ToString('o')|Out-Null
}

if (-not (Test-Path -LiteralPath $fingerprintScript -PathType Leaf) -or -not (Test-Path -LiteralPath $stateScript -PathType Leaf) -or -not (Test-Path -LiteralPath $telemetryModule -PathType Leaf) -or -not (Test-Path -LiteralPath $breakdownScript -PathType Leaf)) { throw 'Developer finalization runtime helpers are missing.' }
Import-Module $telemetryModule -Force
if (-not (Test-Path -LiteralPath $ExecutionStatePath -PathType Leaf)) { throw "Execution state was not found: $ExecutionStatePath" }
if (-not $ExecutionStatePath.StartsWith($projectPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'ExecutionStatePath must stay within the project.' }
$fullValidationPath = Resolve-ProjectFile $ValidationResultPath $true
$fullEvidencePath = Resolve-ProjectFile $EvidencePath
$fullHandoffPath = Resolve-ProjectFile $HandoffPath
$fullResultPath = Resolve-ProjectFile $ResultPath
$warnings = New-Object System.Collections.Generic.List[string]

try { $validation = [System.IO.File]::ReadAllText($fullValidationPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch { throw "Validation result is invalid JSON: $($_.Exception.Message)" }
$validationStatus = if ([string]$validation.status) { [string]$validation.status } else {
    $gateStatuses = @()
    foreach ($gateName in @('project_json','xaml_sanity','get_errors','dependency_restore','build','analyzer','tests','integrity','output_qa')) {
        if ($validation.$gateName -and $validation.$gateName.status) { $gateStatuses += [string]$validation.$gateName.status }
    }
    if ($gateStatuses -contains 'FAIL') { 'FAIL' } elseif ($gateStatuses -contains 'BLOCKED' -or $gateStatuses -contains 'TIMEOUT') { 'BLOCKED' } else { 'PASS' }
}
$validatedSourceFingerprint = if ([string]$validation.validatedSourceFingerprint) { [string]$validation.validatedSourceFingerprint } elseif ($validation.source) { [string]$validation.source.fingerprint } else { [string]$validation.sourceFingerprint }
$buildGate=if($validation.gates -and $validation.gates.build){$validation.gates.build}elseif($validation.build){$validation.build}else{$null}
$diagnosticsGate=if($validation.gates -and $validation.gates.diagnostics){$validation.gates.diagnostics}elseif($validation.get_errors){$validation.get_errors}else{$null}
$buildStatus=if($buildGate){[string]$buildGate.status}else{'NOT_RUN'}
$diagnosticsRequired=if($validation.delivery){[bool]$validation.delivery.validationRequired}elseif($validation.diagnosticsDecision){[bool]$validation.diagnosticsDecision.diagnosticsRequired}else{$false}
$diagnosticsComplete=(-not $diagnosticsRequired) -or ($diagnosticsGate -and [string]$diagnosticsGate.status -in @('PASS','REUSED','SKIPPED'))
$buildExecuted=$buildStatus -in @('PASS','REUSED','FAIL','BLOCKED','TIMEOUT')
$buildSucceeded=$buildStatus -in @('PASS','REUSED')
$validationCompleted=if($validation.delivery){[bool]$validation.delivery.validationCompleted}else{[string]$validationStatus -eq 'PASS' -and $diagnosticsComplete -and $buildSucceeded}
$deliveryReady=if($validation.delivery){[bool]$validation.delivery.deliveryReady}else{$validationCompleted -and $buildSucceeded}
$blockedReason=if($validation.delivery -and $validation.delivery.blockedReason){[string]$validation.delivery.blockedReason}elseif(-not $buildExecuted){'REQUIRED_BUILD_NOT_EXECUTED'}elseif(-not $buildSucceeded){'PROJECT_BUILD_FAILED_OR_BLOCKED'}elseif(-not $diagnosticsComplete){'REQUIRED_NATIVE_DIAGNOSTICS_INCOMPLETE'}else{$null}

$fingerprintStarted = [DateTime]::UtcNow
$snapshot = & $fingerprintScript -ProjectPath $ProjectPath -Json | ConvertFrom-Json
$fingerprintEnded = [DateTime]::UtcNow
$fingerprintSeconds = [Math]::Round(($fingerprintEnded - $fingerprintStarted).TotalSeconds, 6)
$status = if ($validationStatus -eq 'FAIL') { 'FAIL' } elseif ($validationStatus -eq 'BLOCKED' -or -not $deliveryReady) { 'BLOCKED' } else { 'PASS' }
if(-not $deliveryReady){[void]$warnings.Add("DELIVERY_BLOCKED:$blockedReason")}
if ($ExpectedSourceFingerprint -and $ExpectedSourceFingerprint -ne [string]$snapshot.sourceFingerprint) { $status = 'BLOCKED'; [void]$warnings.Add('EXPECTED_SOURCE_FINGERPRINT_MISMATCH') }
if ($validatedSourceFingerprint -and $validatedSourceFingerprint -ne [string]$snapshot.sourceFingerprint) { $status = 'BLOCKED'; [void]$warnings.Add('SOURCE_CHANGED_AFTER_VALIDATION') }

$effectiveAuditMode = $RequestedAuditMode
$auditEscalated = $false
if ($RiskClass -eq 'R3' -and $effectiveAuditMode -ne 'FULL') { $effectiveAuditMode = 'FULL'; $auditEscalated = $true; [void]$warnings.Add('R3_REQUIRES_FULL_AUDIT') }
elseif ($RiskClass -eq 'R2' -and $effectiveAuditMode -eq 'NONE') { $effectiveAuditMode = 'LIGHT'; $auditEscalated = $true; [void]$warnings.Add('R2_CANNOT_SKIP_AUDIT') }
if ($Uncertainty -and $effectiveAuditMode -eq 'NONE') { $effectiveAuditMode = 'LIGHT'; $auditEscalated = $true; [void]$warnings.Add('DEVELOPER_UNCERTAINTY_REQUIRES_AUDIT') }

$evidenceStarted = [DateTime]::UtcNow
$selected = @($SelectedWorkflow | ForEach-Object { Normalize-ProjectPath $_ } | Select-Object -Unique)
$inspected = @($InspectedWorkflow | ForEach-Object { Normalize-ProjectPath $_ } | Select-Object -Unique)
$modifiedRecords = New-Object System.Collections.Generic.List[object]
foreach ($path in @($ModifiedFile | Select-Object -Unique)) {
    $fullPath = Resolve-ProjectFile $path
    $relative = Get-RelativePath $fullPath
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        $status = 'BLOCKED'
        [void]$warnings.Add("MODIFIED_FILE_MISSING:$relative")
        [void]$modifiedRecords.Add([ordered]@{ path = $relative; exists = $false; bytes = 0; sha256 = $null; workflow = [System.IO.Path]::GetExtension($relative) -ieq '.xaml' })
    } else {
        $item = Get-Item -LiteralPath $fullPath
        [void]$modifiedRecords.Add([ordered]@{ path = $relative; exists = $true; bytes = [int64]$item.Length; sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant(); workflow = [System.IO.Path]::GetExtension($relative) -ieq '.xaml' })
    }
}
$validationReference = Get-ArtifactReference $ValidationResultPath 'developer-validation' $true
$contextReference = Get-ArtifactReference $ContextPackagePath 'developer-context-package'
$mapperReference = Get-ArtifactReference $ProjectMapPath 'project-map'
$graphReference = Get-ArtifactReference $GraphSummaryPath 'graph-summary'
$uiTargetReferences = @($UiTargetEvidencePath | ForEach-Object { Get-ArtifactReference $_ 'ui-target-resolution' $true })
if (-not $contextReference) { [void]$warnings.Add('OPTIONAL_CONTEXT_PACKAGE_MISSING') }
if (-not $mapperReference) { [void]$warnings.Add('OPTIONAL_PROJECT_MAP_MISSING') }
if ($GraphSummaryPath -and -not $graphReference) { [void]$warnings.Add('OPTIONAL_GRAPH_SUMMARY_MISSING') }
$contextDecision = $null
if ($contextReference) {
    try {
        $contextPackage = [System.IO.File]::ReadAllText((Resolve-ProjectFile $ContextPackagePath), [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        $contextDecision = [ordered]@{
            fastContextUsed = [bool]$contextPackage.decision.fastContextUsed
            fastContextFallback = [bool]$contextPackage.decision.fastContextFallback
            fallbackReasons = @($contextPackage.decision.fallbackReasons)
            rawSourceFallbackUsed = [bool]$contextPackage.sourceAccess.rawSourceFallbackUsed
            contextExpansions = @($contextPackage.contextExpansions | ForEach-Object { [ordered]@{ workflow = [string]$_.workflow; mode = [string]$_.mode; reason = [string]$_.reason; additionalBytes = [int64]$_.additionalBytes; sha256 = [string]$_.sha256 } })
        }
    } catch { $status = 'BLOCKED'; [void]$warnings.Add('CONTEXT_PACKAGE_INVALID') }
}
$findings = @($validation.findings | ForEach-Object { [string]$_ } | Where-Object { $_ } | Select-Object -Unique)
$evidence = [ordered]@{
    schemaVersion = 1
    createdAtUtc = [DateTime]::UtcNow.ToString('o')
    taskId = $TaskId
    status = $status
    riskClass = $RiskClass
    audit = [ordered]@{ requestedMode = $RequestedAuditMode; effectiveMode = $effectiveAuditMode; escalated = $auditEscalated; uncertainty = [bool]$Uncertainty }
    implementationSummary = if ($DeveloperSummary.Length -gt 2000) { $DeveloperSummary.Substring(0,2000) } else { $DeveloperSummary }
    selectedWorkflows = $selected
    inspectedWorkflows = $inspected
    modifiedFiles = $modifiedRecords.ToArray()
    validation = [ordered]@{ status = $validationStatus; sourceFingerprint = $validatedSourceFingerprint; reference = $validationReference; findings = $findings; validationCompleted=$validationCompleted; buildExecuted=$buildExecuted; buildSucceeded=$buildSucceeded; deliveryReady=$deliveryReady; blockedReason=$blockedReason }
    source = [ordered]@{ fingerprint = [string]$snapshot.sourceFingerprint; executableFingerprint = [string]$snapshot.executableFingerprint; documentationFingerprint = [string]$snapshot.documentationFingerprint; graphConfigFingerprint = [string]$snapshot.graphConfigFingerprint; capturedAtUtc = [string]$snapshot.capturedAtUtc }
    context = [ordered]@{ package = $contextReference; mapper = $mapperReference; graphSummary = $graphReference; decision = $contextDecision }
    uiTargets = $uiTargetReferences
    warnings = $warnings.ToArray()
}
Write-AtomicJson $fullEvidencePath $evidence -SimulateFailure:$SimulateEvidenceWriteFailure
$evidenceEnded = [DateTime]::UtcNow
$evidenceSeconds = [Math]::Round(($evidenceEnded - $evidenceStarted).TotalSeconds, 6)

$handoffStarted = [DateTime]::UtcNow
$handoff = [ordered]@{
    schemaVersion = 1
    createdAtUtc = [DateTime]::UtcNow.ToString('o')
    taskId = $TaskId
    status = $status
    riskClass = $RiskClass
    auditMode = $effectiveAuditMode
    auditorHandoffRequired = $effectiveAuditMode -ne 'NONE'
    uncertainty = [bool]$Uncertainty
    changedFiles = @($modifiedRecords | ForEach-Object path)
    selectedWorkflows = $selected
    sourceFingerprint = [string]$snapshot.sourceFingerprint
    validationStatus = $validationStatus
    deliveryStatus = if($deliveryReady){'DELIVERABLE'}else{'VALIDATION_INCOMPLETE'}
    blockedReason = $blockedReason
    findings = $findings
    evidence = Get-ArtifactReference $EvidencePath 'developer-evidence' $true
    validation = $validationReference
    contextPackage = $contextReference
    projectMap = $mapperReference
    graphSummary = $graphReference
    uiTargets = $uiTargetReferences
    warnings = $warnings.ToArray()
}
Write-AtomicJson $fullHandoffPath $handoff
$handoffEnded = [DateTime]::UtcNow
$handoffSeconds = [Math]::Round(($handoffEnded - $handoffStarted).TotalSeconds, 6)

Add-RetroactiveEvent -Category FINALIZATION -Subcategory 'fingerprint' -Operation 'finalization.source_fingerprint' -Started $fingerprintStarted -Ended $fingerprintEnded
Add-RetroactiveEvent -Category EVIDENCE -Subcategory 'serialization' -Operation 'evidence.prepare_and_write' -Started $evidenceStarted -Ended $evidenceEnded -Artifacts @((Get-ArtifactReference $EvidencePath 'developer-evidence' $true))
Add-RetroactiveEvent -Category FINALIZATION -Subcategory 'handoff' -Operation 'finalization.handoff_write' -Started $handoffStarted -Ended $handoffEnded -Artifacts @((Get-ArtifactReference $HandoffPath 'developer-handoff' $true))

$validationState=[ordered]@{validationRequired=$true;validationCompleted=$validationCompleted;diagnosticsExecuted=($diagnosticsGate -and [string]$diagnosticsGate.status -notin @('NOT_RUN','SKIPPED'));buildExecuted=$buildExecuted;buildSucceeded=$buildSucceeded;deliveryReady=$deliveryReady;blockedReason=$blockedReason;validationResultPath=(Get-RelativePath $fullValidationPath)}
if (-not $SimulateStateWriteFailure) {
    & $stateScript -Action ValidationState -TargetBotPath $ProjectPath -StatePath $ExecutionStatePath -ValidationStateJson ($validationState|ConvertTo-Json -Compress) -Json|Out-Null
}

$completionInput = [ordered]@{
    taskId = $TaskId
    status = $status
    riskClass = $RiskClass
    auditMode = $effectiveAuditMode
    evidencePath = Get-RelativePath $fullEvidencePath
    handoffPath = Get-RelativePath $fullHandoffPath
    validationResultPath = Get-RelativePath $fullValidationPath
    contextPackagePath = if ($contextReference) { [string]$contextReference.path } else { '' }
    sourceFingerprint = [string]$snapshot.sourceFingerprint
    changedFileCount = $modifiedRecords.Count
    uncertainty = [bool]$Uncertainty
    phases = @(
        [ordered]@{ name = 'developer.deterministic_finalization'; startedAtUtc = $helperStarted.ToString('o'); endedAtUtc = $handoffStarted.ToString('o'); status = 'PASS'; reason = 'Deterministic input validation, fingerprinting, hashing, and evidence preparation.' },
        [ordered]@{ name = 'developer.handoff'; startedAtUtc = $handoffStarted.ToString('o'); endedAtUtc = $handoffEnded.ToString('o'); status = 'PASS'; reason = 'Deterministic compact handoff creation.' },
        [ordered]@{ name = 'developer.completion'; startedAtUtc = $handoffEnded.ToString('o'); endedAtUtc = ([DateTime]::UtcNow).ToString('o'); status = 'PASS'; reason = 'Compact completion contract preparation.' }
    )
}
$stateArguments = @{
    Action = 'DeveloperFinalize'
    TargetBotPath = $ProjectPath
    StatePath = $ExecutionStatePath
    DeveloperCompletionJson = ($completionInput | ConvertTo-Json -Depth 10 -Compress)
    Json = $true
}
if ($SimulateStateWriteFailure) { $stateArguments.SimulateWriteFailure = $true }
$stateEvent=Start-DeveloperEvent -ProjectPath $ProjectPath -Category STATE -Subcategory 'atomic_replace' -Operation 'state.developer_finalize'
$stateResult = & $stateScript @stateArguments | ConvertFrom-Json
$stateCommittedAt = [DateTime]::UtcNow
Stop-DeveloperEvent -ProjectPath $ProjectPath -EventId $stateEvent.eventId -Status PASS -NowUtc $stateCommittedAt.ToString('o')|Out-Null
$status=[string]$stateResult.status
$runtimeBreakdownRelative='.ai/evidence/developer-runtime-breakdown.json'
$runtimeBreakdown=& $breakdownScript -ProjectPath $ProjectPath -StatePath $ExecutionStatePath -OutputPath $runtimeBreakdownRelative -Json|ConvertFrom-Json
$telemetryState=[ordered]@{ledgerPath=[string]$runtimeBreakdown.ledger.path;ledgerSha256=[string]$runtimeBreakdown.ledger.sha256;ledgerBytes=[int64]$runtimeBreakdown.ledger.bytes;summaryPath=$runtimeBreakdownRelative;attributionCoveragePct=[double]$runtimeBreakdown.attributionCoveragePct;majorTimingTotals=[ordered]@{developerTotalMs=[double]$runtimeBreakdown.developerTotalMs;activeExecutionMs=[double]$runtimeBreakdown.activeExecutionMs;userWaitMs=[double]$runtimeBreakdown.userWaitMs;externalInterruptionMs=[double]$runtimeBreakdown.externalInterruptionMs;unknownMs=[double]$runtimeBreakdown.unknownMs}}
& $stateScript -Action TelemetryUpdate -TargetBotPath $ProjectPath -StatePath $ExecutionStatePath -TelemetryJson ($telemetryState|ConvertTo-Json -Depth 8 -Compress) -Json|Out-Null
$totalThroughCommit = [Math]::Round(($stateCommittedAt - $helperStarted).TotalSeconds, 6)
$knownSeconds = $fingerprintSeconds + $evidenceSeconds + $handoffSeconds + [double]$stateResult.state_write_seconds
$result = [ordered]@{
    schemaVersion = 1
    status = $status
    taskId = $TaskId
    changedFiles = @($modifiedRecords | ForEach-Object path)
    validationStatus = $validationStatus
    deliveryStatus = if($deliveryReady){'DELIVERABLE'}else{'VALIDATION_INCOMPLETE'}
    deliveryReady = $deliveryReady
    blockedReason = $blockedReason
    structuralStatus = if ([string]$validation.structuralStatus) { [string]$validation.structuralStatus } else { [string]$validation.xaml_sanity.status }
    sourceFingerprint = [string]$snapshot.sourceFingerprint
    evidencePath = Get-RelativePath $fullEvidencePath
    handoffPath = Get-RelativePath $fullHandoffPath
    runtimeBreakdownPath = $runtimeBreakdownRelative
    attributionCoveragePct = [double]$runtimeBreakdown.attributionCoveragePct
    stateUpdateStatus = 'PASS'
    statePath = Get-RelativePath $ExecutionStatePath
    auditMode = $effectiveAuditMode
    auditorHandoffRequired = $effectiveAuditMode -ne 'NONE'
    warnings = $warnings.ToArray()
    timings = [ordered]@{
        fingerprintSeconds = $fingerprintSeconds
        evidencePreparationSeconds = $evidenceSeconds
        handoffCreationSeconds = $handoffSeconds
        stateWriteSeconds = [double]$stateResult.state_write_seconds
        stateWriteCount = [int]$stateResult.state_write_count
        totalHelperThroughStateCommitSeconds = $totalThroughCommit
        unexplainedResidualSeconds = [Math]::Max(0.0, [Math]::Round(($totalThroughCommit - $knownSeconds), 6))
    }
    outputBytes = 0
}
$previousOutputBytes = -1L
while ([int64]$result.outputBytes -ne $previousOutputBytes) {
    $previousOutputBytes = [int64]$result.outputBytes
    $serializedResult = ($result | ConvertTo-Json -Depth 15) + [Environment]::NewLine
    $result.outputBytes = [int64][System.Text.Encoding]::UTF8.GetByteCount($serializedResult)
}
Write-AtomicJson $fullResultPath $result
if ($Json) { $result | ConvertTo-Json -Depth 15 } else { $result }
