[CmdletBinding()]
param(
    [string]$ProjectPath = (Get-Location).Path,
    [string]$HandoffPath,
    [string]$ContextPackagePath,
    [string]$ProjectMapPath,
    [string]$GraphContextPath,
    [string[]]$ContextPath = @(),
    [string[]]$SourcePath = @(),
    [string]$OutputPath,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$startedAt = [DateTime]::UtcNow
$ProjectPath = (Resolve-Path $ProjectPath).Path
$projectPrefix = $ProjectPath.TrimEnd('\','/') + [System.IO.Path]::DirectorySeparatorChar
$warnings = New-Object System.Collections.Generic.List[string]
$inputs = New-Object System.Collections.Generic.List[object]
$seen = @{}

function Resolve-ProfilePath {
    param([string]$Path)
    if (-not $Path) { return $null }
    $candidate = if ([System.IO.Path]::IsPathRooted($Path)) { [System.IO.Path]::GetFullPath($Path) } else { [System.IO.Path]::GetFullPath((Join-Path $ProjectPath $Path)) }
    if (-not $candidate.StartsWith($projectPrefix, [System.StringComparison]::OrdinalIgnoreCase) -and $candidate -ne $ProjectPath) {
        throw "Developer context profile path must stay within the project: $Path"
    }
    return $candidate
}

function Add-ProfileInput {
    param([string]$Category, [string]$Path, [bool]$Required = $false)
    if (-not $Path) { return }
    $fullPath = Resolve-ProfilePath $Path
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        if ($Required) { throw "Required Developer context input was not found: $Path" }
        [void]$warnings.Add("Context input was not found: $Path")
        return
    }
    $key = $fullPath.ToLowerInvariant()
    if ($seen.ContainsKey($key)) { return }
    $seen[$key] = $true
    $item = Get-Item -LiteralPath $fullPath
    $characters = $null
    try { $characters = [System.IO.File]::ReadAllText($fullPath, [System.Text.Encoding]::UTF8).Length } catch { }
    $relative = if ($fullPath.StartsWith($projectPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { $fullPath.Substring($projectPrefix.Length) -replace '\\','/' } else { '.' }
    $hash = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [void]$inputs.Add([pscustomobject][ordered]@{
        category = $Category
        path = $relative
        bytes = [int64]$item.Length
        characters = $characters
        estimatedTokens = if ($null -ne $characters) { [int][Math]::Ceiling($characters / 4.0) } else { $null }
        sha256 = $hash
        rawXaml = [System.IO.Path]::GetExtension($fullPath) -ieq '.xaml'
    })
}

Add-ProfileInput 'developerInstructions' '.github/agents/rpa-developer.agent.md' $true
Add-ProfileInput 'agentsContext' 'AGENTS.md' $true
Add-ProfileInput 'executionState' '.ai/evidence/execution-state.json'
Add-ProfileInput 'developerContextPackage' $ContextPackagePath
Add-ProfileInput 'handoff' $HandoffPath
Add-ProfileInput 'projectMap' $ProjectMapPath
Add-ProfileInput 'graphContext' $GraphContextPath
foreach ($path in @($ContextPath)) { Add-ProfileInput 'scopedContext' $path }
foreach ($path in @($SourcePath)) { Add-ProfileInput 'source' $path $true }

$categoryTotals = @($inputs | Group-Object category | ForEach-Object {
    [ordered]@{
        category = $_.Name
        files = $_.Count
        bytes = [int64](($_.Group | Measure-Object bytes -Sum).Sum)
        characters = [int64](($_.Group | Where-Object { $null -ne $_.characters } | Measure-Object characters -Sum).Sum)
        estimatedTokens = [int64](($_.Group | Where-Object { $null -ne $_.estimatedTokens } | Measure-Object estimatedTokens -Sum).Sum)
    }
} | Sort-Object bytes -Descending)

$duplicateGroups = @($inputs | Group-Object sha256 | Where-Object Count -gt 1 | ForEach-Object {
    [ordered]@{ sha256 = $_.Name; paths = @($_.Group | ForEach-Object path); bytesEach = [int64]$_.Group[0].bytes }
})
$evidenceDirectory = Join-Path $ProjectPath '.ai\evidence'
$evidenceFiles = if (Test-Path $evidenceDirectory -PathType Container) { @(Get-ChildItem -LiteralPath $evidenceDirectory -Recurse -File -Force -ErrorAction SilentlyContinue) } else { @() }
$totalBytes = [int64](($inputs | Measure-Object bytes -Sum).Sum)
$totalCharacters = [int64](($inputs | Where-Object { $null -ne $_.characters } | Measure-Object characters -Sum).Sum)
$contextPackage = $null
if ($ContextPackagePath) {
    $fullContextPackagePath = Resolve-ProfilePath $ContextPackagePath
    if (Test-Path -LiteralPath $fullContextPackagePath -PathType Leaf) {
        $contextPackage = [System.IO.File]::ReadAllText($fullContextPackagePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    }
}
$packageInput = @($inputs | Where-Object category -eq 'developerContextPackage' | Select-Object -First 1)
$developerInstructionBytes = [int64](($inputs | Where-Object category -eq 'developerInstructions' | Measure-Object bytes -Sum).Sum)
$agentsContextBytes = [int64](($inputs | Where-Object category -eq 'agentsContext' | Measure-Object bytes -Sum).Sum)
$executionStateBytes = [int64](($inputs | Where-Object category -eq 'executionState' | Measure-Object bytes -Sum).Sum)
$handoffBytes = [int64](($inputs | Where-Object category -in @('developerContextPackage','handoff') | Measure-Object bytes -Sum).Sum)
$result = [ordered]@{
    schemaVersion = 1
    capturedAtUtc = [DateTime]::UtcNow.ToString('o')
    measurementScope = 'Explicit repository-visible Developer inputs only; host/system prompts and prior conversation supplied internally by the agent host are not observable.'
    tokenEstimateMethod = 'ceil(UTF-8 decoded character count / 4); deterministic approximation, not a model tokenizer.'
    totalIncludedFiles = $inputs.Count
    totalIncludedBytes = $totalBytes
    totalIncludedCharacters = $totalCharacters
    totalEstimatedTokens = [int][Math]::Ceiling($totalCharacters / 4.0)
    sourceFilesIncluded = @($inputs | Where-Object category -eq 'source').Count
    rawXamlFilesIncluded = @($inputs | Where-Object rawXaml).Count
    fullGraphifyJsonIncluded = [bool]@($inputs | Where-Object { $_.path -ieq 'graphify-out/graph.json' }).Count
    priorRoleTranscriptFilesIncluded = @($inputs | Where-Object { $_.path -match '(?i)(transcript|conversation|chat-history)' }).Count
    compactContext = [ordered]@{
        fastContextUsed = if ($contextPackage) { [bool]$contextPackage.decision.fastContextUsed } else { $false }
        fastContextFallback = if ($contextPackage) { [bool]$contextPackage.decision.fastContextFallback } else { $false }
        fallbackReasons = if ($contextPackage) { @($contextPackage.decision.fallbackReasons) } else { @() }
        packageBytes = if ($packageInput.Count) { [int64]$packageInput[0].bytes } else { 0 }
        scopedProjectMapBytes = if ($contextPackage) { [int64]$contextPackage.metrics.scopedProjectMapBytes } else { [int64](($inputs | Where-Object category -eq 'projectMap' | Measure-Object bytes -Sum).Sum) }
        graphSummaryBytes = if ($contextPackage) { [int64]$contextPackage.metrics.graphSummaryBytes } else { [int64](($inputs | Where-Object category -eq 'graphContext' | Measure-Object bytes -Sum).Sum) }
        rawXamlBytesInitiallyIncluded = if ($contextPackage) { [int64]$contextPackage.metrics.rawXamlBytesInitiallyIncluded } else { [int64](($inputs | Where-Object { $_.category -eq 'source' -and $_.rawXaml } | Measure-Object bytes -Sum).Sum) }
        xamlExcerptBytesInitiallyIncluded = if ($contextPackage) { [int64]$contextPackage.metrics.xamlExcerptBytesInitiallyIncluded } else { 0 }
        handoffBytes = $handoffBytes
        developerInstructionBytes = $developerInstructionBytes
        agentsContextBytes = $agentsContextBytes
        executionStateBytes = $executionStateBytes
        workflowsRepresented = if ($contextPackage) { [int]$contextPackage.metrics.workflowsRepresented } else { 0 }
        sourceFilesInitiallyIncluded = if ($contextPackage) { [int]$contextPackage.metrics.sourceFilesInitiallyIncluded } else { @($inputs | Where-Object category -eq 'source').Count }
        contextExpansionCount = if ($contextPackage) { @($contextPackage.contextExpansions).Count } else { 0 }
        contextExpansionBytes = if ($contextPackage) { [int64](($contextPackage.contextExpansions | Measure-Object additionalBytes -Sum).Sum) } else { 0 }
        rawSourceFallbackUsed = if ($contextPackage) { [bool]$contextPackage.sourceAccess.rawSourceFallbackUsed } else { $false }
        contextExpansions = if ($contextPackage) { @($contextPackage.contextExpansions) } else { @() }
    }
    duplicateContentGroups = $duplicateGroups
    categoryTotals = $categoryTotals
    largestContributors = @($inputs | Sort-Object bytes -Descending | Select-Object -First 10)
    inputs = $inputs.ToArray()
    availableEvidence = [ordered]@{
        files = $evidenceFiles.Count
        bytes = [int64](($evidenceFiles | Measure-Object Length -Sum).Sum)
        includedFiles = @($inputs | Where-Object category -eq 'executionState').Count + @($inputs | Where-Object category -eq 'handoff').Count
    }
    hostProvidedContext = [ordered]@{
        systemPrompt = 'NOT_INSTRUMENTABLE'
        priorConversation = 'NOT_INSTRUMENTABLE'
        modelRequestPayload = 'NOT_INSTRUMENTABLE'
    }
    warnings = $warnings.ToArray()
    durationSeconds = [Math]::Round(([DateTime]::UtcNow - $startedAt).TotalSeconds, 3)
}

if ($OutputPath) {
    $fullOutputPath = Resolve-ProfilePath $OutputPath
    New-Item -ItemType Directory -Force -Path (Split-Path $fullOutputPath -Parent) | Out-Null
    [System.IO.File]::WriteAllText($fullOutputPath, (($result | ConvertTo-Json -Depth 12) + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
}
if ($Json) { $result | ConvertTo-Json -Depth 12 } else { $result }
