[CmdletBinding()]
param(
    [string]$TargetBotPath = (Get-Location).Path,
    [switch]$IncludeGraphify
)

$ErrorActionPreference = 'Stop'
$TargetBotPath = (Resolve-Path $TargetBotPath).Path
$resolverScript = Join-Path $PSScriptRoot 'Resolve-DevKitTool.ps1'
if (-not (Test-Path $resolverScript -PathType Leaf)) { throw "Tool resolver is missing: $resolverScript" }
. $resolverScript

if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is required for user-scoped Dev Kit tools.' }
$toolsRoot = Join-Path $env:LOCALAPPDATA 'RpaAiDevKit\tools'
$downloadRoot = Join-Path $env:TEMP ('rpa-ai-prerequisites-' + [guid]::NewGuid().ToString('N'))

function Invoke-DevKitDownload {
    param(
        [Parameter(Mandatory=$true)][string]$Uri,
        [Parameter(Mandatory=$true)][string]$OutFile
    )

    $kitVersion = 'unknown'
    $manifestPath = Join-Path $TargetBotPath '.rpa-ai\kit-manifest.json'
    if (Test-Path $manifestPath -PathType Leaf) {
        try { $kitVersion = [string]((Get-Content $manifestPath -Raw | ConvertFrom-Json).kitVersion) } catch { }
    }
    $parameters = @{
        Uri = $Uri
        OutFile = $OutFile
        Headers = @{ 'User-Agent' = "RpaAiDevKit/$kitVersion" }
    }
    if ($PSVersionTable.PSEdition -eq 'Desktop') { $parameters.UseBasicParsing = $true }
    Invoke-WebRequest @parameters
}

function Assert-DownloadedHash {
    param(
        [Parameter(Mandatory=$true)][string]$ArchivePath,
        [Parameter(Mandatory=$true)][string]$ChecksumPath,
        [Parameter(Mandatory=$true)][string]$ArchiveName
    )

    $checksumText = Get-Content $ChecksumPath -Raw
    $escapedName = [regex]::Escape($ArchiveName)
    $match = [regex]::Match($checksumText, "(?im)^([a-f0-9]{64})\s+\*?$escapedName\s*$")
    if (-not $match.Success) {
        $match = [regex]::Match($checksumText, '(?i)\b([a-f0-9]{64})\b')
    }
    if (-not $match.Success) { throw "Publisher checksum was not found for $ArchiveName." }

    $expectedHash = $match.Groups[1].Value.ToLowerInvariant()
    $actualHash = (Get-FileHash $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) { throw "SHA-256 verification failed for $ArchiveName." }
}

function Get-WindowsArchitecture {
    $architecture = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    if ($architecture -match 'ARM64') { return 'arm64' }
    if ($architecture -match 'AMD64') { return 'x64' }
    throw "Unsupported Windows architecture '$architecture'."
}

function Test-DevKitCommand {
    param(
        [string]$Command,
        [string]$Argument = '--version',
        [switch]$IsGraphify
    )

    if (-not $Command) { return $false }
    $blockedNames = @()
    $saved = @{}
    if ($IsGraphify) {
        $blockedNames = @(
            'ANTHROPIC_API_KEY','ANTHROPIC_BASE_URL','ANTHROPIC_MODEL',
            'GEMINI_API_KEY','GOOGLE_API_KEY','GOOGLE_APPLICATION_CREDENTIALS',
            'OPENAI_API_KEY','OPENAI_BASE_URL','OPENAI_MODEL',
            'DEEPSEEK_API_KEY','MOONSHOT_API_KEY',
            'AZURE_OPENAI_API_KEY','AZURE_OPENAI_ENDPOINT','AZURE_OPENAI_API_VERSION','AZURE_OPENAI_DEPLOYMENT','GRAPHIFY_AZURE_MODEL',
            'OLLAMA_BASE_URL','OLLAMA_MODEL','GRAPHIFY_GOOGLE_WORKSPACE',
            'GRAPHIFY_TRIAGE_BACKEND','GRAPHIFY_TRIAGE_MODEL',
            'GRAPHIFY_QUERY_LOG_ENABLE','GRAPHIFY_QUERY_LOG','GRAPHIFY_QUERY_LOG_RESPONSES','GRAPHIFY_QUERY_LOG_DISABLE',
            'HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY','http_proxy','https_proxy','all_proxy','no_proxy',
            'HF_HUB_OFFLINE','TRANSFORMERS_OFFLINE'
        )
        $blockedNames += @(Get-ChildItem Env: | Where-Object Name -like 'AWS_*' | ForEach-Object Name)
    }
    try {
        foreach ($name in $blockedNames) {
            $item = Get-Item "Env:$name" -ErrorAction SilentlyContinue
            if ($item) { $saved[$name] = $item.Value }
            Remove-Item "Env:$name" -ErrorAction SilentlyContinue
        }
        if ($IsGraphify) {
            $env:GRAPHIFY_QUERY_LOG_DISABLE = '1'
            $env:HTTP_PROXY = 'http://127.0.0.1:1'
            $env:HTTPS_PROXY = 'http://127.0.0.1:1'
            $env:ALL_PROXY = 'http://127.0.0.1:1'
            $env:HF_HUB_OFFLINE = '1'
            $env:TRANSFORMERS_OFFLINE = '1'
        }
        & $Command $Argument *> $null
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    } finally {
        foreach ($name in $blockedNames) {
            Remove-Item "Env:$name" -ErrorAction SilentlyContinue
            if ($saved.ContainsKey($name)) { Set-Item "Env:$name" $saved[$name] }
        }
    }
}

function Install-PortableNode {
    $architecture = Get-WindowsArchitecture
    $indexPath = Join-Path $downloadRoot 'node-index.json'
    Invoke-DevKitDownload -Uri 'https://nodejs.org/dist/index.json' -OutFile $indexPath
    $releases = Get-Content $indexPath -Raw | ConvertFrom-Json
    $fileNameToken = "win-$architecture-zip"
    $release = $null
    $releaseVersion = $null
    foreach ($candidate in $releases) {
        if (-not $candidate.lts -or $candidate.files -notcontains $fileNameToken -or
            [string]$candidate.version -notmatch '^v\d+\.\d+\.\d+$') { continue }
        $candidateVersion = [version]([string]$candidate.version).TrimStart('v')
        if (-not $release -or $candidateVersion -gt $releaseVersion) {
            $release = $candidate
            $releaseVersion = $candidateVersion
        }
    }
    if (-not $release) {
        throw "Official Node.js metadata contains no Windows $architecture LTS ZIP."
    }

    $version = [string]$release.version
    $archiveName = "node-$version-win-$architecture.zip"
    $releaseBase = "https://nodejs.org/dist/$version"
    $archivePath = Join-Path $downloadRoot $archiveName
    $checksumPath = Join-Path $downloadRoot 'node-SHASUMS256.txt'
    Invoke-DevKitDownload -Uri "$releaseBase/$archiveName" -OutFile $archivePath
    Invoke-DevKitDownload -Uri "$releaseBase/SHASUMS256.txt" -OutFile $checksumPath
    Assert-DownloadedHash -ArchivePath $archivePath -ChecksumPath $checksumPath -ArchiveName $archiveName

    $extractPath = Join-Path $downloadRoot 'node-extract'
    Expand-Archive -Path $archivePath -DestinationPath $extractPath -Force
    $source = Get-ChildItem $extractPath -Directory | Where-Object Name -eq "node-$version-win-$architecture" | Select-Object -First 1
    if (-not $source -or -not (Test-Path (Join-Path $source.FullName 'node.exe') -PathType Leaf) -or
        -not (Test-Path (Join-Path $source.FullName 'npm.cmd') -PathType Leaf)) {
        throw 'Verified Node.js archive did not contain node.exe and npm.cmd.'
    }

    $destination = Join-Path $toolsRoot 'node'
    Remove-Item $destination -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $toolsRoot | Out-Null
    Move-Item $source.FullName $destination
    Write-Host "[PASS] Installed portable Node.js $version for the current user."
}

function Install-PortableUv {
    $architecture = Get-WindowsArchitecture
    $target = if ($architecture -eq 'arm64') { 'aarch64-pc-windows-msvc' } else { 'x86_64-pc-windows-msvc' }
    $metadataPath = Join-Path $downloadRoot 'uv-release.json'
    Invoke-DevKitDownload -Uri 'https://api.github.com/repos/astral-sh/uv/releases/latest' -OutFile $metadataPath
    $release = Get-Content $metadataPath -Raw | ConvertFrom-Json
    $archiveName = "uv-$target.zip"
    $checksumName = "$archiveName.sha256"
    $archiveAsset = @($release.assets | Where-Object name -eq $archiveName | Select-Object -First 1)
    $checksumAsset = @($release.assets | Where-Object name -eq $checksumName | Select-Object -First 1)
    if ($archiveAsset.Count -ne 1 -or $checksumAsset.Count -ne 1) {
        throw "Official uv release '$($release.tag_name)' does not contain the expected Windows assets."
    }
    foreach ($uri in @([string]$archiveAsset[0].browser_download_url, [string]$checksumAsset[0].browser_download_url)) {
        if ($uri -notmatch '^https://github\.com/astral-sh/uv/releases/download/') {
            throw "Unexpected uv download location '$uri'."
        }
    }

    $archivePath = Join-Path $downloadRoot $archiveName
    $checksumPath = Join-Path $downloadRoot $checksumName
    Invoke-DevKitDownload -Uri $archiveAsset[0].browser_download_url -OutFile $archivePath
    Invoke-DevKitDownload -Uri $checksumAsset[0].browser_download_url -OutFile $checksumPath
    Assert-DownloadedHash -ArchivePath $archivePath -ChecksumPath $checksumPath -ArchiveName $archiveName

    $extractPath = Join-Path $downloadRoot 'uv-extract'
    Expand-Archive -Path $archivePath -DestinationPath $extractPath -Force
    $uvExecutable = Get-ChildItem $extractPath -Recurse -File -Filter 'uv.exe' | Select-Object -First 1
    if (-not $uvExecutable) { throw 'Verified uv archive did not contain uv.exe.' }

    $destination = Join-Path $toolsRoot 'uv'
    Remove-Item $destination -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    Copy-Item $uvExecutable.FullName (Join-Path $destination 'uv.exe')
    $uvxExecutable = Get-ChildItem $extractPath -Recurse -File -Filter 'uvx.exe' | Select-Object -First 1
    if ($uvxExecutable) { Copy-Item $uvxExecutable.FullName (Join-Path $destination 'uvx.exe') }
    Write-Host "[PASS] Installed uv $($release.tag_name) for the current user."
}

try {
    New-Item -ItemType Directory -Force -Path $downloadRoot | Out-Null
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $uipCommand = Resolve-DevKitTool -Name uip -TargetBotPath $TargetBotPath
    if (-not (Test-DevKitCommand -Command $uipCommand -Argument '--help')) {
        $npmCommand = Resolve-DevKitTool -Name npm -TargetBotPath $TargetBotPath
        if (-not (Test-DevKitCommand $npmCommand)) { Install-PortableNode }
    }
    if ($IncludeGraphify) {
    $graphifyCommand = Resolve-DevKitTool -Name graphify -TargetBotPath $TargetBotPath
    if (-not (Test-DevKitCommand -Command $graphifyCommand -IsGraphify)) {
        $uvCommand = Resolve-DevKitTool -Name uv -TargetBotPath $TargetBotPath
        $pipxCommand = Resolve-DevKitTool -Name pipx -TargetBotPath $TargetBotPath
        if (-not (Test-DevKitCommand $uvCommand) -and -not (Test-DevKitCommand $pipxCommand)) {
            Install-PortableUv
        }
    }

    }
    if (-not (Resolve-DevKitTool -Name uip -TargetBotPath $TargetBotPath)) {
        $npmCommand = Resolve-DevKitTool -Name npm -TargetBotPath $TargetBotPath -Required
        if (-not (Test-DevKitCommand $npmCommand)) { throw 'User-scoped npm verification failed.' }
    }
    if ($IncludeGraphify -and -not (Resolve-DevKitTool -Name graphify -TargetBotPath $TargetBotPath)) {
        $uvOrPipx = Resolve-DevKitTool -Name uv -TargetBotPath $TargetBotPath
        if (-not $uvOrPipx) { $uvOrPipx = Resolve-DevKitTool -Name pipx -TargetBotPath $TargetBotPath -Required }
        if (-not (Test-DevKitCommand $uvOrPipx)) { throw 'Graphify installer verification failed.' }
    }
}
finally {
    Remove-Item $downloadRoot -Recurse -Force -ErrorAction SilentlyContinue
}