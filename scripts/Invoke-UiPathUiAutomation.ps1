[CmdletBinding()]
param(
    [string]$TargetBotPath = (Get-Location).Path,
    [string]$SkillPath = (Join-Path $env:USERPROFILE '.copilot\skills\uipath-rpa\SKILL.md'),
    [string]$CommandName,
    [string[]]$ArgumentList = @(),
    [ValidateSet('capability','snapshot','navigate','live_capture','target_capture','target_generation','target_validation','selector_inspection','target_query','activity_link','native_interaction')]
    [string]$Subcategory = 'capability',
    [string]$ExecutionStatePath,
    [ValidateRange(1,300)][int]$TimeoutSeconds = 60,
    [switch]$ApprovedDevelopment,
    [switch]$NonSensitiveDevelopmentData,
    [switch]$AllowSideEffects,
    [switch]$Json
)

# Transport only: official package procedures own capture/configuration/OR/recovery.
# A process exit code, JSON status, or an existing artifact is never live target proof.
$ErrorActionPreference = 'Stop'
$result = [ordered]@{
    status = 'BLOCKED_UI_CAPTURE'; reason = ''; tool = $null
    category = 'UIA'; subcategory = $Subcategory; commands = @()
    guide = $null; prerequisiteVersion = $null; installedVersion = $null; prerequisiteDocuments = @()
    liveProof = 'NOT_VERIFIED'; captureCompletionAuthority = $false; commandPath = @()
}
function Read-OfficialHelp {
    param($Response, [string]$Name, [string[]]$CommandPath = @())
    if (-not $CommandPath.Count -and $Name) { $CommandPath = @($Name) }
    if ($Name -and $CommandPath[-1] -cne $Name) { throw 'OFFICIAL_COMMAND_SYNTAX_UNAVAILABLE' }
    if ($Response.error -or [string]::IsNullOrWhiteSpace($Response.output)) { throw 'UNRECOGNIZED_OFFICIAL_HELP' }
    $text = $Response.output.Trim()
    $path = 'uip rpa uia'
    $command = 'uia'
    if ($CommandPath.Count) { $path += ' ' + ($CommandPath -join ' '); $command = $CommandPath[-1] }
    # After the exact command path, usage may contain only options, <placeholders>, [optional groups], {choices}, or '...'; a bare word would name a different command.
    $usageGrammar = '(?:\s+(?:--?[A-Za-z][A-Za-z0-9-]*|<[^<>]+>|\[[^\[\]]+\]|\{[^{}]+\}|\.\.\.))*\s*$'
    $pathPattern = '^' + [regex]::Escape($path) + $usageGrammar
    $getRequiredOptions = {
        param([string]$Usage)
        $tail = $Usage.Substring($path.Length) -replace '\[[^\[\]]*\]', ' ' -replace '\{[^{}]*\}', ' ' -replace '<[^<>]*>', ' '
        @([regex]::Matches($tail, '(?<!\S)--?[A-Za-z][A-Za-z0-9-]*') | ForEach-Object { $_.Value })
    }
    $options = @(); $children = @(); $globalOptions = @(); $arguments = @(); $lastDeclared = @(); $requiredOptions = @(); $usageLines = @()
    $arity = New-Object System.Collections.Hashtable ([StringComparer]::Ordinal)
    $optionGroups = New-Object System.Collections.Hashtable ([StringComparer]::Ordinal)
    $setArity = {
        param([string[]]$Declared, [string]$Placeholder)
        $kind = if ($Placeholder.StartsWith('<')) { 'required' } elseif ($Placeholder.StartsWith('[')) { 'optional' } else { 'none' }
        foreach ($flag in $Declared) { $arity[$flag] = $kind; $optionGroups[$flag] = $Declared }
    }
    if ($text -match '^[\{\[]') {
        try { $envelope = $text | ConvertFrom-Json } catch { throw 'MALFORMED_OFFICIAL_HELP' }
        if ($envelope -isnot [pscustomobject] -or $envelope.Result -cne 'Success' -or $envelope.Code -cne 'Help' -or
            $envelope.Data -isnot [pscustomobject] -or $envelope.Error -or $envelope.Errors) { throw 'UNRECOGNIZED_OFFICIAL_HELP' }
        $data = $envelope.Data
        if ($data.Command -cne $command -or $data.Usage -isnot [string] -or $data.Usage -cnotmatch $pathPattern -or
            $data.Description -isnot [string]) { throw 'OFFICIAL_COMMAND_SYNTAX_UNAVAILABLE' }
        $requiredOptions = @(& $getRequiredOptions $data.Usage)
        foreach ($field in @('Arguments','Options','GlobalOptions','Subcommands')) {
            if ($data.$field -isnot [array]) { throw 'MALFORMED_OFFICIAL_HELP' }
            foreach ($entry in $data.$field) {
                if ($entry -isnot [pscustomobject] -or $entry.Description -isnot [string]) { throw 'MALFORMED_OFFICIAL_HELP' }
            }
        }
        $scopedEntries = @(@($data.Options) | ForEach-Object { @{ entry = $_; global = $false } }) + @(@($data.GlobalOptions) | ForEach-Object { @{ entry = $_; global = $true } })
        foreach ($scoped in $scopedEntries) {
            $entry = $scoped.entry
            if ($entry.Flags -isnot [string] -or $entry.Flags -notmatch '^--?[A-Za-z]') { throw 'MALFORMED_OFFICIAL_HELP' }
            $flags = $entry.Flags
            if ($flags -notmatch '^(?<declared>--?[A-Za-z][A-Za-z0-9-]*(?:,\s*--?[A-Za-z][A-Za-z0-9-]*)*)(?:\s+(?<placeholder><[^<>]+>|\[[^\[\]]+\]))?$') { throw 'MALFORMED_OFFICIAL_HELP' }
            $declared = @([regex]::Matches($Matches['declared'], '--?[A-Za-z][A-Za-z0-9-]*') | ForEach-Object { $_.Value })
            & $setArity $declared ([string]$Matches['placeholder'])
            $options += $declared
            if ($scoped.global) { $globalOptions += $declared }
        }
        foreach ($entry in $data.Subcommands) {
            if ($entry.Name -isnot [string] -or $entry.Name -cnotmatch '^[a-z][a-z0-9-]*$') { throw 'MALFORMED_OFFICIAL_HELP' }
            $children += $entry.Name
        }
        foreach ($entry in $data.Arguments) {
            if ($entry.Name -isnot [string] -or $entry.Required -isnot [bool]) { throw 'MALFORMED_OFFICIAL_HELP' }
            $arguments += [pscustomobject]@{ name = $entry.Name; required = [bool]$entry.Required; variadic = $entry.Name -match '\.\.\.' }
        }
    } else {
        if ($text -match '(?i)\[object Object\]|"(?:Result|Code|Data)"\s*:') { throw 'UNRECOGNIZED_OFFICIAL_HELP' }
        $text = [regex]::Replace($text, '\x1b\[[0-?]*[ -/]*[@-~]', '')
        foreach ($encoding in @([Console]::OutputEncoding, [Text.Encoding]::Default)) {
            foreach ($code in @(0x250c,0x2500,0x2510,0x2502,0x2514,0x2518)) {
                $border = $encoding.GetString([Text.Encoding]::UTF8.GetBytes([string][char]$code))
                if ($border -ne '?') { $text = $text.Replace($border, '') }
            }
        }
        $section = ''; $usageFound = $false; $usageSection = $false; $optionsSection = $false
        $entryIndent = $null; $hasEntry = $false; $placeholderOpen = $false
        foreach ($rawLine in ($text -split '\r?\n')) {
            $row = ($rawLine -replace '[\u2500-\u257f]', '').TrimEnd()
            $line = $row.TrimStart()
            if (-not $line) { continue }
            $indent = $row.Length - $line.Length
            if ($line -match '(?i)^(?:\[(?:error|fatal)\]|error\b|fatal\b|exception\b|unhandled\s+exception\b)') { throw 'UNRECOGNIZED_OFFICIAL_HELP' }
            if ($line -match '^(Usage|Commands|Subcommands|Options|Global Options|Arguments|Examples):?\s*(.*)$') {
                if ($placeholderOpen) { throw 'MALFORMED_OFFICIAL_HELP' }
                $section = $Matches[1]; $line = $Matches[2]
                $entryIndent = $null; $hasEntry = $false
                if ($section -eq 'Usage') { $usageSection = $true }
                if ($section -in @('Options','Global Options')) { $optionsSection = $true }
                if (-not $line) { continue }
            }
            if ($section -eq 'Usage') {
                # The table renderer may wrap long usage lines; validate the joined text after the section.
                $usageLines += $line
                $usageFound = $true
                continue
            }
            if ($section -in @('Commands','Subcommands','Options','Global Options','Arguments')) {
                if ($placeholderOpen) {
                    if ($line -notmatch '^[A-Za-z0-9|._-]+>?$') { throw 'MALFORMED_OFFICIAL_HELP' }
                    $placeholderOpen = -not $line.EndsWith('>')
                    continue
                }
                if ($section -in @('Options','Global Options') -and $line -match '^(?<declared>--?[A-Za-z][A-Za-z0-9-]*(?:,\s*--?[A-Za-z][A-Za-z0-9-]*)*)(?:\s+(?<placeholder><[^<>]+>|\[[^\[\]]+\]))?(?:\s{2,}\S.*)?$') {
                    $lastDeclared = @([regex]::Matches($Matches['declared'], '--?[A-Za-z][A-Za-z0-9-]*') | ForEach-Object { $_.Value })
                    & $setArity $lastDeclared ([string]$Matches['placeholder'])
                    $options += $lastDeclared
                    if ($section -eq 'Global Options') { $globalOptions += $lastDeclared }
                } elseif ($section -in @('Commands','Subcommands') -and $line -cmatch '^([a-z][a-z0-9-]*)(?:\s+\[[^\]]+\])?\s{2,}\S') {
                    $children += $Matches[1]
                } elseif ($section -eq 'Arguments' -and $line -match '^(?<argument><[^<>]+>|\[[^\[\]]+\]|[A-Za-z][A-Za-z0-9/_.-]*)\s{2,}\S') {
                    $argumentName = $Matches['argument']
                    $usageSoFar = ($usageLines -join ' ')
                    $required = $argumentName.StartsWith('<') -or ($argumentName -notmatch '^[\[<]' -and $usageSoFar.Contains('<' + $argumentName + '>'))
                    $arguments += [pscustomobject]@{ name = $argumentName; required = $required; variadic = $argumentName -match '\.\.\.' }
                } elseif ($hasEntry -and $section -in @('Options','Global Options') -and $line -match '^(?<placeholder><[A-Za-z0-9|._-]+>?)(?:\s{2,}\S.*)?$') {
                    # A wrapped value placeholder belongs to the option declared on the previous row.
                    & $setArity $lastDeclared '<'
                    $placeholderOpen = -not $Matches['placeholder'].EndsWith('>')
                    continue
                } elseif ($hasEntry -and $indent -gt $entryIndent -and $line -notmatch '^[-<]') {
                    continue
                } else {
                    throw 'MALFORMED_OFFICIAL_HELP'
                }
                $entryIndent = $indent; $hasEntry = $true
            }
        }
        if ($placeholderOpen) { throw 'MALFORMED_OFFICIAL_HELP' }
        if (-not $usageSection -or -not $usageFound -or -not $optionsSection) { throw 'OFFICIAL_COMMAND_SYNTAX_UNAVAILABLE' }
        $usageText = ($usageLines -join ' ') -replace '\s+', ' '
        if ($usageText -cnotmatch $pathPattern) { throw 'OFFICIAL_COMMAND_SYNTAX_UNAVAILABLE' }
        $requiredOptions = @(& $getRequiredOptions $usageText)
    }
    if (-not $options.Count -or $options -cnotcontains '--help') { throw 'OFFICIAL_COMMAND_SYNTAX_UNAVAILABLE' }
    foreach ($requiredOption in $requiredOptions) {
        if ($options -cnotcontains $requiredOption) { throw 'OFFICIAL_COMMAND_SYNTAX_UNAVAILABLE' }
    }
    if (-not $CommandPath.Count -and -not $children.Count) { throw 'OFFICIAL_SUBCOMMAND_DISCOVERY_UNAVAILABLE' }
    return [pscustomobject]@{
        command = $command; usagePath = $path; options = $options; globalOptions = $globalOptions
        requiredOptions = $requiredOptions; optionGroups = $optionGroups
        arity = $arity; arguments = $arguments; subcommands = $children
    }
}
function Get-PrerequisiteDocument {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($item.PSIsContainer) { throw 'UNSAFE_OFFICIAL_PREREQUISITE_REFERENCE' }
    $ancestor = $item
    while ($null -ne $ancestor) {
        if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'UNSAFE_OFFICIAL_PREREQUISITE_REFERENCE' }
        $ancestor = if ($ancestor -is [IO.FileInfo]) { $ancestor.Directory } else { $ancestor.Parent }
    }
    $result.prerequisiteDocuments += @{ path = $item.FullName; bytes = $item.Length; sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash }
    $content = Get-Content -LiteralPath $item.FullName -Raw -Encoding UTF8
    $sections = [regex]::Matches($content, '(?ms)^## UIA Prerequisites\s*\r?\n(?<body>.*?)(?=^#{1,2}\s|\z)')
    if ($sections.Count -ne 1) { throw 'OFFICIAL_MINIMUM_VERSION_UNKNOWN' }
    return $sections[0].Groups['body'].Value
}
function Get-OfficialMinimum {
    $section = Get-PrerequisiteDocument -Path $SkillPath
    $versions = @()
    $documents = @($section)
    $links = [regex]::Matches($section, '\[[^\]]+\]\((?<path>[^)]+)\)')
    foreach ($link in $links) {
        $reference = $link.Groups['path'].Value
        if ($reference -cnotmatch '^references/uia-starter-guide\.md(?:#uia-prerequisites)?$') { throw 'UNSAFE_OFFICIAL_PREREQUISITE_REFERENCE' }
        $documents += Get-PrerequisiteDocument -Path (Join-Path (Split-Path $SkillPath -Parent) 'references/uia-starter-guide.md')
    }
    $documentIndex = 0
    foreach ($document in $documents) {
        $minimumMatches = [regex]::Matches($document, '(?im)^\*\*Required package:\*\*[^\r\n]*?minimum[^\r\n]*?\*\*`(?<version>\d+\.\d+\.\d+(?:\.\d+)?)`\*\*')
        if ($documentIndex -gt 0 -and (-not $minimumMatches.Count -or $document -notmatch '`UiPath\.UIAutomation\.Activities`')) { throw 'OFFICIAL_MINIMUM_VERSION_UNKNOWN' }
        foreach ($match in $minimumMatches) { $versions += $match.Groups['version'].Value }
        $documentIndex++
    }
    if (-not $versions.Count -or @($versions | Select-Object -Unique).Count -ne 1) { throw 'OFFICIAL_MINIMUM_VERSION_UNKNOWN_OR_CONFLICTING' }
    return $versions[0]
}
function Invoke-OfficialCommand {
    param([string[]]$Tokens, [string]$Kind, [bool]$Mutating)
    $parameters = @{
        FilePath = $result.tool; ArgumentList = $Tokens
        WorkingDirectory = $TargetBotPath; TargetBotPath = $TargetBotPath
        Category = 'UIA'; Subcategory = $Kind; Operation = "official UIA $Kind"
        TimeoutSeconds = $TimeoutSeconds
        SideEffecting = $Mutating; Json = $true
    }
    if ($ExecutionStatePath) { $parameters.ExecutionStatePath = $ExecutionStatePath }
    $command = & (Join-Path $PSScriptRoot 'Invoke-DevKitCommand.ps1') @parameters | ConvertFrom-Json
    $result.commands += [ordered]@{
        category = $command.category; subcategory = $Kind; file = $command.file
        exitCode = $command.exit_code; timedOut = $command.timed_out
        sideEffecting = $command.side_effecting; durationSeconds = $command.duration_seconds
        processId = $command.pid; outputPath = $command.output_path; outputSha256 = $command.output_sha256
    }
    if ($command.timed_out -or $command.exit_code -ne 0) { throw 'OFFICIAL_COMMAND_UNAVAILABLE_OR_FAILED' }
    return $command
}
try {
    $TargetBotPath = (Resolve-Path -LiteralPath $TargetBotPath).Path
    . (Join-Path $PSScriptRoot 'Resolve-DevKitTool.ps1')
    $result.tool = Resolve-DevKitTool -Name uip -TargetBotPath $TargetBotPath -Required
    if (-not $CommandName) {
        if ($ArgumentList.Count) { throw 'ARGUMENTS_REQUIRE_A_DOCUMENTED_COMMAND' }
        $help = Invoke-OfficialCommand -Tokens @('rpa','uia','--help','--output','json') -Kind capability -Mutating $false
        $inventory = Read-OfficialHelp -Response $help
        $result.status = 'CAPABILITY_AVAILABLE'
        $result.reason = 'Official UIA help executed; no project or live capture was validated.'
    } else {
        # CommandName may name a nested path ("target-app resolve-defaults"); each segment is still resolved against official help.
        $requestedPath = @($CommandName -split ' ')
        foreach ($segment in $requestedPath) {
            if ($segment -cnotmatch '^[a-z][a-z0-9-]*$' -or $segment -in @('uia-configure-target','uia-improve-selector')) {
                throw 'SKILL_NAME_IS_NOT_A_CLI_COMMAND'
            }
        }
        if (-not $ApprovedDevelopment -or -not $NonSensitiveDevelopmentData) { throw 'APPROVED_NON_SENSITIVE_DEVELOPMENT_CONTEXT_REQUIRED' }
        # Conservatively treat every non-help invocation as side-effecting. Do not
        # trust caller labels to make interactions killable or parallel-safe.
        if (-not $AllowSideEffects) { throw 'EXPLICIT_SIDE_EFFECT_APPROVAL_REQUIRED' }
        $projectPath = Join-Path $TargetBotPath 'project.json'
        if (-not (Test-Path -LiteralPath $projectPath -PathType Leaf)) { throw 'BUSINESS_PROJECT_REQUIRED' }
        if (-not (Test-Path -LiteralPath $SkillPath -PathType Leaf)) { throw 'OFFICIAL_SKILL_UNAVAILABLE' }
        $result.prerequisiteVersion = Get-OfficialMinimum
        $project = Get-Content -LiteralPath $projectPath -Raw | ConvertFrom-Json
        $dependency = [string]$project.dependencies.'UiPath.UIAutomation.Activities'
        # Accept exact NuGet version or exact [version] only, not unresolved ranges.
        if ($dependency -notmatch '^\[?(\d+\.\d+\.\d+(?:\.\d+)?)\]?$') { throw 'UIA_DEPENDENCY_VERSION_UNRESOLVED' }
        $result.installedVersion = $Matches[1]
        if ([version]$result.installedVersion -lt [version]$result.prerequisiteVersion) { throw 'UIA_PACKAGE_BELOW_OFFICIAL_MINIMUM_NO_AUTO_UPGRADE' }
        $guidePath = Join-Path $TargetBotPath '.local\docs\packages\UiPath.UIAutomation.Activities\ui-automation-guide.md'
        if (-not (Test-Path -LiteralPath $guidePath -PathType Leaf)) { throw 'PROJECT_SPECIFIC_OFFICIAL_PACKAGE_GUIDE_REQUIRED' }
        $guideItem = Get-Item -LiteralPath $guidePath
        $result.guide = @{ path = $guidePath; bytes = $guideItem.Length; sha256 = (Get-FileHash -LiteralPath $guidePath -Algorithm SHA256).Hash }
        foreach ($argument in $ArgumentList) {
            if ($argument -match '(?i)(password|passwd|secret|token|authorization|credential)' -or $argument -match '[\r\n]') {
                throw 'SENSITIVE_OR_MULTILINE_ARGUMENT_REJECTED'
            }
            if ($argument -match '[&|<>^%!]') { throw 'SHELL_METACHARACTER_ARGUMENT_REJECTED' }
        }
        # Help at each level is the current CLI syntax authority. Do not hardcode a
        # package-version-specific command inventory or map skill names to verbs.
        $commandPath = @()
        $inventory = $null
        foreach ($segment in $requestedPath) {
            if ($inventory -and $inventory.subcommands -cnotcontains $segment) { throw 'UNKNOWN_OFFICIAL_SUBCOMMAND' }
            $commandPath += $segment
            $help = Invoke-OfficialCommand -Tokens (@('rpa','uia') + $commandPath + @('--help','--output','json')) -Kind capability -Mutating $false
            $inventory = Read-OfficialHelp -Response $help -CommandPath $commandPath
        }
        # Descend through leading ArgumentList tokens only while help declares them as subcommands.
        $index = 0
        while ($index -lt $ArgumentList.Count -and @($inventory.subcommands).Count -and $ArgumentList[$index] -notmatch '^-') {
            $token = $ArgumentList[$index]
            if ($inventory.subcommands -cnotcontains $token) {
                if (@($inventory.arguments).Count) { break }
                throw 'UNKNOWN_OFFICIAL_SUBCOMMAND'
            }
            $commandPath += $token
            $help = Invoke-OfficialCommand -Tokens (@('rpa','uia') + $commandPath + @('--help','--output','json')) -Kind capability -Mutating $false
            $inventory = Read-OfficialHelp -Response $help -CommandPath $commandPath
            $index++
        }
        if (@($inventory.subcommands).Count -and -not @($inventory.arguments).Count -and $index -ge $ArgumentList.Count) { throw 'OFFICIAL_SUBCOMMAND_REQUIRED' }
        $result.commandPath = $commandPath
        # Remaining tokens follow the leaf command; validate them against the leaf help only.
        $operands = @($ArgumentList | Select-Object -Skip $index)
        $positionals = @()
        $usedOptions = @()
        for ($position = 0; $position -lt $operands.Count; $position++) {
            $argument = $operands[$position]
            if ($argument -notmatch '^-') { $positionals += $argument; continue }
            $parts = $argument -split '=', 2
            $option = $parts[0]
            if ($inventory.options -cnotcontains $option) { throw 'UNDOCUMENTED_OFFICIAL_OPTION' }
            $usedOptions += $option
            $kind = [string]$inventory.arity[$option]
            if ($parts.Count -eq 2) {
                if ($option -notmatch '^--' -or $kind -eq 'none') { throw 'OFFICIAL_OPTION_DOES_NOT_ACCEPT_INLINE_VALUE' }
                if (-not $parts[1]) { throw 'OFFICIAL_OPTION_VALUE_MISSING' }
                continue
            }
            if ($kind -eq 'required') {
                if ($position + 1 -ge $operands.Count -or $operands[$position + 1] -match '^-') { throw 'OFFICIAL_OPTION_VALUE_MISSING' }
                $position++
            } elseif ($kind -eq 'optional' -and $position + 1 -lt $operands.Count -and $operands[$position + 1] -notmatch '^-') {
                $position++
            }
        }
        $declaredArguments = @($inventory.arguments)
        foreach ($requiredOption in @($inventory.requiredOptions)) {
            $aliases = @($inventory.optionGroups[$requiredOption])
            if (-not @($usedOptions | Where-Object { $aliases -ccontains $_ }).Count) { throw 'OFFICIAL_REQUIRED_OPTION_MISSING' }
        }
        $requiredCount = @($declaredArguments | Where-Object { $_.required }).Count
        if ($positionals.Count -lt $requiredCount) { throw 'OFFICIAL_ARGUMENT_MISSING' }
        $variadic = $declaredArguments.Count -and $declaredArguments[-1].variadic
        if ($positionals.Count -gt $declaredArguments.Count -and -not $variadic) { throw 'UNEXPECTED_OFFICIAL_ARGUMENT' }
        $command = Invoke-OfficialCommand -Tokens (@('rpa','uia') + $commandPath + $operands) -Kind $Subcategory -Mutating $true
        # No generic success schema is assumed across co-versioned UIA packages.
        # Caller must inspect the actual official artifacts and intended activity.
        if ($command.error -or [string]::IsNullOrWhiteSpace($command.output)) { throw 'OFFICIAL_RESULT_EMPTY_OR_ERROR_BEARING' }
        if ($command.output -match '(?im)^\s*(error|exception|failed)\b' -or
            $command.output -match '(?i)"success"\s*:\s*false' -or
            $command.output -match '(?i)"status"\s*:\s*"(error|failed|failure)"' -or
            $command.output -match '(?i)"errors?"\s*:\s*(?!null\b|\[\s*\]|""\s*[,}])\S') {
            throw 'OFFICIAL_RESULT_ERROR_BEARING'
        }
        $result.status = 'EXECUTED_UNVERIFIED'
        $result.reason = 'Official command executed. Interpret package-specific result/artifacts, bind via official guide, and prove the intended activity through the existing target resolver; this is NOT live proof.'
    }
} catch {
    $result.reason = $_.Exception.Message
}
if ($Json) { $result | ConvertTo-Json -Depth 8 } else { [pscustomobject]$result }
