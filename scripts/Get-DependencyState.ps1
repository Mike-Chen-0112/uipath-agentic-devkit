[CmdletBinding()]
param(
    [string]$ProjectPath = (Get-Location).Path,
    [string]$StatePath = (Join-Path (Get-Location).Path '.ai\evidence\dependency-state.json'),
    [string]$CliVersion = '',
    [ValidateSet('UNKNOWN','VERIFIED')]
    [string]$AvailabilityStatus = 'UNKNOWN',
    [switch]$Record,
    [switch]$Verify,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$ProjectPath = (Resolve-Path $ProjectPath).Path
$telemetryEvent = $null
if (Test-Path -LiteralPath (Join-Path $ProjectPath '.ai\evidence\execution-state.json') -PathType Leaf) {
    Import-Module (Join-Path $PSScriptRoot 'DeveloperTelemetry.psm1') -Force -DisableNameChecking
    $telemetryEvent = Start-DeveloperEvent -ProjectPath $ProjectPath -Category PACKAGE -Subcategory $(if($Verify){'reuse'}elseif($Record){'dependency_update'}else{'fingerprint'}) -Operation $(if($Verify){'package.reuse'}elseif($Record){'package.dependency_update'}else{'package.fingerprint'})
}
$projectFile = Join-Path $ProjectPath 'project.json'
if (-not (Test-Path $projectFile -PathType Leaf)) { throw "project.json not found in $ProjectPath" }

$dependencyNames = @(
    'project.json',
    'packages.config',
    'Directory.Build.props',
    'Directory.Packages.props',
    'requirements.txt',
    'requirements-dev.txt',
    'pyproject.toml',
    'poetry.lock',
    'uv.lock',
    'Pipfile',
    'Pipfile.lock'
)
$excludedDirectoryNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($name in @(
    '.git', '.rpa-ai', 'graphify-out', 'artifacts',
    '.venv', 'venv', 'node_modules', 'bin', 'obj',
    'TestResults', 'test-results', 'coverage', 'dist', 'build', 'target',
    'packages', '.nuget', '.cache', 'package-cache', 'packages-cache',
    '__pycache__', '.pytest_cache', '.mypy_cache', '.tox',
    'generated', 'outputs', 'output', 'out'
)) {
    [void]$excludedDirectoryNames.Add($name)
}

function Test-ReparsePoint {
    param([string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }
    if ($item.PSObject.Properties.Name -contains 'LinkType' -and [string]$item.LinkType) { return $true }
    return $false
}

function Test-DependencyManifestName {
    param([string]$Name)

    return $Name -in $dependencyNames -or $Name -like 'requirements-*.txt'
}

function Find-DependencyFiles {
    $directories = New-Object 'System.Collections.Generic.Queue[string]'
    $directories.Enqueue($ProjectPath)
    $files = New-Object 'System.Collections.Generic.List[object]'
    $issues = New-Object 'System.Collections.Generic.List[string]'

    while ($directories.Count -gt 0) {
        $directory = $directories.Dequeue()
        try {
            $children = @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)
        } catch {
            [void]$issues.Add("Unable to inspect dependency directory '$directory': $($_.Exception.Message)")
            continue
        }

        foreach ($child in $children) {
            if ($child.PSIsContainer) {
                if ($excludedDirectoryNames.Contains($child.Name)) { continue }
                try {
                    if (Test-ReparsePoint $child.FullName) {
                        [void]$issues.Add("Dependency directory is a reparse point: '$($child.FullName)'")
                        continue
                    }
                } catch {
                    [void]$issues.Add("Unable to inspect dependency directory '$($child.FullName)': $($_.Exception.Message)")
                    continue
                }
                $directories.Enqueue($child.FullName)
                continue
            }

            if (-not (Test-DependencyManifestName $child.Name)) { continue }
            try {
                if (Test-ReparsePoint $child.FullName) {
                    [void]$issues.Add("Dependency manifest is a reparse point: '$($child.FullName)'")
                    continue
                }
            } catch {
                [void]$issues.Add("Unable to inspect dependency manifest '$($child.FullName)': $($_.Exception.Message)")
                continue
            }
            [void]$files.Add($child)
        }
    }

    [pscustomobject]@{
        Files = @($files | Sort-Object FullName -Unique)
        IsCertain = ($issues.Count -eq 0)
        Issues = @($issues)
    }
}

function Get-PackageCacheFingerprint {
    $roots = @(
        (Join-Path $env:USERPROFILE '.nuget\packages'),
        (Join-Path $env:USERPROFILE '.local\share\NuGet\v3-cache'),
        (Join-Path $env:LOCALAPPDATA 'NuGet\v3-cache')
    ) | Where-Object { $_ -and (Test-Path $_ -PathType Container) }
    $entries = @($roots | ForEach-Object {
        $item = Get-Item $_ -Force
        "$($_)|$($item.LastWriteTimeUtc.Ticks)|$((Get-ChildItem $_ -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object).Count)"
    })
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes(($entries -join "`n")))) -replace '-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

$discovery = Find-DependencyFiles
$dependencyFiles = @($discovery.Files)
if ($dependencyFiles.Count -eq 0) { throw 'No dependency manifests were found.' }

$entries = @($dependencyFiles | ForEach-Object {
    $relative = $_.FullName.Substring($ProjectPath.Length).TrimStart('\','/') -replace '\\','/'
    [pscustomobject]@{
        path = $relative
        sha256 = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
} | Sort-Object path)
$project = Get-Content $projectFile -Raw | ConvertFrom-Json
$projectCompatibility = [ordered]@{
    targetFramework = [string]$project.targetFramework
    expressionLanguage = [string]$project.expressionLanguage
    modernBehavior = [string]$project.modernBehavior
}
$compatibilityJson = $projectCompatibility | ConvertTo-Json -Compress
$CliVersion = $CliVersion.Trim()
$fingerprintInput = @(
    "cliVersion=$CliVersion"
    "projectCompatibility=$compatibilityJson"
    @($entries | ForEach-Object { "$($_.path)=$($_.sha256)" })
) -join "`n"
$stateHash = ([System.Security.Cryptography.SHA256]::Create()).ComputeHash([System.Text.Encoding]::UTF8.GetBytes($fingerprintInput))
$stateHashText = ([System.BitConverter]::ToString($stateHash) -replace '-','').ToLowerInvariant()
$packageCacheFingerprint = Get-PackageCacheFingerprint
$state = [ordered]@{
    schemaVersion = 2
    stateHash = $stateHashText
    cliVersion = $CliVersion
    projectCompatibility = $projectCompatibility
    files = @($entries)
    discoveryStatus = if ($discovery.IsCertain) { 'COMPLETE' } else { 'UNCERTAIN' }
    discoveryIssues = @($discovery.Issues)
    availabilityStatus = $AvailabilityStatus
    packageCacheFingerprint = $packageCacheFingerprint
    recordedAtUtc = [DateTime]::UtcNow.ToString('o')
}

if ($Record) {
    if (-not $discovery.IsCertain) {
        throw "Dependency manifest discovery is uncertain; reusable state was not recorded. $($discovery.Issues -join ' ' )"
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $StatePath -Parent) | Out-Null
    $jsonText = $state | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText((Resolve-Path (Split-Path $StatePath -Parent)).Path + '\\' + (Split-Path $StatePath -Leaf), $jsonText + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
}

$result = [ordered]@{
    status = 'RECORDED'
    stateHash = $stateHashText
    cliVersion = $CliVersion
    files = @($entries.path)
}
if ($Verify) {
    $result.status = 'UNCERTAIN'
    if ($discovery.IsCertain -and (Test-Path $StatePath -PathType Leaf)) {
        try {
            $recorded = Get-Content $StatePath -Raw | ConvertFrom-Json
            if ($recorded.schemaVersion -ne 2 -or
                [string]$recorded.discoveryStatus -ne 'COMPLETE' -or
                [string]$recorded.stateHash -notmatch '^[0-9a-fA-F]{64}$' -or
                [string]$recorded.availabilityStatus -ne 'VERIFIED' -or
                [string]$recorded.packageCacheFingerprint -ne $packageCacheFingerprint) {
                throw 'Dependency state metadata is incomplete.'
            }
            [DateTime]::Parse([string]$recorded.recordedAtUtc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind) | Out-Null
            $recordedEntries = @($recorded.files | ForEach-Object {
                if ([string]$_.path -notmatch '\S' -or [string]$_.sha256 -notmatch '^[0-9a-fA-F]{64}$') {
                    throw 'Dependency state contains an invalid manifest entry.'
                }
                "$($_.path)=$(([string]$_.sha256).ToLowerInvariant())"
            })
            $currentEntries = @($entries | ForEach-Object { "$($_.path)=$($_.sha256)" })
            if ([string]$recorded.cliVersion -eq $CliVersion -and
                [string]$recorded.stateHash -eq $stateHashText -and
                $recordedEntries.Count -eq $currentEntries.Count -and
                (($recordedEntries -join "`n") -ceq ($currentEntries -join "`n"))) {
                $result.status = 'MATCH'
            } else {
                $result.status = 'CHANGED'
            }
        } catch {
            $result.status = 'UNCERTAIN'
        }
    }
}
if ($telemetryEvent) { Stop-DeveloperEvent -ProjectPath $ProjectPath -EventId $telemetryEvent.eventId -Status $(if($result.status -eq 'UNCERTAIN'){'UNAVAILABLE'}else{'PASS'}) -Artifacts $(if($Record -or $Verify){@([ordered]@{path=$StatePath})}else{@()}) | Out-Null }
if ($Json) { $result | ConvertTo-Json -Depth 5 } else { Write-Host "DEPENDENCY_STATE=$($result.status)"; Write-Host "DEPENDENCY_STATE_HASH=$stateHashText" }
