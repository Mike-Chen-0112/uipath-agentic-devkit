[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('Start','Status','Read','EnvironmentStart','EnvironmentEnd','StageStart','StageEnd','StagePause','StageResume','PhaseStart','PhaseEnd','PhaseUnavailable','DeveloperFinalize','Pause','Resume','InterruptionStart','InterruptionEnd','CommandStart','CommandEnd','RepairStart','ValidationState','TelemetryUpdate','Complete','Report')]
    [string]$Action,
    [string]$TargetBotPath = (Get-Location).Path,
    [string]$StatePath,
    [ValidateSet('new_bot','modification')]
    [string]$TaskType,
    [ValidateSet('coordinator','coordinator_handoff','scaffolding','developer','validation','auditor','documentation','graph','finalization')]
    [string]$Stage,
    [string]$PhaseName = '',
    [string]$PhaseId = '',
    [ValidateSet('PASS','FAIL','BLOCKED','SKIPPED')]
    [string]$PhaseStatus = 'PASS',
    [string]$Reason = '',
    [string]$Operation = '',
    [string]$CommandId = '',
    [int]$ExitCode = 0,
    [double]$DurationSeconds = 0,
    [switch]$TimedOut,
    [string]$CommandOutput = '',
    [string]$CommandOutputPath = '',
    [int]$ProcessId = 0,
    [string]$Category = 'UNKNOWN',
    [string]$Subcategory = '',
    [string]$DeveloperCompletionJson = '',
    [string]$ValidationStateJson = '',
    [string]$TelemetryJson = '',
    [ValidateSet('PASS','REWORK','BLOCKED')]
    [string]$Outcome = 'PASS',
    [switch]$RequireAudit,
    [switch]$Resume,
    [string]$NowUtc,
    [switch]$Json,
    [switch]$SimulateWriteFailure
)

$ErrorActionPreference = 'Stop'
$TargetBotPath = (Resolve-Path $TargetBotPath).Path
$StatePath = if ($StatePath) { [System.IO.Path]::GetFullPath($StatePath) } else { Join-Path $TargetBotPath '.ai\evidence\execution-state.json' }
$stageNames = @('coordinator','coordinator_handoff','scaffolding','developer','validation','auditor','documentation','graph','finalization')
$script:ReadStateUpdatedAt = $null
$script:StateWriteLockPath = "$StatePath.lock"

function Get-Now {
    if ($NowUtc) { return [DateTime]::Parse($NowUtc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal) }
    return [DateTime]::UtcNow
}

$legacyBudgetFields = @('budget_clock','target_seconds','hard_limit_seconds','remaining_target_seconds','remaining_hard_limit_seconds','performance_state','performance_status','wall_clock_status','active_clock_status','hard_limit_reached')

function Get-StageObject {
    return [ordered]@{
        started_at = $null
        ended_at = $null
        active_started_at = $null
        duration_seconds = 0
        status = 'NOT_STARTED'
        intervals = @()
    }
}

function Read-State {
    if (-not (Test-Path $StatePath -PathType Leaf)) { throw "Execution state not found: $StatePath" }
    $state = [System.IO.File]::ReadAllText($StatePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($state.schema_version -notin @(2,3) -or -not $state.execution -or -not $state.stages) { throw "Unsupported or incomplete execution state: $StatePath" }
    if ($state.PSObject.Properties.Name -notcontains 'phases') { $state | Add-Member -NotePropertyName phases -NotePropertyValue @() }
    if ($state.execution.PSObject.Properties.Name -notcontains 'external_interruption_seconds') { $state.execution | Add-Member -NotePropertyName external_interruption_seconds -NotePropertyValue 0 }
    if ($state.execution.PSObject.Properties.Name -notcontains 'external_interruption_intervals') { $state.execution | Add-Member -NotePropertyName external_interruption_intervals -NotePropertyValue @() }
    if ($state.PSObject.Properties.Name -notcontains 'validation') { $state | Add-Member -NotePropertyName validation -NotePropertyValue ([pscustomobject][ordered]@{ validationRequired=$true; validationCompleted=$false; diagnosticsExecuted=$false; buildExecuted=$false; buildSucceeded=$false; deliveryReady=$false; blockedReason=$null }) }
    if ($state.PSObject.Properties.Name -notcontains 'telemetry') { $state | Add-Member -NotePropertyName telemetry -NotePropertyValue ([pscustomobject][ordered]@{ ledgerPath='.ai/evidence/developer-events.jsonl'; ledgerSha256=$null; ledgerBytes=0; summaryPath=$null; attributionCoveragePct=0; majorTimingTotals=$null }) }
    if ($state.PSObject.Properties.Name -notcontains 'command_summary') { $state | Add-Member -NotePropertyName command_summary -NotePropertyValue ([pscustomobject][ordered]@{ total=0;pass=0;fail=0;timeout=0;last=$null }) }
    if ($state.PSObject.Properties.Name -notcontains 'environment_setup') { $state | Add-Member -NotePropertyName environment_setup -NotePropertyValue ([pscustomobject]@{started_at=$null;ended_at=$null;status='NOT_STARTED';active_seconds=0;reason=$null}) }
    foreach($field in @('environment_setup_seconds','implementation_seconds')) {
        if($state.execution.PSObject.Properties.Name -notcontains $field){$state.execution | Add-Member -NotePropertyName $field -NotePropertyValue 0}
    }
    foreach($field in $legacyBudgetFields){ $state.execution.PSObject.Properties.Remove($field) }
    foreach($field in @('target_seconds','hard_limit_seconds')){ $state.environment_setup.PSObject.Properties.Remove($field) }
    foreach($name in $stageNames){ if($state.stages.$name){ $state.stages.$name.PSObject.Properties.Remove('budget_seconds') } }
    if([int]$state.max_repair_loops -lt 3){ $state.max_repair_loops = 3 }
    if($state.validation -and [string]$state.validation.blockedReason -eq 'HARD_LIMIT_BEFORE_REQUIRED_VALIDATION'){ $state.validation.blockedReason = $null }
    $script:ReadStateUpdatedAt = [string]$state.updated_at
    return $state
}

function Get-IntervalSeconds {
    param($Interval, [DateTime]$At)
    $start = [DateTime]::Parse([string]$Interval.started_at, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
    $end = if ($Interval.ended_at) { [DateTime]::Parse([string]$Interval.ended_at, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind) } else { $At }
    return [Math]::Max(0, ($end - $start).TotalSeconds)
}

function Get-WaitSeconds {
    param($State, [DateTime]$At)
    $total = 0.0
    foreach ($interval in @($State.execution.user_wait_intervals)) { $total += Get-IntervalSeconds $interval $At }
    return [Math]::Round($total, 3)
}

function Get-StageLiveSeconds {
    param($StageObject, [DateTime]$At)
    $total = [double]$StageObject.duration_seconds
    if ($StageObject.active_started_at) {
        $interval = [ordered]@{ started_at = $StageObject.active_started_at; ended_at = $null }
        $total += Get-IntervalSeconds $interval $At
    }
    return [Math]::Round($total, 3)
}

function Update-Clock {
    param($State, [DateTime]$At)
    $start = [DateTime]::Parse([string]$State.execution.started_at, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
    $end = if ($State.execution.ended_at) { [DateTime]::Parse([string]$State.execution.ended_at, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind) } else { $At }
    $wall = [Math]::Max(0, ($end - $start).TotalSeconds)
    $wait = Get-WaitSeconds $State $At
    $external = Get-ExternalInterruptionSeconds $State $At
    $active = [Math]::Max(0, $wall - $wait - $external)
    $State.execution.total_wall_seconds = [Math]::Round($wall, 3)
    $State.execution.user_wait_seconds = $wait
    $State.execution.external_interruption_seconds = $external
    $State.execution.active_execution_seconds = [Math]::Round($active, 3)
    $State.execution.elapsed_seconds = $State.execution.active_execution_seconds
    $setupSeconds=0.0
    if($State.environment_setup -and $State.environment_setup.started_at){
        $setupStart=[DateTime]::Parse([string]$State.environment_setup.started_at).ToUniversalTime()
        $setupEnd=if($State.environment_setup.ended_at){[DateTime]::Parse([string]$State.environment_setup.ended_at).ToUniversalTime()}else{$end}
        $setupSeconds=[Math]::Max(0,($setupEnd-$setupStart).TotalSeconds)
        foreach($interval in @($State.execution.user_wait_intervals)+@($State.execution.external_interruption_intervals)){
            $intervalStart=[DateTime]::Parse([string]$interval.started_at).ToUniversalTime()
            $intervalEnd=if($interval.ended_at){[DateTime]::Parse([string]$interval.ended_at).ToUniversalTime()}else{$end}
            $overlapStart=if($intervalStart -gt $setupStart){$intervalStart}else{$setupStart}
            $overlapEnd=if($intervalEnd -lt $setupEnd){$intervalEnd}else{$setupEnd}
            $setupSeconds-=[Math]::Max(0,($overlapEnd-$overlapStart).TotalSeconds)
        }
        $setupSeconds=[Math]::Max(0,$setupSeconds)
        $State.environment_setup.active_seconds=[Math]::Round($setupSeconds,3)
    }
    $implementation=[Math]::Max(0,$active-$setupSeconds)
    $State.execution.environment_setup_seconds=[Math]::Round($setupSeconds,3)
    $State.execution.implementation_seconds=[Math]::Round($implementation,3)
    return $State
}

function Write-State {
    param($State, [DateTime]$At = (Get-Now))
    Update-Clock $State $At | Out-Null
    $State.updated_at = $At.ToString('o')
    New-Item -ItemType Directory -Force -Path (Split-Path $StatePath -Parent) | Out-Null
    $lock = $null
    $tempPath = "$StatePath.$([guid]::NewGuid().ToString('N')).tmp"
    $backupPath = "$StatePath.$([guid]::NewGuid().ToString('N')).bak"
    try {
        try { $lock = New-Item -ItemType File -Path $script:StateWriteLockPath -ErrorAction Stop }
        catch { throw "Concurrent execution-state write detected: $StatePath" }
        if ($script:ReadStateUpdatedAt -and (Test-Path $StatePath -PathType Leaf)) {
            $currentUpdatedAt = [string](([System.IO.File]::ReadAllText($StatePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json).updated_at)
            if ($currentUpdatedAt -ne $script:ReadStateUpdatedAt) { throw "Concurrent execution-state update detected: $StatePath" }
        }
        [System.IO.File]::WriteAllText($tempPath, (($State | ConvertTo-Json -Depth 15) + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
        if ($SimulateWriteFailure) { throw 'Simulated execution-state write failure.' }
        if (Test-Path $StatePath -PathType Leaf) {
            try { [System.IO.File]::Replace($tempPath, $StatePath, $backupPath) }
            catch [System.UnauthorizedAccessException] {
                # Some managed Windows environments deny File.Replace's backup operation
                # while still permitting a same-directory replace through the provider.
                Move-Item -LiteralPath $tempPath -Destination $StatePath -Force -ErrorAction Stop
            }
            if (Test-Path $backupPath -PathType Leaf) { Remove-Item $backupPath -Force -ErrorAction SilentlyContinue }
        }
        else { [System.IO.File]::Move($tempPath, $StatePath) }
        $script:ReadStateUpdatedAt = $null
    }
    finally {
        if (Test-Path $tempPath -PathType Leaf) { Remove-Item $tempPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path $backupPath -PathType Leaf) { Remove-Item $backupPath -Force -ErrorAction SilentlyContinue }
        if ($lock) { Remove-Item $script:StateWriteLockPath -Force -ErrorAction SilentlyContinue }
    }
}

function Add-Interval {
    param($StageObject, [DateTime]$At, [string]$Status = 'COMPLETE')
    if (-not $StageObject.active_started_at) { throw 'Stage has no active interval.' }
    $start = [DateTime]::Parse([string]$StageObject.active_started_at, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
    $interval = [ordered]@{ started_at = [string]$StageObject.active_started_at; ended_at = $At.ToString('o'); duration_seconds = [Math]::Round(($At - $start).TotalSeconds, 3); status = $Status }
    $StageObject.intervals = @($StageObject.intervals) + $interval
    $StageObject.duration_seconds = [Math]::Round(([double]$StageObject.duration_seconds + [double]$interval.duration_seconds), 3)
    $StageObject.ended_at = $interval.ended_at
    $StageObject.active_started_at = $null
}

function Get-ActiveStage {
    param($State)
    foreach ($name in $stageNames) { if ($State.stages.$name.active_started_at) { return $name } }
    return $null
}

function Close-ActiveStage {
    param($State, [DateTime]$At, [string]$Status = 'PAUSED')
    $activeName = Get-ActiveStage $State
    if ($activeName) {
        Add-Interval $State.stages.$activeName $At $Status
        $State.stages.$activeName.status = $Status
        return $activeName
    }
    return $null
}

function Get-StageReport {
    param($State, [DateTime]$At)
    $durations = @($stageNames | ForEach-Object {
        $stage = $State.stages.$_
        [pscustomobject]@{ name = $_; duration_seconds = Get-StageLiveSeconds $stage $At; status = [string]$stage.status; interval_count = @($stage.intervals).Count }
    })
    $bottleneck = $durations | Sort-Object duration_seconds -Descending | Select-Object -First 1
    return [ordered]@{
        stages = $durations
        bottleneck = if ($bottleneck) { [ordered]@{ stage = $bottleneck.name; duration_seconds = $bottleneck.duration_seconds } } else { $null }
    }
}

function Get-ExternalInterruptionSeconds {
    param($State, [DateTime]$At)
    $total = 0.0
    foreach ($interval in @($State.execution.external_interruption_intervals)) { $total += Get-IntervalSeconds $interval $At }
    return [Math]::Round($total, 3)
}

function Get-PhaseReport {
    param($State, [DateTime]$At)
    $records = @($State.phases)
    $developerRecords = @($records | Where-Object { [string]$_.stage -eq 'developer' })
    $request = $developerRecords | Where-Object name -eq 'developer.request_to_first_tool' | Sort-Object started_at | Select-Object -First 1
    $developerStage = $State.stages.developer
    $lifecycleStart = if ($request -and $request.started_at) { [string]$request.started_at } elseif ($developerStage.started_at) { [string]$developerStage.started_at } else { $null }
    $lifecycleEnd = if ($developerStage.ended_at) { [string]$developerStage.ended_at } elseif ($lifecycleStart) { $At.ToString('o') } else { $null }
    $lifecycleSeconds = 0.0
    $lifecycleStartValue = $null
    $lifecycleEndValue = $null
    if ($lifecycleStart -and $lifecycleEnd) {
        $lifecycleStartValue = [DateTime]::Parse($lifecycleStart, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        $lifecycleEndValue = [DateTime]::Parse($lifecycleEnd, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        $lifecycleSeconds = [Math]::Max(0.0, ($lifecycleEndValue - $lifecycleStartValue).TotalSeconds)
    }
    $segments = @($developerRecords | Where-Object { $_.started_at -and [string]$_.status -ne 'NOT_INSTRUMENTABLE' } | ForEach-Object {
        $segmentStart = [DateTime]::Parse([string]$_.started_at, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        $segmentEnd = if ($_.ended_at) { [DateTime]::Parse([string]$_.ended_at, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind) } else { $At }
        [pscustomobject]@{ name = [string]$_.name; start = $segmentStart; end = $segmentEnd; duration = [Math]::Max(0.0, ($segmentEnd - $segmentStart).TotalSeconds) }
    } | Sort-Object start)
    $phaseSeconds = [Math]::Round([double](($segments | Measure-Object duration -Sum).Sum), 3)
    $gaps = @()
    if ($lifecycleStartValue -and $segments.Count -gt 0) {
        $cursor = $lifecycleStartValue
        $previousName = 'developer.lifecycle_start'
        foreach ($segment in $segments) {
            if ($segment.start -gt $cursor) {
                $gaps += [pscustomobject][ordered]@{ name = 'developer.agent_inter_phase_wait'; after = $previousName; before = $segment.name; started_at = $cursor.ToString('o'); ended_at = $segment.start.ToString('o'); duration_seconds = [Math]::Round(($segment.start - $cursor).TotalSeconds, 3); status = 'OBSERVED_GAP'; classification = 'Agent/host reasoning or tool-dispatch interval; internal split is not observable.' }
            }
            if ($segment.end -gt $cursor) { $cursor = $segment.end; $previousName = $segment.name }
        }
        if ($lifecycleEndValue -and $lifecycleEndValue -gt $cursor) {
            $gaps += [pscustomobject][ordered]@{ name = 'developer.agent_inter_phase_wait'; after = $previousName; before = 'developer.complete'; started_at = $cursor.ToString('o'); ended_at = $lifecycleEndValue.ToString('o'); duration_seconds = [Math]::Round(($lifecycleEndValue - $cursor).TotalSeconds, 3); status = 'OBSERVED_GAP'; classification = 'Agent/host reasoning or tool-dispatch interval; internal split is not observable.' }
        }
    }
    $gapSeconds = [Math]::Round([double](($gaps | Measure-Object duration_seconds -Sum).Sum), 3)
    $attributed = [Math]::Min([Math]::Round(($phaseSeconds + $gapSeconds), 3), [Math]::Round($lifecycleSeconds, 3))
    $lifecycleSeconds = [Math]::Round($lifecycleSeconds, 3)
    $phaseCoverage = if ($lifecycleSeconds -gt 0) { [Math]::Round([Math]::Min(100, ($phaseSeconds / $lifecycleSeconds) * 100), 1) } else { 0 }
    $coverage = if ($lifecycleSeconds -gt 0) { [Math]::Round([Math]::Min(100, ($attributed / $lifecycleSeconds) * 100), 1) } else { 0 }
    return [ordered]@{
        phases = $records
        developer = [ordered]@{
            lifecycle_started_at = $lifecycleStart
            lifecycle_ended_at = $lifecycleEnd
            lifecycle_seconds = $lifecycleSeconds
            instrumented_phase_seconds = $phaseSeconds
            instrumented_phase_coverage_percent = $phaseCoverage
            observable_gap_seconds = $gapSeconds
            observable_gaps = $gaps
            attributed_seconds = $attributed
            unattributed_seconds = [Math]::Max(0.0, [Math]::Round(($lifecycleSeconds - $attributed), 3))
            coverage_percent = $coverage
            not_instrumentable = @($developerRecords | Where-Object status -eq 'NOT_INSTRUMENTABLE' | ForEach-Object name)
        }
    }
}

function Get-StateStorageReport {
    param($State, [switch]$Detailed)
    $warningThresholdBytes = 5MB
    $stateBytes = if (Test-Path $StatePath -PathType Leaf) { [int64](Get-Item -LiteralPath $StatePath).Length } else { 0 }
    $inlineOutputBytes = 0L
    foreach ($command in @($State.commands)) { if ($command.output) { $inlineOutputBytes += [System.Text.Encoding]::UTF8.GetByteCount([string]$command.output) } }
    $result = [ordered]@{
        serialized_state_bytes = $stateBytes
        warning_threshold_bytes = [int64]$warningThresholdBytes
        abnormal_size_warning = $stateBytes -gt $warningThresholdBytes
        command_count = if($State.command_summary){[int]$State.command_summary.total}else{@($State.commands).Count}
        inline_command_output_bytes = $inlineOutputBytes
        largest_state_sections = @()
        largest_evidence_artifacts = @()
    }
    if ($Detailed) {
        $sectionSizes = @()
        foreach ($name in @('execution','stages','phases','developer_completion','commands','command_summary','validation','telemetry')) {
            $value = $State.$name
            $sectionJson = if ($null -eq $value) { 'null' } else { [string](ConvertTo-Json -InputObject $value -Depth 15 -Compress) }
            $bytes = [System.Text.Encoding]::UTF8.GetByteCount($sectionJson)
            $sectionSizes += [pscustomobject]@{ name = $name; bytes = $bytes }
        }
        $result.largest_state_sections = @($sectionSizes | Sort-Object bytes -Descending)
        $evidenceDirectory = Split-Path $StatePath -Parent
        if (Test-Path $evidenceDirectory -PathType Container) {
            $result.largest_evidence_artifacts = @(Get-ChildItem -LiteralPath $evidenceDirectory -Recurse -File -Force -ErrorAction SilentlyContinue |
                Sort-Object Length -Descending | Select-Object -First 10 | ForEach-Object {
                    [ordered]@{ path = $_.FullName.Substring($evidenceDirectory.Length).TrimStart('\','/') -replace '\\','/'; bytes = [int64]$_.Length }
                })
        }
    }
    return $result
}

function Emit-State {
    param($State, [DateTime]$At = (Get-Now), [switch]$DetailedStorage)
    Update-Clock $State $At | Out-Null
    $phaseReport = Get-PhaseReport $State $At
    $result = [ordered]@{ execution = $State.execution; stages = $State.stages; phases = @($State.phases); phase_report = $phaseReport.developer; repair_loops = $State.repair_loops; max_repair_loops = $State.max_repair_loops; commands = @($State.commands); command_summary=$State.command_summary; validation = $State.validation; telemetry = $State.telemetry; report = Get-StageReport $State $At; storage = Get-StateStorageReport $State -Detailed:$DetailedStorage; state_path = $StatePath }
    $result.execution_id=$State.execution_id
    $result.environment_setup=$State.environment_setup
    if ($Json) { $result | ConvertTo-Json -Depth 15 } else {
        Write-Host "EXECUTION_STATE_PATH=$StatePath"
        Write-Host "TASK_TYPE=$($State.execution.task_type)"
        Write-Host "CURRENT_STAGE=$($State.execution.current_stage)"
        Write-Host "TOTAL_WALL_SECONDS=$($State.execution.total_wall_seconds)"
        Write-Host "ACTIVE_EXECUTION_SECONDS=$($State.execution.active_execution_seconds)"
        Write-Host "USER_WAIT_SECONDS=$($State.execution.user_wait_seconds)"
        Write-Host "EXTERNAL_INTERRUPTION_SECONDS=$($State.execution.external_interruption_seconds)"
        Write-Host "REPAIR_LOOPS=$($State.repair_loops)"
        Write-Host "DEVELOPER_TIMING_COVERAGE_PERCENT=$($result.phase_report.coverage_percent)"
        Write-Host "EXECUTION_STATE_BYTES=$($result.storage.serialized_state_bytes)"
        if ($result.storage.abnormal_size_warning) { Write-Warning "Execution state exceeds $($result.storage.warning_threshold_bytes) bytes. Review largest state/evidence sections before handoff." }
        if ($result.report.bottleneck) { Write-Host "BOTTLENECK=$($result.report.bottleneck.stage)" }
    }
}

function New-State {
    param([string]$Type, [DateTime]$At)
    $stages = [ordered]@{}
    foreach ($name in $stageNames) { $stages[$name] = Get-StageObject }
    return [ordered]@{
        schema_version = 3
        execution_id = ([guid]::NewGuid()).ToString('N')
        started_at = $At.ToString('o')
        updated_at = $At.ToString('o')
        repair_loops = 0
        max_repair_loops = 3
        environment_setup = [ordered]@{started_at=$null;ended_at=$null;status='NOT_STARTED';active_seconds=0;reason=$null}
        phases = @()
        commands = @()
        command_summary = [ordered]@{ total=0; pass=0; fail=0; timeout=0; last=$null }
        execution = [ordered]@{
            task_type = $Type
            started_at = $At.ToString('o')
            ended_at = $null
            status = 'RUNNING'
            current_stage = 'coordinator'
            resumed_from_execution_id = $null
            total_wall_seconds = 0
            active_execution_seconds = 0
            environment_setup_seconds = 0
            implementation_seconds = 0
            user_wait_seconds = 0
            user_wait_intervals = @()
            external_interruption_seconds = 0
            external_interruption_intervals = @()
            paused_at = $null
            paused_reason = $null
            paused_stage = $null
            interrupted_stage = $null
            resume_after_validation = $null
            elapsed_seconds = 0
        }
        stages = $stages
        validation = [ordered]@{ validationRequired = $true; validationCompleted = $false; diagnosticsExecuted = $false; buildExecuted = $false; buildSucceeded = $false; deliveryReady = $false; blockedReason = $null }
        telemetry = [ordered]@{ ledgerPath = '.ai/evidence/developer-events.jsonl'; ledgerSha256 = $null; ledgerBytes = 0; summaryPath = $null; attributionCoveragePct = 0; majorTimingTotals = $null }
    }
}

switch ($Action) {
    'Start' {
        if (-not $TaskType) { throw 'TaskType is required for Start.' }
        $at = Get-Now
        if (Test-Path $StatePath -PathType Leaf) {
            $existing = [System.IO.File]::ReadAllText($StatePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($existing.execution -and [string]$existing.execution.status -in @('RUNNING','PAUSED')) {
                if (-not $Resume) { throw "An active execution already exists: $($existing.execution_id). Use -Resume to continue it." }
                if ($existing.schema_version -notin @(2,3)) { throw "Active execution uses unsupported schema $($existing.schema_version); do not overwrite it. Resume it with the matching DevKit version or archive it explicitly." }
                $existing=Read-State
                Emit-State $existing $at
                break
            }
            $historyDirectory = Join-Path (Split-Path $StatePath -Parent) 'execution-history'
            New-Item -ItemType Directory -Force -Path $historyDirectory | Out-Null
            $historyName = if ($existing.execution_id) { [string]$existing.execution_id } else { [guid]::NewGuid().ToString('N') }
            Copy-Item $StatePath (Join-Path $historyDirectory "$historyName.json") -Force
        }
        $state = New-State $TaskType $at
        $state.stages.coordinator.started_at = $at.ToString('o')
        $state.stages.coordinator.active_started_at = $at.ToString('o')
        $state.stages.coordinator.status = 'RUNNING'
        Write-State $state $at
        Emit-State $state $at
    }
    'Status' { $state = Read-State; Emit-State $state (Get-Now) }
    'Read' { $state = Read-State; Emit-State $state (Get-Now) }
    'EnvironmentStart' {
        $state=Read-State;$at=Get-Now
        if($state.execution.status -ne 'RUNNING'){throw "Execution is not running: $($state.execution.status)."}
        if($state.environment_setup.started_at){Emit-State $state $at;break}
        $state.environment_setup.started_at=$at.ToString('o');$state.environment_setup.status='RUNNING';$state.environment_setup.reason=$Reason
        Write-State $state $at;Emit-State $state $at
    }
    'EnvironmentEnd' {
        $state=Read-State;$at=Get-Now
        if(-not $state.environment_setup.started_at -or $state.environment_setup.ended_at){throw 'No active environment setup interval.'}
        Update-Clock $state $at | Out-Null
        $state.environment_setup.ended_at=$at.ToString('o')
        $state.environment_setup.status=$PhaseStatus
        Write-State $state $at;Emit-State $state $at
    }
    'StageStart' {
        if (-not $Stage) { throw 'Stage is required for StageStart.' }
        $state = Read-State; $at = Get-Now
        if ([string]$state.execution.status -ne 'RUNNING') { throw "Execution is not running: $($state.execution.status)." }
        $stageObject = $state.stages.$Stage
        if (-not $stageObject) { throw "Unknown execution stage: $Stage" }
        if ($Stage -eq 'validation' -and (Get-ActiveStage $state) -eq 'developer') {
            $state.execution.resume_after_validation = 'developer'
            Close-ActiveStage $state $at 'PAUSED_BY_VALIDATION' | Out-Null
        } elseif (Get-ActiveStage $state) { throw "Exclusive stage overlap: $(Get-ActiveStage $state) is active." }
        if (-not $stageObject.started_at) { $stageObject.started_at = $at.ToString('o') }
        $stageObject.active_started_at = $at.ToString('o')
        $stageObject.status = 'RUNNING'
        $state.execution.current_stage = $Stage
        Write-State $state $at; Emit-State $state $at
    }
    'StageEnd' {
        if (-not $Stage) { throw 'Stage is required for StageEnd.' }
        $state = Read-State; $at = Get-Now; $stageObject = $state.stages.$Stage
        if (-not $stageObject -or -not $stageObject.active_started_at) { throw "Stage '$Stage' has no active interval." }
        Add-Interval $stageObject $at 'COMPLETE'; $stageObject.status = 'COMPLETE'
        if ($Stage -eq 'validation' -and $state.execution.resume_after_validation) {
            $resumeStage = [string]$state.execution.resume_after_validation
            $state.execution.resume_after_validation = $null
            $state.stages.$resumeStage.active_started_at = $at.ToString('o')
            $state.stages.$resumeStage.status = 'RUNNING'
            $state.execution.current_stage = $resumeStage
        } else { $state.execution.current_stage = $Stage }
        Write-State $state $at; Emit-State $state $at
    }
    'StagePause' {
        if (-not $Stage) { throw 'Stage is required for StagePause.' }
        $state = Read-State; $at = Get-Now; $stageObject = $state.stages.$Stage
        if (-not $stageObject -or -not $stageObject.active_started_at) { throw "Stage '$Stage' has no active interval." }
        $pauseStatus = if ($Reason) { $Reason } else { 'PAUSED' }
        Add-Interval $stageObject $at $pauseStatus; $stageObject.status = 'PAUSED'
        Write-State $state $at; Emit-State $state $at
    }
    'StageResume' {
        if (-not $Stage) { throw 'Stage is required for StageResume.' }
        $state = Read-State; $at = Get-Now
        if (Get-ActiveStage $state) { throw "Exclusive stage overlap: $(Get-ActiveStage $state) is active." }
        $stageObject = $state.stages.$Stage; if (-not $stageObject) { throw "Unknown execution stage: $Stage" }
        $stageObject.active_started_at = $at.ToString('o'); $stageObject.status = 'RUNNING'; $state.execution.current_stage = $Stage
        Write-State $state $at; Emit-State $state $at
    }
    'PhaseStart' {
        if (-not $PhaseName) { throw 'PhaseName is required for PhaseStart.' }
        $state = Read-State; $at = Get-Now
        if ([string]$state.execution.status -ne 'RUNNING') { throw "Execution is not running: $($state.execution.status)." }
        $phaseStage = if ($Stage) { $Stage } else { [string]$state.execution.current_stage }
        $running = @($state.phases | Where-Object { [string]$_.stage -eq $phaseStage -and [string]$_.status -eq 'RUNNING' })
        if ($running.Count -gt 0) { throw "Instrumentation phase '$($running[0].name)' is already running for stage '$phaseStage'." }
        $record = [ordered]@{ id = ([guid]::NewGuid()).ToString('N'); name = $PhaseName; stage = $phaseStage; started_at = $at.ToString('o'); ended_at = $null; duration_seconds = $null; status = 'RUNNING'; reason = $Reason }
        $state.phases = @($state.phases) + $record
        Write-State $state $at
        $result = [ordered]@{ phase = $record; phase_report = (Get-PhaseReport $state $at).developer }
        if ($Json) { $result | ConvertTo-Json -Depth 10 } else { Write-Host "PHASE_ID=$($record.id)"; Write-Host "PHASE_STATUS=RUNNING" }
    }
    'PhaseEnd' {
        if (-not $PhaseName -and -not $PhaseId) { throw 'PhaseName or PhaseId is required for PhaseEnd.' }
        $state = Read-State; $at = Get-Now
        $record = @($state.phases | Where-Object { [string]$_.status -eq 'RUNNING' -and (($PhaseId -and [string]$_.id -eq $PhaseId) -or (-not $PhaseId -and [string]$_.name -eq $PhaseName)) } | Select-Object -Last 1)
        if ($record.Count -ne 1) { throw "Running instrumentation phase was not found: $PhaseName$PhaseId" }
        $started = [DateTime]::Parse([string]$record[0].started_at, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        $record[0].ended_at = $at.ToString('o'); $record[0].duration_seconds = [Math]::Round([Math]::Max(0.0, ($at - $started).TotalSeconds), 3); $record[0].status = $PhaseStatus; if ($Reason) { $record[0].reason = $Reason }
        Write-State $state $at
        $result = [ordered]@{ phase = $record[0]; phase_report = (Get-PhaseReport $state $at).developer }
        if ($Json) { $result | ConvertTo-Json -Depth 10 } else { Write-Host "PHASE_ID=$($record[0].id)"; Write-Host "PHASE_STATUS=$PhaseStatus"; Write-Host "PHASE_DURATION_SECONDS=$($record[0].duration_seconds)" }
    }
    'PhaseUnavailable' {
        if (-not $PhaseName) { throw 'PhaseName is required for PhaseUnavailable.' }
        if (-not $Reason) { throw 'Reason is required for PhaseUnavailable.' }
        $state = Read-State; $at = Get-Now
        $phaseStage = if ($Stage) { $Stage } else { [string]$state.execution.current_stage }
        $record = [ordered]@{ id = ([guid]::NewGuid()).ToString('N'); name = $PhaseName; stage = $phaseStage; started_at = $null; ended_at = $null; duration_seconds = $null; status = 'NOT_INSTRUMENTABLE'; reason = $Reason; recorded_at = $at.ToString('o') }
        $state.phases = @($state.phases) + $record
        Write-State $state $at
        if ($Json) { [ordered]@{ phase = $record; phase_report = (Get-PhaseReport $state $at).developer } | ConvertTo-Json -Depth 10 } else { Write-Host "PHASE_STATUS=NOT_INSTRUMENTABLE" }
    }
    'DeveloperFinalize' {
        if (-not $DeveloperCompletionJson) { throw 'DeveloperCompletionJson is required for DeveloperFinalize.' }
        if ([System.Text.Encoding]::UTF8.GetByteCount($DeveloperCompletionJson) -gt 65536) { throw 'DeveloperCompletionJson exceeds the 64 KiB compact-state limit.' }
        try { $completionInput = $DeveloperCompletionJson | ConvertFrom-Json } catch { throw "DeveloperCompletionJson is invalid JSON: $($_.Exception.Message)" }
        foreach ($required in @('taskId','status','riskClass','auditMode','evidencePath','handoffPath','sourceFingerprint')) {
            if (-not [string]$completionInput.$required) { throw "DeveloperCompletionJson is missing '$required'." }
        }
        $state = Read-State; $at = Get-Now
        if ([string]$state.execution.status -ne 'RUNNING') { throw "Execution is not running: $($state.execution.status)." }
        if ((Get-ActiveStage $state) -ne 'developer') { throw "DeveloperFinalize requires the developer stage to be active; active stage is '$(Get-ActiveStage $state)'." }
        $runningPhases = @($state.phases | Where-Object { [string]$_.stage -eq 'developer' -and [string]$_.status -eq 'RUNNING' })
        if ($runningPhases.Count -gt 0) { throw "DeveloperFinalize cannot commit while phase '$($runningPhases[0].name)' is still running." }

        $allowedFinalPhases = @('developer.deterministic_finalization','developer.handoff','developer.completion')
        foreach ($phase in @($completionInput.phases)) {
            $phaseName = [string]$phase.name
            if ($phaseName -notin $allowedFinalPhases) { throw "Unsupported Developer finalization phase: $phaseName" }
            $phaseStarted = [DateTime]::Parse([string]$phase.startedAtUtc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
            $phaseEnded = [DateTime]::Parse([string]$phase.endedAtUtc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
            if ($phaseEnded -lt $phaseStarted -or $phaseEnded -gt $at.AddSeconds(1)) { throw "Invalid timing interval for $phaseName." }
            $state.phases = @($state.phases) + [ordered]@{
                id = ([guid]::NewGuid()).ToString('N')
                name = $phaseName
                stage = 'developer'
                started_at = $phaseStarted.ToString('o')
                ended_at = $phaseEnded.ToString('o')
                duration_seconds = [Math]::Round(($phaseEnded - $phaseStarted).TotalSeconds, 3)
                status = if ([string]$phase.status -in @('PASS','FAIL','BLOCKED','SKIPPED')) { [string]$phase.status } else { 'PASS' }
                reason = [string]$phase.reason
            }
        }
        if (-not @($state.phases | Where-Object { [string]$_.name -eq 'developer.semantic_result_summary' }).Count) {
            $state.phases = @($state.phases) + [ordered]@{
                id = ([guid]::NewGuid()).ToString('N')
                name = 'developer.semantic_result_summary'
                stage = 'developer'
                started_at = $null
                ended_at = $null
                duration_seconds = $null
                status = 'NOT_INSTRUMENTABLE'
                reason = 'Semantic summary was supplied before the finalization invocation; the agent host does not expose its exact boundary.'
                recorded_at = $at.ToString('o')
            }
        }
        if (-not @($state.phases | Where-Object { [string]$_.name -eq 'developer.final_tool_to_complete' }).Count) {
            $state.phases = @($state.phases) + [ordered]@{
                id = ([guid]::NewGuid()).ToString('N')
                name = 'developer.final_tool_to_complete'
                stage = 'developer'
                started_at = $null
                ended_at = $null
                duration_seconds = $null
                status = 'NOT_INSTRUMENTABLE'
                reason = 'Repository code cannot observe response emission after this final tool invocation.'
                recorded_at = $at.ToString('o')
            }
        }
        if ([string]$completionInput.status -eq 'PASS' -and (-not [bool]$state.validation.validationCompleted -or -not [bool]$state.validation.deliveryReady)) {
            $completionInput.status = 'BLOCKED'
            if (-not $state.validation.blockedReason) { $state.validation.blockedReason = 'REQUIRED_VALIDATION_INCOMPLETE' }
        }
        $state.phases = @($state.phases) + [ordered]@{
            id = ([guid]::NewGuid()).ToString('N')
            name = 'developer.state_write'
            stage = 'developer'
            started_at = $at.ToString('o')
            ended_at = $at.ToString('o')
            duration_seconds = 0
            status = 'PASS'
            reason = 'Atomic state-write duration is emitted by DeveloperFinalize and the finalization result; it is not self-rewritten into this state file.'
        }
        $developerCompletion = [ordered]@{
            schemaVersion = 1
            taskId = [string]$completionInput.taskId
            status = [string]$completionInput.status
            riskClass = [string]$completionInput.riskClass
            auditMode = [string]$completionInput.auditMode
            evidencePath = [string]$completionInput.evidencePath
            handoffPath = [string]$completionInput.handoffPath
            validationResultPath = [string]$completionInput.validationResultPath
            contextPackagePath = [string]$completionInput.contextPackagePath
            sourceFingerprint = [string]$completionInput.sourceFingerprint
            changedFileCount = [int]$completionInput.changedFileCount
            uncertainty = [bool]$completionInput.uncertainty
            validationCompleted = [bool]$state.validation.validationCompleted
            buildExecuted = [bool]$state.validation.buildExecuted
            buildSucceeded = [bool]$state.validation.buildSucceeded
            deliveryReady = [bool]$state.validation.deliveryReady
            blockedReason = [string]$state.validation.blockedReason
            telemetryLedgerPath = [string]$state.telemetry.ledgerPath
            committedAtUtc = $at.ToString('o')
        }
        if ($state.PSObject.Properties.Name -contains 'developer_completion') { $state.developer_completion = $developerCompletion }
        else { $state | Add-Member -NotePropertyName developer_completion -NotePropertyValue $developerCompletion }
        $developerStage = $state.stages.developer
        $developerIntervalStatus = if ([string]$completionInput.status -eq 'PASS') { 'COMPLETE' } else { [string]$completionInput.status }
        Add-Interval $developerStage $at $developerIntervalStatus
        $developerStage.status = if ([string]$completionInput.status -eq 'PASS') { 'COMPLETE' } else { [string]$completionInput.status }
        $state.execution.current_stage = 'developer'
        $stateWriteStarted = [DateTime]::UtcNow
        Write-State $state $at
        $stateWriteSeconds = [Math]::Round(([DateTime]::UtcNow - $stateWriteStarted).TotalSeconds, 6)
        $result = [ordered]@{
            status = [string]$completionInput.status
            state_path = $StatePath
            state_write_seconds = $stateWriteSeconds
            state_write_count = 1
            developer_stage_status = [string]$developerStage.status
            committed_at_utc = $at.ToString('o')
        }
        if ($Json) { $result | ConvertTo-Json -Depth 8 } else { Write-Host "DEVELOPER_FINALIZE_STATUS=$($result.status)"; Write-Host "STATE_WRITE_SECONDS=$stateWriteSeconds" }
    }
    'Pause' {
        $state = Read-State; $at = Get-Now
        if ([string]$state.execution.status -ne 'RUNNING') { throw "Execution is not running: $($state.execution.status)." }
        $state.execution.paused_stage = Close-ActiveStage $state $at 'PAUSED_FOR_USER_WAIT'
        $state.execution.paused_at = $at.ToString('o'); $state.execution.paused_reason = $Reason; $state.execution.status = 'PAUSED'
        $state.execution.user_wait_intervals = @($state.execution.user_wait_intervals) + [ordered]@{ started_at = $at.ToString('o'); ended_at = $null; reason = $Reason }
        Write-State $state $at; Emit-State $state $at
    }
    'Resume' {
        $state = Read-State; $at = Get-Now
        if ([string]$state.execution.status -ne 'PAUSED') { throw "Execution is not paused: $($state.execution.status)." }
        $wait = @($state.execution.user_wait_intervals) | Select-Object -Last 1
        if ($wait -and -not $wait.ended_at) { $wait.ended_at = $at.ToString('o') }
        $resumeStage = [string]$state.execution.paused_stage
        $state.execution.status = 'RUNNING'; $state.execution.paused_at = $null; $state.execution.paused_reason = $null; $state.execution.paused_stage = $null
        if ($resumeStage) { $state.stages.$resumeStage.active_started_at = $at.ToString('o'); $state.stages.$resumeStage.status = 'RUNNING'; $state.execution.current_stage = $resumeStage }
        Write-State $state $at; Emit-State $state $at
    }
    'InterruptionStart' {
        $state = Read-State; $at = Get-Now
        if ([string]$state.execution.status -ne 'RUNNING') { throw "External interruption cannot start while execution is $($state.execution.status)." }
        $open = @($state.execution.external_interruption_intervals | Where-Object { -not $_.ended_at })
        if ($open.Count -gt 0) { throw 'An external interruption is already active.' }
        $state.execution.interrupted_stage = Close-ActiveStage $state $at 'PAUSED_FOR_EXTERNAL_INTERRUPTION'
        $state.execution.external_interruption_intervals = @($state.execution.external_interruption_intervals) + [ordered]@{ started_at=$at.ToString('o'); ended_at=$null; reason=$Reason }
        Write-State $state $at; Emit-State $state $at
    }
    'InterruptionEnd' {
        $state = Read-State; $at = Get-Now
        if ([string]$state.execution.status -ne 'RUNNING') { throw "External interruption cannot end while execution is $($state.execution.status)." }
        $interval = @($state.execution.external_interruption_intervals | Where-Object { -not $_.ended_at } | Select-Object -Last 1)
        if ($interval.Count -ne 1) { throw 'No external interruption is active.' }
        $interval[0].ended_at = $at.ToString('o')
        $resumeStage = [string]$state.execution.interrupted_stage
        $state.execution.interrupted_stage = $null
        if ($resumeStage) { $state.stages.$resumeStage.active_started_at=$at.ToString('o'); $state.stages.$resumeStage.status='RUNNING'; $state.execution.current_stage=$resumeStage }
        Write-State $state $at; Emit-State $state $at
    }
    'CommandStart' {
        $state = Read-State; $at = Get-Now
        $id = ([guid]::NewGuid()).ToString('N')
        $outputPath = if ($CommandOutputPath) { $CommandOutputPath } else { Join-Path $TargetBotPath ".ai\evidence\commands\$id.log" }
        $state.commands = @($state.commands) + [ordered]@{ id = $id; operation = $Operation; category=$Category; subcategory=$Subcategory; started_at = $at.ToString('o'); ended_at = $null; duration_seconds = $null; pid=$null; exit_code = $null; timed_out = $false; status = 'RUNNING'; output_bytes = 0; output_sha256 = $null; output_path = $outputPath }
        Write-State $state $at
        if ($Json) { [ordered]@{ command_id = $id; execution = $state.execution } | ConvertTo-Json -Depth 10 } else { Write-Host "COMMAND_ID=$id" }
    }
    'CommandEnd' {
        $state = Read-State; $at = Get-Now; $record = $state.commands | Where-Object id -eq $CommandId | Select-Object -First 1
        if (-not $record) { throw "Command evidence not found: $CommandId" }
        $outputBytes = [System.Text.Encoding]::UTF8.GetBytes([string]$CommandOutput)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $outputHash = ([System.BitConverter]::ToString($sha.ComputeHash($outputBytes)) -replace '-','').ToLowerInvariant() } finally { $sha.Dispose() }
        $record.ended_at = $at.ToString('o'); $record.duration_seconds = $DurationSeconds; $record.pid = if($ProcessId -gt 0){$ProcessId}else{$null}; $record.exit_code = $ExitCode; $record.timed_out = [bool]$TimedOut; $record.status = if ($TimedOut) { 'TIMEOUT' } elseif ($ExitCode -eq 0) { 'PASS' } else { 'FAIL' }; $record.output_bytes = $outputBytes.Length; $record.output_sha256 = $outputHash; if ($CommandOutputPath) { $record.output_path = $CommandOutputPath }
        $state.command_summary.total=[int]$state.command_summary.total+1
        if($record.status -eq 'PASS'){$state.command_summary.pass=[int]$state.command_summary.pass+1}elseif($record.status -eq 'TIMEOUT'){$state.command_summary.timeout=[int]$state.command_summary.timeout+1}else{$state.command_summary.fail=[int]$state.command_summary.fail+1}
        $state.command_summary.last=[ordered]@{id=$record.id;operation=$record.operation;status=$record.status;ended_at=$record.ended_at;duration_seconds=$record.duration_seconds;output_bytes=$record.output_bytes;output_sha256=$record.output_sha256;output_path=$record.output_path}
        $state.commands=@($state.commands|Where-Object id -ne $CommandId)
        Write-State $state $at; if ($Json) { [ordered]@{ command_id = $CommandId; status = $record.status; command=$record; execution = $state.execution } | ConvertTo-Json -Depth 10 } else { Write-Host "COMMAND_STATUS=$($record.status)" }
    }
    'RepairStart' {
        $state = Read-State; $at = Get-Now
        if ([string]$state.execution.status -ne 'RUNNING') { throw "Execution is not running: $($state.execution.status)." }
        if ([int]$state.repair_loops -ge [int]$state.max_repair_loops) { Emit-State $state $at; throw "REPAIR_LOOP_LIMIT_REACHED: maximum repair loops ($($state.max_repair_loops)) already used." }
        $state.repair_loops = [int]$state.repair_loops + 1; Write-State $state $at; Emit-State $state $at
    }
    'ValidationState' {
        if (-not $ValidationStateJson) { throw 'ValidationStateJson is required for ValidationState.' }
        try { $input = $ValidationStateJson | ConvertFrom-Json } catch { throw "ValidationStateJson is invalid JSON: $($_.Exception.Message)" }
        $state = Read-State; $at = Get-Now
        foreach ($required in @('validationRequired','validationCompleted','buildExecuted','buildSucceeded','deliveryReady')) {
            if ($input.PSObject.Properties.Name -notcontains $required) { throw "ValidationStateJson is missing '$required'." }
        }
        if ([bool]$input.deliveryReady -and (-not [bool]$input.validationCompleted -or -not [bool]$input.buildExecuted -or -not [bool]$input.buildSucceeded)) { throw 'deliveryReady cannot be true until required validation and build succeed.' }
        $state.validation = [ordered]@{
            validationRequired=[bool]$input.validationRequired
            validationCompleted=[bool]$input.validationCompleted
            diagnosticsExecuted=[bool]$input.diagnosticsExecuted
            buildExecuted=[bool]$input.buildExecuted
            buildSucceeded=[bool]$input.buildSucceeded
            deliveryReady=[bool]$input.deliveryReady
            blockedReason=if($input.blockedReason){[string]$input.blockedReason}else{$null}
            validationResultPath=if($input.validationResultPath){[string]$input.validationResultPath}else{$null}
            updatedAtUtc=$at.ToString('o')
        }
        Write-State $state $at; Emit-State $state $at
    }
    'TelemetryUpdate' {
        if (-not $TelemetryJson) { throw 'TelemetryJson is required for TelemetryUpdate.' }
        try { $input = $TelemetryJson | ConvertFrom-Json } catch { throw "TelemetryJson is invalid JSON: $($_.Exception.Message)" }
        if ([Text.Encoding]::UTF8.GetByteCount($TelemetryJson) -gt 32768) { throw 'TelemetryJson exceeds the 32 KiB compact-state limit.' }
        $state = Read-State; $at = Get-Now
        $state.telemetry = [ordered]@{
            ledgerPath=[string]$input.ledgerPath
            ledgerSha256=[string]$input.ledgerSha256
            ledgerBytes=[int64]$input.ledgerBytes
            summaryPath=[string]$input.summaryPath
            attributionCoveragePct=[double]$input.attributionCoveragePct
            majorTimingTotals=$input.majorTimingTotals
            updatedAtUtc=$at.ToString('o')
        }
        Write-State $state $at; Emit-State $state $at
    }
    'Complete' {
        $state = Read-State; $at = Get-Now
        if($state.environment_setup.started_at -and -not $state.environment_setup.ended_at){throw 'Execution cannot complete during environment setup.'}
        if($Outcome -eq 'PASS' -and $state.environment_setup.status -in @('BLOCKED','FAIL')){throw 'Execution cannot complete as PASS after failed environment setup.'}
        if ([string]$state.execution.status -ne 'RUNNING') { throw "Execution is not running: $($state.execution.status)." }
        if ($Outcome -eq 'PASS' -and [bool]$state.validation.validationRequired -and -not [bool]$state.validation.deliveryReady) { throw "Execution cannot complete as PASS before required validation/build succeeds: $($state.validation.blockedReason)" }
        if ([string]$state.execution.current_stage -ne 'finalization' -or [string]$state.stages.finalization.status -ne 'COMPLETE') { throw 'Execution cannot complete before the finalization stage is complete.' }
        if (Get-ActiveStage $state) { throw "Execution cannot complete while stage '$(Get-ActiveStage $state)' is active." }
        if ($RequireAudit -and [string]$state.stages.auditor.status -ne 'COMPLETE') { throw 'Execution cannot complete while an independent audit is required but the auditor stage is incomplete.' }
        $state.execution.ended_at = $at.ToString('o'); $state.execution.status = $Outcome; Write-State $state $at; Emit-State $state $at
    }
    'Report' { $state = Read-State; Emit-State $state (Get-Now) -DetailedStorage }
}
