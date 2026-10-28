[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$PayloadPath,

    [Parameter(Mandatory=$true)]
    [string]$TargetBotPath,

    [switch]$Upgrade,
    [switch]$OverwriteManaged,
    [switch]$EnableGraphify
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

if (Test-IsReparsePoint $PayloadPath) {
    throw "Payload root is a reparse point: '$PayloadPath'"
}
if (Test-IsReparsePoint $TargetBotPath) {
    throw "Target root is a reparse point: '$TargetBotPath'"
}
$PayloadPath = (Resolve-Path $PayloadPath).Path
$TargetBotPath = (Resolve-Path $TargetBotPath).Path
$incomingManifestPath = Join-Path $PayloadPath '.rpa-ai\kit-manifest.json'
$incomingManifestDigestPath = Join-Path $PayloadPath '.rpa-ai\kit-manifest.sha256'
$installedManifestPath = Join-Path $TargetBotPath '.rpa-ai\kit-manifest.json'
$installedManifestDigestPath = Join-Path $TargetBotPath '.rpa-ai\kit-manifest.sha256'

function Resolve-ContainedPath {
    param([string]$Root, [string]$RelativePath)

    if (-not $RelativePath -or [System.IO.Path]::IsPathRooted($RelativePath)) {
        throw "Payload path must be relative: '$RelativePath'"
    }
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $Root $RelativePath))
    $rootPrefix = $Root.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Payload path escapes its root: '$RelativePath'"
    }
    return $candidate
}

function Assert-NoReparsePointAncestors {
    param([string]$Root, [string]$Candidate)

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    if (Test-IsReparsePoint $Root) {
            throw "Payload root is a reparse point: '$rootFull'"
    }
    $cursor = if (Test-Path $Candidate) { $Candidate } else { Split-Path $Candidate -Parent }
    while ($cursor -and $cursor.Length -gt $rootFull.Length) {
        if (Test-IsReparsePoint $cursor) {
                throw "Payload path crosses a reparse point: '$cursor'"
        }
        $cursor = Split-Path $cursor -Parent
    }
}

function Get-GitIgnoreBlock {
    param([object[]]$Entries)

    return @('# BEGIN RPA AI DEV KIT') + @($Entries | ForEach-Object { [string]$_ }) + @('# END RPA AI DEV KIT') -join "`r`n"
}

function ConvertTo-Crlf {
    param([string]$Value)
    return ($Value -replace "`r?`n", "`r`n")
}

Assert-NoReparsePointAncestors $PayloadPath $incomingManifestPath
Assert-NoReparsePointAncestors $PayloadPath $incomingManifestDigestPath
Assert-NoReparsePointAncestors $TargetBotPath $installedManifestPath
Assert-NoReparsePointAncestors $TargetBotPath $installedManifestDigestPath

if (-not (Test-Path $incomingManifestPath -PathType Leaf)) {
    throw "Payload manifest not found: $incomingManifestPath"
}
if (-not (Test-Path $incomingManifestDigestPath -PathType Leaf)) {
    throw "Payload manifest digest not found: $incomingManifestDigestPath"
}
$incomingManifestDigest = (Get-Content $incomingManifestDigestPath -Raw).Trim()
if ($incomingManifestDigest -notmatch '^[0-9a-fA-F]{64}$' -or
    (Get-FileHash $incomingManifestPath -Algorithm SHA256).Hash -ne $incomingManifestDigest) {
    throw 'Payload manifest digest verification failed.'
}

if ((Test-Path $installedManifestPath -PathType Leaf) -or (Test-Path $installedManifestDigestPath -PathType Leaf)) {
    if (-not (Test-Path $installedManifestPath -PathType Leaf) -or -not (Test-Path $installedManifestDigestPath -PathType Leaf)) {
        throw 'Installed Dev Kit manifest or detached digest is missing.'
    }
    $installedManifestDigest = (Get-Content $installedManifestDigestPath -Raw).Trim()
    if ($installedManifestDigest -notmatch '^[0-9a-fA-F]{64}$' -or
        (Get-FileHash $installedManifestPath -Algorithm SHA256).Hash -ne $installedManifestDigest) {
        throw 'Installed Dev Kit manifest digest verification failed.'
    }
}

$incoming = Get-Content $incomingManifestPath -Raw | ConvertFrom-Json
$installed = if (Test-Path $installedManifestPath -PathType Leaf) {
    Get-Content $installedManifestPath -Raw | ConvertFrom-Json
} else {
    $null
}

if ($incoming.schemaVersion -ne 1) { throw "Unsupported payload manifest schema: $($incoming.schemaVersion)" }
if (-not $incoming.kitVersion) { throw 'Payload manifest kitVersion is required.' }
if (-not $incoming.files -or @($incoming.files).Count -eq 0) { throw 'Payload manifest contains no files.' }
foreach ($entry in @($incoming.gitignoreEntries)) {
    if (-not $entry -or [string]$entry -match '[\r\n]' -or $entry -in @('# BEGIN RPA AI DEV KIT','# END RPA AI DEV KIT')) {
        throw "Invalid gitignore entry in payload manifest: '$entry'"
    }
}

$validatedFiles = @(foreach ($file in $incoming.files) {
    if ($file.ownership -notin @('managed','preserve')) { throw "Unknown payload ownership '$($file.ownership)' for '$($file.path)'" }
    if ([string]$file.sha256 -notmatch '^[0-9a-fA-F]{64}$') { throw "Invalid SHA-256 value for '$($file.path)'" }
    $sourcePath = Resolve-ContainedPath $PayloadPath ([string]$file.path)
    $destinationPath = Resolve-ContainedPath $TargetBotPath ([string]$file.path)
    Assert-NoReparsePointAncestors $PayloadPath $sourcePath
    Assert-NoReparsePointAncestors $TargetBotPath $destinationPath
    [pscustomobject]@{
        Path = [string]$file.path
        Ownership = [string]$file.ownership
        Sha256 = ([string]$file.sha256).ToLowerInvariant()
        Source = $sourcePath
        Destination = $destinationPath
    }
})

$duplicatePaths = @($validatedFiles | Group-Object Destination | Where-Object Count -gt 1)
if ($duplicatePaths.Count -gt 0) { throw "Payload manifest has duplicate normalized paths: $($duplicatePaths.Name -join ', ')" }

$activationEntries = @($validatedFiles | Where-Object Path -eq '.rpa-ai/scripts/Activate-RpaAiDevKit.ps1')
if ($activationEntries.Count -ne 1) {
    throw 'Payload manifest must contain exactly one managed .rpa-ai/scripts/Activate-RpaAiDevKit.ps1 entry.'
}
if ($activationEntries[0].Ownership -ne 'managed') {
    throw 'Payload activation script must be marked managed.'
}

if ($installed -and $installed.schemaVersion -ne 1) { throw "Unsupported installed manifest schema: $($installed.schemaVersion)" }
if ($installed) {
    $installedNormalizedPaths = @($installed.files | ForEach-Object { Resolve-ContainedPath $TargetBotPath ([string]$_.path) })
    $installedDuplicates = @($installedNormalizedPaths | Group-Object | Where-Object Count -gt 1)
    if ($installedDuplicates.Count -gt 0) { throw "Installed manifest has duplicate normalized paths: $($installedDuplicates.Name -join ', ')" }
}

$actions = @(foreach ($file in $validatedFiles) {
    $source = $file.Source
    $destination = $file.Destination

    if (-not (Test-Path $source -PathType Leaf)) {
        throw "Payload file is missing: $($file.Path)"
    }

    $sourceHash = (Get-FileHash $source -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($sourceHash -ne $file.Sha256) {
        throw "Payload hash mismatch: $($file.Path)"
    }

    if (Test-Path $destination -PathType Container) {
        throw "Payload file destination is an existing directory: $($file.Path)"
    }

    if (-not (Test-Path $destination -PathType Leaf)) {
        [pscustomobject]@{ Path = $file.Path; Action = 'ADD'; Source = $source; Destination = $destination }
        continue
    }

    $currentHash = (Get-FileHash $destination -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($currentHash -eq $sourceHash) {
        [pscustomobject]@{ Path = $file.Path; Action = 'MATCH'; Source = $source; Destination = $destination }
        continue
    }

    if ($file.Ownership -eq 'preserve') {
        [pscustomobject]@{ Path = $file.Path; Action = 'PRESERVE'; Source = $source; Destination = $destination }
        continue
    }

    $previous = if ($installed) { @($installed.files | Where-Object path -eq $file.Path)[0] } else { $null }
    $unchangedSinceInstall = $previous -and $previous.sha256 -eq $currentHash

    if ($OverwriteManaged) {
        [pscustomobject]@{ Path = $file.Path; Action = 'OVERWRITE'; Source = $source; Destination = $destination }
    } elseif ($Upgrade -and $unchangedSinceInstall) {
        [pscustomobject]@{ Path = $file.Path; Action = 'UPGRADE'; Source = $source; Destination = $destination }
    } elseif ($unchangedSinceInstall) {
        [pscustomobject]@{ Path = $file.Path; Action = 'NEEDS_UPGRADE'; Source = $source; Destination = $destination }
    } else {
        [pscustomobject]@{ Path = $file.Path; Action = 'CONFLICT'; Source = $source; Destination = $destination }
    }
})

$gitignorePath = Join-Path $TargetBotPath '.gitignore'
Assert-NoReparsePointAncestors $TargetBotPath $gitignorePath
$marker = '# BEGIN RPA AI DEV KIT'
$endMarker = '# END RPA AI DEV KIT'
$gitignoreCurrent = if (Test-Path $gitignorePath -PathType Leaf) { Get-Content $gitignorePath -Raw } else { '' }
$desiredGitignoreBlock = Get-GitIgnoreBlock @($incoming.gitignoreEntries)
$blockPattern = '(?s)' + [regex]::Escape($marker) + '.*?' + [regex]::Escape($endMarker)
$currentBlockMatch = [regex]::Match($gitignoreCurrent, $blockPattern)
$gitignoreAction = 'MATCH'

if (-not $currentBlockMatch.Success) {
    $gitignoreAction = 'ADD'
} elseif ((ConvertTo-Crlf $currentBlockMatch.Value) -eq $desiredGitignoreBlock) {
    $gitignoreAction = 'MATCH'
} else {
    $previousBlock = if ($installed) { Get-GitIgnoreBlock @($installed.gitignoreEntries) } else { $null }
    $unchangedGitignore = $previousBlock -and ((ConvertTo-Crlf $currentBlockMatch.Value) -eq $previousBlock)
    if ($OverwriteManaged) { $gitignoreAction = 'OVERWRITE' }
    elseif ($Upgrade -and $unchangedGitignore) { $gitignoreAction = 'UPGRADE' }
    elseif ($unchangedGitignore) { $gitignoreAction = 'NEEDS_UPGRADE' }
    else { $gitignoreAction = 'CONFLICT' }
}

$actions += [pscustomobject]@{ Path = '.gitignore (managed block)'; Action = $gitignoreAction; Source = $null; Destination = $gitignorePath }

$actions | Select-Object Action,Path | Sort-Object Action,Path | Format-Table -AutoSize

$blocked = @($actions | Where-Object Action -in @('CONFLICT','NEEDS_UPGRADE'))
if ($blocked.Count -gt 0) {
    $conflicts = @($blocked | Where-Object Action -eq 'CONFLICT')
    $outdated = @($blocked | Where-Object Action -eq 'NEEDS_UPGRADE')
    if ($outdated.Count -gt 0) {
        Write-Host "Re-run with -Upgrade to replace $($outdated.Count) unchanged managed file(s)."
    }
    if ($conflicts.Count -gt 0) {
        Write-Host "Review $($conflicts.Count) locally modified or legacy managed file(s). Use -OverwriteManaged only after review."
    }
    throw 'RPA AI Dev Kit import blocked by managed-file preflight.'
}

$backupRoot = Join-Path $env:TEMP ('rpa-ai-import-rollback-' + [guid]::NewGuid().ToString('N'))
$applied = [System.Collections.Generic.List[object]]::new()
$createdDirectories = [System.Collections.Generic.List[string]]::new()

try {
    New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
    Assert-NoReparsePointAncestors $TargetBotPath $installedManifestPath
    Assert-NoReparsePointAncestors $TargetBotPath $gitignorePath
    foreach ($action in $actions | Where-Object { $_.Path -ne '.gitignore (managed block)' -and $_.Action -in @('ADD','UPGRADE','OVERWRITE') }) {
        Assert-NoReparsePointAncestors $TargetBotPath $action.Destination
        $parent = Split-Path $action.Destination -Parent
        $missingParents = [System.Collections.Generic.List[string]]::new()
        $cursor = $parent
        while ($cursor -and -not (Test-Path $cursor)) {
            $missingParents.Add($cursor)
            $cursor = Split-Path $cursor -Parent
        }
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
        foreach ($directory in $missingParents) { $createdDirectories.Add($directory) }

        $existed = Test-Path $action.Destination -PathType Leaf
        $backup = $null
        if ($existed) {
            $backup = Join-Path $backupRoot ([guid]::NewGuid().ToString('N'))
            Copy-Item $action.Destination $backup
        }
        $applied.Add([pscustomobject]@{ Destination = $action.Destination; Existed = $existed; Backup = $backup })
        Copy-Item $action.Source $action.Destination -Force
    }

    if ($gitignoreAction -in @('ADD','UPGRADE','OVERWRITE')) {
        $gitignoreExisted = Test-Path $gitignorePath -PathType Leaf
        $gitignoreBackup = $null
        if ($gitignoreExisted) {
            $gitignoreBackup = Join-Path $backupRoot ([guid]::NewGuid().ToString('N'))
            Copy-Item $gitignorePath $gitignoreBackup
        }
        $applied.Add([pscustomobject]@{ Destination = $gitignorePath; Existed = $gitignoreExisted; Backup = $gitignoreBackup })
        if ($currentBlockMatch.Success) {
            $newGitignore = [regex]::Replace($gitignoreCurrent, $blockPattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $desiredGitignoreBlock }, 1)
        } else {
            $separator = if ($gitignoreCurrent -and -not $gitignoreCurrent.EndsWith("`n")) { "`r`n" } else { '' }
            $newGitignore = $gitignoreCurrent + $separator + $desiredGitignoreBlock + "`r`n"
        }
        [System.IO.File]::WriteAllText($gitignorePath, $newGitignore, [System.Text.UTF8Encoding]::new($false))
    }

    $manifestParent = Split-Path $installedManifestPath -Parent
    New-Item -ItemType Directory -Force -Path $manifestParent | Out-Null
    $manifestExisted = Test-Path $installedManifestPath -PathType Leaf
    $manifestBackup = $null
    if ($manifestExisted) {
        $manifestBackup = Join-Path $backupRoot ([guid]::NewGuid().ToString('N'))
        Copy-Item $installedManifestPath $manifestBackup
    }
    $applied.Add([pscustomobject]@{ Destination = $installedManifestPath; Existed = $manifestExisted; Backup = $manifestBackup })
    Copy-Item $incomingManifestPath $installedManifestPath -Force

    $manifestDigestExisted = Test-Path $installedManifestDigestPath -PathType Leaf
    $manifestDigestBackup = $null
    if ($manifestDigestExisted) {
        $manifestDigestBackup = Join-Path $backupRoot ([guid]::NewGuid().ToString('N'))
        Copy-Item $installedManifestDigestPath $manifestDigestBackup
    }
    $applied.Add([pscustomobject]@{ Destination = $installedManifestDigestPath; Existed = $manifestDigestExisted; Backup = $manifestDigestBackup })
    Copy-Item $incomingManifestDigestPath $installedManifestDigestPath -Force
}
catch {
    for ($index = $applied.Count - 1; $index -ge 0; $index--) {
        $item = $applied[$index]
        Assert-NoReparsePointAncestors $TargetBotPath $item.Destination
        if ($item.Existed) { Copy-Item $item.Backup $item.Destination -Force }
        else { Remove-Item $item.Destination -Force -ErrorAction SilentlyContinue }
    }
    foreach ($directory in @($createdDirectories) | Sort-Object Length -Descending -Unique) {
        if ((Test-Path $directory -PathType Container) -and -not (Get-ChildItem $directory -Force | Select-Object -First 1)) {
            Remove-Item $directory -Force -ErrorAction SilentlyContinue
        }
    }
    throw "Import failed and applied paths were rolled back: $($_.Exception.Message)"
}
finally {
    Remove-Item $backupRoot -Recurse -Force -ErrorAction SilentlyContinue
}

try {
    & $activationEntries[0].Destination -TargetBotPath $TargetBotPath -EnableGraphify:$EnableGraphify
} catch {
    throw "Dev Kit files were imported, but mandatory activation failed. Fix the local prerequisite and run '.rpa-ai\scripts\Activate-RpaAiDevKit.ps1': $($_.Exception.Message)"
}

Write-Host "[PASS] RPA AI Dev Kit $($incoming.kitVersion) imported into $TargetBotPath"
Write-Host "Managed files changed: $(@($actions | Where-Object Action -in @('ADD','UPGRADE','OVERWRITE')).Count)"
Write-Host "Bot-owned files preserved: $(@($actions | Where-Object Action -eq 'PRESERVE').Count)"