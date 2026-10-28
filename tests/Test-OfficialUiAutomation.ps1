[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) ('devkit-uia-' + [guid]::NewGuid().ToString('N'))
$saved = @{ LOCALAPPDATA = $env:LOCALAPPDATA; APPDATA = $env:APPDATA; USERPROFILE = $env:USERPROFILE; UIA_MOCK_MODE = $env:UIA_MOCK_MODE; UIA_HELP_FIXTURE = $env:UIA_HELP_FIXTURE; UIA_NESTED_FIXTURE = $env:UIA_NESTED_FIXTURE; UIA_NESTED = $env:UIA_NESTED; UIA_ARGS_LOG = $env:UIA_ARGS_LOG; UIA_HELP_LOG = $env:UIA_HELP_LOG; UIA_ACTUAL_DIR = $env:UIA_ACTUAL_DIR }
$checks = 0
function Assert-True($condition, $message) {
    if (-not $condition) { throw $message }
    $script:checks++
}
try {
    New-Item -ItemType Directory -Path "$temp/RpaAiDevKit/tools/npm" -Force | Out-Null
    $env:LOCALAPPDATA = $temp; $env:APPDATA = $temp; $env:USERPROFILE = $temp
    $env:UIA_HELP_FIXTURE = Join-Path $PSScriptRoot 'fixtures/uia-help/captures.json'
    $env:UIA_NESTED_FIXTURE = Join-Path $PSScriptRoot 'fixtures/uia-help/nested.json'
    # Test double only; derived fixture inputs are not live discovery evidence.
    $fake = @'
if ($args -contains '--help') {
    if ($env:UIA_MOCK_MODE -eq 'badhelp') { 'unknown'; exit 0 }
    $helpIndex = [array]::IndexOf($args, '--help')
    $key = if ($helpIndex -gt 2) { ($args[2..($helpIndex - 1)]) -join ' ' } else { '' }
    if ($env:UIA_HELP_LOG) { Add-Content -LiteralPath $env:UIA_HELP_LOG -Value $key }
    if ($env:UIA_ACTUAL_DIR) {
        $map = @{ ''='uia.json'; 'target-app'='target-app.json'; 'target-app resolve-defaults'='resolve-defaults.json'; 'snapshot'='snapshot.json'; 'snapshot capture'='snapshot-capture.json' }
        if ($map.ContainsKey($key)) {
            [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding
            [Console]::Write([IO.File]::ReadAllText((Join-Path $env:UIA_ACTUAL_DIR $map[$key]), [Text.Encoding]::UTF8))
            exit 0
        }
    }
    $nested = (Get-Content -LiteralPath $env:UIA_NESTED_FIXTURE -Raw -Encoding UTF8 | ConvertFrom-Json).help
    if ($key -and $nested.PSObject.Properties.Name -contains $key -and ($key -ne 'snapshot' -or $env:UIA_NESTED -eq '1')) {
        $fixtures = Get-Content -LiteralPath $env:UIA_HELP_FIXTURE -Raw -Encoding UTF8 | ConvertFrom-Json
        $data = $nested.$key
        switch ($env:UIA_MOCK_MODE) {
            'nested-root-fallback' { $data = $fixtures.derived.'parent-json' | ConvertFrom-Json }
            'nested-wrong-path' { if ($key -like '* *') { $data.Data.Usage = 'uip rpa uia ' + $data.Data.Command + ' [options]' } }
            'nested-wrong-command' { if ($key -like '* *') { $data.Data.Command = ($key -split ' ')[0] } }
            'nested-malformed' { if ($key -like '* *') { '{"Result":'; exit 0 } }
            'nested-empty' { if ($key -like '* *') { exit 0 } }
            'nested-failure' { if ($key -like '* *') { exit 4 } }
        }
        $data | ConvertTo-Json -Depth 12
        exit 0
    }
    $fixtures = Get-Content -LiteralPath $env:UIA_HELP_FIXTURE -Raw -Encoding UTF8 | ConvertFrom-Json
    $name = if (-not $key) { 'parent' } else { 'snapshot' }
    $mode = $env:UIA_MOCK_MODE
    if ($mode -like 'raw-*') {
        $capture = $fixtures.raw.($mode.Substring(4))
        $capture.output
        if ($capture.error) { [Console]::Error.WriteLine($capture.error) }
        exit $capture.exitCode
    }
    if ($mode -in @('table','text','ansi')) {
        $text = $fixtures.derived.("$name-table")
        if ($mode -eq 'text') { $text = $text -replace '[\u2500-\u257f]', '' }
        if ($mode -eq 'ansi') { $text = [char]27 + '[32m' + $text + [char]27 + '[0m' }
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding
        [Console]::WriteLine($text)
        exit 0
    }
    $data = $fixtures.derived.("$name-json") | ConvertFrom-Json
    switch ($mode) {
        'malformed' { '{"Result":'; exit 0 }
        'array-envelope' { '[]'; exit 0 }
        'wrong-result' { $data.Result = 'Failure' }
        'wrong-code' { $data.Code = 'Other' }
        'wrong-command' { $data.Data.Command = 'other' }
        'wrong-path' { $data.Data.Usage = 'uip other uia snapshot [options]' }
        'parent-child' { $data = $fixtures.derived.'parent-json' | ConvertFrom-Json }
        'missing-commands' { $data.Data.PSObject.Properties.Remove('Subcommands') }
        'empty-commands' { $data.Data.Subcommands = @() }
        'scalar-commands' { $data.Data.Subcommands = 'snapshot' }
        'scalar-options' { $data.Data.Options = '--project-dir' }
        'invalid-option' { $data.Data.Options = @(@{Flags='--project-dir in prose';Description='invalid'}) }
        'scalar-global' { $data.Data.GlobalOptions = $null }
        'invalid-argument' { $data.Data.Arguments = @('bad') }
        'prose-option' { $data.Data.Description += ' --invented'; $data.Data.Options[0].Description += ' --invented' }
        'stderr' { [Console]::Error.WriteLine('failure') }
    }
    $data | ConvertTo-Json -Depth 12
    if ($mode -eq 'help-failure') { exit 3 }
    exit 0
}
if ($env:UIA_ARGS_LOG) { ConvertTo-Json -InputObject @($args) -Compress | Set-Content -LiteralPath $env:UIA_ARGS_LOG -Encoding UTF8 }
switch ($env:UIA_MOCK_MODE) {
    'empty' { exit 0 }
    'error' { '{"success":false,"error":"mock failure"}'; exit 0 }
    'failure' { exit 3 }
    default { '{"mockControlOnly":true,"artifact":"not-live-proof"}'; exit 0 }
}
'@
    [IO.File]::WriteAllText("$temp/RpaAiDevKit/tools/npm/uip.ps1", $fake)
    $hostPath = (Get-Process -Id $PID).Path
    [IO.File]::WriteAllText("$temp/RpaAiDevKit/tools/npm/uip.cmd", "@echo off`r`n`"$hostPath`" -NoProfile -ExecutionPolicy Bypass -File `"%~dp0uip.ps1`" %*`r`n")
    $skill = Join-Path $temp 'SKILL.md'
    [IO.File]::WriteAllText($skill, '## UIA Prerequisites' + "`n" + '**Required package:** minimum **`26.10.2`**')
    $parameters = @{TargetBotPath=$temp; SkillPath=$skill; Json=$true; TimeoutSeconds=5}
    $adapter = Join-Path $root 'scripts/Invoke-UiPathUiAutomation.ps1'
    $syntax = [Management.Automation.Language.Parser]::ParseFile($adapter, [ref]$null, [ref]$null)
    $helpFunction = $syntax.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Read-OfficialHelp'}, $true)
    . ([scriptblock]::Create($helpFunction.Extent.Text))
    $helpFixtures = Get-Content -LiteralPath $env:UIA_HELP_FIXTURE -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($format in @('json','table')) {
        $helpText = $helpFixtures.derived.("snapshot-$format")
        if ($format -eq 'json') {
            $helpData = $helpText | ConvertFrom-Json
            $helpData.Data.Options[1].Flags = '--project-dir <path --invented>'
            $helpText = $helpData | ConvertTo-Json -Depth 12
        } else {
            $helpText = $helpText.Replace('--project-dir <path>', '--project-dir <path --invented>')
        }
        $parsedHelp = Read-OfficialHelp -Response @{output=$helpText;error=''} -Name snapshot
        Assert-True ($parsedHelp.options -contains '--project-dir' -and $parsedHelp.options -notcontains '--invented') "Placeholder authorized a flag: $format"
    }
    foreach ($badLine in @('Error: discovery failed','[ERROR] discovery failed','--broken ???','unexpected malformed row')) {
        $rejected = $false
        try { Read-OfficialHelp -Response @{output=($helpFixtures.derived.'snapshot-table' + "`n$badLine");error=''} -Name snapshot | Out-Null } catch { $rejected = $true }
        Assert-True $rejected "Invalid text help row accepted: $badLine"
    }
    $r = & $adapter @parameters | ConvertFrom-Json
    Assert-True ($r.status -eq 'CAPABILITY_AVAILABLE') 'Mock official help was not routed'
    Assert-True ($r.tool -eq "$temp\RpaAiDevKit\tools\npm\uip.cmd") 'Actual resolved tool mismatch'
    $r = & $adapter @parameters -CommandName uia-configure-target | ConvertFrom-Json
    Assert-True ($r.reason -eq 'SKILL_NAME_IS_NOT_A_CLI_COMMAND') 'Skill misrouted as CLI command'
    $r = & $adapter @parameters -CommandName snapshot | ConvertFrom-Json
    Assert-True ($r.reason -eq 'APPROVED_NON_SENSITIVE_DEVELOPMENT_CONTEXT_REQUIRED') 'Context guard failed'
    $parameters.ApprovedDevelopment=$true; $parameters.NonSensitiveDevelopmentData=$true
    $r = & $adapter @parameters -CommandName snapshot | ConvertFrom-Json
    Assert-True ($r.reason -eq 'EXPLICIT_SIDE_EFFECT_APPROVAL_REQUIRED') 'Side effect gate failed'
    $parameters.AllowSideEffects=$true
    $r = & $adapter @parameters -CommandName snapshot | ConvertFrom-Json
    Assert-True ($r.reason -eq 'BUSINESS_PROJECT_REQUIRED') 'Central repo incorrectly accepted as bot'
    [IO.File]::WriteAllText("$temp/project.json", '{"dependencies":{"UiPath.UIAutomation.Activities":"[26.10.2]"}}')
    $r = & $adapter @parameters -CommandName snapshot | ConvertFrom-Json
    Assert-True ($r.reason -eq 'PROJECT_SPECIFIC_OFFICIAL_PACKAGE_GUIDE_REQUIRED') 'Missing guide accepted'
    $guideDir="$temp/.local/docs/packages/UiPath.UIAutomation.Activities"
    New-Item -ItemType Directory -Path $guideDir -Force | Out-Null
    [IO.File]::WriteAllText("$guideDir/ui-automation-guide.md", '# Mock guide - control proof only')
    $r = & $adapter @parameters -CommandName snapshot -Subcategory snapshot -ArgumentList @('--project-dir',$temp,'--output','json') | ConvertFrom-Json
    Assert-True ($r.status -eq 'EXECUTED_UNVERIFIED') 'Official command not dispatched'
    Assert-True ($r.commands.Count -eq 2 -and $r.commands[1].category -eq 'UIA' -and $r.commands[1].subcategory -eq 'snapshot') 'Runner category/subcategory incorrect'
    Assert-True ($r.commands[1].sideEffecting -and $r.commands[1].exitCode -eq 0 -and $r.commands[1].processId -gt 0) 'Runner process evidence missing'
    Assert-True (-not $r.captureCompletionAuthority -and $r.liveProof -eq 'NOT_VERIFIED') 'Mock command promoted to live proof'
    $r = & $adapter @parameters -CommandName snapshot -ArgumentList '--invented' | ConvertFrom-Json
    Assert-True ($r.reason -eq 'UNDOCUMENTED_OFFICIAL_OPTION') 'Unknown option accepted'
    $r = & $adapter @parameters -CommandName snapshot -ArgumentList '--password' | ConvertFrom-Json
    Assert-True ($r.reason -eq 'SENSITIVE_OR_MULTILINE_ARGUMENT_REJECTED') 'Sensitive argument accepted'
    $r = & $adapter @parameters -CommandName snapshot -ArgumentList 'value&other' | ConvertFrom-Json
    Assert-True ($r.reason -eq 'SHELL_METACHARACTER_ARGUMENT_REJECTED') 'Shell argument accepted'
    $r = & $adapter @parameters -ArgumentList '--output' | ConvertFrom-Json
    Assert-True ($r.reason -eq 'ARGUMENTS_REQUIRE_A_DOCUMENTED_COMMAND') 'Capability probe silently ignored arguments'
    $originalSkill=$parameters.SkillPath
    $parameters.SkillPath=Join-Path $temp 'absent-skill.md'
    $r = & $adapter @parameters -CommandName snapshot | ConvertFrom-Json
    Assert-True ($r.reason -eq 'OFFICIAL_SKILL_UNAVAILABLE') 'Unavailable skill accepted'
    $parameters.SkillPath=$originalSkill
    foreach ($mode in @('table','text','ansi')) {
        $env:UIA_MOCK_MODE=$mode
        $r = & $adapter @parameters | ConvertFrom-Json
        Assert-True ($r.status -eq 'CAPABILITY_AVAILABLE') "Supported parent text rejected: $mode ($($r.reason))"
        $r = & $adapter @parameters -CommandName snapshot -ArgumentList @('-h',('--project-dir='+$temp)) | ConvertFrom-Json
        Assert-True ($r.status -eq 'EXECUTED_UNVERIFIED') "Supported child text/alias rejected: $mode ($($r.reason))"
    }
    foreach ($mode in @('malformed','array-envelope','wrong-result','wrong-code','wrong-command','wrong-path','missing-commands','scalar-commands','scalar-options','invalid-option','scalar-global','invalid-argument','stderr','help-failure','raw-parent-json','raw-parent-table','raw-parent-plain','raw-snapshot-json','raw-snapshot-table','raw-snapshot-plain')) {
        $env:UIA_MOCK_MODE=$mode
        $r = & $adapter @parameters | ConvertFrom-Json
        Assert-True ($r.status -eq 'BLOCKED_UI_CAPTURE') "Invalid parent evidence accepted: $mode"
        $r = & $adapter @parameters -CommandName snapshot | ConvertFrom-Json
        Assert-True ($r.status -eq 'BLOCKED_UI_CAPTURE') "Invalid child evidence accepted: $mode"
    }
    $env:UIA_MOCK_MODE='empty-commands'
    $r = & $adapter @parameters | ConvertFrom-Json
    Assert-True ($r.status -eq 'BLOCKED_UI_CAPTURE') 'Empty parent inventory accepted'
    $env:UIA_MOCK_MODE='parent-child'
    $r = & $adapter @parameters -CommandName snapshot | ConvertFrom-Json
    Assert-True ($r.status -eq 'BLOCKED_UI_CAPTURE') 'Parent help accepted as child help'
    $env:UIA_MOCK_MODE='prose-option'
    foreach ($option in @('--invented','-x','--project','-hh','--HELP')) {
        $r = & $adapter @parameters -CommandName snapshot -ArgumentList $option | ConvertFrom-Json
        Assert-True ($r.reason -eq 'UNDOCUMENTED_OFFICIAL_OPTION') "Undocumented option accepted: $option"
    }
    $env:UIA_MOCK_MODE=''
    $r = & $adapter @parameters -CommandName snapshot -ArgumentList @("line`nbreak") | ConvertFrom-Json
    Assert-True ($r.reason -eq 'SENSITIVE_OR_MULTILINE_ARGUMENT_REJECTED') 'Multiline argument accepted'
    $referenceDir = Join-Path $temp 'references'
    New-Item -ItemType Directory -Path $referenceDir -Force | Out-Null
    $referencePath = Join-Path $referenceDir 'uia-starter-guide.md'
    $inline = Get-Content -LiteralPath $skill -Raw
    [IO.File]::WriteAllText($skill, "## UIA Prerequisites`nSee [UIA Prerequisites](references/uia-starter-guide.md).`n## Other`n**`26.1.0`**")
    $r = & $adapter @parameters -CommandName snapshot | ConvertFrom-Json
    Assert-True ($r.status -eq 'BLOCKED_UI_CAPTURE') 'Missing delegated reference accepted'
    [IO.File]::WriteAllText($referencePath, '## UIA Prerequisites' + "`n" + '**Required package:** `UiPath.UIAutomation.Activities` - minimum version: **`26.10.2`**')
    $r = & $adapter @parameters -CommandName snapshot | ConvertFrom-Json
    Assert-True ($r.status -eq 'EXECUTED_UNVERIFIED' -and $r.prerequisiteVersion -eq '26.10.2') "Delegated minimum rejected: $($r.reason)"
    Assert-True ($r.prerequisiteDocuments.Count -eq 2 -and $r.prerequisiteDocuments[1].sha256 -and $r.prerequisiteDocuments[1].bytes -gt 0) 'Prerequisite provenance missing'
    [IO.File]::WriteAllText($skill, $inline + "`n[guide](references/uia-starter-guide.md)")
    [IO.File]::WriteAllText($referencePath, '## UIA Prerequisites' + "`n" + '**Required package:** `UiPath.UIAutomation.Activities` - minimum version: **`27.0.0`**')
    $r = & $adapter @parameters -CommandName snapshot | ConvertFrom-Json
    Assert-True ($r.status -eq 'BLOCKED_UI_CAPTURE' -and $r.reason -eq 'OFFICIAL_MINIMUM_VERSION_UNKNOWN_OR_CONFLICTING') 'Valid conflicting prerequisite versions did not reach the conflict check'
    foreach ($reference in @('../SKILL.md','https://example.invalid/guide.md','references/../SKILL.md','C:/outside.md')) {
        [IO.File]::WriteAllText($skill, "## UIA Prerequisites`n[guide]($reference)")
        $r = & $adapter @parameters -CommandName snapshot | ConvertFrom-Json
        Assert-True ($r.reason -eq 'UNSAFE_OFFICIAL_PREREQUISITE_REFERENCE') "Unsafe reference accepted: $reference"
    }
    [IO.File]::WriteAllText($skill, '## UIA Prerequisites' + "`nNo minimum here.`n## Other`n" + '**Required package:** minimum **`26.10.2`**')
    $r = & $adapter @parameters -CommandName snapshot | ConvertFrom-Json
    Assert-True ($r.status -eq 'BLOCKED_UI_CAPTURE') 'Version outside prerequisite section accepted'
    [IO.File]::WriteAllText($skill, $inline)
    foreach ($mode in @('badhelp','empty','error','failure')) {
        $env:UIA_MOCK_MODE=$mode
        $r = & $adapter @parameters -CommandName snapshot | ConvertFrom-Json
        Assert-True ($r.status -eq 'BLOCKED_UI_CAPTURE') "Invalid/unavailable evidence accepted: $mode"
    }
    $env:UIA_MOCK_MODE=''

    # Nested command paths: help is resolved level by level and options are validated at the leaf.
    $nestedFixture = (Get-Content -LiteralPath $env:UIA_NESTED_FIXTURE -Raw -Encoding UTF8 | ConvertFrom-Json).help
    $leafHelp = Read-OfficialHelp -Response @{output=($nestedFixture.'target-app resolve-defaults' | ConvertTo-Json -Depth 12);error=''} -CommandPath @('target-app','resolve-defaults')
    Assert-True ($leafHelp.command -eq 'resolve-defaults' -and $leafHelp.usagePath -eq 'uip rpa uia target-app resolve-defaults' -and $leafHelp.options -contains '--refs' -and $leafHelp.arity['--refs'] -eq 'required' -and $leafHelp.arity['-h'] -eq 'none' -and $leafHelp.globalOptions -contains '--output' -and $leafHelp.globalOptions -notcontains '--refs') 'Nested leaf help identity, arity, or scope was not parsed.'
    foreach ($badPath in @(@('resolve-defaults'), @('snapshot','resolve-defaults'), @('target-app'))) {
        $rejected = $false
        try { Read-OfficialHelp -Response @{output=($nestedFixture.'target-app resolve-defaults' | ConvertTo-Json -Depth 12);error=''} -CommandPath $badPath | Out-Null } catch { $rejected = $true }
        Assert-True $rejected "Leaf help accepted for wrong command path: $($badPath -join ' ')"
    }
    $groupHelp = Read-OfficialHelp -Response @{output=($nestedFixture.'target-app' | ConvertTo-Json -Depth 12);error=''} -CommandPath @('target-app')
    Assert-True ($groupHelp.subcommands -contains 'resolve-defaults' -and $groupHelp.options -notcontains '--refs') 'Parent help scope was not parsed.'
    $tableHelp = Read-OfficialHelp -Response @{output=$helpFixtures.derived.'snapshot-table';error=''} -Name snapshot
    Assert-True ($tableHelp.arity['--output'] -eq 'required' -and $tableHelp.arity['--project-dir'] -eq 'required' -and $tableHelp.arity['--verbose'] -eq 'none') 'Table help option arity (including wrapped placeholders) was not parsed.'
    $clickHelp = Read-OfficialHelp -Response @{output=($nestedFixture.'interact click' | ConvertTo-Json -Depth 12);error=''} -CommandPath @('interact','click')
    Assert-True (@($clickHelp.arguments).Count -eq 1 -and $clickHelp.arguments[0].required) 'Declared positional arguments were not parsed.'

    $argsLog = Join-Path $temp 'uip-args.json'
    $helpLog = Join-Path $temp 'uip-help.log'
    $env:UIA_ARGS_LOG = $argsLog
    $env:UIA_HELP_LOG = $helpLog
    function Get-ExecutedArgs { if (Test-Path -LiteralPath $argsLog) { @(Get-Content -LiteralPath $argsLog -Raw | ConvertFrom-Json) } else { @() } }
    function Reset-Logs { Remove-Item -LiteralPath $argsLog,$helpLog -ErrorAction SilentlyContinue }
    function Get-MutatingCount($r) { @($r.commands | Where-Object { $_.subcategory -ne 'capability' }).Count }

    Reset-Logs
    $r = & $adapter @parameters -CommandName target-app -Subcategory target_generation -ArgumentList @('resolve-defaults','--refs','ref-001','--name','Submit Button') | ConvertFrom-Json
    Assert-True ($r.status -eq 'EXECUTED_UNVERIFIED' -and ($r.commandPath -join ' ') -eq 'target-app resolve-defaults') "Nested resolve-defaults rejected: $($r.reason)"
    Assert-True ($r.commands.Count -eq 3 -and $r.commands[2].subcategory -eq 'target_generation' -and $r.commands[2].sideEffecting -and $r.commands[2].category -eq 'UIA') 'Nested runner evidence incorrect'
    Assert-True (((Get-ExecutedArgs) -join '|') -ceq 'rpa|uia|target-app|resolve-defaults|--refs|ref-001|--name|Submit Button') "Argument order/boundaries not preserved: $((Get-ExecutedArgs) -join '|')"
    Assert-True (-not $r.captureCompletionAuthority -and $r.liveProof -eq 'NOT_VERIFIED') 'Nested execution promoted to live proof'

    Reset-Logs
    $r = & $adapter @parameters -CommandName 'target-app resolve-defaults' -ArgumentList @('--refs=ref-002','--name=My Target Name','--output','json') | ConvertFrom-Json
    Assert-True ($r.status -eq 'EXECUTED_UNVERIFIED') "Space-delimited command path or --option=value rejected: $($r.reason)"
    Assert-True (((Get-ExecutedArgs) -join '|') -ceq 'rpa|uia|target-app|resolve-defaults|--refs=ref-002|--name=My Target Name|--output|json') "Inline option values not preserved: $((Get-ExecutedArgs) -join '|')"

    Reset-Logs
    $r = & $adapter @parameters -CommandName target-app -ArgumentList @('resolve-defaults','--refs','ref-003','--name','resolve-defaults') | ConvertFrom-Json
    Assert-True ($r.status -eq 'EXECUTED_UNVERIFIED' -and ($r.commandPath -join ' ') -eq 'target-app resolve-defaults') "Option value matching a subcommand was misclassified: $($r.reason)"
    Assert-True ((Get-ExecutedArgs)[-1] -ceq 'resolve-defaults') 'Option value matching a subcommand was not passed as a value.'

    Reset-Logs
    $r = & $adapter @parameters -CommandName target-app -ArgumentList @('--name','resolve-defaults') | ConvertFrom-Json
    Assert-True ($r.reason -eq 'UNDOCUMENTED_OFFICIAL_OPTION' -and (Get-MutatingCount $r) -eq 0) "Leaf option accepted at parent level: $($r.reason)"
    Assert-True (@(Get-Content -LiteralPath $helpLog) -notcontains 'target-app resolve-defaults') 'Option value was resolved as a subcommand.'

    foreach ($case in @(
        @{ name='target-app'; args=@('bogus'); reason='UNKNOWN_OFFICIAL_SUBCOMMAND' },
        @{ name='target-app bogus'; args=@(); reason='UNKNOWN_OFFICIAL_SUBCOMMAND' },
        @{ name='target-app'; args=@(); reason='OFFICIAL_SUBCOMMAND_REQUIRED' },
        @{ name='target-app'; args=@('resolve-defaults','--invented'); reason='UNDOCUMENTED_OFFICIAL_OPTION' },
        @{ name='target-app'; args=@('resolve-defaults','--REFS','x'); reason='UNDOCUMENTED_OFFICIAL_OPTION' },
        @{ name='target-app'; args=@('resolve-defaults','--refs'); reason='OFFICIAL_OPTION_VALUE_MISSING' },
        @{ name='target-app'; args=@('resolve-defaults','--refs','--name','x'); reason='OFFICIAL_OPTION_VALUE_MISSING' },
        @{ name='target-app'; args=@('resolve-defaults','--refs='); reason='OFFICIAL_OPTION_VALUE_MISSING' },
        @{ name='target-app'; args=@('resolve-defaults','stray'); reason='UNEXPECTED_OFFICIAL_ARGUMENT' },
        @{ name='target-app'; args=@('resolve-defaults','--name','token-abc'); reason='SENSITIVE_OR_MULTILINE_ARGUMENT_REJECTED' },
        @{ name='target-app'; args=@('resolve-defaults','--name','a|b'); reason='SHELL_METACHARACTER_ARGUMENT_REJECTED' },
        @{ name='target-app RESOLVE'; args=@(); reason='SKILL_NAME_IS_NOT_A_CLI_COMMAND' },
        @{ name='interact'; args=@('click'); reason='OFFICIAL_ARGUMENT_MISSING' },
        @{ name='interact'; args=@('click','ref-1','ref-2'); reason='UNEXPECTED_OFFICIAL_ARGUMENT' },
        @{ name='interact'; args=@('click','ref-1','--double=yes'); reason='OFFICIAL_OPTION_DOES_NOT_ACCEPT_INLINE_VALUE' }
    )) {
        Reset-Logs
        $r = & $adapter @parameters -CommandName $case.name -ArgumentList $case.args | ConvertFrom-Json
        Assert-True ($r.status -eq 'BLOCKED_UI_CAPTURE' -and $r.reason -eq $case.reason -and (Get-MutatingCount $r) -eq 0 -and -not (Test-Path -LiteralPath $argsLog)) "Invalid nested invocation '$($case.name) $($case.args -join ' ')' expected $($case.reason), got $($r.reason)"
    }

    $r = & $adapter @parameters -CommandName interact -ArgumentList @('click','click','--double') | ConvertFrom-Json
    Assert-True ($r.status -eq 'EXECUTED_UNVERIFIED' -and ($r.commandPath -join ' ') -eq 'interact click') "Positional value matching a subcommand rejected: $($r.reason)"

    $env:UIA_NESTED = '1'
    Reset-Logs
    $r = & $adapter @parameters -CommandName snapshot -ArgumentList @('capture','--project-dir',$temp,'--window-title','Invoice Entry','--include-hidden','--depth','--output','json') | ConvertFrom-Json
    Assert-True ($r.status -eq 'EXECUTED_UNVERIFIED' -and ($r.commandPath -join ' ') -eq 'snapshot capture') "snapshot capture leaf options rejected: $($r.reason)"
    Assert-True (((Get-ExecutedArgs) -join '|') -ceq "rpa|uia|snapshot|capture|--project-dir|$temp|--window-title|Invoice Entry|--include-hidden|--depth|--output|json") 'snapshot capture arguments not preserved.'
    $r = & $adapter @parameters -CommandName snapshot -ArgumentList @('capture','--depth','3') | ConvertFrom-Json
    Assert-True ($r.status -eq 'EXECUTED_UNVERIFIED') "Optional option value rejected: $($r.reason)"
    $r = & $adapter @parameters -CommandName snapshot -ArgumentList @('--project-dir',$temp) | ConvertFrom-Json
    Assert-True ($r.reason -eq 'UNDOCUMENTED_OFFICIAL_OPTION') 'snapshot group accepted a leaf option without a subcommand.'
    foreach ($mode in @('nested-root-fallback','nested-wrong-path','nested-wrong-command','nested-malformed','nested-empty','nested-failure')) {
        $env:UIA_MOCK_MODE = $mode
        Reset-Logs
        $r = & $adapter @parameters -CommandName snapshot -ArgumentList @('capture','--include-hidden') | ConvertFrom-Json
        Assert-True ($r.status -eq 'BLOCKED_UI_CAPTURE' -and (Get-MutatingCount $r) -eq 0 -and -not (Test-Path -LiteralPath $argsLog)) "Invalid nested help accepted: $mode ($($r.reason))"
    }
    $env:UIA_MOCK_MODE = ''
    $guarded = $parameters.Clone(); $guarded.Remove('AllowSideEffects')
    $r = & $adapter @guarded -CommandName snapshot -ArgumentList @('capture') | ConvertFrom-Json
    Assert-True ($r.reason -eq 'EXPLICIT_SIDE_EFFECT_APPROVAL_REQUIRED' -and $r.commands.Count -eq 0) 'Nested path bypassed the side-effect gate.'
    $env:UIA_NESTED = ''
    $env:UIA_ARGS_LOG = ''; $env:UIA_HELP_LOG = ''

    # Actual help captured from uip 1.204.0 in a Development bot project (tests/fixtures/uia-help/actual-1.204.0).
    $actualDir = Join-Path $PSScriptRoot 'fixtures/uia-help/actual-1.204.0'
    function Read-Actual([string]$File) { [IO.File]::ReadAllText((Join-Path $actualDir $File), [Text.Encoding]::UTF8) }
    $actualLeaf = Read-OfficialHelp -Response @{output=(Read-Actual 'resolve-defaults.json');error=''} -CommandPath @('target-app','resolve-defaults')
    Assert-True ((@($actualLeaf.requiredOptions) -join ',') -eq '--refs,--name' -and $actualLeaf.arity['--refs'] -eq 'required' -and $actualLeaf.arity['--remote'] -eq 'none' -and $actualLeaf.options -contains '--description') "Actual resolve-defaults usage was not parsed: $(@($actualLeaf.requiredOptions) -join ',')"
    $actualTable = Read-OfficialHelp -Response @{output=(Read-Actual 'resolve-defaults.table.txt');error=''} -CommandPath @('target-app','resolve-defaults')
    Assert-True ((@($actualTable.requiredOptions) -join ',') -eq '--refs,--name' -and $actualTable.arity['--output'] -eq 'required') 'Actual resolve-defaults table usage was not parsed.'
    $actualCapture = Read-OfficialHelp -Response @{output=(Read-Actual 'snapshot-capture.json');error=''} -CommandPath @('snapshot','capture')
    Assert-True (@($actualCapture.requiredOptions).Count -eq 0 -and @($actualCapture.arguments).Count -eq 1 -and -not $actualCapture.arguments[0].required -and $actualCapture.arity['--type'] -eq 'required') 'Actual snapshot capture usage was not parsed.'
    $actualCaptureTable = Read-OfficialHelp -Response @{output=(Read-Actual 'snapshot-capture.table.txt');error=''} -CommandPath @('snapshot','capture')
    Assert-True (@($actualCaptureTable.arguments).Count -eq 1 -and -not $actualCaptureTable.arguments[0].required -and $actualCaptureTable.arity['--framework'] -eq 'required') 'Actual snapshot capture table help was not parsed.'
    $actualGroup = Read-OfficialHelp -Response @{output=(Read-Actual 'target-app.json');error=''} -CommandPath @('target-app')
    Assert-True ($actualGroup.subcommands -contains 'resolve-defaults' -and @($actualGroup.requiredOptions).Count -eq 0) 'Actual target-app group help was not parsed.'
    $leafEnvelope = Read-Actual 'resolve-defaults.json'
    foreach ($tamper in @(
        @{ path=@('target-app'); usage=$null },
        @{ path=@('snapshot','resolve-defaults'); usage=$null },
        @{ path=@('target-app','resolve-defaults'); usage='uip rpa uia target-app resolve-defaults extra --refs <string> --name <string>' },
        @{ path=@('target-app','resolve-defaults'); usage='uip rpa uia target-app --refs <string> --name <string>' },
        @{ path=@('target-app','resolve-defaults'); usage='uip rpa uia target-app resolve-defaults --undeclared <string>' },
        @{ path=@('target-app','resolve-defaults'); usage='uip rpa uia target-app resolve-defaultsX --refs <string>' }
    )) {
        $envelopeText = $leafEnvelope
        if ($tamper.usage) { $envelope = $leafEnvelope | ConvertFrom-Json; $envelope.Data.Usage = $tamper.usage; $envelopeText = $envelope | ConvertTo-Json -Depth 12 }
        $rejected = $false
        try { Read-OfficialHelp -Response @{output=$envelopeText;error=''} -CommandPath $tamper.path | Out-Null } catch { $rejected = $_.Exception.Message -eq 'OFFICIAL_COMMAND_SYNTAX_UNAVAILABLE' }
        Assert-True $rejected "Tampered actual usage accepted: $($tamper.path -join ' ') / $($tamper.usage)"
    }

    $env:UIA_ACTUAL_DIR = $actualDir
    $env:UIA_ARGS_LOG = $argsLog
    $r = & $adapter @parameters | ConvertFrom-Json
    Assert-True ($r.status -eq 'CAPABILITY_AVAILABLE') "Actual root help rejected: $($r.reason)"
    Reset-Logs
    $r = & $adapter @parameters -CommandName target-app -Subcategory target_generation -ArgumentList @('resolve-defaults','--refs','w1-e5','--name','Submit Button','--project-dir',$temp) | ConvertFrom-Json
    Assert-True ($r.status -eq 'EXECUTED_UNVERIFIED' -and ($r.commandPath -join ' ') -eq 'target-app resolve-defaults' -and $r.liveProof -eq 'NOT_VERIFIED') "Actual resolve-defaults (ArgumentList form) rejected: $($r.reason)"
    Assert-True (((Get-ExecutedArgs) -join '|') -ceq "rpa|uia|target-app|resolve-defaults|--refs|w1-e5|--name|Submit Button|--project-dir|$temp") 'Actual resolve-defaults arguments not preserved.'
    Reset-Logs
    $r = & $adapter @parameters -CommandName 'target-app resolve-defaults' -Subcategory target_generation -ArgumentList @('--name=Submit Button','--refs=w1-e5','--remote') | ConvertFrom-Json
    Assert-True ($r.status -eq 'EXECUTED_UNVERIFIED' -and ($r.commandPath -join ' ') -eq 'target-app resolve-defaults') "Actual resolve-defaults (CommandName form) rejected: $($r.reason)"
    foreach ($case in @(
        @{ name='target-app'; args=@('resolve-defaults','--refs','w1-e5'); reason='OFFICIAL_REQUIRED_OPTION_MISSING' },
        @{ name='target-app resolve-defaults'; args=@('--name','Submit'); reason='OFFICIAL_REQUIRED_OPTION_MISSING' },
        @{ name='target-app resolve-defaults'; args=@('--refs','w1-e5','--name'); reason='OFFICIAL_OPTION_VALUE_MISSING' },
        @{ name='target-app resolve-defaults'; args=@('--refs','w1-e5','--name','Submit','--bogus'); reason='UNDOCUMENTED_OFFICIAL_OPTION' },
        @{ name='target-app'; args=@('resolve-default','--refs','w1-e5','--name','Submit'); reason='UNKNOWN_OFFICIAL_SUBCOMMAND' },
        @{ name='snapshot'; args=@('capture','w1','b2'); reason='UNEXPECTED_OFFICIAL_ARGUMENT' }
    )) {
        Reset-Logs
        $r = & $adapter @parameters -CommandName $case.name -ArgumentList $case.args | ConvertFrom-Json
        Assert-True ($r.reason -eq $case.reason -and (Get-MutatingCount $r) -eq 0 -and -not (Test-Path -LiteralPath $argsLog)) "Actual-help invalid invocation '$($case.name) $($case.args -join ' ')' expected $($case.reason), got $($r.reason)"
    }
    $r = & $adapter @parameters -CommandName snapshot -Subcategory snapshot -ArgumentList @('capture','w1','--type','CV','--framework','UIA','--all-windows') | ConvertFrom-Json
    Assert-True ($r.status -eq 'EXECUTED_UNVERIFIED' -and ($r.commandPath -join ' ') -eq 'snapshot capture') "Actual snapshot capture rejected: $($r.reason)"
    $r = & $adapter @parameters -CommandName 'snapshot capture' -Subcategory snapshot | ConvertFrom-Json
    Assert-True ($r.status -eq 'EXECUTED_UNVERIFIED') "Actual snapshot capture without optional reference rejected: $($r.reason)"
    $env:UIA_ACTUAL_DIR = ''; $env:UIA_ARGS_LOG = ''

    [IO.File]::WriteAllText("$temp/project.json", '{"dependencies":{"UiPath.UIAutomation.Activities":"[25.10.0]"}}')
    $r = & $adapter @parameters -CommandName snapshot | ConvertFrom-Json
    Assert-True ($r.reason -eq 'UIA_PACKAGE_BELOW_OFFICIAL_MINIMUM_NO_AUTO_UPGRADE') 'Old package accepted'
    Write-Output "PASS: $checks mock routing/guard/runner checks; NOT live capture proof."
} finally {
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
