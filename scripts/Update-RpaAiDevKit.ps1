[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$TargetBotPath,
    [string]$Version,
    [switch]$ConfirmUpdate
)

$ErrorActionPreference = 'Stop'
function Test-IsReparsePoint {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }
    if ($item.PSObject.Properties.Name -contains 'LinkType' -and [string]$item.LinkType) { return $true }
    if ($item.PSObject.Properties.Name -contains 'Target' -and $item.Target) { return $true }
    $lexicalPath = [System.IO.Path]::GetFullPath($Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $resolvedPath = ([string](Resolve-Path -LiteralPath $Path -ErrorAction Stop)).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    if (-not $lexicalPath.Equals($resolvedPath, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    return [string]$item.Mode -match 'l$'
}

if (Test-IsReparsePoint $TargetBotPath) {
    throw "Update root is a reparse point: '$TargetBotPath'"
}
$TargetBotPath = (Resolve-Path $TargetBotPath).Path
$scriptRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$manifestPath = Join-Path $TargetBotPath '.rpa-ai\kit-manifest.json'
$integrityScript = Join-Path $TargetBotPath '.rpa-ai\scripts\Test-ManagedFileIntegrity.ps1'
$versionCheckScript = Join-Path $TargetBotPath '.rpa-ai\scripts\Check-DevKitRemoteVersion.ps1'
$gitCommand = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $gitCommand) { throw 'Git is required for a Dev Kit update.' }
$gitExecutable = if ($gitCommand.Source) { $gitCommand.Source } else { $gitCommand.Definition }

if (-not $ConfirmUpdate) { throw 'Explicit update choice is required. Re-run with -ConfirmUpdate after the user chooses Update.' }

if (-not (Test-Path $manifestPath -PathType Leaf)) { throw 'A checked Dev Kit installation is required before an automatic update.' }
if (-not (Test-Path $integrityScript -PathType Leaf)) { throw "Managed integrity script is missing: $integrityScript" }
& $integrityScript -TargetBotPath $TargetBotPath
$installedManifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
$installedVersion = [string]$installedManifest.kitVersion
if ($installedVersion -notmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$') { throw "Installed Dev Kit version is not a stable semantic version: '$installedVersion'" }
$sourceRepository = [string]$installedManifest.sourceRepository
if (-not $sourceRepository) {
    $remoteOutput = @(& $gitExecutable -C $TargetBotPath config --get remote.origin.url 2>$null)
    $gitExitCode = $LASTEXITCODE
    $sourceRepository = [string]($remoteOutput | Select-Object -First 1)
    if ($gitExitCode -ne 0 -or -not $sourceRepository) { throw 'Installed payload has no source repository and the bot Git origin could not be determined.' }
    $sourceRepository = $sourceRepository.Trim()
}
if (-not $sourceRepository) { throw 'Installed payload does not record its canonical Azure DevOps repository.' }
if ($sourceRepository -notmatch '(?i)^https://(?:[^/@]+@)?([^/]+\.)?dev\.azure\.com/' -and
    $sourceRepository -notmatch '(?i)^https://(?:[^/@]+@)?[^/]+\.visualstudio\.com/' -and
    $sourceRepository -notmatch '(?i)^git@ssh\.dev\.azure\.com:') { throw 'Recorded source repository is not Azure DevOps.' }

if (-not $Version) {
    if (-not (Test-Path $versionCheckScript -PathType Leaf)) { throw "Version check script is missing: $versionCheckScript" }
    $check = & $versionCheckScript -TargetBotPath $TargetBotPath -Json | ConvertFrom-Json
    if ($check.status -ne 'UPDATE_AVAILABLE') { throw 'No newer stable Dev Kit release is available.' }
    $Version = [string]$check.latestVersion
}
$tag = if ($Version -match '^v') { $Version } else { "v$Version" }
if ($tag -notmatch '^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$') { throw "Update version is not a stable semantic release: '$Version'" }
if ([version]$tag.TrimStart('v') -le [version]$installedVersion) { throw "Selected release '$tag' is not newer than installed version '$installedVersion'." }

$tagRef = "refs/tags/$tag"
& $gitExecutable ls-remote --exit-code --refs $sourceRepository $tagRef *> $null
if ($LASTEXITCODE -ne 0) { throw "Azure DevOps release tag '$tag' was not found." }

$workRoot = Join-Path $env:TEMP ('rpa-ai-devkit-update-' + [guid]::NewGuid().ToString('N'))
$checkoutPath = Join-Path $workRoot 'source'
$payloadOutput = Join-Path $workRoot 'payload'
$backupRoot = Join-Path $workRoot 'backup'
$incomingManifestPath = Join-Path $payloadOutput ("rpa-ai-devkit-bot-$($tag.TrimStart('v'))\.rpa-ai\kit-manifest.json")
$backupItems = [System.Collections.Generic.List[object]]::new()
$upgradeStarted = $false

function Resolve-ContainedPath {
    param([string]$Root, [string]$RelativePath)
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $Root $RelativePath))
    $prefix = $Root.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Path escapes root: '$RelativePath'" }
    return $candidate
}

function Assert-NoReparsePointAncestors {
    param([string]$Root, [string]$Candidate)

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    if (Test-IsReparsePoint $Root) {
            throw "Update root is a reparse point: '$rootFull'"
    }
    $cursor = if (Test-Path $Candidate) { $Candidate } else { Split-Path $Candidate -Parent }
    while ($cursor -and $cursor.Length -gt $rootFull.Length) {
        if (Test-IsReparsePoint $cursor) {
                throw "Update path crosses a reparse point: '$cursor'"
        }
        $cursor = Split-Path $cursor -Parent
    }
}

try {
    New-Item -ItemType Directory -Force -Path $workRoot | Out-Null
    & $gitExecutable clone --depth 1 --branch $tag --single-branch $sourceRepository $checkoutPath *> $null
    if ($LASTEXITCODE -ne 0) { throw "Azure DevOps checkout of '$tag' failed." }
    $sourceVersion = (Get-Content (Join-Path $checkoutPath 'VERSION') -Raw).Trim()
    if ($sourceVersion -ne $tag.TrimStart('v')) { throw "Checked out release version '$sourceVersion' does not match '$tag'." }

    & (Join-Path $checkoutPath 'scripts\Export-RpaAiDevKit.ps1') -OutputDirectory $payloadOutput -NoZip -Force
    $payload = Get-ChildItem $payloadOutput -Directory | Select-Object -First 1
    if (-not $payload) { throw 'Release export did not produce a payload directory.' }
    $incomingManifestPath = Join-Path $payload.FullName '.rpa-ai\kit-manifest.json'
    $incomingManifest = Get-Content $incomingManifestPath -Raw | ConvertFrom-Json

    New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
    $paths = @($installedManifest.files.path) + @($incomingManifest.files.path) + @('.rpa-ai/kit-manifest.json', '.rpa-ai/kit-manifest.sha256')
    foreach ($relativePath in @($paths | Sort-Object -Unique)) {
        $destination = Resolve-ContainedPath $TargetBotPath ([string]$relativePath)
        Assert-NoReparsePointAncestors $TargetBotPath $destination
        $existed = Test-Path $destination -PathType Leaf
        $backup = $null
        if ($existed) {
            $backup = Join-Path $backupRoot ([guid]::NewGuid().ToString('N'))
            Copy-Item $destination $backup
        }
        $backupItems.Add([pscustomobject]@{ Destination = $destination; Existed = $existed; Backup = $backup })
    }
    $gitignorePath = Join-Path $TargetBotPath '.gitignore'
    Assert-NoReparsePointAncestors $TargetBotPath $gitignorePath
    $gitignoreBackup = $null
    $gitignoreExisted = Test-Path $gitignorePath -PathType Leaf
    if ($gitignoreExisted) {
        $gitignoreBackup = Join-Path $backupRoot ([guid]::NewGuid().ToString('N'))
        Copy-Item $gitignorePath $gitignoreBackup
    }
    $backupItems.Add([pscustomobject]@{ Destination = $gitignorePath; Existed = $gitignoreExisted; Backup = $gitignoreBackup })

    $upgradeStarted = $true
    & (Join-Path $payload.FullName '.rpa-ai\scripts\Import-RpaAiDevKit.ps1') -PayloadPath $payload.FullName -TargetBotPath $TargetBotPath -Upgrade
    & (Join-Path $TargetBotPath '.rpa-ai\scripts\Test-ManagedFileIntegrity.ps1') -TargetBotPath $TargetBotPath
    Write-Host "[PASS] RPA AI Dev Kit updated to $($tag.TrimStart('v'))"
} catch {
    if ($upgradeStarted) {
        for ($index = $backupItems.Count - 1; $index -ge 0; $index--) {
            $item = $backupItems[$index]
            Assert-NoReparsePointAncestors $TargetBotPath $item.Destination
            if ($item.Existed) { Copy-Item $item.Backup $item.Destination -Force }
            else { Remove-Item $item.Destination -Force -ErrorAction SilentlyContinue }
        }
        try {
            & $integrityScript -TargetBotPath $TargetBotPath
            throw "Dev Kit update failed; the previous installation was restored and passed managed-file integrity: $($_.Exception.Message)"
        } catch {
            if ($_.Exception.Message -like 'Dev Kit update failed;*') { throw }
            throw "Dev Kit update failed and rollback validation failed: $($_.Exception.Message)"
        }
    }
    throw
} finally {
    Remove-Item $workRoot -Recurse -Force -ErrorAction SilentlyContinue
}