[CmdletBinding()]
param(
    [string]$TargetBotPath = (Get-Location).Path
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
    throw "Managed root is a reparse point: '$TargetBotPath'"
}
$TargetBotPath = (Resolve-Path $TargetBotPath).Path
$manifestPath = Join-Path $TargetBotPath '.rpa-ai\kit-manifest.json'
$manifestDigestPath = Join-Path $TargetBotPath '.rpa-ai\kit-manifest.sha256'

function Resolve-ContainedPath {
    param([string]$Root, [string]$RelativePath)

    if (-not $RelativePath -or [System.IO.Path]::IsPathRooted($RelativePath)) {
        throw "Managed path must be relative: '$RelativePath'"
    }
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $Root $RelativePath))
    $rootPrefix = $Root.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Managed path escapes the bot root: '$RelativePath'"
    }
    return $candidate
}

function Assert-NoReparsePointAncestors {
    param([string]$Root, [string]$Candidate)

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    if (Test-IsReparsePoint $Root) {
            throw "Managed root is a reparse point: '$rootFull'"
    }
    $cursor = if (Test-Path $Candidate) { $Candidate } else { Split-Path $Candidate -Parent }
    while ($cursor -and $cursor.Length -gt $rootFull.Length) {
        if (Test-IsReparsePoint $cursor) {
                throw "Managed path crosses a reparse point: '$cursor'"
        }
        $cursor = Split-Path $cursor -Parent
    }
}

if (-not (Test-Path $manifestPath -PathType Leaf)) {
    throw "Installed Dev Kit manifest not found: $manifestPath"
}
if (-not (Test-Path $manifestDigestPath -PathType Leaf)) {
    throw "Installed Dev Kit manifest digest not found: $manifestDigestPath"
}
Assert-NoReparsePointAncestors $TargetBotPath $manifestPath
Assert-NoReparsePointAncestors $TargetBotPath $manifestDigestPath

$manifestDigest = (Get-Content $manifestDigestPath -Raw).Trim()
if ($manifestDigest -notmatch '^[0-9a-fA-F]{64}$' -or
    (Get-FileHash $manifestPath -Algorithm SHA256).Hash -ne $manifestDigest) {
    throw 'Installed Dev Kit manifest digest verification failed.'
}

$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
if ($manifest.schemaVersion -ne 1) { throw "Unsupported installed manifest schema: $($manifest.schemaVersion)" }
if (-not $manifest.kitVersion) { throw 'Installed manifest kitVersion is required.' }
if (-not $manifest.files -or @($manifest.files).Count -eq 0) { throw 'Installed manifest contains no files.' }

$managedFiles = @()
foreach ($file in @($manifest.files)) {
    if ($file.ownership -notin @('managed','preserve')) {
        throw "Unknown installed ownership '$($file.ownership)' for '$($file.path)'"
    }
    if ([string]$file.sha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw "Invalid installed SHA-256 value for '$($file.path)'"
    }
    $resolvedPath = Resolve-ContainedPath $TargetBotPath ([string]$file.path)
    Assert-NoReparsePointAncestors $TargetBotPath $resolvedPath
    if ($file.ownership -eq 'managed') {
        $managedFiles += [pscustomobject]@{
            Path = [string]$file.path
            ExpectedHash = ([string]$file.sha256).ToLowerInvariant()
            ResolvedPath = $resolvedPath
        }
    }
}

$duplicates = @($managedFiles | Group-Object ResolvedPath | Where-Object Count -gt 1)
if ($duplicates.Count -gt 0) {
    throw "Installed manifest has duplicate normalized managed paths: $($duplicates.Name -join ', ')"
}

$failures = @()
foreach ($file in $managedFiles) {
    if (-not (Test-Path $file.ResolvedPath -PathType Leaf)) {
        $failures += [pscustomobject]@{ Status = 'MISSING'; Path = $file.Path }
        continue
    }
    $currentHash = (Get-FileHash $file.ResolvedPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($currentHash -ne $file.ExpectedHash) {
        $failures += [pscustomobject]@{ Status = 'MODIFIED'; Path = $file.Path }
    }
}

$gitignorePath = Join-Path $TargetBotPath '.gitignore'
$marker = '# BEGIN RPA AI DEV KIT'
$endMarker = '# END RPA AI DEV KIT'
$blockPattern = '(?s)' + [regex]::Escape($marker) + '.*?' + [regex]::Escape($endMarker)
$gitignoreContent = if (Test-Path $gitignorePath -PathType Leaf) { Get-Content $gitignorePath -Raw } else { '' }
$currentBlock = [regex]::Match($gitignoreContent, $blockPattern)
$expectedBlock = (@($marker) + @($manifest.gitignoreEntries | ForEach-Object { [string]$_ }) + @($endMarker)) -join "`n"
if (-not $currentBlock.Success -or (($currentBlock.Value -replace "`r?`n", "`n") -ne $expectedBlock)) {
    $failures += [pscustomobject]@{ Status = 'MODIFIED'; Path = '.gitignore (managed block)' }
}

if ($failures.Count -gt 0) {
    $failures | Format-Table -AutoSize
    throw "Managed Dev Kit integrity failed for $($failures.Count) path(s). Restore them with a reviewed payload import."
}

Write-Host "[PASS] Managed Dev Kit integrity: $($managedFiles.Count) file(s) and .gitignore block"
Write-Host "Kit version: $($manifest.kitVersion)"