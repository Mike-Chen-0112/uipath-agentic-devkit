[CmdletBinding()]
param(
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$manifestPath = Join-Path $root 'MANIFEST.sha256'

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "Git is required to enumerate release files."
}

$paths = @(& git -C $root ls-files --cached --others --exclude-standard)
if ($LASTEXITCODE -ne 0) { throw 'git ls-files failed.' }
$paths = @($paths | Where-Object {
    $_ -and $_ -ne 'MANIFEST.sha256' -and $_ -notlike '.ai/evidence/*' -and $_ -notlike '.ai\\evidence\\*' -and (Test-Path (Join-Path $root $_) -PathType Leaf)
} | Sort-Object)

$expected = @($paths | ForEach-Object {
    $fullPath = Join-Path $root $_
    $hash = (Get-FileHash $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  ./$($_.Replace('\','/'))"
})

if ($Check) {
    if (-not (Test-Path $manifestPath -PathType Leaf)) { throw 'MANIFEST.sha256 is missing.' }
    $actual = @(Get-Content $manifestPath | Where-Object { $_.Trim() })
    if ($actual.Count -ne $expected.Count -or (Compare-Object $actual $expected)) {
        throw 'MANIFEST.sha256 is stale. Run scripts/Update-SourceManifest.ps1 after finalizing release files.'
    }
    Write-Host "[PASS] Source manifest verified: $($expected.Count) files"
    return
}

$manifestContent = ($expected -join [Environment]::NewLine) + [Environment]::NewLine
[System.IO.File]::WriteAllText($manifestPath, $manifestContent, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "[PASS] Source manifest updated: $($expected.Count) files"