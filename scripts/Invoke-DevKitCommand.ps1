[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$FilePath,
    [string[]]$ArgumentList = @(),
    [string]$WorkingDirectory = (Get-Location).Path,
    [string]$Operation = 'command',
    [string]$TargetBotPath = (Get-Location).Path,
    [string]$ExecutionStatePath,
    [ValidateSet('SCAFFOLDING','PACKAGE','UIA','UI_TARGET','OBJECT_REPOSITORY','SOURCE_READ','SOURCE_EDIT','SOURCE_REPAIR','MAPPER','GRAPHIFY','VALIDATION','EVIDENCE','STATE','FINALIZATION','UNKNOWN')]
    [string]$Category = 'UNKNOWN',
    [string]$Subcategory = '',
    [string]$ParentEventId = '',
    [int]$TimeoutSeconds = 1800,
    [switch]$SideEffecting,
    [switch]$DoNotTerminateOnTimeout,
    [switch]$SkipRuntimeSelection,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$TargetBotPath = (Resolve-Path $TargetBotPath).Path
$WorkingDirectory = (Resolve-Path $WorkingDirectory).Path
$ExecutionStatePath = if ($ExecutionStatePath) { $ExecutionStatePath } else { Join-Path $TargetBotPath '.ai\evidence\execution-state.json' }
$stateScript = Join-Path $PSScriptRoot 'ExecutionState.ps1'
$telemetryModule = Join-Path $PSScriptRoot 'DeveloperTelemetry.psm1'
$hasState = $false
if ((Test-Path $stateScript -PathType Leaf) -and (Test-Path $ExecutionStatePath -PathType Leaf)) {
    try {
        $existingState = [System.IO.File]::ReadAllText($ExecutionStatePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        $hasState = $existingState.schema_version -in @(2,3) -and [string]$existingState.execution.status -in @('RUNNING','PAUSED')
    } catch { $hasState = $false }
}

function ConvertTo-WindowsArgument {
    param([string]$Value)
    if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Stop-OwnedProcessTree {
    param([int]$RootPid)
    $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $children = @{}
    foreach ($item in $all) {
        $parent = [int]$item.ParentProcessId
        if (-not $children.ContainsKey($parent)) { $children[$parent] = @() }
        $children[$parent] += [int]$item.ProcessId
    }
    $ids = New-Object System.Collections.Generic.List[int]
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($RootPid)
    while ($queue.Count -gt 0) {
        $id = [int]$queue.Dequeue()
        $ids.Add($id)
        if ($children.ContainsKey($id)) { foreach ($child in $children[$id]) { $queue.Enqueue($child) } }
    }
    foreach ($id in ($ids | Sort-Object -Descending)) {
        Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
    }
}

function Resolve-CommandCategory {
    if ($Category -ne 'UNKNOWN') { return $Category }
    $tokens = ((@($ArgumentList) + @($Operation,$FilePath)) -join ' ').ToLowerInvariant()
    if ($tokens -match '(^|\s)uia(\s|$)') { return 'UIA' }
    if ($tokens -match 'get-errors|\bbuild\b|\banalyze\b|changedworkflow|validation') { return 'VALIDATION' }
    if ($tokens -match '\brestore\b|package|dependenc') { return 'PACKAGE' }
    if ($tokens -match 'projectmap|project map|mapper') { return 'MAPPER' }
    if ($tokens -match 'graphify|botgraph') { return 'GRAPHIFY' }
    if ($tokens -match 'scaffold|create-project|new-rpaproject') { return 'SCAFFOLDING' }
    if ($tokens -match 'target') { return 'UI_TARGET' }
    return 'UNKNOWN'
}
$eventCategory = Resolve-CommandCategory
if($SkipRuntimeSelection -and ($eventCategory -ne 'PACKAGE' -or $Subcategory -notin @('runtime-probe','runtime-install','compiler-probe'))){
    throw 'Runtime selection bypass is restricted to explicit runtime readiness operations.'
}

$commandId = $null
$commandOutputPath = ''

$started = [DateTime]::UtcNow
$stdout = ''
$stderr = ''
$exitCode = -1
$timedOut = $false
$ownedProcessId = $null
$process = New-Object System.Diagnostics.Process
$process.StartInfo = New-Object System.Diagnostics.ProcessStartInfo
$invocationFile = $FilePath
$invocationArguments = @($ArgumentList)
$launcher = 'direct'
if ([System.IO.Path]::GetExtension($FilePath).ToLowerInvariant() -eq '.ps1') {
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { throw "PowerShell command script was not found: $FilePath" }
    $powerShellHost = (Get-Process -Id $PID -ErrorAction Stop).Path
    if (-not $powerShellHost) { throw "PowerShell host could not be resolved for script command: $FilePath" }
    $invocationFile = $powerShellHost
    $invocationArguments = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$FilePath) + @($ArgumentList)
    $launcher = 'PowerShell host'
}

$process.StartInfo.FileName = $invocationFile
$process.StartInfo.Arguments = (($invocationArguments | ForEach-Object { ConvertTo-WindowsArgument ([string]$_) }) -join ' ')
$process.StartInfo.WorkingDirectory = $WorkingDirectory
$process.StartInfo.UseShellExecute = $false
$process.StartInfo.CreateNoWindow = $true
$process.StartInfo.RedirectStandardOutput = $true
$process.StartInfo.RedirectStandardError = $true
if(-not $SkipRuntimeSelection){
    $runtimeRecord=Join-Path $TargetBotPath '.rpa-ai\local\dotnet-runtime.json'
    if(Test-Path -LiteralPath $runtimeRecord -PathType Leaf){
        $runtime=[IO.File]::ReadAllText($runtimeRecord,[Text.Encoding]::UTF8)|ConvertFrom-Json
        if($runtime.status -ne 'PASS' -or $runtime.architecture -notin @('x64','x86','arm64')){
            throw 'BLOCKED_DEPENDENCY: recorded .NET runtime is not verified; run .rpa-ai\scripts\Initialize-UiPathRuntime.ps1 to repair it.'
        }
        foreach($artifact in @(@{path=$runtime.dotnetPath;sha256=$runtime.dotnetSha256})+@($runtime.runtimeConfigSources)){
            if(-not $artifact.path -or -not [IO.Path]::IsPathRooted([string]$artifact.path) -or
                -not (Test-Path -LiteralPath $artifact.path -PathType Leaf) -or
                (Get-FileHash -LiteralPath $artifact.path -Algorithm SHA256).Hash -ne $artifact.sha256){
                throw 'BLOCKED_DEPENDENCY: stale .NET runtime selection; reverify the compiler runtime and host.'
            }
        }
        if(-not @($runtime.runtimeConfigSources).Count -or
            [IO.Path]::GetDirectoryName([string]$runtime.dotnetPath) -ne [string]$runtime.dotnetRoot){
            throw 'BLOCKED_DEPENDENCY: incomplete .NET runtime selection.'
        }
        $process.StartInfo.EnvironmentVariables['DOTNET_ROOT']=[string]$runtime.dotnetRoot
        $process.StartInfo.EnvironmentVariables[('DOTNET_ROOT_'+([string]$runtime.architecture).ToUpperInvariant())]=[string]$runtime.dotnetRoot
    }
}
$started = [DateTime]::UtcNow
if ($hasState) {
    $startResult = & $stateScript -Action CommandStart -Operation $Operation -Category $eventCategory -Subcategory $Subcategory -TargetBotPath $TargetBotPath -StatePath $ExecutionStatePath -Json | ConvertFrom-Json
    $commandId = [string]$startResult.command_id
    $commandOutputPath = Join-Path $TargetBotPath ".ai\evidence\commands\$commandId.log"
    New-Item -ItemType Directory -Force -Path (Split-Path $commandOutputPath -Parent) | Out-Null
}
$eventId = $null
if ($hasState -and (Test-Path -LiteralPath $telemetryModule -PathType Leaf)) {
    Import-Module $telemetryModule -Force
    $event = Start-DeveloperEvent -ProjectPath $TargetBotPath -Category $eventCategory -Subcategory $Subcategory -Operation $Operation -ParentEventId $ParentEventId -CommandType 'SUBPROCESS'
    $eventId = [string]$event.eventId
}
try {
    if (-not $process.Start()) { throw "Unable to start $Operation." }
    $ownedProcessId = [int]$process.Id
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit([Math]::Max(1, $TimeoutSeconds) * 1000)) {
        $timedOut = $true
        if (-not $SideEffecting -and -not $DoNotTerminateOnTimeout) { Stop-OwnedProcessTree $process.Id; [void]$process.WaitForExit(5000) }
    }
    if ($timedOut) {
        if ($stdoutTask.Wait(1000)) { $stdout = $stdoutTask.Result } else { $stdout = '[stdout unavailable before timeout]' }
        if ($stderrTask.Wait(1000)) { $stderr = $stderrTask.Result } else { $stderr = '[stderr unavailable before timeout]' }
    } else {
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
    }
    if (-not $timedOut) { $exitCode = $process.ExitCode }
} finally {
    $ended = [DateTime]::UtcNow
    $duration = [Math]::Round(($ended - $started).TotalSeconds, 3)
    $combinedOutput = (($stdout + "`n" + $stderr).Trim())
    if ($commandOutputPath) {
        [System.IO.File]::WriteAllText($commandOutputPath, $combinedOutput + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
    }
    $artifactReferences = @()
    if ($commandOutputPath -and (Test-Path -LiteralPath $commandOutputPath -PathType Leaf)) {
        $outputItem = Get-Item -LiteralPath $commandOutputPath
        $artifactReferences += [ordered]@{ path = $commandOutputPath.Substring($TargetBotPath.TrimEnd('\','/').Length).TrimStart('\','/') -replace '\\','/'; bytes = [int64]$outputItem.Length; sha256 = (Get-FileHash -LiteralPath $commandOutputPath -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    if ($eventId) {
        $eventStatus = if ($timedOut) { 'TIMEOUT' } elseif ($exitCode -eq 0) { 'PASS' } else { 'FAIL' }
        Stop-DeveloperEvent -ProjectPath $TargetBotPath -EventId $eventId -Status $eventStatus -ExitCode $exitCode -TimedOut:$timedOut -ProcessId $ownedProcessId -Artifacts $artifactReferences | Out-Null
    }
    if ($hasState -and $commandId) {
        & $stateScript -Action CommandEnd -CommandId $commandId -ProcessId $(if($ownedProcessId){$ownedProcessId}else{0}) -ExitCode $exitCode -DurationSeconds $duration -TimedOut:$timedOut -CommandOutput $combinedOutput -CommandOutputPath $commandOutputPath -TargetBotPath $TargetBotPath -StatePath $ExecutionStatePath -Json | Out-Null
    }
    $process.Dispose()
}

$result = [ordered]@{
    operation = $Operation
    file = $FilePath
    arguments = @($ArgumentList)
    launcher = $launcher
    invocation_file = $invocationFile
    event_id = $eventId
    category = $eventCategory
    pid = $ownedProcessId
    started_at_utc = $started.ToString('o')
    ended_at_utc = $ended.ToString('o')
    duration_seconds = $duration
    exit_code = $exitCode
    timed_out = $timedOut
    side_effecting = [bool]$SideEffecting
    output = $stdout
    error = $stderr
    output_path = $commandOutputPath
    output_sha256 = if ($commandOutputPath -and (Test-Path -LiteralPath $commandOutputPath -PathType Leaf)) { (Get-FileHash -LiteralPath $commandOutputPath -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
    status = if ($timedOut) { 'TIMEOUT' } elseif ($exitCode -eq 0) { 'PASS' } else { 'FAIL' }
}
if ($Json) { $result | ConvertTo-Json -Depth 8; return } else {
    Write-Host "COMMAND_STATUS=$($result.status)"
    Write-Host "COMMAND_DURATION_SECONDS=$duration"
    if ($stdout) { Write-Output $stdout }
    if ($stderr) { [Console]::Error.WriteLine($stderr) }
}
if ($timedOut) { throw "$Operation timed out after $TimeoutSeconds seconds." }
if ($exitCode -ne 0) { throw "$Operation failed with exit code $exitCode." }
