[CmdletBinding()]
param(
    [string]$TargetBotPath = (Get-Location).Path,
    [switch]$CheckGraphify
)

$ErrorActionPreference = 'Continue'
$TargetBotPath = (Resolve-Path $TargetBotPath).Path
$fail = $false
$resolverScript = Join-Path $TargetBotPath '.rpa-ai\scripts\Resolve-DevKitTool.ps1'
if (-not (Test-Path $resolverScript -PathType Leaf)) { throw "Tool resolver is missing: $resolverScript" }
. $resolverScript

function Write-Check {
    param([string]$Name, [bool]$Passed, [string]$Detail)

    $status = if ($Passed) { 'PASS' } else { 'FAIL' }
    Write-Host "[$status] $Name - $Detail"
    if (-not $Passed) { $script:fail = $true }
}

Write-Host "RPA AI Dev Kit diagnostics"
Write-Host "Bot path: $TargetBotPath"
Write-Host "PowerShell: $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
Write-Host "OS: $([Environment]::OSVersion.VersionString)"

Write-Check 'PowerShell runtime' ($PSVersionTable.PSVersion -ge [version]'5.1') '5.1 or later required'
$gitCommand = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
Write-Check 'git command' ($null -ne $gitCommand) $(if ($gitCommand) { $gitCommand.Source } else { 'not found on PATH' })
foreach ($commandName in @('uip')) {
    $commandPath = Resolve-DevKitTool -Name $commandName -TargetBotPath $TargetBotPath
    Write-Check "$commandName command" ([bool]$commandPath) $(if ($commandPath) { $commandPath } else { 'not found in PATH or the current user profile' })
}

$graphifyCommand = Resolve-DevKitTool -Name graphify -TargetBotPath $TargetBotPath
Write-Host $(if ($graphifyCommand) { '[INFO] Graphify available on demand.' } else { '[INFO] Graphify not installed (optional).' })

$manifestPath = Join-Path $TargetBotPath '.rpa-ai\kit-manifest.json'
if (Test-Path $manifestPath -PathType Leaf) {
    try {
        $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
        Write-Check 'Installed manifest' ($manifest.schemaVersion -eq 1 -and [bool]$manifest.kitVersion) "kit $($manifest.kitVersion), schema $($manifest.schemaVersion)"
    } catch {
        Write-Check 'Installed manifest' $false 'invalid JSON'
    }
} else {
    Write-Check 'Installed manifest' $false $manifestPath
}

$projectPath = Join-Path $TargetBotPath 'project.json'
if (Test-Path $projectPath -PathType Leaf) {
    try {
        $project = Get-Content $projectPath -Raw | ConvertFrom-Json
        Write-Check 'UiPath project' ([bool]$project.name -and [bool]$project.main) "name '$($project.name)', main '$($project.main)'"
    } catch {
        Write-Check 'UiPath project' $false 'project.json is invalid JSON'
    }
} else {
    Write-Host '[INFO] UiPath project - project.json is absent; this is valid before new-bot scaffolding.'
}

$requiredCustomizations = @(
    '.github\agents\rpa-coordinator.agent.md',
    '.github\agents\rpa-developer.agent.md',
    '.github\agents\rpa-auditor.agent.md',
    '.github\agents\rpa-documentation.agent.md',
    '.github\skills\rpa-standards\SKILL.md'
)
$missingCustomizations = @($requiredCustomizations | Where-Object { -not (Test-Path (Join-Path $TargetBotPath $_) -PathType Leaf) })
Write-Check 'Copilot customizations' ($missingCustomizations.Count -eq 0) $(if ($missingCustomizations.Count -eq 0) { 'required agent and skill files found' } else { "missing: $($missingCustomizations -join ', ')" })

$requiredDocumentation = @('README.md', 'docs\Bot-Documentation.md', 'docs\Testing.md', 'docs\CHANGELOG.md')
$missingDocumentation = @($requiredDocumentation | Where-Object { -not (Test-Path (Join-Path $TargetBotPath $_) -PathType Leaf) })
Write-Check 'Bot documentation structure' ($missingDocumentation.Count -eq 0) $(if ($missingDocumentation.Count -eq 0) { 'standard README and docs files found' } else { "missing: $($missingDocumentation -join ', ')" })

$outlookScript = Join-Path $TargetBotPath '.rpa-ai\scripts\Test-OutlookCapability.ps1'
if (Test-Path $outlookScript -PathType Leaf) {
    try {
        $outlookResult = & $outlookScript -TargetBotPath $TargetBotPath -Json | ConvertFrom-Json
        if ($outlookResult.OUTLOOK_ACTIVITY_AVAILABLE) {
            Write-Host '[PASS] Outlook activities - package and default Inbox capability verified'
        } else {
            Write-Host "[INFO] Outlook activities - unavailable for this machine/user: $($outlookResult.reason)"
        }
    } catch {
        Write-Host "[INFO] Outlook activities - capability check could not run: $($_.Exception.Message)"
    }
} else {
    Write-Host "[INFO] Outlook activities - capability script is not installed: $outlookScript"
}

$integrityScript = Join-Path $TargetBotPath '.rpa-ai\scripts\Test-ManagedFileIntegrity.ps1'
if (Test-Path $integrityScript -PathType Leaf) {
    try {
        & $integrityScript -TargetBotPath $TargetBotPath
    } catch {
        Write-Check 'Managed-file integrity' $false $_.Exception.Message
    }
} else {
    Write-Check 'Managed-file integrity script' $false $integrityScript
}

$refreshScript = Join-Path $TargetBotPath '.rpa-ai\scripts\Refresh-BotGraph.ps1'
$projectExists = Test-Path (Join-Path $TargetBotPath 'project.json') -PathType Leaf
if (-not $CheckGraphify) {
    Write-Host '[INFO] Optional Graphify check skipped (on-demand).'
} elseif (-not $projectExists) {
    Write-Host '[INFO] Bot-local graph - deferred until official new-bot scaffolding creates project.json.'
} elseif (-not $graphifyCommand -or -not (Test-Path (Join-Path $TargetBotPath 'graphify-out\graph.json') -PathType Leaf)) {
    Write-Host '[INFO] Bot-local graph - absent; Project Mapper is the default. Run Activate-RpaAiDevKit.ps1 -EnableGraphify when a graph is needed.'
} elseif (Test-Path $refreshScript -PathType Leaf) {
    try {
        & $refreshScript -TargetBotPath $TargetBotPath -Mode Status
    } catch {
        Write-Host "[WARN] Optional bot-local Graphify status unavailable: $($_.Exception.Message)"
    }
} else {
    Write-Host '[INFO] Optional graph refresh script is missing.'
}

if ($fail) {
    Write-Host '[FAIL] Dev Kit diagnostics found one or more required readiness problems.'
    exit 1
}

Write-Host '[PASS] Dev Kit diagnostics complete.'
