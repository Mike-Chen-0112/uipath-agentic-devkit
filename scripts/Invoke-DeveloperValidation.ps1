[CmdletBinding()]
param(
    [string]$ProjectPath = (Get-Location).Path,
    [string[]]$ChangedWorkflow = @(),
    [string[]]$ExpectedActivityLocalName = @(),
    [ValidateSet('New','Existing')][string]$ProjectKind = 'Existing',
    [ValidateSet('R0','R1','R2','R3','UNKNOWN')]
    [string]$RiskClassification = 'UNKNOWN',
    [string]$ChangeFactsJson,
    [string]$GovernanceFilePath,
    [switch]$RunDiagnostics,
    [string]$RunFile,
    [string]$InputArgumentsJson,
    [int]$TimeoutSeconds = 300,
    [string]$DependencyStatePath,
    [string]$PreviousValidationSummaryPath,
    [string]$ExecutionStatePath,
    [bool]$ReuseDependencyState = $true,
    [switch]$ForceDependencyRestore,
    [switch]$ReuseManagedIntegrity,
    [switch]$OutputQaRequired,
    [switch]$OutputQaComplete,
    [string]$ExpectedSourceFingerprint = '',
    [string]$ValidationSummaryPath,
    [string]$ResultPath = '.ai/evidence/developer-validation.json',
    [switch]$ThrowOnFailure,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$helperStarted = [DateTime]::UtcNow
$ProjectPath = (Resolve-Path $ProjectPath).Path
$projectPrefix = $ProjectPath.TrimEnd('\','/') + [System.IO.Path]::DirectorySeparatorChar
$utf8 = New-Object System.Text.UTF8Encoding($false)
$validationScript = Join-Path $PSScriptRoot 'Validate-RpaProject.ps1'
$sanityScript = Join-Path $PSScriptRoot 'Test-ChangedWorkflowSanity.ps1'
$fingerprintScript = Join-Path $PSScriptRoot 'SourceFingerprint.ps1'
$stateScript = Join-Path $PSScriptRoot 'ExecutionState.ps1'
$telemetryModule = Join-Path $PSScriptRoot 'DeveloperTelemetry.psm1'
$ExecutionStatePath = if ($ExecutionStatePath) { [System.IO.Path]::GetFullPath($ExecutionStatePath) } else { Join-Path $ProjectPath '.ai\evidence\execution-state.json' }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$ValidationSummaryPath = if ($ValidationSummaryPath) { [System.IO.Path]::GetFullPath($ValidationSummaryPath) } else { Join-Path $ProjectPath ".ai\evidence\validation-developer-$stamp.json" }

function Resolve-ProjectFile {
    param([string]$Path)
    $candidate = if ([System.IO.Path]::IsPathRooted($Path)) { [System.IO.Path]::GetFullPath($Path) } else { [System.IO.Path]::GetFullPath((Join-Path $ProjectPath ($Path -replace '/','\'))) }
    if (-not $candidate.StartsWith($projectPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Path must stay within the project: $Path" }
    return $candidate
}

function Write-AtomicJson {
    param([string]$Path, $Value)
    New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null
    $tempPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $backupPath = "$Path.$([guid]::NewGuid().ToString('N')).bak"
    try {
        [System.IO.File]::WriteAllText($tempPath, (($Value | ConvertTo-Json -Depth 15) + [Environment]::NewLine), $utf8)
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

foreach ($requiredHelper in @($validationScript,$sanityScript,$fingerprintScript,$stateScript,$telemetryModule)) {
    if (-not (Test-Path -LiteralPath $requiredHelper -PathType Leaf)) { throw "Required Developer validation helper is missing: $requiredHelper" }
}
if (-not (Test-Path -LiteralPath $ExecutionStatePath -PathType Leaf)) { throw "Execution state was not found: $ExecutionStatePath" }
$fullResultPath = Resolve-ProjectFile $ResultPath
$fullValidationSummaryPath = Resolve-ProjectFile $ValidationSummaryPath
$phaseStarted = $false
$structuralStarted = $null
$validationStarted = $null
$structural = $null
$validation = $null
$validationError = $null
$parentEvent=$null
Import-Module $telemetryModule -Force
$parentEvent=Start-DeveloperEvent -ProjectPath $ProjectPath -Category VALIDATION -Subcategory 'developer_validation_wrapper' -Operation 'validation.wrapper'

& $stateScript -Action PhaseStart -Stage developer -PhaseName developer.deterministic_local_validation -TargetBotPath $ProjectPath -StatePath $ExecutionStatePath -Json | Out-Null
$phaseStarted = $true
try {
    $structuralStarted = [DateTime]::UtcNow
    if (@($ChangedWorkflow).Count -gt 0) {
        $structural = & $sanityScript -ProjectPath $ProjectPath -ChangedFiles $ChangedWorkflow -ExpectedActivityLocalNames $ExpectedActivityLocalName -Json | ConvertFrom-Json
    } else {
        $structural = [pscustomobject][ordered]@{ schemaVersion = 1; status = 'NOT_APPLICABLE'; changedWorkflowCount = 0; workflows = @(); errors = @(); warnings = @() }
    }
    if ([string]$structural.status -eq 'FAIL') { throw 'Changed-workflow structural sanity failed.' }

    $validationStarted = [DateTime]::UtcNow
    $arguments = @{
        ProjectPath = $ProjectPath
        RiskClassification = $RiskClassification
        ValidationSummaryPath = $fullValidationSummaryPath
        ExecutionStatePath = $ExecutionStatePath
        ReuseDependencyState = $ReuseDependencyState
        TimeoutSeconds = $TimeoutSeconds
        ChangedWorkflow = $ChangedWorkflow
        ProjectKind = $ProjectKind
        ParentEventId = [string]$parentEvent.eventId
    }
    if ($ChangeFactsJson) { $arguments.ChangeFactsJson = $ChangeFactsJson }
    if ($GovernanceFilePath) { $arguments.GovernanceFilePath = $GovernanceFilePath }
    if ($RunDiagnostics) { $arguments.RunDiagnostics = $true }
    if ($RunFile) { $arguments.RunFile = $RunFile }
    if ($InputArgumentsJson) { $arguments.InputArgumentsJson = $InputArgumentsJson }
    if ($DependencyStatePath) { $arguments.DependencyStatePath = $DependencyStatePath }
    if ($PreviousValidationSummaryPath) { $arguments.PreviousValidationSummaryPath = $PreviousValidationSummaryPath }
    if ($ForceDependencyRestore) { $arguments.ForceDependencyRestore = $true }
    if ($ReuseManagedIntegrity) { $arguments.ReuseManagedIntegrity = $true }
    if ($OutputQaRequired) { $arguments.OutputQaRequired = $true }
    if ($OutputQaComplete) { $arguments.OutputQaComplete = $true }
    & $validationScript @arguments | Out-Null
} catch {
    $validationError = $_
} finally {
    if (Test-Path -LiteralPath $fullValidationSummaryPath -PathType Leaf) {
        try { $validation = [System.IO.File]::ReadAllText($fullValidationSummaryPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch { }
    }
}

$statuses = New-Object System.Collections.Generic.List[string]
if ($validation) {
    foreach ($name in @('project_json','xaml_sanity','enum_property_compatibility','package_compatibility','get_errors','workflow_validate','dependency_restore','build','analyzer','tests','integrity','output_qa')) {
        $value = $validation.$name
        if ($value -and $value.status) { [void]$statuses.Add([string]$value.status) }
    }
}
$overallStatus = if ([string]$structural.status -eq 'FAIL' -or $statuses.Contains('FAIL')) { 'FAIL' } elseif ($statuses.Contains('BLOCKED') -or $statuses.Contains('TIMEOUT') -or ($validationError -and -not $validation) -or ($validation -and -not [bool]$validation.delivery.deliveryReady)) { 'BLOCKED' } else { 'PASS' }
$snapshot = & $fingerprintScript -ProjectPath $ProjectPath -Json | ConvertFrom-Json
$validatedFingerprint = if ($validation -and $validation.source) { [string]$validation.source.fingerprint } else { '' }
$warnings = New-Object System.Collections.Generic.List[string]
if ($ExpectedSourceFingerprint -and $ExpectedSourceFingerprint -ne [string]$snapshot.sourceFingerprint) { $overallStatus = 'BLOCKED'; [void]$warnings.Add('EXPECTED_SOURCE_FINGERPRINT_MISMATCH') }
if ($validatedFingerprint -and $validatedFingerprint -ne [string]$snapshot.sourceFingerprint) { $overallStatus = 'BLOCKED'; [void]$warnings.Add('SOURCE_CHANGED_AFTER_VALIDATION') }
$findingText = if ($validation) { $validation | ConvertTo-Json -Depth 10 -Compress } else { '' }
$findings = @([regex]::Matches($findingText, 'ST-[A-Z]+-[0-9]+') | ForEach-Object Value | Select-Object -Unique)
$phaseStatus = if ($overallStatus -in @('PASS','FAIL','BLOCKED')) { $overallStatus } else { 'BLOCKED' }
if ($phaseStarted) {
    $phaseReason = if ($validationError) { [string]$validationError.Exception.Message } else { '' }
    $phaseResult = & $stateScript -Action PhaseEnd -Stage developer -PhaseName developer.deterministic_local_validation -PhaseStatus $phaseStatus -Reason $phaseReason -TargetBotPath $ProjectPath -StatePath $ExecutionStatePath -Json | ConvertFrom-Json
}
$structuralSeconds = if ($structuralStarted) {
    $structuralEnded = if ($validationStarted) { $validationStarted } else { [DateTime]::UtcNow }
    [Math]::Round(($structuralEnded - $structuralStarted).TotalSeconds, 3)
} else { 0 }

$result = [ordered]@{
    schemaVersion = 1
    status = $overallStatus
    structuralStatus = [string]$structural.status
    uiRobustnessWarnings = @($structural.warnings | Where-Object { [string]$_.code -like 'UI_*' })
    validationSummaryPath = $fullValidationSummaryPath.Substring($projectPrefix.Length) -replace '\\','/'
    validationSummarySha256 = if (Test-Path -LiteralPath $fullValidationSummaryPath -PathType Leaf) { (Get-FileHash -LiteralPath $fullValidationSummaryPath -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
    sourceFingerprint = [string]$snapshot.sourceFingerprint
    validatedSourceFingerprint = $validatedFingerprint
    diagnosticsDecision = if ($validation) { $validation.diagnostics_decision } else { $null }
    gates = if ($validation) { [ordered]@{ projectJson = $validation.project_json; xamlSanity = $validation.xaml_sanity; enumPropertyCompatibility=$validation.enum_property_compatibility; packageCompatibility=$validation.package_compatibility; diagnostics = $validation.get_errors; dependencyRestore = $validation.dependency_restore; build = $validation.build; analyzer = $validation.analyzer; functionalTest = $validation.tests; integrity = $validation.integrity; outputQa = $validation.output_qa } } else { $null }
    workflowValidate = if($validation){$validation.workflow_validate}else{$null}
    delivery = if($validation){$validation.delivery}else{$null}
    environment = if($validation){$validation.environment}else{$null}
    findings = $findings
    warnings = $warnings.ToArray()
    error = if ($validationError) { [string]$validationError.Exception.Message } else { $null }
    timings = [ordered]@{
        structuralSanitySeconds = $structuralSeconds
        validationCommandSeconds = if ($validation -and $validation.timings) { [double]$validation.timings.validationTotal } elseif ($validationStarted) { [Math]::Round(([DateTime]::UtcNow - $validationStarted).TotalSeconds, 3) } else { 0 }
        deterministicValidationPhaseSeconds = if ($phaseResult) { [double]$phaseResult.phase.duration_seconds } else { [Math]::Round(([DateTime]::UtcNow - $helperStarted).TotalSeconds, 3) }
        diagnosticsSeconds = if ($validation -and $validation.timings) { [double]$validation.timings.diagnostics } else { 0 }
        restoreSeconds = if ($validation -and $validation.timings) { [double]$validation.timings.restore } else { 0 }
        buildSeconds = if ($validation -and $validation.timings) { [double]$validation.timings.build } else { 0 }
        evidencePreparationSeconds = if ($validation -and $validation.timings) { [double]$validation.timings.evidencePreparation } else { 0 }
    }
}
Write-AtomicJson $fullResultPath $result
Stop-DeveloperEvent -ProjectPath $ProjectPath -EventId $parentEvent.eventId -Status $phaseStatus -Artifacts @([ordered]@{path=($fullResultPath.Substring($projectPrefix.Length) -replace '\\','/');bytes=(Get-Item -LiteralPath $fullResultPath).Length;sha256=(Get-FileHash -LiteralPath $fullResultPath -Algorithm SHA256).Hash.ToLowerInvariant()})|Out-Null
if ($Json) { $result | ConvertTo-Json -Depth 15 } else { $result }
if ($ThrowOnFailure -and $overallStatus -ne 'PASS') { throw "Developer validation ended with $overallStatus. Result: $fullResultPath" }
