[CmdletBinding()]
param(
    [switch]$Full
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$testRoot = Join-Path $env:TEMP ('rpa-ai-devkit-tests-' + [guid]::NewGuid().ToString('N'))
$originalPath = $env:PATH
$originalLocalAppData = $env:LOCALAPPDATA
$originalUserProfile = $env:USERPROFILE

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Write-ManifestDigest {
    param([string]$ManifestPath)

    $digestPath = Join-Path (Split-Path $ManifestPath -Parent) 'kit-manifest.sha256'
    (Get-FileHash $ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant() | Set-Content $digestPath -Encoding ascii
}

function New-FakeGraphify {
    param([string]$Directory)

    New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    $powerShellHost = (Get-Process -Id $PID).Path
    @"
@echo off
"$powerShellHost" -NoLogo -NoProfile -File "%~dp0fake-graphify.ps1" %*
exit /b %ERRORLEVEL%
"@ | Set-Content (Join-Path $Directory 'graphify.cmd') -Encoding ascii

    @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)

$record = [ordered]@{
    arguments = $Arguments
    cloudEnvironmentPresent = [bool]($env:OPENAI_API_KEY -or $env:ANTHROPIC_API_KEY -or $env:AWS_ACCESS_KEY_ID)
    queryLoggingDisabled = $env:GRAPHIFY_QUERY_LOG_DISABLE -eq '1'
    networkIsolationEnabled = $env:HTTP_PROXY -eq 'http://127.0.0.1:1' -and
        $env:HTTPS_PROXY -eq 'http://127.0.0.1:1' -and
        $env:ALL_PROXY -eq 'http://127.0.0.1:1' -and
        $env:HF_HUB_OFFLINE -eq '1' -and
        $env:TRANSFORMERS_OFFLINE -eq '1'
}
Add-Content -Path $env:FAKE_GRAPHIFY_LOG -Value ($record | ConvertTo-Json -Compress)
$line = $Arguments -join '|'

if ($line -eq '--version') {
    'graphify 0.9.45'
    exit 0
}
if ($Arguments.Count -ge 2 -and $Arguments[0] -eq 'extract') {
    $output = Join-Path (Get-Location) 'graphify-out'
    New-Item -ItemType Directory -Force -Path $output | Out-Null
    [ordered]@{ nodes = @([ordered]@{ id = 'Main.xaml'; type = 'file' }); edges = @() } |
        ConvertTo-Json -Depth 5 | Set-Content (Join-Path $output 'graph.json') -Encoding UTF8
    '# Graph report' | Set-Content (Join-Path $output 'GRAPH_REPORT.md') -Encoding UTF8
    '<html><body>Graph</body></html>' | Set-Content (Join-Path $output 'graph.html') -Encoding UTF8
    if ($env:FAKE_GRAPHIFY_WARNING -eq '1') { [Console]::Error.WriteLine('warning: source metadata produced zero nodes') }
    exit 0
}
if ($Arguments.Count -ge 1 -and $Arguments[0] -eq 'query') {
    'Main.xaml'
    exit 0
}

Write-Error "Unsupported fake graphify arguments: $line"
exit 2
'@ | Set-Content (Join-Path $Directory 'fake-graphify.ps1') -Encoding UTF8
}

function New-FakeUip {
    param([string]$Directory)

    New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    $powerShellHost = (Get-Process -Id $PID).Path
    @"
@echo off
"$powerShellHost" -NoLogo -NoProfile -File "%~dp0fake-uip.ps1" %*
exit /b %ERRORLEVEL%
"@ | Set-Content (Join-Path $Directory 'uip.cmd') -Encoding ascii

    @"
@echo off
"$powerShellHost" -NoLogo -NoProfile -File "%~dp0fake-npm.ps1" %*
exit /b %ERRORLEVEL%
"@ | Set-Content (Join-Path $Directory 'npm.cmd') -Encoding ascii

    @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)

$family = $env:FAKE_UIP_FAMILY
$line = $Arguments -join '|'
Add-Content -Path $env:FAKE_UIP_LOG -Value $line

if ($line -eq '--help') {
    if ($env:FAKE_UIP_FAIL_HELP -eq '1') { exit 9 }
    'UiPath CLI help'
    exit 0
}
if ($line -eq 'rpa|init|--help') {
    if ($family -eq 'current') { exit 0 } else { exit 2 }
}
if ($line -eq 'rpa|create-project|--help') {
    if ($family -eq 'fallback') { exit 0 } else { exit 2 }
}
if ($line -eq 'rpa|templates|search|--help') {
    if ($family -eq 'current') { exit 0 } else { exit 2 }
}
if ($line -eq 'rpa|search-templates|--help') {
    if ($family -eq 'fallback') { exit 0 } else { exit 2 }
}
if ($line -in @('skills|install|--agent|copilot|--local','skills|update|--agent|copilot|--local')) {
    exit 0
}

if ($line -match '^rpa\|(templates\|search|search-templates)\|') {
    if ($env:FAKE_TEMPLATE_MODE -eq 'noofficial') {
        $results = @(
            [ordered]@{ packageId = 'Marketplace.REFramework'; version = '9.9.9'; title = 'Community Framework'; source = 'Marketplace' }
        )
        ConvertTo-Json -InputObject $results -Compress
        exit 0
    }
    if ($env:FAKE_TEMPLATE_MODE -eq 'multiple') {
        $results = @(
            [ordered]@{ packageId = 'UiPath.Template.REFramework'; version = '1.2.3'; title = 'REFramework'; source = 'Official' },
            [ordered]@{ packageId = 'UiPath.Template.REFramework.Modern'; version = '2.0.0'; title = 'Modern REFramework'; source = 'Official' }
        )
        ConvertTo-Json -InputObject $results -Compress
        exit 0
    }
    $results = @(
        [ordered]@{
            packageId = 'UiPath.Template.REFramework'
            version = '1.2.3'
            title = 'Robotic Enterprise Framework'
            source = 'Official'
        }
    )
    ConvertTo-Json -InputObject $results -Compress
    exit 0
}

if ($Arguments.Count -ge 2 -and $Arguments[0] -eq 'rpa' -and $Arguments[1] -in @('init','create-project')) {
    $values = @{}
    for ($index = 2; $index -lt $Arguments.Count; $index++) {
        if ($Arguments[$index] -like '--*' -and $index + 1 -lt $Arguments.Count -and $Arguments[$index + 1] -notlike '--*') {
            $values[$Arguments[$index]] = $Arguments[$index + 1]
            $index++
        }
    }

    $projectPath = Join-Path $values['--location'] $values['--name']
    New-Item -ItemType Directory -Force -Path $projectPath | Out-Null
    [ordered]@{
        name = $values['--name']
        main = 'Main.xaml'
        dependencies = [ordered]@{}
        expressionLanguage = $values['--expression-language']
        targetFramework = if ($env:FAKE_PROJECT_MISMATCH -eq 'framework') { 'Windows' } else { $values['--target-framework'] }
        designOptions = [ordered]@{ outputType = 'Process' }
    } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $projectPath 'project.json') -Encoding UTF8
    '<Activity />' | Set-Content (Join-Path $projectPath 'Main.xaml') -Encoding UTF8
    if ($values.ContainsKey('--template-package-id')) {
        $frameworkPath = Join-Path $projectPath 'Framework'
        New-Item -ItemType Directory -Force -Path $frameworkPath | Out-Null
        '<Activity />' | Set-Content (Join-Path $frameworkPath 'GetTransactionData.xaml') -Encoding UTF8
        '<Activity />' | Set-Content (Join-Path $projectPath 'Process.xaml') -Encoding UTF8
        '<Activity />' | Set-Content (Join-Path $frameworkPath 'SetTransactionStatus.xaml') -Encoding UTF8
    }
    '{"success":true}'
    if ($env:FAKE_CREATE_EXIT) { exit [int]$env:FAKE_CREATE_EXIT }
    exit 0
}

Write-Error "Unsupported fake uip arguments: $line"
exit 2
'@ | Set-Content (Join-Path $Directory 'fake-uip.ps1') -Encoding UTF8

    @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)

if ($Arguments.Count -eq 1 -and $Arguments[0] -eq '--version') {
    'npm 0.0.0-test'
    exit 0
}
if ($env:FAKE_UIP_FAIL_HELP -eq '1') { exit 9 }
exit 0
'@ | Set-Content (Join-Path $Directory 'fake-npm.ps1') -Encoding UTF8
}

function New-FakeGit {
    param([string]$Directory)

    New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    $powerShellHost = (Get-Process -Id $PID).Path
    @"
@echo off
"$powerShellHost" -NoLogo -NoProfile -File "%~dp0fake-git.ps1" %*
exit /b %ERRORLEVEL%
"@ | Set-Content (Join-Path $Directory 'git.cmd') -Encoding ascii

    @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)

$line = $Arguments -join '|'
if (($Arguments -contains 'config' -and $Arguments -contains '--get' -and $Arguments -contains 'remote.origin.url') -or
    $line -match '(?i)config.*--get.*remote\.origin\.url') {
    'https://dev.azure.com/de-deloitte/GES%20Tech%20Team/_git/uipath-agentic-devkit'
    exit 0
}
if (($Arguments.Count -ge 1 -and $Arguments[0] -eq 'ls-remote') -or $line -match '(?i)(^|\|)ls-remote(\||$)') {
    if ($env:FAKE_GIT_FAIL_TAGS -eq '1') { exit 7 }
    if ($Arguments -contains '--exit-code' -or $line -match '(?i)--exit-code') {
        "0000000000000000000000000000000000000000`trefs/tags/v0.10.0"
        "0000000000000000000000000000000000000000`trefs/tags/v0.11.7"
        exit 0
    }
    if ($env:FAKE_GIT_NO_VALID_TAGS -eq '1') {
        "0000000000000000000000000000000000000000`trefs/tags/release-preview"
        exit 0
    }
    @(
        "0000000000000000000000000000000000000000`trefs/tags/v0.9.0",
        "0000000000000000000000000000000000000000`trefs/tags/v0.10.0",
        "0000000000000000000000000000000000000000`trefs/tags/v0.11.7",
        "0000000000000000000000000000000000000000`trefs/tags/v0.11.0-preview",
        "0000000000000000000000000000000000000000`trefs/tags/release-latest"
    )
    exit 0
}
if (($Arguments.Count -ge 1 -and $Arguments[0] -eq 'clone') -or $line -match '(?i)(^|\|)clone(\||$)') {
    $destination = $Arguments[$Arguments.Count - 1]
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    Get-ChildItem $env:FAKE_DEVKIT_SOURCE_ROOT -Force |
        Where-Object { $_.Name -notin @('.git','artifacts','graphify-out','.rpa-ai') } |
        ForEach-Object { Copy-Item $_.FullName $destination -Recurse -Force }
    if ($env:FAKE_DEVKIT_UPDATE_MARKER) {
        Add-Content (Join-Path $destination 'templates\payload\START-HERE.md') $env:FAKE_DEVKIT_UPDATE_MARKER
    }
    exit 0
}
Write-Error "Unsupported fake git arguments: $line"
exit 2
'@ | Set-Content (Join-Path $Directory 'fake-git.ps1') -Encoding UTF8
}

try {
    New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
    & (Join-Path $root 'scripts\Update-SourceManifest.ps1') -Check
    & (Join-Path $root 'tests\Test-RequirementsWorkspace.ps1')
    & (Join-Path $root 'tests\Test-ProjectMapper.ps1')
    & (Join-Path $root 'tests\Test-DiagnosticsPolicy.ps1')
    & (Join-Path $root 'tests\Test-ToolResolution.ps1')
    & (Join-Path $root 'tests\Test-UiPathRuntime.ps1')
    & (Join-Path $root 'tests\Test-AutonomousRecovery.ps1')
    & (Join-Path $root 'tests\Test-ChangedWorkflowSanity.ps1')
    & (Join-Path $root 'tests\Test-DeveloperProfiling.ps1')
    & (Join-Path $root 'tests\Test-DeveloperFastContext.ps1')
    & (Join-Path $root 'tests\Test-DeveloperFinalization.ps1')
    & (Join-Path $root 'tests\Test-UiTargeting.ps1')
    & (Join-Path $root 'tests\Test-DeveloperObservability.ps1')
    & (Join-Path $root 'tests\Test-UiPathNativeValidation.ps1')
    & (Join-Path $root 'tests\Test-OfficialUiAutomation.ps1')

    if ($Full) {
    $resolverProfile = Join-Path $testRoot 'resolver-profile'
    $resolverBot = Join-Path $testRoot 'resolver-bot'
    $env:LOCALAPPDATA = $resolverProfile
    $env:USERPROFILE = $resolverProfile
    $env:PATH = ''
    $portableNode = Join-Path $resolverProfile 'RpaAiDevKit\tools\node'
    $portableUv = Join-Path $resolverProfile 'RpaAiDevKit\tools\uv'
    $portableNpm = Join-Path $resolverProfile 'RpaAiDevKit\tools\npm'
    $profileBin = Join-Path $env:USERPROFILE '.local\bin'
    New-Item -ItemType Directory -Force -Path $portableNode,$portableUv,$portableNpm,$profileBin,$resolverBot | Out-Null
    $staleNpmDirectory = Join-Path $resolverProfile 'stale-npm'
    New-Item -ItemType Directory -Force -Path $staleNpmDirectory,(Join-Path $resolverBot '.rpa-ai\local') | Out-Null
    '@exit /b 1' | Set-Content (Join-Path $staleNpmDirectory 'npm.cmd') -Encoding ascii
    [System.IO.File]::WriteAllText((Join-Path $resolverBot '.rpa-ai\local\tool-paths.json'), ('{"npm":"' + (Join-Path $staleNpmDirectory 'npm.cmd').Replace('\','\\') + '"}'), (New-Object System.Text.UTF8Encoding($false)))
    'portable node fixture' | Set-Content (Join-Path $portableNode 'node.exe') -Encoding ascii
    '@exit /b 0' | Set-Content (Join-Path $portableNode 'npm.cmd') -Encoding ascii
    $fixturePowerShell = (Get-Process -Id $PID).Path
    $env:FAKE_UV_LOG = Join-Path $resolverProfile 'fake-uv.log'
    @"
@echo off
"$fixturePowerShell" -NoLogo -NoProfile -File "%~dp0fake-uv.ps1" %*
exit /b %ERRORLEVEL%
"@ | Set-Content (Join-Path $portableUv 'uv.cmd') -Encoding ascii
    @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
Add-Content $env:FAKE_UV_LOG ($Arguments -join '|')
if ($Arguments.Count -ge 3 -and $Arguments[0] -eq 'tool' -and $Arguments[1] -eq 'install') {
    '@echo off' + [Environment]::NewLine + 'echo graphify 0.9.45' + [Environment]::NewLine + 'exit /b 0' |
        Set-Content (Join-Path $env:USERPROFILE '.local\bin\graphify.cmd') -Encoding ascii
}
exit 0
'@ | Set-Content (Join-Path $portableUv 'fake-uv.ps1') -Encoding UTF8
    . (Join-Path $root 'scripts\Resolve-DevKitTool.ps1')
    Assert-True ((Resolve-DevKitTool -Name npm -TargetBotPath $resolverBot) -eq (Join-Path $portableNode 'npm.cmd')) 'Portable user-profile npm was not resolved without PATH.'
    Assert-True (@($env:PATH -split [System.IO.Path]::PathSeparator) -contains $portableNode) 'Portable Node was not added to the current process PATH for npm/uip shims.'
    Assert-True ($env:NODE_USE_SYSTEM_CA -eq '1') 'Portable npm was not configured to use the Windows system certificate store.'
    Assert-True ((Resolve-DevKitTool -Name uv -TargetBotPath $resolverBot) -eq (Join-Path $portableUv 'uv.cmd')) 'Portable user-profile uv was not resolved without PATH.'
    $env:STALE_UIP_LOG = Join-Path $resolverProfile 'stale-uip.log'
    "@echo off`necho probed>>`"%STALE_UIP_LOG%`"`nexit /b 1" | Set-Content (Join-Path $portableNpm 'uip.cmd') -Encoding ascii
    & (Join-Path $root 'scripts\Install-DevKitPrerequisites.ps1') -TargetBotPath $resolverBot
    Assert-True (Test-Path $env:STALE_UIP_LOG -PathType Leaf) 'The prerequisite bootstrap trusted an unusable UiPath CLI shim without probing it.'
    Remove-Item Env:STALE_UIP_LOG
    $env:STALE_GRAPHIFY_LOG = Join-Path $resolverProfile 'stale-graphify.log'
    "@echo off`necho probed>>`"%STALE_GRAPHIFY_LOG%`"`nexit /b 1" | Set-Content (Join-Path $profileBin 'graphify.cmd') -Encoding ascii
    & (Join-Path $root 'scripts\Install-DevKitPrerequisites.ps1') -TargetBotPath $resolverBot
    Assert-True (Test-Path $env:STALE_GRAPHIFY_LOG -PathType Leaf) 'The prerequisite bootstrap trusted an unusable Graphify shim without probing it.'
    & (Join-Path $root 'scripts\Install-Graphify.ps1') -TargetBotPath $resolverBot -Installer Uv
    Assert-True ((Get-Content $env:FAKE_UV_LOG -Raw) -match 'tool\|install\|graphifyy==0\.9\.45\|--force') 'A stale Graphify installation was not force-replaced.'
    Remove-Item Env:STALE_GRAPHIFY_LOG
    Remove-Item Env:FAKE_UV_LOG
    $env:LOCALAPPDATA = $originalLocalAppData
    $env:USERPROFILE = $originalUserProfile
    $env:PATH = $originalPath
    }

    $fakeBin = Join-Path $testRoot 'fake-bin'
    New-FakeGraphify $fakeBin
    New-FakeUip $fakeBin
    New-FakeGit $fakeBin
    $fakeOrigin = & (Join-Path $fakeBin 'git.cmd') -C $root config --get remote.origin.url
    Assert-True ($fakeOrigin -match '^https://dev\.azure\.com/') 'Fake Git did not return the Azure DevOps origin.'
    $resolvedGit = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
    $resolvedGitPath = if ($resolvedGit.Source) { $resolvedGit.Source } else { $resolvedGit.Definition }
    $resolvedOrigin = & $resolvedGitPath -C $root config --get remote.origin.url
    Assert-True ($resolvedOrigin -match '^https://(?:[^/@]+@)?dev\.azure\.com/') "Resolved Git did not return the Azure DevOps origin: $resolvedGitPath"
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        Assert-True ((Get-Content (Join-Path $fakeBin 'graphify.cmd') -Raw) -notmatch '(?i)\bpwsh(?:\.exe)?\b') 'Windows PowerShell fake Graphify launcher depends on pwsh.'
        Assert-True ((Get-Content (Join-Path $fakeBin 'uip.cmd') -Raw) -notmatch '(?i)\bpwsh(?:\.exe)?\b') 'Windows PowerShell fake UiPath launcher depends on pwsh.'
    }
    $env:PATH = $fakeBin
    $env:LOCALAPPDATA = $testRoot
    $env:USERPROFILE = $testRoot
    $env:FAKE_GRAPHIFY_LOG = Join-Path $testRoot 'graphify.log'
    $env:FAKE_UIP_LOG = Join-Path $testRoot 'uip.log'
    $env:FAKE_DEVKIT_SOURCE_ROOT = $root
    $env:OPENAI_API_KEY = 'must-not-reach-graphify'
    $env:AWS_ACCESS_KEY_ID = 'must-not-reach-graphify'

    $exportRoot = Join-Path $testRoot 'export'
    & (Join-Path $root 'scripts\Export-RpaAiDevKit.ps1') -OutputDirectory $exportRoot
    $payload = Get-ChildItem $exportRoot -Directory | Select-Object -First 1
    $zip = Get-ChildItem $exportRoot -Filter '*.zip' | Select-Object -First 1
    Assert-True ($null -ne $payload) 'Payload directory was not created.'
    Assert-True ($null -ne $zip) 'Payload ZIP was not created.'
    $validationScriptText = Get-Content (Join-Path $root 'scripts\Validate-RpaProject.ps1') -Raw
    Assert-True ($validationScriptText -match 'ValidationSummaryPath' -and $validationScriptText -match 'ReuseDependencyState' -and $validationScriptText -match 'ForceDependencyRestore' -and $validationScriptText -match 'ReuseManagedIntegrity' -and $validationScriptText -match 'dependency_restore' -and $validationScriptText -match 'xaml_sanity' -and $validationScriptText -match "status = 'REUSED'") 'Structured validation summary, fail-fast sanity, or dependency-state reuse is missing.'
    $nativeValidationScriptText = Get-Content (Join-Path $root 'scripts\Invoke-UiPathNativeDiagnostics.ps1') -Raw
    Assert-True ($validationScriptText -match 'SourceFingerprint\.ps1' -and $validationScriptText -match 'sourceFingerprint' -and $nativeValidationScriptText -match 'get-errors' -and $nativeValidationScriptText -match 'project-dir' -and $nativeValidationScriptText -match 'min-severity' -and $validationScriptText -match '\(Test-Path \$executionStateScript.*\).*and') 'Shared source fingerprint or UiPath-native validation execution-stage integration is missing.'
    Assert-True ($validationScriptText -match 'RiskClassification' -and $validationScriptText -match 'diagnostics_decision' -and $validationScriptText -match 'diagnosticsDecisionReason' -and $validationScriptText -match 'unexplainedResidual') 'Risk-based diagnostics evidence or detailed validation timing is missing.'
    Assert-True ($validationScriptText -match 'uipVersionResult' -and $validationScriptText -match 'UiPath CLI version check ended' -and $validationScriptText -match 'StageEnd.*Stage validation') 'Validation CLI-probe cleanup coverage is missing.'
    $activationScriptText = Get-Content (Join-Path $root 'scripts\Activate-RpaAiDevKit.ps1') -Raw
    Assert-True ($activationScriptText -match 'project\.json' -and $activationScriptText -match 'Graphify extraction deferred') 'New-bot activation does not defer Graphify extraction.'
    $executionStateText = Get-Content (Join-Path $root 'scripts\ExecutionState.ps1') -Raw
    Assert-True ($executionStateText -match 'started_at' -and $executionStateText -match 'elapsed_seconds' -and $executionStateText -notmatch 'hard_limit_seconds\s*=' -and $executionStateText -notmatch 'BUDGET_BLOCKED' -and $executionStateText -match 'max_repair_loops = 3' -and $executionStateText -match 'REPAIR_LOOP_LIMIT_REACHED' -and $executionStateText -match 'bottleneck') 'Execution timing without a time budget, or the three-loop repair limit, is missing.'
    $dependencyStateScriptText = Get-Content (Join-Path $root 'scripts\Get-DependencyState.ps1') -Raw
    Assert-True ($dependencyStateScriptText -notmatch 'Get-ChildItem\s+-LiteralPath \$ProjectPath\s+-Recurse' -and $dependencyStateScriptText -match 'requirements-\*\.txt' -and $dependencyStateScriptText -match 'node_modules' -and $dependencyStateScriptText -match 'discoveryStatus' -and $dependencyStateScriptText -match 'CliVersion' -and $dependencyStateScriptText -match 'AvailabilityStatus' -and $dependencyStateScriptText -match 'packageCacheFingerprint' -and $dependencyStateScriptText -match 'schemaVersion = 2') 'Dependency-state discovery is not targeted or availability-aware.'
    $cacheScriptText = Get-Content (Join-Path $root 'scripts\Check-DevKitRemoteVersion.ps1') -Raw
    Assert-True ($cacheScriptText -match '\[switch\]\$Force' -and $cacheScriptText -match 'MaxAgeHours') 'Remote version-check cache controls are missing.'
    Assert-True (Test-Path (Join-Path $payload.FullName '.ai\intake\README.md')) 'Intake guidance is missing from payload.'
    Assert-True (Test-Path (Join-Path $payload.FullName '.ai\feedback\dev-kit-improvements.md')) 'Bot-owned Dev Kit feedback log is missing from payload.'
    Assert-True (Test-Path (Join-Path $payload.FullName '.ai\context\file-journey.md')) 'Bot-owned file journey graph template is missing from payload.'
    Assert-True (Test-Path (Join-Path $payload.FullName 'AGENTS.md')) 'Compact AGENTS.md context is missing from payload.'
    $agentsContext = Get-Content (Join-Path $payload.FullName 'AGENTS.md') -Raw
    Assert-True (($agentsContext -split "`r?`n").Count -le 200) 'Compact AGENTS.md context exceeds 200 lines.'
    Assert-True ($agentsContext -match 'DOCUMENTATION_IMPACT|documentation.*routing') 'Compact AGENTS.md does not route documentation guidance.'
    $fileJourneyTemplate = Get-Content (Join-Path $payload.FullName '.ai\context\file-journey.md') -Raw
    Assert-True ($fileJourneyTemplate -match 'Detected capabilities:') 'File journey graph template is missing capability inventory.'
    Assert-True ($fileJourneyTemplate -match 'Format / schema' -and $fileJourneyTemplate -match 'Success path' -and $fileJourneyTemplate -match 'Failure / retry / quarantine / cleanup path' -and $fileJourneyTemplate -match 'Retention / deletion') 'File journey graph template is missing lifecycle fields.'
    Assert-True ($fileJourneyTemplate -match 'Do not store file contents, credentials, tokens') 'File journey graph template is missing sensitive-content exclusions.'
    Assert-True (Test-Path (Join-Path $payload.FullName '.rpa-ai\scripts\Get-DevKitDiagnostics.ps1')) 'Bot diagnostics are missing from payload.'
    $diagnosticsScriptText = Get-Content (Join-Path $root 'scripts\Get-DevKitDiagnostics.ps1') -Raw
    Assert-True ($diagnosticsScriptText -match 'projectExists' -and $diagnosticsScriptText -match 'deferred until official new-bot scaffolding') 'New-bot diagnostics still require a graph before project scaffolding.'
    Assert-True (Test-Path (Join-Path $payload.FullName '.rpa-ai\scripts\ExecutionState.ps1')) 'Execution state helper is missing from payload.'
    Assert-True (Test-Path (Join-Path $payload.FullName '.rpa-ai\scripts\Get-DeveloperContextProfile.ps1')) 'Developer context profiler is missing from payload.'
    Assert-True (Test-Path (Join-Path $payload.FullName '.rpa-ai\scripts\New-DeveloperContextPackage.ps1')) 'Developer fast-context package helper is missing from payload.'
    Assert-True (Test-Path (Join-Path $payload.FullName '.rpa-ai\scripts\Invoke-DeveloperValidation.ps1')) 'Deterministic Developer validation wrapper is missing from payload.'
    Assert-True (Test-Path (Join-Path $payload.FullName '.rpa-ai\scripts\Complete-DeveloperRun.ps1')) 'Deterministic Developer finalization helper is missing from payload.'
    foreach ($v116Helper in @('DeveloperTelemetry.psm1','Write-DeveloperEvent.ps1','Get-DeveloperRuntimeBreakdown.ps1','Test-ExecutionTimingConsistency.ps1','UiPathCompatibility.psm1','Get-UiPathEnvironmentCompatibility.ps1','Get-UiPathEnumMetadata.ps1','Test-UiPathXamlCompatibility.ps1','ConvertFrom-UiPathDiagnostics.ps1','Invoke-UiPathNativeDiagnostics.ps1')) {
        Assert-True (Test-Path (Join-Path $payload.FullName ".rpa-ai\scripts\$v116Helper")) "v0.11.7 runtime helper is missing from payload: $v116Helper"
    }
    Assert-True (Test-Path (Join-Path $payload.FullName '.rpa-ai\validation\uipath-serialization-policy.json')) 'UiPath serialization policy is missing from payload.'
    Assert-True (Test-Path (Join-Path $payload.FullName '.rpa-ai\scripts\UiTargeting.psm1')) 'UI targeting runtime module is missing from payload.'
    Assert-True (Test-Path (Join-Path $payload.FullName '.rpa-ai\scripts\Get-UiTargetCapabilities.ps1')) 'UI target capability helper is missing from payload.'
    Assert-True (Test-Path (Join-Path $payload.FullName '.rpa-ai\scripts\Get-UiTargetQuality.ps1')) 'UI target quality helper is missing from payload.'
    Assert-True (Test-Path (Join-Path $payload.FullName '.rpa-ai\scripts\Manage-UiTargetRegistry.ps1')) 'UI Target Registry helper is missing from payload.'
    Assert-True (Test-Path (Join-Path $payload.FullName '.rpa-ai\scripts\Resolve-UiTarget.ps1')) 'UI target resolver is missing from payload.'
    Assert-True (Test-Path (Join-Path $payload.FullName '.rpa-ai\scripts\Resolve-UiTargets.ps1')) 'Screen-batch target resolver is missing from payload.'
    Assert-True (Test-Path (Join-Path $payload.FullName '.rpa-ai\validation\ui-target-policy.json')) 'UI target policy is missing from payload.'
    Assert-True (-not (Test-Path (Join-Path $payload.FullName '.devkit\ui-targets'))) 'UI Target Registry was eagerly created for a payload/non-UI bot.'
    Assert-True (Test-Path (Join-Path $payload.FullName '.rpa-ai\scripts\SourceFingerprint.ps1')) 'Shared source fingerprint helper is missing from payload.'
    Assert-True (Test-Path (Join-Path $payload.FullName '.rpa-ai\scripts\Get-UiPathProjectMap.ps1')) 'UiPath Project Mapper is missing from payload.'
    Assert-True (Test-Path (Join-Path $payload.FullName '.rpa-ai\scripts\Manage-RequirementsWorkspace.ps1')) 'Requirements workspace helper is missing from payload.'
    Assert-True (Test-Path (Join-Path $payload.FullName '.rpa-ai\templates\REQUIREMENTS.md')) 'Requirements workspace template is missing from payload.'
    Assert-True (-not (Test-Path (Join-Path $payload.FullName 'Requirements'))) 'Payload eagerly created a human-owned Requirements workspace.'
    Assert-True (Test-Path (Join-Path $payload.FullName '.rpa-ai\scripts\Get-DiagnosticsDecision.ps1')) 'Risk-based diagnostics decision helper is missing from payload.'
    Assert-True (Test-Path (Join-Path $payload.FullName '.rpa-ai\scripts\Test-ChangedWorkflowSanity.ps1')) 'Changed-workflow sanity helper is missing from payload.'
    Assert-True ((Test-Path (Join-Path $payload.FullName '.rpa-ai\scripts\UiWorkflowRobustness.psm1')) -and (Test-Path (Join-Path $payload.FullName '.rpa-ai\scripts\Test-UiWorkflowRobustness.ps1'))) 'UI robustness helpers are missing from payload.'
    Assert-True (Test-Path (Join-Path $payload.FullName '.rpa-ai\scripts\Invoke-DevKitCommand.ps1')) 'Shared command helper is missing from payload.'
    Assert-True (Test-Path (Join-Path $payload.FullName '.rpa-ai\scripts\Install-DevKitPrerequisites.ps1')) 'User-profile prerequisite bootstrap is missing from payload.'
    Assert-True (Test-Path (Join-Path $payload.FullName '.rpa-ai\scripts\Import-RpaAiDevKit.ps1')) 'Checked ZIP installer is missing from payload.'
    Assert-True (Test-Path (Join-Path $payload.FullName '.rpa-ai\docs\TROUBLESHOOTING.md')) 'Troubleshooting guide is missing from payload.'
    Assert-True (Test-Path (Join-Path $payload.FullName '.github\skills\humanizer\SKILL.md')) 'Humanizer skill is missing from payload.'
    Assert-True (Test-Path (Join-Path $payload.FullName '.github\skills\humanizer\LICENSE')) 'Humanizer license is missing from payload.'
    Assert-True (Test-Path (Join-Path $payload.FullName '.github\skills\caveman\SKILL.md')) 'Caveman skill is missing from payload.'
    Assert-True (Test-Path (Join-Path $payload.FullName '.github\skills\caveman\LICENSE')) 'Caveman license is missing from payload.'
    Assert-True (Test-Path (Join-Path $payload.FullName '.github\instructions\documentation.instructions.md')) 'Documentation routing instruction is missing from payload.'
    $browserInstruction = Get-Content (Join-Path $payload.FullName '.github\instructions\browser-ui.instructions.md') -Raw
    Assert-True ((Get-Content (Join-Path $payload.FullName '.graphifyignore') -Raw) -match '\.devkit/ui-targets/') 'UI Target Registry is not excluded from Graphify extraction.'
    $xamlInstruction = Get-Content (Join-Path $payload.FullName '.github\instructions\uipath-xaml.instructions.md') -Raw
    Assert-True ($browserInstruction -match 'Default browser.*Chrome' -and $browserInstruction -match 'Prefer UiPath UI Automation activities' -and $browserInstruction -match 'Code exception' -and $browserInstruction -match 'stale-reference or target-not-found' -and $browserInstruction -match 'Chrome download prompt' -and $browserInstruction -match 'native Save As dialog' -and $browserInstruction -match 'Target Registry resolution gate' -and $browserInstruction -match 'live validated UI') 'Browser default/activity/registry/recovery/download guidance is missing.'
    Assert-True ($xamlInstruction -match 'default to Chrome' -and $xamlInstruction -match 'UiPath UI Automation activities' -and $xamlInstruction -match 'exception path' -and $xamlInstruction -match 'installed package and exact version' -and $xamlInstruction -match 'smallest necessary XAML subtree') 'XAML browser/schema safety guidance is missing.'
    $coordinatorExcel = Get-Content (Join-Path $payload.FullName '.github\agents\rpa-coordinator.agent.md') -Raw
    $developerExcel = Get-Content (Join-Path $payload.FullName '.github\agents\rpa-developer.agent.md') -Raw
    $auditorText = Get-Content (Join-Path $payload.FullName '.github\agents\rpa-auditor.agent.md') -Raw
    $dependencyExcel = Get-Content (Join-Path $payload.FullName '.github\instructions\dependencies.instructions.md') -Raw
    Assert-True ($coordinatorExcel -match 'Excel output' -and $developerExcel -match 'Excel/Workbook' -and $dependencyExcel -match 'temporary workbook write/read') 'Excel-first implementation guidance is missing.'
    Assert-True ($coordinatorExcel -match 'Get-UiPathProjectMap\.ps1 -OutputPath \.ai/evidence/project-map\.json -Json.*before broad' -and $coordinatorExcel -match 'XAML_FILES_READ_BY_COORDINATOR') 'Coordinator does not persist, use, or measure the project map before broad XAML discovery.'
    Assert-True ($developerExcel -match 'relevant workflow list' -and $developerExcel -match 'Do not rerun a full-project map or scan' -and $developerExcel -match 'TARGET RESOLUTION' -and $developerExcel -match 'Resolve-UiTarget.ps1') 'Developer project-map or deterministic target-resolution guidance is missing.'
    Assert-True ($coordinatorExcel -match 'developer\.request_to_first_tool' -and $coordinatorExcel -match 'developer-context-package\.json' -and $developerExcel -match 'PhaseUnavailable' -and $developerExcel -match 'Get-DeveloperContextProfile\.ps1' -and $developerExcel -match 'raw XAML > deterministic Project Map') 'Developer request, fast-context authority, host limitation, or context instrumentation guidance is missing.'
    Assert-True ($auditorText -match 'changed workflows plus their mapped direct callers/consumers' -and $auditorText -match 'do not remap or rediscover the whole project') 'Auditor does not prefer changed and directly impacted mapped workflows.'
    Assert-True (-not (Test-Path (Join-Path $payload.FullName '.rpa-ai\gitignore.entries'))) 'Unhashed gitignore sidecar leaked into payload.'
    Assert-True (Test-Path (Join-Path $payload.FullName '.rpa-ai\kit-manifest.sha256')) 'Detached payload manifest digest is missing.'
    $payloadManifest = Get-Content (Join-Path $payload.FullName '.rpa-ai\kit-manifest.json') -Raw | ConvertFrom-Json
    Assert-True (@($payloadManifest.gitignoreEntries) -contains '.devkit/cache/') 'Installed bot cache path is not declared for .gitignore.'
    Assert-True ($payloadManifest.sourceRepository -match '^https://dev\.azure\.com/') 'Payload did not record the canonical Azure DevOps repository.'
    Assert-True (($payloadManifest.files | Where-Object path -eq '.rpa-ai/scripts/Install-DevKitPrerequisites.ps1').ownership -eq 'managed') 'User-profile prerequisite bootstrap is not managed.'
    Assert-True (($payloadManifest.files | Where-Object path -eq '.ai/context/file-journey.md').ownership -eq 'preserve') 'File journey graph context is not preserve-owned.'
    Assert-True (($payloadManifest.files | Where-Object path -eq 'AGENTS.md').ownership -eq 'preserve') 'Compact AGENTS.md context is not preserve-owned.'
    Assert-True (($payloadManifest.files | Where-Object path -eq '.github/instructions/documentation.instructions.md').ownership -eq 'managed') 'Documentation routing instruction is not managed.'
    Assert-True (($payloadManifest.files | Where-Object path -eq '.rpa-ai/scripts/ExecutionState.ps1').ownership -eq 'managed' -and ($payloadManifest.files | Where-Object path -eq '.rpa-ai/scripts/Get-DeveloperContextProfile.ps1').ownership -eq 'managed' -and ($payloadManifest.files | Where-Object path -eq '.rpa-ai/scripts/New-DeveloperContextPackage.ps1').ownership -eq 'managed' -and ($payloadManifest.files | Where-Object path -eq '.rpa-ai/scripts/Invoke-DeveloperValidation.ps1').ownership -eq 'managed' -and ($payloadManifest.files | Where-Object path -eq '.rpa-ai/scripts/Complete-DeveloperRun.ps1').ownership -eq 'managed' -and ($payloadManifest.files | Where-Object path -eq '.rpa-ai/scripts/UiTargeting.psm1').ownership -eq 'managed' -and ($payloadManifest.files | Where-Object path -eq '.rpa-ai/scripts/Resolve-UiTarget.ps1').ownership -eq 'managed' -and ($payloadManifest.files | Where-Object path -eq '.rpa-ai/validation/ui-target-policy.json').ownership -eq 'managed' -and ($payloadManifest.files | Where-Object path -eq '.rpa-ai/scripts/SourceFingerprint.ps1').ownership -eq 'managed' -and ($payloadManifest.files | Where-Object path -eq '.rpa-ai/scripts/Get-UiPathProjectMap.ps1').ownership -eq 'managed' -and ($payloadManifest.files | Where-Object path -eq '.rpa-ai/scripts/Invoke-DevKitCommand.ps1').ownership -eq 'managed') 'Shared runtime helpers are not managed.'
    Assert-True (($payloadManifest.files | Where-Object path -eq '.rpa-ai/scripts/DeveloperTelemetry.psm1').ownership -eq 'managed' -and ($payloadManifest.files | Where-Object path -eq '.rpa-ai/scripts/Invoke-UiPathNativeDiagnostics.ps1').ownership -eq 'managed' -and ($payloadManifest.files | Where-Object path -eq '.rpa-ai/validation/uipath-serialization-policy.json').ownership -eq 'managed' -and ($payloadManifest.files | Where-Object path -eq '.rpa-ai/scripts/Manage-RequirementsWorkspace.ps1').ownership -eq 'managed' -and ($payloadManifest.files | Where-Object path -eq '.rpa-ai/templates/REQUIREMENTS.md').ownership -eq 'managed') 'v0.11.7 telemetry/native-validation/Requirements files are not managed.'
    Assert-True (($payloadManifest.files | Where-Object path -eq '.rpa-ai/scripts/Resolve-UiTargets.ps1').ownership -eq 'managed') 'Screen-batch target resolver is not managed.'
    Assert-True (Test-Path (Join-Path $payload.FullName 'AGENTS.md')) 'Compact AGENTS.md context is missing from payload.'
    Assert-True (Test-Path (Join-Path $payload.FullName '.github\instructions\documentation.instructions.md')) 'Documentation routing instruction is missing from payload.'
    $executionBot = Join-Path $testRoot 'execution-state-bot'
    New-Item -ItemType Directory -Force -Path $executionBot | Out-Null
    $executionScript = Join-Path $root 'scripts\ExecutionState.ps1'
    $commandScript = Join-Path $root 'scripts\Invoke-DevKitCommand.ps1'
    & $executionScript -Action Start -TaskType new_bot -TargetBotPath $executionBot -Json | ConvertFrom-Json | Out-Null
    & $executionScript -Action StageEnd -Stage coordinator -TargetBotPath $executionBot -Json | ConvertFrom-Json | Out-Null
    & $executionScript -Action StageStart -Stage developer -TargetBotPath $executionBot -Json | ConvertFrom-Json | Out-Null
    & $executionScript -Action StageEnd -Stage developer -TargetBotPath $executionBot -Json | ConvertFrom-Json | Out-Null
    & $executionScript -Action RepairStart -TargetBotPath $executionBot -Json | ConvertFrom-Json | Out-Null
    & $executionScript -Action RepairStart -TargetBotPath $executionBot -Json | ConvertFrom-Json | Out-Null
    & $executionScript -Action RepairStart -TargetBotPath $executionBot -Json | ConvertFrom-Json | Out-Null
    $repairLimitBlocked = $false
    try { & $executionScript -Action RepairStart -TargetBotPath $executionBot -Json 2>$null | Out-Null } catch { $repairLimitBlocked = $_.Exception.Message -match 'REPAIR_LOOP_LIMIT_REACHED' }
    Assert-True $repairLimitBlocked 'Persisted execution state did not enforce the three-loop repair limit.'
    $readyValidation = [ordered]@{validationRequired=$true;validationCompleted=$true;diagnosticsExecuted=$true;buildExecuted=$true;buildSucceeded=$true;deliveryReady=$true;blockedReason=$null;validationResultPath='.ai/evidence/test-validation.json'} | ConvertTo-Json -Compress
    & $executionScript -Action ValidationState -TargetBotPath $executionBot -ValidationStateJson $readyValidation -Json | Out-Null
    & $executionScript -Action StageStart -Stage finalization -TargetBotPath $executionBot -Json | ConvertFrom-Json | Out-Null
    & $executionScript -Action StageEnd -Stage finalization -TargetBotPath $executionBot -Json | ConvertFrom-Json | Out-Null
    $auditRequiredBlocked = $false
    try { & $executionScript -Action Complete -RequireAudit -TargetBotPath $executionBot -Json 2>$null | Out-Null } catch { $auditRequiredBlocked = $_.Exception.Message -match 'independent audit is required' }
    Assert-True $auditRequiredBlocked 'Required audit completion was allowed before the Auditor stage.'
    & $executionScript -Action StageStart -Stage auditor -TargetBotPath $executionBot -Json | ConvertFrom-Json | Out-Null
    & $executionScript -Action StageEnd -Stage auditor -TargetBotPath $executionBot -Json | ConvertFrom-Json | Out-Null
    & $executionScript -Action StageStart -Stage finalization -TargetBotPath $executionBot -Json | ConvertFrom-Json | Out-Null
    & $executionScript -Action StageEnd -Stage finalization -TargetBotPath $executionBot -Json | ConvertFrom-Json | Out-Null
    & $executionScript -Action Complete -Outcome PASS -TargetBotPath $executionBot -Json | ConvertFrom-Json | Out-Null
    $executionReport = & $executionScript -Action Report -TargetBotPath $executionBot -Json | ConvertFrom-Json
    Assert-True ($null -eq $executionReport.execution.target_seconds -and $null -eq $executionReport.execution.hard_limit_seconds -and $null -ne $executionReport.execution.total_wall_seconds -and $null -ne $executionReport.execution.active_execution_seconds -and $null -ne $executionReport.execution.user_wait_seconds -and $executionReport.repair_loops -eq 3 -and $null -ne $executionReport.report.bottleneck -and $null -ne $executionReport.storage.serialized_state_bytes) 'Execution report did not persist clocks, repair, bottleneck, or storage data, or still carries a time budget.'
    $executionStatePath = Join-Path $executionBot '.ai\evidence\execution-state.json'
    $statusHashBefore = (Get-FileHash $executionStatePath -Algorithm SHA256).Hash
    & $executionScript -Action Status -TargetBotPath $executionBot -Json | Out-Null
    $statusHashAfter = (Get-FileHash $executionStatePath -Algorithm SHA256).Hash
    Assert-True ($statusHashBefore -eq $statusHashAfter) 'Read-only execution status modified the state file.'
    $writeFailureBot = Join-Path $testRoot 'execution-write-failure-bot'
    New-Item -ItemType Directory -Force -Path $writeFailureBot | Out-Null
    & $executionScript -Action Start -TaskType modification -TargetBotPath $writeFailureBot -Json | Out-Null
    $writeFailurePath = Join-Path $writeFailureBot '.ai\evidence\execution-state.json'
    $writeFailureHash = (Get-FileHash $writeFailurePath -Algorithm SHA256).Hash
    $writeFailureThrown = $false
    try { & $executionScript -Action StageEnd -Stage coordinator -TargetBotPath $writeFailureBot -SimulateWriteFailure -Json 2>$null | Out-Null } catch { $writeFailureThrown = $true }
    Assert-True ($writeFailureThrown -and (Get-FileHash $writeFailurePath -Algorithm SHA256).Hash -eq $writeFailureHash) 'Failed execution-state write did not preserve the previous valid JSON.'
    $commandEvidenceBot = Join-Path $testRoot 'command-evidence-bot'
    New-Item -ItemType Directory -Force -Path $commandEvidenceBot | Out-Null
    & $executionScript -Action Start -TaskType modification -TargetBotPath $commandEvidenceBot -Json | Out-Null
    & $executionScript -Action StageEnd -Stage coordinator -TargetBotPath $commandEvidenceBot -Json | Out-Null
    $commandEvidenceState = Join-Path $commandEvidenceBot '.ai\evidence\execution-state.json'
    $commandEvidence = & $commandScript -FilePath $env:ComSpec -ArgumentList @('/c','exit','0') -WorkingDirectory $root -TargetBotPath $commandEvidenceBot -ExecutionStatePath $commandEvidenceState -Operation 'test durable output' -TimeoutSeconds 5 -Json | ConvertFrom-Json
    $commandEvidenceStateObject = Get-Content $commandEvidenceState -Raw | ConvertFrom-Json
    Assert-True ($commandEvidence.status -eq 'PASS' -and @($commandEvidenceStateObject.commands).Count -eq 0 -and $commandEvidenceStateObject.command_summary.total -ge 1 -and (Test-Path $commandEvidence.output_path -PathType Leaf)) 'Completed command evidence did not persist a durable external output reference and compact state summary.'
    & $executionScript -Action Start -TaskType modification -TargetBotPath $executionBot -Json | Out-Null
    Assert-True ((Get-ChildItem (Join-Path $executionBot '.ai\evidence\execution-history') -Filter '*.json' -File).Count -ge 1) 'Completed execution history was overwritten instead of preserved.'
    $timingBot = Join-Path $testRoot 'timing-state-bot'
    New-Item -ItemType Directory -Force -Path $timingBot | Out-Null
    & $executionScript -Action Start -TaskType modification -TargetBotPath $timingBot -NowUtc '2026-09-07T10:00:00Z' -Json | Out-Null
    & $executionScript -Action StageEnd -Stage coordinator -TargetBotPath $timingBot -NowUtc '2026-09-07T10:01:00Z' -Json | Out-Null
    & $executionScript -Action StageStart -Stage developer -TargetBotPath $timingBot -NowUtc '2026-09-07T10:01:00Z' -Json | Out-Null
    $overlapBlocked = $false
    try { & $executionScript -Action StageStart -Stage auditor -TargetBotPath $timingBot -NowUtc '2026-09-07T10:01:01Z' -Json 2>$null | Out-Null } catch { $overlapBlocked = $_.Exception.Message -match 'Exclusive stage overlap' }
    Assert-True $overlapBlocked 'Overlapping exclusive stages were accepted.'
    & $executionScript -Action Pause -Reason 'controlled user wait' -TargetBotPath $timingBot -NowUtc '2026-09-07T10:02:00Z' -Json | Out-Null
    & $executionScript -Action Resume -TargetBotPath $timingBot -NowUtc '2026-09-07T10:07:00Z' -Json | Out-Null
    & $executionScript -Action StageEnd -Stage developer -TargetBotPath $timingBot -NowUtc '2026-09-07T10:08:00Z' -Json | Out-Null
    $timingState = Get-Content (Join-Path $timingBot '.ai\evidence\execution-state.json') -Raw | ConvertFrom-Json
    Assert-True ($timingState.execution.total_wall_seconds -eq 480 -and $timingState.execution.user_wait_seconds -eq 300 -and $timingState.execution.active_execution_seconds -eq 180 -and @($timingState.stages.developer.intervals).Count -eq 2) 'Controlled wall/active/user-wait or repeated-stage timing failed.'
    $fingerprintBot = Join-Path $testRoot 'fingerprint-no-git-bot'
    New-Item -ItemType Directory -Force -Path (Join-Path $fingerprintBot 'src'),(Join-Path $fingerprintBot 'docs') | Out-Null
    'alpha' | Set-Content (Join-Path $fingerprintBot 'src\Main.xaml')
    'docs' | Set-Content (Join-Path $fingerprintBot 'docs\README.md')
    $fingerprintScript = Join-Path $root 'scripts\SourceFingerprint.ps1'
    $fingerprintOne = & $fingerprintScript -ProjectPath $fingerprintBot -Json | ConvertFrom-Json
    $fingerprintTwo = & $fingerprintScript -ProjectPath $fingerprintBot -Json | ConvertFrom-Json
    Assert-True ($fingerprintOne.schemaVersion -eq 4 -and $fingerprintOne.sourceFingerprint -eq $fingerprintTwo.sourceFingerprint -and $fingerprintOne.documentationFingerprint -ne $fingerprintOne.sourceFingerprint) 'Shared no-Git fingerprint reuse or documentation separation failed.'
    'changed' | Set-Content (Join-Path $fingerprintBot 'src\Main.xaml')
    $fingerprintThree = & $fingerprintScript -ProjectPath $fingerprintBot -Json | ConvertFrom-Json
    Assert-True ($fingerprintThree.sourceFingerprint -ne $fingerprintOne.sourceFingerprint) 'Relevant source modification did not invalidate the shared fingerprint.'
    Remove-Item (Join-Path $fingerprintBot 'src\Main.xaml') -Force
    $fingerprintFour = & $fingerprintScript -ProjectPath $fingerprintBot -Json | ConvertFrom-Json
    Assert-True ($fingerprintFour.sourceFingerprint -ne $fingerprintThree.sourceFingerprint) 'Relevant source deletion did not invalidate the shared fingerprint.'
    'docs changed' | Set-Content (Join-Path $fingerprintBot 'docs\README.md')
    $fingerprintFive = & $fingerprintScript -ProjectPath $fingerprintBot -Json | ConvertFrom-Json
    Assert-True ($fingerprintFive.sourceFingerprint -eq $fingerprintFour.sourceFingerprint -and $fingerprintFive.documentationFingerprint -ne $fingerprintOne.documentationFingerprint) 'Documentation-only change invalidated executable fingerprint or was not tracked separately.'
    New-Item -ItemType Directory -Force -Path (Join-Path $fingerprintBot '.uipath\.skills'),(Join-Path $fingerprintBot '.github\skills\uipath-test'),(Join-Path $fingerprintBot '.local') | Out-Null
    '{"version":1}' | Set-Content (Join-Path $fingerprintBot '.uipath\.skills\version-manifest.json') -Encoding UTF8
    '{"source":"tool-managed"}' | Set-Content (Join-Path $fingerprintBot '.github\skills\uipath-test\.uipath-skill-source.json') -Encoding UTF8
    'runtime cache' | Set-Content (Join-Path $fingerprintBot '.local\WorkflowFileValidator.cache') -Encoding UTF8
    $fingerprintSix = & $fingerprintScript -ProjectPath $fingerprintBot -Json | ConvertFrom-Json
    Assert-True ($fingerprintSix.sourceFingerprint -eq $fingerprintFive.sourceFingerprint) 'Tool-managed UiPath skill metadata or runtime cache invalidated executable source evidence.'
    $commandScript = Join-Path $root 'scripts\Invoke-DevKitCommand.ps1'
    $commandPass = & $commandScript -FilePath $env:ComSpec -ArgumentList @('/c','exit','0') -WorkingDirectory $root -TargetBotPath $commandEvidenceBot -ExecutionStatePath $commandEvidenceState -Operation 'test success' -TimeoutSeconds 5 -Json | ConvertFrom-Json
    $commandFail = & $commandScript -FilePath $env:ComSpec -ArgumentList @('/c','exit','7') -WorkingDirectory $root -TargetBotPath $commandEvidenceBot -ExecutionStatePath $commandEvidenceState -Operation 'test failure' -TimeoutSeconds 5 -Json | ConvertFrom-Json
    Assert-True ($commandPass.status -eq 'PASS' -and $commandPass.exit_code -eq 0 -and $commandFail.status -eq 'FAIL' -and $commandFail.exit_code -eq 7 -and $commandPass.duration_seconds -ge 0) 'Shared command success/failure evidence failed.'
    $powerShellHost = (Get-Process -Id $PID).Path
    $commandTimeout = & $commandScript -FilePath $powerShellHost -ArgumentList @('-NoLogo','-NoProfile','-Command','Start-Sleep -Seconds 3') -WorkingDirectory $root -TargetBotPath $commandEvidenceBot -ExecutionStatePath $commandEvidenceState -Operation 'test timeout' -TimeoutSeconds 1 -Json | ConvertFrom-Json
    Assert-True ($commandTimeout.status -eq 'TIMEOUT' -and $commandTimeout.timed_out) 'Shared command timeout evidence failed.'
    $coordinatorAgent = Get-Content (Join-Path $payload.FullName '.github\agents\rpa-coordinator.agent.md') -Raw
    $developerAgent = Get-Content (Join-Path $payload.FullName '.github\agents\rpa-developer.agent.md') -Raw
    $documentationAgent = Get-Content (Join-Path $payload.FullName '.github\agents\rpa-documentation.agent.md') -Raw
    $auditorAgent = Get-Content (Join-Path $payload.FullName '.github\agents\rpa-auditor.agent.md') -Raw
    $documentationAgent = Get-Content (Join-Path $payload.FullName '.github\agents\rpa-documentation.agent.md') -Raw
    $auditorAgent = Get-Content (Join-Path $payload.FullName '.github\agents\rpa-auditor.agent.md') -Raw
    $evidenceTemplate = Get-Content (Join-Path $payload.FullName '.ai\evidence\CHANGE-EVIDENCE-TEMPLATE.md') -Raw
    foreach ($contractText in @($coordinatorAgent, $developerAgent, $evidenceTemplate)) {
        Assert-True ($contractText -match 'FILE_JOURNEY_REQUIRED' -and $contractText -match 'FILE_JOURNEY_PATH' -and $contractText -match 'FILE_JOURNEY_COMPLETE') 'File journey handoff flags are incomplete.'
    }
    Assert-True ($coordinatorAgent -match 'FILE_JOURNEY_CAPABILITIES') 'Coordinator does not expose detected file capabilities.'
    Assert-True ($evidenceTemplate -match 'FILE_JOURNEY_CAPABILITIES') 'Evidence template does not record detected file capabilities.'
    Assert-True ($coordinatorAgent -match 'DOCUMENTATION_IMPACT' -and $coordinatorAgent -match 'candidate_documents') 'Coordinator documentation impact fields are missing.'
    Assert-True ($coordinatorAgent -match 'PREFLIGHT_STATUS' -and $coordinatorAgent -match 'changedCandidates' -and $coordinatorAgent -match 'Audit Packet') 'Coordinator preflight, Impact Set, or Audit Packet handoff is missing.'
    Assert-True ($developerAgent -match 'AGENTS\.md' -and $developerAgent -match 'DOCUMENTATION_CONFIRMATION') 'Developer compact-context or documentation confirmation rules are missing.'
    Assert-True ($developerAgent -match 'Consume Coordinator preflight' -and $developerAgent -match 'approved Impact Set' -and $developerAgent -match 'diagnostics decision' -and $developerAgent -match 'source fingerprint') 'Developer optimized handoff or deterministic validation contract is missing.'
    Assert-True ($developerAgent -notmatch '### 0\. Mandatory Dev Kit preflight') 'Developer still owns unconditional preflight.'
    Assert-True ($documentationAgent -match 'HUMAN_DOCS' -and $documentationAgent -match 'candidate documents' -and $documentationAgent -notmatch 'DOCUMENTATION_REQUIRED') 'Documentation Agent is not targeted to HUMAN_DOCS.'
    Assert-True ($auditorAgent -match 'Conditional capability gates' -and $auditorAgent -match 'documentation\.instructions\.md' -and $auditorAgent -match 'documentation impact') 'Auditor documentation-impact scope verification is missing.'
    Assert-True ($auditorAgent -match 'Audit Packet' -and $auditorAgent -match 'Risk-based audit depth' -and $auditorAgent -match 'concrete rerun reason') 'Auditor targeted challenge or rerun contract is missing.'
    Assert-True ($auditorAgent -notmatch 'Before audit, run `\.\/\.rpa-ai\/scripts\/Test-ManagedFileIntegrity\.ps1`') 'Auditor still owns unconditional integrity preflight.'
    $validationPolicy = Get-Content (Join-Path $root 'validation\validation-policy.json') -Raw | ConvertFrom-Json
    Assert-True ($validationPolicy.schemaVersion -eq 15 -and $null -ne $validationPolicy.requirementsWorkspace -and $validationPolicy.requirementsWorkspace.ownership -eq 'HUMAN' -and $null -ne $validationPolicy.handoffContracts -and $null -ne $validationPolicy.freshnessPolicy -and $null -ne $validationPolicy.diagnosticsDecisionPolicy -and $null -ne $validationPolicy.nativeValidation -and $null -ne $validationPolicy.uiPathSerialization -and $validationPolicy.executionBudget.maxRepairLoops -eq 3 -and $validationPolicy.executionBudget.timeBudget -eq 'NONE' -and $validationPolicy.routing.projectCheckBeforeRepositoryAnalysis) 'Validation policy Requirements, handoff, native validation, serialization, freshness, or execution-budget contract is missing.'
    Assert-True ($validationPolicy.validationOrder[1] -eq 'xml-xaml-sanity' -and $validationPolicy.validationOrder[2] -eq 'package-compatibility' -and $validationPolicy.validationOrder[3] -eq 'enum-property-compatibility' -and $validationPolicy.validationOrder[4] -eq 'native-diagnostics-decision' -and $validationPolicy.validationOrder[6] -eq 'restore-or-reuse') 'Fail-fast risk-based native validation order is missing.'
    Assert-True ($coordinatorAgent -match 'AUDIT_MODE' -and $coordinatorAgent -match 'AUDIT_REASON' -and $coordinatorAgent -match 'R1_NO_AUDIT_ELIGIBLE') 'Coordinator audit routing fields are missing.'
    Assert-True ($coordinatorAgent -match 'Independent Auditor: PASS / SKIPPED / NOT_RUN' -and $coordinatorAgent -match 'Audit Skip Reason') 'Coordinator no-audit reporting distinction is missing.'
    Assert-True ($developerAgent -match 'DEVELOPER_SELF_REVIEW' -and $developerAgent -match 'ESCALATE_TO_AUDITOR' -and $developerAgent -match 'build.*PASS alone') 'Developer no-audit safeguards are missing.'
    Assert-True ($developerAgent -match 'Invoke-DeveloperValidation\.ps1' -and $developerAgent -match 'Complete-DeveloperRun\.ps1' -and $developerAgent -match 'one atomic execution-state write' -and $developerAgent -match 'Do not reopen or recompare source') 'Developer deterministic validation/finalization or evidence-reuse safeguards are missing.'
    Assert-True ($auditorAgent -match 'AUDIT_MODE: LIGHT' -and $auditorAgent -match 'ESCALATE_TO_FULL_AUDIT' -and $auditorAgent -match 'NONE.*valid completion route') 'Auditor conditional routing contract is missing.'
    $startHere = Get-Content (Join-Path $payload.FullName 'START-HERE.md') -Raw
    $payloadAgents = Get-Content (Join-Path $payload.FullName 'AGENTS.md') -Raw
    Assert-True ($startHere -match 'AUDIT_MODE: NONE' -and $startHere -match 'ExecutionState\.ps1' -and $payloadAgents -match 'RISK_LEVEL' -and $payloadAgents -match 'AUDIT_MODE' -and $payloadAgents -match 'AUDIT_REASON' -and $payloadAgents -match 'repair cap|repair-loop|max_repair_loops') 'Payload lifecycle guidance does not expose audit routing or execution budgets.'
    Assert-True ($validationPolicy.auditRouting.defaultByRisk.R0 -eq 'NONE' -and $validationPolicy.auditRouting.defaultByRisk.R3 -eq 'FULL' -and $validationPolicy.auditRouting.r2R3CannotUseNone -eq $true) 'Audit mode defaults or R2/R3 NONE prohibition are missing.'
    Assert-True ($validationPolicy.auditRouting.r1NoAuditEligibility.Count -ge 21 -and $validationPolicy.auditRouting.mandatoryAuditTriggers.Count -ge 20) 'Audit eligibility or mandatory-trigger contract is incomplete.'
    Assert-True ($validationPolicy.auditRouting.defaultByRisk.R1 -match 'NONE.*r1NoAuditEligible.*otherwise LIGHT' -and $validationPolicy.auditRouting.defaultByRisk.R2 -match 'LIGHT.*FULL') 'R1/R2 audit routing is incomplete.'
    Assert-True ($validationPolicy.auditRouting.noneRequires -match 'Developer self-review PASS when AUDIT_MODE is NONE for behavioral R1' -and $validationPolicy.auditRouting.lightOutcome -contains 'ESCALATE_TO_FULL_AUDIT') 'No-audit gate or Light escalation outcome is missing.'
    Assert-True (($validationPolicy.gates | Where-Object id -eq 'audit').mandatory -eq $false -and ($validationPolicy.gates | Where-Object id -eq 'audit').appliesWhen -match 'LIGHT or FULL') 'Audit gate is still universally mandatory.'
    $r0ScopeNote = ($validationPolicy.gates | Where-Object id -eq 'r0-scope-diff-verification').note
    $r1ScopeNote = ($validationPolicy.gates | Where-Object id -eq 'r1-scope-diff-verification').note
    $documentationGateNote = ($validationPolicy.gates | Where-Object id -eq 'documentation-handoff').note
    Assert-True ($r0ScopeNote -match 'The Developer verifies' -and $r0ScopeNote -match 'When AUDIT_MODE is LIGHT or FULL' -and $r0ScopeNote -notmatch 'Developer and Auditor') 'R0 scope verification still assumes an Auditor in NONE mode.'
    Assert-True ($r1ScopeNote -match 'The Developer verifies' -and $r1ScopeNote -match 'actual diff' -and $r1ScopeNote -match 'When AUDIT_MODE is LIGHT or FULL' -and $r1ScopeNote -notmatch 'Developer and Auditor') 'R1 scope verification still assumes an Auditor in NONE mode.'
    Assert-True ($documentationGateNote -match 'When AUDIT_MODE is NONE' -and $documentationGateNote -match 'When AUDIT_MODE is LIGHT or FULL' -and $documentationGateNote -notmatch 'The Auditor verifies the classification and targeted scope\.') 'Documentation verification is not mode-aware.'
    Assert-True ($coordinatorAgent -match 'R0_FAST_LANE_VALIDATED.*only when an Auditor was invoked' -and $evidenceTemplate -match 'R0_FAST_LANE_VALIDATED:.*when invoked') 'No-audit reporting still implies an R0 Auditor marker.'
    $riskRoutingInstruction = Get-Content (Join-Path $payload.FullName '.github\instructions\risk-routing.instructions.md') -Raw
    Assert-True ($riskRoutingInstruction -match 'do not generate an Auditor verdict' -and $riskRoutingInstruction -match 'For `AUDIT_MODE: NONE`, the Developer records actual-diff verification') 'Risk policy does not prohibit fabricated NONE audit evidence.'
    Assert-True ($riskRoutingInstruction -match 'For `AUDIT_MODE: LIGHT` or `FULL`, the Auditor independently verifies the actual diff' -and $riskRoutingInstruction -match 'passed to the Developer and, when `AUDIT_MODE` is `LIGHT` or `FULL`, to the Auditor') 'Risk policy does not separate Developer-only and Auditor-invoked verification.'
    $documentationInstruction = Get-Content (Join-Path $payload.FullName '.github\instructions\documentation.instructions.md') -Raw
    Assert-True ($documentationInstruction -match 'DOCUMENTATION_IMPACT: NONE' -and $documentationInstruction -match 'DOCUMENTATION_IMPACT: CONTEXT_ONLY' -and $documentationInstruction -match 'DOCUMENTATION_IMPACT: HUMAN_DOCS') 'Documentation impact levels are incomplete.'
    Assert-True ($coordinatorAgent -match 'AGENTS\.md' -and $coordinatorAgent -match 'DOCUMENTATION_IMPACT' -and $coordinatorAgent -match 'candidate_documents') 'Coordinator compact-context or documentation-impact routing is missing.'
    Assert-True ($developerAgent -match 'Read `AGENTS\.md`' -and $developerAgent -match 'documentation') 'Developer compact-context or documentation confirmation routing is missing.'
    Assert-True ($documentationAgent -match 'HUMAN_DOCS' -and $documentationAgent -match 'candidate documents' -and $documentationAgent -notmatch 'DOCUMENTATION_REQUIRED') 'Documentation Agent is not HUMAN_DOCS-only and target-scoped.'
    Assert-True ($auditorAgent -match 'Conditional capability gates' -and $auditorAgent -match 'documentation\.instructions\.md' -and $auditorAgent -match 'documentation impact') 'Auditor documentation-impact verification is missing.'
    Assert-True (($payloadManifest.files | Where-Object path -eq '.graphifyignore').ownership -eq 'managed') 'Graphify ignore policy is not managed.'
    $graphifyIgnore = Get-Content (Join-Path $payload.FullName '.graphifyignore') -Raw
    foreach ($requiredExclusion in @('.ai/intake/','.ai/context/','.github/skills/','.uipath/','outputs/','*.csv')) {
        Assert-True ($graphifyIgnore -match [regex]::Escape($requiredExclusion)) "Graphify policy is missing exclusion '$requiredExclusion'."
    }
    Assert-True (-not (Test-Path (Join-Path $payload.FullName 'docs\IMPROVEMENT-BACKLOG.md'))) 'Central backlog leaked into payload.'
    Assert-True (Test-Path (Join-Path $payload.FullName '.github\agents\rpa-documentation.agent.md')) 'Documentation Agent is missing from payload.'
    Assert-True (Test-Path (Join-Path $payload.FullName 'README.md')) 'Standard bot README is missing from payload.'
    Assert-True (Test-Path (Join-Path $payload.FullName 'docs\Bot-Documentation.md')) 'Standard bot documentation is missing from payload.'
    Assert-True (Test-Path (Join-Path $payload.FullName 'docs\Testing.md')) 'Standard bot testing document is missing from payload.'
    Assert-True (Test-Path (Join-Path $payload.FullName 'docs\CHANGELOG.md')) 'Standard bot changelog is missing from payload.'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zip.FullName)
    try {
        $zipEntries = @($archive.Entries.FullName | ForEach-Object { $_.Replace('\','/') })
        Assert-True ($zipEntries -contains '.ai/intake/README.md') 'Intake guidance is missing from ZIP.'
        Assert-True ($zipEntries -contains '.ai/context/file-journey.md') 'File journey graph template is missing from ZIP.'
        Assert-True ($zipEntries -contains 'AGENTS.md') 'Compact AGENTS.md context is missing from ZIP.'
        Assert-True ($zipEntries -contains '.github/instructions/documentation.instructions.md') 'Documentation routing instruction is missing from ZIP.'
        Assert-True ($zipEntries -contains '.rpa-ai/kit-manifest.json') 'Payload metadata is missing from ZIP.'
        Assert-True ($zipEntries -contains '.rpa-ai/kit-manifest.sha256') 'Payload manifest digest is missing from ZIP.'
        Assert-True ($zipEntries -contains '.rpa-ai/scripts/Import-RpaAiDevKit.ps1') 'Checked ZIP installer is missing from ZIP.'
        Assert-True ($zipEntries -notcontains 'docs/IMPROVEMENT-BACKLOG.md') 'Central backlog leaked into ZIP.'
    } finally {
        $archive.Dispose()
    }

    $exportTraversalManifest = Join-Path $testRoot 'export-traversal-manifest.json'
    [ordered]@{
        schemaVersion = 1
        kitVersionFile = 'VERSION'
        files = @(
            [ordered]@{ source = 'README.md'; destination = '../escaped.txt'; ownership = 'managed' }
        )
        gitignoreEntries = @('.uipath/.skills/')
    } | ConvertTo-Json -Depth 5 | Set-Content $exportTraversalManifest -Encoding UTF8
    $exportTraversalRoot = Join-Path $testRoot 'export-traversal'
    $exportTraversalBlocked = $false
    try {
        & (Join-Path $root 'scripts\Export-RpaAiDevKit.ps1') -ManifestPath $exportTraversalManifest -OutputDirectory $exportTraversalRoot -NoZip
    } catch {
        $exportTraversalBlocked = $_.Exception.Message -match 'escapes'
    }
    Assert-True $exportTraversalBlocked 'Exporter destination traversal was not rejected.'
    Assert-True (-not (Test-Path (Join-Path $exportTraversalRoot 'escaped.txt'))) 'Exporter wrote outside the payload root.'

    $bot = Join-Path $testRoot 'existing-bot'
    New-Item -ItemType Directory -Force -Path $bot | Out-Null
    & (Join-Path $payload.FullName '.rpa-ai\scripts\Import-RpaAiDevKit.ps1') -PayloadPath $payload.FullName -TargetBotPath $bot
    Assert-True (-not (Test-Path (Join-Path $bot 'graphify-out\graph.json'))) 'Project-less new-bot activation performed an unnecessary graph extraction.'
    & (Join-Path $bot '.rpa-ai\scripts\Test-ManagedFileIntegrity.ps1') -TargetBotPath $bot
    & (Join-Path $bot '.rpa-ai\scripts\Get-DevKitDiagnostics.ps1') -TargetBotPath $bot
    Assert-True ((Get-Content $env:FAKE_UIP_LOG -Raw) -match 'skills\|install\|--agent\|copilot\|--local') 'Activation did not install UiPath skills locally.'
    $dependencyProject = Join-Path $testRoot 'dependency-project'
    New-Item -ItemType Directory -Force -Path $dependencyProject | Out-Null
    @{ name = 'DependencyBot'; main = 'Main.xaml'; dependencies = @{} } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $dependencyProject 'project.json') -Encoding UTF8
    $dependencyStatePath = Join-Path $dependencyProject '.ai\evidence\dependency-state.json'
    & (Join-Path $bot '.rpa-ai\scripts\Get-DependencyState.ps1') -ProjectPath $dependencyProject -StatePath $dependencyStatePath -AvailabilityStatus VERIFIED -Record | Out-Null
    $dependencyMatch = & (Join-Path $bot '.rpa-ai\scripts\Get-DependencyState.ps1') -ProjectPath $dependencyProject -StatePath $dependencyStatePath -Verify -Json | ConvertFrom-Json
    Assert-True ($dependencyMatch.status -eq 'MATCH') 'Matching dependency state was not recognized.'
    $cliDependencyStatePath = Join-Path $dependencyProject '.ai\evidence\dependency-state-cli.json'
    & (Join-Path $bot '.rpa-ai\scripts\Get-DependencyState.ps1') -ProjectPath $dependencyProject -StatePath $cliDependencyStatePath -CliVersion 'uip-test-1' -AvailabilityStatus VERIFIED -Record | Out-Null
    $cliDependencyMatch = & (Join-Path $bot '.rpa-ai\scripts\Get-DependencyState.ps1') -ProjectPath $dependencyProject -StatePath $cliDependencyStatePath -CliVersion 'uip-test-1' -Verify -Json | ConvertFrom-Json
    Assert-True ($cliDependencyMatch.status -eq 'MATCH') 'Matching CLI-aware dependency state was not recognized.'
    $cliDependencyChanged = & (Join-Path $bot '.rpa-ai\scripts\Get-DependencyState.ps1') -ProjectPath $dependencyProject -StatePath $cliDependencyStatePath -CliVersion 'uip-test-2' -Verify -Json | ConvertFrom-Json
    Assert-True ($cliDependencyChanged.status -eq 'CHANGED') 'CLI version changes were incorrectly treated as reusable dependency state.'
    New-Item -ItemType Directory -Force -Path (Join-Path $dependencyProject 'node_modules\ignored') | Out-Null
    @{ changed = $true } | ConvertTo-Json | Set-Content (Join-Path $dependencyProject 'node_modules\ignored\project.json')
    $dependencyPruned = & (Join-Path $bot '.rpa-ai\scripts\Get-DependencyState.ps1') -ProjectPath $dependencyProject -StatePath $dependencyStatePath -Verify -Json | ConvertFrom-Json
    Assert-True ($dependencyPruned.status -eq 'MATCH') 'Excluded dependency directories changed the fingerprint.'
    Add-Content (Join-Path $dependencyProject 'project.json') "`n"
    $dependencyChanged = & (Join-Path $bot '.rpa-ai\scripts\Get-DependencyState.ps1') -ProjectPath $dependencyProject -StatePath $dependencyStatePath -Verify -Json 2>$null | ConvertFrom-Json
    Assert-True ($dependencyChanged.status -eq 'CHANGED') 'Changed dependency state was not detected.'
    '{"schemaVersion":1,"stateHash":"bad"}' | Set-Content $dependencyStatePath
    $dependencyUncertain = & (Join-Path $bot '.rpa-ai\scripts\Get-DependencyState.ps1') -ProjectPath $dependencyProject -StatePath $dependencyStatePath -Verify -Json | ConvertFrom-Json
    Assert-True ($dependencyUncertain.status -eq 'UNCERTAIN') 'Malformed dependency state was incorrectly reusable.'
    $savedTestPath = $env:PATH
    $env:PATH = $originalPath
    & (Join-Path $bot '.rpa-ai\scripts\Refresh-BotGraph.ps1') -TargetBotPath $bot -Mode Update
    $env:PATH = $savedTestPath
    Assert-True (Test-Path (Join-Path $bot '.rpa-ai\local\tool-paths.json')) 'Resolved user-profile tool paths were not persisted.'
    $env:PATH = "$fakeBin$([System.IO.Path]::PathSeparator)$originalPath"

    $outlookResult = & (Join-Path $bot '.rpa-ai\scripts\Test-OutlookCapability.ps1') -TargetBotPath $bot -Json | ConvertFrom-Json
    Assert-True (-not $outlookResult.OUTLOOK_ACTIVITY_AVAILABLE) 'Outlook capability unexpectedly passed without a declared Outlook package.'
    Assert-True (Test-Path (Join-Path $bot '.rpa-ai\local\outlook-capability.json')) 'Outlook capability result was not persisted in local state.'

    $versionManifestPath = Join-Path $bot '.rpa-ai\kit-manifest.json'
    $versionManifest = Get-Content $versionManifestPath -Raw | ConvertFrom-Json
    $versionManifest.kitVersion = '0.9.0'
    $versionManifest | ConvertTo-Json -Depth 6 | Set-Content $versionManifestPath -Encoding UTF8
    Write-ManifestDigest $versionManifestPath
    $versionResult = & (Join-Path $bot '.rpa-ai\scripts\Check-DevKitRemoteVersion.ps1') -TargetBotPath $bot -Json | ConvertFrom-Json
    Assert-True ($versionResult.status -eq 'UPDATE_AVAILABLE' -and $versionResult.latestVersion -eq 'v0.11.7') 'Remote stable release detection did not identify v0.11.7.'
    $versionManifest.kitVersion = '0.11.7'
    $versionManifest | ConvertTo-Json -Depth 6 | Set-Content $versionManifestPath -Encoding UTF8
    Write-ManifestDigest $versionManifestPath
    $currentVersionResult = & (Join-Path $bot '.rpa-ai\scripts\Check-DevKitRemoteVersion.ps1') -TargetBotPath $bot -Json | ConvertFrom-Json
    Assert-True ($currentVersionResult.status -eq 'CURRENT') 'Current Dev Kit version was not recognized.'
    $env:FAKE_GIT_FAIL_TAGS = '1'
    $cachedVersionResult = & (Join-Path $bot '.rpa-ai\scripts\Check-DevKitRemoteVersion.ps1') -TargetBotPath $bot -Json | ConvertFrom-Json
    $env:FAKE_GIT_FAIL_TAGS = $null
    Assert-True ($cachedVersionResult.status -eq 'CURRENT') 'Fresh version-check cache was not reused.'

    $versionManifest.kitVersion = 'invalid-version'
    $versionManifest | ConvertTo-Json -Depth 6 | Set-Content $versionManifestPath -Encoding UTF8
    Write-ManifestDigest $versionManifestPath
    $invalidVersionResult = & (Join-Path $bot '.rpa-ai\scripts\Check-DevKitRemoteVersion.ps1') -TargetBotPath $bot -Json | ConvertFrom-Json
    Assert-True ($invalidVersionResult.status -eq 'UNAVAILABLE') 'Invalid installed semantic version did not fail open.'
    $versionManifest.kitVersion = '0.11.7'
    $versionManifest | ConvertTo-Json -Depth 6 | Set-Content $versionManifestPath -Encoding UTF8
    Write-ManifestDigest $versionManifestPath
    $env:FAKE_GIT_NO_VALID_TAGS = '1'
    $noTagsResult = & (Join-Path $bot '.rpa-ai\scripts\Check-DevKitRemoteVersion.ps1') -TargetBotPath $bot -Json -Force | ConvertFrom-Json
    $env:FAKE_GIT_NO_VALID_TAGS = $null
    Assert-True ($noTagsResult.status -eq 'UNAVAILABLE') 'Remote tag lookup with no valid stable tags did not fail open.'
    $env:FAKE_GIT_FAIL_TAGS = '1'
    $failedTagsResult = & (Join-Path $bot '.rpa-ai\scripts\Check-DevKitRemoteVersion.ps1') -TargetBotPath $bot -Json -Force | ConvertFrom-Json
    $env:FAKE_GIT_FAIL_TAGS = $null
    Assert-True ($failedTagsResult.status -eq 'UNAVAILABLE') 'Remote tag lookup failure did not fail open.'

    $outlookProject = [ordered]@{
        name = 'OutlookCapabilityBot'
        main = 'Main.xaml'
        dependencies = [ordered]@{ 'UiPath.Outlook.Activities' = '[1.0.0]' }
    }
    $outlookProject | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $bot 'project.json') -Encoding UTF8
    $outlookFixtureScript = Join-Path $testRoot 'Test-OutlookCapability-Unavailable.ps1'
    $outlookProbeText = Get-Content (Join-Path $bot '.rpa-ai\scripts\Test-OutlookCapability.ps1') -Raw
    $outlookProbeText = $outlookProbeText.Replace('$application = New-Object -ComObject Outlook.Application', "throw 'Test fixture blocks Outlook COM access.'")
    [System.IO.File]::WriteAllText($outlookFixtureScript, $outlookProbeText, (New-Object System.Text.UTF8Encoding($false)))
    $unavailableOutlookResult = & $outlookFixtureScript -TargetBotPath $bot -Json | ConvertFrom-Json
    Assert-True ($unavailableOutlookResult.packageAvailable -and -not $unavailableOutlookResult.mailboxAccessible -and -not $unavailableOutlookResult.OUTLOOK_ACTIVITY_AVAILABLE) 'Outlook package-present unavailable capability path was not detected.'
    Remove-Item (Join-Path $bot 'project.json') -Force

    if ($Full) {
    $installedManifest = Join-Path $bot '.rpa-ai\kit-manifest.json'
    $installedManifestBackup = Get-Content $installedManifest -Raw
    $graphifyCallsBeforeMetadataFailure = @(Get-Content $env:FAKE_GRAPHIFY_LOG).Count
    Remove-Item $installedManifest
    $missingManifestBlocked = $false
    try { & (Join-Path $bot '.rpa-ai\scripts\Refresh-BotGraph.ps1') -TargetBotPath $bot -Mode Update } catch { $missingManifestBlocked = $_.Exception.Message -match 'manifest not found' }
    Assert-True $missingManifestBlocked 'Installed graph refresh did not fail closed when its manifest was deleted.'
    Assert-True (@(Get-Content $env:FAKE_GRAPHIFY_LOG).Count -eq $graphifyCallsBeforeMetadataFailure) 'Graphify ran after installed manifest deletion.'
    [System.IO.File]::WriteAllText($installedManifest, $installedManifestBackup, (New-Object System.Text.UTF8Encoding($false)))
    Add-Content $installedManifest 'tampered manifest'
    $alteredManifestBlocked = $false
    try { & (Join-Path $bot '.rpa-ai\scripts\Query-BotGraph.ps1') -TargetBotPath $bot -Question 'must not run' } catch { $alteredManifestBlocked = $_.Exception.Message -match 'digest verification failed' }
    Assert-True $alteredManifestBlocked 'Installed graph query accepted an altered manifest.'
    Assert-True (@(Get-Content $env:FAKE_GRAPHIFY_LOG).Count -eq $graphifyCallsBeforeMetadataFailure) 'Graphify ran after installed manifest alteration.'
    [System.IO.File]::WriteAllText($installedManifest, $installedManifestBackup, (New-Object System.Text.UTF8Encoding($false)))
    Write-ManifestDigest $installedManifest
    'bot-owned intake' | Set-Content (Join-Path $bot '.ai\intake\README.md')
    'bot-owned feedback' | Set-Content (Join-Path $bot '.ai\feedback\dev-kit-improvements.md')
    & (Join-Path $root 'scripts\Import-RpaAiDevKit.ps1') -PayloadPath $payload.FullName -TargetBotPath $bot
    Assert-True ((Get-Content (Join-Path $bot '.ai\intake\README.md') -Raw).Trim() -eq 'bot-owned intake') 'Bot-owned intake was overwritten.'
    Assert-True ((Get-Content (Join-Path $bot '.ai\feedback\dev-kit-improvements.md') -Raw).Trim() -eq 'bot-owned feedback') 'Bot-owned Dev Kit feedback was overwritten.'
    'local managed change' | Set-Content (Join-Path $bot '.github\copilot-instructions.md')
    $integrityBlocked = $false
    try {
        & (Join-Path $bot '.rpa-ai\scripts\Test-ManagedFileIntegrity.ps1') -TargetBotPath $bot
    } catch {
        $integrityBlocked = $_.Exception.Message -match 'integrity failed'
    }
    Assert-True $integrityBlocked 'Managed-file integrity accepted a locally modified core file.'
    $refreshIntegrityBlocked = $false
    try {
        & (Join-Path $bot '.rpa-ai\scripts\Refresh-BotGraph.ps1') -TargetBotPath $bot -Mode Update
    } catch {
        $refreshIntegrityBlocked = $_.Exception.Message -match 'integrity failed'
    }
    Assert-True $refreshIntegrityBlocked 'Graph refresh bypassed managed-file integrity.'
    $conflictBlocked = $false
    try {
        & (Join-Path $root 'scripts\Import-RpaAiDevKit.ps1') -PayloadPath $payload.FullName -TargetBotPath $bot
    } catch {
        $conflictBlocked = $_.Exception.Message -match 'preflight'
    }
    Assert-True $conflictBlocked 'A locally modified managed file did not block import.'
    Assert-True ((Get-Content (Join-Path $bot '.github\copilot-instructions.md') -Raw).Trim() -eq 'local managed change') 'Import overwrote a conflicting managed file.'
    & (Join-Path $root 'scripts\Import-RpaAiDevKit.ps1') -PayloadPath $payload.FullName -TargetBotPath $bot -OverwriteManaged
    Assert-True ((Get-FileHash (Join-Path $bot '.github\copilot-instructions.md')).Hash -eq (Get-FileHash (Join-Path $payload.FullName '.github\copilot-instructions.md')).Hash) 'Reviewed overwrite did not replace the managed file.'
    Assert-True ((Get-Content (Join-Path $bot '.ai\intake\README.md') -Raw).Trim() -eq 'bot-owned intake') 'Reviewed overwrite replaced bot-owned intake.'
    }

    if ($Full) {
    $upgradeBot = Join-Path $testRoot 'upgrade-bot'
    New-Item -ItemType Directory -Force -Path $upgradeBot | Out-Null
    & (Join-Path $root 'scripts\Import-RpaAiDevKit.ps1') -PayloadPath $payload.FullName -TargetBotPath $upgradeBot
    $upgradePayload = Join-Path $testRoot 'upgrade-payload'
    Copy-Item $payload.FullName $upgradePayload -Recurse
    $upgradedStart = Join-Path $upgradePayload 'START-HERE.md'
    Add-Content $upgradedStart 'Upgrade marker'
    $upgradeManifestPath = Join-Path $upgradePayload '.rpa-ai\kit-manifest.json'
    $upgradeManifest = Get-Content $upgradeManifestPath -Raw | ConvertFrom-Json
    $upgradeManifest.kitVersion = '0.7.1'
    ($upgradeManifest.files | Where-Object path -eq 'START-HERE.md').sha256 = (Get-FileHash $upgradedStart -Algorithm SHA256).Hash.ToLowerInvariant()
    $upgradeManifest.gitignoreEntries = @($upgradeManifest.gitignoreEntries) + 'future-cache/'
    $upgradeManifest | ConvertTo-Json -Depth 6 | Set-Content $upgradeManifestPath -Encoding UTF8
    Write-ManifestDigest $upgradeManifestPath
    $upgradeRequired = $false
    try {
        & (Join-Path $root 'scripts\Import-RpaAiDevKit.ps1') -PayloadPath $upgradePayload -TargetBotPath $upgradeBot
    } catch {
        $upgradeRequired = $_.Exception.Message -match 'preflight'
    }
    Assert-True $upgradeRequired 'An unchanged managed installation upgraded without -Upgrade.'
    & (Join-Path $root 'scripts\Import-RpaAiDevKit.ps1') -PayloadPath $upgradePayload -TargetBotPath $upgradeBot -Upgrade
    Assert-True ((Get-Content (Join-Path $upgradeBot 'START-HERE.md') -Raw) -match 'Upgrade marker') 'Managed file was not upgraded.'
    Assert-True ((Get-Content (Join-Path $upgradeBot '.gitignore') -Raw) -match 'future-cache/') 'Managed gitignore block was not upgraded.'
    Assert-True ((Get-Content (Join-Path $upgradeBot '.rpa-ai\kit-manifest.json') -Raw | ConvertFrom-Json).kitVersion -eq '0.7.1') 'Installed metadata did not advance after successful upgrade.'
    Remove-Item (Join-Path $upgradeBot '.github\agents\rpa-auditor.agent.md')
    & (Join-Path $root 'scripts\Import-RpaAiDevKit.ps1') -PayloadPath $upgradePayload -TargetBotPath $upgradeBot
    Assert-True (Test-Path (Join-Path $upgradeBot '.github\agents\rpa-auditor.agent.md')) 'Missing managed file was not repaired.'

    $automaticUpdateBot = Join-Path $testRoot 'automatic-update-bot'
    New-Item -ItemType Directory -Force -Path $automaticUpdateBot | Out-Null
    & (Join-Path $root 'scripts\Import-RpaAiDevKit.ps1') -PayloadPath $payload.FullName -TargetBotPath $automaticUpdateBot
    $automaticManifestPath = Join-Path $automaticUpdateBot '.rpa-ai\kit-manifest.json'
    $automaticManifest = Get-Content $automaticManifestPath -Raw | ConvertFrom-Json
    $automaticManifest.kitVersion = '0.10.0'
    $automaticManifest.PSObject.Properties.Remove('sourceRepository')
    $automaticManifest | ConvertTo-Json -Depth 6 | Set-Content $automaticManifestPath -Encoding UTF8
    Write-ManifestDigest $automaticManifestPath
    'bot-owned documentation' | Set-Content (Join-Path $automaticUpdateBot 'README.md')
    $confirmationBlocked = $false
    try {
        & (Join-Path $automaticUpdateBot '.rpa-ai\scripts\Update-RpaAiDevKit.ps1') -TargetBotPath $automaticUpdateBot -Version v0.11.7
    } catch {
        $confirmationBlocked = $_.Exception.Message -match 'Explicit update choice is required'
    }
    Assert-True $confirmationBlocked 'Automatic update ran without explicit confirmation.'
    & (Join-Path $automaticUpdateBot '.rpa-ai\scripts\Update-RpaAiDevKit.ps1') -TargetBotPath $automaticUpdateBot -Version v0.11.7 -ConfirmUpdate
    $updatedAutomaticManifest = Get-Content $automaticManifestPath -Raw | ConvertFrom-Json
    Assert-True ($updatedAutomaticManifest.kitVersion -eq '0.11.7') 'Automatic update did not advance installed version metadata.'
    Assert-True ((Get-Content (Join-Path $automaticUpdateBot 'README.md') -Raw).Trim() -eq 'bot-owned documentation') 'Automatic update overwrote bot-owned documentation.'

    $junctionUpdateBot = Join-Path $testRoot 'junction-update-bot'
    $junctionUpdateOutside = Join-Path $testRoot 'junction-update-outside'
    New-Item -ItemType Directory -Force -Path $junctionUpdateBot,$junctionUpdateOutside | Out-Null
    & (Join-Path $root 'scripts\Import-RpaAiDevKit.ps1') -PayloadPath $payload.FullName -TargetBotPath $junctionUpdateBot
    $junctionManifestPath = Join-Path $junctionUpdateBot '.rpa-ai\kit-manifest.json'
    $junctionManifest = Get-Content $junctionManifestPath -Raw | ConvertFrom-Json
    $junctionManifest.kitVersion = '0.10.0'
    $junctionManifest.PSObject.Properties.Remove('sourceRepository')
    $junctionManifest | ConvertTo-Json -Depth 6 | Set-Content $junctionManifestPath -Encoding UTF8
    Write-ManifestDigest $junctionManifestPath
    Remove-Item (Join-Path $junctionUpdateBot '.ai\context') -Recurse -Force
    New-Item -ItemType Junction -Path (Join-Path $junctionUpdateBot '.ai\context') -Target $junctionUpdateOutside | Out-Null
    $junctionUpdateBlocked = $false
    try {
        & (Join-Path $junctionUpdateBot '.rpa-ai\scripts\Update-RpaAiDevKit.ps1') -TargetBotPath $junctionUpdateBot -Version v0.11.7 -ConfirmUpdate
    } catch {
        $junctionUpdateBlocked = $_.Exception.Message -match 'reparse point'
    }
    Assert-True $junctionUpdateBlocked 'Automatic update crossed a preserve-path junction.'
    Assert-True (@(Get-ChildItem $junctionUpdateOutside -Force).Count -eq 0) 'Automatic update wrote through a preserve-path junction.'

    $rootPayloadJunction = Join-Path $testRoot 'root-payload-junction'
    $rootPayloadBot = Join-Path $testRoot 'root-payload-bot'
    New-Item -ItemType Directory -Force -Path $rootPayloadBot | Out-Null
    New-Item -ItemType Junction -Path $rootPayloadJunction -Target $payload.FullName | Out-Null
    $rootPayloadBlocked = $false
    try {
        & (Join-Path $root 'scripts\Import-RpaAiDevKit.ps1') -PayloadPath $rootPayloadJunction -TargetBotPath $rootPayloadBot
    } catch {
        $rootPayloadBlocked = $_.Exception.Message -match 'Payload root is a reparse point'
    }
    Assert-True $rootPayloadBlocked 'Import accepted a payload root junction.'
    Assert-True (-not (Test-Path (Join-Path $rootPayloadBot '.rpa-ai\kit-manifest.json'))) 'Payload root junction rejection mutated the target bot.'

    $rootTargetBacking = Join-Path $testRoot 'root-target-backing'
    $rootTargetJunction = Join-Path $testRoot 'root-target-junction'
    New-Item -ItemType Directory -Force -Path $rootTargetBacking | Out-Null
    New-Item -ItemType Junction -Path $rootTargetJunction -Target $rootTargetBacking | Out-Null
    $rootTargetBlocked = $false
    try {
        & (Join-Path $root 'scripts\Import-RpaAiDevKit.ps1') -PayloadPath $payload.FullName -TargetBotPath $rootTargetJunction
    } catch {
        $rootTargetBlocked = $_.Exception.Message -match 'Target root is a reparse point'
    }
    Assert-True $rootTargetBlocked 'Import accepted a target root junction.'
    Assert-True (@(Get-ChildItem $rootTargetBacking -Force).Count -eq 0) 'Import wrote through a target root junction.'

    $importScriptText = Get-Content (Join-Path $root 'scripts\Import-RpaAiDevKit.ps1') -Raw
    Assert-True ($importScriptText -match '(?s)catch \{.*Assert-NoReparsePointAncestors \$TargetBotPath \$item\.Destination') 'Import rollback is missing its reparse-point guard.'

    $rootIntegrityJunction = Join-Path $testRoot 'root-integrity-junction'
    New-Item -ItemType Junction -Path $rootIntegrityJunction -Target $bot | Out-Null
    $rootIntegrityBlocked = $false
    try {
        & (Join-Path $bot '.rpa-ai\scripts\Test-ManagedFileIntegrity.ps1') -TargetBotPath $rootIntegrityJunction
    } catch {
        $rootIntegrityBlocked = $_.Exception.Message -match 'Managed root is a reparse point'
    }
    Assert-True $rootIntegrityBlocked 'Managed integrity accepted a bot root junction.'

    $rootUpdateBacking = Join-Path $testRoot 'root-update-backing'
    $rootUpdateJunction = Join-Path $testRoot 'root-update-junction'
    New-Item -ItemType Directory -Force -Path $rootUpdateBacking | Out-Null
    & (Join-Path $root 'scripts\Import-RpaAiDevKit.ps1') -PayloadPath $payload.FullName -TargetBotPath $rootUpdateBacking
    $rootUpdateManifestPath = Join-Path $rootUpdateBacking '.rpa-ai\kit-manifest.json'
    $rootUpdateManifest = Get-Content $rootUpdateManifestPath -Raw | ConvertFrom-Json
    $rootUpdateManifest.kitVersion = '0.10.0'
    $rootUpdateManifest.PSObject.Properties.Remove('sourceRepository')
    $rootUpdateManifest | ConvertTo-Json -Depth 6 | Set-Content $rootUpdateManifestPath -Encoding UTF8
    Write-ManifestDigest $rootUpdateManifestPath
    $rootUpdateManifestBefore = Get-Content $rootUpdateManifestPath -Raw
    New-Item -ItemType Junction -Path $rootUpdateJunction -Target $rootUpdateBacking | Out-Null
    $rootUpdateBlocked = $false
    try {
        & (Join-Path $rootUpdateBacking '.rpa-ai\scripts\Update-RpaAiDevKit.ps1') -TargetBotPath $rootUpdateJunction -Version v0.11.7 -ConfirmUpdate
    } catch {
        $rootUpdateBlocked = $_.Exception.Message -match 'Update root is a reparse point'
    }
    Assert-True $rootUpdateBlocked 'Automatic update accepted a bot root junction.'
    Assert-True ((Get-Content $rootUpdateManifestPath -Raw) -eq $rootUpdateManifestBefore) 'Root update junction rejection changed the backing installation.'

    $rollbackBot = Join-Path $testRoot 'automatic-rollback-bot'
    New-Item -ItemType Directory -Force -Path $rollbackBot | Out-Null
    & (Join-Path $root 'scripts\Import-RpaAiDevKit.ps1') -PayloadPath $payload.FullName -TargetBotPath $rollbackBot
    $rollbackManifestPath = Join-Path $rollbackBot '.rpa-ai\kit-manifest.json'
    $rollbackManifest = Get-Content $rollbackManifestPath -Raw | ConvertFrom-Json
    $rollbackManifest.kitVersion = '0.10.0'
    $rollbackManifest | ConvertTo-Json -Depth 6 | Set-Content $rollbackManifestPath -Encoding UTF8
    Write-ManifestDigest $rollbackManifestPath
    'rollback-owned documentation' | Set-Content (Join-Path $rollbackBot 'README.md')
    $rollbackStartPath = Join-Path $rollbackBot 'START-HERE.md'
    $rollbackDigestPath = Join-Path $rollbackBot '.rpa-ai\kit-manifest.sha256'
    $rollbackGitignorePath = Join-Path $rollbackBot '.gitignore'
    $rollbackStartHash = (Get-FileHash $rollbackStartPath -Algorithm SHA256).Hash
    $rollbackManifestHash = (Get-FileHash $rollbackManifestPath -Algorithm SHA256).Hash
    $rollbackDigestHash = (Get-FileHash $rollbackDigestPath -Algorithm SHA256).Hash
    $rollbackGitignoreHash = (Get-FileHash $rollbackGitignorePath -Algorithm SHA256).Hash
    $env:FAKE_DEVKIT_UPDATE_MARKER = 'rollback update marker'
    $env:FAKE_UIP_FAIL_HELP = '1'
    $rollbackFailure = $false
    try {
        & (Join-Path $rollbackBot '.rpa-ai\scripts\Update-RpaAiDevKit.ps1') -TargetBotPath $rollbackBot -Version v0.11.7 -ConfirmUpdate
    } catch {
        $rollbackFailure = $_.Exception.Message -match 'previous installation was restored and passed managed-file integrity'
    }
    $env:FAKE_UIP_FAIL_HELP = $null
    $env:FAKE_DEVKIT_UPDATE_MARKER = $null
    Assert-True $rollbackFailure 'Failed automatic update did not report a validated rollback.'
    Assert-True ((Get-FileHash $rollbackStartPath -Algorithm SHA256).Hash -eq $rollbackStartHash) 'Update rollback did not restore the managed file.'
    Assert-True ((Get-FileHash $rollbackManifestPath -Algorithm SHA256).Hash -eq $rollbackManifestHash) 'Update rollback did not restore kit-manifest.json.'
    Assert-True ((Get-FileHash $rollbackDigestPath -Algorithm SHA256).Hash -eq $rollbackDigestHash) 'Update rollback did not restore kit-manifest.sha256.'
    Assert-True ((Get-FileHash $rollbackGitignorePath -Algorithm SHA256).Hash -eq $rollbackGitignoreHash) 'Update rollback did not restore .gitignore.'
    Assert-True ((Get-Content (Join-Path $rollbackBot 'README.md') -Raw).Trim() -eq 'rollback-owned documentation') 'Update rollback altered bot-owned documentation.'

    $legacyBot = Join-Path $testRoot 'legacy-bot'
    New-Item -ItemType Directory -Force -Path (Join-Path $legacyBot '.github') | Out-Null
    'legacy local policy' | Set-Content (Join-Path $legacyBot '.github\copilot-instructions.md')
    $legacyBlocked = $false
    try {
        & (Join-Path $root 'scripts\Import-RpaAiDevKit.ps1') -PayloadPath $payload.FullName -TargetBotPath $legacyBot
    } catch {
        $legacyBlocked = $_.Exception.Message -match 'preflight'
    }
    Assert-True $legacyBlocked 'Legacy managed-file conflict was not blocked.'
    Assert-True (-not (Test-Path (Join-Path $legacyBot '.rpa-ai\kit-manifest.json'))) 'Legacy conflict wrote installed metadata.'
    }

    if ($Full) {
    $tamperedPayload = Join-Path $testRoot 'tampered-payload'
    Copy-Item $payload.FullName $tamperedPayload -Recurse
    Add-Content (Join-Path $tamperedPayload 'START-HERE.md') 'tampered'
    $tamperBot = Join-Path $testRoot 'tamper-bot'
    New-Item -ItemType Directory -Force -Path $tamperBot | Out-Null
    $tamperBlocked = $false
    try {
        & (Join-Path $root 'scripts\Import-RpaAiDevKit.ps1') -PayloadPath $tamperedPayload -TargetBotPath $tamperBot
    } catch {
        $tamperBlocked = $_.Exception.Message -match 'hash mismatch'
    }
    Assert-True $tamperBlocked 'Tampered payload file was not rejected.'
    Assert-True (-not (Test-Path (Join-Path $tamperBot '.rpa-ai\kit-manifest.json'))) 'Tampered payload wrote installed metadata.'

    $invalidPayload = Join-Path $testRoot 'invalid-payload'
    Copy-Item $payload.FullName $invalidPayload -Recurse
    $invalidManifestPath = Join-Path $invalidPayload '.rpa-ai\kit-manifest.json'
    $invalidManifest = Get-Content $invalidManifestPath -Raw | ConvertFrom-Json
    $invalidManifest.files[0].path = '../escape.txt'
    $invalidManifest | ConvertTo-Json -Depth 6 | Set-Content $invalidManifestPath -Encoding UTF8
    Write-ManifestDigest $invalidManifestPath
    $invalidBot = Join-Path $testRoot 'invalid-bot'
    New-Item -ItemType Directory -Force -Path $invalidBot | Out-Null
    $pathBlocked = $false
    try {
        & (Join-Path $root 'scripts\Import-RpaAiDevKit.ps1') -PayloadPath $invalidPayload -TargetBotPath $invalidBot
    } catch {
        $pathBlocked = $_.Exception.Message -match 'escapes'
    }
    Assert-True $pathBlocked 'Manifest path traversal was not rejected.'
    Assert-True (-not (Test-Path (Join-Path $testRoot 'escape.txt'))) 'Manifest path traversal wrote outside the bot root.'

    $junctionBot = Join-Path $testRoot 'junction-bot'
    $junctionOutside = Join-Path $testRoot 'junction-outside'
    New-Item -ItemType Directory -Force -Path $junctionBot,$junctionOutside | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $junctionBot '.github') -Target $junctionOutside | Out-Null
    $junctionBlocked = $false
    try {
        & (Join-Path $root 'scripts\Import-RpaAiDevKit.ps1') -PayloadPath $payload.FullName -TargetBotPath $junctionBot
    } catch {
        $junctionBlocked = $_.Exception.Message -match 'reparse point'
    }
    Assert-True $junctionBlocked 'Target junction escape was not rejected.'
    Assert-True (-not (Test-Path (Join-Path $junctionOutside 'copilot-instructions.md'))) 'Import wrote through a target junction.'

    $incomingJunctionPayload = Join-Path $testRoot 'incoming-junction-payload'
    $incomingJunctionOutside = Join-Path $testRoot 'incoming-junction-outside'
    New-Item -ItemType Directory -Force -Path $incomingJunctionPayload,$incomingJunctionOutside | Out-Null
    '{ malformed incoming manifest' | Set-Content (Join-Path $incomingJunctionOutside 'kit-manifest.json')
    New-Item -ItemType Junction -Path (Join-Path $incomingJunctionPayload '.rpa-ai') -Target $incomingJunctionOutside | Out-Null
    $incomingJunctionBot = Join-Path $testRoot 'incoming-junction-bot'
    New-Item -ItemType Directory -Force -Path $incomingJunctionBot | Out-Null
    $incomingJunctionBlocked = $false
    try {
        & (Join-Path $root 'scripts\Import-RpaAiDevKit.ps1') -PayloadPath $incomingJunctionPayload -TargetBotPath $incomingJunctionBot
    } catch {
        $incomingJunctionBlocked = $_.Exception.Message -match 'reparse point'
    }
    Assert-True $incomingJunctionBlocked 'Incoming metadata junction was read before rejection.'

    $singlePayload = Join-Path $testRoot 'single-payload'
    New-Item -ItemType Directory -Force -Path (Join-Path $singlePayload '.rpa-ai') | Out-Null
    'single payload file' | Set-Content (Join-Path $singlePayload 'START-HERE.md')
    $singleManifest = [ordered]@{
        schemaVersion = 1
        kitVersion = 'test'
        files = @(
            [ordered]@{
                path = 'START-HERE.md'
                ownership = 'managed'
                sha256 = (Get-FileHash (Join-Path $singlePayload 'START-HERE.md') -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        )
        gitignoreEntries = @('.uipath/.skills/')
    }
    $singleManifest | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $singlePayload '.rpa-ai\kit-manifest.json') -Encoding UTF8
    Write-ManifestDigest (Join-Path $singlePayload '.rpa-ai\kit-manifest.json')
    $singleBot = Join-Path $testRoot 'single-bot'
    New-Item -ItemType Directory -Force -Path $singleBot | Out-Null
    $activationOmissionBlocked = $false
    try {
        & (Join-Path $root 'scripts\Import-RpaAiDevKit.ps1') -PayloadPath $singlePayload -TargetBotPath $singleBot
    } catch {
        $activationOmissionBlocked = $_.Exception.Message -match 'exactly one managed.*Activate-RpaAiDevKit'
    }
    Assert-True $activationOmissionBlocked 'Payload without mandatory activation was imported.'
    Assert-True (-not (Test-Path (Join-Path $singleBot 'START-HERE.md'))) 'Activation-omission rejection mutated the bot root.'
    Assert-True (-not (Test-Path (Join-Path $singleBot '.rpa-ai\kit-manifest.json'))) 'Activation-omission rejection advanced installed metadata.'

    $metadataJunctionBot = Join-Path $testRoot 'metadata-junction-bot'
    $metadataJunctionOutside = Join-Path $testRoot 'metadata-junction-outside'
    New-Item -ItemType Directory -Force -Path $metadataJunctionBot,$metadataJunctionOutside | Out-Null
    '{ malformed installed manifest' | Set-Content (Join-Path $metadataJunctionOutside 'kit-manifest.json')
    New-Item -ItemType Junction -Path (Join-Path $metadataJunctionBot '.rpa-ai') -Target $metadataJunctionOutside | Out-Null
    $metadataJunctionBlocked = $false
    try {
        & (Join-Path $root 'scripts\Import-RpaAiDevKit.ps1') -PayloadPath $payload.FullName -TargetBotPath $metadataJunctionBot
    } catch {
        $metadataJunctionBlocked = $_.Exception.Message -match 'reparse point'
    }
    Assert-True $metadataJunctionBlocked 'Installed metadata junction escape was not rejected.'
    Assert-True ((Get-Content (Join-Path $metadataJunctionOutside 'kit-manifest.json') -Raw).Trim() -eq '{ malformed installed manifest') 'Installed metadata outside the bot root was modified through a junction.'

    $schemaPayload = Join-Path $testRoot 'schema-payload'
    Copy-Item $payload.FullName $schemaPayload -Recurse
    $schemaManifestPath = Join-Path $schemaPayload '.rpa-ai\kit-manifest.json'
    $schemaManifest = Get-Content $schemaManifestPath -Raw | ConvertFrom-Json
    $schemaManifest.schemaVersion = 99
    $schemaManifest | ConvertTo-Json -Depth 6 | Set-Content $schemaManifestPath -Encoding UTF8
    Write-ManifestDigest $schemaManifestPath
    $schemaBlocked = $false
    try {
        & (Join-Path $root 'scripts\Import-RpaAiDevKit.ps1') -PayloadPath $schemaPayload -TargetBotPath $invalidBot
    } catch {
        $schemaBlocked = $_.Exception.Message -match 'Unsupported payload manifest schema'
    }
    Assert-True $schemaBlocked 'Unsupported payload schema was not rejected.'

    $ownershipPayload = Join-Path $testRoot 'ownership-payload'
    Copy-Item $payload.FullName $ownershipPayload -Recurse
    $ownershipManifestPath = Join-Path $ownershipPayload '.rpa-ai\kit-manifest.json'
    $ownershipManifest = Get-Content $ownershipManifestPath -Raw | ConvertFrom-Json
    $ownershipManifest.files[0].ownership = 'unknown'
    $ownershipManifest | ConvertTo-Json -Depth 6 | Set-Content $ownershipManifestPath -Encoding UTF8
    Write-ManifestDigest $ownershipManifestPath
    $ownershipBlocked = $false
    try {
        & (Join-Path $root 'scripts\Import-RpaAiDevKit.ps1') -PayloadPath $ownershipPayload -TargetBotPath $invalidBot
    } catch {
        $ownershipBlocked = $_.Exception.Message -match 'Unknown payload ownership'
    }
    Assert-True $ownershipBlocked 'Unknown payload ownership was not rejected.'

    $duplicatePayload = Join-Path $testRoot 'duplicate-payload'
    Copy-Item $payload.FullName $duplicatePayload -Recurse
    $duplicateManifestPath = Join-Path $duplicatePayload '.rpa-ai\kit-manifest.json'
    $duplicateManifest = Get-Content $duplicateManifestPath -Raw | ConvertFrom-Json
    $duplicateManifest.files = @($duplicateManifest.files) + $duplicateManifest.files[0]
    $duplicateManifest | ConvertTo-Json -Depth 6 | Set-Content $duplicateManifestPath -Encoding UTF8
    Write-ManifestDigest $duplicateManifestPath
    $duplicateBlocked = $false
    try {
        & (Join-Path $root 'scripts\Import-RpaAiDevKit.ps1') -PayloadPath $duplicatePayload -TargetBotPath $invalidBot
    } catch {
        $duplicateBlocked = $_.Exception.Message -match 'duplicate .*paths'
    }
    Assert-True $duplicateBlocked 'Duplicate payload paths were not rejected.'

    $normalizedDuplicatePayload = Join-Path $testRoot 'normalized-duplicate-payload'
    New-Item -ItemType Directory -Force -Path (Join-Path $normalizedDuplicatePayload '.rpa-ai') | Out-Null
    'normalized duplicate content' | Set-Content (Join-Path $normalizedDuplicatePayload 'managed.txt')
    $normalizedHash = (Get-FileHash (Join-Path $normalizedDuplicatePayload 'managed.txt') -Algorithm SHA256).Hash.ToLowerInvariant()
    [ordered]@{
        schemaVersion = 1
        kitVersion = 'test'
        files = @(
            [ordered]@{ path = 'managed.txt'; ownership = 'preserve'; sha256 = $normalizedHash },
            [ordered]@{ path = 'folder/../managed.txt'; ownership = 'managed'; sha256 = $normalizedHash }
        )
        gitignoreEntries = @('.uipath/.skills/')
    } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $normalizedDuplicatePayload '.rpa-ai\kit-manifest.json') -Encoding UTF8
    Write-ManifestDigest (Join-Path $normalizedDuplicatePayload '.rpa-ai\kit-manifest.json')
    $normalizedDuplicateBot = Join-Path $testRoot 'normalized-duplicate-bot'
    New-Item -ItemType Directory -Force -Path $normalizedDuplicateBot | Out-Null
    $normalizedDuplicateBlocked = $false
    try {
        & (Join-Path $root 'scripts\Import-RpaAiDevKit.ps1') -PayloadPath $normalizedDuplicatePayload -TargetBotPath $normalizedDuplicateBot
    } catch {
        $normalizedDuplicateBlocked = $_.Exception.Message -match 'duplicate normalized paths'
    }
    Assert-True $normalizedDuplicateBlocked 'Normalized duplicate payload paths were not rejected.'
    Assert-True (-not (Test-Path (Join-Path $normalizedDuplicateBot 'managed.txt'))) 'Normalized duplicate rejection mutated the bot root.'
    Assert-True (-not (Test-Path (Join-Path $normalizedDuplicateBot '.rpa-ai\kit-manifest.json'))) 'Normalized duplicate rejection wrote installed metadata.'

    $rollbackBot = Join-Path $testRoot 'rollback-bot'
    New-Item -ItemType Directory -Force -Path $rollbackBot | Out-Null
    'original start' | Set-Content (Join-Path $rollbackBot 'START-HERE.md')
    'blocks intake directory' | Set-Content (Join-Path $rollbackBot '.ai')
    $rollbackTriggered = $false
    try {
        & (Join-Path $root 'scripts\Import-RpaAiDevKit.ps1') -PayloadPath $payload.FullName -TargetBotPath $rollbackBot -OverwriteManaged
    } catch {
        $rollbackTriggered = $_.Exception.Message -match 'rolled back'
    }
    Assert-True $rollbackTriggered 'Import write failure did not trigger rollback.'
    Assert-True ((Get-Content (Join-Path $rollbackBot 'START-HERE.md') -Raw).Trim() -eq 'original start') 'Import rollback did not restore the original managed file.'
    Assert-True (-not (Test-Path (Join-Path $rollbackBot '.rpa-ai\kit-manifest.json'))) 'Failed import advanced installed metadata.'
    }

    $graphBot = Join-Path $testRoot 'graph-bot'
    New-Item -ItemType Directory -Force -Path (Join-Path $graphBot '.rpa-ai\validation') | Out-Null
    Copy-Item (Join-Path $root 'graph\config\graphify-version.json') (Join-Path $graphBot '.rpa-ai\validation\graphify-version.json')
    '<Activity />' | Set-Content (Join-Path $graphBot 'Main.xaml') -Encoding UTF8
    $env:FAKE_GRAPHIFY_WARNING = '1'
    try { & (Join-Path $root 'scripts\Refresh-BotGraph.ps1') -TargetBotPath $graphBot -Mode Build }
    finally { $env:FAKE_GRAPHIFY_WARNING = $null }
    & (Join-Path $root 'scripts\Query-BotGraph.ps1') -TargetBotPath $graphBot -Question 'Find the main workflow'
    $graphifyRecords = @(Get-Content $env:FAKE_GRAPHIFY_LOG | ForEach-Object { $_ | ConvertFrom-Json })
    $extractRecord = @($graphifyRecords | Where-Object { $_.arguments[0] -eq 'extract' })[0]
    Assert-True ($null -ne $extractRecord) 'Graphify extract was not invoked.'
    Assert-True (@($extractRecord.arguments) -contains '--code-only') 'Graphify extraction was not forced to code-only mode.'
    Assert-True (@($extractRecord.arguments) -contains '--no-cluster') 'Graphify extraction did not disable clustering.'
    Assert-True (-not @($graphifyRecords | Where-Object cloudEnvironmentPresent)) 'Cloud backend credentials reached a Graphify subprocess.'
    Assert-True (-not @($graphifyRecords | Where-Object { -not $_.queryLoggingDisabled })) 'Graphify query logging was not disabled for every subprocess.'
    Assert-True (-not @($graphifyRecords | Where-Object { -not $_.networkIsolationEnabled })) 'Graphify subprocesses did not receive the offline network boundary.'
    Assert-True ($env:OPENAI_API_KEY -eq 'must-not-reach-graphify') 'Graphify wrapper did not restore the caller environment.'
    Assert-True ($env:AWS_ACCESS_KEY_ID -eq 'must-not-reach-graphify') 'Graphify wrapper did not restore AWS environment state.'

    $incrementalGraphBot = Join-Path $testRoot 'incremental-graph-bot'
    New-Item -ItemType Directory -Force -Path (Join-Path $incrementalGraphBot '.rpa-ai\validation') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $incrementalGraphBot '.rpa-ai\local') | Out-Null
    Copy-Item (Join-Path $root 'graph\config\graphify-version.json') (Join-Path $incrementalGraphBot '.rpa-ai\validation\graphify-version.json')
    '<Activity />' | Set-Content (Join-Path $incrementalGraphBot 'Main.xaml') -Encoding UTF8
    [ordered]@{ graphify = (Join-Path $fakeBin 'graphify.cmd') } | ConvertTo-Json |
        Set-Content (Join-Path $incrementalGraphBot '.rpa-ai\local\tool-paths.json') -Encoding UTF8
    $refreshBotGraphScript = Join-Path $root 'scripts\Refresh-BotGraph.ps1'
    function Get-ExtractCallCount {
        @(Get-Content $env:FAKE_GRAPHIFY_LOG | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.arguments[0] -eq 'extract' }).Count
    }

    # Graphify is resolved from the pre-seeded tool-paths.json above, so the real (non-faked) git can stay on PATH for the fingerprint's own git calls.
    $savedIncrementalPath = $env:PATH
    $env:PATH = $originalPath
    try {
        & git -C $incrementalGraphBot init --quiet 2>&1 | Out-Null

        $callsBeforeFirstUpdate = Get-ExtractCallCount
        & $refreshBotGraphScript -TargetBotPath $incrementalGraphBot -Mode Update
        Assert-True ((Get-ExtractCallCount) -eq ($callsBeforeFirstUpdate + 1)) 'First incremental graph refresh did not extract.'
        Assert-True (Test-Path (Join-Path $incrementalGraphBot 'graphify-out\refresh-state.json')) 'Incremental graph refresh did not record a source fingerprint.'

        $callsBeforeReuse = Get-ExtractCallCount
        & $refreshBotGraphScript -TargetBotPath $incrementalGraphBot -Mode Update
        Assert-True ((Get-ExtractCallCount) -eq $callsBeforeReuse) 'Unchanged source triggered an unnecessary Graphify re-extraction.'

        New-Item -ItemType Directory -Force -Path (Join-Path $incrementalGraphBot '.ai\evidence') | Out-Null
        '{"execution":"runtime evidence"}' | Set-Content (Join-Path $incrementalGraphBot '.ai\evidence\execution-state.json') -Encoding UTF8
        $callsBeforeEvidence = Get-ExtractCallCount
        & $refreshBotGraphScript -TargetBotPath $incrementalGraphBot -Mode Update
        Assert-True ((Get-ExtractCallCount) -eq $callsBeforeEvidence) 'Runtime evidence changes invalidated an unchanged Graphify source graph.'

        Add-Content (Join-Path $incrementalGraphBot 'Main.xaml') "`n<!-- changed -->"
        $callsBeforeChange = Get-ExtractCallCount
        & $refreshBotGraphScript -TargetBotPath $incrementalGraphBot -Mode Update
        Assert-True ((Get-ExtractCallCount) -eq ($callsBeforeChange + 1)) 'Changed source did not trigger a Graphify re-extraction.'

        $callsBeforeSecondReuse = Get-ExtractCallCount
        & $refreshBotGraphScript -TargetBotPath $incrementalGraphBot -Mode Update
        Assert-True ((Get-ExtractCallCount) -eq $callsBeforeSecondReuse) 'Unchanged source after a real change still triggered re-extraction.'

        $callsBeforeForce = Get-ExtractCallCount
        & $refreshBotGraphScript -TargetBotPath $incrementalGraphBot -Mode Update -Force
        Assert-True ((Get-ExtractCallCount) -eq ($callsBeforeForce + 1)) '-Force did not bypass fingerprint reuse.'
    } finally {
        $env:PATH = $savedIncrementalPath
    }

    $env:FAKE_UIP_LOG = Join-Path $testRoot 'uip.log'
    $env:FAKE_TEMPLATE_MODE = $null
    $env:FAKE_CREATE_EXIT = $null
    $env:FAKE_PROJECT_MISMATCH = $null
    $env:FAKE_UIP_FAMILY = 'current'
    $processBot = Join-Path $testRoot 'new-process'
    New-Item -ItemType Directory -Force -Path $processBot | Out-Null
    $processToolStateDirectory = Join-Path $processBot '.rpa-ai\local'
    New-Item -ItemType Directory -Force -Path $processToolStateDirectory | Out-Null
    [ordered]@{
        uip = (Join-Path $fakeBin 'uip.cmd')
        graphify = (Join-Path $fakeBin 'graphify.cmd')
    } | ConvertTo-Json | Set-Content (Join-Path $processToolStateDirectory 'tool-paths.json') -Encoding UTF8
    & (Join-Path $root 'scripts\ExecutionState.ps1') -Action Start -TaskType new_bot -TargetBotPath $processBot -Json | Out-Null
    & (Join-Path $root 'scripts\ExecutionState.ps1') -Action StageEnd -Stage coordinator -TargetBotPath $processBot -Json | Out-Null
    & (Join-Path $root 'scripts\New-RpaProject.ps1') -ProjectName 'InvoiceBot' -ProjectType Process -TargetFramework Portable -TargetBotPath $processBot
    $processProject = Get-Content (Join-Path $processBot 'project.json') -Raw | ConvertFrom-Json
    Assert-True ($processProject.targetFramework -eq 'Portable') 'Portable target framework was not passed to current CLI.'
    Assert-True ($processProject.expressionLanguage -eq 'VisualBasic') 'Visual Basic default was not passed to current CLI.'
    $processEvidence = Get-Content (Join-Path $processBot '.ai\evidence\project-scaffold.json') -Raw | ConvertFrom-Json
    Assert-True ($processEvidence.commandFamily -eq 'uip rpa init') 'Current CLI command family was not recorded.'
    Assert-True ($processEvidence.transferHashVerification -eq 'PASS') 'Transferred Process scaffold hashes were not verified.'
    Assert-True (Test-Path (Join-Path $processBot 'Requirements\REQUIREMENTS.md') -PathType Leaf) 'New Process scaffold did not create the Requirements workspace.'
    Assert-True (-not (Test-Path (Join-Path $processBot 'graphify-out\graph.json')) -and -not (Test-Path (Join-Path $processBot 'graphify-out\refresh-state.json'))) 'New Process scaffold performed an unnecessary early Graphify refresh.'
    Assert-True (@(Get-ChildItem $testRoot -Directory -Filter '.rpa-ai-scaffold-*').Count -eq 0) 'Successful Process staging was not removed.'
    Assert-True ((Get-Content $env:FAKE_UIP_LOG -Raw) -match 'rpa\|init') 'Current init command was not invoked.'
    Import-Module (Join-Path $root 'scripts\DeveloperTelemetry.psm1') -Force
    $scaffoldLedger = Read-DeveloperEventLedger -LedgerPath (Join-Path $processBot '.ai\evidence\developer-events.jsonl')
    $scaffoldOperations = @($scaffoldLedger.events.operation)
    Assert-True (-not @($scaffoldLedger.errors).Count -and -not @($scaffoldLedger.events | Where-Object { $_.status -eq 'INCOMPLETE' }).Count) 'Scaffolding telemetry ledger is corrupt or contains incomplete events.'
    foreach ($requiredScaffoldOperation in @('scaffolding.total','scaffolding.template_resolution','scaffolding.directory_creation','scaffolding.blank_template_creation','scaffolding.project_json_creation','scaffolding.main_xaml_initialization','scaffolding.standard_folder_initialization','scaffolding.devkit_activation','scaffolding.transfer','scaffolding.initial_evidence_setup','requirements.folder.check','requirements.folder.create','requirements.template.check','requirements.template.create','requirements.inventory')) {
        Assert-True ($scaffoldOperations -contains $requiredScaffoldOperation) "Scaffolding telemetry is missing '$requiredScaffoldOperation'."
    }

    if ($Full) {
    $env:FAKE_UIP_FAMILY = 'fallback'
    $reframeworkBot = Join-Path $testRoot 'new-reframework'
    New-Item -ItemType Directory -Force -Path $reframeworkBot | Out-Null
    & (Join-Path $root 'scripts\New-RpaProject.ps1') -ProjectName 'QueueBot' -ProjectType REFramework -TargetFramework Windows -TargetBotPath $reframeworkBot
    $reframeworkEvidence = Get-Content (Join-Path $reframeworkBot '.ai\evidence\project-scaffold.json') -Raw | ConvertFrom-Json
    Assert-True ($reframeworkEvidence.commandFamily -eq 'uip rpa create-project') 'Fallback CLI command family was not recorded.'
    Assert-True ($reframeworkEvidence.template.packageId -eq 'UiPath.Template.REFramework') 'Official REFramework package was not selected.'
    Assert-True ($reframeworkEvidence.template.source -eq 'Official') 'REFramework template trust source was not recorded.'
    Assert-True ($reframeworkEvidence.outputType -eq 'Process') 'Generated REFramework output type was not verified.'

    $explicitTemplateBot = Join-Path $testRoot 'explicit-template-bot'
    New-Item -ItemType Directory -Force -Path $explicitTemplateBot | Out-Null
    & (Join-Path $root 'scripts\New-RpaProject.ps1') -ProjectName 'ExplicitBot' -ProjectType REFramework -TargetFramework Windows -TemplatePackageId 'UiPath.Template.REFramework' -TemplatePackageVersion '1.2.3' -TargetBotPath $explicitTemplateBot
    Assert-True (Test-Path (Join-Path $explicitTemplateBot 'project.json')) 'Verified explicit Official template was not created.'

    $untrustedTemplateBot = Join-Path $testRoot 'untrusted-template-bot'
    New-Item -ItemType Directory -Force -Path $untrustedTemplateBot | Out-Null
    $untrustedBlocked = $false
    try {
        & (Join-Path $root 'scripts\New-RpaProject.ps1') -ProjectName 'UntrustedBot' -ProjectType REFramework -TargetFramework Windows -TemplatePackageId 'Marketplace.REFramework' -TemplatePackageVersion '9.9.9' -TargetBotPath $untrustedTemplateBot
    } catch {
        $untrustedBlocked = $_.Exception.Message -match 'No Official'
    }
    Assert-True $untrustedBlocked 'Explicit untrusted template package bypassed Official verification.'

    $env:FAKE_TEMPLATE_MODE = 'noofficial'
    $noOfficialBot = Join-Path $testRoot 'no-official-bot'
    New-Item -ItemType Directory -Force -Path $noOfficialBot | Out-Null
    $noOfficialBlocked = $false
    try {
        & (Join-Path $root 'scripts\New-RpaProject.ps1') -ProjectName 'NoOfficialBot' -ProjectType REFramework -TargetFramework Windows -TargetBotPath $noOfficialBot
    } catch {
        $noOfficialBlocked = $_.Exception.Message -match 'No Official'
    }
    Assert-True $noOfficialBlocked 'Marketplace-only template results were not blocked.'
    $env:FAKE_TEMPLATE_MODE = $null

    $env:FAKE_CREATE_EXIT = '7'
    $partialBot = Join-Path $testRoot 'partial-success-bot'
    New-Item -ItemType Directory -Force -Path $partialBot | Out-Null
    & (Join-Path $root 'scripts\New-RpaProject.ps1') -ProjectName 'PartialBot' -ProjectType Process -TargetFramework Windows -TargetBotPath $partialBot 6>$null
    $partialEvidence = Get-Content (Join-Path $partialBot '.ai\evidence\project-scaffold.json') -Raw | ConvertFrom-Json
    Assert-True ($partialEvidence.cliExitCode -eq 7 -and $partialEvidence.partialSuccessAccepted) 'Verified partial-success evidence was not recorded.'
    $env:FAKE_CREATE_EXIT = $null

    $env:FAKE_CREATE_EXIT = '8'
    $unsupportedExitBot = Join-Path $testRoot 'unsupported-exit-bot'
    New-Item -ItemType Directory -Force -Path $unsupportedExitBot | Out-Null
    $unsupportedExitBlocked = $false
    try {
        & (Join-Path $root 'scripts\New-RpaProject.ps1') -ProjectName 'UnsupportedExitBot' -ProjectType Process -TargetFramework Windows -TargetBotPath $unsupportedExitBot
    } catch {
        $unsupportedExitBlocked = $_.Exception.Message -match 'unsupported exit code 8'
    }
    $env:FAKE_CREATE_EXIT = $null
    Assert-True $unsupportedExitBlocked 'Unsupported nonzero UiPath CLI exit was not rejected.'
    Assert-True (-not (Test-Path (Join-Path $unsupportedExitBot 'project.json'))) 'Unsupported CLI exit transferred project files.'
    Assert-True (-not (Test-Path (Join-Path $unsupportedExitBot '.ai\evidence\project-scaffold.json'))) 'Unsupported CLI exit created scaffold evidence.'

    $env:FAKE_PROJECT_MISMATCH = 'framework'
    $mismatchBot = Join-Path $testRoot 'semantic-mismatch-bot'
    New-Item -ItemType Directory -Force -Path $mismatchBot | Out-Null
    $mismatchBlocked = $false
    try {
        & (Join-Path $root 'scripts\New-RpaProject.ps1') -ProjectName 'MismatchBot' -ProjectType Process -TargetFramework Portable -TargetBotPath $mismatchBot
    } catch {
        $mismatchBlocked = $_.Exception.Message -match 'does not match'
    }
    Assert-True $mismatchBlocked 'Generated semantic mismatch was not rejected.'
    Assert-True (-not (Test-Path (Join-Path $mismatchBot 'project.json'))) 'Semantic mismatch transferred project files.'
    $env:FAKE_PROJECT_MISMATCH = $null

    $evidenceFailureBot = Join-Path $testRoot 'evidence-failure-bot'
    New-Item -ItemType Directory -Force -Path (Join-Path $evidenceFailureBot '.ai') | Out-Null
    'blocks evidence directory' | Set-Content (Join-Path $evidenceFailureBot '.ai\evidence')
    $scaffoldRollback = $false
    try {
        & (Join-Path $root 'scripts\New-RpaProject.ps1') -ProjectName 'RollbackBot' -ProjectType Process -TargetFramework Windows -TargetBotPath $evidenceFailureBot
    } catch {
        $scaffoldRollback = $_.Exception.Message -match 'rolled back'
    }
    Assert-True $scaffoldRollback 'Scaffold evidence failure did not trigger rollback.'
    Assert-True (-not (Test-Path (Join-Path $evidenceFailureBot 'project.json'))) 'Scaffold rollback left project.json in the bot root.'
    Assert-True (-not (Test-Path (Join-Path $evidenceFailureBot 'Main.xaml'))) 'Scaffold rollback left Main.xaml in the bot root.'
    Assert-True ((Get-Content (Join-Path $evidenceFailureBot '.ai\evidence') -Raw).Trim() -eq 'blocks evidence directory') 'Scaffold rollback altered the pre-existing evidence blocker.'

    $existingEvidenceBot = Join-Path $testRoot 'existing-evidence-bot'
    New-Item -ItemType Directory -Force -Path (Join-Path $existingEvidenceBot '.ai\evidence') | Out-Null
    'bot-owned evidence' | Set-Content (Join-Path $existingEvidenceBot '.ai\evidence\project-scaffold.json')
    $evidenceCollisionBlocked = $false
    try {
        & (Join-Path $root 'scripts\New-RpaProject.ps1') -ProjectName 'EvidenceCollisionBot' -ProjectType Process -TargetFramework Windows -TargetBotPath $existingEvidenceBot
    } catch {
        $evidenceCollisionBlocked = $_.Exception.Message -match 'bot-owned'
    }
    Assert-True $evidenceCollisionBlocked 'Existing scaffold evidence did not block overwrite.'
    Assert-True ((Get-Content (Join-Path $existingEvidenceBot '.ai\evidence\project-scaffold.json') -Raw).Trim() -eq 'bot-owned evidence') 'Existing scaffold evidence was modified.'
    Assert-True (-not (Test-Path (Join-Path $existingEvidenceBot 'project.json'))) 'Evidence collision transferred scaffold files.'

    $collisionBot = Join-Path $testRoot 'collision-bot'
    New-Item -ItemType Directory -Force -Path $collisionBot | Out-Null
    'existing workflow' | Set-Content (Join-Path $collisionBot 'Main.xaml')
    $collisionBlocked = $false
    try {
        & (Join-Path $root 'scripts\New-RpaProject.ps1') -ProjectName 'CollisionBot' -ProjectType Process -TargetFramework Windows -TargetBotPath $collisionBot
    } catch {
        $collisionBlocked = $_.Exception.Message -match 'collide'
    }
    Assert-True $collisionBlocked 'Existing bot-root files did not block scaffold transfer.'
    Assert-True ((Get-Content (Join-Path $collisionBot 'Main.xaml') -Raw).Trim() -eq 'existing workflow') 'Scaffold collision overwrote an existing file.'

    $env:FAKE_TEMPLATE_MODE = 'multiple'
    $ambiguousBot = Join-Path $testRoot 'ambiguous-template-bot'
    New-Item -ItemType Directory -Force -Path $ambiguousBot | Out-Null
    $ambiguousBlocked = $false
    try {
        & (Join-Path $root 'scripts\New-RpaProject.ps1') -ProjectName 'AmbiguousBot' -ProjectType REFramework -TargetFramework Windows -TargetBotPath $ambiguousBot
    } catch {
        $ambiguousBlocked = $_.Exception.Message -match 'Multiple Official'
    }
    Assert-True $ambiguousBlocked 'Multiple Official REFramework templates did not require an explicit choice.'

    $log = Get-Content $env:FAKE_UIP_LOG -Raw
    Assert-True ($log -match 'rpa\|init') 'Current init command was not invoked.'
    Assert-True ($log -match 'rpa\|search-templates') 'Fallback template search command was not invoked.'
    Assert-True ($log -match '--target-framework\|Windows') 'Explicit Windows framework was not passed.'
    Assert-True ($log -match '--expression-language\|VisualBasic') 'Explicit expression language was not passed.'
    }

    Write-Host '[PASS] Dev Kit deterministic tests'
}
finally {
    if ($originalPath) { $env:PATH = $originalPath }
    if ($originalLocalAppData) { $env:LOCALAPPDATA = $originalLocalAppData }
    if ($originalUserProfile) { $env:USERPROFILE = $originalUserProfile }
    $env:FAKE_GRAPHIFY_LOG = $null
    $env:OPENAI_API_KEY = $null
    $env:AWS_ACCESS_KEY_ID = $null
    $env:FAKE_UIP_FAMILY = $null
    $env:FAKE_UIP_LOG = $null
    $env:FAKE_DEVKIT_SOURCE_ROOT = $null
    $env:FAKE_TEMPLATE_MODE = $null
    $env:FAKE_CREATE_EXIT = $null
    $env:FAKE_PROJECT_MISMATCH = $null
    $env:FAKE_UIP_FAIL_HELP = $null
    $env:FAKE_DEVKIT_UPDATE_MARKER = $null
    $env:FAKE_GIT_FAIL_TAGS = $null
    $env:FAKE_GIT_NO_VALID_TAGS = $null
    Remove-Item $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
