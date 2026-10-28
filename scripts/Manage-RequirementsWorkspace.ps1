[CmdletBinding()]
param(
    [ValidateSet('Discover','InitializeNew')]
    [string]$Action = 'Discover',
    [string]$ProjectPath = (Get-Location).Path,
    [string]$TemplatePath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'templates\REQUIREMENTS.md'),
    [string]$ParentEventId = '',
    [bool]$DetailedTelemetry = $true,
    [switch]$ReadEntryPoint,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$ProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path
$projectFile = Join-Path $ProjectPath 'project.json'
if ($Action -eq 'InitializeNew' -and -not (Test-Path -LiteralPath $projectFile -PathType Leaf)) {
    throw "UiPath project.json was not found under '$ProjectPath'."
}

$requirementsPath = Join-Path $ProjectPath 'Requirements'
$entryPointPath = Join-Path $requirementsPath 'REQUIREMENTS.md'
$telemetryModule = Join-Path $PSScriptRoot 'DeveloperTelemetry.psm1'
$telemetryEnabled = $DetailedTelemetry -and (Test-Path -LiteralPath (Join-Path $ProjectPath '.ai\evidence\execution-state.json') -PathType Leaf) -and
    (Test-Path -LiteralPath $telemetryModule -PathType Leaf)
if ($telemetryEnabled) { Import-Module $telemetryModule -Force -DisableNameChecking }

$supportedTypes = [ordered]@{
    '.md' = 'markdown'; '.txt' = 'text'; '.docx' = 'word'; '.pdf' = 'pdf'
    '.png' = 'image'; '.jpg' = 'image'; '.jpeg' = 'image'; '.xlsx' = 'excel'; '.csv' = 'csv'
}

function Get-RelativeRequirementPath {
    param([string]$Path)
    return $Path.Substring($ProjectPath.Length).TrimStart('\','/') -replace '\\','/'
}

function Invoke-RequirementsEvent {
    param(
        [Parameter(Mandatory=$true)][string]$Operation,
        [Parameter(Mandatory=$true)][scriptblock]$Work,
        [scriptblock]$Artifacts = { @() },
        [string]$Reason = ''
    )
    $event = if ($telemetryEnabled) {
        Start-DeveloperEvent -ProjectPath $ProjectPath -Category EVIDENCE -Subcategory requirements -Operation $Operation -ParentEventId $ParentEventId
    } else { $null }
    try {
        $value = & $Work
        if ($event) {
            Stop-DeveloperEvent -ProjectPath $ProjectPath -EventId $event.eventId -Status PASS -Artifacts (& $Artifacts $value) -Reason $Reason | Out-Null
        }
        return $value
    } catch {
        if ($event) {
            try { Stop-DeveloperEvent -ProjectPath $ProjectPath -EventId $event.eventId -Status FAIL -Reason $_.Exception.Message | Out-Null } catch {}
        }
        throw
    }
}

$folderExists = [bool](Invoke-RequirementsEvent -Operation 'requirements.folder.check' -Work {
    Test-Path -LiteralPath $requirementsPath -PathType Container
} -Artifacts { @([ordered]@{ path = 'Requirements'; bytes = $null; sha256 = $null }) })
$folderCreated = $false
if ($Action -eq 'InitializeNew' -and -not $folderExists) {
    Invoke-RequirementsEvent -Operation 'requirements.folder.create' -Work {
        [void][System.IO.Directory]::CreateDirectory($requirementsPath)
    } -Artifacts { @([ordered]@{ path = 'Requirements'; bytes = $null; sha256 = $null }) }
    $folderExists = $true
    $folderCreated = $true
}

$templateExists = $false
$templateCreated = $false
if ($folderExists) {
    $templateExists = [bool](Invoke-RequirementsEvent -Operation 'requirements.template.check' -Work {
        Test-Path -LiteralPath $entryPointPath -PathType Leaf
    } -Artifacts { @([ordered]@{ path = 'Requirements/REQUIREMENTS.md'; bytes = $null; sha256 = $null }) })

    if ($Action -eq 'InitializeNew' -and -not $templateExists) {
        if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) {
            throw "Requirements template was not found: $TemplatePath"
        }
        Invoke-RequirementsEvent -Operation 'requirements.template.create' -Work {
            $templateBytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $TemplatePath).Path)
            $stream = New-Object System.IO.FileStream($entryPointPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try { $stream.Write($templateBytes, 0, $templateBytes.Length) } finally { $stream.Dispose() }
        } -Artifacts {
            @([ordered]@{
                path = 'Requirements/REQUIREMENTS.md'
                bytes = (Get-Item -LiteralPath $entryPointPath).Length
                sha256 = (Get-FileHash -LiteralPath $entryPointPath -Algorithm SHA256).Hash.ToLowerInvariant()
            })
        }
        $templateExists = $true
        $templateCreated = $true
    } elseif ($Action -eq 'InitializeNew' -and $templateExists) {
        Invoke-RequirementsEvent -Operation 'requirements.template.reuse' -Work { $true } -Artifacts {
            @([ordered]@{
                path = 'Requirements/REQUIREMENTS.md'
                bytes = (Get-Item -LiteralPath $entryPointPath).Length
                sha256 = (Get-FileHash -LiteralPath $entryPointPath -Algorithm SHA256).Hash.ToLowerInvariant()
            })
        } | Out-Null
    }
}

$inventoryFiles = @(Invoke-RequirementsEvent -Operation 'requirements.inventory' -Work {
    if (-not $folderExists) { return @() }
    @(Get-ChildItem -LiteralPath $requirementsPath -Recurse -File -Force | Sort-Object FullName | ForEach-Object {
        $extension = $_.Extension.ToLowerInvariant()
        [ordered]@{
            path = Get-RelativeRequirementPath $_.FullName
            name = $_.Name
            extension = $extension
            fileType = if ($supportedTypes.Contains($extension)) { $supportedTypes[$extension] } else { 'unsupported' }
            bytes = [int64]$_.Length
            entryPoint = $_.FullName.Equals($entryPointPath, [System.StringComparison]::OrdinalIgnoreCase)
            supportedForInspection = $supportedTypes.Contains($extension)
        }
    })
} -Artifacts {
    param($files)
    @($files | ForEach-Object { [ordered]@{ path = $_.path; bytes = $_.bytes; sha256 = $null } })
} -Reason 'Requirement file inventory only; file content was not recorded.')

$entryPointContent = $null
if ($ReadEntryPoint -and $templateExists) {
    $entryPointContent = Invoke-RequirementsEvent -Operation 'requirements.read' -Work {
        [System.IO.File]::ReadAllText($entryPointPath, [System.Text.Encoding]::UTF8)
    } -Artifacts {
        @([ordered]@{
            path = 'Requirements/REQUIREMENTS.md'
            bytes = (Get-Item -LiteralPath $entryPointPath).Length
            sha256 = (Get-FileHash -LiteralPath $entryPointPath -Algorithm SHA256).Hash.ToLowerInvariant()
        })
    } -Reason 'REQUIREMENTS.md was returned to the caller; its content was not recorded in telemetry.'
}

$entryPointMetadata = if ($templateExists) {
    [ordered]@{
        path = 'Requirements/REQUIREMENTS.md'
        exists = $true
        created = $templateCreated
        reused = ($Action -eq 'InitializeNew' -and -not $templateCreated)
        bytes = [int64](Get-Item -LiteralPath $entryPointPath).Length
        sha256 = (Get-FileHash -LiteralPath $entryPointPath -Algorithm SHA256).Hash.ToLowerInvariant()
        content = $entryPointContent
    }
} else {
    [ordered]@{ path = 'Requirements/REQUIREMENTS.md'; exists = $false; created = $false; reused = $false; bytes = $null; sha256 = $null; content = $null }
}

$result = [ordered]@{
    schemaVersion = 1
    action = $Action
    status = 'PASS'
    projectPath = $ProjectPath
    ownership = 'HUMAN'
    folder = [ordered]@{ path = 'Requirements'; exists = $folderExists; created = $folderCreated; reused = ($folderExists -and -not $folderCreated) }
    entryPoint = $entryPointMetadata
    inventory = [ordered]@{
        totalFileCount = $inventoryFiles.Count
        supportingFileCount = @($inventoryFiles | Where-Object { -not $_.entryPoint }).Count
        files = @($inventoryFiles)
        contentIncluded = $false
    }
}

if ($Json) { $result | ConvertTo-Json -Depth 8 } else { $result }
