[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9._-]*$')]
    [string]$ProjectName,

    [Parameter(Mandatory=$true)]
    [ValidateSet('Process','REFramework')]
    [string]$ProjectType,

    [Parameter(Mandatory=$true)]
    [ValidateSet('Windows','Portable')]
    [string]$TargetFramework,

    [ValidateSet('VisualBasic','CSharp')]
    [string]$ExpressionLanguage = 'VisualBasic',

    [string]$Description = '',
    [string]$TargetBotPath = (Get-Location).Path,
    [string]$TemplatePackageId,
    [string]$TemplatePackageVersion
)

$ErrorActionPreference = 'Stop'
$TargetBotPath = (Resolve-Path $TargetBotPath).Path

if (Test-Path (Join-Path $TargetBotPath 'project.json')) {
    throw "A UiPath project already exists in $TargetBotPath"
}

$resolverScript = Join-Path $PSScriptRoot 'Resolve-DevKitTool.ps1'
$commandScript = Join-Path $PSScriptRoot 'Invoke-DevKitCommand.ps1'
$executionStateScript = Join-Path $PSScriptRoot 'ExecutionState.ps1'
$telemetryModule = Join-Path $PSScriptRoot 'DeveloperTelemetry.psm1'
$requirementsScript = Join-Path $PSScriptRoot 'Manage-RequirementsWorkspace.ps1'
if (-not (Test-Path $resolverScript -PathType Leaf)) { throw "Tool resolver is missing: $resolverScript" }
if (-not (Test-Path $commandScript -PathType Leaf)) { throw "Command helper is missing: $commandScript" }
if (-not (Test-Path $requirementsScript -PathType Leaf)) { throw "Requirements workspace helper is missing: $requirementsScript" }
. $resolverScript
$uipCommand = Resolve-DevKitTool -Name uip -TargetBotPath $TargetBotPath -Required
$executionStatePath = Join-Path $TargetBotPath '.ai\evidence\execution-state.json'
$executionStageStarted = (Test-Path $executionStateScript -PathType Leaf) -and (Test-Path $executionStatePath -PathType Leaf)
$scaffoldTelemetryEvent = $null
$scaffoldTelemetryCompleted = $false
$templateResolutionEvent = $null
$templateResolutionCompleted = $false
$directoryEvent = $null
$directoryEventCompleted = $false
if ($executionStageStarted -and (Test-Path $telemetryModule -PathType Leaf)) {
    Import-Module $telemetryModule -Force
    $scaffoldTelemetryEvent = Start-DeveloperEvent -ProjectPath $TargetBotPath -Category SCAFFOLDING -Subcategory total -Operation 'scaffolding.total'
}
trap {
    $trappedError = $_
    try {
        if ($templateResolutionEvent -and -not $templateResolutionCompleted) { Stop-DeveloperEvent -ProjectPath $TargetBotPath -EventId $templateResolutionEvent.eventId -Status FAIL -Reason $trappedError.Exception.Message | Out-Null }
        if ($directoryEvent -and -not $directoryEventCompleted) { Stop-DeveloperEvent -ProjectPath $TargetBotPath -EventId $directoryEvent.eventId -Status FAIL -Reason $trappedError.Exception.Message | Out-Null }
        if ($scaffoldTelemetryEvent -and -not $scaffoldTelemetryCompleted) {
            Stop-DeveloperEvent -ProjectPath $TargetBotPath -EventId $scaffoldTelemetryEvent.eventId -Status FAIL -Reason $trappedError.Exception.Message | Out-Null
            $scaffoldTelemetryCompleted = $true
        }
    } catch {
        # Telemetry is diagnostic and must not replace the authoritative scaffold failure.
    }
    throw $trappedError
}

function Test-UipCommand {
    param([string[]]$Arguments)

    $parentEventId = if ($templateResolutionEvent) { $templateResolutionEvent.eventId } elseif ($scaffoldTelemetryEvent) { $scaffoldTelemetryEvent.eventId } else { '' }
    $result = & $commandScript -FilePath $uipCommand -ArgumentList (@($Arguments) + '--help') -WorkingDirectory $TargetBotPath -TargetBotPath $TargetBotPath -ExecutionStatePath $executionStatePath -Operation 'UiPath CLI capability check' -Category SCAFFOLDING -Subcategory capability -ParentEventId $parentEventId -TimeoutSeconds 60 -Json | ConvertFrom-Json
    return $result.status -eq 'PASS'
}

function Invoke-UipJson {
    param([string[]]$Arguments, [string]$ParentEventId = '')

    $result = & $commandScript -FilePath $uipCommand -ArgumentList $Arguments -WorkingDirectory $TargetBotPath -TargetBotPath $TargetBotPath -ExecutionStatePath $executionStatePath -Operation 'UiPath CLI scaffolding operation' -Category SCAFFOLDING -Subcategory cli_create -ParentEventId $ParentEventId -TimeoutSeconds 300 -Json | ConvertFrom-Json
    return [pscustomobject]@{ Output = ([string]$result.output).Trim(); ExitCode = [int]$result.exit_code; Status = [string]$result.status; TimedOut = [bool]$result.timed_out }
}

function ConvertTo-TemplateList {
    param([string]$Json)

    if (-not $Json) { return @() }
    try {
        $parsed = $Json | ConvertFrom-Json
    } catch {
        throw "UiPath template search did not return valid JSON."
    }

    if ($parsed -is [System.Collections.IList]) { return @($parsed) }
    if ($parsed.PSObject.Properties.Name -contains 'Data') { return @($parsed.Data) }
    if ($parsed.PSObject.Properties.Name -contains 'data') { return @($parsed.data) }
    return @($parsed)
}

function Test-OfficialTemplate {
    param($Template)

    return $Template.source -eq 'Official' -or
        $Template.sourceType -eq 'Official' -or
        $Template.isOfficial -eq $true
}

$templateResolutionEvent = if ($scaffoldTelemetryEvent) { Start-DeveloperEvent -ProjectPath $TargetBotPath -Category SCAFFOLDING -Subcategory template_resolution -Operation 'scaffolding.template_resolution' -ParentEventId $scaffoldTelemetryEvent.eventId } else { $null }
$usesInit = Test-UipCommand @('rpa','init')
$usesCreateProject = if ($usesInit) { $false } else { Test-UipCommand @('rpa','create-project') }
if (-not $usesInit -and -not $usesCreateProject) {
    throw "The installed UiPath CLI exposes neither 'uip rpa init' nor 'uip rpa create-project'. Update the UiPath RPA tool."
}

$createVerb = if ($usesInit) { 'init' } else { 'create-project' }
$searchArguments = $null
$selectedTemplate = $null

if ($ProjectType -eq 'REFramework') {
    if (Test-UipCommand @('rpa','templates','search')) {
        $searchArguments = @('rpa','templates','search','--query',$(if ($TemplatePackageId) { $TemplatePackageId } else { 'REFramework' }),'--output','json')
    } elseif (Test-UipCommand @('rpa','search-templates')) {
        $searchArguments = @('rpa','search-templates','--query',$(if ($TemplatePackageId) { $TemplatePackageId } else { 'REFramework' }),'--output','json')
    } else {
        throw 'The installed UiPath CLI cannot search project templates. REFramework creation is blocked.'
    }

    $search = Invoke-UipJson $searchArguments $(if ($templateResolutionEvent) { $templateResolutionEvent.eventId } else { '' })
    if ($search.ExitCode -ne 0) {
        throw "UiPath template search failed with exit code $($search.ExitCode)."
    }

    $official = @(ConvertTo-TemplateList $search.Output | Where-Object { Test-OfficialTemplate $_ })
    if ($TemplatePackageId) {
        $official = @($official | Where-Object {
            [string]$_.packageId -eq $TemplatePackageId -and
            (-not $TemplatePackageVersion -or [string]$_.version -eq $TemplatePackageVersion)
        })
    }
    if ($official.Count -eq 0) {
        $requested = if ($TemplatePackageId) { " matching '$TemplatePackageId' version '$TemplatePackageVersion'" } else { '' }
        throw "No Official REFramework template$requested was found in the configured UiPath feeds. No Marketplace template was selected."
    }
    if ($official.Count -gt 1) {
        $choices = $official | ForEach-Object { "$($_.packageId) $($_.version)" }
        throw "Multiple Official REFramework templates were found. Re-run with -TemplatePackageId and -TemplatePackageVersion after choosing one: $($choices -join '; ')"
    }

    $selectedTemplate = $official[0]
    $TemplatePackageId = [string]$selectedTemplate.packageId
    $TemplatePackageVersion = [string]$selectedTemplate.version
}
if ($templateResolutionEvent) {
    Stop-DeveloperEvent -ProjectPath $TargetBotPath -EventId $templateResolutionEvent.eventId -Status PASS -Reason $(if ($ProjectType -eq 'Process') { 'Built-in BlankTemplate selected.' } else { "Official template $TemplatePackageId $TemplatePackageVersion selected." }) | Out-Null
    $templateResolutionCompleted = $true
}

$parent = Split-Path $TargetBotPath -Parent
$stagingContainer = Join-Path $parent ('.rpa-ai-scaffold-' + [guid]::NewGuid().ToString('N'))
$directoryEvent = if ($scaffoldTelemetryEvent) { Start-DeveloperEvent -ProjectPath $TargetBotPath -Category SCAFFOLDING -Subcategory directory_creation -Operation 'scaffolding.directory_creation' -ParentEventId $scaffoldTelemetryEvent.eventId } else { $null }
New-Item -ItemType Directory -Force -Path $stagingContainer | Out-Null
if ($directoryEvent) { Stop-DeveloperEvent -ProjectPath $TargetBotPath -EventId $directoryEvent.eventId -Status PASS -Artifacts @([ordered]@{path=$stagingContainer}) | Out-Null; $directoryEventCompleted = $true }
$generatedProject = Join-Path $stagingContainer $ProjectName

$createArguments = @(
    'rpa', $createVerb,
    '--name', $ProjectName,
    '--location', $stagingContainer,
    '--target-framework', $TargetFramework,
    '--expression-language', $ExpressionLanguage,
    '--output', 'json'
)
if ($Description) {
    $createArguments += @('--description', $Description)
}
if ($ProjectType -eq 'Process') {
    $createArguments += @('--template-id', 'BlankTemplate')
} else {
    $createArguments += @('--template-package-id', $TemplatePackageId)
    if ($TemplatePackageVersion) {
        $createArguments += @('--template-package-version', $TemplatePackageVersion)
    }
}

$stageStarted = $false
$creationEvent = if ($scaffoldTelemetryEvent) { Start-DeveloperEvent -ProjectPath $TargetBotPath -Category SCAFFOLDING -Subcategory $(if ($ProjectType -eq 'Process') { 'blank_template_creation' } else { 'official_template_creation' }) -Operation $(if ($ProjectType -eq 'Process') { 'scaffolding.blank_template_creation' } else { 'scaffolding.official_template_creation' }) -ParentEventId $scaffoldTelemetryEvent.eventId } else { $null }
$creationStatus = 'FAIL'
$created = $null
try {
    if ($executionStageStarted) {
        & $executionStateScript -Action StageStart -Stage scaffolding -TargetBotPath $TargetBotPath -StatePath $executionStatePath | Out-Null
        $stageStarted = $true
    }
    $created = Invoke-UipJson $createArguments $(if ($creationEvent) { $creationEvent.eventId } else { '' })
    $creationStatus = if ($created.ExitCode -in @(0, 7)) { 'PASS' } else { 'BLOCKED' }
}
finally {
    if ($stageStarted) {
        & $executionStateScript -Action StageEnd -Stage scaffolding -TargetBotPath $TargetBotPath -StatePath $executionStatePath | Out-Null
    }
    if ($creationEvent) {
        Stop-DeveloperEvent -ProjectPath $TargetBotPath -EventId $creationEvent.eventId -Status $creationStatus -ExitCode $(if ($created) { $created.ExitCode } else { $null }) | Out-Null
    }
}
$projectJson = Join-Path $generatedProject 'project.json'

if ($created.ExitCode -notin @(0, 7)) {
    throw "UiPath scaffolding failed with unsupported exit code $($created.ExitCode). Staging preserved at $stagingContainer"
}

if (-not (Test-Path $projectJson -PathType Leaf)) {
    throw "UiPath scaffolding did not create project.json. Exit code: $($created.ExitCode). Staging preserved at $stagingContainer"
}
if ($scaffoldTelemetryEvent) {
    Add-DeveloperInstantEvent -ProjectPath $TargetBotPath -Category SCAFFOLDING -Subcategory project_json_creation -Operation 'scaffolding.project_json_creation' -ParentEventId $scaffoldTelemetryEvent.eventId -Artifacts @([ordered]@{path=$projectJson}) | Out-Null
}

try {
    $project = Get-Content $projectJson -Raw | ConvertFrom-Json
} catch {
    throw "Generated project.json is invalid. Staging preserved at $stagingContainer"
}

$workflows = @(Get-ChildItem $generatedProject -Recurse -File -Filter '*.xaml')
if ($workflows.Count -eq 0) {
    throw "UiPath scaffolding created no XAML workflow. Staging preserved at $stagingContainer"
}
if ($scaffoldTelemetryEvent) {
    $mainPath = Join-Path $generatedProject ([string]$project.main)
    Add-DeveloperInstantEvent -ProjectPath $TargetBotPath -Category SCAFFOLDING -Subcategory main_xaml_initialization -Operation 'scaffolding.main_xaml_initialization' -ParentEventId $scaffoldTelemetryEvent.eventId -Status $(if (Test-Path $mainPath -PathType Leaf) { 'PASS' } else { 'FAIL' }) -Artifacts @([ordered]@{path=$mainPath}) | Out-Null
    $standardFolders = @('Input','Output','Log')
    $presentFolders = @($standardFolders | Where-Object { Test-Path (Join-Path $generatedProject $_) -PathType Container })
    Add-DeveloperInstantEvent -ProjectPath $TargetBotPath -Category SCAFFOLDING -Subcategory standard_folder_initialization -Operation 'scaffolding.standard_folder_initialization' -ParentEventId $scaffoldTelemetryEvent.eventId -Status $(if ($presentFolders.Count -eq $standardFolders.Count) { 'PASS' } else { 'SKIPPED' }) -Reason $(if ($presentFolders.Count -eq $standardFolders.Count) { 'Input, Output, and Log folders were emitted by the official template.' } else { 'One or more standard folders were not emitted by the official template; telemetry did not alter scaffold semantics.' }) | Out-Null
    Add-DeveloperInstantEvent -ProjectPath $TargetBotPath -Category SCAFFOLDING -Subcategory devkit_activation -Operation 'scaffolding.devkit_activation' -ParentEventId $scaffoldTelemetryEvent.eventId -Status $(if (Test-Path (Join-Path $TargetBotPath '.rpa-ai') -PathType Container) { 'PASS' } else { 'SKIPPED' }) -Reason 'Activation is an upstream prerequisite; this event records its observed state without repeating activation.' | Out-Null
}

$semanticErrors = @()
if ([string]$project.name -ne $ProjectName) { $semanticErrors += "name '$($project.name)'" }
if ([string]$project.targetFramework -ne $TargetFramework) { $semanticErrors += "targetFramework '$($project.targetFramework)'" }
if ([string]$project.expressionLanguage -ne $ExpressionLanguage) { $semanticErrors += "expressionLanguage '$($project.expressionLanguage)'" }
if ([string]$project.designOptions.outputType -ne 'Process') { $semanticErrors += "outputType '$($project.designOptions.outputType)'" }
if (-not $project.main -or -not (Test-Path (Join-Path $generatedProject ([string]$project.main)) -PathType Leaf)) {
    $semanticErrors += "main entry point '$($project.main)'"
}

if ($ProjectType -eq 'REFramework') {
    $workflowNames = @($workflows.BaseName | ForEach-Object { $_.ToLowerInvariant() })
    foreach ($requiredWorkflow in @('gettransactiondata','process','settransactionstatus')) {
        if ($workflowNames -notcontains $requiredWorkflow) {
            $semanticErrors += "missing REFramework workflow '$requiredWorkflow.xaml'"
        }
    }
}

if ($semanticErrors.Count -gt 0) {
    throw "Generated project does not match the approved scaffold: $($semanticErrors -join '; '). Staging preserved at $stagingContainer"
}

$generatedRootPrefix = $generatedProject.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
$generatedFileRecords = @(Get-ChildItem $generatedProject -Recurse -File | ForEach-Object {
    if (-not $_.FullName.StartsWith($generatedRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Generated file escapes the staging project: $($_.FullName)"
    }
    [pscustomobject]@{
        Path = $_.FullName.Substring($generatedRootPrefix.Length).Replace('\','/')
        Hash = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
})

$collisions = @(Get-ChildItem $generatedProject -Force | Where-Object { Test-Path (Join-Path $TargetBotPath $_.Name) })
if ($collisions.Count -gt 0) {
    throw "Generated project files would collide with existing bot-root paths: $($collisions.Name -join ', '). Staging preserved at $stagingContainer"
}

$evidenceDirectory = Join-Path $TargetBotPath '.ai\evidence'
$evidencePath = Join-Path $evidenceDirectory 'project-scaffold.json'
if (Test-Path $evidencePath) {
    throw "Scaffold evidence already exists and is bot-owned: $evidencePath. Staging preserved at $stagingContainer"
}
$copiedPaths = [System.Collections.Generic.List[string]]::new()
$transferEvent = $null
$transferEventCompleted = $false
$evidenceEvent = $null
$evidenceEventCompleted = $false

try {
    if ($scaffoldTelemetryEvent) { $transferEvent = Start-DeveloperEvent -ProjectPath $TargetBotPath -Category SCAFFOLDING -Subcategory transfer -Operation 'scaffolding.transfer' -ParentEventId $scaffoldTelemetryEvent.eventId }
    foreach ($item in Get-ChildItem $generatedProject -Force) {
        $destination = Join-Path $TargetBotPath $item.Name
        $copiedPaths.Add($destination)
        Copy-Item $item.FullName $destination -Recurse
    }

    foreach ($file in $generatedFileRecords) {
        $transferredPath = Join-Path $TargetBotPath $file.Path
        if (-not (Test-Path $transferredPath -PathType Leaf)) {
            throw "Transferred scaffold is missing '$($file.Path)'."
        }
        $transferredHash = (Get-FileHash $transferredPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($transferredHash -ne $file.Hash) {
            throw "Transferred scaffold hash mismatch for '$($file.Path)'."
        }
    }
    if ($transferEvent) {
        Stop-DeveloperEvent -ProjectPath $TargetBotPath -EventId $transferEvent.eventId -Status PASS -Reason "$($generatedFileRecords.Count) generated files transferred and hash-verified." | Out-Null
        $transferEventCompleted = $true
    }

    if ($scaffoldTelemetryEvent) { $evidenceEvent = Start-DeveloperEvent -ProjectPath $TargetBotPath -Category SCAFFOLDING -Subcategory initial_evidence_setup -Operation 'scaffolding.initial_evidence_setup' -ParentEventId $scaffoldTelemetryEvent.eventId }
    New-Item -ItemType Directory -Force -Path $evidenceDirectory | Out-Null
    $evidence = [ordered]@{
        schemaVersion = 1
        generatedAtUtc = [DateTime]::UtcNow.ToString('o')
        generator = 'official UiPath CLI'
        commandFamily = "uip rpa $createVerb"
        projectName = [string]$project.name
        projectType = $ProjectType
        targetFramework = [string]$project.targetFramework
        expressionLanguage = [string]$project.expressionLanguage
        outputType = [string]$project.designOptions.outputType
        main = [string]$project.main
        template = if ($ProjectType -eq 'Process') {
            [ordered]@{ id = 'BlankTemplate'; packageId = $null; version = $null; source = 'BuiltIn' }
        } else {
            [ordered]@{
                id = $null
                packageId = [string]$selectedTemplate.packageId
                version = [string]$selectedTemplate.version
                source = 'Official'
                title = [string]$selectedTemplate.title
            }
        }
        cliExitCode = $created.ExitCode
        partialSuccessAccepted = $created.ExitCode -eq 7
        generatedFiles = @($generatedFileRecords.Path)
        transferHashVerification = 'PASS'
        generatedBehaviorEdited = $false
    }
    $evidenceJson = $evidence | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($evidencePath, $evidenceJson + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
    if ($evidenceEvent) {
        Stop-DeveloperEvent -ProjectPath $TargetBotPath -EventId $evidenceEvent.eventId -Status PASS -Artifacts @([ordered]@{path=$evidencePath;sha256=(Get-FileHash $evidencePath -Algorithm SHA256).Hash.ToLowerInvariant();bytes=(Get-Item $evidencePath).Length}) | Out-Null
        $evidenceEventCompleted = $true
    }
}
catch {
    if ($transferEvent -and -not $transferEventCompleted) { Stop-DeveloperEvent -ProjectPath $TargetBotPath -EventId $transferEvent.eventId -Status FAIL -Reason $_.Exception.Message | Out-Null }
    if ($evidenceEvent -and -not $evidenceEventCompleted) { Stop-DeveloperEvent -ProjectPath $TargetBotPath -EventId $evidenceEvent.eventId -Status FAIL -Reason $_.Exception.Message | Out-Null }
    foreach ($copiedPath in $copiedPaths) {
        Remove-Item $copiedPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $evidencePath -Force -ErrorAction SilentlyContinue
    throw "$($_.Exception.Message) Copied scaffold paths were rolled back. Staging preserved at $stagingContainer"
}

$requirementsResult = & $requirementsScript -Action InitializeNew -ProjectPath $TargetBotPath -ParentEventId $(if ($scaffoldTelemetryEvent) { $scaffoldTelemetryEvent.eventId } else { '' }) -Json | ConvertFrom-Json
if ($requirementsResult.status -ne 'PASS' -or -not $requirementsResult.folder.exists -or -not $requirementsResult.entryPoint.exists) {
    throw "Requirements workspace initialization did not complete. Project and staging are preserved at $TargetBotPath and $stagingContainer"
}

Remove-Item $stagingContainer -Recurse -Force
if ($scaffoldTelemetryEvent) {
    Stop-DeveloperEvent -ProjectPath $TargetBotPath -EventId $scaffoldTelemetryEvent.eventId -Status PASS -Artifacts @([ordered]@{path=$evidencePath}) | Out-Null
    $scaffoldTelemetryCompleted = $true
}

Write-Host "[PASS] Created $ProjectType project '$ProjectName' in $TargetBotPath"
Write-Host "[PASS] Scaffold evidence: $evidencePath"
Write-Host "[PASS] Human-owned requirements workspace: $(Join-Path $TargetBotPath 'Requirements\REQUIREMENTS.md')"
if ($created.ExitCode -eq 7) {
    Write-Host "[INFO] Accepted UiPath CLI partial-success exit $($created.ExitCode) after project structure and transfer hashes passed verification."
}
