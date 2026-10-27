[CmdletBinding()]
param(
    [string]$ProjectPath = (Get-Location).Path,
    [string]$CachePath,
    [string]$OutputPath,
    [switch]$NoCache,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$startedAt = [DateTime]::UtcNow
$ProjectPath = (Resolve-Path $ProjectPath).Path
$telemetryEnabled = Test-Path -LiteralPath (Join-Path $ProjectPath '.ai\evidence\execution-state.json') -PathType Leaf
$telemetryEvent = $null
if ($telemetryEnabled) {
    Import-Module (Join-Path $PSScriptRoot 'DeveloperTelemetry.psm1') -Force -DisableNameChecking
    $telemetryEvent = Start-DeveloperEvent -ProjectPath $ProjectPath -Category MAPPER -Subcategory project_map -Operation 'mapper.project_map' -NowUtc $startedAt.ToString('o')
}
$projectFile = Join-Path $ProjectPath 'project.json'
if (-not (Test-Path $projectFile -PathType Leaf)) { throw "UiPath project.json was not found under '$ProjectPath'." }

$schemaVersion = 1
$cacheSchemaVersion = 1
$CachePath = if ($CachePath) { [System.IO.Path]::GetFullPath($CachePath) } else { Join-Path $ProjectPath '.devkit\cache\project-map-cache.json' }
$excludedSegments = @('.git','.devkit','.rpa-ai','.ai','Requirements','graphify-out','bin','obj','packages','node_modules','TestResults','test-results','.venv','venv')

# Activity classification is intentionally small and declarative. Add activity local names here;
# XML namespace prefixes are never part of the match.
$capabilityRules = [ordered]@{
    'Browser / UI Automation' = '^(UseApplicationBrowser|ApplicationCard|NApplicationCard|OpenBrowser|AttachBrowser|CloseTab|Click|NClick|DoubleClick|Hover|TypeInto|NTypeInto|SetText|GetText|GetAttribute|ElementExists|UiElementExists|SelectItem|Check|Uncheck|TakeScreenshot)$'
    'Excel' = '^(ExcelApplicationScope|UseExcelFile|ReadRange|WriteRange|AppendRange|ReadCell|WriteCell|AddDataRow|CreateTable|FilterTable|SortTable|SaveExcelFile)$'
    'Mail' = '^(SendOutlookMailMessage|GetOutlookMailMessages|MoveOutlookMailMessage|SaveMailAttachments|SendSmtpMailMessage|GetImapMailMessages|GetPop3MailMessages)$'
    'Queue / Orchestrator' = '^(AddQueueItem|AddQueueItems|GetTransactionItem|GetQueueItems|SetTransactionStatus|PostponeTransactionItem|DeleteQueueItems|GetAsset|GetCredential|SetAsset|SetCredential)$'
    'File' = '^(MoveFile|CopyFile|DeleteFile|CreateFile|AppendLine|WriteTextFile|ReadTextFile|PathExists|CreateFolder|DeleteFolder|MoveFolder|CopyFolder|CompressZipFiles|ExtractUnzipFiles)$'
    'HTTP' = '^(HttpRequest|HTTPRequest)$'
    'Logging' = '^(LogMessage|WriteLine|AddLogFields|RemoveLogFields)$'
    'Workflow Invocation' = '^(InvokeWorkflowFile)$'
}

function Get-NormalizedRelativePath {
    param([string]$FullPath)
    return $FullPath.Substring($ProjectPath.Length).TrimStart('\','/') -replace '\\','/'
}

function Normalize-ProjectPath {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $candidate = $Value.Trim().Trim('"').Trim("'") -replace '\\','/'
    if ($candidate.StartsWith('/') -or [System.IO.Path]::IsPathRooted($candidate)) { return $null }
    while ($candidate.StartsWith('./')) { $candidate = $candidate.Substring(2) }
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

function Get-DisplayPath {
    param([string]$Path)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $projectPrefix = $ProjectPath.TrimEnd('\','/') + [System.IO.Path]::DirectorySeparatorChar
    if ($fullPath.StartsWith($projectPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { return Get-NormalizedRelativePath $fullPath }
    return $fullPath
}

function Test-ExcludedPath {
    param([string]$RelativePath)
    return [bool](($RelativePath -split '/') | Where-Object { $_ -in $excludedSegments } | Select-Object -First 1)
}

function Get-JsonPropertyValue {
    param($Object, [string[]]$Names)
    if ($null -eq $Object) { return $null }
    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties | Where-Object { $_.Name -ieq $name } | Select-Object -First 1
        if ($property -and $null -ne $property.Value -and [string]$property.Value -ne '') { return $property.Value }
    }
    return $null
}

function Add-Warning {
    param(
        [System.Collections.Generic.List[object]]$List,
        [string]$Code,
        [string]$Path,
        [string]$Message
    )
    [void]$List.Add([ordered]@{ code = $Code; path = $Path; message = $Message })
}

function Get-ProjectMetadata {
    param($Document)
    $designOptions = Get-JsonPropertyValue $Document @('designOptions')
    $entryPointItems = @()
    foreach ($entry in @(Get-JsonPropertyValue $Document @('entryPoints'))) {
        $entryPath = if ($entry -is [string]) { [string]$entry } else { [string](Get-JsonPropertyValue $entry @('filePath','path','workflowFile')) }
        if ($entryPath) {
            $normalized = Normalize-ProjectPath $entryPath
            if ($normalized) { $entryPointItems += $normalized }
        }
    }
    $main = [string](Get-JsonPropertyValue $Document @('main','mainWorkflow'))
    $main = Normalize-ProjectPath $main
    if ($main -and $main -notin $entryPointItems) { $entryPointItems = @($main) + @($entryPointItems) }

    $dependencies = New-Object System.Collections.Generic.List[object]
    $dependencyObject = Get-JsonPropertyValue $Document @('dependencies')
    if ($dependencyObject) {
        foreach ($property in @($dependencyObject.PSObject.Properties | Sort-Object Name)) {
            $value = $property.Value
            $version = if ($value -is [string]) { [string]$value } else { [string](Get-JsonPropertyValue $value @('version','requestedVersion','resolvedVersion')) }
            [void]$dependencies.Add([ordered]@{ name = [string]$property.Name; version = $version })
        }
    }

    $projectType = Get-JsonPropertyValue $Document @('projectType','type')
    if (-not $projectType) { $projectType = Get-JsonPropertyValue $designOptions @('outputType','projectType') }
    [ordered]@{
        name = [string](Get-JsonPropertyValue $Document @('name','projectName'))
        main = $main
        entryPoints = @($entryPointItems | Select-Object -Unique)
        type = if ($projectType) { [string]$projectType } else { $null }
        expressionLanguage = [string](Get-JsonPropertyValue $Document @('expressionLanguage'))
        dependencies = $dependencies.ToArray()
    }
}

function Get-RequirementsMetadata {
    $requirementsPath = Join-Path $ProjectPath 'Requirements'
    $exists = Test-Path -LiteralPath $requirementsPath -PathType Container
    $files = if ($exists) {
        @(Get-ChildItem -LiteralPath $requirementsPath -Recurse -File -Force | Sort-Object FullName | ForEach-Object {
            $extension = $_.Extension.ToLowerInvariant()
            [ordered]@{
                path = Get-NormalizedRelativePath $_.FullName
                extension = $extension
                bytes = [int64]$_.Length
                supportedForInspection = $extension -in @('.md','.txt','.docx','.pdf','.png','.jpg','.jpeg','.xlsx','.csv')
            }
        })
    } else { @() }
    return [ordered]@{
        ownership = 'HUMAN'
        folderExists = [bool]$exists
        entryPointExists = [bool](Test-Path -LiteralPath (Join-Path $requirementsPath 'REQUIREMENTS.md') -PathType Leaf)
        supportingFileCount = @($files | Where-Object { $_.path -ine 'Requirements/REQUIREMENTS.md' }).Count
        files = @($files)
        contentIncluded = $false
    }
}

function Get-WorkflowMetadata {
    param([System.IO.FileInfo]$File, [string]$RelativePath)

    $warnings = New-Object System.Collections.Generic.List[string]
    $arguments = New-Object System.Collections.Generic.List[object]
    $invocations = New-Object System.Collections.Generic.List[object]
    $capabilities = New-Object System.Collections.Generic.List[string]
    try {
        $settings = New-Object System.Xml.XmlReaderSettings
        $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $reader = [System.Xml.XmlReader]::Create($File.FullName, $settings)
        try {
            $document = New-Object System.Xml.XmlDocument
            $document.XmlResolver = $null
            $document.Load($reader)
        } finally { $reader.Dispose() }

        foreach ($node in @($document.SelectNodes("//*[local-name()='Members']/*[local-name()='Property']"))) {
            $nameAttribute = @($node.Attributes | Where-Object { $_.LocalName -eq 'Name' } | Select-Object -First 1)
            $typeAttribute = @($node.Attributes | Where-Object { $_.LocalName -eq 'Type' } | Select-Object -First 1)
            if (-not $nameAttribute) { continue }
            $argumentName = [string]$nameAttribute.Value
            $direction = if ($argumentName -match '^(?i)in_') { 'In' } elseif ($argumentName -match '^(?i)out_') { 'Out' } elseif ($argumentName -match '^(?i)io_') { 'InOut' } else { 'Unknown' }
            [void]$arguments.Add([ordered]@{ name = $argumentName; type = [string]$typeAttribute.Value; direction = $direction })
        }

        foreach ($element in @($document.SelectNodes('//*'))) {
            $localName = [string]$element.LocalName
            foreach ($category in $capabilityRules.Keys) {
                if ($localName -match $capabilityRules[$category] -and $category -notin $capabilities) { [void]$capabilities.Add($category) }
            }
        }

        foreach ($invokeNode in @($document.SelectNodes("//*[local-name()='InvokeWorkflowFile']"))) {
            $rawValue = ''
            foreach ($attribute in @($invokeNode.Attributes)) {
                if ($attribute.LocalName -in @('WorkflowFileName','WorkflowFilePath','FileName')) { $rawValue = [string]$attribute.Value; break }
            }
            if (-not $rawValue) {
                $propertyNode = @($invokeNode.ChildNodes | Where-Object { $_.LocalName -match '(WorkflowFileName|WorkflowFilePath|FileName)$' } | Select-Object -First 1)
                if ($propertyNode) { $rawValue = [string]$propertyNode.InnerText }
            }
            $rawValue = $rawValue.Trim()
            if (-not $rawValue) {
                [void]$warnings.Add('INVOKE_TARGET_MISSING: Invoke Workflow File has no readable workflow path.')
                [void]$invocations.Add([ordered]@{ target = $null; resolved = $false; dynamic = $true; expression = '' })
                continue
            }
            $isDynamic = $rawValue -match '^\s*\[' -or $rawValue -match '[{}]' -or $rawValue -notmatch '(?i)\.xaml\s*$'
            if ($isDynamic) {
                [void]$warnings.Add("DYNAMIC_INVOKE: '$rawValue' was preserved without guessing a target.")
                [void]$invocations.Add([ordered]@{ target = $null; resolved = $false; dynamic = $true; expression = $rawValue })
            } else {
                $normalized = Normalize-ProjectPath $rawValue
                if (-not $normalized) {
                    [void]$warnings.Add("INVOKE_OUTSIDE_PROJECT: '$rawValue' cannot be normalized inside the project.")
                    [void]$invocations.Add([ordered]@{ target = $null; resolved = $false; dynamic = $false; expression = $rawValue })
                } else {
                    [void]$invocations.Add([ordered]@{ target = $normalized; resolved = $false; dynamic = $false; expression = $rawValue })
                }
            }
        }
    } catch {
        [void]$warnings.Add("MALFORMED_XAML: $($_.Exception.Message)")
    }

    return [ordered]@{
        path = $RelativePath
        invokes = $invocations.ToArray()
        arguments = $arguments.ToArray()
        capabilities = @($capabilities | Sort-Object)
        parsingWarnings = $warnings.ToArray()
    }
}

$warnings = New-Object System.Collections.Generic.List[object]
try { $projectDocument = Get-Content $projectFile -Raw | ConvertFrom-Json }
catch { throw "project.json could not be parsed: $($_.Exception.Message)" }
$projectMetadata = Get-ProjectMetadata $projectDocument

$cachedByPath = @{}
$cacheStatus = if ($NoCache) { 'DISABLED' } else { 'MISS' }
if (-not $NoCache -and (Test-Path $CachePath -PathType Leaf)) {
    try {
        $cache = Get-Content $CachePath -Raw | ConvertFrom-Json
        if ([int]$cache.schemaVersion -ne $cacheSchemaVersion) { throw "Unsupported cache schema $($cache.schemaVersion)." }
        foreach ($record in @($cache.workflows)) { $cachedByPath[[string]$record.path] = $record }
        $cacheStatus = 'VALID'
    } catch {
        $cacheStatus = 'INVALID'
        Add-Warning $warnings 'CACHE_INVALID' (Get-DisplayPath $CachePath) "The project-map cache was ignored and rebuilt: $($_.Exception.Message)"
        $cachedByPath = @{}
    }
}

$workflowFiles = @(Get-ChildItem -LiteralPath $ProjectPath -Recurse -File -Filter '*.xaml' -Force | Where-Object {
    $relative = Get-NormalizedRelativePath $_.FullName
    -not (Test-ExcludedPath $relative)
} | Sort-Object { Get-NormalizedRelativePath $_.FullName })

$workflowRecords = New-Object System.Collections.Generic.List[object]
$workflowCache = New-Object System.Collections.Generic.List[object]
$parsedCount = 0
$reusedCount = 0
$currentPaths = @{}
foreach ($file in $workflowFiles) {
    $relative = Get-NormalizedRelativePath $file.FullName
    $currentPaths[$relative] = $true
    $cached = $cachedByPath[$relative]
    if (-not $NoCache -and $cached -and [int64]$cached.length -eq [int64]$file.Length -and [int64]$cached.lastWriteTicks -eq [int64]$file.LastWriteTimeUtc.Ticks -and $cached.metadata) {
        $metadata = $cached.metadata
        $reusedCount++
    } else {
        $metadata = Get-WorkflowMetadata $file $relative
        $parsedCount++
    }
    [void]$workflowRecords.Add($metadata)
    $cacheMetadata = $metadata | ConvertTo-Json -Depth 15 | ConvertFrom-Json
    [void]$workflowCache.Add([ordered]@{
        path = $relative
        length = [int64]$file.Length
        lastWriteTicks = [int64]$file.LastWriteTimeUtc.Ticks
        metadata = $cacheMetadata
    })
}
$deletedCount = @($cachedByPath.Keys | Where-Object { -not $currentPaths.ContainsKey($_) }).Count

$workflowLookup = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($record in $workflowRecords) { $workflowLookup[[string]$record.path] = [string]$record.path }

$edges = New-Object System.Collections.Generic.List[object]
$forward = [ordered]@{}
$reverseLists = @{}
foreach ($record in $workflowRecords) {
    $source = [string]$record.path
    $forward[$source] = @()
    foreach ($invoke in @($record.invokes)) {
        if ($invoke.dynamic -or -not $invoke.target) {
            [void]$edges.Add([ordered]@{ source = $source; target = $null; resolved = $false; dynamic = $true; expression = [string]$invoke.expression })
            continue
        }
        $target = [string]$invoke.target
        if (-not $workflowLookup.ContainsKey($target)) {
            $sourceDirectory = [System.IO.Path]::GetDirectoryName($source) -replace '\\','/'
            if ($sourceDirectory) {
                $relativeCandidate = Normalize-ProjectPath ($sourceDirectory + '/' + $target)
                if ($relativeCandidate -and $workflowLookup.ContainsKey($relativeCandidate)) { $target = $workflowLookup[$relativeCandidate] }
            }
        } else { $target = $workflowLookup[$target] }
        $resolved = $workflowLookup.ContainsKey($target)
        $invoke.target = $target
        $invoke.resolved = $resolved
        $forward[$source] = @($forward[$source]) + $target
        if (-not $reverseLists.ContainsKey($target)) { $reverseLists[$target] = New-Object System.Collections.Generic.List[string] }
        [void]$reverseLists[$target].Add($source)
        [void]$edges.Add([ordered]@{ source = $source; target = $target; resolved = $resolved; dynamic = $false; expression = [string]$invoke.expression })
        if (-not $resolved) {
            $missingMessage = "MISSING_WORKFLOW: Referenced workflow '$target' was not found."
            if ($missingMessage -notin @($record.parsingWarnings)) { $record.parsingWarnings = @($record.parsingWarnings) + $missingMessage }
            Add-Warning $warnings 'MISSING_WORKFLOW' $source "Referenced workflow '$target' was not found."
        }
    }
    $forward[$source] = @($forward[$source] | Select-Object -Unique)
}

$reverse = [ordered]@{}
foreach ($record in $workflowRecords) {
    $path = [string]$record.path
    $reverse[$path] = if ($reverseLists.ContainsKey($path)) { @($reverseLists[$path] | Select-Object -Unique) } else { @() }
    foreach ($message in @($record.parsingWarnings)) {
        if ($message -like 'MALFORMED_XAML:*') { Add-Warning $warnings 'MALFORMED_XAML' $path $message }
        elseif ($message -like 'DYNAMIC_INVOKE:*') { Add-Warning $warnings 'DYNAMIC_INVOKE' $path $message }
        elseif ($message -like 'INVOKE_TARGET_MISSING:*') { Add-Warning $warnings 'INVOKE_TARGET_MISSING' $path $message }
        elseif ($message -like 'INVOKE_OUTSIDE_PROJECT:*') { Add-Warning $warnings 'INVOKE_OUTSIDE_PROJECT' $path $message }
    }
}

$workflowMap = [ordered]@{}
foreach ($record in $workflowRecords) {
    $workflowMap[[string]$record.path] = [ordered]@{
        invokes = @($record.invokes)
        arguments = @($record.arguments)
        capabilities = @($record.capabilities)
        parsingWarnings = @($record.parsingWarnings)
    }
}

$result = [ordered]@{
    schemaVersion = $schemaVersion
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    project = $projectMetadata
    requirements = Get-RequirementsMetadata
    workflows = $workflowMap
    edges = $edges.ToArray()
    dependencies = [ordered]@{ forward = $forward; reverse = $reverse }
    resources = [ordered]@{}
    warnings = $warnings.ToArray()
    metrics = [ordered]@{
        mappingDurationMs = 0
        xamlFilesMapped = $workflowFiles.Count
        xamlFilesParsed = $parsedCount
        cacheHits = $reusedCount
        deletedWorkflows = $deletedCount
        cacheStatus = $cacheStatus
    }
}

if (-not $NoCache) {
    try {
        $cacheDocument = [ordered]@{ schemaVersion = $cacheSchemaVersion; generatedAtUtc = [DateTime]::UtcNow.ToString('o'); workflows = $workflowCache.ToArray() }
        New-Item -ItemType Directory -Force -Path (Split-Path $CachePath -Parent) | Out-Null
        [System.IO.File]::WriteAllText($CachePath, (($cacheDocument | ConvertTo-Json -Depth 20) + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        $result.metrics.cacheStatus = 'WRITE_FAILED'
        Add-Warning $warnings 'CACHE_WRITE_FAILED' (Get-DisplayPath $CachePath) "The map is valid but its optional cache could not be written: $($_.Exception.Message)"
        $result.warnings = $warnings.ToArray()
    }
}

$result.metrics.mappingDurationMs = [Math]::Round(([DateTime]::UtcNow - $startedAt).TotalMilliseconds, 3)
if ($OutputPath) {
    $fullOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
    New-Item -ItemType Directory -Force -Path (Split-Path $fullOutputPath -Parent) | Out-Null
    [System.IO.File]::WriteAllText($fullOutputPath, (($result | ConvertTo-Json -Depth 20) + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
}
if ($telemetryEvent) {
    $artifacts = if($OutputPath){@([ordered]@{path=$(if($fullOutputPath.StartsWith($ProjectPath.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){$fullOutputPath.Substring($ProjectPath.TrimEnd('\','/').Length).TrimStart('\','/') -replace '\\','/'}else{$fullOutputPath})})}else{@()}
    Stop-DeveloperEvent -ProjectPath $ProjectPath -EventId $telemetryEvent.eventId -Status PASS -Artifacts $artifacts | Out-Null
}
if ($Json) { $result | ConvertTo-Json -Depth 20 } else { $result }
