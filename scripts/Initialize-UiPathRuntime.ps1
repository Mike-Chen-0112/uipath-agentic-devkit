[CmdletBinding()]
param(
    [string[]]$RuntimeConfigPath = @(),
    [ValidateSet('x64','x86','arm64')][string]$Architecture,
    [string]$CompilerPath,
    [string[]]$CompilerArgumentList,
    [string]$DotnetPath,
    [string]$TargetBotPath = (Get-Location).Path,
    [string]$InstallDirectory,
    [switch]$ApprovedInstall,
    [switch]$NoInstall,
    [ValidateRange(1,1800)][int]$TimeoutSeconds = 180,
    [switch]$Json
)

# Dot-sourcing exposes the helpers for deterministic tests; no test switches or
# alternate download/command sources are accepted by the production entry point.
function Get-UiPathRuntimeRemainingSeconds {
    param([datetime]$Deadline)
    $remaining = [Math]::Ceiling(($Deadline - [DateTime]::UtcNow).TotalSeconds)
    if ($remaining -le 0) { throw 'RUNTIME_READINESS_TIMEOUT' }
    return [int]$remaining
}

function Get-UiPathRuntimePeArchitecture {
    param([string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    $reader = New-Object IO.BinaryReader($stream)
    try {
        if ($reader.ReadUInt16() -ne 0x5a4d) { throw 'NOT_PE_EXECUTABLE' }
        $stream.Position = 0x3c
        $offset = $reader.ReadInt32()
        if ($offset -lt 64 -or $offset -gt ($stream.Length - 6)) { throw 'INVALID_PE_HEADER' }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x4550) { throw 'INVALID_PE_SIGNATURE' }
        switch ($reader.ReadUInt16()) {
            0x8664 { return 'x64' }
            0x014c { return 'x86' }
            0xaa64 { return 'arm64' }
            default { throw 'UNSUPPORTED_PE_ARCHITECTURE' }
        }
    } finally { $reader.Dispose(); $stream.Dispose() }
}

function Invoke-UiPathRuntimeCommand {
    param([string]$FilePath, [string[]]$Arguments, [string]$BotPath,
          [ValidateSet('runtime-probe','runtime-install','compiler-probe')][string]$Subcategory,
          [int]$Timeout, [bool]$SideEffecting = $false)
    $runner = Join-Path $PSScriptRoot 'Invoke-DevKitCommand.ps1'
    if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { throw 'SHARED_COMMAND_RUNNER_MISSING' }
    # Bootstrap commands must not consume the stale/BLOCKED record they repair.
    # The optional compiler probe runs only after in-memory runtime verification
    # and inherits the verified process DOTNET_ROOT variables set below. It must
    # not reload an older on-disk selection before this invocation is committed.
    $text = & $runner -FilePath $FilePath -ArgumentList $Arguments -WorkingDirectory $BotPath `
        -TargetBotPath $BotPath -Category PACKAGE -Subcategory $Subcategory `
        -Operation "uipath-runtime.$Subcategory" -TimeoutSeconds $Timeout `
        -SideEffecting:$SideEffecting -SkipRuntimeSelection -Json
    return ($text | ConvertFrom-Json)
}

function Get-UiPathRuntimeRequirements {
    param([string[]]$Paths)
    if (-not $Paths -or $Paths.Count -eq 0) { throw 'RUNTIMECONFIG_REQUIRED' }
    if ($Paths.Count -gt 16) { throw 'TOO_MANY_RUNTIMECONFIGS' }
    $requirements = @()
    $sources = @()
    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'RUNTIMECONFIG_MISSING' }
        try { $config = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $path).Path) | ConvertFrom-Json }
        catch { throw 'RUNTIMECONFIG_UNPARSEABLE' }
        $options = $config.runtimeOptions
        if (-not $options -or $options.includedFrameworks) { throw 'RUNTIMECONFIG_NOT_FRAMEWORK_DEPENDENT' }
        $frameworks = @()
        if ($options.framework) { $frameworks += $options.framework }
        if ($options.frameworks) { $frameworks += @($options.frameworks) }
        if ($frameworks.Count -eq 0) { throw 'RUNTIMECONFIG_FRAMEWORK_MISSING' }
        foreach ($framework in $frameworks) {
            if ($framework.name -notin @('Microsoft.NETCore.App','Microsoft.WindowsDesktop.App')) {
                throw 'UNSUPPORTED_RUNTIME_FRAMEWORK'
            }
            if ([string]$framework.version -notmatch '^\d+\.\d+\.\d+$') { throw 'UNSUPPORTED_RUNTIME_VERSION' }
            $roll = 'Minor' # .NET default; this component only accepts its conservative same-minor subset.
            if ($null -ne $options.rollForward) { $roll = [string]$options.rollForward }
            if ($null -ne $framework.rollForward) { $roll = [string]$framework.rollForward }
            if ($roll -cnotin @('Disable','LatestPatch','Minor','LatestMinor','Major','LatestMajor')) {
                throw 'UNSUPPORTED_ROLL_FORWARD_POLICY'
            }
            $exact = $roll -eq 'Disable' -or $options.applyPatches -eq $false -or $framework.applyPatches -eq $false
            # Legacy policy cannot authorize a wider selection without full host policy evaluation.
            if ($null -ne $options.rollForwardOnNoCandidateFx) { $exact = $true }
            $requirements += [pscustomobject]@{
                framework = [string]$framework.name; version = [string]$framework.version
                rollForward = $roll; selectionPolicy = $(if ($exact) { 'EXACT' } else { 'SAME_MINOR_COMPATIBLE_PATCH' })
            }
        }
        $sources += [pscustomobject]@{
            path = (Resolve-Path -LiteralPath $path).Path
            sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        if ($requirements.Count -gt 16) { throw 'TOO_MANY_RUNTIME_REQUIREMENTS' }
    }
    return [pscustomobject]@{ requirements = @($requirements); sources = @($sources) }
}

function Test-UiPathRuntimeHost {
    param([string]$Path, [string]$Architecture, [object[]]$Requirements,
          [string]$BotPath, [int]$Timeout)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'DOTNET_HOST_MISSING' }
    if ((Get-UiPathRuntimePeArchitecture $Path) -ne $Architecture) { throw 'DOTNET_ARCHITECTURE_MISMATCH' }
    $probe = Invoke-UiPathRuntimeCommand $Path @('--list-runtimes') $BotPath 'runtime-probe' $Timeout
    if ($probe.status -ne 'PASS' -or $probe.exit_code -ne 0 -or $probe.timed_out) { throw 'RUNTIME_PROBE_FAILED' }
    if (-not [string]::IsNullOrWhiteSpace([string]$probe.error)) { throw 'RUNTIME_PROBE_STDERR' }
    $runtimes = @()
    foreach ($line in ([string]$probe.output -split '\r?\n')) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch '^(?<name>Microsoft\.[A-Za-z0-9.]+) (?<version>\d+\.\d+\.\d+) \[(?<location>.+)\]$') {
            throw 'RUNTIME_PROBE_OUTPUT_UNKNOWN'
        }
        $runtimes += [pscustomobject]@{ framework = $Matches.name; version = $Matches.version; location = $Matches.location }
    }
    if ($runtimes.Count -eq 0) { throw 'RUNTIME_PROBE_OUTPUT_EMPTY' }
    $selected = @()
    foreach ($requirement in $Requirements) {
        $wanted = [version]$requirement.version
        $compatible = @($runtimes | Where-Object {
            $v = [version]$_.version
            $_.framework -eq $requirement.framework -and
            $v.Major -eq $wanted.Major -and $v.Minor -eq $wanted.Minor -and
            (($requirement.selectionPolicy -eq 'EXACT' -and $v -eq $wanted) -or
             ($requirement.selectionPolicy -ne 'EXACT' -and $v -ge $wanted))
        } | Sort-Object { [version]$_.version } -Descending)
        if ($compatible.Count -eq 0) { throw "REQUIRED_RUNTIME_NOT_FOUND:$($requirement.framework)/$($requirement.version)" }
        $selected += $compatible[0]
    }
    return [pscustomobject]@{
        dotnetPath = (Resolve-Path -LiteralPath $Path).Path
        architecture = $Architecture
        dotnetSha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
        selectedRuntimes = @($selected); installedRuntimes = @($runtimes)
    }
}

function Get-UiPathRuntimeOfficialFile {
    param([string]$Url, [string]$Destination, [int]$Timeout)
    $uri = [uri]$Url
    if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'builds.dotnet.microsoft.com' -or
        $uri.Port -ne 443 -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or
        $uri.AbsolutePath -notmatch '^/dotnet/(release-metadata/|Runtime/|WindowsDesktop/)') {
        throw 'DOWNLOAD_URL_NOT_ALLOWLISTED'
    }
    # Redirects cannot escape the allowlist; do not execute any downloaded script.
    Invoke-WebRequest -Uri $uri.AbsoluteUri -OutFile $Destination -UseBasicParsing `
        -MaximumRedirection 0 -TimeoutSec $Timeout -ErrorAction Stop | Out-Null
}

function Install-UiPathRuntimeArchive {
    param([object[]]$Requirements, [string]$Architecture, [string]$Directory,
          [string]$BotPath, [int]$Timeout)
    # Official publisher release metadata authenticates the ZIP's SHA-512 over HTTPS.
    # ZIP distributions avoid the elevation/global servicing of the Windows EXE installer.
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ('rpa-runtime-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $scratch
    $root = Join-Path $Directory ('runtime-' + [guid]::NewGuid().ToString('N'))
    $install = $null
    $deadline = [DateTime]::UtcNow.AddSeconds($Timeout)
    try {
        $bundles = @()
        foreach ($requirement in ($Requirements | Sort-Object framework,version -Unique)) {
            $v = [version]$requirement.version
            $metadataPath = Join-Path $scratch ("releases-$($v.Major).$($v.Minor).json")
            Get-UiPathRuntimeOfficialFile "https://builds.dotnet.microsoft.com/dotnet/release-metadata/$($v.Major).$($v.Minor)/releases.json" `
                $metadataPath (Get-UiPathRuntimeRemainingSeconds $deadline)
            $metadata = [IO.File]::ReadAllText($metadataPath) | ConvertFrom-Json
            $section = if ($requirement.framework -eq 'Microsoft.WindowsDesktop.App') { 'windowsdesktop' } else { 'runtime' }
            $releases = @($metadata.releases | Where-Object { $_.$section.version -eq $requirement.version })
            if ($releases.Count -ne 1) { throw 'OFFICIAL_RUNTIME_RELEASE_NOT_FOUND' }
            $files = @($releases[0].$section.files | Where-Object {
                $_.rid -eq "win-$Architecture" -and $_.url -match '\.zip$'
            })
            if ($files.Count -ne 1 -or [string]$files[0].hash -notmatch '^[a-fA-F0-9]{128}$') {
                throw 'OFFICIAL_ARCHIVE_METADATA_INVALID'
            }
            $archive = Join-Path $scratch ("bundle-$($bundles.Count).zip")
            Get-UiPathRuntimeOfficialFile $files[0].url $archive (Get-UiPathRuntimeRemainingSeconds $deadline)
            $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA512).Hash
            if ($hash -ine $files[0].hash) { throw 'OFFICIAL_ARCHIVE_HASH_MISMATCH' }
            $bundles += [pscustomobject]@{ path = $archive; sha512 = $hash.ToLowerInvariant(); url = $files[0].url }
        }
        # Exactly one bounded install subprocess. New isolated root, no replacement
        # of existing runtimes, no PATH/registry/admin operations. Conflicts fail closed.
        $payload = @{ root = $root; bundles = @($bundles) } | ConvertTo-Json -Depth 6 -Compress
        $encodedPayload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
        $worker = @'
$ErrorActionPreference = 'Stop'
$p = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('PAYLOAD')) | ConvertFrom-Json
if (Test-Path -LiteralPath $p.root) { throw 'INSTALL_ROOT_ALREADY_EXISTS' }
$null = New-Item -ItemType Directory -Path $p.root
Add-Type -AssemblyName System.IO.Compression.FileSystem
foreach ($bundle in $p.bundles) {
    if ((Get-FileHash -LiteralPath $bundle.path -Algorithm SHA512).Hash -ine $bundle.sha512) { throw 'ARCHIVE_CHANGED' }
    $zip = [IO.Compression.ZipFile]::OpenRead($bundle.path)
    try {
        foreach ($entry in $zip.Entries) {
            $destination = [IO.Path]::GetFullPath((Join-Path $p.root $entry.FullName))
            if (-not $destination.StartsWith($p.root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'UNSAFE_ARCHIVE_ENTRY' }
            if ($entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')) { continue }
            $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
            if (Test-Path -LiteralPath $destination) {
                $hashStream = $entry.Open()
                $hasher = [Security.Cryptography.SHA256]::Create()
                try { $entryHash = [BitConverter]::ToString($hasher.ComputeHash($hashStream)).Replace('-','') }
                finally { $hashStream.Dispose(); $hasher.Dispose() }
                if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ine $entryHash) { throw 'ARCHIVE_FILE_COLLISION' }
                continue # Identical files shared by official bundles are not rewritten.
            }
            $inputStream = $entry.Open()
            try {
                $outputStream = [IO.File]::Open($destination, [IO.FileMode]::CreateNew)
                try { $inputStream.CopyTo($outputStream) } finally { $outputStream.Dispose() }
            } finally { $inputStream.Dispose() }
        }
    } finally { $zip.Dispose() }
}
'@
        $worker = $worker.Replace('PAYLOAD', $encodedPayload)
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($worker))
        $shell = Join-Path $PSHOME 'powershell.exe'
        if (-not (Test-Path -LiteralPath $shell)) { $shell = Join-Path $PSHOME 'pwsh.exe' }
        $install = Invoke-UiPathRuntimeCommand $shell @('-NoProfile','-NonInteractive','-EncodedCommand',$encoded) `
            $BotPath 'runtime-install' (Get-UiPathRuntimeRemainingSeconds $deadline) $true
        if ($install.status -ne 'PASS' -or $install.exit_code -ne 0 -or $install.timed_out) { throw 'RUNTIME_INSTALL_SUBPROCESS_FAILED' }
        return [pscustomobject]@{ dotnetPath = (Join-Path $root 'dotnet.exe'); root = $root; archives = @($bundles | Select-Object url,sha512) }
    } finally {
        Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
        # A failed install's fresh root is not a usable runtime and must not be selected.
        if (-not $install -or $install.status -ne 'PASS' -or $install.exit_code -ne 0 -or $install.timed_out) {
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}

function Initialize-UiPathRuntime {
    [CmdletBinding()]
    param(
        [string[]]$RuntimeConfigPath = @(),
        [ValidateSet('x64','x86','arm64')][string]$Architecture,
        [string]$CompilerPath, [string[]]$CompilerArgumentList, [string]$DotnetPath,
        [string]$TargetBotPath = (Get-Location).Path, [string]$InstallDirectory,
        [switch]$ApprovedInstall, [ValidateRange(1,1800)][int]$TimeoutSeconds = 180
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $probeRequested = $CompilerPath -and $PSBoundParameters.ContainsKey('CompilerArgumentList')
    $result = [ordered]@{
        schemaVersion = 1; status = 'BLOCKED'; cause = $null
        verifiedAtUtc = [DateTime]::UtcNow.ToString('o')
        requirements = @(); runtimeConfigSources = @(); architecture = $null
        runtimeConfigPath = $null; runtimeConfigSha256 = $null
        dotnetRoot = $null; dotnetPath = $null; dotnetSha256 = $null; verifiedFrameworks = @()
        runtimeVerified = $false; runtime = $null; environment = @{}
        installation = [ordered]@{ approved = [bool]$ApprovedInstall; attempted = $false; status = 'NOT_RUN'; cause = $null; archives = @() }
        compilerProbe = [ordered]@{ status = 'NOT_RUN'; cause = $(if ($probeRequested) { 'RUNTIME_NOT_READY' } else { 'NO_EXPLICIT_PROBE_SUPPLIED' }); exitCode = $null }
        hostAttempts = @(); evidencePath = $null
    }
    try {
        $TargetBotPath = (Resolve-Path -LiteralPath $TargetBotPath -ErrorAction Stop).Path
        $requirements = Get-UiPathRuntimeRequirements $RuntimeConfigPath
        $result.requirements = @($requirements.requirements)
        $result.runtimeConfigSources = @($requirements.sources)
        # Singular fields identify the primary compiler configuration. Consumers
        # must also validate every entry in runtimeConfigSources when several
        # explicit configurations contributed requirements.
        $result.runtimeConfigPath = $requirements.sources[0].path
        $result.runtimeConfigSha256 = $requirements.sources[0].sha256
        if ($CompilerPath) {
            if (-not (Test-Path -LiteralPath $CompilerPath -PathType Leaf)) { throw 'COMPILER_PATH_MISSING' }
            $CompilerPath = (Resolve-Path -LiteralPath $CompilerPath).Path
            if ([IO.Path]::GetExtension($CompilerPath) -ine '.exe') { throw 'COMPILER_MUST_BE_EXECUTABLE_APPHOST' }
            $actualArchitecture = Get-UiPathRuntimePeArchitecture $CompilerPath
            if ($Architecture -and $Architecture -ne $actualArchitecture) { throw 'COMPILER_ARCHITECTURE_MISMATCH' }
            $Architecture = $actualArchitecture
        }
        if (-not $Architecture) { throw 'COMPILER_ARCHITECTURE_REQUIRED' }
        $result.architecture = $Architecture
        if (-not $InstallDirectory) {
            if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA_UNAVAILABLE' }
            $InstallDirectory = Join-Path $env:LOCALAPPDATA "RpaAiDevKit\tools\dotnet\$Architecture"
        }
        $InstallDirectory = [IO.Path]::GetFullPath($InstallDirectory)
        $candidates = @()
        if ($DotnetPath) { $candidates += $DotnetPath }
        $candidates += Join-Path $InstallDirectory 'dotnet.exe'
        # Only reuse a prior selected root after fresh architecture/framework verification.
        $recordPath = Join-Path $TargetBotPath '.rpa-ai\local\dotnet-runtime.json'
        if (Test-Path -LiteralPath $recordPath) {
            try {
                $prior = [IO.File]::ReadAllText($recordPath) | ConvertFrom-Json
                if ($prior.runtimeVerified -and $prior.architecture -eq $Architecture) { $candidates += $prior.runtime.dotnetPath }
            } catch { } # An invalid old record is never evidence of readiness.
        }
        foreach ($variable in @("DOTNET_ROOT_$($Architecture.ToUpperInvariant())",'DOTNET_ROOT')) {
            $value = [Environment]::GetEnvironmentVariable($variable, 'Process')
            if ($value) { $candidates += Join-Path $value 'dotnet.exe' }
        }
        $command = Get-Command dotnet -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) { $candidates += $command.Source }
        foreach ($folder in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432)) {
            if ($folder) { $candidates += Join-Path $folder 'dotnet\dotnet.exe' }
        }
        $selected = $null
        foreach ($candidate in ($candidates | Where-Object { $_ } | Select-Object -Unique)) {
            try {
                $selected = Test-UiPathRuntimeHost $candidate $Architecture $result.requirements $TargetBotPath `
                    (Get-UiPathRuntimeRemainingSeconds $deadline)
                $result.hostAttempts += @{ path = $candidate; status = 'PASS' }
                break
            } catch { $result.hostAttempts += @{ path = $candidate; status = 'BLOCKED'; cause = $_.Exception.Message } }
        }
        if (-not $selected) {
            if (-not $ApprovedInstall) {
                $result.installation.cause = 'INSTALL_NOT_APPROVED'
                throw 'REQUIRED_RUNTIME_UNAVAILABLE_INSTALL_NOT_APPROVED'
            }
            # Never install into a global or another user's tree, even with approval.
            if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA_UNAVAILABLE' }
            $local = [IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd('\') + '\'
            if (-not $InstallDirectory.StartsWith($local, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'INSTALL_DIRECTORY_MUST_BE_USER_LOCAL'
            }
            # Reject existing reparse points so a user-local spelling cannot target global resources.
            $ancestor = $InstallDirectory
            while ($ancestor) {
                if ((Test-Path -LiteralPath $ancestor) -and
                    ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    throw 'INSTALL_DIRECTORY_REPARSE_POINT'
                }
                $ancestor = [IO.Path]::GetDirectoryName($ancestor)
            }
            $remaining = Get-UiPathRuntimeRemainingSeconds $deadline
            $result.installation.attempted = $true
            $result.installation.status = 'FAIL'
            try {
                $installed = Install-UiPathRuntimeArchive $result.requirements $Architecture $InstallDirectory $TargetBotPath $remaining
                $result.installation.archives = @($installed.archives)
                $selected = Test-UiPathRuntimeHost $installed.dotnetPath $Architecture $result.requirements $TargetBotPath `
                    (Get-UiPathRuntimeRemainingSeconds $deadline)
                $result.installation.status = 'PASS'
            } catch {
                $result.installation.cause = $_.Exception.Message
                throw
            }
        }
        $result.runtimeVerified = $true
        $result.runtime = $selected
        $root = Split-Path -Parent $selected.dotnetPath
        $result.dotnetRoot = $root
        $result.dotnetPath = $selected.dotnetPath
        $result.dotnetSha256 = $selected.dotnetSha256
        $result.verifiedFrameworks = @($selected.selectedRuntimes)
        $result.environment = @{ DOTNET_ROOT = $root }
        $result.environment["DOTNET_ROOT_$($Architecture.ToUpperInvariant())"] = $root
        foreach ($name in $result.environment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $result.environment[$name], 'Process')
        }
        if ($probeRequested) {
            $result.compilerProbe.cause = $null
            $result.compilerProbe.status = 'BLOCKED'
            $probe = Invoke-UiPathRuntimeCommand $CompilerPath $CompilerArgumentList $TargetBotPath 'compiler-probe' `
                (Get-UiPathRuntimeRemainingSeconds $deadline)
            $result.compilerProbe.exitCode = $probe.exit_code
            if ($probe.status -ne 'PASS' -or $probe.exit_code -ne 0 -or $probe.timed_out) {
                $result.compilerProbe.cause = 'COMPILER_PROBE_FAILED'
                throw 'COMPILER_PROBE_FAILED'
            }
            $result.compilerProbe.status = 'PASS'
            $result.compilerProbe.path = $CompilerPath
            $result.compilerProbe.sha256 = (Get-FileHash -LiteralPath $CompilerPath -Algorithm SHA256).Hash.ToLowerInvariant()
        } elseif ($PSBoundParameters.ContainsKey('CompilerArgumentList')) { throw 'COMPILER_PATH_REQUIRED_FOR_PROBE' }
        $result.status = 'PASS'
        $result.cause = 'REQUIRED_RUNTIME_VERIFIED'
    } catch {
        $result.cause = $_.Exception.Message
        if ($result.compilerProbe.status -eq 'BLOCKED' -and -not $result.compilerProbe.cause) {
            $result.compilerProbe.cause = 'COMPILER_PROBE_EXECUTION_FAILED'
        }
    }
    # Persist no command output/arguments or environment beyond the verified roots.
    try {
        $recordPath = Join-Path $TargetBotPath '.rpa-ai\local\dotnet-runtime.json'
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $recordPath) -Force
        $result.evidencePath = $recordPath
        $temporary = $recordPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        [IO.File]::WriteAllText($temporary, ($result | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temporary -Destination $recordPath -Force
    } catch {
        $result.status = 'BLOCKED'
        $result.cause = 'RUNTIME_EVIDENCE_WRITE_FAILED'
        # A failed write must not intentionally leave an older reusable PASS.
        if ($recordPath -and (Test-Path -LiteralPath $recordPath)) {
            Remove-Item -LiteralPath $recordPath -Force -ErrorAction SilentlyContinue
        }
    }
    return [pscustomobject]$result
}

if ($MyInvocation.InvocationName -ne '.') {
    $arguments = @{}
    foreach ($key in $PSBoundParameters.Keys) {
        if ($key -notin @('Json','NoInstall','ApprovedInstall')) { $arguments[$key] = $PSBoundParameters[$key] }
    }
    # The script entry point self-heals: user-scoped install from official sources is on by default.
    $arguments['ApprovedInstall'] = -not $NoInstall
    $readiness = Initialize-UiPathRuntime @arguments
    if ($Json) { $readiness | ConvertTo-Json -Depth 12 } else { $readiness }
}
