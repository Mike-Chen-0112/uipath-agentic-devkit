[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$resolver = Join-Path $root 'scripts\Resolve-DevKitTool.ps1'
$invoker = Join-Path $root 'scripts\Invoke-DevKitCommand.ps1'
$testRoot = Join-Path $env:TEMP ('rpa-tool-resolution-tests-' + [guid]::NewGuid().ToString('N'))
$savedEnvironment = @{
    LOCALAPPDATA = $env:LOCALAPPDATA
    APPDATA = $env:APPDATA
    USERPROFILE = $env:USERPROFILE
    ProgramFiles = $env:ProgramFiles
    PATH = $env:PATH
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Write-Text {
    param([string]$Path, [string]$Value, [switch]$Ascii)
    New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null
    if ($Ascii) { [System.IO.File]::WriteAllText($Path, $Value, [System.Text.Encoding]::ASCII) }
    else { [System.IO.File]::WriteAllText($Path, $Value, (New-Object System.Text.UTF8Encoding($false))) }
}

function New-ToolFile {
    param([string]$Path)
    $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($extension -eq '.exe') { Copy-Item -LiteralPath $env:ComSpec -Destination $Path -Force; return }
    if ($extension -eq '.cmd') { Write-Text $Path "@echo off`r`necho cmd:%1`r`nexit /b 0`r`n" -Ascii; return }
    if ($extension -eq '.bat') { Write-Text $Path "@echo off`r`necho bat:%1`r`nexit /b 0`r`n" -Ascii; return }
    if ($extension -eq '.ps1') { Write-Text $Path 'param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments); "ps1:$($Arguments -join '','')"; exit 0' }
}

function Reset-Scenario {
    param([string]$Name)
    $scenario = Join-Path $testRoot $Name
    $bot = Join-Path $scenario 'bot'
    $local = Join-Path $scenario 'local'
    $app = Join-Path $scenario 'app'
    $profile = Join-Path $scenario 'profile'
    $programs = Join-Path $scenario 'programs'
    $pathBin = Join-Path $scenario 'path-bin'
    New-Item -ItemType Directory -Force -Path $bot,$local,$app,$profile,$programs,$pathBin | Out-Null
    $env:LOCALAPPDATA = $local
    $env:APPDATA = $app
    $env:USERPROFILE = $profile
    $env:ProgramFiles = $programs
    $env:PATH = $pathBin
    return [pscustomobject]@{
        bot = $bot
        preferred = Join-Path $local 'RpaAiDevKit\tools\npm'
        pathBin = $pathBin
        statePath = Join-Path $bot '.rpa-ai\local\tool-paths.json'
    }
}

try {
    New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
    . $resolver

    $multi = Reset-Scenario 'multiple'
    New-Item -ItemType Directory -Force -Path $multi.preferred | Out-Null
    foreach ($extension in @('.exe','.cmd','.bat','.ps1')) { New-ToolFile (Join-Path $multi.preferred "uip$extension") }
    $resolved = Resolve-DevKitTool -Name uip -TargetBotPath $multi.bot -Required
    Assert-True ($resolved -eq (Join-Path $multi.preferred 'uip.exe')) 'Multiple candidates did not deterministically prefer .exe.'
    $exeResult = & $invoker -FilePath $resolved -ArgumentList @('/c','echo','exe') -WorkingDirectory $multi.bot -TargetBotPath $multi.bot -Json | ConvertFrom-Json
    Assert-True ($exeResult.status -eq 'PASS' -and $exeResult.launcher -eq 'direct') '.exe launchability failed.'

    Remove-Item -LiteralPath (Join-Path $multi.preferred 'uip.exe') -Force
    Remove-Item -LiteralPath $multi.statePath -Force
    $cmd = Resolve-DevKitTool -Name uip -TargetBotPath $multi.bot -Required
    Assert-True ([System.IO.Path]::GetExtension($cmd) -eq '.cmd') '.cmd precedence failed.'
    Assert-True ((& $invoker -FilePath $cmd -ArgumentList @('probe') -WorkingDirectory $multi.bot -TargetBotPath $multi.bot -Json | ConvertFrom-Json).status -eq 'PASS') '.cmd launchability failed.'

    Remove-Item -LiteralPath (Join-Path $multi.preferred 'uip.cmd') -Force
    Remove-Item -LiteralPath $multi.statePath -Force
    $bat = Resolve-DevKitTool -Name uip -TargetBotPath $multi.bot -Required
    Assert-True ([System.IO.Path]::GetExtension($bat) -eq '.bat') '.bat precedence failed.'
    Assert-True ((& $invoker -FilePath $bat -ArgumentList @('probe') -WorkingDirectory $multi.bot -TargetBotPath $multi.bot -Json | ConvertFrom-Json).status -eq 'PASS') '.bat launchability failed.'

    Remove-Item -LiteralPath (Join-Path $multi.preferred 'uip.bat') -Force
    Remove-Item -LiteralPath $multi.statePath -Force
    $ps1 = Resolve-DevKitTool -Name uip -TargetBotPath $multi.bot -Required
    $ps1Result = & $invoker -FilePath $ps1 -ArgumentList @('probe') -WorkingDirectory $multi.bot -TargetBotPath $multi.bot -Json | ConvertFrom-Json
    Assert-True ([System.IO.Path]::GetExtension($ps1) -eq '.ps1' -and $ps1Result.status -eq 'PASS' -and $ps1Result.launcher -eq 'PowerShell host') '.ps1 was not launched through PowerShell.'

    $argumentProbe = Join-Path $testRoot 'argument transport with spaces'
    $receiver = Join-Path $argumentProbe 'receive-arguments.ps1'
    $shim = Join-Path $argumentProbe 'receive-arguments.cmd'
    $powerShellHost = (Get-Process -Id $PID).Path
    Write-Text $receiver 'param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Values); ConvertTo-Json -InputObject @($Values) -Compress'
    Write-Text $shim "@echo off`r`n`"$powerShellHost`" -NoLogo -NoProfile -File `"%~dp0receive-arguments.ps1`" %*`r`nexit /b %ERRORLEVEL%`r`n" -Ascii
    $refs = ConvertTo-Json -InputObject @([ordered]@{ ref = '0'; outputFile = 'C:\Test and Benchmark\window.xaml' }) -Compress
    $expectedArguments = @($refs, 'Sample files', 'quote"inside', 'C:\path with spaces\', 'plain')
    foreach ($form in @('native','ps1','cmd')) {
        $file = switch ($form) { 'native' { $powerShellHost }; 'ps1' { $receiver }; 'cmd' { $shim } }
        $arguments = if ($form -eq 'native') { @('-NoLogo','-NoProfile','-File',$receiver) + $expectedArguments } else { $expectedArguments }
        $result = & $invoker -FilePath $file -ArgumentList $arguments -WorkingDirectory $argumentProbe -TargetBotPath $multi.bot -Json | ConvertFrom-Json
        Assert-True ($result.status -eq 'PASS') "$form argument receiver failed."
        $received = ConvertFrom-Json -InputObject $result.output
        Assert-True ($received.Count -eq $expectedArguments.Count) "$form changed the argument count."
        for ($index = 0; $index -lt $expectedArguments.Count; $index++) {
            Assert-True ($received[$index] -ceq $expectedArguments[$index]) "$form changed argument $index."
        }
    }

    $invalidSaved = Reset-Scenario 'invalid-saved'
    New-ToolFile (Join-Path $invalidSaved.pathBin 'uip.cmd')
    Write-Text $invalidSaved.statePath '{"uip":"C:\\missing\\uip.exe"}'
    Assert-True ((Resolve-DevKitTool -Name uip -TargetBotPath $invalidSaved.bot -Required) -eq (Join-Path $invalidSaved.pathBin 'uip.cmd')) 'Invalid saved path did not fall through to a valid candidate.'

    $managedPreferred = Reset-Scenario 'managed-preferred'
    New-Item -ItemType Directory -Force -Path $managedPreferred.preferred | Out-Null
    $staleCachedPath = Join-Path $testRoot 'stale-cache\uip.cmd'
    New-ToolFile $staleCachedPath
    New-ToolFile (Join-Path $managedPreferred.preferred 'uip.cmd')
    Write-Text $managedPreferred.statePath (([ordered]@{ uip = $staleCachedPath } | ConvertTo-Json -Compress))
    Assert-True ((Resolve-DevKitTool -Name uip -TargetBotPath $managedPreferred.bot -Required) -eq (Join-Path $managedPreferred.preferred 'uip.cmd')) 'Managed preferred CLI did not supersede a stale cached path.'

    $missingPreferred = Reset-Scenario 'missing-preferred'
    New-ToolFile (Join-Path $missingPreferred.pathBin 'uip.cmd')
    Assert-True (-not (Test-Path $missingPreferred.preferred) -and (Resolve-DevKitTool -Name uip -TargetBotPath $missingPreferred.bot -Required) -eq (Join-Path $missingPreferred.pathBin 'uip.cmd')) 'Missing preferred directory blocked PATH discovery.'

    $emptyPreferred = Reset-Scenario 'empty-preferred'
    New-Item -ItemType Directory -Force -Path $emptyPreferred.preferred | Out-Null
    New-ToolFile (Join-Path $emptyPreferred.pathBin 'uip.bat')
    Assert-True ((Resolve-DevKitTool -Name uip -TargetBotPath $emptyPreferred.bot -Required) -eq (Join-Path $emptyPreferred.pathBin 'uip.bat')) 'Empty preferred directory blocked a later valid candidate.'

    $custom = Reset-Scenario 'custom'
    $customPath = Join-Path $testRoot 'custom-tool\uip.bat'
    New-ToolFile $customPath
    New-ToolFile (Join-Path $custom.pathBin 'uip.cmd')
    Write-Text $custom.statePath (([ordered]@{ uip = $customPath } | ConvertTo-Json -Compress))
    Assert-True ((Resolve-DevKitTool -Name uip -TargetBotPath $custom.bot -Required) -eq $customPath) 'Valid custom tool path was not preserved.'

    $none = Reset-Scenario 'none'
    $requiredFailure = ''
    try { Resolve-DevKitTool -Name uip -TargetBotPath $none.bot -Required | Out-Null }
    catch { $requiredFailure = $_.Exception.Message }
    Assert-True ($requiredFailure -match 'no launchable' -and $requiredFailure -match 'Attempted:') 'No-candidate error did not identify attempted launchable forms.'

    Write-Host '[PASS] UiPath CLI resolution and launchability tests'
}
finally {
    foreach ($key in $savedEnvironment.Keys) { Set-Item -Path "env:$key" -Value $savedEnvironment[$key] }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
