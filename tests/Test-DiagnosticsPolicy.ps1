[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$decisionScript = Join-Path $root 'scripts\Get-DiagnosticsDecision.ps1'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function New-Facts {
    param([hashtable]$Overrides = @{})
    $facts = [ordered]@{
        projectJsonChanged = $false
        dependencyChanged = $false
        newWorkflow = $false
        deletedWorkflow = $false
        workflowArgumentsChanged = $false
        invokeTopologyChanged = $false
        uiAutomationStructureChanged = $false
        generatedXaml = $false
        activityTypeChanged = $false
        activityPropertySerializationChanged = $false
        enumBackedPropertyChanged = $false
        selectorSerializationChanged = $false
        targetDescriptorChanged = $false
        packageCompatibilityChanged = $false
        securitySensitiveChanged = $false
        unresolvedDependency = $false
        relevantMapperWarning = $false
        architectureChanged = $false
        developerUncertainty = $false
        ambiguousImpact = $false
        localizedScope = $true
        textOnly = $false
        loggingOnly = $false
        nonStructuralPropertyChange = $false
        localizedConfigurationChange = $false
        changedFiles = @('Main.xaml')
        changedWorkflows = @('Main.xaml')
    }
    foreach ($key in $Overrides.Keys) { $facts[$key] = $Overrides[$key] }
    return $facts
}

function Get-Decision {
    param([string]$Risk, [hashtable]$Overrides = @{}, [string]$StructuralStatus = 'PASS')
    $facts = New-Facts $Overrides
    return (& $decisionScript -RiskClassification $Risk -StructuralValidationStatus $StructuralStatus -ChangeFactsJson ($facts | ConvertTo-Json -Depth 6 -Compress) -Json | ConvertFrom-Json)
}

$r0 = Get-Decision R0 @{ textOnly = $true; changedFiles = @('README.md'); changedWorkflows = @() }
Assert-True (-not $r0.diagnosticsRequired) 'R0 textual/local change should be eligible to skip diagnostics.'

$r1 = Get-Decision R1 @{ loggingOnly = $true }
Assert-True (-not $r1.diagnosticsRequired) 'Localized R1 logging change should be eligible to skip diagnostics.'

$requiredCases = [ordered]@{
    'project.json change' = @{ Risk = 'R1'; Facts = @{ projectJsonChanged = $true; localizedConfigurationChange = $true } }
    'package/dependency change' = @{ Risk = 'R1'; Facts = @{ dependencyChanged = $true; localizedConfigurationChange = $true } }
    'workflow argument/interface change' = @{ Risk = 'R1'; Facts = @{ workflowArgumentsChanged = $true; nonStructuralPropertyChange = $true } }
    'new workflow' = @{ Risk = 'R1'; Facts = @{ newWorkflow = $true; loggingOnly = $true } }
    'deleted workflow' = @{ Risk = 'R1'; Facts = @{ deletedWorkflow = $true; loggingOnly = $true } }
    'Invoke Workflow topology change' = @{ Risk = 'R1'; Facts = @{ invokeTopologyChanged = $true; nonStructuralPropertyChange = $true } }
    'selector/UI Automation structural change' = @{ Risk = 'R1'; Facts = @{ uiAutomationStructureChanged = $true; nonStructuralPropertyChange = $true } }
    'generated XAML' = @{ Risk = 'R1'; Facts = @{ generatedXaml = $true; loggingOnly = $true } }
    'activity type change' = @{ Risk = 'R1'; Facts = @{ activityTypeChanged = $true; nonStructuralPropertyChange = $true } }
    'serialized activity property change' = @{ Risk = 'R1'; Facts = @{ activityPropertySerializationChanged = $true; nonStructuralPropertyChange = $true } }
    'enum-backed property change' = @{ Risk = 'R1'; Facts = @{ enumBackedPropertyChanged = $true; nonStructuralPropertyChange = $true } }
    'selector serialization change' = @{ Risk = 'R1'; Facts = @{ selectorSerializationChanged = $true; nonStructuralPropertyChange = $true } }
    'target descriptor change' = @{ Risk = 'R1'; Facts = @{ targetDescriptorChanged = $true; nonStructuralPropertyChange = $true } }
    'package compatibility change' = @{ Risk = 'R1'; Facts = @{ packageCompatibilityChanged = $true; localizedConfigurationChange = $true } }
    'credential/security-sensitive change' = @{ Risk = 'R1'; Facts = @{ securitySensitiveChanged = $true; nonStructuralPropertyChange = $true } }
    'unresolved dependency' = @{ Risk = 'R1'; Facts = @{ unresolvedDependency = $true; loggingOnly = $true } }
    'relevant Mapper warning' = @{ Risk = 'R1'; Facts = @{ relevantMapperWarning = $true; loggingOnly = $true } }
    'Developer uncertainty' = @{ Risk = 'R1'; Facts = @{ developerUncertainty = $true; loggingOnly = $true } }
    'ambiguous impact' = @{ Risk = 'R1'; Facts = @{ ambiguousImpact = $true; loggingOnly = $true } }
    'uncertain classification' = @{ Risk = 'UNKNOWN'; Facts = @{ loggingOnly = $true } }
}
foreach ($name in $requiredCases.Keys) {
    $case = $requiredCases[$name]
    $decision = Get-Decision $case.Risk $case.Facts
    Assert-True $decision.diagnosticsRequired "$name must require diagnostics."
}

$structuralFailure = Get-Decision R1 @{ loggingOnly = $true } 'FAIL'
Assert-True $structuralFailure.diagnosticsRequired 'Failed structural validation must require diagnostics.'

$missingFacts = & $decisionScript -RiskClassification R1 -StructuralValidationStatus PASS -ChangeFactsJson '{"loggingOnly":true,"localizedScope":true}' -Json | ConvertFrom-Json
Assert-True ($missingFacts.diagnosticsRequired -and @($missingFacts.missingSafetyFacts).Count -gt 0) 'Incomplete safety facts must conservatively require diagnostics.'

$forced = & $decisionScript -RiskClassification R1 -StructuralValidationStatus PASS -ChangeFactsJson ((New-Facts @{ loggingOnly = $true }) | ConvertTo-Json -Compress) -ForceDiagnostics -Json | ConvertFrom-Json
Assert-True $forced.diagnosticsRequired 'Explicit force must require diagnostics.'

Write-Host '[PASS] Risk-based diagnostics decision tests'
