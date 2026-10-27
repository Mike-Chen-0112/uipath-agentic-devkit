Set-StrictMode -Version 2.0

$script:TelemetryCategories = @(
    'HOST_MODEL_GAP','SCAFFOLDING','PACKAGE','UIA','UI_TARGET','OBJECT_REPOSITORY',
    'SOURCE_READ','SOURCE_EDIT','SOURCE_REPAIR','MAPPER','GRAPHIFY','VALIDATION',
    'EVIDENCE','STATE','FINALIZATION','USER_WAIT','EXTERNAL_INTERRUPTION','UNKNOWN'
)

function ConvertTo-DevKitUtc {
    param([string]$Value)
    if (-not $Value) { return [DateTime]::UtcNow }
    return [DateTime]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
}

function Resolve-DeveloperLedgerPath {
    param([Parameter(Mandatory=$true)][string]$ProjectPath, [string]$LedgerPath)
    $root = [IO.Path]::GetFullPath($ProjectPath)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "Developer telemetry project path not found: $root" }
    $path = if ($LedgerPath) { [IO.Path]::GetFullPath($LedgerPath) } else { Join-Path $root '.ai\evidence\developer-events.jsonl' }
    $prefix = $root.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Developer ledger must stay within the project: $path" }
    return $path
}

function Get-DevKitSha256Text {
    param([Parameter(Mandatory=$true)][string]$Value)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function ConvertTo-DevKitArtifactReference {
    param($Artifact)
    if ($null -eq $Artifact) { return @() }
    $result = New-Object Collections.Generic.List[object]
    foreach ($item in @($Artifact)) {
        if ($item -is [string]) {
            [void]$result.Add([ordered]@{ path = [string]$item; sha256 = $null; bytes = $null })
            continue
        }
        if(-not ($item.PSObject.Properties.Name -contains 'path')){continue}
        $path = [string]$item.path
        if (-not $path) { continue }
        [void]$result.Add([ordered]@{
            path = $path
            sha256 = if (($item.PSObject.Properties.Name -contains 'sha256') -and $item.sha256) { [string]$item.sha256 } else { $null }
            bytes = if (($item.PSObject.Properties.Name -contains 'bytes') -and $null -ne $item.bytes) { [int64]$item.bytes } else { $null }
        })
    }
    return $result.ToArray()
}

function Write-DeveloperLedgerRecord {
    param(
        [Parameter(Mandatory=$true)][string]$LedgerPath,
        [Parameter(Mandatory=$true)]$Record,
        [int]$LockRetryCount = 80,
        [int]$LockRetryMilliseconds = 25
    )
    $ledgerDirectory = Split-Path $LedgerPath -Parent
    if (-not (Test-Path -LiteralPath $ledgerDirectory -PathType Container)) { New-Item -ItemType Directory -Force -Path $ledgerDirectory | Out-Null }
    $line = ($Record | ConvertTo-Json -Depth 10 -Compress) + [Environment]::NewLine
    $bytes = [Text.Encoding]::UTF8.GetBytes($line)
    $stream = $null
    for ($attempt = 0; $attempt -lt $LockRetryCount; $attempt++) {
        try {
            $stream = New-Object IO.FileStream($LedgerPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            break
        } catch [IO.IOException] {
            if ($attempt -eq ($LockRetryCount - 1)) { throw "Concurrent developer-ledger write did not become available: $LedgerPath" }
            Start-Sleep -Milliseconds $LockRetryMilliseconds
        }
    }
    try {
        [void]$stream.Seek(0, [IO.SeekOrigin]::End)
        $stream.Write($bytes, 0, $bytes.Length)
        # Dispose flushes the compact append to the OS cache. Avoid a physical-disk flush for
        # every boundary; JSONL tail recovery handles a process interruption mid-record.
        $stream.Flush()
    } finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Start-DeveloperEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$ProjectPath,
        [string]$LedgerPath,
        [Parameter(Mandatory=$true)][ValidateSet('HOST_MODEL_GAP','SCAFFOLDING','PACKAGE','UIA','UI_TARGET','OBJECT_REPOSITORY','SOURCE_READ','SOURCE_EDIT','SOURCE_REPAIR','MAPPER','GRAPHIFY','VALIDATION','EVIDENCE','STATE','FINALIZATION','USER_WAIT','EXTERNAL_INTERRUPTION','UNKNOWN')][string]$Category,
        [string]$Subcategory = '',
        [Parameter(Mandatory=$true)][string]$Operation,
        [string]$ParentEventId = '',
        [string]$CommandType = 'IN_PROCESS',
        [Nullable[int]]$ProcessId,
        [object[]]$Artifacts = @(),
        [string]$EditCycleId = '',
        [string]$Reason = '',
        [Nullable[int64]]$BytesBefore,
        [Nullable[int64]]$BytesAfter,
        [string]$HashBefore = '',
        [string]$HashAfter = '',
        [string]$NowUtc,
        [string]$EventId = ''
    )
    $resolved = Resolve-DeveloperLedgerPath -ProjectPath $ProjectPath -LedgerPath $LedgerPath
    $id = if ($EventId) { $EventId } else { [guid]::NewGuid().ToString('N') }
    $at = ConvertTo-DevKitUtc $NowUtc
    $record = [ordered]@{
        schemaVersion = 1
        recordType = 'START'
        eventId = $id
        parentEventId = if ($ParentEventId) { $ParentEventId } else { $null }
        category = $Category
        subcategory = $Subcategory
        operation = $Operation
        startUtc = $at.ToString('o')
        endUtc = $null
        elapsedMilliseconds = $null
        inclusiveMilliseconds = $null
        exclusiveMilliseconds = $null
        status = 'RUNNING'
        commandType = $CommandType
        pid = if ($null -ne $ProcessId) { [int]$ProcessId } else { $null }
        exitCode = $null
        timedOut = $false
        artifacts = ConvertTo-DevKitArtifactReference $Artifacts
        editCycleId = if($EditCycleId){$EditCycleId}else{$null}
        reason = if($Reason){$Reason}else{$null}
        bytesBefore = if($null -ne $BytesBefore){[int64]$BytesBefore}else{$null}
        bytesAfter = if($null -ne $BytesAfter){[int64]$BytesAfter}else{$null}
        hashBefore = if($HashBefore){$HashBefore}else{$null}
        hashAfter = if($HashAfter){$HashAfter}else{$null}
        nested = [bool]$ParentEventId
    }
    Write-DeveloperLedgerRecord -LedgerPath $resolved -Record $record
    return [pscustomobject]$record
}

function Stop-DeveloperEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$ProjectPath,
        [string]$LedgerPath,
        [Parameter(Mandatory=$true)][string]$EventId,
        [ValidateSet('PASS','FAIL','BLOCKED','TIMEOUT','SKIPPED','UNAVAILABLE')][string]$Status = 'PASS',
        [Nullable[int]]$ExitCode,
        [switch]$TimedOut,
        [Nullable[int]]$ProcessId,
        [object[]]$Artifacts = @(),
        [string]$EditCycleId = '',
        [string]$Reason = '',
        [Nullable[int64]]$BytesBefore,
        [Nullable[int64]]$BytesAfter,
        [string]$HashBefore = '',
        [string]$HashAfter = '',
        [string]$NowUtc
    )
    $resolved = Resolve-DeveloperLedgerPath -ProjectPath $ProjectPath -LedgerPath $LedgerPath
    $at = ConvertTo-DevKitUtc $NowUtc
    $record = [ordered]@{
        schemaVersion = 1
        recordType = 'END'
        eventId = $EventId
        endUtc = $at.ToString('o')
        status = if ($TimedOut) { 'TIMEOUT' } else { $Status }
        pid = if ($null -ne $ProcessId) { [int]$ProcessId } else { $null }
        exitCode = if ($null -ne $ExitCode) { [int]$ExitCode } else { $null }
        timedOut = [bool]$TimedOut
        artifacts = ConvertTo-DevKitArtifactReference $Artifacts
        editCycleId = if($EditCycleId){$EditCycleId}else{$null}
        reason = if($Reason){$Reason}else{$null}
        bytesBefore = if($null -ne $BytesBefore){[int64]$BytesBefore}else{$null}
        bytesAfter = if($null -ne $BytesAfter){[int64]$BytesAfter}else{$null}
        hashBefore = if($HashBefore){$HashBefore}else{$null}
        hashAfter = if($HashAfter){$HashAfter}else{$null}
    }
    Write-DeveloperLedgerRecord -LedgerPath $resolved -Record $record
    return [pscustomobject]$record
}

function Add-DeveloperInstantEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$ProjectPath,
        [string]$LedgerPath,
        [Parameter(Mandatory=$true)][ValidateSet('HOST_MODEL_GAP','SCAFFOLDING','PACKAGE','UIA','UI_TARGET','OBJECT_REPOSITORY','SOURCE_READ','SOURCE_EDIT','SOURCE_REPAIR','MAPPER','GRAPHIFY','VALIDATION','EVIDENCE','STATE','FINALIZATION','USER_WAIT','EXTERNAL_INTERRUPTION','UNKNOWN')][string]$Category,
        [string]$Subcategory = '',
        [Parameter(Mandatory=$true)][string]$Operation,
        [string]$ParentEventId = '',
        [ValidateSet('PASS','FAIL','BLOCKED','TIMEOUT','SKIPPED','UNAVAILABLE')][string]$Status = 'PASS',
        [object[]]$Artifacts = @(),
        [string]$EditCycleId = '',
        [string]$Reason = '',
        [Nullable[int64]]$BytesBefore,
        [Nullable[int64]]$BytesAfter,
        [string]$HashBefore = '',
        [string]$HashAfter = '',
        [string]$NowUtc
    )
    $at = ConvertTo-DevKitUtc $NowUtc
    $event = Start-DeveloperEvent -ProjectPath $ProjectPath -LedgerPath $LedgerPath -Category $Category -Subcategory $Subcategory -Operation $Operation -ParentEventId $ParentEventId -Artifacts $Artifacts -EditCycleId $EditCycleId -Reason $Reason -BytesBefore $BytesBefore -BytesAfter $BytesAfter -HashBefore $HashBefore -HashAfter $HashAfter -NowUtc $at.ToString('o')
    Stop-DeveloperEvent -ProjectPath $ProjectPath -LedgerPath $LedgerPath -EventId $event.eventId -Status $Status -Artifacts $Artifacts -EditCycleId $EditCycleId -Reason $Reason -BytesBefore $BytesBefore -BytesAfter $BytesAfter -HashBefore $HashBefore -HashAfter $HashAfter -NowUtc $at.ToString('o') | Out-Null
    return $event
}

function Read-DeveloperEventLedger {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$LedgerPath)
    $warnings = New-Object Collections.Generic.List[string]
    $errors = New-Object Collections.Generic.List[string]
    $records = New-Object Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $LedgerPath -PathType Leaf)) {
        return [pscustomobject][ordered]@{ records=@(); events=@(); warnings=@('LEDGER_NOT_FOUND'); errors=@(); truncatedTail=$false }
    }
    $text = [IO.File]::ReadAllText($LedgerPath, [Text.Encoding]::UTF8)
    $hasTrailingNewline = $text.EndsWith("`n")
    $lines = @($text -split "`r?`n")
    $lastNonEmpty = -1
    for ($i = $lines.Count - 1; $i -ge 0; $i--) { if ($lines[$i].Trim()) { $lastNonEmpty = $i; break } }
    $truncatedTail = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i].Trim()
        if (-not $line) { continue }
        try {
            $record = $line | ConvertFrom-Json -ErrorAction Stop
            if ([int]$record.schemaVersion -ne 1 -or -not [string]$record.recordType -or -not [string]$record.eventId) { throw 'required ledger fields are missing' }
            [void]$records.Add($record)
        } catch {
            if ($i -eq $lastNonEmpty -and -not $hasTrailingNewline) {
                $truncatedTail = $true
                [void]$warnings.Add("LEDGER_TRUNCATED_TAIL:line=$($i+1)")
            } else {
                [void]$errors.Add("LEDGER_CORRUPT_RECORD:line=$($i+1):$($_.Exception.Message)")
            }
        }
    }
    $eventsById = [ordered]@{}
    foreach ($record in $records) {
        $id = [string]$record.eventId
        if ([string]$record.recordType -eq 'START') {
            if ($eventsById.Contains($id)) { [void]$errors.Add("DUPLICATE_EVENT_START:$id"); continue }
            $eventsById[$id] = [ordered]@{
                eventId=$id; parentEventId=if($record.PSObject.Properties.Name -contains 'parentEventId'){[string]$record.parentEventId}else{''}; category=if($record.PSObject.Properties.Name -contains 'category'){[string]$record.category}else{'UNKNOWN'}; subcategory=if($record.PSObject.Properties.Name -contains 'subcategory'){[string]$record.subcategory}else{''}
                operation=if($record.PSObject.Properties.Name -contains 'operation'){[string]$record.operation}else{''}; startUtc=if($record.PSObject.Properties.Name -contains 'startUtc'){[string]$record.startUtc}else{$null}; endUtc=$null; elapsedMilliseconds=$null
                inclusiveMilliseconds=$null; exclusiveMilliseconds=$null; status='INCOMPLETE'; commandType=if($record.PSObject.Properties.Name -contains 'commandType'){[string]$record.commandType}else{'UNKNOWN'}
                pid=if($record.PSObject.Properties.Name -contains 'pid'){$record.pid}else{$null}; exitCode=$null; timedOut=$false; artifacts=if($record.PSObject.Properties.Name -contains 'artifacts'){@($record.artifacts)}else{@()}; nested=if($record.PSObject.Properties.Name -contains 'nested'){[bool]$record.nested}else{$false}
                editCycleId=if($record.PSObject.Properties.Name -contains 'editCycleId'){[string]$record.editCycleId}else{''}; reason=if($record.PSObject.Properties.Name -contains 'reason'){[string]$record.reason}else{''}; bytesBefore=if($record.PSObject.Properties.Name -contains 'bytesBefore'){$record.bytesBefore}else{$null}; bytesAfter=if($record.PSObject.Properties.Name -contains 'bytesAfter'){$record.bytesAfter}else{$null}; hashBefore=if($record.PSObject.Properties.Name -contains 'hashBefore'){[string]$record.hashBefore}else{''}; hashAfter=if($record.PSObject.Properties.Name -contains 'hashAfter'){[string]$record.hashAfter}else{''}
            }
        } elseif ([string]$record.recordType -eq 'END') {
            if (-not $eventsById.Contains($id)) { [void]$errors.Add("ORPHAN_EVENT_END:$id"); continue }
            $event = $eventsById[$id]
            $event.endUtc = [string]$record.endUtc
            $event.status = [string]$record.status
            $event.exitCode = if($record.PSObject.Properties.Name -contains 'exitCode'){$record.exitCode}else{$null}
            $event.timedOut = if($record.PSObject.Properties.Name -contains 'timedOut'){[bool]$record.timedOut}else{$false}
            if (($record.PSObject.Properties.Name -contains 'pid') -and $null -ne $record.pid) { $event.pid = $record.pid }
            $event.artifacts = @($event.artifacts) + $(if($record.PSObject.Properties.Name -contains 'artifacts'){@($record.artifacts)}else{@()})
            foreach($field in @('editCycleId','reason','bytesBefore','bytesAfter','hashBefore','hashAfter')){if($record.PSObject.Properties.Name -contains $field -and $null -ne $record.$field -and [string]$record.$field){$event[$field]=$record.$field}}
            try {
                $start = ConvertTo-DevKitUtc $event.startUtc
                $end = ConvertTo-DevKitUtc $event.endUtc
                $event.elapsedMilliseconds = [Math]::Round(($end - $start).TotalMilliseconds, 3)
                $event.inclusiveMilliseconds = $event.elapsedMilliseconds
            } catch { [void]$errors.Add("INVALID_EVENT_INTERVAL:$id") }
        }
    }
    $events = @($eventsById.Values)
    foreach ($event in $events) { if (-not $event.endUtc) { [void]$warnings.Add("INCOMPLETE_EVENT:$($event.eventId)") } }
    return [pscustomobject][ordered]@{ records=$records.ToArray(); events=$events; warnings=$warnings.ToArray(); errors=$errors.ToArray(); truncatedTail=$truncatedTail }
}

function Get-IntervalUnionMilliseconds {
    param([object[]]$Intervals)
    $items = @($Intervals | Where-Object { $null -ne $_ -and $_.PSObject.Properties.Name -contains 'start' -and $_.PSObject.Properties.Name -contains 'end' -and $_.start -and $_.end } | Sort-Object start)
    if ($items.Count -eq 0) { return 0.0 }
    $total = 0.0
    $start = [DateTime]$items[0].start
    $end = [DateTime]$items[0].end
    foreach ($item in @($items | Select-Object -Skip 1)) {
        $nextStart = [DateTime]$item.start
        $nextEnd = [DateTime]$item.end
        if ($nextStart -le $end) { if ($nextEnd -gt $end) { $end = $nextEnd } }
        else { $total += ($end - $start).TotalMilliseconds; $start = $nextStart; $end = $nextEnd }
    }
    $total += ($end - $start).TotalMilliseconds
    return [Math]::Round($total, 3)
}

function Get-ExecutionIntervals {
    param($Values, [DateTime]$FallbackEnd)
    $result = @()
    foreach ($interval in @($Values)) {
        if (-not $interval.started_at) { continue }
        $start = ConvertTo-DevKitUtc ([string]$interval.started_at)
        $end = if ($interval.ended_at) { ConvertTo-DevKitUtc ([string]$interval.ended_at) } else { $FallbackEnd }
        $result += [pscustomobject]@{ start=$start; end=$end; source=$interval }
    }
    return $result
}

function Remove-ExcludedIntervals {
    param([DateTime]$Start,[DateTime]$End,[object[]]$Exclusions)
    $segments=@([pscustomobject]@{start=$Start;end=$End})
    foreach($exclude in @($Exclusions|Sort-Object start)){
        $next=@()
        foreach($segment in $segments){
            if($exclude.end -le $segment.start -or $exclude.start -ge $segment.end){$next+=$segment;continue}
            if($exclude.start -gt $segment.start){$next += [pscustomobject]@{start=$segment.start;end=$exclude.start}}
            if($exclude.end -lt $segment.end){$next += [pscustomobject]@{start=$exclude.end;end=$segment.end}}
        }
        $segments=$next
    }
    return @($segments|Where-Object {$_.end -gt $_.start})
}

function Get-DeveloperRuntimeBreakdownData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$ProjectPath,
        [string]$StatePath,
        [string]$LedgerPath,
        [string]$NowUtc
    )
    $root = (Resolve-Path -LiteralPath $ProjectPath).Path
    $statePathResolved = if ($StatePath) { [IO.Path]::GetFullPath($StatePath) } else { Join-Path $root '.ai\evidence\execution-state.json' }
    $ledgerPathResolved = Resolve-DeveloperLedgerPath -ProjectPath $root -LedgerPath $LedgerPath
    if (-not (Test-Path -LiteralPath $statePathResolved -PathType Leaf)) { throw "Execution state not found: $statePathResolved" }
    $state = [IO.File]::ReadAllText($statePathResolved, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $now = ConvertTo-DevKitUtc $NowUtc
    $executionStart = ConvertTo-DevKitUtc ([string]$state.execution.started_at)
    $executionEnd = if ($state.execution.ended_at) { ConvertTo-DevKitUtc ([string]$state.execution.ended_at) } else { $now }
    $userWaitIntervals = @(Get-ExecutionIntervals @($state.execution.user_wait_intervals) $executionEnd)
    $externalIntervals = @(Get-ExecutionIntervals @($state.execution.external_interruption_intervals) $executionEnd)
    $excludedIntervals=@($userWaitIntervals)+@($externalIntervals)
    $developerIntervals = @(Get-ExecutionIntervals @($state.stages.developer.intervals) $executionEnd)
    if ($state.stages.developer.active_started_at) { $developerIntervals += [pscustomobject]@{ start=(ConvertTo-DevKitUtc ([string]$state.stages.developer.active_started_at)); end=$executionEnd; source=$null } }
    $developerStart = if ($developerIntervals.Count) { ($developerIntervals | Sort-Object start | Select-Object -First 1).start } else { $executionStart }
    $developerEnd = if ($developerIntervals.Count) { ($developerIntervals | Sort-Object end -Descending | Select-Object -First 1).end } else { $executionEnd }
    $ledger = Read-DeveloperEventLedger -LedgerPath $ledgerPathResolved
    $complete = @($ledger.events | Where-Object { $_.startUtc -and $_.endUtc -and [double]$_.elapsedMilliseconds -ge 0 })
    $eventById = @{}
    foreach ($event in $complete) { $eventById[[string]$event.eventId] = $event }
    foreach ($event in $complete) {
        $childIntervals = @()
        foreach ($child in $complete | Where-Object { [string]$_.parentEventId -eq [string]$event.eventId }) {
            $childIntervals += [pscustomobject]@{ start=(ConvertTo-DevKitUtc $child.startUtc); end=(ConvertTo-DevKitUtc $child.endUtc) }
        }
        $childMs = Get-IntervalUnionMilliseconds $childIntervals
        $event.exclusiveMilliseconds = [Math]::Max(0.0, [Math]::Round(([double]$event.elapsedMilliseconds - $childMs), 3))
    }
    $categories = [ordered]@{}
    foreach ($category in $script:TelemetryCategories) { $categories[$category] = 0.0 }
    foreach ($event in $complete) {
        $category = if ([string]$event.category -in $script:TelemetryCategories) { [string]$event.category } else { 'UNKNOWN' }
        $categories[$category] = [Math]::Round(([double]$categories[$category] + [double]$event.exclusiveMilliseconds), 3)
    }
    $measuredIntervals = @($complete | ForEach-Object { [pscustomobject]@{ start=(ConvertTo-DevKitUtc $_.startUtc); end=(ConvertTo-DevKitUtc $_.endUtc); event=$_ } })
    $ordered = @($measuredIntervals | Sort-Object start)
    $hostGaps = @()
    if ($ordered.Count -gt 1) {
        $cursor = [DateTime]$ordered[0].end
        $previous = $ordered[0].event
        foreach ($item in @($ordered | Select-Object -Skip 1)) {
            if ($item.start -gt $cursor) {
                foreach($segment in @(Remove-ExcludedIntervals -Start $cursor -End $item.start -Exclusions $excludedIntervals)){
                    $hostGaps += [pscustomobject][ordered]@{
                        gapStart=$segment.start.ToString('o'); gapEnd=$segment.end.ToString('o'); durationMilliseconds=[Math]::Round(($segment.end-$segment.start).TotalMilliseconds,3)
                        previousEvent=[string]$previous.eventId; nextEvent=[string]$item.event.eventId; classification='HOST_MODEL_OR_DISPATCH_GAP'
                    }
                }
            }
            if ($item.end -gt $cursor) { $cursor=$item.end; $previous=$item.event }
        }
    }
    $hostGapMs=0.0;foreach($gap in @($hostGaps)){$hostGapMs+=[double]$gap.durationMilliseconds};$hostGapMs=[Math]::Round($hostGapMs,3)
    $categories['HOST_MODEL_GAP'] = [Math]::Round(([double]$categories['HOST_MODEL_GAP'] + $hostGapMs),3)
    $developerTotalMs = [Math]::Max(0.0, [Math]::Round(($developerEnd-$developerStart).TotalMilliseconds,3))
    $userWaitMs = Get-IntervalUnionMilliseconds $userWaitIntervals
    $externalMs = Get-IntervalUnionMilliseconds $externalIntervals
    $categories['USER_WAIT']=$userWaitMs
    $categories['EXTERNAL_INTERRUPTION']=$externalMs
    $wallMs = [Math]::Max(0.0, [Math]::Round(($executionEnd-$executionStart).TotalMilliseconds,3))
    $activeMs = [Math]::Max(0.0, [Math]::Round(($wallMs-$userWaitMs-$externalMs),3))
    $measuredMs = Get-IntervalUnionMilliseconds $measuredIntervals
    $boundedAttributedMs = [Math]::Min($developerTotalMs, [Math]::Round(($measuredMs+$hostGapMs+$userWaitMs+$externalMs),3))
    $unknownMs = [Math]::Max(0.0, [Math]::Round(($developerTotalMs-$boundedAttributedMs),3))
    $categories['UNKNOWN'] = $unknownMs
    $coverage = if ($developerTotalMs -gt 0) { [Math]::Round(($boundedAttributedMs/$developerTotalMs)*100,2) } else { 0.0 }
    $top = @($complete | Sort-Object elapsedMilliseconds -Descending | Select-Object -First 10 | ForEach-Object { [pscustomobject]@{ eventId=$_.eventId; category=$_.category; operation=$_.operation; elapsedMilliseconds=$_.elapsedMilliseconds; exclusiveMilliseconds=$_.exclusiveMilliseconds } })
    $sourceEvents=@($complete|Where-Object {$_.category -in @('SOURCE_READ','SOURCE_EDIT','SOURCE_REPAIR')})
    $sourceOperations=[ordered]@{
        reads=@($sourceEvents|Where-Object {$_.operation -in @('source.read','source.reopen')}).Count
        creates=@($sourceEvents|Where-Object {$_.operation -eq 'source.create'}).Count
        patches=@($sourceEvents|Where-Object {$_.operation -eq 'source.patch'}).Count
        writes=@($sourceEvents|Where-Object {$_.operation -in @('source.write','source.replace')}).Count
        validations=@($sourceEvents|Where-Object {$_.operation -eq 'source.validate'}).Count
        repairs=@($sourceEvents|Where-Object {$_.operation -eq 'source.repair'}).Count
        editCycles=@($sourceEvents|ForEach-Object {[string]$_.editCycleId}|Where-Object {$_}|Sort-Object -Unique).Count
        diagnosticsTriggeredRepairs=@($sourceEvents|Where-Object {$_.operation -eq 'source.repair' -and [string]$_.reason -match 'diagnostic|get-errors'}).Count
        exclusiveMilliseconds=[Math]::Round((@($sourceEvents)|ForEach-Object {[double]$_.exclusiveMilliseconds}|Measure-Object -Sum).Sum,3)
    }
    $largestUnknown = @()
    if ($ordered.Count) {
        if ($ordered[0].start -gt $developerStart) { $largestUnknown += [pscustomobject]@{ startUtc=$developerStart.ToString('o'); endUtc=$ordered[0].start.ToString('o'); durationMilliseconds=[Math]::Round(($ordered[0].start-$developerStart).TotalMilliseconds,3); reason='UNBOUNDED_BEFORE_FIRST_EVENT' } }
        $last = $ordered | Sort-Object end -Descending | Select-Object -First 1
        if ($developerEnd -gt $last.end) { $largestUnknown += [pscustomobject]@{ startUtc=$last.end.ToString('o'); endUtc=$developerEnd.ToString('o'); durationMilliseconds=[Math]::Round(($developerEnd-$last.end).TotalMilliseconds,3); reason='UNBOUNDED_AFTER_LAST_EVENT' } }
    } elseif ($developerTotalMs -gt 0) { $largestUnknown += [pscustomobject]@{ startUtc=$developerStart.ToString('o'); endUtc=$developerEnd.ToString('o'); durationMilliseconds=$developerTotalMs; reason='NO_LEDGER_EVENTS' } }
    $item = if (Test-Path -LiteralPath $ledgerPathResolved -PathType Leaf) { Get-Item -LiteralPath $ledgerPathResolved } else { $null }
    return [pscustomobject][ordered]@{
        schemaVersion=1; generatedAtUtc=$now.ToString('o'); developerTotalMs=$developerTotalMs; wallClockMs=$wallMs; activeExecutionMs=$activeMs
        userWaitMs=$userWaitMs; externalInterruptionMs=$externalMs; categories=$categories; unknownMs=$unknownMs
        attributedRuntimeMs=$boundedAttributedMs; attributionCoveragePct=$coverage; eventCount=$complete.Count; incompleteEventCount=@($ledger.events | Where-Object { -not $_.endUtc }).Count
        topLongestOperations=$top; topHostModelGaps=@($hostGaps | Sort-Object durationMilliseconds -Descending | Select-Object -First 10)
        sourceOperations=$sourceOperations
        largestUnknownIntervals=@($largestUnknown | Sort-Object durationMilliseconds -Descending | Select-Object -First 10)
        ledger=[ordered]@{ path=if($item){$ledgerPathResolved.Substring($root.TrimEnd('\','/').Length).TrimStart('\','/') -replace '\\','/'}else{'.ai/evidence/developer-events.jsonl'}; bytes=if($item){[int64]$item.Length}else{0}; sha256=if($item){(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}else{$null}; warnings=@($ledger.warnings); errors=@($ledger.errors) }
        semantics='HOST_MODEL_GAP is a conservative observed interval between measured operations; it does not prove model inference.'
    }
}

function Test-DeveloperTimingConsistencyData {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$ProjectPath,[string]$StatePath,[string]$LedgerPath,[string]$NowUtc,[double]$ToleranceMilliseconds=5)
    $breakdown = Get-DeveloperRuntimeBreakdownData -ProjectPath $ProjectPath -StatePath $StatePath -LedgerPath $LedgerPath -NowUtc $NowUtc
    $resolvedLedger = Resolve-DeveloperLedgerPath -ProjectPath $ProjectPath -LedgerPath $LedgerPath
    $ledger = Read-DeveloperEventLedger -LedgerPath $resolvedLedger
    $failures = New-Object Collections.Generic.List[string]
    $warnings = New-Object Collections.Generic.List[string]
    foreach ($error in @($ledger.errors)) { [void]$failures.Add([string]$error) }
    foreach ($warning in @($ledger.warnings)) { [void]$warnings.Add([string]$warning) }
    $byId = @{}; foreach ($event in @($ledger.events)) { $byId[[string]$event.eventId]=$event }
    function Test-EventAncestor {
        param([string]$AncestorId,[string]$DescendantId)
        $visited=@{}
        $cursor=$DescendantId
        while($cursor -and $byId.ContainsKey($cursor)){
            if($visited.ContainsKey($cursor)){return $false};$visited[$cursor]=$true
            $parentId=[string]$byId[$cursor].parentEventId
            if($parentId -eq $AncestorId){return $true}
            $cursor=$parentId
        }
        return $false
    }
    $statePathResolved=if($StatePath){[IO.Path]::GetFullPath($StatePath)}else{Join-Path (Resolve-Path -LiteralPath $ProjectPath).Path '.ai\evidence\execution-state.json'}
    $state=[IO.File]::ReadAllText($statePathResolved,[Text.Encoding]::UTF8)|ConvertFrom-Json
    $executionEnd=if($state.execution.ended_at){ConvertTo-DevKitUtc ([string]$state.execution.ended_at)}else{ConvertTo-DevKitUtc $NowUtc}
    $waitIntervals=@(Get-ExecutionIntervals @($state.execution.user_wait_intervals) $executionEnd)
    $externalIntervals=@(Get-ExecutionIntervals @($state.execution.external_interruption_intervals) $executionEnd)
    foreach($kind in @([pscustomobject]@{name='USER_WAIT';items=$waitIntervals},[pscustomobject]@{name='EXTERNAL_INTERRUPTION';items=$externalIntervals})){
        $ordered=@($kind.items|Sort-Object start)
        for($i=0;$i -lt $ordered.Count;$i++){
            if($ordered[$i].end -lt $ordered[$i].start){[void]$failures.Add("NEGATIVE_$($kind.name)_INTERVAL:$i")}
            if($i -gt 0 -and $ordered[$i].start -lt $ordered[$i-1].end){[void]$failures.Add("OVERLAPPING_$($kind.name)_INTERVALS:$($i-1):$i")}
        }
    }
    foreach($wait in $waitIntervals){foreach($external in $externalIntervals){if($wait.start -lt $external.end -and $external.start -lt $wait.end){[void]$failures.Add('OVERLAPPING_WAIT_AND_EXTERNAL_INTERRUPTION')}}}
    foreach ($event in @($ledger.events)) {
        if ($event.endUtc -and [double]$event.elapsedMilliseconds -lt 0) { [void]$failures.Add("NEGATIVE_DURATION:$($event.eventId)") }
        if ($event.parentEventId -and -not $byId.ContainsKey([string]$event.parentEventId)) { [void]$failures.Add("MISSING_PARENT:$($event.eventId):$($event.parentEventId)") }
        if ($event.parentEventId -and $byId.ContainsKey([string]$event.parentEventId)) {
            $parent=$byId[[string]$event.parentEventId]
            if ($parent.endUtc -and $event.endUtc) {
                if ((ConvertTo-DevKitUtc $event.startUtc) -lt (ConvertTo-DevKitUtc $parent.startUtc) -or (ConvertTo-DevKitUtc $event.endUtc) -gt (ConvertTo-DevKitUtc $parent.endUtc)) { [void]$failures.Add("CHILD_OUTSIDE_PARENT:$($event.eventId)") }
            }
        }
        $seenParents=@{};$cursor=[string]$event.eventId
        while($cursor -and $byId.ContainsKey($cursor)){
            if($seenParents.ContainsKey($cursor)){[void]$failures.Add("PARENT_CYCLE:$($event.eventId)");break}
            $seenParents[$cursor]=$true;$cursor=[string]$byId[$cursor].parentEventId
        }
    }
    $completeEvents=@($ledger.events|Where-Object {$_.endUtc}|Sort-Object startUtc)
    for($i=0;$i -lt $completeEvents.Count;$i++){
        $left=$completeEvents[$i];$leftStart=ConvertTo-DevKitUtc $left.startUtc;$leftEnd=ConvertTo-DevKitUtc $left.endUtc
        for($j=$i+1;$j -lt $completeEvents.Count;$j++){
            $right=$completeEvents[$j];$rightStart=ConvertTo-DevKitUtc $right.startUtc;if($rightStart -ge $leftEnd){break};$rightEnd=ConvertTo-DevKitUtc $right.endUtc
            $related=(Test-EventAncestor -AncestorId ([string]$left.eventId) -DescendantId ([string]$right.eventId)) -or (Test-EventAncestor -AncestorId ([string]$right.eventId) -DescendantId ([string]$left.eventId))
            if(-not $related -and $rightStart -lt $leftEnd -and $leftStart -lt $rightEnd){[void]$failures.Add("ILLEGAL_EVENT_OVERLAP:$($left.eventId):$($right.eventId)")}
        }
    }
    $reconciled = [Math]::Round(([double]$breakdown.activeExecutionMs+[double]$breakdown.userWaitMs+[double]$breakdown.externalInterruptionMs),3)
    $delta = [Math]::Abs([double]$breakdown.wallClockMs-$reconciled)
    if ($delta -gt $ToleranceMilliseconds) { [void]$failures.Add("TIMING_INCONSISTENCY:wall=$($breakdown.wallClockMs):components=$reconciled:delta=$delta") }
    $status = if ($failures.Count) { 'FAIL' } elseif ($warnings.Count) { 'WARN' } else { 'PASS' }
    return [pscustomobject][ordered]@{ schemaVersion=1; status=$status; toleranceMilliseconds=$ToleranceMilliseconds; wallClockMs=$breakdown.wallClockMs; activeExecutionMs=$breakdown.activeExecutionMs; userWaitMs=$breakdown.userWaitMs; externalInterruptionMs=$breakdown.externalInterruptionMs; reconciliationDeltaMs=$delta; failures=$failures.ToArray(); warnings=$warnings.ToArray(); attributionCoveragePct=$breakdown.attributionCoveragePct }
}

Export-ModuleMember -Function Resolve-DeveloperLedgerPath,Start-DeveloperEvent,Stop-DeveloperEvent,Add-DeveloperInstantEvent,Read-DeveloperEventLedger,Get-DeveloperRuntimeBreakdownData,Test-DeveloperTimingConsistencyData
