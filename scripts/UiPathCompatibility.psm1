Set-StrictMode -Version 2.0

function Get-NormalizedPackageVersion {
    param([string]$Value)
    if (-not $Value) { return '' }
    return ($Value.Trim() -replace '^[\[\(]\s*','' -replace '\s*[\]\)]$','' -split ',')[0].Trim()
}

function Get-ReleaseLine {
    param([string]$Version)
    $normalized=Get-NormalizedPackageVersion $Version
    if($normalized -match '^(\d+)\.(\d+)'){return "$($Matches[1]).$($Matches[2])"}
    return 'UNKNOWN'
}

function Get-ProjectUiAutomationVersion {
    param([string]$ProjectPath)
    $projectFile=Join-Path $ProjectPath 'project.json'
    if(-not(Test-Path -LiteralPath $projectFile -PathType Leaf)){return [pscustomobject]@{version='UNKNOWN';raw=$null;pinned=$false}}
    try{$project=[IO.File]::ReadAllText($projectFile,[Text.Encoding]::UTF8)|ConvertFrom-Json}catch{return [pscustomobject]@{version='UNKNOWN';raw=$null;pinned=$false}}
    $property=@($project.dependencies.PSObject.Properties|Where-Object Name -ieq 'UiPath.UIAutomation.Activities'|Select-Object -First 1)
    if($property.Count -ne 1){return [pscustomobject]@{version='UNKNOWN';raw=$null;pinned=$false}}
    $raw=[string]$property[0].Value
    return [pscustomobject]@{version=Get-NormalizedPackageVersion $raw;raw=$raw;pinned=($raw -match '^\[.+\]$' -or $raw -match '^\d+\.\d+\.\d+([-.].*)?$')}
}

function Get-LocalUiAutomationVersions {
    param([string]$ProjectPath,[string[]]$AdditionalPackageRoots=@())
    $roots=New-Object Collections.Generic.List[string]
    foreach($candidate in @(
        (Join-Path $ProjectPath '.local\packages\UiPath.UIAutomation.Activities'),
        (Join-Path $ProjectPath '.local\docs\packages\UiPath.UIAutomation.Activities'),
        (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.nuget\packages\uipath.uiautomation.activities')
    )+@($AdditionalPackageRoots)){
        if($candidate -and (Test-Path -LiteralPath $candidate -PathType Container)){[void]$roots.Add((Resolve-Path -LiteralPath $candidate).Path)}
    }
    $versions=New-Object Collections.Generic.List[string]
    foreach($root in $roots){
        foreach($dir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)){
            if($dir.Name -match '^\d+\.\d+'){[void]$versions.Add($dir.Name)}
        }
    }
    return @($versions|Select-Object -Unique|Sort-Object { try { [version]($_ -replace '-.*$','') } catch { [version]'0.0' } } -Descending)
}

function Get-UiAutomationMinimumRequirement {
    param([string]$ProjectPath,[string]$PackageVersion,[string]$StudioVersion,[string[]]$AdditionalPackageRoots=@())
    $result=[ordered]@{status='UNKNOWN';minimumStudioVersion=$null;path=$null;sha256=$null}
    $roots=@(
        (Join-Path $ProjectPath '.local\packages\UiPath.UIAutomation.Activities'),
        (Join-Path $ProjectPath '.local\docs\packages\UiPath.UIAutomation.Activities'),
        (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.nuget\packages\uipath.uiautomation.activities')
    )+@($AdditionalPackageRoots)
    foreach($packageRoot in $roots){
        $path=Join-Path (Join-Path $packageRoot $PackageVersion) 'uipath.uiautomation.activities.nuspec'
        if(-not(Test-Path -LiteralPath $path -PathType Leaf)){continue}
        try{
            $document=New-Object Xml.XmlDocument
            $document.XmlResolver=$null
            $document.Load($path)
            $metadata=$document.SelectSingleNode('/*[local-name()="package"]/*[local-name()="metadata"]')
            $id=$metadata.SelectSingleNode('*[local-name()="id"]').InnerText
            $version=$metadata.SelectSingleNode('*[local-name()="version"]').InnerText
            $description=$metadata.SelectSingleNode('*[local-name()="description"]').InnerText
            if($id -ine 'UiPath.UIAutomation.Activities' -or $version -ne $PackageVersion){continue}
            $minimums=@([regex]::Matches($description,'(?i)\brequires\s+Studio\s+(\d+\.\d+(?:\.\d+){0,2})\s+or\s+higher\b') | ForEach-Object {$_.Groups[1].Value} | Select-Object -Unique)
            if($minimums.Count -ne 1){continue}
            $result.minimumStudioVersion=$minimums[0];$result.path=$path
            $result.sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            if($StudioVersion -match '^\d+\.\d+(?:\.\d+){0,2}$'){
                $hostParts=@($StudioVersion.Split('.'));while($hostParts.Count -lt 4){$hostParts+= '0'}
                $minimumParts=@($minimums[0].Split('.'));while($minimumParts.Count -lt 4){$minimumParts+= '0'}
                $result.status=if([version]($hostParts -join '.') -ge [version]($minimumParts -join '.')){'MET'}else{'NOT_MET'}
            }
            return [pscustomobject]$result
        }catch{continue}
    }
    return [pscustomobject]$result
}

function Get-StudioVersionFromProject {
    param([string]$ProjectPath)
    try{
        $project=[IO.File]::ReadAllText((Join-Path $ProjectPath 'project.json'),[Text.Encoding]::UTF8)|ConvertFrom-Json
        foreach($name in @('studioVersion','studio-version','targetStudioVersion')){
            $property=$project.PSObject.Properties|Where-Object Name -ieq $name|Select-Object -First 1
            if($property -and [string]$property.Value){return [string]$property.Value}
        }
    }catch{}
    return 'UNKNOWN'
}

function Get-InstalledProductVersion {
    param([string]$ProductPattern)
    if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){return 'UNKNOWN'}
    foreach($path in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')){
        try{
            $item=Get-ItemProperty $path -ErrorAction SilentlyContinue|Where-Object {$_.DisplayName -match $ProductPattern -and $_.DisplayVersion}|Select-Object -First 1
            if($item){return [string]$item.DisplayVersion}
        }catch{}
    }
    return 'UNKNOWN'
}

function Get-UiPathEnvironmentCompatibility {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$ProjectPath,
        [ValidateSet('New','Existing')][string]$ProjectKind='Existing',
        [string]$StudioVersion,
        [string]$RobotVersion,
        [string]$CliVersion,
        [string]$CliPath,
        [string[]]$AvailableUiAutomationVersion=@(),
        [string[]]$AdditionalPackageRoots=@(),
        [string[]]$RequiredCapability=@(),
        [string]$CompatibilityEvidencePath,
        [switch]$NewerReleaseCompatibilityEstablished
    )
    $root=(Resolve-Path -LiteralPath $ProjectPath).Path
    $dependency=Get-ProjectUiAutomationVersion $root
    $generatorVersion=Get-StudioVersionFromProject $root
    $studio=if($StudioVersion){$StudioVersion}else{Get-InstalledProductVersion 'UiPath Studio'}
    $studioSource=if($StudioVersion){'supplied authoring host'}else{'installed Studio'}
    $robot=if($RobotVersion){$RobotVersion}else{Get-InstalledProductVersion 'UiPath Robot'}
    if(-not $robot){$robot='UNKNOWN'}
    $cli=if($CliVersion){$CliVersion}else{'UNKNOWN'}
    $toolPath=if($CliPath -and (Test-Path -LiteralPath $CliPath -PathType Leaf)){(Resolve-Path -LiteralPath $CliPath).Path}else{''}
    $toolHash=if($toolPath -and (Test-Path -LiteralPath $toolPath -PathType Leaf)){(Get-FileHash -LiteralPath $toolPath -Algorithm SHA256).Hash}else{'UNKNOWN'}
    $skillRoots=@((Join-Path $root '.github\skills\uipath-rpa'),(Join-Path ([Environment]::GetFolderPath('UserProfile')) '.copilot\skills\uipath-rpa'))
    $skill=@($skillRoots | ForEach-Object { $f=Join-Path $_ 'SKILL.md';if(Test-Path -LiteralPath $f -PathType Leaf){[ordered]@{path=$f;sha256=(Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash;status='VERIFIED';scope='Local skill snapshot only; not runtime proof'}} })
    $projectMetadata=$null
    try{$projectMetadata=[IO.File]::ReadAllText((Join-Path $root 'project.json'))|ConvertFrom-Json}catch{}
    $uiRequired=@($RequiredCapability | Where-Object {$_ -match '^(ui|selector|semantic|computerVision)' }).Count -gt 0
    $guidePath=Join-Path $root '.local\docs\packages\UiPath.UIAutomation.Activities\ui-automation-guide.md'
    $guidePresent=Test-Path -LiteralPath $guidePath -PathType Leaf
    $framework=if($projectMetadata){[string]$projectMetadata.targetFramework}else{''}
    $requiredBlockers=New-Object Collections.Generic.List[string]
    if(-not $toolPath -or $cli -eq 'UNKNOWN'){[void]$requiredBlockers.Add('CLI_IDENTITY_UNKNOWN')}
    if($framework -notin @('Windows','Portable','Legacy')){[void]$requiredBlockers.Add('PROJECT_FRAMEWORK_UNKNOWN')}
    if($uiRequired -and ($dependency.version -eq 'UNKNOWN' -or -not $guidePresent)){[void]$requiredBlockers.Add('REQUIRED_UI_PACKAGE_DOCUMENTATION_UNAVAILABLE')}
    $toolchain=[ordered]@{
        cli=[ordered]@{resolvedPath=$toolPath;launcherSha256=$toolHash;version=$cli;status=if($toolPath -and $cli -ne 'UNKNOWN'){'VERIFIED'}else{'UNKNOWN'}}
        officialSkills=$skill
        project=[ordered]@{targetFramework=if($projectMetadata){$projectMetadata.targetFramework}else{$null};activities=if($projectMetadata){$projectMetadata.dependencies}else{$null};status=if($projectMetadata){'VERIFIED'}else{'UNKNOWN'}}
        packageSchema=[ordered]@{status=if($uiRequired -and $guidePresent){'VERIFIED'}elseif($uiRequired){'UNKNOWN'}else{'NOT_APPLICABLE'};required=$uiRequired;documentationPath=if($guidePresent){$guidePath}else{$null};documentationSha256=if($guidePresent){(Get-FileHash -LiteralPath $guidePath -Algorithm SHA256).Hash}else{$null};reason='Local package documentation identity only; validate/build and live UI evidence remain separate gates.'}
        commandCapabilities=[ordered]@{status='UNKNOWN';reason='Version or installed skill text does not prove command execution; consult command evidence.'}
        capturePrerequisites=[ordered]@{status='UNKNOWN';reason='No live Development capture was performed by environment inventory.'}
        requiredEvidence=[ordered]@{status=if($requiredBlockers.Count){'BLOCKED'}else{'PASS'};blockers=@($requiredBlockers);requiredCapabilities=@($RequiredCapability)}
    }
    $available=@(@($AvailableUiAutomationVersion)+@(Get-LocalUiAutomationVersions -ProjectPath $root -AdditionalPackageRoots $AdditionalPackageRoots)|Where-Object {$_}|Select-Object -Unique)
    $studioLine=Get-ReleaseLine $studio
    $currentLine=Get-ReleaseLine $dependency.version
    $sameLine=@($available|Where-Object {(Get-ReleaseLine $_) -eq $studioLine})
    $minimumRequirements=@{}
    foreach($packageVersion in @(@($dependency.version)+$available | Where-Object {$_ -ne 'UNKNOWN'} | Select-Object -Unique)){
        $minimumRequirements[$packageVersion]=Get-UiAutomationMinimumRequirement -ProjectPath $root -PackageVersion $packageVersion -StudioVersion $studio -AdditionalPackageRoots $AdditionalPackageRoots
    }
    $minimumCompatible=@($available | Where-Object {$minimumRequirements[$_].status -eq 'MET'} | Sort-Object {[version]($_ -replace '-.*$','')} -Descending)
    $sameLine=@($sameLine | Where-Object {$minimumRequirements[$_].status -ne 'NOT_MET'})
    $documentedVersions=@()
    $compatibilityReference=$null
    if($CompatibilityEvidencePath){
        $evidencePath=if([IO.Path]::IsPathRooted($CompatibilityEvidencePath)){$CompatibilityEvidencePath}else{Join-Path $root $CompatibilityEvidencePath}
        $documented=[IO.File]::ReadAllText($evidencePath,[Text.Encoding]::UTF8)|ConvertFrom-Json
        if($documented.schemaVersion -ne 1 -or $studio -eq 'UNKNOWN' -or $cli -eq 'UNKNOWN' -or
            [string]$documented.studioVersion -ne $studio -or [string]$documented.cliVersion -ne $cli){
            throw 'COMPATIBILITY_EVIDENCE_MISMATCH: expected schema 1 and exact current authoring-host and CLI versions.'
        }
        foreach($package in @($documented.packages)){
            $reference=$null
            if(-not [Uri]::TryCreate([string]$package.reference,[UriKind]::Absolute,[ref]$reference) -or
                $reference.Scheme -ne 'https' -or $reference.Host -ne 'docs.uipath.com'){
                throw 'COMPATIBILITY_EVIDENCE_INVALID: an official HTTPS UiPath documentation reference is required.'
            }
            if([string]$package.version -in $available -or [string]$package.version -eq $dependency.version){$documentedVersions+= [string]$package.version}
        }
        $compatibilityReference=[ordered]@{path=$evidencePath;sha256=(Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash.ToLowerInvariant()}
    }
    $selected=$dependency.version
    $decision='UNKNOWN'
    $reason='Compatibility could not be established from available environment evidence.'
    $automaticUpgrade=$false
    if($dependency.version -ne 'UNKNOWN'){
        if($minimumRequirements[$dependency.version].status -eq 'NOT_MET'){
            $decision='INCOMPATIBLE_STUDIO_MINIMUM';$reason="Studio $studio is below package $($dependency.version) minimum Studio $($minimumRequirements[$dependency.version].minimumStudioVersion)."
        }elseif($minimumRequirements[$dependency.version].status -eq 'MET'){
            $decision='PRESERVE_MINIMUM_REQUIREMENT_MET';$reason="Existing package minimum Studio $($minimumRequirements[$dependency.version].minimumStudioVersion) is met by authoring host $studio; release-line equality is not required."
        }elseif($dependency.version -in $documentedVersions){
            $decision='PRESERVE_POSITIVELY_ESTABLISHED';$reason='Existing pin has explicit official compatibility documentation for the current authoring host and CLI.'
        }elseif($studioLine -eq 'UNKNOWN'){
            $decision='PRESERVE_EXISTING_UNKNOWN_ENVIRONMENT';$reason='Studio version is unknown; preserve the existing dependency and do not auto-upgrade.'
        }elseif($currentLine -eq $studioLine){
            $decision='PRESERVE_COMPATIBLE_EXISTING';$reason="Existing UI Automation dependency matches Studio release line $studioLine."
        }else{
            $decision='INCOMPATIBLE_RELEASE_TRAIN';$reason="UI Automation release line $currentLine is not established compatible with Studio release line $studioLine."
        }
    }elseif($minimumCompatible.Count){
        $selected=[string]$minimumCompatible[0]
        $decision='SELECT_MINIMUM_REQUIREMENT_MET';$reason='Selected an available package whose declared minimum Studio requirement is met; restore/build and live capture remain required.'
    }elseif(@($documentedVersions | Where-Object {$minimumRequirements[$_].status -ne 'NOT_MET'}).Count){
        $documentedVersions=@($documentedVersions | Where-Object {$minimumRequirements[$_].status -ne 'NOT_MET'})
        $selected=@($documentedVersions|Sort-Object {[version]($_ -replace '-.*$','')} -Descending)[0]
        $decision='SELECT_DOCUMENTED_COMPATIBLE';$reason='Selected an available package explicitly documented for the current authoring host and CLI; restore/build and live capture remain required.'
    }elseif($studioLine -ne 'UNKNOWN' -and $sameLine.Count){
        $selected=[string]$sameLine[0];$decision='SELECT_COMPATIBLE_RELEASE_LINE';$reason="No current dependency; selected an available package from Studio release line $studioLine."
    }else{$selected='UNKNOWN'}
    $fallbackRequired=@($RequiredCapability).Count -gt 0 -and $decision -in @('INCOMPATIBLE_STUDIO_MINIMUM','INCOMPATIBLE_RELEASE_TRAIN','PRESERVE_EXISTING_UNKNOWN_ENVIRONMENT','UNKNOWN')
    $evidence=[ordered]@{
        source='actual supplied/installed authoring host, separate generator metadata, package inventory and optional official compatibility references'
        studioReleaseLine=$studioLine;currentPackageReleaseLine=$currentLine;availableSameReleaseLine=$sameLine
        newerReleaseCompatibilityEstablished=($documentedVersions.Count -gt 0);existingPinned=[bool]$dependency.pinned
        documentation=$compatibilityReference;legacyCompatibilitySwitchIgnored=([bool]$NewerReleaseCompatibilityEstablished -and -not $CompatibilityEvidencePath)
        packageMinimumRequirements=$minimumRequirements
    }
    $fingerprintInput=(@($studio,$studioSource,$generatorVersion,$robot,$cli,$dependency.version,$selected,($available -join ','),$decision,($compatibilityReference|ConvertTo-Json -Compress),($minimumRequirements|ConvertTo-Json -Depth 5 -Compress),($toolchain|ConvertTo-Json -Depth 10 -Compress)) -join '|')
    $sha=[Security.Cryptography.SHA256]::Create();try{$fingerprint=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($fingerprintInput))) -replace '-','').ToLowerInvariant()}finally{$sha.Dispose()}
    return [pscustomobject][ordered]@{
        schemaVersion=1;detectedStudioVersion=$studio;detectedRobotVersion=$robot;detectedCliVersion=$cli
        studioVersionSource=$studioSource;projectGeneratorStudioVersion=$generatorVersion
        currentUiAutomationVersion=$dependency.version;currentUiAutomationRaw=$dependency.raw;existingDependencyPinned=[bool]$dependency.pinned
        locallyAvailableUiAutomationVersions=$available;selectedUiAutomationVersion=$selected;compatibilityDecision=$decision
        compatibilityEvidence=$evidence;compatibilityReason=$reason;automaticPackageUpgrade=$automaticUpgrade
        requiredCapabilities=@($RequiredCapability);capabilityFallbackRequired=$fallbackRequired;environmentFingerprint=$fingerprint
        toolchainEvidence=$toolchain
    }
}

function Get-UiPathEnumMetadataData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$ProjectPath,
        [string]$PackageVersion='UNKNOWN',
        [string]$EnumTypeName='UIElementType',
        [string]$AssemblyPath,
        [string]$CacheDirectory,
        [switch]$Force
    )
    $root=(Resolve-Path -LiteralPath $ProjectPath).Path
    $cacheRoot=if($CacheDirectory){[IO.Path]::GetFullPath($CacheDirectory)}else{Join-Path $root '.rpa-ai\local\cache\uipath-enums'}
    $assemblies=@()
    if($AssemblyPath){if(Test-Path -LiteralPath $AssemblyPath -PathType Leaf){$assemblies=@((Resolve-Path -LiteralPath $AssemblyPath).Path)}}
    else{
        $version=Get-NormalizedPackageVersion $PackageVersion
        $candidateRoots=@(
            (Join-Path $root ".local\packages\UiPath.UIAutomation.Activities\$version"),
            (Join-Path ([Environment]::GetFolderPath('UserProfile')) ".nuget\packages\uipath.uiautomation.activities\$version")
        )
        foreach($candidate in $candidateRoots){if(Test-Path -LiteralPath $candidate -PathType Container){$assemblies+=@(Get-ChildItem -LiteralPath $candidate -Recurse -File -Filter '*.dll' -ErrorAction SilentlyContinue|Select-Object -ExpandProperty FullName)}}
    }
    $assemblyEvidence=@($assemblies|ForEach-Object{$item=Get-Item -LiteralPath $_;[pscustomobject]@{path=$_.ToLowerInvariant();bytes=$item.Length;ticks=$item.LastWriteTimeUtc.Ticks}})
    $keyText="$PackageVersion|$EnumTypeName|"+(($assemblyEvidence|ConvertTo-Json -Compress)-join '')
    $sha=[Security.Cryptography.SHA256]::Create();try{$key=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($keyText))) -replace '-','').ToLowerInvariant()}finally{$sha.Dispose()}
    $cachePath=Join-Path $cacheRoot "$key.json"
    if(-not $Force -and (Test-Path -LiteralPath $cachePath -PathType Leaf)){
        try{$cached=[IO.File]::ReadAllText($cachePath,[Text.Encoding]::UTF8)|ConvertFrom-Json;if($cached.cacheKey -eq $key){$cached.cacheStatus='HIT';return $cached}}catch{}
    }
    $values=New-Object Collections.Generic.List[string]
    $resolvedType=$null;$resolvedAssembly=$null;$reflectionErrors=New-Object Collections.Generic.List[string]
    foreach($path in $assemblies){
        try{
            $assembly=[Reflection.Assembly]::LoadFrom($path)
            $type=@($assembly.GetTypes()|Where-Object {$_.IsEnum -and ($_.Name -eq $EnumTypeName -or $_.FullName -eq $EnumTypeName)}|Select-Object -First 1)
            if($type.Count){$resolvedType=$type[0];$resolvedAssembly=$assembly;foreach($name in [Enum]::GetNames($resolvedType)){[void]$values.Add($name)};break}
        }catch{[void]$reflectionErrors.Add("${path}:$($_.Exception.Message)")}
    }
    $result=[ordered]@{
        schemaVersion=1;cacheKey=$key;cacheStatus='MISS';status=if($resolvedType){'RESOLVED'}else{'UNAVAILABLE'}
        enumType=if($resolvedType){$resolvedType.FullName}else{$EnumTypeName};values=@($values|Select-Object -Unique)
        packageVersion=$PackageVersion;assemblyPath=if($resolvedAssembly){$resolvedAssembly.Location}else{$null}
        assemblyVersion=if($resolvedAssembly){$resolvedAssembly.GetName().Version.ToString()}else{$null}
        assemblySha256=if($resolvedAssembly){(Get-FileHash -LiteralPath $resolvedAssembly.Location -Algorithm SHA256).Hash.ToLowerInvariant()}else{$null}
        reflectionErrors=$reflectionErrors.ToArray();createdAtUtc=[DateTime]::UtcNow.ToString('o')
    }
    New-Item -ItemType Directory -Force -Path $cacheRoot|Out-Null
    [IO.File]::WriteAllText($cachePath,(($result|ConvertTo-Json -Depth 8)+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))
    return [pscustomobject]$result
}

function Test-UiPathXamlCompatibilityData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$ProjectPath,
        [Parameter(Mandatory=$true)][string[]]$Workflow,
        [Parameter(Mandatory=$true)]$Environment,
        [string]$PolicyPath,
        [string]$AssemblyPath,
        [string[]]$ResolvedUiElementTypeValue=@(),
        [string]$ParentEventId='',
        [switch]$OmitUnsupportedOptionalProperty
    )
    $root=(Resolve-Path -LiteralPath $ProjectPath).Path
    $prefix=$root.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    $telemetryEnabled=Test-Path -LiteralPath (Join-Path $root '.ai\evidence\execution-state.json') -PathType Leaf
    if($telemetryEnabled){Import-Module (Join-Path $PSScriptRoot 'DeveloperTelemetry.psm1') -Force}
    $policyFile=if($PolicyPath){(Resolve-Path -LiteralPath $PolicyPath).Path}else{Join-Path $PSScriptRoot '..\validation\uipath-serialization-policy.json'}
    $policy=[IO.File]::ReadAllText($policyFile,[Text.Encoding]::UTF8)|ConvertFrom-Json
    $enumMetadata=if(@($ResolvedUiElementTypeValue).Count){[pscustomobject][ordered]@{status='RESOLVED';enumType='UIElementType';values=@($ResolvedUiElementTypeValue);cacheStatus='TEST_OVERRIDE';packageVersion=[string]$Environment.selectedUiAutomationVersion;assemblySha256=$null}}else{Get-UiPathEnumMetadataData -ProjectPath $root -PackageVersion ([string]$Environment.selectedUiAutomationVersion) -AssemblyPath $AssemblyPath}
    $issues=New-Object Collections.Generic.List[object];$workflowResults=New-Object Collections.Generic.List[object]
    foreach($relativeInput in @($Workflow|Select-Object -Unique)){
        $readStarted=[DateTime]::UtcNow
        $full=if([IO.Path]::IsPathRooted($relativeInput)){[IO.Path]::GetFullPath($relativeInput)}else{[IO.Path]::GetFullPath((Join-Path $root ($relativeInput -replace '/','\')))}
        if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw "Workflow must stay within the project: $relativeInput"}
        $relative=$full.Substring($prefix.Length) -replace '\\','/'
        if(-not(Test-Path -LiteralPath $full -PathType Leaf)){[void]$issues.Add([ordered]@{classification='WORKFLOW_NOT_FOUND';workflow=$relative});continue}
        $beforeHash=(Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant();$beforeBytes=(Get-Item -LiteralPath $full).Length
        $xml=New-Object Xml.XmlDocument;$xml.PreserveWhitespace=$true
        try{$xml.Load($full)}catch{[void]$issues.Add([ordered]@{classification='XAML_XML_INVALID';workflow=$relative;error=$_.Exception.Message});continue}
        $readEnded=[DateTime]::UtcNow
        if($telemetryEnabled){$readEvent=Start-DeveloperEvent -ProjectPath $root -Category SOURCE_READ -Subcategory 'xaml.read' -Operation 'source.read' -ParentEventId $ParentEventId -Artifacts @([ordered]@{path=$relative;sha256=$beforeHash;bytes=[int64]$beforeBytes}) -NowUtc $readStarted.ToString('o');Stop-DeveloperEvent -ProjectPath $root -EventId $readEvent.eventId -Status PASS -NowUtc $readEnded.ToString('o')|Out-Null}
        $removed=New-Object Collections.Generic.List[object]
        foreach($property in @($policy.enumProperties)){
            $attributes=@($xml.SelectNodes('//@*')|Where-Object {$_.LocalName -eq [string]$property.property})
            foreach($attribute in $attributes){
                $valid=$enumMetadata.status -eq 'RESOLVED' -and @($enumMetadata.values) -contains [string]$attribute.Value
                if($valid){continue}
                $activity=if($attribute.OwnerElement){$attribute.OwnerElement.LocalName}else{'UNKNOWN'}
                $issue=[ordered]@{
                    classification='UIPATH_XAML_ENUM_INCOMPATIBLE';workflow=$relative;activity=$activity;property=[string]$property.property
                    invalidValue=[string]$attribute.Value;resolvedEnumType=[string]$property.enumType;uiAutomationPackageVersion=[string]$Environment.selectedUiAutomationVersion
                    studioVersion=[string]$Environment.detectedStudioVersion;runtimeVersion=[string]$Environment.detectedRobotVersion
                    enumResolutionStatus=[string]$enumMetadata.status;optional=[bool]$property.optional;action='BLOCKED'
                }
                if([bool]$property.optional -and $OmitUnsupportedOptionalProperty){
                    [void]$attribute.OwnerElement.RemoveAttributeNode($attribute);$issue.action='OMITTED_OPTIONAL_PROPERTY';[void]$removed.Add($issue)
                }else{[void]$issues.Add($issue)}
            }
        }
        $repairMilliseconds=0.0
        if($removed.Count){
            $repairStarted=[DateTime]::UtcNow;$settings=New-Object Xml.XmlWriterSettings;$settings.Encoding=New-Object Text.UTF8Encoding($false);$settings.Indent=$false;$writer=[Xml.XmlWriter]::Create($full,$settings);try{$xml.Save($writer)}finally{$writer.Dispose()};$repairEnded=[DateTime]::UtcNow;$repairMilliseconds=[Math]::Round(($repairEnded-$repairStarted).TotalMilliseconds,3)
        }
        $afterHash=(Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant();$afterBytes=(Get-Item -LiteralPath $full).Length
        if($removed.Count -and $telemetryEnabled){$repairEvent=Start-DeveloperEvent -ProjectPath $root -Category SOURCE_REPAIR -Subcategory 'enum_property_omission' -Operation 'source.repair' -ParentEventId $ParentEventId -Artifacts @([ordered]@{path=$relative;sha256=$beforeHash;bytes=[int64]$beforeBytes}) -NowUtc $repairStarted.ToString('o');Stop-DeveloperEvent -ProjectPath $root -EventId $repairEvent.eventId -Status PASS -Artifacts @([ordered]@{path=$relative;sha256=$afterHash;bytes=[int64]$afterBytes}) -NowUtc $repairEnded.ToString('o')|Out-Null}
        [void]$workflowResults.Add([ordered]@{workflow=$relative;sourceHashBefore=$beforeHash;sourceHashAfter=$afterHash;bytesBefore=[int64]$beforeBytes;bytesAfter=[int64]$afterBytes;optionalPropertiesOmitted=$removed.ToArray();changed=$beforeHash -ne $afterHash;repairDurationMs=$repairMilliseconds})
    }
    return [pscustomobject][ordered]@{
        schemaVersion=1;status=if($issues.Count){'BLOCKED'}else{'PASS'};classification=if($issues.Count){'UIPATH_XAML_ENUM_INCOMPATIBLE'}else{'COMPATIBLE'}
        environment=$Environment;enumMetadata=$enumMetadata;workflows=$workflowResults.ToArray();issues=$issues.ToArray();semanticRoleMappedToEnum=$false
    }
}

Export-ModuleMember -Function Get-NormalizedPackageVersion,Get-ReleaseLine,Get-ProjectUiAutomationVersion,Get-LocalUiAutomationVersions,Get-UiPathEnvironmentCompatibility,Get-UiPathEnumMetadataData,Test-UiPathXamlCompatibilityData
