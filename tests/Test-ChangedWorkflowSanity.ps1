[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script = Join-Path $root 'scripts\Test-ChangedWorkflowSanity.ps1'
$testRoot = Join-Path $env:TEMP ('rpa-changed-workflow-tests-' + [guid]::NewGuid().ToString('N'))

function Assert-True { param([bool]$Condition,[string]$Message); if (-not $Condition) { throw $Message } }
function Write-Utf8 { param([string]$Path,[string]$Text); New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null; [System.IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($false))) }

try {
    New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
    Write-Utf8 (Join-Path $testRoot 'Child.xaml') '<Activity xmlns="urn:test"><LogMessage /></Activity>'
    Write-Utf8 (Join-Path $testRoot 'Main.xaml') '<Activity xmlns="urn:test" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"><x:Members><x:Property Name="in_Id" Type="InArgument(x:String)" /></x:Members><Sequence><InvokeWorkflowFile WorkflowFileName="Child.xaml" /><AddQueueItem /></Sequence></Activity>'
    $pass = & $script -ProjectPath $testRoot -ChangedFiles @('Main.xaml') -ExpectedActivityLocalNames @('AddQueueItem') -Json | ConvertFrom-Json
    Assert-True ($pass.status -eq 'PASS' -and $pass.changedWorkflowCount -eq 1 -and $pass.workflows[0].staticInvokes -contains 'Child.xaml') 'Changed workflow sanity did not validate a correct workflow.'

    Write-Utf8 (Join-Path $testRoot 'Broken.xaml') '<Activity><Sequence>'
    $broken = & $script -ProjectPath $testRoot -ChangedFiles @('Broken.xaml') -Json | ConvertFrom-Json
    Assert-True ($broken.status -eq 'FAIL' -and $broken.errors[0].code -eq 'MALFORMED_XAML') 'Malformed changed workflow was not rejected.'

    Write-Utf8 (Join-Path $testRoot 'MissingInvoke.xaml') '<Activity xmlns="urn:test"><InvokeWorkflowFile WorkflowFileName="Missing.xaml" /></Activity>'
    $missing = & $script -ProjectPath $testRoot -ChangedFiles @('MissingInvoke.xaml') -Json | ConvertFrom-Json
    Assert-True ($missing.status -eq 'FAIL' -and @($missing.errors | Where-Object code -eq 'MISSING_INVOKED_WORKFLOW').Count -eq 1) 'Missing static invoke target was not rejected.'

    $expected = & $script -ProjectPath $testRoot -ChangedFiles @('Main.xaml') -ExpectedActivityLocalNames @('TypeInto') -Json | ConvertFrom-Json
    Assert-True ($expected.status -eq 'FAIL' -and @($expected.errors | Where-Object code -eq 'EXPECTED_ACTIVITY_MISSING').Count -eq 1) 'Expected activity verification did not fail when absent.'

    Write-Utf8 (Join-Path $testRoot 'UiBlocking.xaml') @'
<Activity xmlns="urn:test" xmlns:ui="urn:ui"><Sequence>
  <ui:Click DisplayName="Submit" ContinueOnError="True"><ui:Click.Target><ui:Target Selector="&lt;webctrl id='submit' /&gt;" /></ui:Click.Target></ui:Click>
  <ui:Click DisplayName="Blind"><ui:Click.CursorPosition><ui:CursorPosition OffsetX="120" OffsetY="40" /></ui:Click.CursorPosition></ui:Click>
  <ui:TypeInto DisplayName="Name" EmptyField="True"><ui:TypeInto.Target><ui:Target Selector="&lt;wnd app='notepad.exe' pid='4312' /&gt;" /></ui:TypeInto.Target></ui:TypeInto>
  <ui:ElementExists />
</Sequence></Activity>
'@
    $blocking = & $script -ProjectPath $testRoot -ChangedFiles @('UiBlocking.xaml') -Json | ConvertFrom-Json
    $blockingCodes = @($blocking.errors | ForEach-Object code)
    Assert-True ($blocking.status -eq 'FAIL' -and $blockingCodes -contains 'UI_CONTINUE_ON_ERROR' -and $blockingCodes -contains 'UI_COORDINATE_ONLY' -and $blockingCodes -contains 'UI_VOLATILE_SELECTOR') "UI anti-patterns were not blocked: $($blockingCodes -join ',')"

    Write-Utf8 (Join-Path $testRoot 'UiWarnings.xaml') @'
<Activity xmlns="urn:test" xmlns:ui="urn:ui"><Sequence>
  <ui:TypeInto DisplayName="Invoice" TimeoutMS="1000"><ui:TypeInto.Target><ui:Target Selector="&lt;html title='Invoice 12345' /&gt;&lt;webctrl tag='INPUT' idx='3' /&gt;" /></ui:TypeInto.Target></ui:TypeInto>
  <Delay Duration="00:00:05" />
</Sequence></Activity>
'@
    $warned = & $script -ProjectPath $testRoot -ChangedFiles @('UiWarnings.xaml') -Json | ConvertFrom-Json
    $warningCodes = @($warned.warnings | ForEach-Object code)
    foreach ($code in @('UI_TYPE_WITHOUT_CLEAR','UI_SELECTOR_IDX','UI_DYNAMIC_TITLE','UI_TIMEOUT_EXTREME','UI_FIXED_DELAY','UI_NO_STATE_VERIFICATION')) {
        Assert-True ($warningCodes -contains $code) "UI robustness warning $code was not reported: $($warningCodes -join ',')"
    }
    Assert-True ($warned.status -eq 'PASS') 'UI robustness warnings must not block delivery.'

    Write-Utf8 (Join-Path $testRoot 'UiGood.xaml') @'
<Activity xmlns="urn:test" xmlns:uix="urn:uix"><Sequence>
  <uix:NTypeInto DisplayName="Name" EmptyFieldMode="SingleLine" Timeout="30"><uix:NTypeInto.Target><uix:TargetAnchorable FullSelectorArgument="&lt;webctrl id='customer-name' /&gt;" /></uix:NTypeInto.Target></uix:NTypeInto>
  <uix:NCheckState DisplayName="Saved" />
</Sequence></Activity>
'@
    $good = & $script -ProjectPath $testRoot -ChangedFiles @('UiGood.xaml') -Json | ConvertFrom-Json
    Assert-True ($good.status -eq 'PASS' -and @($good.warnings | Where-Object { $_.code -like 'UI_*' }).Count -eq 0) "Robust UI workflow produced findings: $(@($good.warnings | ForEach-Object code) -join ',')"
    $cli = & (Join-Path $root 'scripts\Test-UiWorkflowRobustness.ps1') -ProjectPath $testRoot -ChangedFiles @('UiBlocking.xaml','UiGood.xaml') -Json | ConvertFrom-Json
    Assert-True ($cli.status -eq 'FAIL' -and @($cli.workflows).Count -eq 2) 'Standalone UI robustness scan did not report blocking findings.'

    Write-Host '[PASS] Changed-workflow structural sanity tests'
}
finally { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
