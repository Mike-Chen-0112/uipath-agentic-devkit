function Resolve-DevKitTool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet('uip','npm','node','graphify','uv','pipx','dotnet','python','py')]
        [string]$Name,
        [string]$TargetBotPath = (Get-Location).Path,
        [switch]$Required
    )

    $TargetBotPath = (Resolve-Path $TargetBotPath).Path
    $stateDirectory = Join-Path $TargetBotPath '.rpa-ai\local'
    $statePath = Join-Path $stateDirectory 'tool-paths.json'
    $state = @{}
    if (Test-Path $statePath -PathType Leaf) {
        try {
            $saved = Get-Content $statePath -Raw | ConvertFrom-Json
            foreach ($property in $saved.PSObject.Properties) { $state[$property.Name] = [string]$property.Value }
        } catch { Write-Warning "Ignoring invalid local tool cache: $statePath" }
    }

    function Join-OptionalPath {
        param([string]$Base, [string]$Child)
        if (-not $Base) { return $null }
        return Join-Path $Base $Child
    }

    $preferredDirectory = $null
    if ($Name -in @('node','npm')) { $preferredDirectory = Join-OptionalPath $env:LOCALAPPDATA 'RpaAiDevKit\tools\node' }
    elseif ($Name -eq 'uip') { $preferredDirectory = Join-OptionalPath $env:LOCALAPPDATA 'RpaAiDevKit\tools\npm' }
    elseif ($Name -eq 'uv') { $preferredDirectory = Join-OptionalPath $env:LOCALAPPDATA 'RpaAiDevKit\tools\uv' }
    elseif ($Name -eq 'graphify') { $preferredDirectory = Join-OptionalPath $env:USERPROFILE '.local\bin' }

    $rawCandidates = @()
    if ($preferredDirectory) {
        foreach ($extension in @('.exe','.cmd','.bat','.ps1')) {
            $rawCandidates += [pscustomobject]@{ path = (Join-Path $preferredDirectory ($Name + $extension)); source = 'preferred DevKit directory' }
        }
    }
    if ($state.ContainsKey($Name)) { $rawCandidates += [pscustomobject]@{ path = $state[$Name]; source = 'saved custom/local path' } }

    foreach ($command in @(Get-Command $Name -All -CommandType Application,ExternalScript -ErrorAction SilentlyContinue)) {
        $commandPath = if ($command.Path) { $command.Path } elseif ($command.Source) { $command.Source } else { $command.Definition }
        if ($commandPath) { $rawCandidates += [pscustomobject]@{ path = $commandPath; source = 'current process command discovery' } }
    }

    $directories = @(
        (Join-OptionalPath $env:APPDATA 'npm'),
        (Join-OptionalPath $env:USERPROFILE '.local\bin'),
        (Join-OptionalPath $env:LOCALAPPDATA 'Programs\nodejs'),
        (Join-OptionalPath $env:ProgramFiles 'nodejs')
    )
    foreach ($directory in $directories) {
        if (-not $directory) { continue }
        foreach ($extension in @('.exe','.cmd','.bat','.ps1')) {
            $rawCandidates += [pscustomobject]@{ path = (Join-Path $directory ($Name + $extension)); source = 'common user-profile location' }
        }
    }

    $patterns = @(
        (Join-OptionalPath $env:LOCALAPPDATA "Programs\*\$Name.exe"),
        (Join-OptionalPath $env:LOCALAPPDATA "Programs\*\*\$Name.exe"),
        (Join-OptionalPath $env:APPDATA "Python\Python*\Scripts\$Name.exe"),
        (Join-OptionalPath $env:LOCALAPPDATA "Programs\Python\Python*\Scripts\$Name.exe")
    )
    foreach ($pattern in $patterns) {
        if (-not $pattern) { continue }
        foreach ($item in @(Get-Item $pattern -ErrorAction SilentlyContinue)) {
            $rawCandidates += [pscustomobject]@{ path = $item.FullName; source = 'deterministic installation pattern' }
        }
    }

    # Directly executable candidates always precede PowerShell shims. Within each
    # class, preferred managed paths, saved custom configuration, PATH, and common paths
    # retain the deterministic order above.
    $directExtensions = @('.exe','.cmd','.bat')
    $orderedCandidates = @($rawCandidates | Where-Object { [System.IO.Path]::GetExtension([string]$_.path).ToLowerInvariant() -in $directExtensions }) +
        @($rawCandidates | Where-Object { [System.IO.Path]::GetExtension([string]$_.path).ToLowerInvariant() -eq '.ps1' })

    $seen = @{}
    $attempted = @()
    $resolvedPath = $null
    foreach ($candidate in $orderedCandidates) {
        $candidatePath = [string]$candidate.path
        if (-not $candidatePath) { continue }
        $key = $candidatePath.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $extension = [System.IO.Path]::GetExtension($candidatePath).ToLowerInvariant()
        $reason = $null
        if ($extension -notin @('.exe','.cmd','.bat','.ps1')) { $reason = "unsupported extension '$extension'" }
        elseif (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) { $reason = 'file not found' }
        elseif ($extension -eq '.ps1' -and -not (Get-Process -Id $PID -ErrorAction SilentlyContinue).Path) { $reason = 'PowerShell host unavailable' }

        if ($reason) {
            $attempted += "$candidatePath [$($candidate.source): $reason]"
            continue
        }
        try { $resolvedPath = (Resolve-Path -LiteralPath $candidatePath -ErrorAction Stop).Path }
        catch {
            $attempted += "$candidatePath [$($candidate.source): resolution failed]"
            continue
        }
        break
    }

    if ($resolvedPath) {
        if ($Name -in @('npm','uip')) {
            $portableNodeDirectory = Join-OptionalPath $env:LOCALAPPDATA 'RpaAiDevKit\tools\node'
            $portableNode = if ($portableNodeDirectory) { Join-Path $portableNodeDirectory 'node.exe' } else { $null }
            $pathEntries = @($env:PATH -split [System.IO.Path]::PathSeparator)
            if ($portableNode -and (Test-Path $portableNode -PathType Leaf) -and $pathEntries -notcontains $portableNodeDirectory) {
                $env:PATH = $portableNodeDirectory + [System.IO.Path]::PathSeparator + $env:PATH
            }
            if (-not $env:NODE_USE_SYSTEM_CA) { $env:NODE_USE_SYSTEM_CA = '1' }
        }
        if (-not $state.ContainsKey($Name) -or $state[$Name] -ne $resolvedPath) {
            $state[$Name] = $resolvedPath
            New-Item -ItemType Directory -Force -Path $stateDirectory | Out-Null
            $json = [ordered]@{}
            foreach ($key in @($state.Keys | Sort-Object)) { $json[$key] = $state[$key] }
            [System.IO.File]::WriteAllText($statePath, (($json | ConvertTo-Json) + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
        }
        return $resolvedPath
    }

    if ($Required) {
        $attemptedText = if ($attempted.Count -gt 0) { ($attempted | Select-Object -First 20) -join '; ' } else { 'no supported candidate paths were produced' }
        throw "Required tool '$Name' has no launchable .exe, .cmd, .bat, or PowerShell-hosted .ps1 candidate. Attempted: $attemptedText"
    }
    return $null
}
