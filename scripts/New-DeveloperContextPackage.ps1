[CmdletBinding()]
param(
    [ValidateSet('Prepare','Validate','Expand')]
    [string]$Action = 'Prepare',
    [string]$ProjectPath = (Get-Location).Path,
    [string]$PackagePath = '.ai/evidence/developer-context-package.json',
    [string]$ProjectMapPath = '.ai/evidence/project-map.json',
    [string]$GraphPath = 'graphify-out/graph.json',
    [string]$GraphRefreshStatePath = 'graphify-out/refresh-state.json',
    [string]$GraphSummaryPath = 'graphify-out/GRAPH_REPORT.md',
    [string]$TaskId = '',
    [string]$TaskSummary = '',
    [ValidateSet('R0','R1','R2','R3')]
    [string]$Risk = 'R1',
    [string[]]$WorkflowPath = @(),
    [string[]]$RelevantActivityName = @(),
    [string[]]$ValidationExpectation = @(),
    [string[]]$Constraint = @(),
    [string]$ExpectedSourceFingerprint = '',
    [string]$ExpectedGraphFingerprint = '',
    [switch]$LocalizedScope,
    [switch]$ArchitectureChange,
    [switch]$ArgumentInterfaceChange,
    [switch]$AmbiguousScope,
    [switch]$DeveloperUncertainty,
    [switch]$ExplicitFullSourceRequirement,
    [switch]$NewWorkflow,
    [switch]$DeletedWorkflow,
    [switch]$InvokeTopologyChange,
    [switch]$GraphConflict,
    [ValidateSet('Excerpt','FullSource')]
    [string]$ExpansionMode = 'FullSource',
    [string]$ExpansionReason = '',
    [int]$ExcerptStartLine = 0,
    [int]$ExcerptEndLine = 0,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$ProjectPath = (Resolve-Path $ProjectPath).Path
$projectPrefix = $ProjectPath.TrimEnd('\','/') + [System.IO.Path]::DirectorySeparatorChar
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Resolve-ProjectPath {
    param([string]$Path, [bool]$MustExist = $false)
    if (-not $Path) { return $null }
    $candidate = if ([System.IO.Path]::IsPathRooted($Path)) { [System.IO.Path]::GetFullPath($Path) } else { [System.IO.Path]::GetFullPath((Join-Path $ProjectPath ($Path -replace '/','\'))) }
    if (-not $candidate.StartsWith($projectPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Path must stay within the project: $Path" }
    if ($MustExist -and -not (Test-Path -LiteralPath $candidate -PathType Leaf)) { throw "Required file was not found: $Path" }
    return $candidate
}

function Get-RelativePath {
    param([string]$FullPath)
    return $FullPath.Substring($projectPrefix.Length) -replace '\\','/'
}

function Normalize-WorkflowPath {
    param([string]$Path)
    $fullPath = Resolve-ProjectPath $Path
    return Get-RelativePath $fullPath
}

function Get-PropertyValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
    if ($property) { return $property.Value }
    return $null
}

function Get-JsonBytes {
    param($Value)
    if ($null -eq $Value) { return 0 }
    return [System.Text.Encoding]::UTF8.GetByteCount([string](ConvertTo-Json -InputObject $Value -Depth 20 -Compress))
}

function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-Package {
    param($Package, [string]$Path)
    $Package.metrics.packageBytes = 0
    $Package.metrics.packageBytes = Get-JsonBytes $Package
    $Package.metrics.packageBytes = Get-JsonBytes $Package
    New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null
    $tempPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $backupPath = "$Path.$([guid]::NewGuid().ToString('N')).bak"
    try {
        [System.IO.File]::WriteAllText($tempPath, (($Package | ConvertTo-Json -Depth 20 -Compress) + [Environment]::NewLine), $utf8)
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            try { [System.IO.File]::Replace($tempPath, $Path, $backupPath) }
            catch [System.UnauthorizedAccessException] { Move-Item -LiteralPath $tempPath -Destination $Path -Force -ErrorAction Stop }
            if (Test-Path -LiteralPath $backupPath -PathType Leaf) { Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue }
        } else { [System.IO.File]::Move($tempPath, $Path) }
    } finally {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $backupPath -PathType Leaf) { Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue }
    }
}

function Get-CurrentFingerprint {
    $fingerprintScript = Join-Path $PSScriptRoot 'SourceFingerprint.ps1'
    if (-not (Test-Path -LiteralPath $fingerprintScript -PathType Leaf)) { throw "Source fingerprint helper is missing: $fingerprintScript" }
    return (& $fingerprintScript -ProjectPath $ProjectPath -Json | ConvertFrom-Json)
}

function Add-Reason {
    param([System.Collections.Generic.List[string]]$Reasons, [string]$Reason)
    if ($Reason -and -not $Reasons.Contains($Reason)) { [void]$Reasons.Add($Reason) }
}

function Get-ActivityLocations {
    param([string]$SourcePath, [string[]]$Names)
    $locations = New-Object System.Collections.Generic.List[object]
    if (@($Names).Count -eq 0) { return $locations.ToArray() }
    $readerSettings = New-Object System.Xml.XmlReaderSettings
    $readerSettings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $readerSettings.XmlResolver = $null
    $reader = [System.Xml.XmlReader]::Create($SourcePath, $readerSettings)
    try {
        while ($reader.Read()) {
            if ($reader.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
            $localName = [string]$reader.LocalName
            $displayName = [string]$reader.GetAttribute('DisplayName')
            if ($localName -notin $Names -and $displayName -notin $Names) { continue }
            $idRef = ''
            if ($reader.HasAttributes) {
                for ($index = 0; $index -lt $reader.AttributeCount; $index++) {
                    [void]$reader.MoveToAttribute($index)
                    if ($reader.LocalName -eq 'IdRef') { $idRef = [string]$reader.Value }
                }
                [void]$reader.MoveToElement()
            }
            $lineInfo = [System.Xml.IXmlLineInfo]$reader
            [void]$locations.Add([pscustomobject][ordered]@{
                localName = $localName
                displayName = $displayName
                idRef = $idRef
                line = if ($lineInfo.HasLineInfo()) { $lineInfo.LineNumber } else { $null }
                position = if ($lineInfo.HasLineInfo()) { $lineInfo.LinePosition } else { $null }
            })
        }
    } finally { $reader.Dispose() }
    return $locations.ToArray()
}

function Get-RelevantResources {
    param($Resources, [string[]]$Neighborhood)
    if ($null -eq $Resources) { return @() }
    $selected = New-Object System.Collections.Generic.List[object]
    if ($Resources -is [System.Collections.IEnumerable] -and $Resources -isnot [string] -and -not $Resources.PSObject.Properties.Count) {
        foreach ($resource in @($Resources)) {
            $owner = [string](Get-PropertyValue $resource 'workflow')
            if (-not $owner) { $owner = [string](Get-PropertyValue $resource 'path') }
            if ($owner -and $owner -in $Neighborhood) { [void]$selected.Add($resource) }
        }
    } else {
        foreach ($property in @($Resources.PSObject.Properties)) {
            if ($property.Name -in $Neighborhood) { [void]$selected.Add([pscustomobject][ordered]@{ workflow = $property.Name; value = $property.Value }) }
        }
    }
    return $selected.ToArray()
}

function Test-PackageFreshness {
    param($Package)
    $reasons = New-Object System.Collections.Generic.List[string]
    $snapshot = Get-CurrentFingerprint
    if ([string]$Package.freshness.sourceFingerprint -ne [string]$snapshot.sourceFingerprint) { Add-Reason $reasons 'SOURCE_FINGERPRINT_MISMATCH' }
    if ([string]$Package.graph.fullGraphSha256 -and [string]$Package.freshness.graphConfigFingerprint -ne [string]$snapshot.graphConfigFingerprint) { Add-Reason $reasons 'GRAPH_CONFIG_FINGERPRINT_MISMATCH' }
    $graphFile = Resolve-ProjectPath ([string]$Package.graph.fullGraphPath)
    if ([string]$Package.graph.fullGraphSha256) {
        if (-not (Test-Path -LiteralPath $graphFile -PathType Leaf)) { Add-Reason $reasons 'GRAPH_MISSING' }
        elseif ([string]$Package.graph.fullGraphSha256 -ne (Get-Sha256 $graphFile)) { Add-Reason $reasons 'GRAPH_FINGERPRINT_MISMATCH' }
    }
    foreach ($source in @($Package.sourceAccess.paths)) {
        $sourceFile = Resolve-ProjectPath ([string]$source.path)
        if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) { Add-Reason $reasons 'RELEVANT_WORKFLOW_NOT_FOUND'; continue }
        if ([string]$source.sha256 -ne (Get-Sha256 $sourceFile)) { Add-Reason $reasons 'SOURCE_FILE_MISMATCH' }
    }
    return [pscustomobject][ordered]@{ snapshot = $snapshot; reasons = $reasons.ToArray() }
}

$fullPackagePath = Resolve-ProjectPath $PackagePath

if ($Action -eq 'Validate') {
    if (-not (Test-Path -LiteralPath $fullPackagePath -PathType Leaf)) { throw "Developer context package was not found: $PackagePath" }
    $package = [System.IO.File]::ReadAllText($fullPackagePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $freshness = Test-PackageFreshness $package
    $reasons = New-Object System.Collections.Generic.List[string]
    foreach ($reason in @($package.decision.fallbackReasons)) { Add-Reason $reasons ([string]$reason) }
    foreach ($reason in @($freshness.reasons)) { Add-Reason $reasons ([string]$reason) }
    $package.decision.fastContextFallback = $reasons.Count -gt 0
    $package.decision.fastContextUsed = [bool]$package.decision.fastContextEligible -and $reasons.Count -eq 0
    $package.decision.fallbackReasons = $reasons.ToArray()
    $package.decision.lastValidatedAtUtc = [DateTime]::UtcNow.ToString('o')
    Write-Package $package $fullPackagePath
    if ($Json) { $package | ConvertTo-Json -Depth 20 } else { $package }
    exit 0
}

if ($Action -eq 'Expand') {
    if (-not $ExpansionReason) { throw 'ExpansionReason is required for Expand.' }
    if (-not (Test-Path -LiteralPath $fullPackagePath -PathType Leaf)) { throw "Developer context package was not found: $PackagePath" }
    if (@($WorkflowPath).Count -eq 0) { throw 'WorkflowPath is required for Expand.' }
    $package = [System.IO.File]::ReadAllText($fullPackagePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $freshness = Test-PackageFreshness $package
    if (@($freshness.reasons).Count -gt 0) {
        $reasons = New-Object System.Collections.Generic.List[string]
        foreach ($reason in @($package.decision.fallbackReasons) + @($freshness.reasons)) { Add-Reason $reasons ([string]$reason) }
        $package.decision.fastContextFallback = $true
        $package.decision.fastContextUsed = $false
        $package.decision.fallbackReasons = $reasons.ToArray()
        Write-Package $package $fullPackagePath
        throw "Developer context package is stale: $($freshness.reasons -join ', ')"
    }
    foreach ($path in @($WorkflowPath | Select-Object -Unique)) {
        $sourceFile = Resolve-ProjectPath $path $true
        $relative = Get-RelativePath $sourceFile
        $bytes = [int64](Get-Item -LiteralPath $sourceFile).Length
        $excerptHash = $null
        if ($ExpansionMode -eq 'Excerpt') {
            if ($ExcerptStartLine -lt 1 -or $ExcerptEndLine -lt $ExcerptStartLine) { throw 'Valid ExcerptStartLine and ExcerptEndLine are required for Excerpt expansion.' }
            $sourceLines = [System.IO.File]::ReadAllLines($sourceFile, [System.Text.Encoding]::UTF8)
            if ($ExcerptEndLine -gt $sourceLines.Count) { throw "ExcerptEndLine exceeds the source length for $relative." }
            $excerptText = ($sourceLines[($ExcerptStartLine - 1)..($ExcerptEndLine - 1)] -join [Environment]::NewLine)
            $excerptBytes = [System.Text.Encoding]::UTF8.GetBytes($excerptText)
            $bytes = $excerptBytes.Length
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try { $excerptHash = ([System.BitConverter]::ToString($sha.ComputeHash($excerptBytes)) -replace '-','').ToLowerInvariant() } finally { $sha.Dispose() }
        }
        $record = [pscustomobject][ordered]@{
            recordedAtUtc = [DateTime]::UtcNow.ToString('o')
            reason = $ExpansionReason
            workflow = $relative
            mode = $ExpansionMode
            additionalBytes = $bytes
            sha256 = if ($ExpansionMode -eq 'FullSource') { Get-Sha256 $sourceFile } else { $excerptHash }
            excerptStartLine = if ($ExpansionMode -eq 'Excerpt') { $ExcerptStartLine } else { $null }
            excerptEndLine = if ($ExpansionMode -eq 'Excerpt') { $ExcerptEndLine } else { $null }
            rawSourceFallbackUsed = $ExpansionMode -eq 'FullSource'
        }
        $package.contextExpansions = @($package.contextExpansions) + $record
    }
    $package.sourceAccess.rawSourceFallbackUsed = [bool](@($package.contextExpansions | Where-Object rawSourceFallbackUsed).Count)
    $package.metrics.contextExpansionCount = @($package.contextExpansions).Count
    $package.metrics.contextExpansionBytes = [int64](($package.contextExpansions | Measure-Object additionalBytes -Sum).Sum)
    Write-Package $package $fullPackagePath
    if ($Json) { $package | ConvertTo-Json -Depth 20 } else { $package }
    exit 0
}

if (-not $TaskSummary) { throw 'TaskSummary is required for Prepare.' }
if (@($WorkflowPath).Count -eq 0) { throw 'At least one WorkflowPath is required for Prepare.' }
$fullMapPath = Resolve-ProjectPath $ProjectMapPath $true
$map = [System.IO.File]::ReadAllText($fullMapPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$snapshot = Get-CurrentFingerprint
$selectedWorkflows = @($WorkflowPath | ForEach-Object { Normalize-WorkflowPath $_ } | Select-Object -Unique)
$fallbackReasons = New-Object System.Collections.Generic.List[string]
if (-not $LocalizedScope) { Add-Reason $fallbackReasons 'SCOPE_NOT_LOCALIZED' }
if ($Risk -notin @('R0','R1')) { Add-Reason $fallbackReasons 'RISK_NOT_FAST_PATH_ELIGIBLE' }
if ($ArchitectureChange) { Add-Reason $fallbackReasons 'ARCHITECTURE_CHANGE' }
if ($ArgumentInterfaceChange) { Add-Reason $fallbackReasons 'ARGUMENT_INTERFACE_CHANGE' }
if ($AmbiguousScope) { Add-Reason $fallbackReasons 'AMBIGUOUS_SCOPE' }
if ($DeveloperUncertainty) { Add-Reason $fallbackReasons 'DEVELOPER_UNCERTAINTY' }
if ($ExplicitFullSourceRequirement) { Add-Reason $fallbackReasons 'EXPLICIT_FULL_SOURCE_REQUIREMENT' }
if ($NewWorkflow) { Add-Reason $fallbackReasons 'NEW_WORKFLOW' }
if ($DeletedWorkflow) { Add-Reason $fallbackReasons 'DELETED_WORKFLOW' }
if ($InvokeTopologyChange) { Add-Reason $fallbackReasons 'INVOKE_TOPOLOGY_CHANGE' }
if ($GraphConflict) { Add-Reason $fallbackReasons 'GRAPH_CONFLICT' }
if (-not $ExpectedSourceFingerprint) { Add-Reason $fallbackReasons 'SOURCE_FINGERPRINT_MISSING' }
elseif ($ExpectedSourceFingerprint -ne [string]$snapshot.sourceFingerprint) { Add-Reason $fallbackReasons 'SOURCE_FINGERPRINT_MISMATCH' }

$forward = Get-PropertyValue (Get-PropertyValue $map 'dependencies') 'forward'
$reverse = Get-PropertyValue (Get-PropertyValue $map 'dependencies') 'reverse'
$parents = New-Object System.Collections.Generic.List[string]
$children = New-Object System.Collections.Generic.List[string]
foreach ($workflow in $selectedWorkflows) {
    $record = Get-PropertyValue (Get-PropertyValue $map 'workflows') $workflow
    if ($null -eq $record) { Add-Reason $fallbackReasons 'RELEVANT_WORKFLOW_NOT_FOUND'; continue }
    foreach ($parent in @(Get-PropertyValue $reverse $workflow)) { if ($parent -and -not $parents.Contains([string]$parent)) { [void]$parents.Add([string]$parent) } }
    foreach ($child in @(Get-PropertyValue $forward $workflow)) { if ($child -and -not $children.Contains([string]$child)) { [void]$children.Add([string]$child) } }
}
$neighborhood = @($selectedWorkflows + $parents.ToArray() + $children.ToArray() | Select-Object -Unique)
$workflowContext = [ordered]@{}
$sourceRecords = New-Object System.Collections.Generic.List[object]
$foundActivityNames = New-Object System.Collections.Generic.List[string]
foreach ($workflow in $neighborhood) {
    $record = Get-PropertyValue (Get-PropertyValue $map 'workflows') $workflow
    if ($null -eq $record) { continue }
    $relation = if ($workflow -in $selectedWorkflows) { 'selected' } elseif ($workflow -in $parents) { 'parent' } else { 'child' }
    $activityLocations = @()
    if ($workflow -in $selectedWorkflows) {
        $sourceFile = Resolve-ProjectPath $workflow
        if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) { Add-Reason $fallbackReasons 'RELEVANT_WORKFLOW_NOT_FOUND' }
        else {
            $activityLocations = @(Get-ActivityLocations $sourceFile $RelevantActivityName)
            foreach ($location in $activityLocations) {
                if ($location.localName -and -not $foundActivityNames.Contains([string]$location.localName)) { [void]$foundActivityNames.Add([string]$location.localName) }
                if ($location.displayName -and -not $foundActivityNames.Contains([string]$location.displayName)) { [void]$foundActivityNames.Add([string]$location.displayName) }
            }
            [void]$sourceRecords.Add([pscustomobject][ordered]@{ path = $workflow; bytes = [int64](Get-Item -LiteralPath $sourceFile).Length; sha256 = Get-Sha256 $sourceFile; fullXamlAvailable = $true })
        }
    }
    foreach ($invoke in @(Get-PropertyValue $record 'invokes')) {
        if (-not [bool](Get-PropertyValue $invoke 'resolved') -or [bool](Get-PropertyValue $invoke 'dynamic')) { Add-Reason $fallbackReasons 'UNRESOLVED_RELEVANT_INVOKE' }
    }
    $workflowContext[$workflow] = [ordered]@{
        relation = $relation
        parents = @((Get-PropertyValue $reverse $workflow))
        children = @((Get-PropertyValue $forward $workflow))
        arguments = @((Get-PropertyValue $record 'arguments'))
        capabilities = @((Get-PropertyValue $record 'capabilities'))
        invokes = @((Get-PropertyValue $record 'invokes'))
        relevantActivities = $activityLocations
    }
}
foreach ($activityName in @($RelevantActivityName)) {
    if ($activityName -notin $foundActivityNames) { Add-Reason $fallbackReasons 'MISSING_RELEVANT_ACTIVITY_LOCATION' }
}

$relevantWarnings = New-Object System.Collections.Generic.List[object]
foreach ($warning in @((Get-PropertyValue $map 'warnings'))) {
    $warningPath = [string](Get-PropertyValue $warning 'path')
    if ($warningPath -in $neighborhood) { [void]$relevantWarnings.Add($warning); Add-Reason $fallbackReasons 'RELEVANT_MAPPER_WARNING' }
}
foreach ($workflow in $neighborhood) {
    $record = Get-PropertyValue (Get-PropertyValue $map 'workflows') $workflow
    foreach ($warning in @((Get-PropertyValue $record 'parsingWarnings'))) {
        if ($warning) { [void]$relevantWarnings.Add([pscustomobject][ordered]@{ code = 'WORKFLOW_PARSING_WARNING'; path = $workflow; message = [string]$warning }); Add-Reason $fallbackReasons 'RELEVANT_MAPPER_WARNING' }
    }
}
$mapGeneratedAt = [DateTime]::Parse([string]$map.generatedAtUtc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
foreach ($source in $sourceRecords) {
    $sourceItem = Get-Item -LiteralPath (Resolve-ProjectPath ([string]$source.path))
    if ($sourceItem.LastWriteTimeUtc -gt $mapGeneratedAt.ToUniversalTime()) { Add-Reason $fallbackReasons 'PROJECT_MAP_STALE' }
}

$scopedEdges = @((Get-PropertyValue $map 'edges') | Where-Object { [string]$_.source -in $neighborhood -and [string]$_.target -in $neighborhood })
$scopedMap = [ordered]@{
    schemaVersion = [int]$map.schemaVersion
    generatedAtUtc = [string]$map.generatedAtUtc
    selectedWorkflows = $selectedWorkflows
    neighborhood = $neighborhood
    workflows = $workflowContext
    edges = $scopedEdges
    resources = @(Get-RelevantResources (Get-PropertyValue $map 'resources') $neighborhood)
    warnings = $relevantWarnings.ToArray()
}

$fullGraphPath = Resolve-ProjectPath $GraphPath
$fullGraphRefreshPath = Resolve-ProjectPath $GraphRefreshStatePath
$graph = $null
$refreshState = $null
# A graph is optional; an absent graph must not force a full-context fallback.
# Explicit expected fingerprints still require a matching graph.
if (Test-Path -LiteralPath $fullGraphPath -PathType Leaf) {
    $graph = [System.IO.File]::ReadAllText($fullGraphPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
} elseif ($ExpectedGraphFingerprint) { Add-Reason $fallbackReasons 'GRAPH_MISSING' }
if (Test-Path -LiteralPath $fullGraphRefreshPath -PathType Leaf) {
    $refreshState = [System.IO.File]::ReadAllText($fullGraphRefreshPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
} elseif ($ExpectedGraphFingerprint) { Add-Reason $fallbackReasons 'GRAPH_REFRESH_STATE_MISSING' }
# Use graph artifacts only when the handoff explicitly requires their fingerprint.
# A pre-existing stale graph must not invalidate a Mapper-only task.
if (-not $ExpectedGraphFingerprint) { $graph = $null; $refreshState = $null }
if ($refreshState) {
    if ([string]$refreshState.sourceFingerprint -ne [string]$snapshot.sourceFingerprint) { Add-Reason $fallbackReasons 'GRAPH_FINGERPRINT_MISMATCH' }
    if ($ExpectedGraphFingerprint -and [string]$refreshState.sourceFingerprint -ne $ExpectedGraphFingerprint) { Add-Reason $fallbackReasons 'GRAPH_FINGERPRINT_MISMATCH' }
    if ([string]$refreshState.graphConfigFingerprint -ne [string]$snapshot.graphConfigFingerprint) { Add-Reason $fallbackReasons 'GRAPH_CONFIG_FINGERPRINT_MISMATCH' }
}
$relevantNodes = @()
$relevantGraphEdges = @()
if ($graph) {
    $relevantNodes = @($graph.nodes | Where-Object { [string]$_.source_file -in $neighborhood -and [string]$_.source_location -eq 'L1' } | ForEach-Object { [pscustomobject][ordered]@{ id = [string]$_.id; label = [string]$_.label; sourceFile = [string]$_.source_file; sourceLocation = [string]$_.source_location } })
    $nodeIds = @($relevantNodes | ForEach-Object id)
    $relevantGraphEdges = @($graph.edges | Where-Object { [string]$_.source -in $nodeIds -and [string]$_.target -in $nodeIds } | ForEach-Object { [pscustomobject][ordered]@{ source = [string]$_.source; target = [string]$_.target; relation = [string]$_.relation; confidence = [string]$_.confidence } })
}
$graphSummary = [ordered]@{
    fullGraphPath = Get-RelativePath $fullGraphPath
    graphSummaryPath = if (Test-Path -LiteralPath (Resolve-ProjectPath $GraphSummaryPath)) { Get-RelativePath (Resolve-ProjectPath $GraphSummaryPath) } else { $null }
    fullGraphSha256 = if ($graph) { Get-Sha256 $fullGraphPath } else { $null }
    nodeCount = if ($graph) { @($graph.nodes).Count } else { 0 }
    edgeCount = if ($graph) { @($graph.edges).Count } else { 0 }
    relevantNodes = $relevantNodes
    relevantEdges = $relevantGraphEdges
    sourceFingerprint = if ($refreshState) { [string]$refreshState.sourceFingerprint } else { $null }
    graphConfigFingerprint = if ($refreshState) { [string]$refreshState.graphConfigFingerprint } else { $null }
    refreshedAtUtc = if ($refreshState) { [string]$refreshState.refreshedAtUtc } else { $null }
}

$package = [ordered]@{
    schemaVersion = 1
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    task = [ordered]@{ id = $TaskId; summary = $TaskSummary; risk = $Risk }
    scope = [ordered]@{ localized = [bool]$LocalizedScope; selectedWorkflows = $selectedWorkflows; workflowsRepresented = $neighborhood }
    scopedProjectMap = $scopedMap
    graph = $graphSummary
    sourceAccess = [ordered]@{
        authorityOrder = @('raw XAML','deterministic Project Map','compact graph summary','natural-language handoff')
        initialMode = if ($ExplicitFullSourceRequirement) { 'full_source_required' } else { 'metadata_and_locations' }
        rawXamlBytesInitiallyIncluded = 0
        xamlExcerptBytesInitiallyIncluded = 0
        sourceFilesInitiallyIncluded = 0
        rawSourceFallbackUsed = $false
        escalation = @('metadata_and_locations','bounded_excerpt','full_xaml')
        paths = $sourceRecords.ToArray()
    }
    validationExpectations = @($ValidationExpectation)
    constraints = @($Constraint)
    freshness = [ordered]@{
        sourceFingerprint = [string]$snapshot.sourceFingerprint
        graphConfigFingerprint = [string]$snapshot.graphConfigFingerprint
        expectedSourceFingerprint = $ExpectedSourceFingerprint
        expectedGraphFingerprint = $ExpectedGraphFingerprint
        projectMapPath = Get-RelativePath $fullMapPath
        projectMapSha256 = Get-Sha256 $fullMapPath
    }
    decision = [ordered]@{
        fastContextEligible = $fallbackReasons.Count -eq 0
        fastContextUsed = $fallbackReasons.Count -eq 0
        fastContextFallback = $fallbackReasons.Count -gt 0
        fallbackReasons = $fallbackReasons.ToArray()
        evaluatedAtUtc = [DateTime]::UtcNow.ToString('o')
        lastValidatedAtUtc = $null
    }
    contextExpansions = @()
    evidenceReferences = [ordered]@{
        fullProjectMapPath = Get-RelativePath $fullMapPath
        fullGraphPath = Get-RelativePath $fullGraphPath
        sourceFingerprintCachePath = '.ai/evidence/source-fingerprint-cache.json'
    }
    metrics = [ordered]@{
        packageBytes = 0
        scopedProjectMapBytes = Get-JsonBytes $scopedMap
        graphSummaryBytes = Get-JsonBytes $graphSummary
        rawXamlBytesInitiallyIncluded = 0
        xamlExcerptBytesInitiallyIncluded = 0
        workflowsRepresented = $neighborhood.Count
        sourceFilesInitiallyIncluded = 0
        contextExpansionCount = 0
        contextExpansionBytes = 0
    }
}
Write-Package $package $fullPackagePath
if ($Json) { $package | ConvertTo-Json -Depth 20 } else { $package }
