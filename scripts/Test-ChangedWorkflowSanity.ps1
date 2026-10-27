[CmdletBinding()]
param(
    [string]$ProjectPath = (Get-Location).Path,
    [Parameter(Mandatory=$true)]
    [string[]]$ChangedFiles,
    [string[]]$ExpectedActivityLocalNames = @(),
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$ProjectPath = (Resolve-Path $ProjectPath).Path
$errors = New-Object System.Collections.Generic.List[object]
$warnings = New-Object System.Collections.Generic.List[object]
$workflows = New-Object System.Collections.Generic.List[object]
$foundActivities = @{}
$robustnessModule = Join-Path $PSScriptRoot 'UiWorkflowRobustness.psm1'
if (-not (Test-Path -LiteralPath $robustnessModule -PathType Leaf)) { throw "UI robustness helper is missing: $robustnessModule" }
Import-Module $robustnessModule -Force -DisableNameChecking

function Normalize-RelativePath {
    param([string]$Path)
    $candidate = $Path -replace '\\','/'
    while ($candidate.StartsWith('./')) { $candidate = $candidate.Substring(2) }
    if ([System.IO.Path]::IsPathRooted($candidate) -or $candidate.StartsWith('/')) { return $null }
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($part in ($candidate -split '/')) {
        if (-not $part -or $part -eq '.') { continue }
        if ($part -eq '..') {
            if ($parts.Count -eq 0) { return $null }
            $parts.RemoveAt($parts.Count - 1)
        } else { $parts.Add($part) }
    }
    return $parts -join '/'
}

function Add-Issue {
    param([System.Collections.Generic.List[object]]$List, [string]$Code, [string]$Path, [string]$Message)
    [void]$List.Add([ordered]@{ code = $Code; path = $Path; message = $Message })
}

foreach ($changedFile in @($ChangedFiles | Select-Object -Unique)) {
    $relative = Normalize-RelativePath $changedFile
    if (-not $relative) {
        Add-Issue $errors 'PATH_OUTSIDE_PROJECT' $changedFile 'Changed path is not a valid project-relative path.'
        continue
    }
    if ([System.IO.Path]::GetExtension($relative) -ine '.xaml') { continue }
    $fullPath = [System.IO.Path]::GetFullPath((Join-Path $ProjectPath ($relative -replace '/','\')))
    $rootPrefix = $ProjectPath.TrimEnd('\','/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        Add-Issue $errors 'PATH_OUTSIDE_PROJECT' $relative 'Changed workflow resolves outside the project.'
        continue
    }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        Add-Issue $errors 'CHANGED_WORKFLOW_MISSING' $relative 'Changed workflow does not exist.'
        continue
    }

    try {
        $settings = New-Object System.Xml.XmlReaderSettings
        $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $reader = [System.Xml.XmlReader]::Create($fullPath, $settings)
        try {
            $document = New-Object System.Xml.XmlDocument
            $document.XmlResolver = $null
            $document.Load($reader)
        } finally { $reader.Dispose() }
    } catch {
        Add-Issue $errors 'MALFORMED_XAML' $relative $_.Exception.Message
        continue
    }

    $activityNames = @($document.SelectNodes('//*') | ForEach-Object { [string]$_.LocalName } | Sort-Object -Unique)
    foreach ($activityName in $activityNames) { $foundActivities[$activityName.ToLowerInvariant()] = $true }
    $argumentNames = @($document.SelectNodes("//*[local-name()='Members']/*[local-name()='Property']") | ForEach-Object {
        $attribute = $_.Attributes | Where-Object { $_.LocalName -eq 'Name' } | Select-Object -First 1
        if ($attribute) { [string]$attribute.Value }
    } | Where-Object { $_ })
    $duplicateArguments = @($argumentNames | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name)
    if ($duplicateArguments.Count -gt 0) {
        Add-Issue $errors 'DUPLICATE_ARGUMENT' $relative ("Duplicate workflow argument name(s): " + ($duplicateArguments -join ', '))
    }

    $staticInvokes = @()
    foreach ($node in @($document.SelectNodes("//*[local-name()='InvokeWorkflowFile']"))) {
        $raw = ''
        foreach ($attribute in @($node.Attributes)) {
            if ($attribute.LocalName -in @('WorkflowFileName','WorkflowFilePath','FileName')) { $raw = [string]$attribute.Value; break }
        }
        $raw = $raw.Trim()
        if (-not $raw -or $raw -match '^\s*\[' -or $raw -match '[{}]' -or $raw -notmatch '(?i)\.xaml\s*$') {
            Add-Issue $warnings 'DYNAMIC_OR_UNREADABLE_INVOKE' $relative "Invoke target '$raw' was not statically validated."
            continue
        }
        $target = Normalize-RelativePath $raw
        $sourceDirectory = [System.IO.Path]::GetDirectoryName($relative) -replace '\\','/'
        $candidates = @($target)
        if ($sourceDirectory -and $target) { $candidates += Normalize-RelativePath ($sourceDirectory + '/' + $target) }
        $resolvedTarget = $null
        foreach ($candidate in @($candidates | Where-Object { $_ } | Select-Object -Unique)) {
            $candidatePath = Join-Path $ProjectPath ($candidate -replace '/','\')
            if (Test-Path -LiteralPath $candidatePath -PathType Leaf) { $resolvedTarget = $candidate; break }
        }
        if (-not $resolvedTarget) { Add-Issue $errors 'MISSING_INVOKED_WORKFLOW' $relative "Static Invoke Workflow target '$raw' does not exist." }
        else { $staticInvokes += $resolvedTarget }
    }

    $uiFindings = @(Get-UiWorkflowRobustnessFindings $document)
    foreach ($finding in $uiFindings) {
        if ($finding.severity -eq 'ERROR') { Add-Issue $errors $finding.code $relative $finding.message }
        else { Add-Issue $warnings $finding.code $relative $finding.message }
    }

    [void]$workflows.Add([ordered]@{
        path = $relative
        activityCount = $activityNames.Count
        arguments = @($argumentNames)
        staticInvokes = @($staticInvokes | Select-Object -Unique)
    })
}

foreach ($expected in @($ExpectedActivityLocalNames | Where-Object { $_ } | Select-Object -Unique)) {
    if (-not $foundActivities.ContainsKey($expected.ToLowerInvariant())) {
        Add-Issue $errors 'EXPECTED_ACTIVITY_MISSING' '' "Expected activity local name '$expected' was not found in the changed workflows."
    }
}

$result = [ordered]@{
    schemaVersion = 1
    status = if ($errors.Count -eq 0) { 'PASS' } else { 'FAIL' }
    changedWorkflowCount = $workflows.Count
    workflows = $workflows.ToArray()
    errors = $errors.ToArray()
    warnings = $warnings.ToArray()
}
if ($Json) { $result | ConvertTo-Json -Depth 10 } else { $result }
if ($errors.Count -gt 0 -and -not $Json) { throw "Changed workflow sanity failed with $($errors.Count) error(s)." }
