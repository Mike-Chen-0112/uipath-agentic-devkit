[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$testRoot = Join-Path $env:TEMP ('rpa-ai-requirements-tests-' + [guid]::NewGuid().ToString('N'))
$workspaceScript = Join-Path $root 'scripts\Manage-RequirementsWorkspace.ps1'
$mapperScript = Join-Path $root 'scripts\Get-UiPathProjectMap.ps1'
$fingerprintScript = Join-Path $root 'scripts\SourceFingerprint.ps1'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Write-MinimalProject {
    param([string]$Path, [string]$Name)
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    [ordered]@{
        name = $Name
        main = 'Main.xaml'
        targetFramework = 'Windows'
        expressionLanguage = 'VisualBasic'
        dependencies = [ordered]@{}
        designOptions = [ordered]@{ outputType = 'Process' }
    } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $Path 'project.json') -Encoding UTF8
    '<Activity />' | Set-Content (Join-Path $Path 'Main.xaml') -Encoding UTF8
}

try {
    # A-C: creation, template shape, idempotency, and byte-for-byte human preservation.
    $newProject = Join-Path $testRoot 'new-project'
    Write-MinimalProject $newProject 'RequirementsFixture'
    New-Item -ItemType Directory -Force -Path (Join-Path $newProject '.ai\evidence') | Out-Null
    '{}' | Set-Content (Join-Path $newProject '.ai\evidence\execution-state.json') -Encoding UTF8

    $created = & $workspaceScript -Action InitializeNew -ProjectPath $newProject -Json | ConvertFrom-Json
    $requirementsFile = Join-Path $newProject 'Requirements\REQUIREMENTS.md'
    Assert-True ($created.status -eq 'PASS' -and $created.folder.created -and $created.entryPoint.created) 'A: New project Requirements workspace was not created.'
    Assert-True (Test-Path -LiteralPath $requirementsFile -PathType Leaf) 'A: REQUIREMENTS.md is missing.'
    $templateText = [System.IO.File]::ReadAllText($requirementsFile, [System.Text.Encoding]::UTF8)
    foreach ($section in 1..12) {
        Assert-True ($templateText -match "(?m)^## $section\.") "A: REQUIREMENTS.md is missing section $section."
    }

    $createdHash = (Get-FileHash -LiteralPath $requirementsFile -Algorithm SHA256).Hash
    $createdBytes = [System.IO.File]::ReadAllBytes($requirementsFile)
    $reused = & $workspaceScript -Action InitializeNew -ProjectPath $newProject -Json | ConvertFrom-Json
    Assert-True ($reused.folder.reused -and $reused.entryPoint.reused -and -not $reused.entryPoint.created) 'B: Repeated initialization did not report reuse.'
    Assert-True ((Get-FileHash -LiteralPath $requirementsFile -Algorithm SHA256).Hash -eq $createdHash) 'B: Repeated initialization changed REQUIREMENTS.md.'

    $humanText = "# Automation Requirements`r`n`r`nHuman-authored-marker-7f2d`r`n"
    $humanBytes = [System.Text.Encoding]::UTF8.GetBytes($humanText)
    [System.IO.File]::WriteAllBytes($requirementsFile, $humanBytes)
    $humanHash = (Get-FileHash -LiteralPath $requirementsFile -Algorithm SHA256).Hash
    $humanResult = & $workspaceScript -Action InitializeNew -ProjectPath $newProject -Json | ConvertFrom-Json
    Assert-True ($humanResult.entryPoint.reused -and (Get-FileHash -LiteralPath $requirementsFile -Algorithm SHA256).Hash -eq $humanHash) 'C: Human-authored REQUIREMENTS.md was not preserved byte-for-byte.'
    Assert-True ([System.Linq.Enumerable]::SequenceEqual([byte[]]$humanBytes, [byte[]][System.IO.File]::ReadAllBytes($requirementsFile))) 'C: Human-authored requirement bytes changed.'

    # D, F, H, J, K: inventory recognizes supported types, never loads supporting content, and preserves every file.
    $supporting = [ordered]@{
        'screenshot.png' = 'png-content-marker'
        'process.docx' = 'docx-content-marker'
        'policy.pdf' = 'pdf-content-marker'
        'expected.xlsx' = 'xlsx-content-marker'
        'sample.csv' = 'csv-content-marker'
        'notes.txt' = 'text-content-marker'
        'alternate.md' = 'conflicting-human-value'
        'opaque.bin' = 'unsupported-content-marker'
        'sample.xaml' = '<Activity DisplayName="Requirement example only" />'
    }
    $beforeHashes = @{}
    foreach ($name in $supporting.Keys) {
        $path = Join-Path $newProject "Requirements\$name"
        [System.IO.File]::WriteAllBytes($path, [System.Text.Encoding]::UTF8.GetBytes($supporting[$name]))
        $beforeHashes[$name] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }
    $discoveredJson = & $workspaceScript -Action Discover -ProjectPath $newProject -ReadEntryPoint -Json
    $discovered = $discoveredJson | ConvertFrom-Json
    Assert-True ($discovered.folder.exists -and $discovered.folder.reused -and $discovered.inventory.supportingFileCount -eq $supporting.Count) 'D/F: Existing Requirements workspace was not discovered and inventoried.'
    foreach ($extension in @('.png','.docx','.pdf','.xlsx','.csv','.txt','.md')) {
        Assert-True (@($discovered.inventory.files | Where-Object { $_.extension -eq $extension -and $_.supportedForInspection }).Count -ge 1) "D: Supported type $extension was not recognized."
    }
    $opaque = @($discovered.inventory.files | Where-Object name -eq 'opaque.bin')
    Assert-True ($opaque.Count -eq 1 -and -not $opaque[0].supportedForInspection -and $opaque[0].fileType -eq 'unsupported') 'K: Unsupported file was not retained in the nonblocking inventory.'
    Assert-True (-not $discovered.inventory.contentIncluded -and $discoveredJson -notmatch 'png-content-marker|docx-content-marker|unsupported-content-marker|conflicting-human-value') 'H: Supporting file content was blindly loaded into discovery output.'
    foreach ($name in $supporting.Keys) {
        $path = Join-Path $newProject "Requirements\$name"
        Assert-True ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq $beforeHashes[$name]) "D/J/K: Supporting file changed: $name"
    }

    # E: read-only discovery does not pollute a mature existing project.
    $matureProject = Join-Path $testRoot 'mature-project'
    Write-MinimalProject $matureProject 'MatureFixture'
    $absent = & $workspaceScript -Action Discover -ProjectPath $matureProject -ReadEntryPoint -Json | ConvertFrom-Json
    Assert-True (-not $absent.folder.exists -and -not (Test-Path -LiteralPath (Join-Path $matureProject 'Requirements'))) 'E: Existing mature project was polluted with an empty Requirements folder.'

    # G, I, J, L: deterministic policy checks for Coordinator/Developer behavior.
    $coordinator = Get-Content -LiteralPath (Join-Path $root '.github\agents\rpa-coordinator.agent.md') -Raw
    $developer = Get-Content -LiteralPath (Join-Path $root '.github\agents\rpa-developer.agent.md') -Raw
    $documentation = Get-Content -LiteralPath (Join-Path $root '.github\instructions\documentation.instructions.md') -Raw
    Assert-True ($coordinator -match 'Manage-RequirementsWorkspace\.ps1 -Action Discover -ReadEntryPoint' -and $coordinator -match 'inventor' -and $coordinator -match 'first-class business context') 'G: Coordinator does not recognize inventory-first Requirements discovery.'
    Assert-True ($coordinator -match 'Empty optional template fields do not block' -and $documentation -match 'Empty optional template fields are nonblocking') 'I: Optional empty fields are not explicitly nonblocking.'
    Assert-True ($coordinator -match 'Surface conflicts' -and $coordinator -match 'without silently choosing or rewriting') 'J: Conflicting requirement sources are not surfaced and preserved by policy.'
    Assert-True ($developer -match 'Treat every file under `Requirements/` as human-owned' -and $developer -match 'must not edit, delete, rename, move') 'L: Developer human-ownership protection is missing.'

    # Mapper metadata is lightweight and sample XAML under Requirements is never structural source.
    $map = & $mapperScript -ProjectPath $newProject -NoCache -Json | ConvertFrom-Json
    Assert-True ($map.requirements.folderExists -and $map.requirements.entryPointExists -and $map.requirements.contentIncluded -eq $false) 'Mapper: lightweight Requirements metadata is missing.'
    Assert-True ($map.requirements.supportingFileCount -eq $supporting.Count -and @($map.workflows.PSObject.Properties.Name) -contains 'Main.xaml') 'Mapper: Requirements file count or normal workflow mapping is incorrect.'
    Assert-True (@($map.workflows.PSObject.Properties.Name) -notcontains 'Requirements/sample.xaml') 'Mapper: requirement sample XAML leaked into structural workflow mapping.'

    # Requirements files affect documentation freshness but never executable freshness.
    $fingerprintOne = & $fingerprintScript -ProjectPath $newProject -CachePath (Join-Path $newProject '.ai\evidence\requirements-fingerprint-cache.json') -Json | ConvertFrom-Json
    [System.IO.File]::AppendAllText((Join-Path $newProject 'Requirements\expected.xlsx'), '-changed', [System.Text.Encoding]::UTF8)
    $fingerprintTwo = & $fingerprintScript -ProjectPath $newProject -CachePath (Join-Path $newProject '.ai\evidence\requirements-fingerprint-cache.json') -Json | ConvertFrom-Json
    Assert-True ($fingerprintOne.executableFingerprint -eq $fingerprintTwo.executableFingerprint -and $fingerprintOne.documentationFingerprint -ne $fingerprintTwo.documentationFingerprint) 'Fingerprint: Requirements content incorrectly invalidated executable source or failed to invalidate documentation.'

    # M: lifecycle events are compact and contain no entry-point content.
    $ledgerPath = Join-Path $newProject '.ai\evidence\developer-events.jsonl'
    $ledgerText = Get-Content -LiteralPath $ledgerPath -Raw
    $ledgerRecords = @($ledgerText -split "`r?`n" | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    $operations = @($ledgerRecords | Where-Object recordType -eq 'START' | ForEach-Object operation)
    foreach ($operation in @('requirements.folder.check','requirements.folder.create','requirements.template.check','requirements.template.create','requirements.template.reuse','requirements.inventory','requirements.read')) {
        Assert-True ($operations -contains $operation) "M: Telemetry operation is missing: $operation"
    }
    Assert-True ($ledgerText -notmatch 'Human-authored-marker-7f2d|png-content-marker|conflicting-human-value') 'M: Requirement content leaked into telemetry.'

    Write-Host '[PASS] Requirements workspace creation, preservation, discovery, mapping, policy, fingerprint, and telemetry tests passed.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
