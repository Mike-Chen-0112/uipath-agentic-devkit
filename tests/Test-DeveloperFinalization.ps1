[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$testRoot = Join-Path $env:TEMP ('rpa-developer-finalization-tests-' + [guid]::NewGuid().ToString('N'))
$fakeBin = Join-Path $testRoot 'fake-bin'
$originalPath = $env:PATH
$originalFailBuild = $env:FAKE_UIP_FAIL_BUILD
$powerShellHost = (Get-Process -Id $PID).Path
$stateScript = Join-Path $root 'scripts\ExecutionState.ps1'
$fingerprintScript = Join-Path $root 'scripts\SourceFingerprint.ps1'
$validationWrapper = Join-Path $root 'scripts\Invoke-DeveloperValidation.ps1'
$finalizer = Join-Path $root 'scripts\Complete-DeveloperRun.ps1'

function Assert-True { param([bool]$Condition,[string]$Message); if (-not $Condition) { throw $Message } }
function Write-Utf8 { param([string]$Path,[string]$Text); New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null; [System.IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($false))) }

function New-FakeUip {
    New-Item -ItemType Directory -Force -Path $fakeBin | Out-Null
    "@echo off`n`"$powerShellHost`" -NoLogo -NoProfile -File `"%~dp0fake-uip.ps1`" %*`nexit /b %ERRORLEVEL%" | Set-Content (Join-Path $fakeBin 'uip.cmd') -Encoding ascii
    @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
$line = $Arguments -join '|'
if ($line -in @('--help','--version')) { if ($line -eq '--version') { 'uip-finalization-test 1.0' }; exit 0 }
if ($line -like 'rpa|get-errors*') { '[]'; exit 0 }
if ($line -like 'rpa|restore*') { exit 0 }
if ($line -like 'rpa|validate*') { '{"success":true,"errors":[]}'; exit 0 }
if ($line -like 'rpa|build*') { if ($env:FAKE_UIP_FAIL_BUILD -eq '1') { 'Build failed: Analyzer error: ST-SEC-008'; exit 9 }; '{"Result":"Success"}'; exit 0 }
if ($line -like 'rpa|analyze*') { '{"Result":"Success"}'; exit 0 }
exit 2
'@ | Set-Content (Join-Path $fakeBin 'fake-uip.ps1') -Encoding utf8
}

function New-TestProject {
    param([string]$Path, [switch]$Child)
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    [ordered]@{ name = 'FinalizationBot'; main = 'Main.xaml'; targetFramework = 'Windows'; expressionLanguage = 'VisualBasic'; dependencies = [ordered]@{} } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $Path 'project.json') -Encoding utf8
    Write-Utf8 (Join-Path $Path 'Main.xaml') '<Activity xmlns="urn:test"><Sequence><AddQueueItem /></Sequence></Activity>'
    if ($Child) { Write-Utf8 (Join-Path $Path 'Child.xaml') '<Activity xmlns="urn:test"><LogMessage /></Activity>' }
    & $stateScript -Action Start -TaskType modification -TargetBotPath $Path -Json | Out-Null
    & $stateScript -Action StageEnd -Stage coordinator -TargetBotPath $Path -Json | Out-Null
    & $stateScript -Action StageStart -Stage developer -TargetBotPath $Path -Json | Out-Null
}

function New-ValidationFixture {
    param([string]$Project,[ValidateSet('PASS','FAIL','BLOCKED')][string]$Status,[string[]]$Findings=@())
    $snapshot = & $fingerprintScript -ProjectPath $Project -Json | ConvertFrom-Json
    $path = Join-Path $Project '.ai\evidence\developer-validation.json'
    [ordered]@{
        schemaVersion = 1
        status = $Status
        structuralStatus = if ($Status -eq 'PASS') { 'PASS' } else { $Status }
        sourceFingerprint = [string]$snapshot.sourceFingerprint
        validatedSourceFingerprint = [string]$snapshot.sourceFingerprint
        findings = $Findings
        gates = [ordered]@{ build = [ordered]@{ status = $Status; findings = $Findings } }
    } | ConvertTo-Json -Depth 8 | Set-Content $path -Encoding utf8
    return [pscustomobject]@{ path = $path; fingerprint = [string]$snapshot.sourceFingerprint }
}

function Invoke-FixtureFinalizer {
    param([string]$Project,$Fixture,[string[]]$Modified=@(),[string[]]$UiTargetEvidence=@(),[switch]$Uncertainty,[switch]$FailEvidence,[switch]$FailState,[string]$Expected='')
    $arguments = @{
        ProjectPath = $Project
        TaskId = 'finalization-test'
        RiskClass = 'R1'
        RequestedAuditMode = if ($Uncertainty) { 'NONE' } else { 'LIGHT' }
        SelectedWorkflow = @('Main.xaml')
        InspectedWorkflow = @('Main.xaml')
        ModifiedFile = $Modified
        ValidationResultPath = $Fixture.path
        UiTargetEvidencePath = $UiTargetEvidence
        DeveloperSummary = 'Deterministic finalization test summary.'
        ExpectedSourceFingerprint = if ($Expected) { $Expected } else { $Fixture.fingerprint }
        Uncertainty = [bool]$Uncertainty
        SimulateEvidenceWriteFailure = [bool]$FailEvidence
        SimulateStateWriteFailure = [bool]$FailState
        Json = $true
    }
    return (& $finalizer @arguments | ConvertFrom-Json)
}

try {
    New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
    New-FakeUip
    $env:PATH = "$fakeBin$([System.IO.Path]::PathSeparator)$originalPath"

    # One deterministic validation call owns structural sanity, validation-stage execution, and its phase boundary.
    $normal = Join-Path $testRoot 'normal-r1'
    New-TestProject $normal
    $snapshot = & $fingerprintScript -ProjectPath $normal -Json | ConvertFrom-Json
    $facts = [ordered]@{
        projectJsonChanged=$false; dependencyChanged=$false; newWorkflow=$false; deletedWorkflow=$false; workflowArgumentsChanged=$false
        invokeTopologyChanged=$false; uiAutomationStructureChanged=$false; securitySensitiveChanged=$false; unresolvedDependency=$false
        generatedXaml=$false; activityTypeChanged=$false; activityPropertySerializationChanged=$false; enumBackedPropertyChanged=$false
        selectorSerializationChanged=$false; targetDescriptorChanged=$false; packageCompatibilityChanged=$false
        relevantMapperWarning=$false; architectureChanged=$false; developerUncertainty=$false; ambiguousImpact=$false; localizedScope=$true
        textOnly=$false; loggingOnly=$true; nonStructuralPropertyChange=$false; localizedConfigurationChange=$false
        changedFiles=@('Main.xaml'); changedWorkflows=@('Main.xaml')
    } | ConvertTo-Json -Depth 5 -Compress
    $validationResult = & $validationWrapper -ProjectPath $normal -ChangedWorkflow @('Main.xaml') -ExpectedActivityLocalName @('AddQueueItem') -RiskClassification R1 -ChangeFactsJson $facts -ReuseManagedIntegrity -ExpectedSourceFingerprint $snapshot.sourceFingerprint -Json | ConvertFrom-Json
    Assert-True ($validationResult.status -eq 'PASS' -and $validationResult.structuralStatus -eq 'PASS' -and $validationResult.gates.build.status -eq 'PASS') 'One-call localized R1 validation did not pass.'
    Assert-True ($validationResult.timings.deterministicValidationPhaseSeconds -ge $validationResult.timings.validationCommandSeconds -and $validationResult.timings.evidencePreparationSeconds -ge 0) 'Validation phase does not represent deterministic validation execution.'
    $normalState = Get-Content (Join-Path $normal '.ai\evidence\execution-state.json') -Raw | ConvertFrom-Json
    $validationPhase = @($normalState.phases | Where-Object name -eq 'developer.deterministic_local_validation')
    Assert-True ($validationPhase.Count -eq 1 -and $validationPhase[0].status -eq 'PASS' -and $normalState.stages.developer.active_started_at) 'Validation wrapper did not close its phase and resume Developer.'

    Write-Utf8 (Join-Path $normal '.ai\evidence\ui-target-resolution.json') '{"status":"REUSED","targetId":"web.fixture","artifact":{"path":".ai/evidence/target.png","sha256":"reference-only"}}'
    $normalFinal = Invoke-FixtureFinalizer -Project $normal -Fixture ([pscustomobject]@{ path=(Join-Path $normal '.ai\evidence\developer-validation.json'); fingerprint=$snapshot.sourceFingerprint }) -Modified @('Main.xaml') -UiTargetEvidence @('.ai/evidence/ui-target-resolution.json')
    $normalState = Get-Content (Join-Path $normal '.ai\evidence\execution-state.json') -Raw | ConvertFrom-Json
    $normalEvidenceText = Get-Content (Join-Path $normal '.ai\evidence\developer-evidence.json') -Raw
    Assert-True ($normalFinal.status -eq 'PASS' -and $normalFinal.timings.stateWriteCount -eq 1 -and $normalState.stages.developer.status -eq 'COMPLETE' -and $normalFinal.outputBytes -eq (Get-Item (Join-Path $normal '.ai\evidence\developer-finalization.json')).Length) "Normal Developer finalization did not commit once, report exact output size, and close the stage. Result: $($normalFinal | ConvertTo-Json -Depth 5 -Compress)"
    $knownFinalizationSeconds = [double]$normalFinal.timings.fingerprintSeconds + [double]$normalFinal.timings.evidencePreparationSeconds + [double]$normalFinal.timings.handoffCreationSeconds + [double]$normalFinal.timings.stateWriteSeconds
    $expectedResidualSeconds = [Math]::Max(0.0, [Math]::Round(([double]$normalFinal.timings.totalHelperThroughStateCommitSeconds - $knownFinalizationSeconds), 6))
    Assert-True ([Math]::Abs(([double]$normalFinal.timings.unexplainedResidualSeconds - $expectedResidualSeconds)) -lt 0.000001) 'Finalization residual timing lost sub-second precision.'
    Assert-True ((Test-Path (Join-Path $normal '.ai\evidence\developer-handoff.json')) -and $normalFinal.auditorHandoffRequired) 'Auditor handoff was not generated.'
    Assert-True ($normalEvidenceText -match 'ui-target-resolution' -and $normalEvidenceText -notmatch 'reference-only') 'UI target evidence was not referenced compactly by Developer finalization.'
    Assert-True ($normalEvidenceText -notmatch '<Activity' -and (Get-Item (Join-Path $normal '.ai\evidence\execution-state.json')).Length -lt 131072) 'Large source content leaked into compact finalization evidence/state.'
    foreach ($phaseName in @('developer.deterministic_local_validation','developer.deterministic_finalization','developer.handoff','developer.state_write','developer.completion','developer.semantic_result_summary','developer.final_tool_to_complete')) {
        Assert-True (@($normalState.phases | Where-Object name -eq $phaseName).Count -eq 1) "Finalization timing phase is missing: $phaseName"
    }

    # Zero and multiple changed files remain deterministic.
    $zero = Join-Path $testRoot 'zero-change'; New-TestProject $zero; $zeroFixture = New-ValidationFixture $zero PASS
    $zeroResult = Invoke-FixtureFinalizer -Project $zero -Fixture $zeroFixture
    Assert-True ($zeroResult.status -eq 'PASS' -and @($zeroResult.changedFiles).Count -eq 0) 'Zero-change finalization failed.'
    $multiple = Join-Path $testRoot 'multiple-change'; New-TestProject $multiple -Child; $multipleFixture = New-ValidationFixture $multiple PASS
    $multipleResult = Invoke-FixtureFinalizer -Project $multiple -Fixture $multipleFixture -Modified @('Main.xaml','Child.xaml')
    Assert-True ($multipleResult.status -eq 'PASS' -and @($multipleResult.changedFiles).Count -eq 2) 'Multiple-workflow finalization failed.'

    # Validation failure/blocking and analyzer findings survive into evidence and handoff.
    $failed = Join-Path $testRoot 'validation-fail'; New-TestProject $failed; $failedFixture = New-ValidationFixture $failed FAIL @('ST-SEC-008')
    $failedResult = Invoke-FixtureFinalizer -Project $failed -Fixture $failedFixture -Modified @('Main.xaml')
    $failedEvidence = Get-Content (Join-Path $failed '.ai\evidence\developer-evidence.json') -Raw | ConvertFrom-Json
    Assert-True ($failedResult.status -eq 'FAIL' -and $failedEvidence.validation.findings -contains 'ST-SEC-008') 'Validation FAIL or analyzer finding was lost.'
    $blocked = Join-Path $testRoot 'validation-blocked'; New-TestProject $blocked; $blockedFixture = New-ValidationFixture $blocked BLOCKED
    $blockedResult = Invoke-FixtureFinalizer -Project $blocked -Fixture $blockedFixture -Modified @('Main.xaml')
    Assert-True ($blockedResult.status -eq 'BLOCKED') 'Validation BLOCKED was not preserved.'

    # Uncertainty escalates audit, optional artifacts remain optional, and stale source blocks completion.
    $uncertain = Join-Path $testRoot 'uncertain'; New-TestProject $uncertain; $uncertainFixture = New-ValidationFixture $uncertain PASS
    $uncertainResult = Invoke-FixtureFinalizer -Project $uncertain -Fixture $uncertainFixture -Modified @('Main.xaml') -Uncertainty
    Assert-True ($uncertainResult.status -eq 'PASS' -and $uncertainResult.auditMode -eq 'LIGHT' -and $uncertainResult.warnings -contains 'DEVELOPER_UNCERTAINTY_REQUIRES_AUDIT') 'Developer uncertainty did not conservatively route to audit.'
    Assert-True ($uncertainResult.warnings -contains 'OPTIONAL_CONTEXT_PACKAGE_MISSING' -and $uncertainResult.warnings -contains 'OPTIONAL_PROJECT_MAP_MISSING') 'Missing optional artifact warnings were not preserved.'
    $stale = Join-Path $testRoot 'stale'; New-TestProject $stale; $staleFixture = New-ValidationFixture $stale PASS
    $staleResult = Invoke-FixtureFinalizer -Project $stale -Fixture $staleFixture -Modified @('Main.xaml') -Expected ('0' * 64)
    Assert-True ($staleResult.status -eq 'BLOCKED' -and $staleResult.warnings -contains 'EXPECTED_SOURCE_FINGERPRINT_MISMATCH') 'Stale expected source fingerprint did not block completion.'

    # Atomic evidence/state failures preserve the previous recoverable state; rerun succeeds.
    $evidenceFailure = Join-Path $testRoot 'evidence-failure'; New-TestProject $evidenceFailure; $evidenceFixture = New-ValidationFixture $evidenceFailure PASS
    $evidencePath = Join-Path $evidenceFailure '.ai\evidence\developer-evidence.json'; Write-Utf8 $evidencePath '{"sentinel":true}'
    $evidenceHash = (Get-FileHash $evidencePath -Algorithm SHA256).Hash; $evidenceStatePath = Join-Path $evidenceFailure '.ai\evidence\execution-state.json'; $evidenceStateHash = (Get-FileHash $evidenceStatePath -Algorithm SHA256).Hash
    $evidenceFailed = $false; try { Invoke-FixtureFinalizer -Project $evidenceFailure -Fixture $evidenceFixture -Modified @('Main.xaml') -FailEvidence | Out-Null } catch { $evidenceFailed = $true }
    Assert-True ($evidenceFailed -and (Get-FileHash $evidencePath -Algorithm SHA256).Hash -eq $evidenceHash -and (Get-FileHash $evidenceStatePath -Algorithm SHA256).Hash -eq $evidenceStateHash) 'Evidence failure damaged prior evidence or execution state.'
    $evidenceRecovery = Invoke-FixtureFinalizer -Project $evidenceFailure -Fixture $evidenceFixture -Modified @('Main.xaml')
    Assert-True ($evidenceRecovery.status -eq 'PASS') 'Recovery after evidence failure did not succeed.'

    $stateFailure = Join-Path $testRoot 'state-failure'; New-TestProject $stateFailure; $stateFixture = New-ValidationFixture $stateFailure PASS
    $statePath = Join-Path $stateFailure '.ai\evidence\execution-state.json'; $stateHash = (Get-FileHash $statePath -Algorithm SHA256).Hash
    $stateFailed = $false; try { Invoke-FixtureFinalizer -Project $stateFailure -Fixture $stateFixture -Modified @('Main.xaml') -FailState | Out-Null } catch { $stateFailed = $true }
    Assert-True ($stateFailed -and (Get-FileHash $statePath -Algorithm SHA256).Hash -eq $stateHash) 'State-write failure changed the prior recoverable state.'
    $stateRecovery = Invoke-FixtureFinalizer -Project $stateFailure -Fixture $stateFixture -Modified @('Main.xaml')
    Assert-True ($stateRecovery.status -eq 'PASS') 'Recovery after state-write failure did not succeed.'

    # The validation wrapper surfaces the existing analyzer finding without suppressing build failure.
    $buildFail = Join-Path $testRoot 'build-fail'; New-TestProject $buildFail; $buildFingerprint = & $fingerprintScript -ProjectPath $buildFail -Json | ConvertFrom-Json
    $env:FAKE_UIP_FAIL_BUILD = '1'
    $buildFailureResult = & $validationWrapper -ProjectPath $buildFail -ChangedWorkflow @('Main.xaml') -ExpectedActivityLocalName @('AddQueueItem') -RiskClassification R1 -ChangeFactsJson $facts -ReuseManagedIntegrity -ExpectedSourceFingerprint $buildFingerprint.sourceFingerprint -Json | ConvertFrom-Json
    Assert-True ($buildFailureResult.status -eq 'FAIL' -and $buildFailureResult.findings -contains 'ST-SEC-008' -and $buildFailureResult.gates.build.status -eq 'FAIL') 'Validation wrapper suppressed the analyzer build finding.'

    Write-Host '[PASS] Deterministic Developer validation and finalization tests'
}
finally {
    $env:PATH = $originalPath
    if ($null -eq $originalFailBuild) { Remove-Item Env:FAKE_UIP_FAIL_BUILD -ErrorAction SilentlyContinue } else { $env:FAKE_UIP_FAIL_BUILD = $originalFailBuild }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
