[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$packageScript = Join-Path $root 'scripts\New-DeveloperContextPackage.ps1'
$fingerprintScript = Join-Path $root 'scripts\SourceFingerprint.ps1'
$profileScript = Join-Path $root 'scripts\Get-DeveloperContextProfile.ps1'
$testRoot = Join-Path $env:TEMP ('rpa-developer-fast-context-tests-' + [guid]::NewGuid().ToString('N'))
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Write-Utf8 {
    param([string]$Path, [string]$Value)
    New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null
    [System.IO.File]::WriteAllText($Path, $Value, $utf8)
}

function Write-Json {
    param([string]$Path, $Value)
    Write-Utf8 $Path (($Value | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
}

function Invoke-Prepare {
    param(
        [string]$Name,
        [string]$MapPath = '.ai/evidence/project-map.json',
        [string]$RefreshPath = 'graphify-out/refresh-state.json',
        [string]$ExpectedSource,
        [string[]]$Activity = @('AddQueueItem'),
        [hashtable]$Switches = @{}
    )
    $arguments = @{
        Action = 'Prepare'
        ProjectPath = $testRoot
        PackagePath = ".ai/evidence/$Name.json"
        ProjectMapPath = $MapPath
        GraphPath = 'graphify-out/graph.json'
        GraphRefreshStatePath = $RefreshPath
        TaskId = $Name
        TaskSummary = 'Add an informational log before queue submission.'
        Risk = 'R1'
        WorkflowPath = @('Selected.xaml')
        RelevantActivityName = $Activity
        ExpectedSourceFingerprint = $ExpectedSource
        ExpectedGraphFingerprint = $ExpectedSource
        LocalizedScope = $true
        ValidationExpectation = @('Changed workflow sanity PASS')
        Constraint = @('No queue payload change')
        Json = $true
    }
    foreach ($key in $Switches.Keys) { $arguments[$key] = $Switches[$key] }
    return (& $packageScript @arguments | ConvertFrom-Json)
}

function Assert-Fallback {
    param($Package, [string]$Reason, [string]$Case)
    Assert-True (-not $Package.decision.fastContextUsed -and $Package.decision.fastContextFallback) "$Case did not fall back."
    Assert-True ($Reason -in @($Package.decision.fallbackReasons)) "$Case did not record $Reason."
}

try {
    New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
    Write-Utf8 (Join-Path $testRoot 'project.json') '{"name":"FastContextFixture","main":"Parent.xaml"}'
    Write-Utf8 (Join-Path $testRoot 'Selected.xaml') @'
<Activity xmlns="http://schemas.microsoft.com/netfx/2009/xaml/activities" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" xmlns:ui="http://schemas.uipath.com/workflow/activities">
  <Sequence>
    <ui:AddQueueItem DisplayName="Add Queue Item" />
    <ui:InvokeWorkflowFile WorkflowFileName="Child.xaml" />
  </Sequence>
</Activity>
'@
    Write-Utf8 (Join-Path $testRoot 'Parent.xaml') '<Activity xmlns="http://schemas.microsoft.com/netfx/2009/xaml/activities" />'
    Write-Utf8 (Join-Path $testRoot 'Child.xaml') '<Activity xmlns="http://schemas.microsoft.com/netfx/2009/xaml/activities" />'
    Write-Utf8 (Join-Path $testRoot 'Unrelated.xaml') '<Activity xmlns="http://schemas.microsoft.com/netfx/2009/xaml/activities"><Sequence DisplayName="UNRELATED_SENTINEL" /></Activity>'
    Write-Utf8 (Join-Path $testRoot 'AGENTS.md') 'fixture context'
    Write-Utf8 (Join-Path $testRoot '.github\agents\rpa-developer.agent.md') 'fixture developer instructions'

    $map = [ordered]@{
        schemaVersion = 1
        generatedAtUtc = [DateTime]::UtcNow.AddSeconds(2).ToString('o')
        project = [ordered]@{ name = 'FastContextFixture'; main = 'Parent.xaml' }
        workflows = [ordered]@{
            'Selected.xaml' = [ordered]@{ invokes = @([ordered]@{ target = 'Child.xaml'; resolved = $true; dynamic = $false; expression = 'Child.xaml' }); arguments = @([ordered]@{ name = 'in_Config'; type = 'InArgument(Dictionary)'; direction = 'In' }); capabilities = @('Queue / Orchestrator','Logging'); parsingWarnings = @() }
            'Parent.xaml' = [ordered]@{ invokes = @([ordered]@{ target = 'Selected.xaml'; resolved = $true; dynamic = $false; expression = 'Selected.xaml' }); arguments = @(); capabilities = @('Workflow Invocation'); parsingWarnings = @() }
            'Child.xaml' = [ordered]@{ invokes = @(); arguments = @(); capabilities = @(); parsingWarnings = @() }
            'Unrelated.xaml' = [ordered]@{ invokes = @(); arguments = @(); capabilities = @('Excel'); parsingWarnings = @() }
        }
        edges = @(
            [ordered]@{ source = 'Parent.xaml'; target = 'Selected.xaml'; resolved = $true; dynamic = $false; expression = 'Selected.xaml' },
            [ordered]@{ source = 'Selected.xaml'; target = 'Child.xaml'; resolved = $true; dynamic = $false; expression = 'Child.xaml' }
        )
        dependencies = [ordered]@{
            forward = [ordered]@{ 'Selected.xaml' = @('Child.xaml'); 'Parent.xaml' = @('Selected.xaml'); 'Child.xaml' = @(); 'Unrelated.xaml' = @() }
            reverse = [ordered]@{ 'Selected.xaml' = @('Parent.xaml'); 'Parent.xaml' = @(); 'Child.xaml' = @('Selected.xaml'); 'Unrelated.xaml' = @() }
        }
        resources = [ordered]@{ 'Selected.xaml' = @([ordered]@{ kind = 'queue'; name = 'ConfiguredQueue' }); 'Unrelated.xaml' = @([ordered]@{ kind = 'asset'; name = 'UnrelatedAsset' }) }
        warnings = @()
        metrics = [ordered]@{ xamlFilesMapped = 4 }
    }
    $mapPath = Join-Path $testRoot '.ai\evidence\project-map.json'
    Write-Json $mapPath $map
    $graph = [ordered]@{
        nodes = @(
            [ordered]@{ id = 'selected'; label = 'Selected.xaml'; source_file = 'Selected.xaml'; source_location = 'L1' },
            [ordered]@{ id = 'parent'; label = 'Parent.xaml'; source_file = 'Parent.xaml'; source_location = 'L1' },
            [ordered]@{ id = 'child'; label = 'Child.xaml'; source_file = 'Child.xaml'; source_location = 'L1' },
            [ordered]@{ id = 'unrelated'; label = 'UNRELATED_GRAPH_SENTINEL'; source_file = 'Unrelated.xaml'; source_location = 'L1' }
        )
        edges = @(
            [ordered]@{ source = 'parent'; target = 'selected'; relation = 'references'; confidence = 'EXTRACTED' },
            [ordered]@{ source = 'selected'; target = 'child'; relation = 'references'; confidence = 'EXTRACTED' },
            [ordered]@{ source = 'unrelated'; target = 'unrelated'; relation = 'contains'; confidence = 'EXTRACTED' }
        )
        hyperedges = @()
    }
    Write-Json (Join-Path $testRoot 'graphify-out\graph.json') $graph
    Write-Utf8 (Join-Path $testRoot 'graphify-out\GRAPH_REPORT.md') 'compact graph report reference'
    $snapshot = & $fingerprintScript -ProjectPath $testRoot -Json | ConvertFrom-Json
    $refresh = [ordered]@{ schemaVersion = 2; fingerprintSchemaVersion = $snapshot.schemaVersion; fingerprint = $snapshot.sourceFingerprint; sourceFingerprint = $snapshot.sourceFingerprint; graphConfigFingerprint = $snapshot.graphConfigFingerprint; refreshedAtUtc = [DateTime]::UtcNow.ToString('o') }
    Write-Json (Join-Path $testRoot 'graphify-out\refresh-state.json') $refresh

    $baseline = Invoke-Prepare -Name 'baseline' -ExpectedSource $snapshot.sourceFingerprint
    Assert-True ($baseline.decision.fastContextUsed -and -not $baseline.decision.fastContextFallback) 'Localized one-workflow task did not use fast context.'
    Assert-True (@($baseline.scope.workflowsRepresented).Count -eq 3 -and 'Unrelated.xaml' -notin @($baseline.scope.workflowsRepresented)) 'Scoped Project Map did not exclude unrelated workflows.'
    Assert-True ('Parent.xaml' -in @($baseline.scopedProjectMap.workflows.'Selected.xaml'.parents) -and 'Child.xaml' -in @($baseline.scopedProjectMap.workflows.'Selected.xaml'.children)) 'Direct parent/child relationships were not preserved.'
    Assert-True ($baseline.scopedProjectMap.resources[0].workflow -eq 'Selected.xaml') 'Relevant resource information was not preserved.'
    Assert-True ($baseline.sourceAccess.paths[0].path -eq 'Selected.xaml' -and $baseline.sourceAccess.paths[0].fullXamlAvailable) 'Authoritative source path was not preserved.'
    Assert-True ($baseline.graph.fullGraphPath -eq 'graphify-out/graph.json' -and $baseline.graph.graphSummaryPath -eq 'graphify-out/GRAPH_REPORT.md') 'Graph summary references were not preserved.'
    Assert-True ($baseline.sourceAccess.rawXamlBytesInitiallyIncluded -eq 0 -and $baseline.sourceAccess.initialMode -eq 'metadata_and_locations') 'Raw XAML was embedded in initial context.'
    Assert-True (@($baseline.scopedProjectMap.workflows.'Selected.xaml'.relevantActivities).Count -eq 1) 'Relevant activity location was not materialized.'
    $baselineText = Get-Content -Raw -LiteralPath (Join-Path $testRoot '.ai\evidence\baseline.json')
    Assert-True ($baselineText -notmatch 'UNRELATED_SENTINEL|UNRELATED_GRAPH_SENTINEL' -and $baselineText -notmatch '<ui:AddQueueItem') 'Complete map, graph, or raw source leaked into the compact package.'
    Assert-True ($baseline.metrics.packageBytes -lt ((Get-Item $mapPath).Length + (Get-Item (Join-Path $testRoot 'Selected.xaml')).Length)) 'Compact package was not smaller than the replaced map/source inputs.'

    $expanded = & $packageScript -Action Expand -ProjectPath $testRoot -PackagePath '.ai/evidence/baseline.json' -WorkflowPath 'Selected.xaml' -ExpansionMode FullSource -ExpansionReason 'Exact source structure required for safe XAML edit.' -Json | ConvertFrom-Json
    Assert-True ($expanded.sourceAccess.rawSourceFallbackUsed -and $expanded.contextExpansions[0].additionalBytes -eq (Get-Item (Join-Path $testRoot 'Selected.xaml')).Length) 'Full-source expansion was not retained as auditable evidence.'
    Assert-True ((Get-Content -Raw (Join-Path $testRoot '.ai\evidence\baseline.json')) -notmatch '<ui:AddQueueItem') 'Source expansion duplicated raw XAML into evidence.'
    $profile = & $profileScript -ProjectPath $testRoot -ContextPackagePath '.ai/evidence/baseline.json' -OutputPath '.ai/evidence/developer-context-profile.json' -Json | ConvertFrom-Json
    Assert-True ($profile.compactContext.fastContextUsed -and $profile.compactContext.scopedProjectMapBytes -gt 0 -and $profile.compactContext.graphSummaryBytes -gt 0) 'Compact context metrics were not persisted.'
    Assert-True ($profile.compactContext.rawXamlBytesInitiallyIncluded -eq 0 -and $profile.compactContext.sourceFilesInitiallyIncluded -eq 0 -and $profile.compactContext.contextExpansionCount -eq 1 -and $profile.compactContext.rawSourceFallbackUsed) 'Initial/expanded source context metrics are incorrect.'

    $unresolved = $map | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $unresolved.workflows.'Selected.xaml'.invokes[0].resolved = $false
    Write-Json (Join-Path $testRoot '.ai\evidence\map-unresolved.json') $unresolved
    Assert-Fallback (Invoke-Prepare -Name 'unresolved' -MapPath '.ai/evidence/map-unresolved.json' -ExpectedSource $snapshot.sourceFingerprint) 'UNRESOLVED_RELEVANT_INVOKE' 'Unresolved invoke'

    $warned = $map | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $warned.warnings = @([ordered]@{ code = 'DYNAMIC_INVOKE'; path = 'Selected.xaml'; message = 'Relevant warning' })
    Write-Json (Join-Path $testRoot '.ai\evidence\map-warning.json') $warned
    Assert-Fallback (Invoke-Prepare -Name 'warning' -MapPath '.ai/evidence/map-warning.json' -ExpectedSource $snapshot.sourceFingerprint) 'RELEVANT_MAPPER_WARNING' 'Relevant Mapper warning'

    Assert-Fallback (Invoke-Prepare -Name 'stale-source' -ExpectedSource ('0' * 64)) 'SOURCE_FINGERPRINT_MISMATCH' 'Stale source fingerprint'
    $staleRefresh = $refresh | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $staleRefresh.sourceFingerprint = '1' * 64
    Write-Json (Join-Path $testRoot 'graphify-out\refresh-state-stale.json') $staleRefresh
    Assert-Fallback (Invoke-Prepare -Name 'stale-graph' -RefreshPath 'graphify-out/refresh-state-stale.json' -ExpectedSource $snapshot.sourceFingerprint) 'GRAPH_FINGERPRINT_MISMATCH' 'Stale graph fingerprint'
    Assert-Fallback (Invoke-Prepare -Name 'architecture' -ExpectedSource $snapshot.sourceFingerprint -Switches @{ ArchitectureChange = $true }) 'ARCHITECTURE_CHANGE' 'Architecture change'
    Assert-Fallback (Invoke-Prepare -Name 'interface' -ExpectedSource $snapshot.sourceFingerprint -Switches @{ ArgumentInterfaceChange = $true }) 'ARGUMENT_INTERFACE_CHANGE' 'Argument/interface change'
    Assert-Fallback (Invoke-Prepare -Name 'ambiguous' -ExpectedSource $snapshot.sourceFingerprint -Switches @{ AmbiguousScope = $true }) 'AMBIGUOUS_SCOPE' 'Ambiguous scope'
    Assert-Fallback (Invoke-Prepare -Name 'uncertain' -ExpectedSource $snapshot.sourceFingerprint -Switches @{ DeveloperUncertainty = $true }) 'DEVELOPER_UNCERTAINTY' 'Developer uncertainty'
    Assert-Fallback (Invoke-Prepare -Name 'missing-activity' -ExpectedSource $snapshot.sourceFingerprint -Activity @('MissingActivity')) 'MISSING_RELEVANT_ACTIVITY_LOCATION' 'Missing activity location'
    Assert-Fallback (Invoke-Prepare -Name 'full-source' -ExpectedSource $snapshot.sourceFingerprint -Switches @{ ExplicitFullSourceRequirement = $true }) 'EXPLICIT_FULL_SOURCE_REQUIREMENT' 'Explicit full-source requirement'

    $stalePackage = Invoke-Prepare -Name 'source-authority' -ExpectedSource $snapshot.sourceFingerprint
    Write-Utf8 (Join-Path $testRoot 'Selected.xaml') ((Get-Content -Raw (Join-Path $testRoot 'Selected.xaml')) + [Environment]::NewLine + '<!-- changed after package -->')
    $validated = & $packageScript -Action Validate -ProjectPath $testRoot -PackagePath '.ai/evidence/source-authority.json' -Json | ConvertFrom-Json
    Assert-Fallback $validated 'SOURCE_FINGERPRINT_MISMATCH' 'Post-package source change'
    Assert-True ('raw XAML' -eq $validated.sourceAccess.authorityOrder[0]) 'Raw source is not the documented authority.'

    Write-Host '[PASS] Developer fast-context package and fallback tests'
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
