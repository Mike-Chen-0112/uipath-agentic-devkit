[CmdletBinding()]
param(
    [ValidateSet('R0','R1','R2','R3','UNKNOWN')]
    [string]$RiskClassification = 'UNKNOWN',
    [string]$ChangeFactsJson,
    [ValidateSet('PASS','FAIL','UNKNOWN')]
    [string]$StructuralValidationStatus = 'UNKNOWN',
    [switch]$ForceDiagnostics,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$safetyFields = @(
    'projectJsonChanged',
    'dependencyChanged',
    'newWorkflow',
    'deletedWorkflow',
    'workflowArgumentsChanged',
    'invokeTopologyChanged',
    'uiAutomationStructureChanged',
    'generatedXaml',
    'activityTypeChanged',
    'activityPropertySerializationChanged',
    'enumBackedPropertyChanged',
    'selectorSerializationChanged',
    'targetDescriptorChanged',
    'packageCompatibilityChanged',
    'securitySensitiveChanged',
    'unresolvedDependency',
    'relevantMapperWarning',
    'architectureChanged',
    'developerUncertainty',
    'ambiguousImpact'
)
$eligibleChangeKinds = @('textOnly','loggingOnly','nonStructuralPropertyChange','localizedConfigurationChange')

function Get-FactProperty {
    param($Facts, [string]$Name)
    if ($null -eq $Facts) { return $null }
    $property = $Facts.PSObject.Properties | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
    if (-not $property) { return $null }
    return $property.Value
}

$facts = $null
$parseError = $null
if ($ChangeFactsJson) {
    try { $facts = $ChangeFactsJson | ConvertFrom-Json }
    catch { $parseError = $_.Exception.Message }
}

$normalizedFacts = [ordered]@{}
foreach ($name in ($safetyFields + $eligibleChangeKinds + @('localizedScope','changedFiles','changedWorkflows'))) {
    $normalizedFacts[$name] = Get-FactProperty $facts $name
}

$required = $true
$reason = ''
$blockingFacts = @()
$missingFacts = @()

if ($ForceDiagnostics) {
    $reason = 'Diagnostics explicitly forced.'
} elseif ($RiskClassification -notin @('R0','R1')) {
    $reason = "Risk classification $RiskClassification requires diagnostics."
} elseif (-not $ChangeFactsJson) {
    $reason = 'Change facts were not supplied; conservative fallback requires diagnostics.'
} elseif ($parseError) {
    $reason = "Change facts are invalid; conservative fallback requires diagnostics: $parseError"
} elseif ($StructuralValidationStatus -ne 'PASS') {
    $reason = "Structural validation status is $StructuralValidationStatus; diagnostics are required."
} else {
    foreach ($name in $safetyFields) {
        $value = $normalizedFacts[$name]
        if ($null -eq $value -or $value -isnot [bool]) { $missingFacts += $name }
        elseif ([bool]$value) { $blockingFacts += $name }
    }
    if ($missingFacts.Count -gt 0) {
        $reason = 'Required safety facts are missing or non-boolean: ' + ($missingFacts -join ', ') + '.'
    } elseif ($blockingFacts.Count -gt 0) {
        $reason = 'Diagnostics required by change facts: ' + ($blockingFacts -join ', ') + '.'
    } elseif ($normalizedFacts.localizedScope -isnot [bool] -or -not [bool]$normalizedFacts.localizedScope) {
        $reason = 'Localized impact scope was not explicitly established.'
    } else {
        $eligibleKinds = @($eligibleChangeKinds | Where-Object { $normalizedFacts[$_] -is [bool] -and [bool]$normalizedFacts[$_] })
        if ($eligibleKinds.Count -eq 0) {
            $reason = 'No explicitly eligible low-risk change kind was established.'
        } elseif ($RiskClassification -eq 'R0' -and -not [bool]$normalizedFacts.textOnly) {
            $reason = 'R0 diagnostics skipping is limited to an explicitly textual/non-runtime change.'
        } else {
            $required = $false
            $reason = "Eligible localized $RiskClassification change with structural validation PASS and no safety triggers ($($eligibleKinds -join ', '))."
        }
    }
}

$result = [ordered]@{
    schemaVersion = 1
    riskClassification = $RiskClassification
    diagnosticsRequired = $required
    diagnosticsDecisionReason = $reason
    structuralValidationStatus = $StructuralValidationStatus
    relevantChangeFacts = $normalizedFacts
    blockingFacts = @($blockingFacts)
    missingSafetyFacts = @($missingFacts)
}

if ($Json) { $result | ConvertTo-Json -Depth 8 } else { $result }
