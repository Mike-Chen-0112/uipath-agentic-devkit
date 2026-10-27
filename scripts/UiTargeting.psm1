Set-StrictMode -Version 1
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:UiCapabilityCache = @{}

function Get-UiTargetPolicy {
    param([string]$PolicyPath = '')
    if (-not $PolicyPath) { $PolicyPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'validation\ui-target-policy.json' }
    if (-not (Test-Path -LiteralPath $PolicyPath -PathType Leaf)) { throw "UI target policy not found: $PolicyPath" }
    $policy = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $PolicyPath).Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if ([int]$policy.schemaVersion -ne 1 -or [int]$policy.registrySchemaVersion -ne 2) { throw 'Unsupported UI target policy schema.' }
    return $policy
}

function Get-UiSha256 {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))) -replace '-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function ConvertTo-NormalizedSelector {
    param([string]$Selector)
    if (-not $Selector) { return '' }
    $trimmed = ($Selector.Trim() -replace '\s+', ' ')
    try {
        [xml]$xml = "<root>$trimmed</root>"
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($node in @($xml.DocumentElement.ChildNodes)) {
            if ($node.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
            if (@($node.SelectNodes('.//*')).Count -gt 0) { return $trimmed.ToLowerInvariant() }
            $attributes = @($node.Attributes | Sort-Object Name | ForEach-Object { "$($_.Name.ToLowerInvariant())='$($_.Value.Trim())'" })
            [void]$parts.Add("<$($node.Name.ToLowerInvariant()) $($attributes -join ' ')>")
        }
        if ($parts.Count -gt 0) { return ($parts -join '') }
    } catch { }
    return $trimmed.ToLowerInvariant()
}

function Normalize-UiTargetContext {
    param(
        [ValidateSet('Web','Native')][string]$Kind = 'Web',
        [string]$Browser = 'Chrome',
        [string]$Application = '',
        [string]$Domain = '',
        [string]$Page = '',
        [string]$Window = ''
    )
    if ($Kind -eq 'Web' -and -not $Browser) { $Browser = 'Chrome' }
    $normalizedDomain = $Domain.Trim().ToLowerInvariant()
    $normalizedPage = $Page.Trim()
    if ($normalizedPage) {
        try {
            $uri = [Uri]$normalizedPage
            if (-not $normalizedDomain -and $uri.Host) { $normalizedDomain = $uri.Host.ToLowerInvariant() }
            $normalizedPage = $uri.AbsolutePath.TrimEnd('/').ToLowerInvariant()
            if (-not $normalizedPage) { $normalizedPage = '/' }
        } catch {
            $normalizedPage = (($normalizedPage -split '[?#]', 2)[0]).TrimEnd('/').ToLowerInvariant()
            if (-not $normalizedPage) { $normalizedPage = '/' }
        }
    }
    return [ordered]@{
        kind = $Kind
        browser = if ($Kind -eq 'Web') { $Browser.Trim() } else { '' }
        application = $Application.Trim()
        domain = if ($Kind -eq 'Web') { $normalizedDomain } else { '' }
        page = if ($Kind -eq 'Web') { $normalizedPage } else { '' }
        window = if ($Kind -eq 'Native') { $Window.Trim() } else { '' }
    }
}

function Test-UiTargetContextMatch {
    param($Expected, $Actual)
    if (-not $Expected -or -not $Actual) { return $false }
    foreach ($name in @('kind','browser','application','domain','page','window')) {
        $left = [string]$Expected.$name
        $right = [string]$Actual.$name
        if (-not $left.Equals($right, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    return $true
}

function Get-UiAutomationDependency {
    param([string]$ProjectPath)
    $projectFile = Join-Path $ProjectPath 'project.json'
    if (-not (Test-Path -LiteralPath $projectFile -PathType Leaf)) { return [ordered]@{ present=$false; version=''; parsedVersion=$null } }
    try { $project = [System.IO.File]::ReadAllText($projectFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json }
    catch { throw "project.json is invalid: $($_.Exception.Message)" }
    if (-not $project.dependencies) { return [ordered]@{ present=$false; version=''; parsedVersion=$null } }
    $property = @($project.dependencies.PSObject.Properties | Where-Object { $_.Name -ieq 'UiPath.UIAutomation.Activities' }) | Select-Object -First 1
    if (-not $property) { return [ordered]@{ present=$false; version=''; parsedVersion=$null } }
    $value = if ($property.Value -is [string]) { [string]$property.Value } elseif ($property.Value.version) { [string]$property.Value.version } else { [string]$property.Value }
    $match = [regex]::Match($value, '\d+(?:\.\d+){0,3}')
    $parsed = $null
    if ($match.Success) { try { $parsed = [version]$match.Value } catch { } }
    return [ordered]@{ present=$true; version=$value; parsedVersion=$parsed }
}

function Get-UiTargetCapabilities {
    param([string]$ProjectPath, [string[]]$FeatureEvidencePath = @())
    $ProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path
    $dependency = Get-UiAutomationDependency $ProjectPath
    $evidenceFiles = New-Object System.Collections.Generic.List[string]
    foreach ($path in @($FeatureEvidencePath)) {
        $full = if ([IO.Path]::IsPathRooted($path)) { [IO.Path]::GetFullPath($path) } else { [IO.Path]::GetFullPath((Join-Path $ProjectPath $path)) }
        if (-not $full.StartsWith($ProjectPath.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "Capability evidence must stay within the project: $path" }
        if (Test-Path -LiteralPath $full -PathType Leaf) { [void]$evidenceFiles.Add($full) }
        elseif (Test-Path -LiteralPath $full -PathType Container) {
            foreach ($file in @(Get-ChildItem -LiteralPath $full -Recurse -File -ErrorAction SilentlyContinue | Where-Object Length -le 1048576 | Select-Object -First 50)) { [void]$evidenceFiles.Add($file.FullName) }
        }
    }
    foreach ($relative in @('.local\docs\packages\UiPath.UIAutomation.Activities','.uipath\.skills')) {
        $candidate = Join-Path $ProjectPath $relative
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            foreach ($file in @(Get-ChildItem -LiteralPath $candidate -Recurse -File -ErrorAction SilentlyContinue | Where-Object Length -le 1048576 | Select-Object -First 50)) { [void]$evidenceFiles.Add($file.FullName) }
        }
    }
    $uniqueEvidenceFiles = @($evidenceFiles | Sort-Object -Unique)
    $objectRepositoryPaths = @('ObjectRepository','.objects','Objects','UIObjects') | ForEach-Object { Join-Path $ProjectPath $_ }
    $objectRepository = @($objectRepositoryPaths | Where-Object { Test-Path -LiteralPath $_ }).Count -gt 0
    $evidenceHashes = @($uniqueEvidenceFiles | ForEach-Object { "$_|$((Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash)" })
    $stateFingerprint = Get-UiSha256 (@('ui-capability-cache-v1', $dependency.present, $dependency.version, $objectRepository) + $evidenceHashes -join "`n")
    $cacheKey = $ProjectPath.ToLowerInvariant()
    if ($script:UiCapabilityCache.ContainsKey($cacheKey) -and $script:UiCapabilityCache[$cacheKey].fingerprint -eq $stateFingerprint) {
        $cached = $script:UiCapabilityCache[$cacheKey].json | ConvertFrom-Json
        $cached.cacheStatus = 'REUSED'
        return $cached
    }
    $evidenceText = @($uniqueEvidenceFiles | ForEach-Object {
        [System.IO.File]::ReadAllText($_, [System.Text.Encoding]::UTF8)
    }) -join "`n"
    $major = if ($dependency.parsedVersion) { [int]$dependency.parsedVersion.Major } else { 0 }
    $semanticDenied = $evidenceText -match '(?i)semantic\s+(dom|selector|target|image).{0,30}(not supported|unsupported|unavailable)'
    $cvDenied = $evidenceText -match '(?i)(computer\s+vision|\bCV\b).{0,30}(not supported|unsupported|unavailable)'
    $validationDenied = $evidenceText -match '(?i)(target\s+validation|validate\s+(a\s+)?target).{0,30}(not supported|unsupported|unavailable)'
    $semanticDom = $dependency.present -and -not $semanticDenied -and $evidenceText -match '(?i)semantic\s+(dom|selector|target)'
    $semanticImage = $dependency.present -and -not $semanticDenied -and $evidenceText -match '(?i)semantic\s+(image|screen)'
    $computerVision = $dependency.present -and -not $cvDenied -and $evidenceText -match '(?i)computer\s+vision|\bCV\s+(target|activity|selector)'
    $targetValidation = $dependency.present -and -not $validationDenied -and $evidenceText -match '(?i)validate\s+(a\s+)?target|target\s+validation|uia\s+validate'
    $fuzzy = $dependency.present -and ($major -ge 20 -or $evidenceText -match '(?i)fuzzy\s+selector')
    $capability = [ordered]@{
        schemaVersion = 1
        uiAutomationDependencyPresent = [bool]$dependency.present
        uiAutomationVersion = [string]$dependency.version
        strictSelector = [bool]$dependency.present
        domSelector = [bool]$dependency.present
        anchors = [bool]$dependency.present
        fuzzySelector = [bool]$fuzzy
        semanticDom = [bool]$semanticDom
        semanticImage = [bool]$semanticImage
        computerVision = [bool]$computerVision
        imageTarget = [bool]$dependency.present
        coordinateTarget = [bool]$dependency.present
        targetValidation = [bool]$targetValidation
        objectRepository = [bool]$objectRepository
        defaultBrowser = 'Chrome'
        cacheStatus = 'COMPUTED'
        evidenceFingerprint = $stateFingerprint
        evidenceFiles = @($evidenceFiles | Sort-Object -Unique | ForEach-Object { $_.Substring($ProjectPath.Length).TrimStart('\','/') -replace '\\','/' })
    }
    $fingerprintInput = @('ui-target-capabilities-v1', $capability.uiAutomationVersion, $capability.strictSelector, $capability.fuzzySelector, $capability.semanticDom, $capability.semanticImage, $capability.computerVision, $capability.targetValidation, $capability.objectRepository) -join '|'
    $capability.environmentFingerprint = Get-UiSha256 $fingerprintInput
    if ($script:UiCapabilityCache.Count -ge 32) { $script:UiCapabilityCache.Clear() }
    $script:UiCapabilityCache[$cacheKey] = @{ fingerprint=$stateFingerprint; json=($capability | ConvertTo-Json -Depth 10 -Compress) }
    return [pscustomobject]$capability
}

function Get-UiTargetQuality {
    param(
        [string]$Selector,
        [string]$Strategy = 'StrictSelector',
        [string]$AnchorSelector = '',
        [int]$MatchCount = -1,
        [string]$ExpectedRole = '',
        [string]$ActualRole = '',
        [string]$PolicyPath = ''
    )
    $policy = Get-UiTargetPolicy $PolicyPath
    $q = $policy.selectorQuality
    $score = [int]$q.baseScore
    $signals = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $normalized = ConvertTo-NormalizedSelector $Selector
    if ($Strategy -eq 'Coordinate') {
        $score = [int]$q.coordinateScore
        [void]$warnings.Add('COORDINATE_ONLY')
    } elseif ($Strategy -in @('SemanticDom','SemanticImage','ComputerVision','Image')) {
        $wordCount = @($Selector.Trim() -split '\s+' | Where-Object { $_ }).Count
        if ($wordCount -ge 3 -and $wordCount -le 12) { $score = 80; [void]$signals.Add('CONCISE_SEMANTIC_DESCRIPTION') }
        elseif ($wordCount -gt 12 -and $wordCount -le 20) { $score = 60; [void]$warnings.Add('VERBOSE_SEMANTIC_DESCRIPTION') }
        else { $score = 25; [void]$warnings.Add('VAGUE_SEMANTIC_DESCRIPTION') }
    } elseif ($Strategy -eq 'ObjectRepository') {
        $score = if ($Selector.Trim()) { 85 } else { 0 }
        if ($score -gt 0) { [void]$signals.Add('OBJECT_REPOSITORY_REFERENCE') } else { [void]$warnings.Add('MISSING_OBJECT_REPOSITORY_REFERENCE') }
    } else {
        $id = [regex]::Match($Selector, '(?i)\bid\s*=\s*["'']([^"'']+)["'']')
        $dynamicId = $id.Success -and $id.Groups[1].Value -match '(?i)(?:^|[-_])(ember|react|ext|auto|generated)[-_]?\d+|[0-9a-f]{8}-[0-9a-f-]{27,}|\d{8,}|[a-z]{2,}\d{6,}|[a-z][-_:]\d{4,}$'
        if ($id.Success -and -not $dynamicId) { $score += [int]$q.stableIdBonus; [void]$signals.Add('STABLE_ID') }
        elseif ($dynamicId) { $score -= [int]$q.dynamicIdPenalty; [void]$warnings.Add('DYNAMIC_ID') }
        if ($Selector -match '(?i)\bname\s*=\s*["''][^"'']+["'']') { $score += [int]$q.stableNameBonus; [void]$signals.Add('STABLE_NAME') }
        if ($Selector -match '(?i)\b(role|type)\s*=\s*["''][^"'']+["'']') { $score += [int]$q.stableRoleBonus; [void]$signals.Add('STABLE_ROLE') }
        if ($Selector -match '(?i)\baria-(label|labelledby)\s*=\s*["''][^"'']+["'']') { $score += [int]$q.stableAriaBonus; [void]$signals.Add('STABLE_ARIA') }
        if ($Selector -match '(?i)\bdata-(testid|test-id|qa|automation-id)\s*=\s*["''][^"'']+["'']') { $score += [int]$q.stableDataAttributeBonus; [void]$signals.Add('STABLE_DATA_ATTRIBUTE') }
        if ($Selector -match '(?i)(session|token|nonce|timestamp)[=:][^\s>]+|\b\d{4}-\d{2}-\d{2}\b|\b\d{10,13}\b') { $score -= [int]$q.volatileValuePenalty; [void]$warnings.Add('VOLATILE_VALUE') }
        if ($Selector -match '\bclass\s*=\s*["''][^"'']*\b(css-[a-z0-9]{5,}|sc-[A-Za-z]{5,}|jss\d+|[A-Za-z]+_[A-Za-z0-9]{5}_\d+)') { $score -= [int]$q.volatileValuePenalty; [void]$warnings.Add('GENERATED_CLASS') }
        if ($Selector -match '(?i)\b(aaname|title|text|innertext)\s*=\s*["''][^"''*]*(\b\d{1,2}[/.-]\d{1,2}[/.-]\d{2,4}\b|[$\u20AC\u00A3]\s?\d|\b\d+[.,]\d{2}\b)') { $score -= [int]$q.volatileValuePenalty; [void]$warnings.Add('DYNAMIC_TEXT') }
        if ($Selector -match '(?i)\b(idx|index)\s*=|:nth-(child|of-type)\(') { $score -= [int]$q.indexPenalty; [void]$warnings.Add('POSITIONAL_INDEX') }
        $depth = [regex]::Matches($Selector, '<[a-zA-Z][^>/]*>').Count
        if ($depth -gt 4 -or ([regex]::Matches($Selector, '[>/]').Count -gt 10)) { $score -= [int]$q.longHierarchyPenalty; [void]$warnings.Add('LONG_HIERARCHY') }
        $meaningful = $signals.Count -gt 0 -or $Selector -match '(?i)\b(aaname|class|tag|title|text)\s*=\s*["''][^"'']+["'']'
        if (-not $meaningful -or $Selector -match '(?i)^\s*<\w+\s+(tag|class)\s*=\s*["''][^"'']+["'']\s*/?>\s*$') { $score -= [int]$q.genericSelectorPenalty; [void]$warnings.Add('OVERLY_GENERIC') }
        if ($AnchorSelector) {
            $anchor = Get-UiTargetQuality -Selector $AnchorSelector -Strategy StrictSelector -MatchCount 1 -PolicyPath $PolicyPath
            if ($anchor.classification -in @('GOOD','ACCEPTABLE')) { $score += [int]$q.reliableAnchorBonus; [void]$signals.Add('RELIABLE_ANCHOR') }
            else { [void]$warnings.Add('FRAGILE_ANCHOR') }
        }
        if ($MatchCount -gt 1 -or $MatchCount -eq 0) { $score -= [int]$q.ambiguousMatchPenalty; [void]$warnings.Add($(if ($MatchCount -eq 0) { 'NO_MATCH' } else { 'AMBIGUOUS_MATCH' })) }
        if ($ExpectedRole -and $ActualRole -and -not $ExpectedRole.Equals($ActualRole, [StringComparison]::OrdinalIgnoreCase)) { $score -= [int]$q.ambiguousMatchPenalty; [void]$warnings.Add('ROLE_MISMATCH') }
    }
    $score = [Math]::Max(0, [Math]::Min(100, $score))
    $classification = if ($score -ge [int]$q.goodThreshold) { 'GOOD' } elseif ($score -ge [int]$q.acceptableThreshold) { 'ACCEPTABLE' } elseif ($score -ge [int]$q.fragileThreshold) { 'FRAGILE' } else { 'REJECT' }
    $fallbackRequired = $Strategy -in @('StrictSelector','DomSelector') -and $classification -in @('ACCEPTABLE','FRAGILE') -and -not $signals.Contains('RELIABLE_ANCHOR')
    if ($fallbackRequired) { [void]$warnings.Add('FALLBACK_REQUIRED') }
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        score = $score
        classification = $classification
        fallbackRequired = $fallbackRequired
        normalizedSelector = $normalized
        selectorHash = Get-UiSha256 "$Strategy|$normalized|$(ConvertTo-NormalizedSelector $AnchorSelector)"
        positiveSignals = $signals.ToArray()
        warnings = $warnings.ToArray()
    }
}

function New-UiTargetMetrics {
    return [ordered]@{
        targetsRequired=0; registryHits=0; registryMisses=0; reuseAttempts=0; reuseSuccesses=0; reuseFailures=0
        discoveryCount=0; validationCount=0; failedValidationCount=0; strategyDistribution=[ordered]@{}
        fallbackCount=0; semanticSelectorCount=0; cvImageFallbackCount=0; coordinateFallbackCount=0
        duplicatedTargetsPrevented=0; totalTargetResolutionMs=0; targetDiscoveryMs=0; targetValidationMs=0; registryLookupMs=0
        registryWriteMs=0; browserExplorationOperations=0; candidateEvaluationCount=0
    }
}

function New-UiTargetRegistry {
    param([string]$ProjectPath)
    $now = [DateTime]::UtcNow.ToString('o')
    return [pscustomobject][ordered]@{ schemaVersion=2; createdAtUtc=$now; updatedAtUtc=$now; projectPathHint='.'; targets=@(); attemptLedger=@(); metrics=New-UiTargetMetrics }
}

function ConvertTo-UiTargetV2 {
    param($Target)
    $context = if ($Target.context) { $Target.context } elseif ($Target.application) {
        Normalize-UiTargetContext -Kind $(if ($Target.application.domain) { 'Web' } else { 'Native' }) -Browser ([string]$Target.application.browser) -Application ([string]$Target.application.name) -Domain ([string]$Target.application.domain) -Page ([string]$Target.application.page) -Window ([string]$Target.application.window)
    } else { Normalize-UiTargetContext }
    $primary = if ($Target.primary) { $Target.primary } else { [ordered]@{ strategy=[string]$Target.strategy; descriptor=[string]$Target.selector } }
    return [pscustomobject][ordered]@{
        targetId = [string]$Target.targetId
        logicalName = [string]$Target.logicalName
        context = $context
        elementRole = [string]$Target.elementRole
        primary = $primary
        anchors = @($Target.anchors)
        fallbacks = @($Target.fallbacks)
        semanticDescription = [string]$Target.semanticDescription
        objectRepositoryReference = $Target.objectRepositoryReference
        quality = $Target.quality
        lifecycle = if ([string]$Target.lifecycle) { [string]$Target.lifecycle } else { 'DISCOVERED' }
        validation = $Target.validation
        capability = $Target.capability
        sourceLocations = @($Target.sourceLocations)
        artifact = $Target.artifact
        warnings = @($Target.warnings)
        fingerprint = [string]$Target.fingerprint
        createdAtUtc = [string]$Target.createdAtUtc
        updatedAtUtc = [string]$Target.updatedAtUtc
    }
}

function Read-UiTargetRegistry {
    param([string]$RegistryPath, [string]$ProjectPath)
    if (-not (Test-Path -LiteralPath $RegistryPath -PathType Leaf)) { return New-UiTargetRegistry $ProjectPath }
    try { $raw = [System.IO.File]::ReadAllText($RegistryPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json }
    catch { throw "UI target registry is malformed: $($_.Exception.Message)" }
    if ([int]$raw.schemaVersion -notin @(1,2)) { throw "Unsupported UI target registry schema: $($raw.schemaVersion)" }
    $targets = if ($raw.targets) { @($raw.targets) } elseif ($raw.entries) { @($raw.entries) } else { @() }
    $registry = New-UiTargetRegistry $ProjectPath
    if ($raw.createdAtUtc) { $registry.createdAtUtc = [string]$raw.createdAtUtc }
    $registry.targets = @($targets | ForEach-Object { ConvertTo-UiTargetV2 $_ })
    if ($raw.attemptLedger) { $registry.attemptLedger = @($raw.attemptLedger) }
    if ($raw.metrics) {
        foreach ($property in @($registry.metrics.Keys)) {
            if ($raw.metrics.PSObject.Properties.Name -contains $property) { $registry.metrics[$property] = $raw.metrics.$property }
        }
    }
    return $registry
}

function Enter-UiTargetRegistryLock {
    param([string]$RegistryPath, [int]$TimeoutMilliseconds = 3000)
    $lockPath = "$RegistryPath.lock"
    $directory = Split-Path $RegistryPath -Parent
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
        try { return [IO.File]::Open($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None) }
        catch [IO.IOException] {
            try {
                $lockItem = Get-Item -LiteralPath $lockPath -ErrorAction Stop
                if (([DateTime]::UtcNow - $lockItem.LastWriteTimeUtc).TotalSeconds -gt 30) { Remove-Item -LiteralPath $lockPath -Force -ErrorAction Stop }
            } catch { }
            Start-Sleep -Milliseconds 20
        }
    }
    throw "Timed out acquiring UI target registry lock: $lockPath"
}

function Exit-UiTargetRegistryLock {
    param($Lock, [string]$RegistryPath)
    if ($Lock) { $Lock.Dispose() }
    Remove-Item -LiteralPath "$RegistryPath.lock" -Force -ErrorAction SilentlyContinue
}

function Write-UiTargetRegistry {
    param([string]$RegistryPath, $Registry)
    $directory = Split-Path $RegistryPath -Parent
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
    $Registry.updatedAtUtc = [DateTime]::UtcNow.ToString('o')
    $temporary = "$RegistryPath.$([guid]::NewGuid().ToString('N')).tmp"
    $backup = "$RegistryPath.$([guid]::NewGuid().ToString('N')).bak"
    try {
        [IO.File]::WriteAllText($temporary, (($Registry | ConvertTo-Json -Depth 20) + [Environment]::NewLine), $script:Utf8NoBom)
        if (Test-Path -LiteralPath $RegistryPath -PathType Leaf) {
            try { [IO.File]::Replace($temporary, $RegistryPath, $backup) }
            catch [UnauthorizedAccessException] { Move-Item -LiteralPath $temporary -Destination $RegistryPath -Force }
        } else { [IO.File]::Move($temporary, $RegistryPath) }
    } finally {
        Remove-Item -LiteralPath $temporary,$backup -Force -ErrorAction SilentlyContinue
    }
}

function Add-UiMetric {
    param($Metrics, [string]$Name, [double]$Value = 1)
    if ($Metrics.PSObject -and $Metrics.PSObject.Properties.Name -contains $Name) { $Metrics.$Name = [double]$Metrics.$Name + $Value }
    elseif ($Metrics -is [System.Collections.IDictionary]) { $Metrics[$Name] = [double]$Metrics[$Name] + $Value }
}

function Add-UiStrategyMetric {
    param($Metrics, [string]$Strategy)
    $distribution = $Metrics.strategyDistribution
    if ($distribution -is [System.Collections.IDictionary]) {
        if (-not $distribution.Contains($Strategy)) { $distribution[$Strategy] = 0 }
        $distribution[$Strategy] = [int]$distribution[$Strategy] + 1
    } else {
        if ($distribution.PSObject.Properties.Name -notcontains $Strategy) { $distribution | Add-Member -NotePropertyName $Strategy -NotePropertyValue 0 }
        $distribution.$Strategy = [int]$distribution.$Strategy + 1
    }
}

function Get-UiTargetFingerprint {
    param($Target)
    $context = @($Target.context.kind,$Target.context.browser,$Target.context.application,$Target.context.domain,$Target.context.page,$Target.context.window) -join '|'
    $primary = "$($Target.primary.strategy)|$(ConvertTo-NormalizedSelector ([string]$Target.primary.descriptor))|$([string]$Target.primary.objectRepositoryReference)"
    $anchors = @($Target.anchors | ForEach-Object { "$(($_.strategy))|$(ConvertTo-NormalizedSelector ([string]$_.descriptor))" }) -join ';'
    return Get-UiSha256 "$context|$primary|$anchors|$($Target.elementRole)"
}

function Resolve-UiArtifactReference {
    param([string]$ProjectPath, [string]$ArtifactPath, [int64]$MaxBytes)
    if (-not $ArtifactPath) { return $null }
    $prefix = $ProjectPath.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    $full = if ([IO.Path]::IsPathRooted($ArtifactPath)) { [IO.Path]::GetFullPath($ArtifactPath) } else { [IO.Path]::GetFullPath((Join-Path $ProjectPath $ArtifactPath)) }
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'UI target artifact must stay within the project.' }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "UI target artifact not found: $ArtifactPath" }
    $item = Get-Item -LiteralPath $full
    if ($item.Length -gt $MaxBytes) { throw "UI target artifact exceeds the configured size cap: $($item.Length) bytes" }
    return [ordered]@{ path=$full.Substring($prefix.Length) -replace '\\','/'; bytes=[int64]$item.Length; sha256=(Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant() }
}

Export-ModuleMember -Function Get-UiTargetPolicy,Get-UiSha256,ConvertTo-NormalizedSelector,Normalize-UiTargetContext,Test-UiTargetContextMatch,Get-UiTargetCapabilities,Get-UiTargetQuality,New-UiTargetMetrics,New-UiTargetRegistry,Read-UiTargetRegistry,Enter-UiTargetRegistryLock,Exit-UiTargetRegistryLock,Write-UiTargetRegistry,Add-UiMetric,Add-UiStrategyMetric,Get-UiTargetFingerprint,Resolve-UiArtifactReference,ConvertTo-UiTargetV2
