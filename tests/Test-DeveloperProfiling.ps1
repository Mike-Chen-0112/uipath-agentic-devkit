[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$stateScript = Join-Path $root 'scripts\ExecutionState.ps1'
$profileScript = Join-Path $root 'scripts\Get-DeveloperContextProfile.ps1'
$testRoot = Join-Path $env:TEMP ('rpa-developer-profiling-tests-' + [guid]::NewGuid().ToString('N'))

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Write-Utf8 {
    param([string]$Path, [string]$Value)
    New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null
    [System.IO.File]::WriteAllText($Path, $Value, (New-Object System.Text.UTF8Encoding($false)))
}

try {
    New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
    Write-Utf8 (Join-Path $testRoot '.github\agents\rpa-developer.agent.md') 'developer instructions'
    Write-Utf8 (Join-Path $testRoot 'AGENTS.md') 'compact bot context'
    Write-Utf8 (Join-Path $testRoot '.ai\evidence\developer-handoff.json') '{"scope":["Workflow.xaml"]}'
    Write-Utf8 (Join-Path $testRoot '.ai\evidence\project-map.json') '{"workflows":{"Workflow.xaml":{}}}'
    Write-Utf8 (Join-Path $testRoot 'graphify-out\GRAPH_REPORT.md') 'compact graph summary'
    Write-Utf8 (Join-Path $testRoot 'graphify-out\graph.json') '{"nodes":[1],"edges":[]}'
    Write-Utf8 (Join-Path $testRoot '.ai\context\architecture.md') 'relevant architecture context'
    Write-Utf8 (Join-Path $testRoot 'Workflow.xaml') '<Activity />'

    & $stateScript -Action Start -TaskType modification -TargetBotPath $testRoot -NowUtc '2026-09-10T10:00:00Z' -Json | Out-Null
    & $stateScript -Action StageEnd -Stage coordinator -TargetBotPath $testRoot -NowUtc '2026-09-10T10:01:00Z' -Json | Out-Null
    & $stateScript -Action PhaseStart -PhaseName developer.request_to_first_tool -Stage developer -TargetBotPath $testRoot -NowUtc '2026-09-10T10:01:10Z' -Json | Out-Null
    $requestPhase = & $stateScript -Action PhaseEnd -PhaseName developer.request_to_first_tool -TargetBotPath $testRoot -NowUtc '2026-09-10T10:01:20.250Z' -Json | ConvertFrom-Json
    Assert-True ($requestPhase.phase.duration_seconds -eq 10.25) 'Developer phase duration lost subsecond precision.'
    & $stateScript -Action PhaseUnavailable -PhaseName developer.host_start -Stage developer -Reason 'Agent host does not expose this boundary.' -TargetBotPath $testRoot -NowUtc '2026-09-10T10:01:20.250Z' -Json | Out-Null
    & $stateScript -Action StageStart -Stage developer -TargetBotPath $testRoot -NowUtc '2026-09-10T10:01:20.250Z' -Json | Out-Null
    & $stateScript -Action PhaseStart -PhaseName developer.context_build -Stage developer -TargetBotPath $testRoot -NowUtc '2026-09-10T10:01:20.250Z' -Json | Out-Null
    & $stateScript -Action PhaseEnd -PhaseName developer.context_build -TargetBotPath $testRoot -NowUtc '2026-09-10T10:01:30.250Z' -Json | Out-Null
    & $stateScript -Action PhaseStart -PhaseName developer.implementation -Stage developer -TargetBotPath $testRoot -NowUtc '2026-09-10T10:01:35Z' -Json | Out-Null
    $overlapBlocked = $false
    try { & $stateScript -Action PhaseStart -PhaseName developer.overlap -Stage developer -TargetBotPath $testRoot -NowUtc '2026-09-10T10:01:35Z' -Json 2>$null | Out-Null } catch { $overlapBlocked = $_.Exception.Message -match 'already running' }
    Assert-True $overlapBlocked 'Overlapping Developer timing phases were not rejected.'
    & $stateScript -Action PhaseEnd -PhaseName developer.implementation -TargetBotPath $testRoot -NowUtc '2026-09-10T10:02:00Z' -Json | Out-Null
    & $stateScript -Action StageEnd -Stage developer -TargetBotPath $testRoot -NowUtc '2026-09-10T10:02:00Z' -Json | Out-Null
    $report = & $stateScript -Action Report -TargetBotPath $testRoot -NowUtc '2026-09-10T10:02:00Z' -Json | ConvertFrom-Json
    Assert-True ($report.phase_report.lifecycle_seconds -eq 50 -and $report.phase_report.instrumented_phase_seconds -eq 45.25 -and $report.phase_report.observable_gap_seconds -eq 4.75 -and $report.phase_report.attributed_seconds -eq 50 -and $report.phase_report.coverage_percent -eq 100) 'Developer phase precision or observable-gap coverage report is incorrect.'
    Assert-True ($report.phase_report.observable_gaps[0].status -eq 'OBSERVED_GAP') 'Inter-phase agent wait was not identified.'
    Assert-True (@($report.phases | Where-Object status -eq 'NOT_INSTRUMENTABLE').Count -eq 1) 'Unavailable host boundary was not preserved.'

    $profilePath = Join-Path $testRoot '.ai\evidence\developer-context-profile.json'
    $profile = & $profileScript -ProjectPath $testRoot -HandoffPath '.ai/evidence/developer-handoff.json' -ProjectMapPath '.ai/evidence/project-map.json' -GraphContextPath 'graphify-out/GRAPH_REPORT.md' -ContextPath '.ai/context/architecture.md' -SourcePath 'Workflow.xaml' -OutputPath $profilePath -Json | ConvertFrom-Json
    Assert-True ($profile.totalIncludedFiles -eq 8 -and $profile.totalIncludedBytes -gt 0 -and $profile.totalEstimatedTokens -gt 0) 'Developer context totals were not produced.'
    Assert-True ($profile.sourceFilesIncluded -eq 1 -and $profile.rawXamlFilesIncluded -eq 1) 'Developer source/XAML context counts are incorrect.'
    Assert-True (-not $profile.fullGraphifyJsonIncluded -and $profile.priorRoleTranscriptFilesIncluded -eq 0) 'Compact context incorrectly reported full Graphify or transcript inclusion.'
    Assert-True ($profile.hostProvidedContext.systemPrompt -eq 'NOT_INSTRUMENTABLE' -and (Test-Path $profilePath -PathType Leaf)) 'Host limitation or profile evidence was not recorded.'
    $fullGraphProfile = & $profileScript -ProjectPath $testRoot -GraphContextPath 'graphify-out/graph.json' -Json | ConvertFrom-Json
    Assert-True $fullGraphProfile.fullGraphifyJsonIncluded 'Full Graphify JSON inclusion was not detected.'

    Write-Host '[PASS] Developer timing and context profiling tests'
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
