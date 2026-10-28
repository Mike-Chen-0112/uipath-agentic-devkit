[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$mapper = Join-Path $root 'scripts\Get-UiPathProjectMap.ps1'
$testRoot = Join-Path $env:TEMP ('rpa-project-mapper-tests-' + [guid]::NewGuid().ToString('N'))

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Write-Utf8 {
    param([string]$Path, [string]$Value)
    $parent = Split-Path $Path -Parent
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Value, (New-Object System.Text.UTF8Encoding($false)))
}

try {
    New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
    $project = [ordered]@{
        name = 'MapperFixture'
        main = 'Main.xaml'
        entryPoints = @(
            [ordered]@{ filePath = 'Main.xaml'; uniqueId = 'main' },
            [ordered]@{ filePath = 'Workflows\Process.xaml'; uniqueId = 'process' }
        )
        expressionLanguage = 'VisualBasic'
        designOptions = [ordered]@{ outputType = 'Process' }
        dependencies = [ordered]@{
            'UiPath.System.Activities' = '[24.10.0]'
            'UiPath.Excel.Activities' = '[2.24.0]'
        }
    }
    Write-Utf8 (Join-Path $testRoot 'project.json') ($project | ConvertTo-Json -Depth 8)

    Write-Utf8 (Join-Path $testRoot 'Main.xaml') @'
<Activity xmlns="http://schemas.microsoft.com/netfx/2009/xaml/activities" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" xmlns:custom="urn:test-uipath">
  <x:Members>
    <x:Property Name="in_Input" Type="InArgument(x:String)" />
    <x:Property Name="out_Result" Type="OutArgument(x:String)" />
  </x:Members>
  <Sequence>
    <custom:InvokeWorkflowFile WorkflowFileName="Workflows\Process.xaml" />
    <custom:LogMessage />
  </Sequence>
</Activity>
'@
    Write-Utf8 (Join-Path $testRoot 'Workflows\Process.xaml') @'
<Activity xmlns="http://schemas.microsoft.com/netfx/2009/xaml/activities" xmlns:u="urn:another-prefix">
  <Sequence>
    <u:InvokeWorkflowFile WorkflowFileName="Nested\Browser.xaml" />
    <u:ReadRange />
    <u:AddQueueItem />
    <u:CopyFile />
    <u:HttpRequest />
  </Sequence>
</Activity>
'@
    Write-Utf8 (Join-Path $testRoot 'Workflows\Nested\Browser.xaml') @'
<Activity xmlns="http://schemas.microsoft.com/netfx/2009/xaml/activities" xmlns:ui="urn:uipath">
  <Sequence><ui:UseApplicationBrowser /><ui:Click /><ui:TypeInto /></Sequence>
</Activity>
'@
    Write-Utf8 (Join-Path $testRoot 'Dynamic.xaml') @'
<Activity xmlns="http://schemas.microsoft.com/netfx/2009/xaml/activities" xmlns:alt="urn:uipath">
  <alt:InvokeWorkflowFile WorkflowFileName="[workflowPath]" />
</Activity>
'@
    Write-Utf8 (Join-Path $testRoot 'MissingCaller.xaml') @'
<Activity xmlns="http://schemas.microsoft.com/netfx/2009/xaml/activities" xmlns:alt="urn:uipath">
  <alt:InvokeWorkflowFile WorkflowFileName="Missing\NotThere.xaml" />
</Activity>
'@
    Write-Utf8 (Join-Path $testRoot 'Malformed.xaml') '<Activity><Sequence>'

    $first = & $mapper -ProjectPath $testRoot -Json | ConvertFrom-Json

    # project.json parsing and normalized project map output
    Assert-True ($first.schemaVersion -eq 1 -and $first.project.name -eq 'MapperFixture') 'Normalized project metadata is missing.'
    Assert-True ($first.project.main -eq 'Main.xaml' -and $first.project.type -eq 'Process' -and $first.project.expressionLanguage -eq 'VisualBasic') 'Main/type/expression language parsing failed.'
    Assert-True (@($first.project.entryPoints).Count -eq 2) 'Entry-point parsing failed.'
    Assert-True (@($first.project.dependencies).Count -eq 2 -and $first.project.dependencies[0].name -eq 'UiPath.Excel.Activities') 'UiPath dependency normalization failed.'
    Assert-True (@($first.workflows.PSObject.Properties).Count -eq 6 -and $first.metrics.xamlFilesMapped -eq 6) "Recursive XAML discovery failed (properties=$(@($first.workflows.PSObject.Properties).Count), mapped=$($first.metrics.xamlFilesMapped))."

    # static, nested, and Windows-path invocation normalization
    $mainInvoke = @($first.workflows.'Main.xaml'.invokes)[0]
    Assert-True ($mainInvoke.target -eq 'Workflows/Process.xaml' -and $mainInvoke.resolved -and -not $mainInvoke.dynamic) 'Static Windows-path invocation was not normalized or resolved.'
    $nestedInvoke = @($first.workflows.'Workflows/Process.xaml'.invokes)[0]
    Assert-True ($nestedInvoke.target -eq 'Workflows/Nested/Browser.xaml' -and $nestedInvoke.resolved) 'Nested source-relative workflow invocation was not resolved.'

    # dynamic references remain expressions and are never guessed
    $dynamicInvoke = @($first.workflows.'Dynamic.xaml'.invokes)[0]
    Assert-True ($dynamicInvoke.dynamic -and -not $dynamicInvoke.resolved -and $null -eq $dynamicInvoke.target -and $dynamicInvoke.expression -eq '[workflowPath]') 'Dynamic invocation was not preserved as unresolved.'

    # malformed and missing references warn without aborting the scan
    Assert-True (@($first.warnings | Where-Object code -eq 'MALFORMED_XAML').Count -eq 1) 'Malformed XAML did not produce a warning.'
    Assert-True (@($first.warnings | Where-Object code -eq 'MISSING_WORKFLOW').Count -eq 1) 'Missing referenced workflow did not produce a warning.'

    # forward/reverse graph and edges
    Assert-True (@($first.dependencies.forward.'Main.xaml') -contains 'Workflows/Process.xaml') 'Forward dependency graph is incomplete.'
    Assert-True (@($first.dependencies.reverse.'Workflows/Process.xaml') -contains 'Main.xaml') 'Reverse dependency graph is incomplete.'
    Assert-True (@($first.dependencies.reverse.'Workflows/Nested/Browser.xaml') -contains 'Workflows/Process.xaml') 'Nested reverse dependency graph is incomplete.'
    Assert-True (@($first.edges | Where-Object { $_.source -eq 'Main.xaml' -and $_.target -eq 'Workflows/Process.xaml' -and $_.resolved }).Count -eq 1) 'Normalized edge output is incomplete.'

    # arguments and activity capabilities are local-name based
    Assert-True (@($first.workflows.'Main.xaml'.arguments).Count -eq 2 -and $first.workflows.'Main.xaml'.arguments[0].direction -eq 'In') 'Workflow argument extraction failed.'
    Assert-True (@($first.workflows.'Main.xaml'.capabilities) -contains 'Logging') 'Logging classification failed.'
    Assert-True (@($first.workflows.'Main.xaml'.capabilities) -contains 'Workflow Invocation') 'Workflow invocation classification failed.'
    Assert-True (@($first.workflows.'Workflows/Process.xaml'.capabilities) -contains 'Excel') 'Excel classification failed.'
    Assert-True (@($first.workflows.'Workflows/Process.xaml'.capabilities) -contains 'Queue / Orchestrator') 'Queue classification failed.'
    Assert-True (@($first.workflows.'Workflows/Process.xaml'.capabilities) -contains 'File') 'File classification failed.'
    Assert-True (@($first.workflows.'Workflows/Process.xaml'.capabilities) -contains 'HTTP') 'HTTP classification failed.'
    Assert-True (@($first.workflows.'Workflows/Nested/Browser.xaml'.capabilities) -contains 'Browser / UI Automation') 'Browser/UI classification failed.'

    # unchanged cache reuse
    Assert-True ($first.metrics.xamlFilesParsed -eq 6 -and $first.metrics.cacheHits -eq 0) 'Initial scan cache metrics are incorrect.'
    $second = & $mapper -ProjectPath $testRoot -Json | ConvertFrom-Json
    Assert-True ($second.metrics.xamlFilesParsed -eq 0 -and $second.metrics.cacheHits -eq 6 -and $second.metrics.cacheStatus -eq 'VALID') 'Unchanged workflow metadata was not reused.'
    Assert-True (@($second.workflows.'MissingCaller.xaml'.parsingWarnings | Where-Object { $_ -like 'MISSING_WORKFLOW:*' }).Count -eq 1) 'Cached missing-workflow warnings were duplicated.'

    # changed files are reparsed while unchanged files remain cached
    Write-Utf8 (Join-Path $testRoot 'Dynamic.xaml') @'
<Activity xmlns="http://schemas.microsoft.com/netfx/2009/xaml/activities" xmlns:alt="urn:uipath">
  <Sequence><alt:InvokeWorkflowFile WorkflowFileName="[newWorkflowPath]" /><alt:LogMessage /></Sequence>
</Activity>
'@
    $third = & $mapper -ProjectPath $testRoot -Json | ConvertFrom-Json
    Assert-True ($third.metrics.xamlFilesParsed -eq 1 -and $third.metrics.cacheHits -eq 5) 'Changed workflow cache invalidation failed.'
    Assert-True ($third.workflows.'Dynamic.xaml'.invokes[0].expression -eq '[newWorkflowPath]') 'Changed workflow metadata was not reparsed.'

    # deleted files disappear from the map and are reported in metrics
    Remove-Item -LiteralPath (Join-Path $testRoot 'Malformed.xaml') -Force
    $fourth = & $mapper -ProjectPath $testRoot -Json | ConvertFrom-Json
    Assert-True (@($fourth.workflows.PSObject.Properties).Count -eq 5 -and $null -eq $fourth.workflows.'Malformed.xaml') 'Deleted workflow remained in the map.'
    Assert-True ($fourth.metrics.deletedWorkflows -eq 1) 'Deleted workflow cache handling was not reported.'

    # a corrupt cache safely falls back to a complete fresh scan
    Write-Utf8 (Join-Path $testRoot '.devkit\cache\project-map-cache.json') 'not-json'
    $fifth = & $mapper -ProjectPath $testRoot -Json | ConvertFrom-Json
    Assert-True ($fifth.metrics.cacheStatus -eq 'INVALID' -and $fifth.metrics.xamlFilesParsed -eq 5 -and $fifth.metrics.cacheHits -eq 0) 'Corrupt cache did not trigger a fresh scan.'
    Assert-True (@($fifth.warnings | Where-Object code -eq 'CACHE_INVALID').Count -eq 1) 'Corrupt cache fallback warning is missing.'

    Write-Host '[PASS] UiPath Project Mapper tests'
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
