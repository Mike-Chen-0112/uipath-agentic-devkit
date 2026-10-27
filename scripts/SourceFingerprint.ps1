[CmdletBinding()]
param(
    [ValidateSet('Get')]
    [string]$Action = 'Get',
    [string]$ProjectPath = (Get-Location).Path,
    [string]$CachePath,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$ProjectPath = (Resolve-Path $ProjectPath).Path
$CachePath = if ($CachePath) { [System.IO.Path]::GetFullPath($CachePath) } else { Join-Path $ProjectPath '.ai\evidence\source-fingerprint-cache.json' }
$schemaVersion = 4
$excludedSegments = @('.git','graphify-out','bin','obj','packages','node_modules','TestResults','test-results','coverage','dist','build','target','outputs','output','out','artifacts','generated','.local','.venv','venv')
$graphConfigPaths = @('.graphifyignore','.graphifyrc','.rpa-ai/validation/graphify-version.json','graph/config/graphify-version.json')

function Get-NormalizedRelativePath {
    param([string]$FullPath)
    return $FullPath.Substring($ProjectPath.Length).TrimStart('\','/') -replace '\\','/'
}

function Test-ExcludedPath {
    param([string]$RelativePath)
    $parts = $RelativePath -split '/'
    if ($parts | Where-Object { $_ -in $excludedSegments }) { return $true }
    if ($RelativePath -like '.rpa-ai/local/*' -or
        $RelativePath -like '.ai/evidence/*' -or
        $RelativePath -like '.uipath/*' -or
        $RelativePath -like '.github/skills/*') { return $true }
    return $false
}

function Get-FileKind {
    param([string]$RelativePath)
    if ($graphConfigPaths -contains $RelativePath) { return 'graph'
    }
    if ($RelativePath -like 'Requirements/*') { return 'documentation' }
    $extension = [System.IO.Path]::GetExtension($RelativePath).ToLowerInvariant()
    if (($extension -in @('.md','.markdown','.rst')) -and $RelativePath -notlike '.github/*') { return 'documentation' }
    if ($RelativePath -like 'docs/*' -or $RelativePath -like '.ai/context/*') { return 'documentation' }
    return 'executable'
}

function Get-HashText {
    param([string]$Value)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Value))) -replace '-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-FileHashCached {
    param($File, $Cached)
    $lastWrite = $File.LastWriteTimeUtc.Ticks
    if ($Cached -and [int64]$Cached.length -eq [int64]$File.Length -and [int64]$Cached.last_write_ticks -eq $lastWrite -and [string]$Cached.sha256 -match '^[0-9a-fA-F]{64}$') {
        return [string]$Cached.sha256
    }
    return (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
}

$cachedFiles = @{}
$cacheStatus = 'MISS'
if (Test-Path $CachePath -PathType Leaf) {
    try {
        $cache = [System.IO.File]::ReadAllText($CachePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($cache.schemaVersion -eq $schemaVersion) {
            foreach ($entry in @($cache.files)) { $cachedFiles[[string]$entry.path] = $entry }
            $cacheStatus = 'PARTIAL_REUSE'
        }
    } catch { $cacheStatus = 'INVALID' }
}

$fileRecords = [System.Collections.Generic.List[object]]::new()
$files = @(Get-ChildItem -LiteralPath $ProjectPath -Recurse -File -Force | Where-Object {
    $relative = Get-NormalizedRelativePath $_.FullName
    -not (Test-ExcludedPath $relative)
})
foreach ($file in ($files | Sort-Object { Get-NormalizedRelativePath $_.FullName })) {
    $relative = Get-NormalizedRelativePath $file.FullName
    $kind = Get-FileKind $relative
    $cached = $cachedFiles[$relative]
    $hash = Get-FileHashCached $file $cached
    [void]$fileRecords.Add([ordered]@{ path = $relative; kind = $kind; length = [int64]$file.Length; last_write_ticks = [int64]$file.LastWriteTimeUtc.Ticks; sha256 = $hash })
}

function Get-CategoryFingerprint {
    param([string]$Kind)
    $lines = @($fileRecords | Where-Object kind -eq $Kind | Sort-Object path | ForEach-Object { "$($_.path)|$($_.sha256)" })
    return Get-HashText ($lines -join "`n")
}

$result = [ordered]@{
    schemaVersion = $schemaVersion
    capturedAtUtc = [DateTime]::UtcNow.ToString('o')
    sourceFingerprint = Get-CategoryFingerprint 'executable'
    executableFingerprint = Get-CategoryFingerprint 'executable'
    documentationFingerprint = Get-CategoryFingerprint 'documentation'
    graphConfigFingerprint = Get-CategoryFingerprint 'graph'
    executableFileCount = @($fileRecords | Where-Object kind -eq 'executable').Count
    documentationFileCount = @($fileRecords | Where-Object kind -eq 'documentation').Count
    graphConfigFileCount = @($fileRecords | Where-Object kind -eq 'graph').Count
    cacheStatus = $cacheStatus
    files = @($fileRecords)
}

New-Item -ItemType Directory -Force -Path (Split-Path $CachePath -Parent) | Out-Null
[System.IO.File]::WriteAllText($CachePath, (($result | ConvertTo-Json -Depth 8) + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
if ($Json) { $result | ConvertTo-Json -Depth 8 } else {
    Write-Host "SOURCE_FINGERPRINT_SCHEMA=$schemaVersion"
    Write-Host "SOURCE_FINGERPRINT=$($result.sourceFingerprint)"
    Write-Host "DOCUMENTATION_FINGERPRINT=$($result.documentationFingerprint)"
    Write-Host "GRAPH_CONFIG_FINGERPRINT=$($result.graphConfigFingerprint)"
    Write-Host "FINGERPRINT_CACHE=$cacheStatus"
}
