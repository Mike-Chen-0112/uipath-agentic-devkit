[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path (Get-Location).Path 'artifacts'),
    [string]$ManifestPath,
    [switch]$NoZip,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$kitRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ManifestPath = if ($ManifestPath) { (Resolve-Path $ManifestPath).Path } else { Join-Path $kitRoot 'distribution\payload-manifest.json' }
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

function Resolve-ContainedPath {
    param([string]$Root, [string]$RelativePath, [string]$Purpose)

    if (-not $RelativePath -or [System.IO.Path]::IsPathRooted($RelativePath)) {
        throw "$Purpose path must be relative: '$RelativePath'"
    }
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $Root $RelativePath))
    $rootPrefix = $Root.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Purpose path escapes its root: '$RelativePath'"
    }
    return $candidate
}

function Get-CanonicalSourceRepository {
    $gitCommand = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $gitCommand) { throw 'Git is required to record the canonical Azure DevOps repository.' }
    $gitExecutable = if ($gitCommand.Source) { $gitCommand.Source } else { $gitCommand.Definition }
    $remoteOutput = @(& $gitExecutable -C $kitRoot config --get remote.origin.url 2>$null)
    $gitExitCode = $LASTEXITCODE
    $remote = $remoteOutput | Select-Object -First 1
    if ($gitExitCode -ne 0 -or -not $remote) { throw 'The canonical Azure DevOps repository could not be determined from Git remote.origin.url.' }
    $remote = ([string]$remote).Trim()
    if ($remote -notmatch '(?i)^https://(?:[^/@]+@)?([^/]+\.)?dev\.azure\.com/' -and
        $remote -notmatch '(?i)^https://(?:[^/@]+@)?[^/]+\.visualstudio\.com/' -and
        $remote -notmatch '(?i)^git@ssh\.dev\.azure\.com:') {
        throw "Git origin is not an Azure DevOps repository: '$remote'"
    }
    return $remote
}

if ($manifest.schemaVersion -ne 1) { throw "Unsupported payload source manifest schema: $($manifest.schemaVersion)" }
if (-not $manifest.files -or @($manifest.files).Count -eq 0) { throw 'Payload source manifest contains no files.' }
foreach ($entry in @($manifest.gitignoreEntries)) {
    if (-not $entry -or [string]$entry -match '[\r\n]' -or $entry -in @('# BEGIN RPA AI DEV KIT','# END RPA AI DEV KIT')) {
        throw "Invalid gitignore entry in payload source manifest: '$entry'"
    }
}

$versionPath = Resolve-ContainedPath $kitRoot ([string]$manifest.kitVersionFile) 'Version file'
if (-not (Test-Path $versionPath -PathType Leaf)) { throw "VERSION source is missing: $versionPath" }
$version = (Get-Content $versionPath -Raw).Trim()

if ($version -notmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$') {
    throw "VERSION must be a stable semantic version: '$version'"
}
$sourceRepository = Get-CanonicalSourceRepository

$payloadName = "rpa-ai-devkit-bot-$version"
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
$payloadPath = Join-Path $OutputDirectory $payloadName
$zipPath = "$payloadPath.zip"

$validatedFiles = @($manifest.files | ForEach-Object {
    if ($_.ownership -notin @('managed','preserve')) { throw "Unknown payload ownership '$($_.ownership)' for '$($_.destination)'" }
    $sourcePath = Resolve-ContainedPath $kitRoot ([string]$_.source) 'Payload source'
    $destinationPath = Resolve-ContainedPath $payloadPath ([string]$_.destination) 'Payload destination'
    [pscustomobject]@{
        SourceRelative = [string]$_.source
        DestinationRelative = [string]$_.destination
        Ownership = [string]$_.ownership
        Source = $sourcePath
        Destination = $destinationPath
    }
})

$duplicates = @($validatedFiles | Group-Object Destination | Where-Object Count -gt 1)
if ($duplicates.Count -gt 0) {
    throw "Payload manifest has duplicate destinations: $($duplicates.Name -join ', ')"
}

$missing = @($validatedFiles | Where-Object { -not (Test-Path $_.Source -PathType Leaf) })
if ($missing.Count -gt 0) {
    throw "Payload sources are missing: $($missing.SourceRelative -join ', ')"
}

if ((Test-Path $payloadPath) -or (Test-Path $zipPath)) {
    if (-not $Force) {
        throw "Output already exists. Re-run with -Force after reviewing it: $payloadPath"
    }
    Remove-Item $payloadPath -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
}

New-Item -ItemType Directory -Force -Path $payloadPath | Out-Null

$installedFiles = foreach ($file in $validatedFiles) {
    $source = $file.Source
    $destination = $file.Destination
    New-Item -ItemType Directory -Force -Path (Split-Path $destination -Parent) | Out-Null
    Copy-Item $source $destination

    [ordered]@{
        path = $file.DestinationRelative
        ownership = $file.Ownership
        sha256 = (Get-FileHash $source -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

$metadata = [ordered]@{
    schemaVersion = 1
    kitVersion = $version
    sourceRepository = $sourceRepository
    files = @($installedFiles)
    gitignoreEntries = @($manifest.gitignoreEntries)
}
$metadataPath = Join-Path $payloadPath '.rpa-ai\kit-manifest.json'
New-Item -ItemType Directory -Force -Path (Split-Path $metadataPath -Parent) | Out-Null
$metadataJson = $metadata | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText($metadataPath, $metadataJson + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
$metadataDigestPath = Join-Path $payloadPath '.rpa-ai\kit-manifest.sha256'
$metadataDigest = (Get-FileHash $metadataPath -Algorithm SHA256).Hash.ToLowerInvariant()
[System.IO.File]::WriteAllText($metadataDigestPath, $metadataDigest + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))

if (-not $NoZip) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        $payloadRootPrefix = $payloadPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
        foreach ($file in Get-ChildItem -LiteralPath $payloadPath -Recurse -File -Force) {
            $entryName = $file.FullName.Substring($payloadRootPrefix.Length).Replace('\','/')
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $entryName, [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    }
    finally {
        $archive.Dispose()
    }
}

Write-Host "[PASS] Bot payload: $payloadPath"
if (-not $NoZip) {
    Write-Host "[PASS] Bot payload ZIP: $zipPath"
}