[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$testRoot=Join-Path $env:TEMP ('rpa-ai-native-validation-'+[guid]::NewGuid().ToString('N'))
$fakeBin=Join-Path $testRoot 'bin';$originalPath=$env:PATH;$powerShellHost=(Get-Process -Id $PID).Path
function Assert-True{param([bool]$Condition,[string]$Message)if(-not $Condition){throw $Message}}
function Write-Utf8{param([string]$Path,[string]$Text)New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent)|Out-Null;[IO.File]::WriteAllText($Path,$Text,(New-Object Text.UTF8Encoding($false)))}
function New-Project{
    param([string]$Path,[string]$UiVersion='',[string]$Studio='25.10.16')
    New-Item -ItemType Directory -Force -Path $Path|Out-Null
    $deps=[ordered]@{};if($UiVersion){$deps['UiPath.UIAutomation.Activities']="[$UiVersion]"}
    [ordered]@{name=(Split-Path $Path -Leaf);main='Main.xaml';targetFramework='Windows';expressionLanguage='VisualBasic';studioVersion=$Studio;dependencies=$deps}|ConvertTo-Json -Depth 6|Set-Content (Join-Path $Path 'project.json') -Encoding utf8
    Write-Utf8 (Join-Path $Path 'Main.xaml') '<Activity xmlns="http://schemas.microsoft.com/netfx/2009/xaml/activities" />'
}
function New-FakeUip{
    New-Item -ItemType Directory -Force -Path $fakeBin|Out-Null
    Write-Utf8 (Join-Path $fakeBin 'uip.cmd') "@echo off`r`n`"$powerShellHost`" -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"%~dp0fake-uip.ps1`" %*`r`nexit /b %ERRORLEVEL%`r`n"
    Write-Utf8 (Join-Path $fakeBin 'fake-uip.ps1') @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
$line=$Arguments -join '|';if($env:V116_UIP_LOG){Add-Content -LiteralPath $env:V116_UIP_LOG -Value $line}
if($line -eq '--version'){'1.201.0';exit 0}
if($line -like 'rpa|get-errors*'){
 if($env:V116_GET_ERRORS_MODE -eq 'UNKNOWN'){ '{}';exit 0 }
 if($env:V116_GET_ERRORS_MODE -eq 'ERROR'){ '[{"severity":"Error","message":"Document is not a valid value for UIElementType.","filePath":"Main.xaml","activityName":"Use Application/Browser","propertyName":"ElementType"}]';exit 0 }
 '[]';exit 0
}
if($line -like 'rpa|restore*'){
 if($env:V116_RESTORE_MINIMUM){
  $packageDir=Join-Path $Arguments[2] '.local\packages\UiPath.UIAutomation.Activities\26.0.6'
  New-Item -ItemType Directory -Force -Path $packageDir | Out-Null
  '<package><metadata><id>UiPath.UIAutomation.Activities</id><version>26.0.6</version><description>This package requires Studio 27.0 or higher.</description></metadata></package>' | Set-Content (Join-Path $packageDir 'uipath.uiautomation.activities.nuspec') -Encoding UTF8
 }
 exit 0
}
if($line -like 'rpa|validate*'){
 if($env:V116_VALIDATE_MODE -eq 'ERROR'){'{"success":true,"errors":[{"message":"invalid workflow"}]}';exit 0}
 if($env:V116_VALIDATE_MODE -eq 'UNKNOWN'){'{}';exit 0}
 '{"success":true,"errors":[]}';exit 0
}
if($line -like 'rpa|build*'){
 if($env:V116_BUILD_MODE -eq 'FAIL'){'compiler failure';exit 8}
 if($env:V116_BUILD_MODE -eq 'ERROR_ZERO'){'{"Result":"Success","Data":{"HasErrors":true}}';exit 0}
 if($env:V116_BUILD_MODE -eq 'UNKNOWN'){'{}';exit 0}
 '{"Result":"Success","Data":{"HasErrors":false}}';exit 0
}
if($line -like 'rpa|analyze*'){
 if($env:V116_ANALYZE_MODE -eq 'ERROR_ZERO'){'{"Result":"Failure","Message":"Analyzer failure"}';exit 0}
 '{"Result":"Success"}';exit 0
}
if($line -like 'rpa|run|*'){
 if($env:V116_RUN_MODE -eq 'FAIL'){'{"Result":"Failure","Data":{"runResult":"{\"HasErrors\":true,\"ErrorMessage\":\"Runtime failure\"}"}}';exit 0}
 if($env:V116_RUN_MODE -eq 'MALFORMED'){'{"Result":"Success","Data":{"runResult":"not-json"}}';exit 0}
 'Error: workflow log'
 '{"Result":"Success","Data":{"runResult":"{\"HasErrors\":false,\"ErrorMessage\":null,\"DebugState\":null,\"Output\":\"{}\"}"}}';exit 0
}
exit 2
'@
}
try{
    New-Item -ItemType Directory -Force -Path $testRoot|Out-Null;New-FakeUip;$env:PATH="$fakeBin$([IO.Path]::PathSeparator)$originalPath";$env:V116_UIP_LOG=Join-Path $testRoot 'uip.log'
    $native=Join-Path $root 'scripts\Invoke-UiPathNativeDiagnostics.ps1';$compat=Join-Path $root 'scripts\Get-UiPathEnvironmentCompatibility.ps1';$xamlCheck=Join-Path $root 'scripts\Test-UiPathXamlCompatibility.ps1';$enumScript=Join-Path $root 'scripts\Get-UiPathEnumMetadata.ps1';$stateScript=Join-Path $root 'scripts\ExecutionState.ps1';$validationScript=Join-Path $root 'scripts\Validate-RpaProject.ps1'
    $parser=Join-Path $root 'scripts\ConvertFrom-UiPathDiagnostics.ps1'
    foreach($inputCase in @('{"success":true,"errors":[{"code":"E123"}]}','{"success":true,"errors":[{"errorMessage":"Compilation failed"}]}','{"errors":17}','{"diagnostics":"invalid shape"}','{"success":"true"}','{"errorCount":"0"}','{"errors":[null]}')){
        $parsed=& $parser -InputText $inputCase -Json | ConvertFrom-Json
        Assert-True (-not $parsed.contentParsed -or $parsed.errorCount -gt 0) "Unsafe diagnostic accepted: $inputCase"
    }
    foreach($inputCase in @('[]','{"Result":"Success","Data":{"HasErrors":false}}','{"success":true,"errors":[]}','{"diagnostics":[{"severity":"Warning","message":"invalid field example"}]}')){
        $parsed=& $parser -InputText $inputCase -Json | ConvertFrom-Json
        Assert-True ($parsed.contentParsed -and $parsed.errorCount -eq 0) "Valid diagnostic rejected: $inputCase"
    }
    $runVerdict=& $parser -InputText '{"Result":"Success","Data":{"runResult":{"HasErrors":false,"logEntries":[{"Level":"Error","Message":"workflow log"}]}}}' -ResultOnly -Json | ConvertFrom-Json
    Assert-True ($runVerdict.contentParsed -and $runVerdict.errorCount -eq 0) 'Runtime log level incorrectly replaced the official verdict.'
    $serializedRun='{"Result":"Success","Data":{"runResult":"{\"HasErrors\":false,\"DebugState\":null,\"Output\":\"{}\"}"}}'
    $runVerdict=& $parser -InputText ("Error: workflow log`n"+$serializedRun) -ResultOnly -Json | ConvertFrom-Json
    Assert-True ($runVerdict.contentParsed -and $runVerdict.errorCount -eq 0) 'Documented serialized runtime result was rejected or workflow logs replaced the verdict.'
    $runVerdict=& $parser -InputText '{"Result":"Success","Data":{"runResult":"{\"HasErrors\":true}"}}' -ResultOnly -Json | ConvertFrom-Json
    Assert-True ($runVerdict.contentParsed -and $runVerdict.errorCount -gt 0) 'Serialized inner runtime failure was accepted.'
    foreach($badRun in @('not-json','{}','null','[]','{"HasErrors":"false"}','{"HasErrors":false,"DebugState":"Suspended"}','{"HasErrors":false,"DebugState":"Running"}','{"HasErrors":false,"DebugState":"Paused"}')){
        $inputCase=@{Result='Success';Data=@{runResult=$badRun}} | ConvertTo-Json -Depth 4 -Compress
        $runVerdict=& $parser -InputText $inputCase -ResultOnly -Json | ConvertFrom-Json
        Assert-True (-not $runVerdict.contentParsed) "Malformed or unfinished runtime accepted: $badRun"
    }
    $project=Join-Path $testRoot 'generic-web';New-Project $project
    $state=Join-Path $project '.ai\evidence\execution-state.json';& $stateScript -Action Start -TaskType new_bot -TargetBotPath $project -Json|Out-Null;& $stateScript -Action StageEnd -Stage coordinator -TargetBotPath $project -Json|Out-Null;& $stateScript -Action StageStart -Stage developer -TargetBotPath $project -Json|Out-Null

    $env:V116_GET_ERRORS_MODE='PASS';$passPath=Join-Path $project '.ai\evidence\native.json';$accepted=& $native -ProjectPath $project -ChangedWorkflow Main.xaml -UiPathCommand (Join-Path $fakeBin 'uip.cmd') -ExecutionStatePath $state -DependencyFingerprint dep1 -EnvironmentFingerprint env1 -OutputPath $passPath -Json|ConvertFrom-Json
    Assert-True ($accepted.status -eq 'PASS' -and $accepted.getErrorsExecuted -and $accepted.getErrorsErrorCount -eq 0) '1. Valid workflow was not accepted by get-errors.'
    $reused=& $native -ProjectPath $project -ChangedWorkflow Main.xaml -UiPathCommand (Join-Path $fakeBin 'uip.cmd') -ExecutionStatePath $state -DependencyFingerprint dep1 -EnvironmentFingerprint env1 -OutputPath $passPath -Json|ConvertFrom-Json
    Assert-True ($reused.status -eq 'PASS' -and -not $reused.getErrorsExecuted -and $reused.getErrorsReuse -eq 1) 'Safe unchanged native-validation reuse failed.'

    $errorPath=Join-Path $project '.ai\evidence\native-error.json';$env:V116_GET_ERRORS_MODE='ERROR';$diagnosed=& $native -ProjectPath $project -ChangedWorkflow Main.xaml -UiPathCommand (Join-Path $fakeBin 'uip.cmd') -ExecutionStatePath $state -DependencyFingerprint dep2 -EnvironmentFingerprint env1 -OutputPath $errorPath -Json|ConvertFrom-Json
    Assert-True ($diagnosed.status -eq 'FAIL' -and $diagnosed.getErrorsErrorCount -eq 1 -and $diagnosed.workflows[0].exitCode -eq 0 -and $diagnosed.workflows[0].diagnostics[0].property -eq 'ElementType') '2-3. Diagnostics content was not parsed independently of successful exit.'
    $beforeLines=@(Get-Content $env:V116_UIP_LOG|Where-Object {$_ -like 'rpa|get-errors*'}).Count
    $duplicate=& $native -ProjectPath $project -ChangedWorkflow Main.xaml -UiPathCommand (Join-Path $fakeBin 'uip.cmd') -ExecutionStatePath $state -DependencyFingerprint dep2 -EnvironmentFingerprint env1 -OutputPath $errorPath -Json|ConvertFrom-Json
    $afterLines=@(Get-Content $env:V116_UIP_LOG|Where-Object {$_ -like 'rpa|get-errors*'}).Count
    Assert-True ($duplicate.status -eq 'BLOCKED' -and $duplicate.getErrorsReason -eq 'UNCHANGED_XAML_REPEATED_DIAGNOSTIC' -and $beforeLines -eq $afterLines) '9-10. Unchanged repeated diagnostics were not bounded.'
    $dependencyChanged=& $native -ProjectPath $project -ChangedWorkflow Main.xaml -UiPathCommand (Join-Path $fakeBin 'uip.cmd') -ExecutionStatePath $state -DependencyFingerprint dep3 -EnvironmentFingerprint env1 -OutputPath $errorPath -Json|ConvertFrom-Json
    $afterDependencyChange=@(Get-Content $env:V116_UIP_LOG|Where-Object {$_ -like 'rpa|get-errors*'}).Count
    Assert-True ($dependencyChanged.status -eq 'FAIL' -and $dependencyChanged.getErrorsExecuted -and $afterDependencyChange -eq ($afterLines + 1)) 'Safe reuse incorrectly survived a dependency-fingerprint change.'
    Add-Content (Join-Path $project 'Main.xaml') '<!-- meaningful repair -->';$env:V116_GET_ERRORS_MODE='PASS'
    $repaired=& $native -ProjectPath $project -ChangedWorkflow Main.xaml -UiPathCommand (Join-Path $fakeBin 'uip.cmd') -ExecutionStatePath $state -DependencyFingerprint dep2 -EnvironmentFingerprint env1 -OutputPath $errorPath -Json|ConvertFrom-Json
    Assert-True ($repaired.status -eq 'PASS' -and $repaired.getErrorsRepairCount -eq 1) "9. Targeted Developer repair cycle was not recorded: $($repaired|ConvertTo-Json -Depth 6 -Compress)"
    $env:V116_GET_ERRORS_MODE='UNKNOWN'
    $unknownNative=& $native -ProjectPath $project -ChangedWorkflow Main.xaml -UiPathCommand (Join-Path $fakeBin 'uip.cmd') -OutputPath '.ai\evidence\unknown-native.json' -Json | ConvertFrom-Json
    Assert-True ($unknownNative.status -eq 'BLOCKED') 'Unparsed required get-errors output was accepted.'
    $env:V116_GET_ERRORS_MODE='PASS'
    $retryNative=& $native -ProjectPath $project -ChangedWorkflow Main.xaml -UiPathCommand (Join-Path $fakeBin 'uip.cmd') -OutputPath '.ai\evidence\unknown-native.json' -Json | ConvertFrom-Json
    Assert-True ($retryNative.status -eq 'PASS' -and $retryNative.getErrorsExecuted) 'Unknown diagnostic result was incorrectly cached as clean.'
    $identity=& $compat -ProjectPath $project -CliVersion '1.201.0' -CliPath (Join-Path $fakeBin 'uip.cmd') -Json | ConvertFrom-Json
    Assert-True ($identity.toolchainEvidence.cli.resolvedPath -eq (Join-Path $fakeBin 'uip.cmd') -and $identity.toolchainEvidence.requiredEvidence.status -eq 'PASS') 'Actual CLI identity was not used.'
    $missingUi=& $compat -ProjectPath $project -CliVersion '1.201.0' -CliPath (Join-Path $fakeBin 'uip.cmd') -RequiredCapability ui.authoring -Json | ConvertFrom-Json
    Assert-True ($missingUi.toolchainEvidence.requiredEvidence.status -eq 'BLOCKED') 'Required unknown UI documentation was accepted.'

    $enumProject=Join-Path $testRoot 'enum-generic';New-Project $enumProject '25.10.5'
    Write-Utf8 (Join-Path $enumProject 'Invalid.xaml') '<Activity xmlns="http://schemas.microsoft.com/netfx/2009/xaml/activities"><UseApp ElementType="Document" role="Link" domRole="link" /></Activity>'
    $environment=& $compat -ProjectPath $enumProject -StudioVersion '25.10.16' -RobotVersion '25.10.8' -CliVersion '1.201.0' -AvailableUiAutomationVersion '25.10.5' -Json|ConvertFrom-Json
    $omitted=& $xamlCheck -ProjectPath $enumProject -Workflow Invalid.xaml -EnvironmentJson ($environment|ConvertTo-Json -Depth 10 -Compress) -ResolvedUiElementTypeValue @('Default','Button','Edit') -OmitUnsupportedOptionalProperty -Json|ConvertFrom-Json
    $fixedText=Get-Content -Raw (Join-Path $enumProject 'Invalid.xaml')
    Assert-True ($omitted.status -eq 'PASS' -and $omitted.workflows[0].optionalPropertiesOmitted[0].invalidValue -eq 'Document' -and $fixedText -notmatch 'ElementType=' -and $fixedText -match 'role="Link"' -and $fixedText -match 'domRole="link"') '11,14,16-17. Optional invalid enum omission or semantic/DOM separation failed.'
    Write-Utf8 (Join-Path $enumProject 'Invalid.xaml') '<Activity xmlns="http://schemas.microsoft.com/netfx/2009/xaml/activities"><UseApp ElementType="Link" /></Activity>'
    $blocked=& $xamlCheck -ProjectPath $enumProject -Workflow Invalid.xaml -EnvironmentJson ($environment|ConvertTo-Json -Depth 10 -Compress) -ResolvedUiElementTypeValue @('Default','Button') -Json|ConvertFrom-Json
    Assert-True ($blocked.status -eq 'BLOCKED' -and $blocked.issues[0].classification -eq 'UIPATH_XAML_ENUM_INCOMPATIBLE' -and $blocked.issues[0].invalidValue -eq 'Link') '12,15. Required/non-omitted invalid enum was not blocked.'
    Write-Utf8 (Join-Path $enumProject 'Valid.xaml') '<Activity xmlns="http://schemas.microsoft.com/netfx/2009/xaml/activities"><UseApp ElementType="Button" /></Activity>'
    $validEnum=& $xamlCheck -ProjectPath $enumProject -Workflow Valid.xaml -EnvironmentJson ($environment|ConvertTo-Json -Depth 10 -Compress) -ResolvedUiElementTypeValue @('Default','Button') -Json|ConvertFrom-Json
    Assert-True ($validEnum.status -eq 'PASS' -and -not $validEnum.workflows[0].changed) '13. Supported enum value was not preserved.'
    $requiredPolicy=Join-Path $testRoot 'required-policy.json';Write-Utf8 $requiredPolicy '{"schemaVersion":1,"policyVersion":"test","enumProperties":[{"property":"ElementType","enumType":"UIElementType","optional":false}]}'
    $requiredBlocked=& $xamlCheck -ProjectPath $enumProject -Workflow Invalid.xaml -EnvironmentJson ($environment|ConvertTo-Json -Depth 10 -Compress) -PolicyPath $requiredPolicy -ResolvedUiElementTypeValue @('Default','Button') -OmitUnsupportedOptionalProperty -Json|ConvertFrom-Json
    Assert-True ($requiredBlocked.status -eq 'BLOCKED' -and $requiredBlocked.issues[0].optional -eq $false) '15. Required invalid enum did not block generation.'

    $assembly=Join-Path $testRoot 'EnumFixture.dll';Add-Type -TypeDefinition 'public enum UIElementType { Default, Button, Edit }' -Language CSharp -OutputAssembly $assembly
    $enumCache=Join-Path $testRoot 'enum-cache';$reflected=& $enumScript -ProjectPath $enumProject -PackageVersion '25.10.5' -AssemblyPath $assembly -CacheDirectory $enumCache -Json|ConvertFrom-Json;$cached=& $enumScript -ProjectPath $enumProject -PackageVersion '25.10.5' -AssemblyPath $assembly -CacheDirectory $enumCache -Json|ConvertFrom-Json;$unavailable=& $enumScript -ProjectPath $enumProject -PackageVersion '25.10.5' -AssemblyPath (Join-Path $testRoot 'missing.dll') -CacheDirectory (Join-Path $testRoot 'enum-missing') -Json|ConvertFrom-Json
    Assert-True ($reflected.status -eq 'RESOLVED' -and $reflected.values -contains 'Button' -and $cached.cacheStatus -eq 'HIT' -and $unavailable.status -eq 'UNAVAILABLE') '18-20. Enum reflection, unavailable path, or cache fingerprint failed.'

    $same=& $compat -ProjectPath $enumProject -StudioVersion '25.10.16' -RobotVersion '25.10.8' -CliVersion '1.201.0' -AvailableUiAutomationVersion @('25.10.5','26.10.3') -Json|ConvertFrom-Json
    $mismatchProject=Join-Path $testRoot 'existing-mismatch';New-Project $mismatchProject '26.10.3';$mismatch=& $compat -ProjectPath $mismatchProject -StudioVersion '25.10.16' -RobotVersion '25.10.8' -CliVersion '1.201.0' -AvailableUiAutomationVersion @('25.10.5','26.10.3') -RequiredCapability semantic -Json|ConvertFrom-Json
    $newProject=Join-Path $testRoot 'new-compatible';New-Project $newProject '';$selected=& $compat -ProjectPath $newProject -ProjectKind New -StudioVersion '25.10.16' -AvailableUiAutomationVersion @('26.10.3','25.10.9') -Json|ConvertFrom-Json
    $unknown=& $compat -ProjectPath $enumProject -StudioVersion 'UNKNOWN' -Json|ConvertFrom-Json
    Assert-True ($same.compatibilityDecision -eq 'PRESERVE_COMPATIBLE_EXISTING' -and $same.selectedUiAutomationVersion -eq '25.10.5') '21,23,25. Compatible pinned package was not preserved.'
    Assert-True ($mismatch.compatibilityDecision -eq 'INCOMPATIBLE_RELEASE_TRAIN' -and -not $mismatch.automaticPackageUpgrade -and $mismatch.capabilityFallbackRequired) '22,26-27,29. Incompatible release train did not choose conservative capability fallback.'
    Assert-True ($selected.selectedUiAutomationVersion -eq '25.10.9' -and $selected.compatibilityDecision -eq 'SELECT_COMPATIBLE_RELEASE_LINE') '23. New-project same-release-line selection failed.'
    Assert-True ($unknown.detectedStudioVersion -eq 'UNKNOWN' -and $unknown.compatibilityDecision -eq 'PRESERVE_EXISTING_UNKNOWN_ENVIRONMENT' -and $unknown.compatibilityEvidence) '24,28,30. Unknown environment decision was not conservative/evidenced.'

    $minimumProject=Join-Path $testRoot 'restore-minimum';New-Project $minimumProject '26.0.6'
    $isolatedScripts=Join-Path $testRoot 'minimum-scripts'
    Copy-Item (Join-Path $root 'scripts') $isolatedScripts -Recurse
    Copy-Item (Join-Path $root 'validation') (Join-Path $testRoot 'validation') -Recurse
    Write-Utf8 (Join-Path $isolatedScripts 'Get-UiPathEnvironmentCompatibility.ps1') @'
param($ProjectPath,$ProjectKind,$CliVersion,$CliPath,[string[]]$RequiredCapability,[switch]$Json)
Import-Module (Join-Path $PSScriptRoot 'UiPathCompatibility.psm1') -Force
Get-UiPathEnvironmentCompatibility -ProjectPath $ProjectPath -ProjectKind $ProjectKind -CliVersion $CliVersion -CliPath $CliPath -RequiredCapability $RequiredCapability -StudioVersion '26.0.204.0' | ConvertTo-Json -Depth 12
'@
    $minimumSummary=Join-Path $minimumProject '.ai\evidence\minimum.json'
    $env:V116_RESTORE_MINIMUM='true'
    $minimumDenied=$false
    try{& (Join-Path $isolatedScripts 'Validate-RpaProject.ps1') -ProjectPath $minimumProject -ChangedWorkflow Main.xaml -ReuseManagedIntegrity -ValidationSummaryPath $minimumSummary | Out-Null}catch{$minimumDenied=$true}
    Remove-Item Env:V116_RESTORE_MINIMUM
    $minimumData=Get-Content -LiteralPath $minimumSummary -Raw | ConvertFrom-Json
    Assert-True ($minimumDenied -and $minimumData.package_compatibility.status -eq 'BLOCKED' -and $minimumData.package_compatibility.decision -eq 'INCOMPATIBLE_STUDIO_MINIMUM' -and -not $minimumData.delivery.deliveryReady -and -not $minimumData.build.buildExecuted) 'Restore-discovered unmet minimum did not block delivery before build.'

    $buildProject=Join-Path $testRoot 'non-ui-build';New-Project $buildProject '' 'UNKNOWN';$buildState=Join-Path $buildProject '.ai\evidence\execution-state.json';& $stateScript -Action Start -TaskType new_bot -TargetBotPath $buildProject -Json|Out-Null;& $stateScript -Action StageEnd -Stage coordinator -TargetBotPath $buildProject -Json|Out-Null
    $env:V116_BUILD_MODE='PASS';$buildPass=Join-Path $buildProject '.ai\evidence\pass.json';& $validationScript -ProjectPath $buildProject -RunDiagnostics -ChangedWorkflow Main.xaml -ProjectKind New -ReuseManagedIntegrity -ExecutionStatePath $buildState -ValidationSummaryPath $buildPass|Out-Null;$buildPassData=Get-Content -Raw $buildPass|ConvertFrom-Json
    Assert-True ($buildPassData.build.status -eq 'PASS' -and $buildPassData.delivery.buildExecuted -and $buildPassData.delivery.deliveryReady) '4. Project build PASS did not make delivery ready.'
    $commands=@(Get-Content $env:V116_UIP_LOG)
    $restoreIndex=[Array]::FindLastIndex($commands,[Predicate[object]]{param($x)$x -like 'rpa|restore*'})
    $validateIndex=[Array]::FindLastIndex($commands,[Predicate[object]]{param($x)$x -like 'rpa|validate*'})
    $buildIndex=[Array]::FindLastIndex($commands,[Predicate[object]]{param($x)$x -like 'rpa|build*'})
    Assert-True ($restoreIndex -lt $validateIndex -and $validateIndex -lt $buildIndex -and $buildPassData.workflow_validate.status -eq 'PASS') 'Restore -> per-file validate -> build ordering failed.'
    $runPath=Join-Path $buildProject '.ai\evidence\runtime.json'
    & $validationScript -ProjectPath $buildProject -RunDiagnostics -ChangedWorkflow Main.xaml -RunFile Main.xaml -ReuseManagedIntegrity -ExecutionStatePath $buildState -ValidationSummaryPath $runPath | Out-Null
    $runtime=Get-Content -Raw $runPath | ConvertFrom-Json
    Assert-True ($runtime.tests.status -eq 'PASS' -and $runtime.delivery.deliveryReady) 'Workflow Error logs incorrectly failed runtime validation.'
    $runLine=Get-Content $env:V116_UIP_LOG | Where-Object {$_ -like 'rpa|run|*'} | Select-Object -Last 1
    Assert-True ($runLine -like '*--file-path|Main.xaml|--skip-build|--output|json*') 'Runtime did not use the supported command with a relative workflow path.'
    $env:V116_RUN_MODE='FAIL'
    try{& $validationScript -ProjectPath $buildProject -RunDiagnostics -ChangedWorkflow Main.xaml -RunFile Main.xaml -ReuseManagedIntegrity -ExecutionStatePath $buildState -ValidationSummaryPath $runPath | Out-Null}catch{}
    $runtime=Get-Content -Raw $runPath | ConvertFrom-Json
    Assert-True ($runtime.tests.status -eq 'FAIL' -and -not $runtime.delivery.deliveryReady) 'Exit-zero runtime failure was accepted.'
    $env:V116_RUN_MODE='MALFORMED'
    try{& $validationScript -ProjectPath $buildProject -RunDiagnostics -ChangedWorkflow Main.xaml -RunFile Main.xaml -ReuseManagedIntegrity -ExecutionStatePath $buildState -ValidationSummaryPath $runPath | Out-Null}catch{}
    $runtime=Get-Content -Raw $runPath | ConvertFrom-Json
    Assert-True ($runtime.tests.status -eq 'BLOCKED' -and -not $runtime.delivery.deliveryReady) 'Malformed serialized runtime allowed delivery.'
    $env:V116_RUN_MODE='PASS'
    $qaPath=Join-Path $buildProject '.ai\evidence\qa-incomplete.json'
    & $validationScript -ProjectPath $buildProject -RunDiagnostics -ChangedWorkflow Main.xaml -ReuseManagedIntegrity -ExecutionStatePath $buildState -ValidationSummaryPath $qaPath -OutputQaRequired | Out-Null
    $qa=Get-Content $qaPath -Raw|ConvertFrom-Json
    Assert-True (-not $qa.delivery.deliveryReady -and $qa.build.status -in @('PASS','REUSED')) 'Incomplete output QA incorrectly allowed delivery.'
    $env:V116_VALIDATE_MODE='ERROR';Add-Content (Join-Path $buildProject 'Main.xaml') '<!-- validate failure -->'
    $vfail=Join-Path $buildProject '.ai\evidence\validate-fail.json'
    try{& $validationScript -ProjectPath $buildProject -RunDiagnostics -ChangedWorkflow Main.xaml -ReuseManagedIntegrity -ExecutionStatePath $buildState -ValidationSummaryPath $vfail | Out-Null}catch{}
    $vf=Get-Content $vfail -Raw|ConvertFrom-Json
    Assert-True ($vf.workflow_validate.status -eq 'FAIL' -and $vf.build.status -eq 'NOT_RUN' -and -not $vf.delivery.deliveryReady) 'Exit-zero validate errors were erased by build/delivery.'
    $env:V116_VALIDATE_MODE='UNKNOWN';Add-Content (Join-Path $buildProject 'Main.xaml') '<!-- unparseable validation -->'
    $unknownPath=Join-Path $buildProject '.ai\evidence\validate-unknown.json'
    try{& $validationScript -ProjectPath $buildProject -RunDiagnostics -ChangedWorkflow Main.xaml -ReuseManagedIntegrity -ExecutionStatePath $buildState -ValidationSummaryPath $unknownPath | Out-Null}catch{}
    $uv=Get-Content $unknownPath -Raw|ConvertFrom-Json
    Assert-True ($uv.workflow_validate.status -eq 'BLOCKED' -and -not $uv.delivery.deliveryReady) 'Unrecognized validate envelope allowed delivery.'
    Remove-Item Env:V116_VALIDATE_MODE -ErrorAction SilentlyContinue
    Add-Content (Join-Path $buildProject 'Main.xaml') '<!-- change -->';$env:V116_BUILD_MODE='FAIL';$buildFail=Join-Path $buildProject '.ai\evidence\fail.json';$failed=$false;try{& $validationScript -ProjectPath $buildProject -RunDiagnostics -ChangedWorkflow Main.xaml -ProjectKind New -ReuseManagedIntegrity -ExecutionStatePath $buildState -ValidationSummaryPath $buildFail 2>$null|Out-Null}catch{$failed=$true};$buildFailData=Get-Content -Raw $buildFail|ConvertFrom-Json
    Assert-True ($failed -and $buildFailData.build.status -eq 'FAIL' -and -not $buildFailData.delivery.deliveryReady) '5. Project build failure did not block delivery.'
    foreach($mode in @('ERROR_ZERO','UNKNOWN')){
        $env:V116_BUILD_MODE=$mode
        Add-Content (Join-Path $buildProject 'Main.xaml') "<!-- build $mode -->"
        $gatePath=Join-Path $buildProject ".ai\evidence\build-$mode.json"
        try{& $validationScript -ProjectPath $buildProject -RunDiagnostics -ChangedWorkflow Main.xaml -ReuseManagedIntegrity -ExecutionStatePath $buildState -ValidationSummaryPath $gatePath | Out-Null}catch{}
        $gate=Get-Content -Raw $gatePath | ConvertFrom-Json
        Assert-True ($gate.build.status -in @('FAIL','BLOCKED') -and -not $gate.delivery.deliveryReady) "Exit-zero build $mode was accepted."
    }
    $env:V116_BUILD_MODE='PASS';$env:V116_ANALYZE_MODE='ERROR_ZERO'
    $gov=Join-Path $buildProject 'governance.json';Write-Utf8 $gov '{}'
    $analyzerPath=Join-Path $buildProject '.ai\evidence\analyzer-zero.json'
    try{& $validationScript -ProjectPath $buildProject -RunDiagnostics -ChangedWorkflow Main.xaml -ReuseManagedIntegrity -GovernanceFilePath $gov -ExecutionStatePath $buildState -ValidationSummaryPath $analyzerPath | Out-Null}catch{}
    $analyzer=Get-Content -Raw $analyzerPath | ConvertFrom-Json
    Assert-True ($analyzer.analyzer.status -eq 'FAIL' -and -not $analyzer.delivery.deliveryReady) 'Exit-zero analyzer failure was accepted.'

    $limitProject=Join-Path $testRoot 'limit';New-Project $limitProject;$limitState=Join-Path $limitProject '.ai\evidence\execution-state.json';& $stateScript -Action Start -TaskType modification -TargetBotPath $limitProject -NowUtc '2026-09-11T10:00:00Z' -Json|Out-Null
    $limitStatus=& $stateScript -Action Status -TargetBotPath $limitProject -NowUtc '2026-09-11T12:00:00Z' -Json|ConvertFrom-Json
    Assert-True ($limitStatus.validation.validationRequired -and -not $limitStatus.validation.deliveryReady -and -not $limitStatus.validation.blockedReason -and $null -eq $limitStatus.execution.hard_limit_reached) '7. Long-running execution was blocked by a time budget.'
    $partialState=[ordered]@{validationRequired=$true;validationCompleted=$false;diagnosticsExecuted=$true;buildExecuted=$false;buildSucceeded=$false;deliveryReady=$false;blockedReason='REQUIRED_BUILD_NOT_EXECUTED'}|ConvertTo-Json -Compress;& $stateScript -Action ValidationState -TargetBotPath $limitProject -ValidationStateJson $partialState -NowUtc '2026-09-11T12:00:00Z' -Json|Out-Null;$afterPartial=& $stateScript -Action Read -TargetBotPath $limitProject -NowUtc '2026-09-11T12:00:00Z' -Json|ConvertFrom-Json
    Assert-True ($afterPartial.validation.diagnosticsExecuted -and -not $afterPartial.validation.buildExecuted -and $afterPartial.validation.blockedReason -eq 'REQUIRED_BUILD_NOT_EXECUTED') '6,8. Required build not executed state was not preserved.'
    Write-Host '[PASS] UiPath-native validation, enum safety, and package compatibility tests'
}finally{$env:PATH=$originalPath;Remove-Item Env:V116_GET_ERRORS_MODE,Env:V116_BUILD_MODE -ErrorAction SilentlyContinue;if($env:V116_UIP_LOG){Remove-Item Env:V116_UIP_LOG -ErrorAction SilentlyContinue};Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue}
