[CmdletBinding()]
param(
    [string]$ProjectPath = (Get-Location).Path,
    [string]$GovernanceFilePath,
    [switch]$RunDiagnostics,
    [string]$RunFile,
    [string]$InputArgumentsJson,
    [int]$TimeoutSeconds = 300,
    [string]$DependencyStatePath,
    [string]$ValidationSummaryPath,
    [string]$PreviousValidationSummaryPath,
    [string]$ExecutionStatePath,
    [bool]$ReuseDependencyState = $true,
    [switch]$ForceDependencyRestore,
    [switch]$ReuseManagedIntegrity,
    [switch]$OutputQaRequired,
    [switch]$OutputQaComplete,
    [switch]$SkipDiagnostics,
    [ValidateSet('R0','R1','R2','R3','UNKNOWN')]
    [string]$RiskClassification = 'UNKNOWN',
    [string]$ChangeFactsJson,
    [string[]]$ChangedWorkflow = @(),
    [ValidateSet('New','Existing')][string]$ProjectKind = 'Existing',
    [string]$ParentEventId = ''
)

$ErrorActionPreference = 'Stop'
$validationStartedAt = [DateTime]::UtcNow
$ProjectPath = (Resolve-Path $ProjectPath).Path
$projectJson = Join-Path $ProjectPath 'project.json'
$evidenceDir = Join-Path $ProjectPath '.ai\evidence'
New-Item -ItemType Directory -Force -Path $evidenceDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $evidenceDir "validation-$stamp.log"
$DependencyStatePath = if ($DependencyStatePath) { $DependencyStatePath } else { Join-Path $evidenceDir 'dependency-state.json' }
$ValidationSummaryPath = if ($ValidationSummaryPath) { $ValidationSummaryPath } else { Join-Path $evidenceDir "validation-$stamp.json" }
$ExecutionStatePath = if ($ExecutionStatePath) { $ExecutionStatePath } else { Join-Path $evidenceDir 'execution-state.json' }
$executionStateScript = Join-Path $PSScriptRoot 'ExecutionState.ps1'
$summary = [ordered]@{
    project_json = [ordered]@{ status = 'NOT_RUN' }
    source = [ordered]@{ fingerprint = $null; capturedAtUtc = $null }
    source_fresh = $true
    environment = [ordered]@{ cliVersion = $null; governanceFingerprint = $null; compatibility = $null; fingerprint = $null }
    package_compatibility = [ordered]@{ status = 'NOT_RUN' }
    xaml_sanity = [ordered]@{ status = 'NOT_RUN' }
    enum_property_compatibility = [ordered]@{ status = 'NOT_RUN' }
    dependency_restore = [ordered]@{ status = 'NOT_RUN'; reused = $false; dependencyFingerprint = $null; sourceFingerprint = $null }
    build = [ordered]@{ status = 'NOT_RUN' }
    analyzer = [ordered]@{ status = 'NOT_RUN' }
    get_errors = [ordered]@{ status = 'NOT_RUN' }
    workflow_validate = [ordered]@{ status = 'NOT_RUN'; required = $true }
    toolchain = [ordered]@{ status = 'NOT_RUN' }
    diagnostics = [ordered]@{ status = 'NOT_RUN' }
    diagnostics_decision = [ordered]@{
        riskClassification = $RiskClassification
        diagnosticsRequired = $true
        diagnosticsExecuted = $false
        diagnosticsDecisionReason = 'Decision pending structural validation.'
        relevantChangeFacts = $null
        diagnosticsDurationSeconds = $null
    }
    tests = [ordered]@{ status = 'NOT_RUN' }
    integrity = [ordered]@{ status = 'NOT_RUN' }
    output_qa = if ($OutputQaRequired) { [ordered]@{ status = if ($OutputQaComplete) { 'PASS' } else { 'REQUIRED' } } } else { [ordered]@{ status = 'NOT_APPLICABLE' } }
    delivery = [ordered]@{ validationRequired=$true; validationCompleted=$false; buildRequired=$true; buildExecuted=$false; buildSucceeded=$false; deliveryReady=$false; blockedReason=$null }
    timings = [ordered]@{
        validationTotal = 0
        projectJson = 0
        validationStageStart = 0
        toolResolution = 0
        manifestLookup = 0
        integrityLookup = 0
        sourceFingerprint = 0
        previousEvidenceLookup = 0
        xamlSanity = 0
        enumPropertyCompatibility = 0
        environmentCompatibility = 0
        cliVersion = 0
        diagnosticsDecision = 0
        diagnostics = 0
        diagnosticsCommand = 0
        dependencyStateLookup = 0
        restore = 0
        restoreCommand = 0
        postRestoreFingerprint = 0
        build = 0
        buildCommand = 0
        analyzer = 0
        analyzerCommand = 0
        functionalTest = 0
        functionalTestCommand = 0
        finalSourceFingerprint = 0
        evidencePreparation = 0
        validationStageEnd = 0
        cleanup = 0
        unexplainedResidual = 0
    }
}

function Add-Timing {
    param([string]$Name, [DateTime]$StartedAt)
    $elapsed = [Math]::Round(([DateTime]::UtcNow - $StartedAt).TotalSeconds, 3)
    if ($summary.timings.Contains($Name)) { $summary.timings[$Name] = [Math]::Round(([double]$summary.timings[$Name] + $elapsed), 3) }
    return $elapsed
}
function Update-ValidationTimingTotals {
    $summary.timings.validationTotal = [Math]::Round(([DateTime]::UtcNow - $validationStartedAt).TotalSeconds, 3)
    $accountedKeys = @('projectJson','validationStageStart','toolResolution','manifestLookup','integrityLookup','sourceFingerprint','previousEvidenceLookup','xamlSanity','enumPropertyCompatibility','environmentCompatibility','cliVersion','diagnosticsDecision','diagnostics','dependencyStateLookup','restore','postRestoreFingerprint','build','analyzer','functionalTest','finalSourceFingerprint','validationStageEnd','cleanup')
    $accounted = 0.0
    foreach ($key in $accountedKeys) { $accounted += [double]$summary.timings[$key] }
    $summary.timings.unexplainedResidual = [Math]::Max(0, [Math]::Round(([double]$summary.timings.validationTotal - $accounted), 3))
}
function Update-DeliveryState {
    $diagnosticsRequired=[bool]$summary.diagnostics_decision.diagnosticsRequired
    $diagnosticsComplete=(-not $diagnosticsRequired) -or ([string]$summary.get_errors.status -in @('PASS','REUSED'))
    $buildStatus=[string]$summary.build.status
    $summary.delivery.validationRequired=$true
    $summary.delivery.buildRequired=$true
    $summary.delivery.buildExecuted=$buildStatus -in @('PASS','REUSED','FAIL','BLOCKED','TIMEOUT')
    $summary.delivery.buildSucceeded=$buildStatus -in @('PASS','REUSED')
    $nativeComplete=[string]$summary.workflow_validate.status -in @('PASS','REUSED')
    $otherComplete=[string]$summary.toolchain.status -eq 'PASS' -and [string]$summary.dependency_restore.status -in @('PASS','REUSED') -and [string]$summary.package_compatibility.status -eq 'PASS' -and [string]$summary.integrity.status -in @('PASS','REUSED') -and [string]$summary.analyzer.status -in @('PASS','REUSED','NOT_APPLICABLE') -and ((-not $RunFile) -or [string]$summary.tests.status -eq 'PASS')
    $summary.delivery.validationCompleted=$diagnosticsComplete -and $nativeComplete -and $otherComplete -and $summary.delivery.buildSucceeded -and [string]$summary.xaml_sanity.status -eq 'PASS' -and [string]$summary.enum_property_compatibility.status -in @('PASS','NOT_APPLICABLE')
    $summary.delivery.validationCompleted=[bool]$summary.delivery.validationCompleted -and [bool]$summary.source_fresh
    $summary.delivery.deliveryReady=[bool]$summary.delivery.validationCompleted -and [string]$summary.output_qa.status -in @('PASS','NOT_APPLICABLE')
    if(-not $summary.delivery.deliveryReady -and -not $summary.delivery.blockedReason){
        if($buildStatus -eq 'NOT_RUN'){$summary.delivery.blockedReason='REQUIRED_BUILD_NOT_EXECUTED'}
        elseif($buildStatus -notin @('PASS','REUSED')){$summary.delivery.blockedReason='PROJECT_BUILD_FAILED_OR_BLOCKED'}
        elseif(-not $diagnosticsComplete){$summary.delivery.blockedReason='REQUIRED_NATIVE_DIAGNOSTICS_INCOMPLETE'}
        else{$summary.delivery.blockedReason='VALIDATION_INCOMPLETE'}
    }
    if($summary.delivery.deliveryReady){$summary.delivery.blockedReason=$null}
}
function Sync-ExecutionValidationState {
    if(-not(Test-Path -LiteralPath $ExecutionStatePath -PathType Leaf)){return}
    Update-DeliveryState
    $compact=[ordered]@{validationRequired=[bool]$summary.delivery.validationRequired;validationCompleted=[bool]$summary.delivery.validationCompleted;diagnosticsExecuted=[bool]$summary.diagnostics_decision.diagnosticsExecuted;buildExecuted=[bool]$summary.delivery.buildExecuted;buildSucceeded=[bool]$summary.delivery.buildSucceeded;deliveryReady=[bool]$summary.delivery.deliveryReady;blockedReason=[string]$summary.delivery.blockedReason;validationResultPath=$ValidationSummaryPath}
    & $executionStateScript -Action ValidationState -TargetBotPath $ProjectPath -StatePath $ExecutionStatePath -ValidationStateJson ($compact|ConvertTo-Json -Compress) -Json|Out-Null
}
function Get-PreviousValidationSummary {
    if ($PreviousValidationSummaryPath -and (Test-Path $PreviousValidationSummaryPath -PathType Leaf)) {
        try { return (Get-Content $PreviousValidationSummaryPath -Raw | ConvertFrom-Json) } catch { return $null }
    }
    $currentName = Split-Path $ValidationSummaryPath -Leaf
    $candidate = Get-ChildItem -LiteralPath $evidenceDir -Filter 'validation-*.json' -File -Force -ErrorAction SilentlyContinue |
        Where-Object Name -ne $currentName | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if ($candidate) { try { return (Get-Content $candidate.FullName -Raw | ConvertFrom-Json) } catch { } }
    return $null
}
function Write-EarlyValidationSummary {
    $writeStarted = [DateTime]::UtcNow
    Update-DeliveryState
    Update-ValidationTimingTotals
    $summary | ConvertTo-Json -Depth 8 | Set-Content $ValidationSummaryPath -Encoding UTF8
    Add-Timing 'evidencePreparation' $writeStarted | Out-Null
}
$executionStageStarted = $false

if (-not (Test-Path $projectJson)) {
    $summary.project_json = [ordered]@{ status = 'FAIL'; reason = 'project.json not found.' }
    Write-EarlyValidationSummary
    throw "project.json not found in $ProjectPath"
}

# Gate 1: JSON sanity
$phaseStarted = [DateTime]::UtcNow
try {
    Get-Content $projectJson -Raw | ConvertFrom-Json | Out-Null
    $summary.project_json = [ordered]@{ status = 'PASS'; capturedAtUtc = [DateTime]::UtcNow.ToString('o') }
    Write-Host "[PASS] project.json parses"
} catch {
    $summary.project_json = [ordered]@{ status = 'FAIL'; reason = $_.Exception.Message; capturedAtUtc = [DateTime]::UtcNow.ToString('o') }
    Write-EarlyValidationSummary
    Write-Host "[FAIL] project.json parse"
    throw
}
finally { Add-Timing 'projectJson' $phaseStarted | Out-Null }

if ((Test-Path $executionStateScript -PathType Leaf) -and (Test-Path $ExecutionStatePath -PathType Leaf)) {
    $phaseStarted = [DateTime]::UtcNow
    try {
        & $executionStateScript -Action StageStart -Stage validation -TargetBotPath $ProjectPath -StatePath $ExecutionStatePath | Out-Null
        $executionStageStarted = $true
    } catch {
        $summary.integrity = [ordered]@{ status = 'BLOCKED'; reason = "Unable to start validation timing: $($_.Exception.Message)" }
        Write-EarlyValidationSummary
        throw
    }
    finally { Add-Timing 'validationStageStart' $phaseStarted | Out-Null }
}

$resolverScript = Join-Path $PSScriptRoot 'Resolve-DevKitTool.ps1'
if (-not (Test-Path $resolverScript -PathType Leaf)) {
    $summary.integrity = [ordered]@{ status = 'BLOCKED'; reason = "Tool resolver is missing: $resolverScript" }
    Write-EarlyValidationSummary
    if ($executionStageStarted) { & $executionStateScript -Action StageEnd -Stage validation -TargetBotPath $ProjectPath -StatePath $ExecutionStatePath | Out-Null; $executionStageStarted = $false }
    throw "Tool resolver is missing: $resolverScript"
}
try {
    $phaseStarted = [DateTime]::UtcNow
    . $resolverScript
    $uipCommand = Resolve-DevKitTool -Name uip -TargetBotPath $ProjectPath -Required
} catch {
    $summary.integrity = [ordered]@{ status = 'BLOCKED'; reason = $_.Exception.Message }
    Write-EarlyValidationSummary
    if ($executionStageStarted) { & $executionStateScript -Action StageEnd -Stage validation -TargetBotPath $ProjectPath -StatePath $ExecutionStatePath | Out-Null; $executionStageStarted = $false }
    throw
}
finally { if ($phaseStarted) { Add-Timing 'toolResolution' $phaseStarted | Out-Null } }

$dependencyStateScript = Join-Path $PSScriptRoot 'Get-DependencyState.ps1'
$fingerprintScript = Join-Path $PSScriptRoot 'SourceFingerprint.ps1'
$commandScript = Join-Path $PSScriptRoot 'Invoke-DevKitCommand.ps1'
$diagnosticsDecisionScript = Join-Path $PSScriptRoot 'Get-DiagnosticsDecision.ps1'
$compatibilityScript = Join-Path $PSScriptRoot 'Get-UiPathEnvironmentCompatibility.ps1'
$xamlCompatibilityScript = Join-Path $PSScriptRoot 'Test-UiPathXamlCompatibility.ps1'
$nativeDiagnosticsScript = Join-Path $PSScriptRoot 'Invoke-UiPathNativeDiagnostics.ps1'
$diagnosticsParserScript = Join-Path $PSScriptRoot 'ConvertFrom-UiPathDiagnostics.ps1'
foreach ($requiredHelper in @($fingerprintScript,$commandScript,$diagnosticsDecisionScript,$compatibilityScript,$xamlCompatibilityScript,$nativeDiagnosticsScript)) {
    if (-not (Test-Path $requiredHelper -PathType Leaf)) {
        $summary.integrity = [ordered]@{ status = 'FAIL'; reason = "Validation helper is missing: $requiredHelper" }
        Write-EarlyValidationSummary
        if ($executionStageStarted) { & $executionStateScript -Action StageEnd -Stage validation -TargetBotPath $ProjectPath -StatePath $ExecutionStatePath | Out-Null; $executionStageStarted = $false }
        throw "Validation helper is missing: $requiredHelper"
    }
}
try {
    $phaseStarted = [DateTime]::UtcNow
    $uipVersionResult = & $commandScript -FilePath $uipCommand -ArgumentList @('--version') -WorkingDirectory $ProjectPath -TargetBotPath $ProjectPath -ExecutionStatePath $ExecutionStatePath -Operation 'UiPath CLI version check' -Category PACKAGE -Subcategory 'cli.version' -ParentEventId $ParentEventId -TimeoutSeconds 60 -Json | ConvertFrom-Json
} catch {
    $summary.integrity = [ordered]@{ status = 'BLOCKED'; reason = $_.Exception.Message }
    Write-EarlyValidationSummary
    if ($executionStageStarted) { & $executionStateScript -Action StageEnd -Stage validation -TargetBotPath $ProjectPath -StatePath $ExecutionStatePath | Out-Null; $executionStageStarted = $false }
    throw
}
finally { if ($phaseStarted) { Add-Timing 'cliVersion' $phaseStarted | Out-Null } }
$uipVersionOutput = [string]$uipVersionResult.output
$uipVersion = if ($uipVersionResult.status -eq 'PASS' -and $uipVersionOutput) { $uipVersionOutput.Trim() } else { 'UNKNOWN' }
if ($uipVersionResult.status -ne 'PASS') {
    $summary.integrity = [ordered]@{ status = 'BLOCKED'; reason = "UiPath CLI version check ended with $($uipVersionResult.status)."; command = $uipVersionResult }
    Write-EarlyValidationSummary
    if ($executionStageStarted) { & $executionStateScript -Action StageEnd -Stage validation -TargetBotPath $ProjectPath -StatePath $ExecutionStatePath | Out-Null; $executionStageStarted = $false }
    throw "UiPath CLI version check ended with $($uipVersionResult.status)."
}
$governanceFingerprint = if ($GovernanceFilePath) { (Get-FileHash (Resolve-Path $GovernanceFilePath).Path -Algorithm SHA256).Hash.ToLowerInvariant() } else { 'NONE' }
$phaseStarted = [DateTime]::UtcNow
$requiredCapabilities=@()
$validateTargets=@($ChangedWorkflow)
if(-not $validateTargets.Count){$validateTargets=@(Get-ChildItem -LiteralPath $ProjectPath -Recurse -File -Include '*.xaml','*.cs' | Where-Object {$_.FullName -notmatch '[\\/](\.ai|\.rpa-ai|\.local|graphify-out|packages|bin|obj|node_modules)[\\/]'} | ForEach-Object {$_.FullName})}
foreach($workflow in $validateTargets){
    $path=if([IO.Path]::IsPathRooted($workflow)){$workflow}else{Join-Path $ProjectPath $workflow}
    if((Test-Path -LiteralPath $path -PathType Leaf) -and [IO.File]::ReadAllText($path) -match 'UiPath\.UIAutomation|uiAutomation\.|<\w+:N(ApplicationCard|Click|TypeInto|GetText|CheckState|SelectItem)\b'){
        $requiredCapabilities=@('ui.authoring');break
    }
}
$compatibility = & $compatibilityScript -ProjectPath $ProjectPath -ProjectKind $ProjectKind -CliVersion $uipVersion -CliPath $uipCommand -RequiredCapability $requiredCapabilities -Json | ConvertFrom-Json
Add-Timing 'environmentCompatibility' $phaseStarted | Out-Null
$summary.environment = [ordered]@{ cliVersion = $uipVersion; governanceFingerprint = $governanceFingerprint; compatibility = $compatibility; fingerprint = [string]$compatibility.environmentFingerprint }
$summary.package_compatibility = [ordered]@{ status=if([string]$compatibility.compatibilityDecision -in @('INCOMPATIBLE_RELEASE_TRAIN','INCOMPATIBLE_STUDIO_MINIMUM')){'BLOCKED'}else{'PASS'}; decision=[string]$compatibility.compatibilityDecision; reason=[string]$compatibility.compatibilityReason; selectedUiAutomationVersion=[string]$compatibility.selectedUiAutomationVersion; automaticPackageUpgrade=[bool]$compatibility.automaticPackageUpgrade; evidence=$compatibility.compatibilityEvidence }
$summary.toolchain=[ordered]@{status=[string]$compatibility.toolchainEvidence.requiredEvidence.status;evidence=$compatibility.toolchainEvidence}
function Get-CurrentSourceEvidence {
    $snapshot = & $fingerprintScript -ProjectPath $ProjectPath -Json | ConvertFrom-Json
    [ordered]@{
        schemaVersion = [int]$snapshot.schemaVersion
        fingerprint = [string]$snapshot.sourceFingerprint
        executableFingerprint = [string]$snapshot.executableFingerprint
        documentationFingerprint = [string]$snapshot.documentationFingerprint
        graphConfigFingerprint = [string]$snapshot.graphConfigFingerprint
        cacheStatus = [string]$snapshot.cacheStatus
        capturedAtUtc = [string]$snapshot.capturedAtUtc
    }
}

try {
    $phaseStarted = [DateTime]::UtcNow
    $summary.source = Get-CurrentSourceEvidence
    $script:currentSourceEvidence = $summary.source
    Add-Timing 'sourceFingerprint' $phaseStarted | Out-Null
    $phaseStarted = [DateTime]::UtcNow
    $previousSummary = Get-PreviousValidationSummary
    Add-Timing 'previousEvidenceLookup' $phaseStarted | Out-Null
    $canReuseExecutableGates = $previousSummary -and
        [string]$previousSummary.source.executableFingerprint -eq [string]$summary.source.executableFingerprint -and
        [string]$previousSummary.source.schemaVersion -eq [string]$summary.source.schemaVersion -and
        [string]$previousSummary.environment.cliVersion -eq [string]$summary.environment.cliVersion -and
        [string]$previousSummary.environment.fingerprint -eq [string]$summary.environment.fingerprint -and
        [string]$previousSummary.environment.governanceFingerprint -eq [string]$summary.environment.governanceFingerprint -and
        [string]$previousSummary.validationPolicyFingerprint -eq ((Get-FileHash -LiteralPath $diagnosticsParserScript -Algorithm SHA256).Hash+'|'+(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash)
    $summary.validationPolicyFingerprint=(Get-FileHash -LiteralPath $diagnosticsParserScript -Algorithm SHA256).Hash+'|'+(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
} catch {
    $summary.source = [ordered]@{ status = 'FAIL'; reason = $_.Exception.Message; capturedAtUtc = [DateTime]::UtcNow.ToString('o') }
    Write-EarlyValidationSummary
    if ($executionStageStarted) {
        & $executionStateScript -Action StageEnd -Stage validation -TargetBotPath $ProjectPath -StatePath $ExecutionStatePath | Out-Null
        $executionStageStarted = $false
    }
    throw
}

function Write-ValidationSummary {
    $writeStarted = [DateTime]::UtcNow
    New-Item -ItemType Directory -Force -Path (Split-Path $ValidationSummaryPath -Parent) | Out-Null
    Update-DeliveryState
    Update-ValidationTimingTotals
    $summary | ConvertTo-Json -Depth 8 | Set-Content $ValidationSummaryPath -Encoding UTF8
    Add-Timing 'evidencePreparation' $writeStarted | Out-Null
}

function Test-XamlSanity {
    $excluded = @('graphify-out','.rpa-ai','.ai','.local','bin','obj','packages','node_modules')
    $files = @(Get-ChildItem -LiteralPath $ProjectPath -Recurse -File -Filter '*.xaml' | Where-Object {
        $relative = $_.FullName.Substring($ProjectPath.Length).TrimStart('\','/')
        $parts = $relative -split '[\\/]'
        -not ($parts | Where-Object { $_ -in $excluded })
    })
    foreach ($file in $files) {
        $settings = New-Object System.Xml.XmlReaderSettings
        $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $reader = $null
        try {
            $reader = [System.Xml.XmlReader]::Create($file.FullName, $settings)
            while ($reader.Read()) { }
        } catch {
            throw "XAML/XML sanity failed for '$($file.FullName)': $($_.Exception.Message)"
        } finally {
            if ($reader) { $reader.Dispose() }
        }
    }
    return $files.Count
}

$integrityScript = Join-Path $PSScriptRoot 'Test-ManagedFileIntegrity.ps1'
$phaseStarted = [DateTime]::UtcNow
$installedManifestPath = Join-Path $ProjectPath '.rpa-ai\kit-manifest.json'
$installedManifestDigestPath = Join-Path $ProjectPath '.rpa-ai\kit-manifest.sha256'
$installedManifestAvailable = (Test-Path $installedManifestPath -PathType Leaf) -and (Test-Path $installedManifestDigestPath -PathType Leaf)
Add-Timing 'manifestLookup' $phaseStarted | Out-Null
$phaseStarted = [DateTime]::UtcNow
if ($ReuseManagedIntegrity) {
    $summary.integrity = [ordered]@{ status = 'REUSED'; reason = 'Coordinator preflight managed-file integrity evidence reused.'; sourceFingerprint = [string]$summary.source.fingerprint; capturedAtUtc = [string]$summary.source.capturedAtUtc }
} elseif (Test-Path $integrityScript -PathType Leaf) {
    try {
        & $integrityScript -TargetBotPath $ProjectPath | Tee-Object -FilePath $log -Append
        $summary.integrity = [ordered]@{ status = 'PASS'; exitCode = 0 }
    } catch {
        $summary.integrity = [ordered]@{ status = 'FAIL'; reason = $_.Exception.Message }
        Write-ValidationSummary
        if ($executionStageStarted) {
            & $executionStateScript -Action StageEnd -Stage validation -TargetBotPath $ProjectPath -StatePath $ExecutionStatePath | Out-Null
            $executionStageStarted = $false
        }
        throw
    }
} else {
    $summary.integrity = [ordered]@{ status = 'NOT_APPLICABLE'; reason = 'Managed integrity script is not installed.' }
}
Add-Timing 'integrityLookup' $phaseStarted | Out-Null

$phaseStarted = [DateTime]::UtcNow
try {
    $xamlCount = Test-XamlSanity
    $summary.xaml_sanity = [ordered]@{ status = 'PASS'; files = $xamlCount; sourceFingerprint = [string]$summary.source.fingerprint; capturedAtUtc = [DateTime]::UtcNow.ToString('o') }
    "[PASS] XAML/XML sanity ($xamlCount file(s))" | Tee-Object -FilePath $log -Append
} catch {
    $summary.xaml_sanity = [ordered]@{ status = 'FAIL'; reason = $_.Exception.Message; sourceFingerprint = [string]$summary.source.fingerprint; capturedAtUtc = [DateTime]::UtcNow.ToString('o') }
    Write-ValidationSummary
    if ($executionStageStarted) {
        & $executionStateScript -Action StageEnd -Stage validation -TargetBotPath $ProjectPath -StatePath $ExecutionStatePath | Out-Null
        $executionStageStarted = $false
    }
    throw
}
finally { Add-Timing 'xamlSanity' $phaseStarted | Out-Null }

$phaseStarted = [DateTime]::UtcNow
try {
    $changedXaml=@($ChangedWorkflow | Where-Object {[IO.Path]::GetExtension($_) -eq '.xaml'})
    if ($changedXaml.Count -gt 0) {
        $enumResult = & $xamlCompatibilityScript -ProjectPath $ProjectPath -Workflow $changedXaml -EnvironmentJson ($compatibility | ConvertTo-Json -Depth 10 -Compress) -ParentEventId $ParentEventId -OmitUnsupportedOptionalProperty -Json | ConvertFrom-Json
        $summary.enum_property_compatibility = $enumResult
        if ([string]$enumResult.status -ne 'PASS') {
            $summary.delivery.blockedReason = 'UIPATH_XAML_ENUM_INCOMPATIBLE'
            throw 'UIPATH_XAML_ENUM_INCOMPATIBLE: one or more required/version-sensitive XAML properties are not valid for the target environment.'
        }
        if (@($enumResult.workflows | Where-Object changed).Count -gt 0) {
            $summary.source = Get-CurrentSourceEvidence
            $script:currentSourceEvidence = $summary.source
            $canReuseExecutableGates = $false
        }
    } else {
        $summary.enum_property_compatibility = [ordered]@{ status='NOT_APPLICABLE'; reason='No changed workflow was supplied for enum/property inspection.' }
    }
    if ([string]$summary.package_compatibility.status -eq 'BLOCKED') {
        $summary.delivery.blockedReason = 'UIPATH_PACKAGE_RELEASE_TRAIN_INCOMPATIBLE'
        throw "UIPATH_PACKAGE_RELEASE_TRAIN_INCOMPATIBLE: $($summary.package_compatibility.reason)"
    }
} catch {
    if ([string]$summary.enum_property_compatibility.status -eq 'NOT_RUN') { $summary.enum_property_compatibility = [ordered]@{status='BLOCKED';reason=$_.Exception.Message} }
    Write-ValidationSummary
    Sync-ExecutionValidationState
    if ($executionStageStarted) { & $executionStateScript -Action StageEnd -Stage validation -TargetBotPath $ProjectPath -StatePath $ExecutionStatePath | Out-Null; $executionStageStarted=$false }
    throw
} finally { Add-Timing 'enumPropertyCompatibility' $phaseStarted | Out-Null }

if ($ReuseDependencyState -and -not $ForceDependencyRestore -and (Test-Path $dependencyStateScript -PathType Leaf)) {
    $phaseStarted = [DateTime]::UtcNow
    try {
        $dependencyStateResult = & $dependencyStateScript -ProjectPath $ProjectPath -StatePath $DependencyStatePath -CliVersion $uipVersion -Verify -Json 2>$null | ConvertFrom-Json
        if ($uipVersion -ne 'UNKNOWN' -and $dependencyStateResult.status -eq 'MATCH') {
            $summary.dependency_restore = [ordered]@{ status = 'REUSED'; reused = $true; dependencyFingerprint = [string]$dependencyStateResult.stateHash; cliVersion = $uipVersion; sourceFingerprint = [string]$summary.source.fingerprint }
        }
    } catch { }
    finally { Add-Timing 'dependencyStateLookup' $phaseStarted | Out-Null }
}

function Invoke-Gate {
    param([string]$Name, [string[]]$Arguments, [string]$SummaryKey, [string]$TimingKey, [switch]$SideEffecting)
    $gateStarted = [DateTime]::UtcNow
    if ($SummaryKey -eq 'get_errors') { $summary.diagnostics_decision.diagnosticsExecuted = $true }
    "`n=== $Name ===" | Tee-Object -FilePath $log -Append
    ("uip " + ($Arguments -join ' ')) | Tee-Object -FilePath $log -Append
    try {
        $commandResult = & $commandScript -FilePath $uipCommand -ArgumentList $Arguments -WorkingDirectory $ProjectPath -TargetBotPath $ProjectPath -ExecutionStatePath $ExecutionStatePath -Operation $Name -ParentEventId $ParentEventId -TimeoutSeconds $TimeoutSeconds -SideEffecting:$SideEffecting -DoNotTerminateOnTimeout:$SideEffecting -Json | ConvertFrom-Json
    } catch {
        if ($TimingKey) { Add-Timing $TimingKey $gateStarted | Out-Null }
        $gateSource = $script:currentSourceEvidence
        $summary[$SummaryKey] = [ordered]@{ status = 'BLOCKED'; reason = $_.Exception.Message; sourceFingerprint = $gateSource.fingerprint; capturedAtUtc = $gateSource.capturedAtUtc }
        if ($SummaryKey -eq 'get_errors') { $summary.diagnostics = $summary[$SummaryKey] }
        Write-ValidationSummary
        throw
    }
    if ($commandResult.output) { $commandResult.output | Tee-Object -FilePath $log -Append }
    if ($commandResult.error) { $commandResult.error | Tee-Object -FilePath $log -Append }
    $code = [int]$commandResult.exit_code
    $gateSource = $script:currentSourceEvidence
    if ($TimingKey) {
        Add-Timing $TimingKey $gateStarted | Out-Null
        $commandTimingKey = $TimingKey + 'Command'
        if ($summary.timings.Contains($commandTimingKey)) { $summary.timings[$commandTimingKey] = [double]$commandResult.duration_seconds }
    }
    if ($SummaryKey -eq 'get_errors') { $summary.diagnostics_decision.diagnosticsDurationSeconds = [double]$commandResult.duration_seconds }
    $findingText = ([string]$commandResult.output) + [Environment]::NewLine + ([string]$commandResult.error)
    $ruleFindings = @([regex]::Matches($findingText, 'ST-[A-Z]+-[0-9]+') | ForEach-Object Value | Select-Object -Unique)
    $contentStatus='PASS'
    $content=$null
    if($SummaryKey -in @('build','analyzer','tests')){
        $parseArgs=@{InputText=$findingText;Json=$true}
        if($SummaryKey -eq 'tests'){$parseArgs.ResultOnly=$true}
        $content=& $diagnosticsParserScript @parseArgs | ConvertFrom-Json
        $contentStatus=if([int]$content.errorCount -gt 0){'FAIL'}elseif(-not [bool]$content.contentParsed){'BLOCKED'}else{'PASS'}
    }
    if ($commandResult.status -ne 'PASS' -or $contentStatus -ne 'PASS') {
        "[$($commandResult.status)] $Name (exit $code)" | Tee-Object -FilePath $log -Append
        $summary[$SummaryKey] = [ordered]@{ status = if($commandResult.status -ne 'PASS'){[string]$commandResult.status}else{$contentStatus}; content=$content; exitCode = $code; timedOut = [bool]$commandResult.timed_out; durationSeconds = [double]$commandResult.duration_seconds; toolVersion = $uipVersion; sourceFingerprint = $gateSource.fingerprint; capturedAtUtc = $gateSource.capturedAtUtc; outputPath = [string]$commandResult.output_path; outputSha256 = [string]$commandResult.output_sha256; findings = $ruleFindings }
        if($SummaryKey -eq 'build'){$summary[$SummaryKey].buildRequired=$true;$summary[$SummaryKey].buildExecuted=$true;$summary[$SummaryKey].buildSucceeded=$false;$summary[$SummaryKey].buildReuse=$false;$summary[$SummaryKey].buildDurationMs=[Math]::Round([double]$commandResult.duration_seconds*1000,3);$summary[$SummaryKey].buildRepairCount=0}
        if ($SummaryKey -eq 'get_errors') { $summary.diagnostics = $summary[$SummaryKey] }
        Write-ValidationSummary
        throw "$Name ended with status $($commandResult.status), exit code $code. Evidence: $log"
    }
    "[PASS] $Name" | Tee-Object -FilePath $log -Append
    $summary[$SummaryKey] = [ordered]@{ status = 'PASS'; content=$content; exitCode = 0; timedOut = $false; durationSeconds = [double]$commandResult.duration_seconds; toolVersion = $uipVersion; sourceFingerprint = $gateSource.fingerprint; capturedAtUtc = $gateSource.capturedAtUtc; outputPath = [string]$commandResult.output_path; outputSha256 = [string]$commandResult.output_sha256; findings = $ruleFindings }
    if($SummaryKey -eq 'build'){$summary[$SummaryKey].buildRequired=$true;$summary[$SummaryKey].buildExecuted=$true;$summary[$SummaryKey].buildSucceeded=$true;$summary[$SummaryKey].buildReuse=$false;$summary[$SummaryKey].buildDurationMs=[Math]::Round([double]$commandResult.duration_seconds*1000,3);$summary[$SummaryKey].buildRepairCount=0}
    Write-ValidationSummary
}

$validationError = $null
Push-Location $ProjectPath
try {
    $phaseStarted = [DateTime]::UtcNow
    $diagnosticsDecision = & $diagnosticsDecisionScript -RiskClassification $RiskClassification -ChangeFactsJson $ChangeFactsJson -StructuralValidationStatus PASS -ForceDiagnostics:$RunDiagnostics -Json | ConvertFrom-Json
    $decisionReason = [string]$diagnosticsDecision.diagnosticsDecisionReason
    if ($SkipDiagnostics) {
        if ($diagnosticsDecision.diagnosticsRequired) { $decisionReason += ' Legacy -SkipDiagnostics request rejected by conservative policy.' }
        else { $decisionReason += ' Legacy -SkipDiagnostics request is consistent with the policy decision.' }
    }
    $summary.diagnostics_decision = [ordered]@{
        riskClassification = [string]$diagnosticsDecision.riskClassification
        diagnosticsRequired = [bool]$diagnosticsDecision.diagnosticsRequired
        diagnosticsExecuted = $false
        diagnosticsDecisionReason = $decisionReason
        relevantChangeFacts = $diagnosticsDecision.relevantChangeFacts
        blockingFacts = @($diagnosticsDecision.blockingFacts)
        missingSafetyFacts = @($diagnosticsDecision.missingSafetyFacts)
        diagnosticsDurationSeconds = $null
    }
    Add-Timing 'diagnosticsDecision' $phaseStarted | Out-Null
    if ($summary.dependency_restore.status -eq 'REUSED' -and $summary.dependency_restore.reused) {
        '[REUSED] Restore reused from matching dependency state.' | Tee-Object -FilePath $log -Append
        $summary.dependency_restore.sourceFingerprint = $script:currentSourceEvidence.fingerprint
    } else {
        Invoke-Gate -Name 'Restore' -SummaryKey 'dependency_restore' -TimingKey 'restore' -Arguments @('rpa','restore',$ProjectPath)
        if (Test-Path $dependencyStateScript -PathType Leaf) {
            $recordedState = & $dependencyStateScript -ProjectPath $ProjectPath -StatePath $DependencyStatePath -CliVersion $uipVersion -AvailabilityStatus VERIFIED -Record -Json | ConvertFrom-Json
            $summary.dependency_restore.dependencyFingerprint = [string]$recordedState.stateHash
            $summary.dependency_restore.cliVersion = $uipVersion
            "[PASS] Dependency state recorded: $($recordedState.stateHash)" | Tee-Object -FilePath $log -Append
        }
        $phaseStarted = [DateTime]::UtcNow
        $postRestoreSource = Get-CurrentSourceEvidence
        Add-Timing 'postRestoreFingerprint' $phaseStarted | Out-Null
        if ([string]$postRestoreSource.executableFingerprint -ne [string]$script:currentSourceEvidence.executableFingerprint) { $canReuseExecutableGates = $false }
        $script:currentSourceEvidence = $postRestoreSource
        $summary.source = $postRestoreSource
    }
    $restoredCompatibility=& $compatibilityScript -ProjectPath $ProjectPath -ProjectKind $ProjectKind -CliVersion $uipVersion -CliPath $uipCommand -RequiredCapability $requiredCapabilities -Json | ConvertFrom-Json
    if($restoredCompatibility.environmentFingerprint -ne $compatibility.environmentFingerprint){$canReuseExecutableGates=$false}
    $compatibility=$restoredCompatibility
    $summary.environment.compatibility=$compatibility
    $summary.environment.fingerprint=[string]$compatibility.environmentFingerprint
    $summary.toolchain=[ordered]@{status=[string]$compatibility.toolchainEvidence.requiredEvidence.status;evidence=$compatibility.toolchainEvidence}
    $summary.package_compatibility = [ordered]@{ status=if([string]$compatibility.compatibilityDecision -in @('INCOMPATIBLE_RELEASE_TRAIN','INCOMPATIBLE_STUDIO_MINIMUM')){'BLOCKED'}else{'PASS'}; decision=[string]$compatibility.compatibilityDecision; reason=[string]$compatibility.compatibilityReason; selectedUiAutomationVersion=[string]$compatibility.selectedUiAutomationVersion; automaticPackageUpgrade=[bool]$compatibility.automaticPackageUpgrade; evidence=$compatibility.compatibilityEvidence }
    if([string]$summary.package_compatibility.status -eq 'BLOCKED'){
        $summary.delivery.blockedReason=[string]$compatibility.compatibilityDecision
        throw ('Package compatibility failed: '+$compatibility.compatibilityReason)
    }
    if([string]$summary.toolchain.status -ne 'PASS'){
        $summary.delivery.blockedReason='REQUIRED_TOOLCHAIN_EVIDENCE_INCOMPLETE'
        throw ('Required toolchain evidence is incomplete: '+($compatibility.toolchainEvidence.requiredEvidence.blockers -join ', '))
    }
    $diagnosticsRequested = [bool]$diagnosticsDecision.diagnosticsRequired
    if ($diagnosticsRequested) {
        $diagnosticStarted=[DateTime]::UtcNow
        $dependencyFingerprint=if($summary.dependency_restore.dependencyFingerprint){[string]$summary.dependency_restore.dependencyFingerprint}else{(Get-FileHash -LiteralPath $projectJson -Algorithm SHA256).Hash.ToLowerInvariant()}
        $nativeEvidencePath=Join-Path $evidenceDir 'uipath-native-diagnostics.json'
        $native=& $nativeDiagnosticsScript -ProjectPath $ProjectPath -ChangedWorkflow $ChangedWorkflow -UiPathCommand $uipCommand -ExecutionStatePath $ExecutionStatePath -DependencyFingerprint $dependencyFingerprint -EnvironmentFingerprint ([string]$compatibility.environmentFingerprint) -ParentEventId $ParentEventId -PolicyVersion '1.0' -ProjectFingerprint ([string]$summary.source.fingerprint) -OutputPath $nativeEvidencePath -TimeoutSeconds $TimeoutSeconds -Json|ConvertFrom-Json
        Add-Timing 'diagnostics' $diagnosticStarted|Out-Null
        $summary.get_errors = [ordered]@{ status=[string]$native.status; getErrorsRequired=[bool]$native.getErrorsRequired; getErrorsExecuted=[bool]$native.getErrorsExecuted; getErrorsReuse=[int]$native.getErrorsReuse; getErrorsReason=[string]$native.getErrorsReason; getErrorsDurationMs=[double]$native.getErrorsDurationMs; getErrorsErrorCount=[int]$native.getErrorsErrorCount; getErrorsRepairCount=[int]$native.getErrorsRepairCount; nativeValidationTotalMs=[double]$native.nativeValidationTotalMs; workflows=@($native.workflows); evidencePath='uipath-native-diagnostics.json'; toolVersion=$uipVersion; sourceFingerprint=[string]$summary.source.fingerprint; capturedAtUtc=[DateTime]::UtcNow.ToString('o') }
        $summary.diagnostics = $summary.get_errors
        $summary.diagnostics_decision.diagnosticsExecuted = [bool]$native.getErrorsExecuted
        $summary.diagnostics_decision.diagnosticsDurationSeconds = [Math]::Round([double]$native.getErrorsDurationMs/1000,3)
        if([string]$native.status -ne 'PASS'){
            $summary.delivery.blockedReason=if([string]$native.status -eq 'FAIL'){'UIPATH_NATIVE_DIAGNOSTICS_FAILED'}else{'UIPATH_NATIVE_DIAGNOSTICS_BLOCKED'}
            Write-ValidationSummary
            throw "$($summary.delivery.blockedReason): changed-workflow diagnostics did not pass."
        }
        '[PASS] UiPath-native changed-workflow diagnostics' | Tee-Object -FilePath $log -Append
    } else {
        "[SKIPPED] Diagnostics: $decisionReason" | Tee-Object -FilePath $log -Append
        $summary.get_errors = [ordered]@{ status = 'SKIPPED'; getErrorsRequired=$false; getErrorsExecuted=$false; getErrorsReuse=0; getErrorsReason=$decisionReason; getErrorsDurationMs=0; getErrorsErrorCount=0; getErrorsRepairCount=0; nativeValidationTotalMs=0; reason = $decisionReason; sourceFingerprint = [string]$summary.source.fingerprint; capturedAtUtc = [DateTime]::UtcNow.ToString('o') }
        $summary.diagnostics = $summary.get_errors
        $summary.diagnostics_decision.diagnosticsDurationSeconds = 0
        Write-ValidationSummary
    }

    # Independent official per-file validation follows dependency availability.
    if(-not $validateTargets.Count){throw 'No workflow available for required official per-file validation.'}
    $validationPolicyHash=(@($PSCommandPath,$nativeDiagnosticsScript,(Join-Path $PSScriptRoot 'ConvertFrom-UiPathDiagnostics.ps1'))|ForEach-Object {(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash}) -join '|'
    $nativeValidate=& $nativeDiagnosticsScript -CommandKind validate -ProjectPath $ProjectPath -ChangedWorkflow $validateTargets -UiPathCommand $uipCommand -ExecutionStatePath $ExecutionStatePath -DependencyFingerprint ([string]$summary.dependency_restore.dependencyFingerprint) -EnvironmentFingerprint (([string]$compatibility.environmentFingerprint)+'|'+$uipCommand+'|'+$uipVersion) -ParentEventId $ParentEventId -PolicyVersion $validationPolicyHash -OutputPath (Join-Path $evidenceDir 'uipath-workflow-validate.json') -TimeoutSeconds $TimeoutSeconds -Json | ConvertFrom-Json
    $summary.workflow_validate=[ordered]@{status=[string]$nativeValidate.status;required=$true;executed=[bool]$nativeValidate.getErrorsExecuted;reused=[int]$nativeValidate.getErrorsReuse;workflows=@($nativeValidate.workflows);sourceFingerprint=[string]$summary.source.fingerprint;capturedAtUtc=[DateTime]::UtcNow.ToString('o')}
    Write-ValidationSummary
    if([string]$nativeValidate.status -ne 'PASS'){$summary.delivery.blockedReason='REQUIRED_WORKFLOW_VALIDATE_INCOMPLETE';throw 'Official per-file validation failed or was blocked.'}

    # Build remains a separate compile gate.
    $buildArgs = @('rpa','build',$ProjectPath,'--output','json')
    if ($GovernanceFilePath) {
        $gov = (Resolve-Path $GovernanceFilePath).Path
        $buildArgs += @('--governance-file-path',$gov)
    }
    $canReuseBuild = $canReuseExecutableGates -and [string]$previousSummary.build.status -eq 'PASS' -and [string]$previousSummary.build.toolVersion -eq $uipVersion -and [string]$previousSummary.dependency_restore.dependencyFingerprint -eq [string]$summary.dependency_restore.dependencyFingerprint
    if ($canReuseBuild) {
        $summary.build = [ordered]@{ status = 'REUSED'; reason = 'Matching executable source, dependency, and CLI evidence.'; sourceFingerprint = [string]$summary.source.fingerprint; toolVersion = $uipVersion; capturedAtUtc = [DateTime]::UtcNow.ToString('o') }
        '[REUSED] Build reused from matching executable/dependency evidence.' | Tee-Object -FilePath $log -Append
        Write-ValidationSummary
    } else {
        Invoke-Gate -Name 'Build' -SummaryKey 'build' -TimingKey 'build' -Arguments $buildArgs
    }
    $summary.build.buildRequired=$true
    $summary.build.buildExecuted=[string]$summary.build.status -in @('PASS','REUSED')
    $summary.build.buildSucceeded=[string]$summary.build.status -in @('PASS','REUSED')
    $summary.build.buildReuse=[string]$summary.build.status -eq 'REUSED'
    $summary.build.buildDurationMs=if($summary.build.durationSeconds){[Math]::Round([double]$summary.build.durationSeconds*1000,3)}else{0}
    $summary.build.buildRepairCount=0

    if ($GovernanceFilePath) {
        $analyzeArgs = @('rpa','analyze',$ProjectPath,'--governance-file-path',$gov,'--output','json')
        if ($canReuseExecutableGates -and [string]$previousSummary.analyzer.status -eq 'PASS' -and [string]$previousSummary.analyzer.toolVersion -eq $uipVersion) {
            $summary.analyzer = [ordered]@{ status = 'REUSED'; reason = 'Matching executable source, governance, and CLI evidence.'; sourceFingerprint = [string]$summary.source.fingerprint; toolVersion = $uipVersion; capturedAtUtc = [DateTime]::UtcNow.ToString('o') }
            '[REUSED] Analyzer reused from matching executable evidence.' | Tee-Object -FilePath $log -Append
            Write-ValidationSummary
        } else {
            Invoke-Gate -Name 'Analyzer' -SummaryKey 'analyzer' -TimingKey 'analyzer' -Arguments $analyzeArgs
        }
    } else {
        "[NOT_RUN] Standalone analyzer: no governance file supplied." | Tee-Object -FilePath $log -Append
        $summary.analyzer = [ordered]@{ status = 'NOT_APPLICABLE'; reason = 'No governance file supplied.' }
    }

    if ($RunFile) {
        $runPath = (Resolve-Path (Join-Path $ProjectPath $RunFile)).Path
        $prefix=$ProjectPath.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
        if(-not $runPath.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'RunFile must stay within the project.'}
        $runArgs = @('rpa','run','--project-dir',$ProjectPath,'--file-path',$runPath.Substring($prefix.Length),'--skip-build','--output','json')
        if ($InputArgumentsJson) {
            $runArgs += @('--input-arguments',$InputArgumentsJson)
        }
        Invoke-Gate -Name 'Functional execution' -SummaryKey 'tests' -TimingKey 'functionalTest' -Arguments $runArgs -SideEffecting
    } else {
        "[NOT_RUN] Functional execution: no -RunFile supplied." | Tee-Object -FilePath $log -Append
        $summary.tests = [ordered]@{ status = 'NOT_RUN'; reason = 'No -RunFile supplied.' }
    }

    $phaseStarted = [DateTime]::UtcNow
    $finalSource = Get-CurrentSourceEvidence
    Add-Timing 'finalSourceFingerprint' $phaseStarted | Out-Null
    if ([string]$finalSource.executableFingerprint -ne [string]$script:currentSourceEvidence.executableFingerprint) {
        $summary.source_fresh=$false
        $summary.source = $finalSource
        Write-ValidationSummary
        throw 'Executable source changed after its validation gates completed. Rerun validation against the final source state.'
    }
    $summary.source = $finalSource
}
catch {
    $validationError = $_
}
finally {
    if ($executionStageStarted) {
        $phaseStarted = [DateTime]::UtcNow
        & $executionStateScript -Action StageEnd -Stage validation -TargetBotPath $ProjectPath -StatePath $ExecutionStatePath | Out-Null
        Add-Timing 'validationStageEnd' $phaseStarted | Out-Null
        $executionStageStarted = $false
    }
    $phaseStarted = [DateTime]::UtcNow
    Pop-Location
    Add-Timing 'cleanup' $phaseStarted | Out-Null
}

if ($validationError) {
    Write-ValidationSummary
    Sync-ExecutionValidationState
    throw $validationError
}

Write-ValidationSummary
Sync-ExecutionValidationState
Write-Host "Validation complete. Evidence: $log"
Write-Host "Validation summary: $ValidationSummaryPath"
