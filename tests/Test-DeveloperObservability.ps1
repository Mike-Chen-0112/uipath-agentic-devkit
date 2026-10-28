[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path;$testRoot=Join-Path $env:TEMP ('rpa-ai-observability-'+[guid]::NewGuid().ToString('N'))
function Assert-True{param([bool]$Condition,[string]$Message)if(-not $Condition){throw $Message}}
function Write-Utf8{param([string]$Path,[string]$Value)New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent)|Out-Null;[IO.File]::WriteAllText($Path,$Value,(New-Object Text.UTF8Encoding($false)))}
try{
    New-Item -ItemType Directory -Force -Path $testRoot|Out-Null
    $stateScript=Join-Path $root 'scripts\ExecutionState.ps1';$eventScript=Join-Path $root 'scripts\Write-DeveloperEvent.ps1';$breakdownScript=Join-Path $root 'scripts\Get-DeveloperRuntimeBreakdown.ps1';$checkScript=Join-Path $root 'scripts\Test-ExecutionTimingConsistency.ps1';$module=Join-Path $root 'scripts\DeveloperTelemetry.psm1'
    & $stateScript -Action Start -TaskType modification -TargetBotPath $testRoot -NowUtc '2026-09-11T10:00:00Z' -Json|Out-Null
    & $stateScript -Action StageEnd -Stage coordinator -TargetBotPath $testRoot -NowUtc '2026-09-11T10:00:01Z' -Json|Out-Null
    & $stateScript -Action StageStart -Stage developer -TargetBotPath $testRoot -NowUtc '2026-09-11T10:00:01Z' -Json|Out-Null
    $parent=& $eventScript -Action Start -ProjectPath $testRoot -Category VALIDATION -Subcategory wrapper -Operation validation.wrapper -NowUtc '2026-09-11T10:00:01Z' -Json|ConvertFrom-Json
    $child=& $eventScript -Action Start -ProjectPath $testRoot -Category UIA -Subcategory snapshot -Operation uia.snapshot -ParentEventId $parent.eventId -CommandType SUBPROCESS -ProcessId 4242 -NowUtc '2026-09-11T10:00:02Z' -Json|ConvertFrom-Json
    & $eventScript -Action End -ProjectPath $testRoot -EventId $child.eventId -Status PASS -ProcessId 4242 -ExitCode 0 -NowUtc '2026-09-11T10:00:03Z' -Json|Out-Null
    & $eventScript -Action End -ProjectPath $testRoot -EventId $parent.eventId -Status PASS -NowUtc '2026-09-11T10:00:04Z' -Json|Out-Null
    $operations=@(
        @('UIA','navigate','uia.navigate'),@('UI_TARGET','capture','ui.target.capture'),@('UI_TARGET','generate','ui.target.generate'),
        @('UI_TARGET','live_validation','ui.target.live_validation'),@('UI_TARGET','resolve','ui.target.resolve'),@('UI_TARGET','persist','ui.target.persist'),
        @('UI_TARGET','reuse','ui.target.reuse'),@('OBJECT_REPOSITORY','lookup','object_repository.lookup'),@('OBJECT_REPOSITORY','workflow_link','object_repository.link'),
        @('UIA','native','ui.native.interaction'),@('SOURCE_READ','xaml','source.read'),@('SOURCE_EDIT','create','source.create'),
        @('SOURCE_EDIT','patch','source.patch'),@('SOURCE_EDIT','write','source.write'),@('SOURCE_EDIT','replace','source.replace'),
        @('SOURCE_EDIT','validate','source.validate'),@('SOURCE_READ','reopen','source.reopen'),@('SOURCE_REPAIR','diagnostics','source.repair'),
        @('PACKAGE','search','package.search'),@('PACKAGE','compatibility','package.compatibility_decision'),@('PACKAGE','install','package.install'),
        @('PACKAGE','dependency_update','package.dependency_update'),@('PACKAGE','restore','package.restore'),@('PACKAGE','reuse','package.reuse'),
        @('MAPPER','warm','mapper.update'),@('GRAPHIFY','reuse','graphify.reuse'),@('EVIDENCE','serialize','evidence.serialize'),@('STATE','atomic_replace','state.write')
    )
    $cursor=[DateTime]'2026-09-11T10:00:04Z'
    foreach($op in $operations){$next=$cursor.AddMilliseconds(250);$event=& $eventScript -Action Start -ProjectPath $testRoot -Category $op[0] -Subcategory $op[1] -Operation $op[2] -NowUtc $cursor.ToString('o') -Json|ConvertFrom-Json;& $eventScript -Action End -ProjectPath $testRoot -EventId $event.eventId -Status PASS -NowUtc $next.ToString('o') -Json|Out-Null;$cursor=$next}
    $bridgeEnd=[DateTime]'2026-09-11T10:00:12Z';$bridge=& $eventScript -Action Start -ProjectPath $testRoot -Category PACKAGE -Subcategory cli_initialization -Operation package.cli_initialization -CommandType SUBPROCESS -ProcessId 4343 -NowUtc $cursor.ToString('o') -Json|ConvertFrom-Json;& $eventScript -Action End -ProjectPath $testRoot -EventId $bridge.eventId -Status PASS -ProcessId 4343 -ExitCode 0 -NowUtc $bridgeEnd.ToString('o') -Json|Out-Null
    & $stateScript -Action Pause -TargetBotPath $testRoot -Reason 'approval wait' -NowUtc '2026-09-11T10:00:12Z' -Json|Out-Null;& $stateScript -Action Resume -TargetBotPath $testRoot -NowUtc '2026-09-11T10:00:13Z' -Json|Out-Null
    $source=& $eventScript -Action Start -ProjectPath $testRoot -Category SOURCE_EDIT -Subcategory coherent_cycle -Operation source.write -EditCycleId cycle-1 -Reason 'initial generation' -BytesBefore 0 -HashBefore ('0'*64) -NowUtc '2026-09-11T10:00:13Z' -Json|ConvertFrom-Json;& $eventScript -Action End -ProjectPath $testRoot -EventId $source.eventId -Status PASS -EditCycleId cycle-1 -Reason 'initial generation' -BytesAfter 128 -HashAfter ('a'*64) -NowUtc '2026-09-11T10:00:14Z' -Json|Out-Null
    & $stateScript -Action InterruptionStart -TargetBotPath $testRoot -Reason 'external host interruption' -NowUtc '2026-09-11T10:00:14Z' -Json|Out-Null;& $stateScript -Action InterruptionEnd -TargetBotPath $testRoot -NowUtc '2026-09-11T10:00:15Z' -Json|Out-Null
    $final=& $eventScript -Action Start -ProjectPath $testRoot -Category FINALIZATION -Subcategory wrapper -Operation finalization.wrapper -NowUtc '2026-09-11T10:00:15Z' -Json|ConvertFrom-Json;& $eventScript -Action End -ProjectPath $testRoot -EventId $final.eventId -Status PASS -NowUtc '2026-09-11T10:00:20Z' -Json|Out-Null
    & $stateScript -Action StageEnd -Stage developer -TargetBotPath $testRoot -NowUtc '2026-09-11T10:00:20Z' -Json|Out-Null
    $breakdown=& $breakdownScript -ProjectPath $testRoot -NowUtc '2026-09-11T10:00:20Z' -Json|ConvertFrom-Json;$consistency=& $checkScript -ProjectPath $testRoot -NowUtc '2026-09-11T10:00:20Z' -Json|ConvertFrom-Json
    Assert-True ($consistency.status -eq 'PASS' -and $consistency.wallClockMs -eq 20000 -and $consistency.activeExecutionMs -eq 18000 -and $consistency.userWaitMs -eq 1000 -and $consistency.externalInterruptionMs -eq 1000) '31-46. Wall/active/wait/interruption reconciliation or parent-child timing failed.'
    Assert-True ($breakdown.attributionCoveragePct -ge 95 -and $breakdown.unknownMs -le 1000 -and $breakdown.categories.UIA -gt 0 -and $breakdown.categories.UI_TARGET -gt 0 -and $breakdown.categories.SOURCE_EDIT -gt 0 -and $breakdown.categories.PACKAGE -gt 0) '31,36-45,51-75. Runtime breakdown did not provide high-coverage non-overlapping category attribution.'
    Assert-True (@($breakdown.topLongestOperations).Count -gt 0 -and @($breakdown.topHostModelGaps).Count -ge 0 -and $breakdown.semantics -match 'does not prove model inference') '36-37. Host/model gap semantics or deterministic top-operation output is missing.'
    Assert-True ($breakdown.sourceOperations.writes -ge 1 -and $breakdown.sourceOperations.editCycles -eq 1 -and $breakdown.sourceOperations.exclusiveMilliseconds -gt 0) '61-69. Source operation/edit-cycle aggregation is missing.'
    Assert-True (-not @($breakdown.topHostModelGaps|Where-Object {[DateTime]$_.gapStart -lt [DateTime]'2026-09-11T10:00:12Z' -and [DateTime]$_.gapEnd -gt [DateTime]'2026-09-11T10:00:11Z'}).Count) '37. Active subprocess time was incorrectly classified as a host/model gap.'

    $telemetry=[ordered]@{ledgerPath=$breakdown.ledger.path;ledgerSha256=$breakdown.ledger.sha256;ledgerBytes=$breakdown.ledger.bytes;summaryPath='.ai/evidence/runtime.json';attributionCoveragePct=$breakdown.attributionCoveragePct;majorTimingTotals=[ordered]@{developerTotalMs=$breakdown.developerTotalMs;unknownMs=$breakdown.unknownMs}}|ConvertTo-Json -Depth 6 -Compress;& $stateScript -Action TelemetryUpdate -TargetBotPath $testRoot -TelemetryJson $telemetry -NowUtc '2026-09-11T10:00:20Z' -Json|Out-Null;$compact=& $stateScript -Action Read -TargetBotPath $testRoot -NowUtc '2026-09-11T10:00:20Z' -Json|ConvertFrom-Json
    Assert-True ($compact.telemetry.ledgerSha256 -match '^[0-9a-f]{64}$' -and $compact.telemetry.ledgerBytes -gt 0 -and @($compact.commands).Count -eq 0 -and ($compact|ConvertTo-Json -Depth 15 -Compress) -notmatch 'uia\.snapshot.*uia\.navigate') '50. Execution state embedded detailed ledger data instead of a compact reference.'

    Import-Module $module -Force
    $incompleteLedger=Join-Path $testRoot '.ai\evidence\incomplete.jsonl';Start-DeveloperEvent -ProjectPath $testRoot -LedgerPath $incompleteLedger -Category VALIDATION -Operation incomplete -NowUtc '2026-09-11T10:00:01Z'|Out-Null;Add-Content -LiteralPath $incompleteLedger -Value '{"schemaVersion":1,"recordType":"END"' -NoNewline;$incomplete=Read-DeveloperEventLedger -LedgerPath $incompleteLedger
    Assert-True ($incomplete.truncatedTail -and @($incomplete.warnings|Where-Object {$_ -like 'INCOMPLETE_EVENT*'}).Count -eq 1) '42,47-48. Incomplete event/truncated append recovery failed.'
    $corruptLedger=Join-Path $testRoot '.ai\evidence\corrupt.jsonl';Write-Utf8 $corruptLedger "{`"schemaVersion`":1,`"recordType`":`"START`",`"eventId`":`"a`",`"category`":`"VALIDATION`",`"operation`":`"x`",`"startUtc`":`"2026-09-11T10:00:01Z`"}`nNOT_JSON`n{`"schemaVersion`":1,`"recordType`":`"END`",`"eventId`":`"a`",`"endUtc`":`"2026-09-11T10:00:02Z`",`"status`":`"PASS`"}`n";$corrupt=Read-DeveloperEventLedger -LedgerPath $corruptLedger
    Assert-True (@($corrupt.errors|Where-Object {$_ -like 'LEDGER_CORRUPT_RECORD*'}).Count -eq 1 -and @($corrupt.events).Count -eq 1) '48. Middle-record corruption was not isolated and reported.'

    $concurrentLedger=Join-Path $testRoot '.ai\evidence\concurrent.jsonl';$jobs=@();1..4|ForEach-Object{$jobIndex=$_;$jobs+=Start-Job -ScriptBlock {param($Module,$Project,$Ledger,$Index)Import-Module $Module -Force;1..10|ForEach-Object{Add-DeveloperInstantEvent -ProjectPath $Project -LedgerPath $Ledger -Category STATE -Subcategory concurrent -Operation "write.$Index.$_"|Out-Null}} -ArgumentList $module,$testRoot,$concurrentLedger,$jobIndex};$jobs|Wait-Job|Out-Null;$jobErrors=@($jobs|Receive-Job -ErrorAction SilentlyContinue);$jobs|Remove-Job -Force;$concurrent=Read-DeveloperEventLedger -LedgerPath $concurrentLedger
    Assert-True (-not @($concurrent.errors).Count -and @($concurrent.events).Count -eq 40) '49. Concurrent append safety lost or corrupted ledger records.'

    $badState=Join-Path $testRoot '.ai\evidence\bad-state.json';Copy-Item (Join-Path $testRoot '.ai\evidence\execution-state.json') $badState;$bad=Get-Content -Raw $badState|ConvertFrom-Json;$bad.execution.user_wait_intervals=@([pscustomobject]@{started_at='2026-09-11T10:00:05Z';ended_at='2026-09-11T10:00:07Z'},[pscustomobject]@{started_at='2026-09-11T10:00:06Z';ended_at='2026-09-11T10:00:08Z'});$bad|ConvertTo-Json -Depth 15|Set-Content $badState -Encoding utf8;$badCheck=& $checkScript -ProjectPath $testRoot -StatePath $badState -NowUtc '2026-09-11T10:00:20Z' -Json|ConvertFrom-Json
    Assert-True ($badCheck.status -eq 'FAIL' -and @($badCheck.failures|Where-Object {$_ -like 'OVERLAPPING_USER_WAIT*'}).Count) '40,46. Timing inconsistency/overlapping wait detection failed.'
    Write-Host '[PASS] Developer event ledger and runtime observability tests'
}finally{Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue}
