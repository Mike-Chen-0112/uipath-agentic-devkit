[CmdletBinding()]
param(
    [string]$TargetBotPath = (Get-Location).Path,
    [ValidateSet('Auto','Uv','Pipx')]
    [string]$Installer = 'Auto',
    [switch]$ForceReinstall,
    [switch]$InstallVsCodeIntegration,
    [switch]$InstallGitHooks
)

$ErrorActionPreference = 'Stop'
$TargetBotPath = (Resolve-Path $TargetBotPath).Path
$version = 'unknown'
$centralVersionPath = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path 'VERSION'
$installedManifestPath = Join-Path $TargetBotPath '.rpa-ai\kit-manifest.json'
if (Test-Path $centralVersionPath -PathType Leaf) {
    $version = (Get-Content $centralVersionPath -Raw).Trim()
} elseif (Test-Path $installedManifestPath -PathType Leaf) {
    try { $version = [string]((Get-Content $installedManifestPath -Raw | ConvertFrom-Json).kitVersion) } catch { }
}
if ($InstallVsCodeIntegration -or $InstallGitHooks) {
    throw "Graphify VS Code integration and git hooks are disabled by the v$version local-only policy. Use the hardened Dev Kit wrappers."
}
$resolverScript = Join-Path $PSScriptRoot 'Resolve-DevKitTool.ps1'
if (-not (Test-Path $resolverScript -PathType Leaf)) { throw "Tool resolver is missing: $resolverScript" }
. $resolverScript
$centralPin = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path 'graph\config\graphify-version.json'
$payloadPin = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path 'validation\graphify-version.json'
$pinPath = if (Test-Path $centralPin -PathType Leaf) { $centralPin } elseif (Test-Path $payloadPin -PathType Leaf) { $payloadPin } else { $null }
if (-not $pinPath) { throw 'Graphify version policy was not found in the central kit or bot payload.' }
$config = Get-Content $pinPath -Raw | ConvertFrom-Json
$version = [string]$config.version
$packageSpec = "$($config.package)==$version"
$script:graphifyProbeFailed = $false

function Invoke-LocalGraphify {
    param(
        [Parameter(Mandatory=$true)]
        [string[]]$GraphifyArguments,
        [Parameter(Mandatory=$true)]
        [string]$Operation
    )

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
    $blockedNames = @($blockedNames | Sort-Object -Unique)
    $saved = @{}

    try {
        foreach ($name in $blockedNames) {
            $item = Get-Item "Env:$name" -ErrorAction SilentlyContinue
            if ($item) { $saved[$name] = $item.Value }
            Remove-Item "Env:$name" -ErrorAction SilentlyContinue
        }
        $env:GRAPHIFY_QUERY_LOG_DISABLE = '1'
        $env:HTTP_PROXY = 'http://127.0.0.1:1'
        $env:HTTPS_PROXY = 'http://127.0.0.1:1'
        $env:ALL_PROXY = 'http://127.0.0.1:1'
        $env:http_proxy = $env:HTTP_PROXY
        $env:https_proxy = $env:HTTPS_PROXY
        $env:all_proxy = $env:ALL_PROXY
        $env:NO_PROXY = ''
        $env:no_proxy = ''
        $env:HF_HUB_OFFLINE = '1'
        $env:TRANSFORMERS_OFFLINE = '1'
        $output = (& $script:graphifyCommand @GraphifyArguments 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { throw "$Operation failed with exit code $LASTEXITCODE." }
        return $output
    }
    finally {
        foreach ($name in $blockedNames) {
            Remove-Item "Env:$name" -ErrorAction SilentlyContinue
            if ($saved.ContainsKey($name)) { Set-Item "Env:$name" $saved[$name] }
        }
    }
}

function Get-GraphifyVersion {
    $script:graphifyCommand = Resolve-DevKitTool -Name graphify -TargetBotPath $TargetBotPath
    if (-not $script:graphifyCommand) { return $null }
    try {
        $text = Invoke-LocalGraphify -GraphifyArguments @('--version') -Operation 'Graphify version check'
    } catch {
        $script:graphifyProbeFailed = $true
        $script:graphifyCommand = $null
        return $null
    }
    if ($text -match '(\d+\.\d+\.\d+)') { return $Matches[1] }
    return $text
}

$current = Get-GraphifyVersion
if ($current -and $current -ne $version -and -not $ForceReinstall) {
    throw "Graphify $current is installed, but this Dev Kit pins $version. Re-run with -ForceReinstall after reviewing the pinned version change."
}

if (-not $current -or $ForceReinstall) {
    if ($Installer -eq 'Auto') {
        if (Resolve-DevKitTool -Name uv -TargetBotPath $TargetBotPath) { $Installer = 'Uv' }
        elseif (Resolve-DevKitTool -Name pipx -TargetBotPath $TargetBotPath) { $Installer = 'Pipx' }
        else { throw "Neither 'uv' nor 'pipx' is available. Install one of them, then re-run." }
    }

    if ($ForceReinstall -and $current) {
        if ($Installer -eq 'Uv' -and ($uvCommand = Resolve-DevKitTool -Name uv -TargetBotPath $TargetBotPath)) {
            & $uvCommand tool uninstall graphifyy 2>$null | Out-Null
        } elseif ($Installer -eq 'Pipx' -and ($pipxCommand = Resolve-DevKitTool -Name pipx -TargetBotPath $TargetBotPath)) {
            & $pipxCommand uninstall graphifyy 2>$null | Out-Null
        }
    }

    if ($Installer -eq 'Uv') {
        $uvCommand = Resolve-DevKitTool -Name uv -TargetBotPath $TargetBotPath -Required
        $installArguments = @('tool','install',$packageSpec)
        if ($script:graphifyProbeFailed) { $installArguments += '--force' }
        & $uvCommand @installArguments
        if ($LASTEXITCODE -ne 0) { throw "uv tool install failed." }
    } else {
        $pipxCommand = Resolve-DevKitTool -Name pipx -TargetBotPath $TargetBotPath -Required
        $installArguments = @('install',$packageSpec)
        if ($script:graphifyProbeFailed) { $installArguments += '--force' }
        & $pipxCommand @installArguments
        if ($LASTEXITCODE -ne 0) { throw "pipx install failed." }
    }
}

$current = Get-GraphifyVersion
if ($current -ne $version) {
    throw "Graphify installation verification failed. Expected $version; got '$current'."
}

# Force query logs off in this process. Runtime wrappers do the same for every agent query.
$env:GRAPHIFY_QUERY_LOG_DISABLE = '1'

Write-Host "[PASS] Graphify $version ready for $TargetBotPath"
Write-Host "Default Dev Kit policy: code/XAML graph only; query logging forced off by wrappers."
