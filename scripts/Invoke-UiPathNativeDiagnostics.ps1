[CmdletBinding()]
param(
    [string]$ProjectPath=(Get-Location).Path,
    [string[]]$ChangedWorkflow=@(),
    [ValidateSet('get-errors','validate')][string]$CommandKind='get-errors',
    [string]$UiPathCommand='uip',
    [string]$ExecutionStatePath,
    [string]$DependencyFingerprint='UNKNOWN',
    [string]$EnvironmentFingerprint='UNKNOWN',
    [string]$ParentEventId='',
    [string]$PolicyVersion='1.0',
    [string]$ProjectFingerprint='',
    [string]$PreviousEvidencePath,
    [string]$OutputPath='.ai/evidence/uipath-native-diagnostics.json',
    [int]$TimeoutSeconds=300,
    [switch]$Json
)
$ErrorActionPreference='Stop'
$started=[DateTime]::UtcNow
$root=(Resolve-Path -LiteralPath $ProjectPath).Path;$prefix=$root.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
$commandScript=Join-Path $PSScriptRoot 'Invoke-DevKitCommand.ps1';$parserScript=Join-Path $PSScriptRoot 'ConvertFrom-UiPathDiagnostics.ps1'
foreach($required in @($commandScript,$parserScript)){if(-not(Test-Path -LiteralPath $required -PathType Leaf)){throw "Native diagnostics helper missing: $required"}}
$statePath=if($ExecutionStatePath){[IO.Path]::GetFullPath($ExecutionStatePath)}else{Join-Path $root '.ai\evidence\execution-state.json'}
$fullOutput=if([IO.Path]::IsPathRooted($OutputPath)){[IO.Path]::GetFullPath($OutputPath)}else{[IO.Path]::GetFullPath((Join-Path $root ($OutputPath -replace '/','\')))}
$previous=$null
foreach($candidate in @($PreviousEvidencePath,$fullOutput)){
    if($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)){try{$previous=[IO.File]::ReadAllText($candidate,[Text.Encoding]::UTF8)|ConvertFrom-Json;break}catch{}}
}
$parserFingerprint=(Get-FileHash -LiteralPath $parserScript -Algorithm SHA256).Hash
$cliPath=if(Test-Path -LiteralPath $UiPathCommand -PathType Leaf){(Resolve-Path -LiteralPath $UiPathCommand).Path}else{$UiPathCommand}
$cliFingerprint=if(Test-Path -LiteralPath $cliPath -PathType Leaf){(Get-FileHash -LiteralPath $cliPath -Algorithm SHA256).Hash}else{'UNKNOWN'}
$scopeFingerprint=$ProjectFingerprint
if(-not $scopeFingerprint){$scopeFingerprint=[string]((& (Join-Path $PSScriptRoot 'SourceFingerprint.ps1') -ProjectPath $root -Json | ConvertFrom-Json).sourceFingerprint)}
$previousAttempts=if($previous){@($previous.attempts)}else{@()}
$attempts=New-Object Collections.Generic.List[object];foreach($item in $previousAttempts){[void]$attempts.Add($item)}
$results=New-Object Collections.Generic.List[object]
$targets=if(@($ChangedWorkflow).Count){@($ChangedWorkflow|Select-Object -Unique)}else{@('')}
$executed=0;$reused=0;$totalDurationMs=0.0;$totalErrors=0;$blockedReason=$null
foreach($workflowInput in $targets){
    $full=$null;$relative='<project>';$sourceHash=$ProjectFingerprint
    if(-not $sourceHash){
        $fingerprintScript=Join-Path $PSScriptRoot 'SourceFingerprint.ps1'
        if(Test-Path -LiteralPath $fingerprintScript -PathType Leaf){$sourceHash=[string]((& $fingerprintScript -ProjectPath $root -Json|ConvertFrom-Json).sourceFingerprint)}else{$sourceHash='UNKNOWN_PROJECT_SCOPE'}
    }
    if($workflowInput){
        $full=if([IO.Path]::IsPathRooted($workflowInput)){[IO.Path]::GetFullPath($workflowInput)}else{[IO.Path]::GetFullPath((Join-Path $root ($workflowInput -replace '/','\')))}
        if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw "Changed workflow must stay within project: $workflowInput"}
        if(-not(Test-Path -LiteralPath $full -PathType Leaf)){throw "Changed workflow not found: $workflowInput"}
        $relative=$full.Substring($prefix.Length) -replace '\\','/';$sourceHash=(Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $reuseKey="$CommandKind|$sourceHash|$scopeFingerprint|$DependencyFingerprint|$EnvironmentFingerprint|$PolicyVersion|$parserFingerprint|$cliPath|$cliFingerprint"
    $priorPass=@($previousAttempts|Where-Object {$_.workflow -eq $relative -and $_.reuseKey -eq $reuseKey -and $_.status -eq 'PASS'}|Select-Object -Last 1)
    if($priorPass.Count){$reused++;[void]$results.Add([ordered]@{workflow=$relative;status='REUSED';sourceHash=$sourceHash;reuseKey=$reuseKey;errorCount=0;durationMs=0;reason='Matching workflow, dependency, environment, and validation-policy evidence.'});continue}
    $priorFailure=@($previousAttempts|Where-Object {$_.workflow -eq $relative -and $_.reuseKey -eq $reuseKey -and $_.status -eq 'FAIL'}|Select-Object -Last 1)
    if($priorFailure.Count){
        $blockedReason='UNCHANGED_XAML_REPEATED_DIAGNOSTIC';$totalErrors+=[int]$priorFailure[0].errorCount;[void]$results.Add([ordered]@{workflow=$relative;status='BLOCKED';sourceHash=$sourceHash;reuseKey=$reuseKey;errorCount=[int]$priorFailure[0].errorCount;durationMs=0;diagnosticFingerprint=[string]$priorFailure[0].diagnosticFingerprint;reason=$blockedReason});continue
    }
    $args=@('rpa',$CommandKind);if($workflowInput){$args+=@('--file-path',$relative)};$args+=@('--project-dir',$root)
    if($CommandKind -eq 'get-errors'){$args+=@('--min-severity','error')}
    $args+=@('--output','json')
    $command=& $commandScript -FilePath $UiPathCommand -ArgumentList $args -WorkingDirectory $root -TargetBotPath $root -ExecutionStatePath $statePath -Operation "uipath.workflow.$CommandKind" -Category VALIDATION -Subcategory "workflow.$CommandKind" -ParentEventId $ParentEventId -TimeoutSeconds $TimeoutSeconds -Json|ConvertFrom-Json
    $executed++;$totalDurationMs+=[double]$command.duration_seconds*1000
    $text=([string]$command.output)+[Environment]::NewLine+([string]$command.error)
    $parsed=& $parserScript -InputText $text -Workflow $relative -Json|ConvertFrom-Json
    $totalErrors+=[int]$parsed.errorCount
    $status=if([int]$parsed.errorCount -gt 0){'FAIL'}elseif([string]$command.status -ne 'PASS' -or -not [bool]$parsed.contentParsed){'BLOCKED'}else{'PASS'}
    if($status -eq 'BLOCKED' -and -not $blockedReason){$blockedReason=if(-not [bool]$parsed.contentParsed){"$CommandKind`_UNRECOGNIZED_OUTPUT"}else{"$CommandKind`_$($command.status)"}}
    $attempt=[ordered]@{attemptId=[guid]::NewGuid().ToString('N');workflow=$relative;sourceHash=$sourceHash;reuseKey=$reuseKey;dependencyFingerprint=$DependencyFingerprint;environmentFingerprint=$EnvironmentFingerprint;policyVersion=$PolicyVersion;startedAtUtc=[string]$command.started_at_utc;endedAtUtc=[string]$command.ended_at_utc;durationMs=[Math]::Round([double]$command.duration_seconds*1000,3);processStatus=[string]$command.status;exitCode=[int]$command.exit_code;timedOut=[bool]$command.timed_out;status=$status;errorCount=[int]$parsed.errorCount;diagnosticFingerprint=[string]$parsed.diagnosticFingerprint;diagnostics=@($parsed.diagnostics);outputPath=[string]$command.output_path;outputSha256=[string]$command.output_sha256}
    [void]$attempts.Add($attempt);[void]$results.Add($attempt)
}
$repairTotal=0
foreach($successful in @($attempts|Where-Object {[string]$_.status -eq 'PASS'})){
    $priorFailure=@($attempts|Where-Object {[string]$_.workflow -eq [string]$successful.workflow -and [string]$_.status -eq 'FAIL' -and [string]$_.sourceHash -ne [string]$successful.sourceHash}|Select-Object -First 1)
    if($priorFailure.Count){$repairTotal++}
}
$overall=if(@($results|Where-Object status -eq 'FAIL').Count){'FAIL'}elseif(@($results|Where-Object status -eq 'BLOCKED').Count){'BLOCKED'}else{'PASS'}
$result=[ordered]@{schemaVersion=1;commandKind=$CommandKind;status=$overall;getErrorsRequired=$true;getErrorsExecuted=$executed -gt 0;getErrorsReuse=$reused;getErrorsReason=if($blockedReason){$blockedReason}else{'NATIVE_WORKFLOW_VALIDATION'};getErrorsDurationMs=[Math]::Round($totalDurationMs,3);getErrorsErrorCount=$totalErrors;getErrorsRepairCount=$repairTotal;nativeValidationTotalMs=[Math]::Round(([DateTime]::UtcNow-$started).TotalMilliseconds,3);workflows=$results.ToArray();attempts=$attempts.ToArray();createdAtUtc=[DateTime]::UtcNow.ToString('o')}
New-Item -ItemType Directory -Force -Path (Split-Path $fullOutput -Parent)|Out-Null;[IO.File]::WriteAllText($fullOutput,(($result|ConvertTo-Json -Depth 15)+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))
if($Json){$result|ConvertTo-Json -Depth 15}else{[pscustomobject]$result}
