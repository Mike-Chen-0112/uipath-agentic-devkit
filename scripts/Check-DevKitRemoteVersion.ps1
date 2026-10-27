[CmdletBinding()]
param(
    [string]$TargetBotPath = (Get-Location).Path,
    [switch]$Json,
    [switch]$Force,
    [ValidateRange(1,168)]
    [int]$MaxAgeHours = 24
)

$ErrorActionPreference = 'Stop'
$TargetBotPath = (Resolve-Path $TargetBotPath).Path
$manifestPath = Join-Path $TargetBotPath '.rpa-ai\kit-manifest.json'
$resultPath = Join-Path $TargetBotPath '.rpa-ai\local\version-check.json'

function Get-CanonicalSourceRepository {
    param([object]$Manifest)

    if ($Manifest.sourceRepository) { return [string]$Manifest.sourceRepository }
    $gitCommand = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $gitCommand) { throw 'Git is not available to determine the canonical Azure DevOps repository.' }
    $gitExecutable = if ($gitCommand.Source) { $gitCommand.Source } else { $gitCommand.Definition }
    $remoteOutput = @(& $gitExecutable -C $TargetBotPath config --get remote.origin.url 2>$null)
    $gitExitCode = $LASTEXITCODE
    $remote = ($remoteOutput | Select-Object -First 1)
    if ($gitExitCode -ne 0 -or -not $remote) { throw 'Installed payload has no source repository and the bot Git origin could not be determined.' }
    return ([string]$remote).Trim()
}

function New-VersionCheckResult {
    param([string]$Status, [string]$Reason, [string]$InstalledVersion, [string]$LatestVersion, [string]$SourceRepository)
    return [ordered]@{
        schemaVersion = 1
        status = $Status
        installedVersion = $InstalledVersion
        latestVersion = $LatestVersion
        sourceRepository = $SourceRepository
        checkedAtUtc = [DateTime]::UtcNow.ToString('o')
        reason = $Reason
    }
}

function Write-VersionCheckOutput {
    param([object]$Value)

    $jsonText = $Value | ConvertTo-Json -Depth 5
    if ($Json) {
        Write-Output $jsonText
    } elseif ($Value.status -eq 'UPDATE_AVAILABLE') {
        Write-Host 'RPA AI Dev Kit update available'
        Write-Host "Installed: $($Value.installedVersion)"
        Write-Host "Latest:    $($Value.latestVersion)"
    } elseif ($Value.status -eq 'UNAVAILABLE') {
        Write-Host 'VERSION_CHECK_STATUS=UNAVAILABLE'
    } elseif ($Value.status -eq 'CURRENT') {
        Write-Host 'VERSION_CHECK_STATUS=CURRENT'
    }
}

$result = $null
try {
    if (-not (Test-Path $manifestPath -PathType Leaf)) { throw 'Installed Dev Kit manifest is missing.' }
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    $installedVersion = [string]$manifest.kitVersion
    if (-not $Force -and (Test-Path $resultPath -PathType Leaf)) {
        try {
            $cached = Get-Content $resultPath -Raw | ConvertFrom-Json
            $checkedAt = [DateTime]::Parse([string]$cached.checkedAtUtc).ToUniversalTime()
            $cacheAgeHours = ([DateTime]::UtcNow - $checkedAt).TotalHours
            if ($cached.schemaVersion -eq 1 -and [string]$cached.installedVersion -eq $installedVersion -and
                $cached.status -in @('CURRENT','UPDATE_AVAILABLE','UNAVAILABLE') -and
                $cacheAgeHours -ge 0 -and $cacheAgeHours -lt $MaxAgeHours) {
                Write-VersionCheckOutput $cached
                return
            }
        } catch { }
    }
    $sourceRepository = Get-CanonicalSourceRepository $manifest
    if ($installedVersion -notmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$') { throw 'Installed Dev Kit version is not a stable semantic version.' }
    if (-not $sourceRepository) { throw 'Installed payload does not record its canonical Azure DevOps repository.' }
    if ($sourceRepository -notmatch '(?i)^https://(?:[^/@]+@)?([^/]+\.)?dev\.azure\.com/' -and
        $sourceRepository -notmatch '(?i)^https://(?:[^/@]+@)?[^/]+\.visualstudio\.com/' -and
        $sourceRepository -notmatch '(?i)^git@ssh\.dev\.azure\.com:') { throw 'Recorded source repository is not Azure DevOps.' }

    $gitCommand = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $gitCommand) { throw 'Git is not available for remote tag lookup.' }
    $gitExecutable = if ($gitCommand.Source) { $gitCommand.Source } else { $gitCommand.Definition }
    $tagLines = @(& $gitExecutable ls-remote --tags --refs $sourceRepository 2>$null)
    if ($LASTEXITCODE -ne 0) { throw 'Remote Azure DevOps tag lookup failed.' }

    $candidates = @()
    foreach ($line in $tagLines) {
        if ($line -match '(?i)\srefs/tags/(v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*))$') {
            $tag = $matches[1]
            $candidates += [pscustomobject]@{ Tag = $tag; Version = [version]$tag.TrimStart('v') }
        }
    }
    if ($candidates.Count -eq 0) { throw 'No valid stable release tags were returned by Azure DevOps.' }

    $latest = $candidates | Sort-Object Version -Descending | Select-Object -First 1
    $isUpdate = $latest.Version -gt ([version]$installedVersion)
    $result = if ($isUpdate) {
        New-VersionCheckResult 'UPDATE_AVAILABLE' 'A newer stable release tag was found.' $installedVersion $latest.Tag $sourceRepository
    } else {
        New-VersionCheckResult 'CURRENT' 'Installed version is current.' $installedVersion $latest.Tag $sourceRepository
    }
} catch {
    $installedVersion = ''
    if (Test-Path $manifestPath -PathType Leaf) {
        try { $installedVersion = [string]((Get-Content $manifestPath -Raw | ConvertFrom-Json).kitVersion) } catch { }
    }
    $result = New-VersionCheckResult 'UNAVAILABLE' 'Remote version check was unavailable; continuing with the installed Dev Kit.' $installedVersion '' ''
}

New-Item -ItemType Directory -Force -Path (Split-Path $resultPath -Parent) | Out-Null
$resultJson = $result | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText($resultPath, $resultJson + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))

Write-VersionCheckOutput $result