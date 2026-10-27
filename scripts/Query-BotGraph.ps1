[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$Question,
    [string]$TargetBotPath = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'
$TargetBotPath = (Resolve-Path $TargetBotPath).Path
$graphPath = Join-Path $TargetBotPath 'graphify-out\graph.json'
if (-not (Test-Path $graphPath)) { throw "Graph not found: $graphPath. Run Refresh-BotGraph.ps1 -Mode Build first." }
$resolverScript = Join-Path $PSScriptRoot 'Resolve-DevKitTool.ps1'
if (-not (Test-Path $resolverScript -PathType Leaf)) { throw "Tool resolver is missing: $resolverScript" }
. $resolverScript
$graphifyCommand = Resolve-DevKitTool -Name graphify -TargetBotPath $TargetBotPath -Required

$installedScriptRoot = [System.IO.Path]::GetFullPath((Join-Path $TargetBotPath '.rpa-ai\scripts')).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
$currentScriptRoot = [System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
$installedManifestPath = Join-Path $TargetBotPath '.rpa-ai\kit-manifest.json'
if ($currentScriptRoot -eq $installedScriptRoot -or (Test-Path $installedManifestPath -PathType Leaf)) {
    $integrityScript = Join-Path $TargetBotPath '.rpa-ai\scripts\Test-ManagedFileIntegrity.ps1'
    if (-not (Test-Path $integrityScript -PathType Leaf)) { throw "Managed-file integrity script is missing: $integrityScript" }
    & $integrityScript -TargetBotPath $TargetBotPath
}

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
        & $graphifyCommand @GraphifyArguments
        if ($LASTEXITCODE -ne 0) { throw "$Operation failed with exit code $LASTEXITCODE." }
    }
    finally {
        foreach ($name in $blockedNames) {
            Remove-Item "Env:$name" -ErrorAction SilentlyContinue
            if ($saved.ContainsKey($name)) { Set-Item "Env:$name" $saved[$name] }
        }
    }
}

$pinFile = Join-Path $TargetBotPath '.rpa-ai\validation\graphify-version.json'
if (Test-Path $pinFile) {
    $pin = Get-Content $pinFile -Raw | ConvertFrom-Json
    $versionText = (Invoke-LocalGraphify -GraphifyArguments @('--version') -Operation 'Graphify version check' 2>&1 | Out-String).Trim()
    if ($versionText -notmatch [regex]::Escape([string]$pin.version)) {
        throw "Graphify version mismatch. Bot expects $($pin.version); installed CLI reports '$versionText'."
    }
}

Push-Location $TargetBotPath
try {
    Invoke-LocalGraphify -GraphifyArguments @('query',$Question,'--graph',$graphPath) -Operation 'Graphify query'
}
finally { Pop-Location }
