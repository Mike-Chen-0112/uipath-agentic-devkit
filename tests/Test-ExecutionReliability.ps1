[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$testRoot = Join-Path $env:TEMP ('rpa-ai-reliability-tests-' + [guid]::NewGuid().ToString('N'))
$fakeBin = Join-Path $testRoot 'fake-bin'
$originalPath = $env:PATH
$originalFakeLog = $env:FAKE_UIP_LOG
$powerShellHost = (Get-Process -Id $PID).Path

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function New-FakeUip {
    New-Item -ItemType Directory -Force -Path $fakeBin | Out-Null
    "@echo off`n`"$powerShellHost`" -NoLogo -NoProfile -File `"%~dp0fake-uip.ps1`" %*`nexit /b %ERRORLEVEL%" |
        Set-Content (Join-Path $fakeBin 'uip.cmd') -Encoding ascii
    @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
$line = $Arguments -join '|'
if ($env:FAKE_UIP_LOG) { Add-Content $env:FAKE_UIP_LOG $line }
if ($line -in @('--help','--version')) {
    if ($line -eq '--version') { 'uip-reliability-test 1.0' }
    exit 0
}
if ($line -like 'rpa|get-errors*') { '[]'; exit 0 }
if ($line -like 'rpa|validate*') { '{"Result":"Success"}'; exit 0 }
if ($line -like 'rpa|restore*') { exit 0 }
if ($line -like 'rpa|build*') { if ($env:FAKE_UIP_FAIL_BUILD -eq '1') { exit 9 }; '{"Result":"Success"}'; exit 0 }
if ($line -like 'rpa|analyze*') { '{"Result":"Success"}'; exit 0 }
exit 2
'@ | Set-Content (Join-Path $fakeBin 'fake-uip.ps1') -Encoding utf8
}

function New-TestProject {
    param([string]$Path)
    New-Item -ItemType Directory -Force -Path $Path,(Join-Path $Path 'docs') | Out-Null
    [ordered]@{ name = 'ReliabilityBot'; main = 'Main.xaml'; targetFramework = 'Windows'; expressionLanguage = 'VisualBasic'; dependencies = [ordered]@{} } |
        ConvertTo-Json -Depth 5 | Set-Content (Join-Path $Path 'project.json') -Encoding utf8
    '<Activity />' | Set-Content (Join-Path $Path 'Main.xaml') -Encoding utf8
    'initial documentation' | Set-Content (Join-Path $Path 'docs\README.md') -Encoding utf8
}

try {
    New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
    New-FakeUip
    $env:PATH = "$fakeBin$([System.IO.Path]::PathSeparator)$originalPath"
    $env:FAKE_UIP_LOG = Join-Path $testRoot 'uip.log'

    $stateBot = Join-Path $testRoot 'state-bot'
    New-Item -ItemType Directory -Force -Path $stateBot | Out-Null
    $stateScript = Join-Path $root 'scripts\ExecutionState.ps1'
    & $stateScript -Action Start -TaskType modification -TargetBotPath $stateBot -Json | Out-Null
    $statePath = Join-Path $stateBot '.ai\evidence\execution-state.json'
    $beforeHash = (Get-FileHash $statePath -Algorithm SHA256).Hash
    $writeFailed = $false
    try { & $stateScript -Action StageEnd -Stage coordinator -TargetBotPath $stateBot -SimulateWriteFailure -NowUtc '2026-09-08T10:01:00Z' -Json 2>$null | Out-Null } catch { $writeFailed = $true }
    Assert-True ($writeFailed -and (Get-FileHash $statePath -Algorithm SHA256).Hash -eq $beforeHash) 'State write failure did not preserve the previous valid JSON.'
    $statusHash = (Get-FileHash $statePath -Algorithm SHA256).Hash
    & $stateScript -Action Status -TargetBotPath $stateBot -Json | Out-Null
    Assert-True ((Get-FileHash $statePath -Algorithm SHA256).Hash -eq $statusHash) 'Read-only status changed the state file.'

    $commandBot = Join-Path $testRoot 'command-bot'
    New-Item -ItemType Directory -Force -Path $commandBot | Out-Null
    & $stateScript -Action Start -TaskType modification -TargetBotPath $commandBot -Json | Out-Null
    & $stateScript -Action StageEnd -Stage coordinator -TargetBotPath $commandBot -Json | Out-Null
    $commandStatePath = Join-Path $commandBot '.ai\evidence\execution-state.json'
    $commandScript = Join-Path $root 'scripts\Invoke-DevKitCommand.ps1'
    $silent = & $commandScript -FilePath $env:ComSpec -ArgumentList @('/c','exit','0') -WorkingDirectory $commandBot -TargetBotPath $commandBot -ExecutionStatePath $commandStatePath -Operation 'silent success' -TimeoutSeconds 5 -Json | ConvertFrom-Json
    $failure = & $commandScript -FilePath $env:ComSpec -ArgumentList @('/c','exit','7') -WorkingDirectory $commandBot -TargetBotPath $commandBot -ExecutionStatePath $commandStatePath -Operation 'nonzero failure' -TimeoutSeconds 5 -Json | ConvertFrom-Json
    $timeout = & $commandScript -FilePath $powerShellHost -ArgumentList @('-NoLogo','-NoProfile','-Command','Start-Sleep -Seconds 3') -WorkingDirectory $commandBot -TargetBotPath $commandBot -ExecutionStatePath $commandStatePath -Operation 'controlled timeout' -TimeoutSeconds 1 -Json | ConvertFrom-Json
    Assert-True ($silent.status -eq 'PASS' -and $failure.status -eq 'FAIL' -and $failure.exit_code -eq 7 -and $timeout.status -eq 'TIMEOUT' -and $timeout.timed_out) 'Command evidence did not distinguish silent success, failure, and timeout.'
    $largeOutput = & $commandScript -FilePath $powerShellHost -ArgumentList @('-NoLogo','-NoProfile','-Command',"'x' * 5000") -WorkingDirectory $commandBot -TargetBotPath $commandBot -ExecutionStatePath $commandStatePath -Operation 'large output reference' -TimeoutSeconds 5 -Json | ConvertFrom-Json
    $storageReport = & $stateScript -Action Report -TargetBotPath $commandBot -Json | ConvertFrom-Json
    Assert-True ($largeOutput.status -eq 'PASS' -and @($storageReport.commands).Count -eq 0 -and $storageReport.command_summary.total -ge 4 -and [string]$largeOutput.output_sha256 -match '^[0-9a-f]{64}$' -and (Test-Path $largeOutput.output_path -PathType Leaf)) "Large command output was not externalized from compact state (status=$($largeOutput.status), hash=$($largeOutput.output_sha256), path=$($largeOutput.output_path))."
    Assert-True ($storageReport.storage.serialized_state_bytes -gt 0 -and -not $storageReport.storage.abnormal_size_warning -and @($storageReport.storage.largest_state_sections).Count -ge 3 -and @($storageReport.storage.largest_evidence_artifacts).Count -ge 1) 'Execution-state size diagnostics are missing or incompatible.'

    $unicodeOutput = 'graph ' + [char]0x2014 + ' warning'
    $unicodeStart = & $stateScript -Action CommandStart -Operation 'unicode output stability' -TargetBotPath $commandBot -Json | ConvertFrom-Json
    & $stateScript -Action CommandEnd -CommandId $unicodeStart.command_id -ExitCode 0 -DurationSeconds 0.01 -CommandOutput $unicodeOutput -TargetBotPath $commandBot -Json | Out-Null
    $unicodeSizeBefore = (Get-Item -LiteralPath $commandStatePath).Length
    $rewriteJson = '{"validationRequired":true,"validationCompleted":false,"buildExecuted":false,"buildSucceeded":false,"deliveryReady":false}'
    1..8 | ForEach-Object { & $stateScript -Action ValidationState -ValidationStateJson $rewriteJson -TargetBotPath $commandBot -Json | Out-Null }
    $unicodeSizeAfter = (Get-Item -LiteralPath $commandStatePath).Length
    $unicodeState = [System.IO.File]::ReadAllText($commandStatePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    Assert-True (@($unicodeState.commands).Count -eq 0 -and $unicodeState.command_summary.last.output_bytes -gt 0 -and $unicodeSizeAfter -lt ($unicodeSizeBefore + 4096)) 'UTF-8 command evidence was embedded or expanded across repeated execution-state reads and writes.'

    $project = Join-Path $testRoot 'validation-project'
    New-TestProject $project
    $validation = Join-Path $root 'scripts\Validate-RpaProject.ps1'
    $dependencyState = Join-Path $project '.ai\evidence\dependency-state.json'
    $firstSummary = Join-Path $project '.ai\evidence\validation-first.json'
    $secondSummary = Join-Path $project '.ai\evidence\validation-second.json'
    $thirdSummary = Join-Path $project '.ai\evidence\validation-third.json'
    $lowRiskSummary = Join-Path $project '.ai\evidence\validation-low-risk.json'
    $highRiskSummary = Join-Path $project '.ai\evidence\validation-high-risk.json'
    $validationState = Join-Path $project '.ai\evidence\execution-state.json'

    $env:FAKE_UIP_FAIL_BUILD = '1'
    & $stateScript -Action Start -TaskType modification -TargetBotPath $project -StatePath $validationState | Out-Null
    & $stateScript -Action StageEnd -Stage coordinator -TargetBotPath $project -StatePath $validationState | Out-Null
    $partialFailed = $false
    try { & $validation -ProjectPath $project -RunDiagnostics -ReuseManagedIntegrity -DependencyStatePath $dependencyState -ValidationSummaryPath $firstSummary -ExecutionStatePath $validationState 2>$null | Out-Null } catch { $partialFailed = $true }
    $partial = Get-Content $firstSummary -Raw | ConvertFrom-Json
    $integrityReason = if ($partial.integrity.reason) { [string]$partial.integrity.reason } else { '' }
    Assert-True ($partialFailed -and $partial.get_errors.status -in @('PASS','REUSED') -and $partial.dependency_restore.status -in @('PASS','REUSED') -and $partial.build.status -eq 'FAIL') "Partial validation evidence was not preserved after a later build failure: integrity=$($partial.integrity.status), reason=$integrityReason, diagnostics=$($partial.get_errors.status), restore=$($partial.dependency_restore.status), build=$($partial.build.status)."
    Assert-True ($partial.timings.validationStageEnd -gt 0 -and $partial.timings.validationTotal -ge $partial.timings.build) 'Failure-path validation evidence was written before stage-end timing completed.'

    $env:FAKE_UIP_FAIL_BUILD = '0'
    & $validation -ProjectPath $project -RunDiagnostics -ReuseManagedIntegrity -DependencyStatePath $dependencyState -ValidationSummaryPath $firstSummary | Out-Null
    'documentation-only change' | Set-Content (Join-Path $project 'docs\README.md') -Encoding utf8
    & $validation -ProjectPath $project -RunDiagnostics -ReuseManagedIntegrity -DependencyStatePath $dependencyState -PreviousValidationSummaryPath $firstSummary -ValidationSummaryPath $secondSummary | Out-Null
    $second = Get-Content $secondSummary -Raw | ConvertFrom-Json
    Assert-True ($second.source.executableFingerprint -eq ((Get-Content $firstSummary -Raw | ConvertFrom-Json).source.executableFingerprint) -and $second.build.status -eq 'REUSED') 'Documentation-only change invalidated executable build reuse.'

    '<Activity Changed="true" />' | Set-Content (Join-Path $project 'Main.xaml') -Encoding utf8
    & $validation -ProjectPath $project -RunDiagnostics -ReuseManagedIntegrity -DependencyStatePath $dependencyState -PreviousValidationSummaryPath $secondSummary -ValidationSummaryPath $thirdSummary | Out-Null
    $third = Get-Content $thirdSummary -Raw | ConvertFrom-Json
    Assert-True ($third.build.status -eq 'PASS' -and $third.source.executableFingerprint -ne $second.source.executableFingerprint) 'Executable change did not invalidate build evidence.'

    $changeFacts = [ordered]@{
        projectJsonChanged = $false; dependencyChanged = $false; newWorkflow = $false; deletedWorkflow = $false
        workflowArgumentsChanged = $false; invokeTopologyChanged = $false; uiAutomationStructureChanged = $false
        generatedXaml = $false; activityTypeChanged = $false; activityPropertySerializationChanged = $false
        enumBackedPropertyChanged = $false; selectorSerializationChanged = $false; targetDescriptorChanged = $false; packageCompatibilityChanged = $false
        securitySensitiveChanged = $false; unresolvedDependency = $false; relevantMapperWarning = $false
        architectureChanged = $false; developerUncertainty = $false; ambiguousImpact = $false
        localizedScope = $true; textOnly = $false; loggingOnly = $true; nonStructuralPropertyChange = $false
        localizedConfigurationChange = $false; changedFiles = @('Main.xaml'); changedWorkflows = @('Main.xaml')
    } | ConvertTo-Json -Depth 5 -Compress
    Clear-Content $env:FAKE_UIP_LOG
    & $validation -ProjectPath $project -RiskClassification R1 -ChangeFactsJson $changeFacts -ReuseManagedIntegrity -DependencyStatePath $dependencyState -PreviousValidationSummaryPath $thirdSummary -ValidationSummaryPath $lowRiskSummary | Out-Null
    $lowRisk = Get-Content $lowRiskSummary -Raw | ConvertFrom-Json
    $lowRiskCommands = Get-Content $env:FAKE_UIP_LOG -Raw
    Assert-True (-not $lowRisk.diagnostics_decision.diagnosticsRequired -and -not $lowRisk.diagnostics_decision.diagnosticsExecuted -and $lowRisk.get_errors.status -eq 'SKIPPED' -and $lowRiskCommands -notmatch 'rpa\|get-errors') 'Eligible localized R1 validation did not skip diagnostics deterministically.'
    Assert-True ($lowRisk.timings.validationTotal -gt 0 -and $null -ne $lowRisk.timings.toolResolution -and $null -ne $lowRisk.timings.diagnosticsDecision -and $null -ne $lowRisk.timings.unexplainedResidual) 'Detailed validation timings were not generated.'

    Clear-Content $env:FAKE_UIP_LOG
    & $validation -ProjectPath $project -RiskClassification R2 -ChangeFactsJson $changeFacts -ReuseManagedIntegrity -DependencyStatePath $dependencyState -PreviousValidationSummaryPath $lowRiskSummary -ValidationSummaryPath $highRiskSummary | Out-Null
    $highRisk = Get-Content $highRiskSummary -Raw | ConvertFrom-Json
    $highRiskCommands = Get-Content $env:FAKE_UIP_LOG -Raw
    Assert-True ($highRisk.diagnostics_decision.diagnosticsRequired -and $highRisk.get_errors.status -eq 'PASS' -and ($highRisk.diagnostics_decision.diagnosticsExecuted -or $highRisk.get_errors.getErrorsReuse -gt 0)) 'Higher-risk validation neither executed nor safely reused diagnostics.'

    Write-Host '[PASS] Execution reliability focused tests'
}
finally {
    $env:PATH = $originalPath
    if ($null -eq $originalFakeLog) { Remove-Item Env:FAKE_UIP_LOG -ErrorAction SilentlyContinue } else { $env:FAKE_UIP_LOG = $originalFakeLog }
    Remove-Item Env:FAKE_UIP_FAIL_BUILD -ErrorAction SilentlyContinue
    Remove-Item $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
