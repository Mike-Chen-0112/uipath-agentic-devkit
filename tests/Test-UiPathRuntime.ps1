[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\Initialize-UiPathRuntime.ps1')

$originalEnvironment = @{}
foreach ($key in @('DOTNET_ROOT','DOTNET_ROOT_X64','DOTNET_ROOT_X86','DOTNET_ROOT_ARM64')) {
    $originalEnvironment[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
}
$suite = Join-Path $env:LOCALAPPDATA ('RpaAiDevKit-runtime-test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $suite
$script:passed = 0

function Assert-RuntimeTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERTION_FAILED: $Message" }
}
function New-TestPe {
    param([string]$Path, [string]$Architecture = 'x64')
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force
    $bytes = New-Object byte[] 256
    $bytes[0] = 0x4d; $bytes[1] = 0x5a; $bytes[0x3c] = 0x80
    $bytes[0x80] = 0x50; $bytes[0x81] = 0x45
    $machine = switch ($Architecture) { 'x64' { 0x8664 }; 'x86' { 0x014c }; 'arm64' { 0xaa64 } }
    [BitConverter]::GetBytes([uint16]$machine).CopyTo($bytes, 0x84)
    [IO.File]::WriteAllBytes($Path, $bytes)
}
function New-TestConfig {
    param([string]$Name = 'compiler', [string]$Version = '10.0.0',
          [string]$Framework = 'Microsoft.NETCore.App', [string]$RollForward = 'Minor')
    $path = Join-Path $script:case "$Name.runtimeconfig.json"
    $config = @{ runtimeOptions = @{ framework = @{ name = $Framework; version = $Version }; rollForward = $RollForward } }
    [IO.File]::WriteAllText($path, ($config | ConvertTo-Json -Depth 5))
    return $path
}
function Invoke-Case {
    param([string]$Name, [scriptblock]$Body)
    $script:case = Join-Path $suite $Name
    $null = New-Item -ItemType Directory -Path $script:case
    $script:hostPath = Join-Path $script:case 'existing\dotnet.exe'
    New-TestPe $script:hostPath
    $script:config = New-TestConfig
    $script:runtimeOutput = 'Microsoft.NETCore.App 10.0.2 [C:\verified\shared\Microsoft.NETCore.App]'
    $script:runtimeError = ''
    $script:runtimeExit = 0
    $script:installFails = $false
    $script:badHash = $false
    $script:badUrl = $false
    $script:compilerFails = $false
    $script:installCalls = 0
    $script:downloadCalls = 0
    $script:probeCalls = 0
    $script:installedPath = $null
    $script:allCommands = @()
    & $Body
    $script:passed++
    Write-Host "PASS $Name"
}
function Invoke-Readiness {
    param([switch]$ApprovedInstall)
    Initialize-UiPathRuntime -RuntimeConfigPath $script:config -Architecture x64 `
        -DotnetPath $script:hostPath -TargetBotPath $script:case `
        -InstallDirectory (Join-Path $script:case 'installed') -ApprovedInstall:$ApprovedInstall
}

# Function mocking, not production injection flags. The real parser, PE inspection,
# metadata selection, archive hashing/extraction, environment and evidence code run.
function Invoke-UiPathRuntimeCommand {
    param([string]$FilePath, [string[]]$Arguments, [string]$BotPath,
          [string]$Subcategory, [int]$Timeout, [bool]$SideEffecting = $false)
    Assert-RuntimeTest ($Timeout -gt 0) 'all subprocesses have a timeout'
    $script:allCommands += $Subcategory
    if ($Subcategory -eq 'runtime-install') {
        $script:installCalls++
        Assert-RuntimeTest $SideEffecting 'installer marked side-effecting'
        if ($script:installFails) { return @{ status = 'FAIL'; exit_code = 5; timed_out = $false; output = ''; error = '' } }
        $worker = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Arguments[-1]))
        # Execute only the repository-authored extraction worker, never network code.
        & ([scriptblock]::Create($worker))
        $payloadMatch = [regex]::Match($worker, "FromBase64String\('([^']+)'\)")
        $payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payloadMatch.Groups[1].Value)) | ConvertFrom-Json
        $script:installedPath = Join-Path $payload.root 'dotnet.exe'
        return @{ status = 'PASS'; exit_code = 0; timed_out = $false; output = ''; error = '' }
    }
    if ($Subcategory -eq 'compiler-probe') {
        $script:probeCalls++
        return @{ status = $(if ($script:compilerFails) { 'FAIL' } else { 'PASS' }); exit_code = $(if ($script:compilerFails) { 9 } else { 0 }); timed_out = $false }
    }
    Assert-RuntimeTest ($Subcategory -eq 'runtime-probe') 'specific PACKAGE subcategory'
    Assert-RuntimeTest ($Arguments.Count -eq 1 -and $Arguments[0] -eq '--list-runtimes') 'actual runtime probe command'
    # Ignore unrelated real machine hosts, even if installed on the test machine.
    if ($FilePath -ne $script:hostPath -and $FilePath -ne $script:installedPath) {
        return @{ status = 'PASS'; exit_code = 0; timed_out = $false; output = ''; error = '' }
    }
    $output = $script:runtimeOutput
    if ($FilePath -eq $script:installedPath) { $output = 'Microsoft.NETCore.App 10.0.0 [C:\installed\shared\Microsoft.NETCore.App]' }
    return @{ status = $(if ($script:runtimeExit -eq 0) { 'PASS' } else { 'FAIL' }); exit_code = $script:runtimeExit; timed_out = $false; output = $output; error = $script:runtimeError }
}
function Get-UiPathRuntimeOfficialFile {
    param([string]$Url, [string]$Destination, [int]$Timeout)
    $script:downloadCalls++
    if ($Url -match '/releases.json$') {
        $source = Join-Path $script:case 'archive-source'
        $null = New-Item -ItemType Directory -Path $source -Force
        New-TestPe (Join-Path $source 'dotnet.exe')
        $null = New-Item -ItemType Directory -Path (Join-Path $source 'shared\Microsoft.NETCore.App\10.0.0') -Force
        [IO.File]::WriteAllText((Join-Path $source 'shared\Microsoft.NETCore.App\10.0.0\test.txt'), 'official-fixture')
        $script:archive = Join-Path $script:case 'official.zip'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        if (Test-Path -LiteralPath $script:archive) { Remove-Item -LiteralPath $script:archive }
        [IO.Compression.ZipFile]::CreateFromDirectory($source, $script:archive)
        $hash = (Get-FileHash -LiteralPath $script:archive -Algorithm SHA512).Hash
        if ($script:badHash) { $hash = '0' * 128 }
        $url = 'https://builds.dotnet.microsoft.com/dotnet/Runtime/10.0.0/dotnet-runtime-10.0.0-win-x64.zip'
        $metadata = @{ releases = @(@{ runtime = @{ version = '10.0.0'; files = @(@{ rid = 'win-x64'; url = $url; hash = $hash }) } }) }
        [IO.File]::WriteAllText($Destination, ($metadata | ConvertTo-Json -Depth 8))
    } else {
        Copy-Item -LiteralPath $script:archive -Destination $Destination
    }
}

try {
    Invoke-Case 'existing-compatible-runtime' {
        $r = Invoke-Readiness
        Assert-RuntimeTest ($r.status -eq 'PASS' -and $r.runtimeVerified) 'existing runtime verified'
        Assert-RuntimeTest ($r.compilerProbe.status -eq 'NOT_RUN') 'list-runtimes is not compiler proof'
        Assert-RuntimeTest ($r.installation.status -eq 'NOT_RUN' -and $script:downloadCalls -eq 0) 'no download without need/approval'
        $record = [IO.File]::ReadAllText($r.evidencePath) | ConvertFrom-Json
        Assert-RuntimeTest ($record.environment.DOTNET_ROOT_X64 -eq (Split-Path -Parent $script:hostPath)) 'persist verified arch root'
        Assert-RuntimeTest ($record.dotnetRoot -eq (Split-Path -Parent $script:hostPath) -and $record.dotnetPath -eq $script:hostPath) 'parent integration top-level contract'
        Assert-RuntimeTest ($record.dotnetSha256 -eq (Get-FileHash -LiteralPath $script:hostPath).Hash.ToLowerInvariant()) 'parent host freshness fingerprint'
        Assert-RuntimeTest ($record.runtimeConfigPath -eq $script:config -and $record.runtimeConfigSha256 -eq (Get-FileHash -LiteralPath $script:config).Hash.ToLowerInvariant()) 'parent primary runtimeconfig freshness fields'
        Assert-RuntimeTest ($record.runtimeConfigSources[0].sha256 -eq (Get-FileHash -LiteralPath $script:config).Hash.ToLowerInvariant()) 'actual runtimeconfig fingerprint'
        Assert-RuntimeTest ($env:DOTNET_ROOT_X64 -eq $record.environment.DOTNET_ROOT_X64) 'process environment selected'
        Assert-RuntimeTest ($record.runtime.selectedRuntimes[0].version -eq '10.0.2') 'compatible patch identity recorded'
    }
    Invoke-Case 'net8-not-net10-denied-install' {
        $script:runtimeOutput = 'Microsoft.NETCore.App 8.0.20 [C:\dotnet\shared\Microsoft.NETCore.App]'
        $r = Invoke-Readiness
        Assert-RuntimeTest ($r.status -eq 'BLOCKED' -and -not $r.runtimeVerified) 'NET8 cannot satisfy NET10'
        Assert-RuntimeTest ($r.cause -eq 'REQUIRED_RUNTIME_UNAVAILABLE_INSTALL_NOT_APPROVED') 'explicit denial cause'
        Assert-RuntimeTest ($script:downloadCalls -eq 0 -and $script:installCalls -eq 0) 'no unapproved installation'
    }
    Invoke-Case 'approved-install-retains-existing' {
        $script:runtimeOutput = 'Microsoft.NETCore.App 8.0.20 [C:\dotnet\shared\Microsoft.NETCore.App]'
        $before = (Get-FileHash -LiteralPath $script:hostPath).Hash
        $r = Invoke-Readiness -ApprovedInstall
        Assert-RuntimeTest ($r.status -eq 'PASS' -and $r.installation.status -eq 'PASS') 'approved installation reprobed'
        Assert-RuntimeTest ($script:installCalls -eq 1 -and $script:downloadCalls -eq 2) 'one bounded install'
        Assert-RuntimeTest ((Get-FileHash -LiteralPath $script:hostPath).Hash -eq $before) 'existing host retained'
        Assert-RuntimeTest ($r.runtime.dotnetPath -ne $script:hostPath -and $r.runtime.dotnetPath -eq $script:installedPath) 'new correct host selected'
        Assert-RuntimeTest (@($r.installation.archives).Count -eq 1) 'official archive hash provenance'
    }
    Invoke-Case 'install-failure-no-retry' {
        $script:runtimeOutput = ''
        $script:installFails = $true
        $r = Invoke-Readiness -ApprovedInstall
        Assert-RuntimeTest ($r.status -eq 'BLOCKED' -and $r.installation.status -eq 'FAIL') 'install failure blocked'
        Assert-RuntimeTest ($script:installCalls -eq 1 -and -not $r.runtimeVerified) 'no retry or false proof'
    }
    Invoke-Case 'publisher-hash-failure' {
        $script:runtimeOutput = ''
        $script:badHash = $true
        $r = Invoke-Readiness -ApprovedInstall
        Assert-RuntimeTest ($r.cause -eq 'OFFICIAL_ARCHIVE_HASH_MISMATCH') 'hash mismatch rejected'
        Assert-RuntimeTest ($script:installCalls -eq 0) 'unverified archive never executed'
    }
    Invoke-Case 'missing-runtimeconfig' {
        $script:config = Join-Path $script:case 'missing.json'
        $r = Invoke-Readiness -ApprovedInstall
        Assert-RuntimeTest ($r.cause -eq 'RUNTIMECONFIG_MISSING' -and $script:downloadCalls -eq 0) 'missing actual compiler config blocks'
    }
    Invoke-Case 'unparseable-runtimeconfig' {
        [IO.File]::WriteAllText($script:config, '{broken')
        $r = Invoke-Readiness
        Assert-RuntimeTest ($r.cause -eq 'RUNTIMECONFIG_UNPARSEABLE') 'invalid config blocks'
    }
    Invoke-Case 'no-runtimeconfig' {
        $r = Initialize-UiPathRuntime -TargetBotPath $script:case -Architecture x64
        Assert-RuntimeTest ($r.cause -eq 'RUNTIMECONFIG_REQUIRED') 'no studio-version inference'
    }
    Invoke-Case 'architecture-required' {
        $r = Initialize-UiPathRuntime -RuntimeConfigPath $script:config -TargetBotPath $script:case
        Assert-RuntimeTest ($r.cause -eq 'COMPILER_ARCHITECTURE_REQUIRED') 'architecture not guessed from process'
    }
    Invoke-Case 'wrong-host-architecture' {
        New-TestPe $script:hostPath x86
        $r = Invoke-Readiness
        Assert-RuntimeTest ($r.status -eq 'BLOCKED') 'x86 host not accepted for x64 compiler'
        Assert-RuntimeTest (@($r.hostAttempts | Where-Object { $_.cause -eq 'DOTNET_ARCHITECTURE_MISMATCH' }).Count -gt 0) 'architecture failure evidence'
    }
    Invoke-Case 'compiler-architecture-contradiction' {
        $compiler = Join-Path $script:case 'compiler.exe'
        New-TestPe $compiler x86
        $r = Initialize-UiPathRuntime -RuntimeConfigPath $script:config -CompilerPath $compiler -Architecture x64 -TargetBotPath $script:case
        Assert-RuntimeTest ($r.cause -eq 'COMPILER_ARCHITECTURE_MISMATCH') 'explicit architecture must match compiler'
    }
    Invoke-Case 'x86-architecture-derived' {
        $compiler = Join-Path $script:case 'compiler.exe'
        New-TestPe $compiler x86
        New-TestPe $script:hostPath x86
        $r = Initialize-UiPathRuntime -RuntimeConfigPath $script:config -CompilerPath $compiler `
            -DotnetPath $script:hostPath -TargetBotPath $script:case
        Assert-RuntimeTest ($r.status -eq 'PASS' -and $r.architecture -eq 'x86') 'derive actual compiler PE architecture'
        Assert-RuntimeTest ($r.environment.DOTNET_ROOT_X86 -eq (Split-Path -Parent $script:hostPath)) 'arch-specific x86 environment'
        Assert-RuntimeTest ($r.compilerProbe.status -eq 'NOT_RUN') 'compiler path alone is not a probe'
    }
    Invoke-Case 'arm64-host' {
        New-TestPe $script:hostPath arm64
        $r = Initialize-UiPathRuntime -RuntimeConfigPath $script:config -Architecture arm64 `
            -DotnetPath $script:hostPath -TargetBotPath $script:case
        Assert-RuntimeTest ($r.status -eq 'PASS' -and $r.environment.DOTNET_ROOT_ARM64) 'arm64 verified independently'
    }
    Invoke-Case 'unknown-runtime-output' {
        $script:runtimeOutput = 'A host exists but runtimes are unknown'
        $r = Invoke-Readiness
        Assert-RuntimeTest ($r.status -eq 'BLOCKED') 'unknown output cannot prove runtime'
        Assert-RuntimeTest (@($r.hostAttempts | Where-Object { $_.cause -eq 'RUNTIME_PROBE_OUTPUT_UNKNOWN' }).Count -gt 0) 'unknown-output cause'
    }
    Invoke-Case 'failed-runtime-probe' {
        $script:runtimeExit = 1
        $r = Invoke-Readiness
        Assert-RuntimeTest ($r.status -eq 'BLOCKED') 'exit failure cannot pass from plausible output'
    }
    Invoke-Case 'disable-rollforward' {
        $script:config = New-TestConfig -RollForward Disable
        $r = Invoke-Readiness
        Assert-RuntimeTest ($r.status -eq 'BLOCKED') 'Disable requires exact patch'
        $script:runtimeOutput = 'Microsoft.NETCore.App 10.0.0 [C:\dotnet\shared\Microsoft.NETCore.App]'
        $r = Invoke-Readiness
        Assert-RuntimeTest ($r.status -eq 'PASS') 'Disable accepts exact patch'
    }
    Invoke-Case 'applypatches-false' {
        $config = [IO.File]::ReadAllText($script:config) | ConvertFrom-Json
        $config.runtimeOptions | Add-Member -NotePropertyName applyPatches -NotePropertyValue $false
        [IO.File]::WriteAllText($script:config, ($config | ConvertTo-Json -Depth 5))
        $r = Invoke-Readiness
        Assert-RuntimeTest ($r.status -eq 'BLOCKED') 'applyPatches false conservatively exact'
    }
    Invoke-Case 'unknown-rollforward' {
        $script:config = New-TestConfig -RollForward Unexpected
        $r = Invoke-Readiness
        Assert-RuntimeTest ($r.cause -eq 'UNSUPPORTED_ROLL_FORWARD_POLICY') 'unknown host policy blocked'
    }
    Invoke-Case 'minor-major-not-inferred' {
        $script:runtimeOutput = 'Microsoft.NETCore.App 11.0.0 [C:\dotnet\shared\Microsoft.NETCore.App]'
        $r = Invoke-Readiness
        Assert-RuntimeTest ($r.status -eq 'BLOCKED') 'default Minor never upgraded across major'
    }
    Invoke-Case 'desktop-and-core-frameworks' {
        $desktop = New-TestConfig -Name desktop -Framework Microsoft.WindowsDesktop.App
        $script:runtimeOutput += "`nMicrosoft.WindowsDesktop.App 10.0.1 [C:\dotnet\shared\Microsoft.WindowsDesktop.App]"
        $r = Initialize-UiPathRuntime -RuntimeConfigPath @($script:config,$desktop) -Architecture x64 `
            -DotnetPath $script:hostPath -TargetBotPath $script:case
        Assert-RuntimeTest ($r.status -eq 'PASS' -and $r.requirements.Count -eq 2) 'all supplied compiler requirements verified'
        $script:runtimeOutput = 'Microsoft.NETCore.App 10.0.2 [C:\dotnet\shared\Microsoft.NETCore.App]'
        $r = Initialize-UiPathRuntime -RuntimeConfigPath $desktop -Architecture x64 `
            -DotnetPath $script:hostPath -TargetBotPath $script:case
        Assert-RuntimeTest ($r.status -eq 'BLOCKED') 'core runtime is not desktop runtime'
    }
    Invoke-Case 'compiler-probe-pass-and-failure' {
        $compiler = Join-Path $script:case 'compiler.exe'
        New-TestPe $compiler
        $r = Initialize-UiPathRuntime -RuntimeConfigPath $script:config -CompilerPath $compiler `
            -CompilerArgumentList @('--help') -DotnetPath $script:hostPath -TargetBotPath $script:case
        Assert-RuntimeTest ($r.status -eq 'PASS' -and $r.compilerProbe.status -eq 'PASS' -and $script:probeCalls -eq 1) 'only supplied real probe counted'
        $script:compilerFails = $true
        $r = Initialize-UiPathRuntime -RuntimeConfigPath $script:config -CompilerPath $compiler `
            -CompilerArgumentList @('--help') -DotnetPath $script:hostPath -TargetBotPath $script:case
        Assert-RuntimeTest ($r.status -eq 'BLOCKED' -and $r.runtimeVerified -and $r.compilerProbe.status -eq 'BLOCKED') 'runtime and compiler capability separate'
        $record = [IO.File]::ReadAllText($r.evidencePath) | ConvertFrom-Json
        Assert-RuntimeTest ($record.status -eq 'BLOCKED') 'failed latest probe replaces prior PASS'
    }
    Invoke-Case 'failed-runtime-replaces-pass' {
        $r = Invoke-Readiness
        Assert-RuntimeTest ($r.status -eq 'PASS') 'initial verification passed'
        $script:runtimeOutput = 'unknown output'
        $r = Invoke-Readiness
        $record = [IO.File]::ReadAllText($r.evidencePath) | ConvertFrom-Json
        Assert-RuntimeTest ($record.status -eq 'BLOCKED' -and -not $record.runtimeVerified -and -not $record.dotnetRoot) 'failed runtime probe invalidates persisted selection'
    }
    Invoke-Case 'global-install-denied' {
        $script:runtimeOutput = ''
        $r = Initialize-UiPathRuntime -RuntimeConfigPath $script:config -Architecture x64 `
            -DotnetPath $script:hostPath -TargetBotPath $script:case -ApprovedInstall `
            -InstallDirectory (Join-Path $env:ProgramFiles 'ForbiddenRuntimeTest')
        Assert-RuntimeTest ($r.cause -eq 'INSTALL_DIRECTORY_MUST_BE_USER_LOCAL' -and $script:downloadCalls -eq 0) 'no global install even with approval'
    }
    # Exercise the production URL allowlist, not the mocked downloader.
    . (Join-Path $PSScriptRoot '..\scripts\Initialize-UiPathRuntime.ps1')
    foreach ($url in @('http://builds.dotnet.microsoft.com/dotnet/Runtime/a.zip',
                        'https://example.org/runtime.zip',
                        'https://builds.dotnet.microsoft.com/other/a.zip',
                        'https://builds.dotnet.microsoft.com/dotnet/Runtime/a.zip?source=other')) {
        $blocked = $false
        try { Get-UiPathRuntimeOfficialFile $url (Join-Path $suite 'never-created') 1 }
        catch { $blocked = $_.Exception.Message -eq 'DOWNLOAD_URL_NOT_ALLOWLISTED' }
        Assert-RuntimeTest $blocked 'unapproved download URL rejected before network access'
    }
    $script:passed++
    Write-Host 'PASS official-download-allowlist'
    Write-Output "RUNTIME_TEST_STATUS=PASS CASES=$script:passed NETWORK_CALLS=0 REAL_INSTALLS=0"
} finally {
    foreach ($key in $originalEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($key, $originalEnvironment[$key], 'Process')
    }
    Remove-Item -LiteralPath $suite -Recurse -Force -ErrorAction SilentlyContinue
}
