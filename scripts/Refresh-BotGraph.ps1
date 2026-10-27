[CmdletBinding()]
param(
    [ValidateSet('Status','Build','Update')]
    [string]$Mode = 'Status',
    [string]$TargetBotPath = (Get-Location).Path,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$TargetBotPath = (Resolve-Path $TargetBotPath).Path
$graphPath = Join-Path $TargetBotPath 'graphify-out\graph.json'
$reportPath = Join-Path $TargetBotPath 'graphify-out\GRAPH_REPORT.md'
$refreshStatePath = Join-Path $TargetBotPath 'graphify-out\refresh-state.json'
$resolverScript = Join-Path $PSScriptRoot 'Resolve-DevKitTool.ps1'
$fingerprintScript = Join-Path $PSScriptRoot 'SourceFingerprint.ps1'
$commandScript = Join-Path $PSScriptRoot 'Invoke-DevKitCommand.ps1'
if (-not (Test-Path $resolverScript -PathType Leaf)) { throw "Tool resolver is missing: $resolverScript" }
if (-not (Test-Path $fingerprintScript -PathType Leaf)) { throw "Source fingerprint script is missing: $fingerprintScript" }
if (-not (Test-Path $commandScript -PathType Leaf)) { throw "Command helper is missing: $commandScript" }
. $resolverScript
$graphifyCommand = Resolve-DevKitTool -Name graphify -TargetBotPath $TargetBotPath -Required

function Get-SourceSnapshot {
    return (& $fingerprintScript -ProjectPath $TargetBotPath -Json | ConvertFrom-Json)
}

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
        $commandResult = & $commandScript -FilePath $graphifyCommand -ArgumentList $GraphifyArguments -WorkingDirectory $TargetBotPath -TargetBotPath $TargetBotPath -Operation $Operation -Category GRAPHIFY -Subcategory $(if($GraphifyArguments -contains 'extract'){'extraction'}else{'startup'}) -TimeoutSeconds 300 -Json | ConvertFrom-Json
        if ($commandResult.output) { Write-Output $commandResult.output }
        if ($commandResult.error) {
            if ($commandResult.status -eq 'PASS') { Write-Warning ([string]$commandResult.error).Trim() }
            else { Write-Error $commandResult.error }
        }
        if ($commandResult.status -ne 'PASS') { throw "$Operation ended with status $($commandResult.status)." }
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
    switch ($Mode) {
        'Status' {
            Invoke-LocalGraphify -GraphifyArguments @('--version') -Operation 'Graphify status check'
            if (Test-Path $graphPath) {
                $item = Get-Item $graphPath
                Write-Host "[PASS] Graph: $($item.FullName)"
                Write-Host "Last written: $($item.LastWriteTime)"
                if (Test-Path $reportPath) { Write-Host "Report: $reportPath" }
            } else {
                Write-Warning "No bot graph found yet."
                exit 2
            }
        }
        'Build' {
            Invoke-LocalGraphify -GraphifyArguments @('extract','.','--code-only','--no-cluster') -Operation 'Graphify build'
            $snapshot = $null
            try { $snapshot = Get-SourceSnapshot } catch { $snapshot = $null }
            if ($snapshot) {
                [ordered]@{
                    schemaVersion = 2
                    fingerprintSchemaVersion = [int]$snapshot.schemaVersion
                    fingerprint = [string]$snapshot.sourceFingerprint
                    sourceFingerprint = [string]$snapshot.sourceFingerprint
                    graphConfigFingerprint = [string]$snapshot.graphConfigFingerprint
                    refreshedAtUtc = [DateTime]::UtcNow.ToString('o')
                } | ConvertTo-Json | Set-Content $refreshStatePath -Encoding UTF8
            } elseif (Test-Path $refreshStatePath) {
                Remove-Item $refreshStatePath -Force -ErrorAction SilentlyContinue
            }
        }
        'Update' {
            $snapshot = $null
            try { $snapshot = Get-SourceSnapshot } catch { $snapshot = $null }
            $currentFingerprint = if ($snapshot) { [string]$snapshot.sourceFingerprint } else { $null }
            $currentGraphConfigFingerprint = if ($snapshot) { [string]$snapshot.graphConfigFingerprint } else { $null }

            $reused = $false
            if (-not $Force -and $currentFingerprint -and (Test-Path $refreshStatePath) -and (Test-Path $graphPath)) {
                try {
                    $priorState = Get-Content $refreshStatePath -Raw | ConvertFrom-Json
                    if ($priorState.schemaVersion -eq 2 -and $priorState.fingerprintSchemaVersion -eq [int]$snapshot.schemaVersion -and $priorState.fingerprint -eq $currentFingerprint -and $priorState.graphConfigFingerprint -eq $currentGraphConfigFingerprint) {
                        $graphContent = (Get-Content $graphPath -Raw)
                        if ($graphContent -and $graphContent.Trim().Length -gt 0) {
                            [void](ConvertFrom-Json $graphContent)
                            $reused = $true
                        }
                    }
                } catch { $reused = $false }
            }

            if ($reused) {
                if (Test-Path -LiteralPath (Join-Path $TargetBotPath '.ai\evidence\execution-state.json') -PathType Leaf) {
                    Import-Module (Join-Path $PSScriptRoot 'DeveloperTelemetry.psm1') -Force -DisableNameChecking
                    Add-DeveloperInstantEvent -ProjectPath $TargetBotPath -Category GRAPHIFY -Subcategory reuse -Operation 'graphify.reuse' -Artifacts @([ordered]@{path='graphify-out/graph.json'}) | Out-Null
                }
                Write-Host "[PASS] Graph: $graphPath (REUSED - source unchanged since last refresh)"
            } else {
                Invoke-LocalGraphify -GraphifyArguments @('extract','.','--code-only','--no-cluster') -Operation 'Graphify update'
                if ($currentFingerprint) {
                    [ordered]@{
                        schemaVersion = 2
                        fingerprintSchemaVersion = if ($snapshot) { [int]$snapshot.schemaVersion } else { 2 }
                        fingerprint = $currentFingerprint
                        sourceFingerprint = $currentFingerprint
                        graphConfigFingerprint = $currentGraphConfigFingerprint
                        refreshedAtUtc = [DateTime]::UtcNow.ToString('o')
                    } | ConvertTo-Json | Set-Content $refreshStatePath -Encoding UTF8
                } elseif (Test-Path $refreshStatePath) {
                    Remove-Item $refreshStatePath -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
}
finally { Pop-Location }
