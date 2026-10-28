[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$manager = Join-Path $root 'scripts\Manage-UiTargetRegistry.ps1'
$resolver = Join-Path $root 'scripts\Resolve-UiTarget.ps1'
$qualityScript = Join-Path $root 'scripts\Get-UiTargetQuality.ps1'
$capabilityScript = Join-Path $root 'scripts\Get-UiTargetCapabilities.ps1'
$testRoot = Join-Path $env:TEMP ('rpa-ui-target-tests-' + [guid]::NewGuid().ToString('N'))
$utf8 = New-Object Text.UTF8Encoding($false)

function Assert-True { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw $Message } }
function Write-Text { param([string]$Path,[string]$Value) New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null; [IO.File]::WriteAllText($Path,$Value,$utf8) }
function New-Project {
    param([string]$Name,[string]$Version='24.10.1',[string]$Evidence='',[switch]$NoUiAutomation,[switch]$ObjectRepository)
    $path=Join-Path $testRoot $Name; New-Item -ItemType Directory -Force -Path $path | Out-Null
    $dependencies=if($NoUiAutomation){[ordered]@{'UiPath.System.Activities'='24.10.1'}}else{[ordered]@{'UiPath.UIAutomation.Activities'=$Version}}
    Write-Text (Join-Path $path 'project.json') (($([ordered]@{name=$Name;dependencies=$dependencies})|ConvertTo-Json -Depth 5))
    if($Evidence){Write-Text (Join-Path $path '.local\docs\packages\UiPath.UIAutomation.Activities\features.md') $Evidence}
    if($ObjectRepository){New-Item -ItemType Directory -Force -Path (Join-Path $path 'ObjectRepository')|Out-Null}
    return $path
}
function New-TargetJson {
    param([string]$Id,[string]$Name,[string]$Descriptor="<webctrl id='stable-id' role='button' />",[string]$Domain='example.test',[string]$Page='/upload',[string]$Kind='Web',[string]$Application='',[string]$Window='')
    return ([ordered]@{targetId=$Id;logicalName=$Name;context=[ordered]@{kind=$Kind;browser='Chrome';application=$Application;domain=$Domain;page=$Page;window=$Window};elementRole='button';primary=[ordered]@{strategy='StrictSelector';descriptor=$Descriptor};validation=[ordered]@{status='PASS';level='LIVE';method='fixture';validatedAtUtc=[DateTime]::UtcNow.ToString('o');environmentFingerprint='';matchCount=1;actualRole='button'};lifecycle='REUSABLE'}|ConvertTo-Json -Depth 8 -Compress)
}
function New-Candidate {
    param([string]$Strategy='StrictSelector',[string]$Descriptor="<webctrl id='stable-id' role='button' />",[string]$Status='PASS',[string]$Level='LIVE',[int]$Matches=1,[string]$Role='button',[string]$Anchor='')
    return [ordered]@{strategy=$Strategy;descriptor=$Descriptor;anchorDescriptor=$Anchor;validationStatus=$Status;validationLevel=$Level;validationMethod='deterministic-fixture';validationDurationMs=2.5;matchCount=$Matches;actualRole=$Role}
}
function Invoke-Resolve {
    param([string]$Project,[string]$Id,[string]$Name,[object[]]$Candidates=@(),[string]$Kind='Web',[string]$Domain='example.test',[string]$Page='/upload',[string]$Application='',[string]$Window='',[string]$Reuse='NOT_RUN',[switch]$Coordinate,[string[]]$FeatureEvidence=@())
    $candidateJson=if($Candidates.Count){$Candidates|ConvertTo-Json -Depth 10 -Compress}else{'[]'}
    return & $resolver -ProjectPath $Project -TargetId $Id -LogicalName $Name -ContextKind $Kind -Domain $Domain -Page $Page -Application $Application -Window $Window -ExpectedRole button -DiscoveryCandidatesJson $candidateJson -ReuseValidationStatus $Reuse -AllowCoordinateFallback:$Coordinate -FeatureEvidencePath $FeatureEvidence -Json | ConvertFrom-Json
}

try {
    New-Item -ItemType Directory -Force -Path $testRoot | Out-Null

    # 1-5: create/add/load/update/deduplicate.
    $registryProject=New-Project 'registry'
    $init=& $manager -Action Initialize -ProjectPath $registryProject -Json|ConvertFrom-Json
    Assert-True ($init.status -eq 'INITIALIZED' -and (Test-Path (Join-Path $registryProject '.devkit\ui-targets\registry.json'))) '1. Registry creation failed.'
    $add=& $manager -Action Upsert -ProjectPath $registryProject -TargetJson (New-TargetJson web.upload 'Upload drop zone') -Json|ConvertFrom-Json
    Assert-True ($add.status -eq 'ADDED' -and $add.target.lifecycle -eq 'REUSABLE') '2. Validated target add failed.'
    $get=& $manager -Action Get -ProjectPath $registryProject -TargetId web.upload -Json|ConvertFrom-Json
    Assert-True ($get.status -eq 'FOUND' -and $get.target.logicalName -eq 'Upload drop zone') '3. Target load failed.'
    $update=& $manager -Action Upsert -ProjectPath $registryProject -TargetJson (New-TargetJson web.upload 'Upload area') -Json|ConvertFrom-Json
    Assert-True ($update.status -eq 'UPDATED' -and $update.target.logicalName -eq 'Upload area') '4. Target update failed.'
    $duplicate=& $manager -Action Upsert -ProjectPath $registryProject -TargetJson (New-TargetJson web.upload.copy 'Upload copy') -Json|ConvertFrom-Json
    Assert-True ($duplicate.status -eq 'DUPLICATE_PREVENTED' -and $duplicate.duplicateTargetId -eq 'web.upload') '5. Duplicate target was not prevented.'

    # 6-12: malformed/stale/missing/context/migration/atomic concurrency.
    $malformed=New-Project 'malformed'; Write-Text (Join-Path $malformed '.devkit\ui-targets\registry.json') '{bad'
    $malformedFailed=$false; try{& $manager -Action Get -ProjectPath $malformed -Json|Out-Null}catch{$malformedFailed=$_.Exception.Message -match 'malformed'}
    Assert-True $malformedFailed '6. Malformed registry did not fail safely.'
    $stale=& $manager -Action MarkStale -ProjectPath $registryProject -TargetId web.upload -Reason 'selector no longer resolves' -Json|ConvertFrom-Json
    Assert-True ($stale.status -eq 'STALE' -and $stale.target.validation.status -eq 'STALE') '7. Stale target was not marked.'
    Assert-True ((& $manager -Action Get -ProjectPath $registryProject -TargetId web.missing -Json|ConvertFrom-Json).status -eq 'NOT_FOUND') '8. Missing target lookup was incorrect.'
    $mismatch=Invoke-Resolve $registryProject web.upload 'Upload area' @() Web other.test /upload
    Assert-True ($mismatch.targetReuseFailed -and $mismatch.targetReuseFailureReason -eq 'APPLICATION_OR_PAGE_MISMATCH') '9. Application/domain mismatch was not rejected.'
    $pageMismatch=Invoke-Resolve $registryProject web.upload 'Upload area' @() Web example.test /other
    Assert-True ($pageMismatch.targetReuseFailed -and $pageMismatch.targetReuseFailureReason -eq 'APPLICATION_OR_PAGE_MISMATCH') '10. Page mismatch was not rejected.'
    $migration=New-Project 'migration'; Write-Text (Join-Path $migration '.devkit\ui-targets\registry.json') '{"schemaVersion":1,"entries":[{"targetId":"web.legacy","logicalName":"Legacy","strategy":"StrictSelector","selector":"<webctrl id=''legacy'' />","application":{"browser":"Chrome","domain":"legacy.test","page":"/"}}]}'
    $migrated=& $manager -Action Initialize -ProjectPath $migration -Json|ConvertFrom-Json
    Assert-True ($migrated.registrySchemaVersion -eq 2 -and $migrated.targetCount -eq 1) '11. Schema migration/backward compatibility failed.'
    $concurrent=New-Project 'concurrent'; & $manager -Action Initialize -ProjectPath $concurrent|Out-Null
    $job1=Start-Job -ScriptBlock { param($m,$p,$j) & $m -Action Upsert -ProjectPath $p -TargetJson $j -Json } -ArgumentList $manager,$concurrent,(New-TargetJson web.one One "<webctrl id='one' />")
    $job2=Start-Job -ScriptBlock { param($m,$p,$j) & $m -Action Upsert -ProjectPath $p -TargetJson $j -Json } -ArgumentList $manager,$concurrent,(New-TargetJson web.two Two "<webctrl id='two' />")
    Wait-Job $job1,$job2|Out-Null; Receive-Job $job1,$job2|Out-Null; Remove-Job $job1,$job2
    $concurrentRegistry=& $manager -Action Get -ProjectPath $concurrent -Json|ConvertFrom-Json
    Assert-True ($concurrentRegistry.targetCount -eq 2) '12. Concurrent atomic registry writes lost an update or corrupted JSON.'

    # 13-22: deterministic selector quality.
    $stableId=& $qualityScript -Selector "<webctrl id='upload-button' />" -MatchCount 1 -Json|ConvertFrom-Json
    $nameRole=& $qualityScript -Selector "<webctrl name='Upload' role='button' />" -MatchCount 1 -Json|ConvertFrom-Json
    $aria=& $qualityScript -Selector "<webctrl aria-label='Upload file' role='button' />" -MatchCount 1 -Json|ConvertFrom-Json
    $dynamic=& $qualityScript -Selector "<webctrl id='ember-93847563' role='button' />" -MatchCount 1 -Json|ConvertFrom-Json
    $volatile=& $qualityScript -Selector "<webctrl title='Session 2026-09-10' />" -MatchCount 1 -Json|ConvertFrom-Json
    $indexed=& $qualityScript -Selector "<webctrl name='Upload' idx='7' />" -MatchCount 1 -Json|ConvertFrom-Json
    $long=& $qualityScript -Selector "<html><body><div><section><form><webctrl id='upload-button' /></form></section></div></body></html>" -MatchCount 1 -Json|ConvertFrom-Json
    $anchored=& $qualityScript -Selector "<webctrl name='Upload' />" -AnchorSelector "<webctrl id='stable-panel' />" -MatchCount 1 -Json|ConvertFrom-Json
    $ambiguous=& $qualityScript -Selector "<webctrl id='upload-button' />" -MatchCount 3 -Json|ConvertFrom-Json
    $coordinate=& $qualityScript -Selector 'x=120;y=400' -Strategy Coordinate -MatchCount 1 -Json|ConvertFrom-Json
    Assert-True ($stableId.classification -eq 'GOOD') '13. Stable ID quality failed.'
    Assert-True ($nameRole.classification -eq 'GOOD') '14. Stable name/role quality failed.'
    Assert-True ($aria.classification -in @('GOOD','ACCEPTABLE')) '15. Stable aria quality failed.'
    Assert-True ($dynamic.warnings -contains 'DYNAMIC_ID' -and $dynamic.classification -in @('FRAGILE','REJECT')) '16. Dynamic ID was not penalized.'
    Assert-True ($volatile.warnings -contains 'VOLATILE_VALUE') '17. Volatile title was not detected.'
    Assert-True ($indexed.warnings -contains 'POSITIONAL_INDEX') '18. Unnecessary index was not detected.'
    Assert-True ($long.warnings -contains 'LONG_HIERARCHY') '19. Brittle hierarchy was not detected.'
    Assert-True ($anchored.positiveSignals -contains 'RELIABLE_ANCHOR' -and $anchored.classification -in @('GOOD','ACCEPTABLE')) '20. Valid anchor did not improve quality.'
    Assert-True ($ambiguous.warnings -contains 'AMBIGUOUS_MATCH') '21. Ambiguous selector was not rejected/penalized.'
    Assert-True ($coordinate.classification -eq 'REJECT' -and $coordinate.warnings -contains 'COORDINATE_ONLY') '22. Coordinate-only selector classification failed.'
    $suffixId=& $qualityScript -Selector "<webctrl id='btn_48213' role='button' />" -MatchCount 1 -Json|ConvertFrom-Json
    $generatedClass=& $qualityScript -Selector "<webctrl tag='BUTTON' class='css-1q2w3e4 primary' />" -MatchCount 1 -Json|ConvertFrom-Json
    $dynamicText=& $qualityScript -Selector "<webctrl aaname='Total 1,234.50' role='cell' />" -MatchCount 1 -Json|ConvertFrom-Json
    $needsFallback=& $qualityScript -Selector "<webctrl name='Upload' />" -MatchCount 1 -Json|ConvertFrom-Json
    Assert-True ($suffixId.warnings -contains 'DYNAMIC_ID') '22a. Numeric-suffix ID was not treated as dynamic.'
    Assert-True ($generatedClass.warnings -contains 'GENERATED_CLASS') '22b. Generated CSS class was not penalized.'
    Assert-True ($dynamicText.warnings -contains 'DYNAMIC_TEXT') '22c. Amount/date in visible text was not penalized.'
    Assert-True (-not $stableId.fallbackRequired -and ($needsFallback.fallbackRequired -and $needsFallback.warnings -contains 'FALLBACK_REQUIRED') -and -not $anchored.fallbackRequired) '22d. Fallback requirement was not reported for non-GOOD selectors without an anchor.'

    # 23-33: reuse and bounded capability-aware fallback.
    $reuseProject=New-Project 'reuse' -Evidence 'Semantic DOM selector. Semantic image target. Computer Vision target. Validate target.'
    $newResult=Invoke-Resolve $reuseProject web.submit Submit @((New-Candidate))
    $registryHashBeforeReuse=(Get-FileHash (Join-Path $reuseProject '.devkit\ui-targets\registry.json') -Algorithm SHA256).Hash
    $reused=Invoke-Resolve $reuseProject web.submit Submit @() Web example.test 'https://example.test/upload?session=transient'
    $registryHashAfterReuse=(Get-FileHash (Join-Path $reuseProject '.devkit\ui-targets\registry.json') -Algorithm SHA256).Hash
    Assert-True ($reused.status -eq 'REUSED' -and $reused.targetReuseSucceeded -and $registryHashBeforeReuse -eq $registryHashAfterReuse -and $reused.timings.registryWriteMs -eq 0) '23. Valid registry target was not reused read-only.'
    $domFallback=Invoke-Resolve $reuseProject web.submit Submit @((New-Candidate DomSelector "<webctrl id='submit-v2' role='button' />")) Web example.test /upload '' '' FAIL
    Assert-True ($domFallback.status -eq 'RESOLVED' -and $domFallback.strategy -eq 'DomSelector' -and $domFallback.targetReuseFailed) '24-25. Failed reuse did not fall back to DOM discovery.'
    $anchorFallback=Invoke-Resolve $reuseProject web.anchor Anchor @((New-Candidate StrictSelector "<webctrl tag='BUTTON' />" FAIL LIVE 0), (New-Candidate AnchorSelector "<webctrl name='Upload' />" PASS LIVE 1 button "<webctrl id='stable-panel' />"))
    Assert-True ($anchorFallback.strategy -eq 'AnchorSelector') '26. Anchor fallback failed.'
    $fuzzyFallback=Invoke-Resolve $reuseProject web.fuzzy Fuzzy @((New-Candidate StrictSelector "<webctrl tag='BUTTON' />" FAIL LIVE 0), (New-Candidate FuzzySelector "<webctrl name='Upload invoice' role='button' />"))
    Assert-True ($fuzzyFallback.strategy -eq 'FuzzySelector') '27. Supported fuzzy fallback failed.'
    $semanticDom=Invoke-Resolve $reuseProject web.semantic Semantic @((New-Candidate SemanticDom "file upload drop zone"))
    Assert-True ($semanticDom.strategy -eq 'SemanticDom') '28. Supported semantic DOM fallback failed.'
    $semanticImage=Invoke-Resolve $reuseProject web.semantic-image 'Semantic image' @((New-Candidate SemanticImage 'file upload drop zone'))
    Assert-True ($semanticImage.strategy -eq 'SemanticImage') '29. Supported semantic image/CV fallback failed.'
    Write-Text (Join-Path $reuseProject '.ai\evidence\targets\cv-reference.png') ('x' * 128)
    $cvCandidate=New-Candidate ComputerVision 'file upload drop zone'; $cvCandidate.artifactPath='.ai/evidence/targets/cv-reference.png'
    $cvResult=Invoke-Resolve $reuseProject web.cv-reference 'CV reference' @($cvCandidate)
    Assert-True ($cvResult.status -eq 'RESOLVED' -and (Get-Content (Join-Path $reuseProject '.devkit\ui-targets\registry.json') -Raw) -notmatch ('x' * 64)) 'CV/image artifact bytes were embedded instead of referenced.'
    $unsupported=New-Project 'unsupported' -Version '19.4.0'
    $unsupportedSemantic=Invoke-Resolve $unsupported web.semantic Semantic @((New-Candidate SemanticDom 'upload drop zone'))
    Assert-True ($unsupportedSemantic.status -eq 'UNRESOLVED_TARGET' -and $unsupportedSemantic.attempts[0].reason -eq 'CAPABILITY_UNSUPPORTED') '30. Unsupported semantic capability did not fail conservatively.'
    $unsupportedCv=Invoke-Resolve $unsupported web.cv CV @((New-Candidate ComputerVision 'upload image'))
    Assert-True ($unsupportedCv.status -eq 'UNRESOLVED_TARGET' -and $unsupportedCv.attempts[0].reason -eq 'CAPABILITY_UNSUPPORTED') '31. Unsupported CV capability did not fail conservatively.'
    $allFail=Invoke-Resolve $reuseProject web.fail Failure @((New-Candidate StrictSelector "<webctrl tag='BUTTON' />" FAIL LIVE 0), (New-Candidate FuzzySelector "<webctrl name='Missing' />" FAIL LIVE 0))
    Assert-True ($allFail.status -eq 'UNRESOLVED_TARGET' -and $allFail.unresolved) '32. Exhausted strategies did not return unresolved target.'
    $same=New-Candidate StrictSelector "<webctrl id='duplicate' />" FAIL LIVE 0
    $noLoop=Invoke-Resolve $reuseProject web.loop Loop @($same,$same,$same)
    $noLoopAgain=Invoke-Resolve $reuseProject web.loop Loop @($same)
    Assert-True (@($noLoop.attempts|Where-Object reason -eq 'DUPLICATE_ATTEMPT_PREVENTED').Count -eq 2 -and @($noLoop.attempts|Where-Object status -eq 'FAILED').Count -eq 1 -and $noLoopAgain.attempts[0].reason -eq 'PREVIOUS_IDENTICAL_ATTEMPT_PREVENTED' -and $noLoopAgain.metrics.discoveryCount -eq 0) '33. Identical retries were repeated within or across resolution calls.'
    $staticOnly=Invoke-Resolve $reuseProject web.static Static @((New-Candidate StrictSelector "<webctrl id='static-only' role='button' />" PASS STATIC 1 button))
    Assert-True ($staticOnly.status -eq 'VALIDATION_REQUIRED' -and $staticOnly.lifecycle -eq 'VALIDATED') 'Static validation was falsely treated as live reusable proof.'
    $unsupportedValidation=Invoke-Resolve $reuseProject web.no-validation 'No validation' @((New-Candidate StrictSelector "<webctrl id='no-validation' role='button' />" PASS UNSUPPORTED 1 button))
    Assert-True ($unsupportedValidation.status -eq 'BLOCKED_UI_CAPTURE') 'Unsupported live validation was falsely reported as PASS.'
    $coordinateLast=Invoke-Resolve $reuseProject web.coordinate Coordinate @((New-Candidate Coordinate 'x=100;y=200' PASS LIVE 1 button)) Web example.test /upload '' '' NOT_RUN -Coordinate
    Assert-True ($coordinateLast.status -eq 'RESOLVED_NONREUSABLE' -and $coordinateLast.lifecycle -ne 'REUSABLE') 'Coordinate fallback was trusted as a reusable default.'
    $sensitive=Invoke-Resolve $reuseProject web.secret Secret @((New-Candidate StrictSelector "<webctrl token='abcdefghijklmnop1234' role='button' />"))
    Assert-True ($sensitive.attempts[0].reason -eq 'SENSITIVE_DESCRIPTOR_REJECTED') 'Sensitive target material was not rejected.'

    # 34-38: separate web/Chrome and native dialog contexts.
    Assert-True ($newResult.context.kind -eq 'Web' -and $newResult.strategy -eq 'StrictSelector') '34. Browser DOM target resolution failed.'
    Assert-True ($newResult.context.browser -eq 'Chrome') '35. Chrome is not the default browser.'
    $native=Invoke-Resolve $reuseProject native.open.filename 'Open filename' @((New-Candidate DomSelector "<webctrl id='filename' />"),(New-Candidate StrictSelector "<wnd app='explorer.exe' /><ctrl name='File name:' role='edit' />")) Native '' '' 'Windows Open Dialog' 'Open'
    Assert-True ($native.status -eq 'RESOLVED' -and $native.context.kind -eq 'Native') '36. Native Windows Open dialog target failed.'
    Assert-True (@($native.attempts|Where-Object strategy -eq 'DomSelector').Count -eq 0 -and $native.strategy -eq 'StrictSelector') '37. DOM strategy was attempted against a native dialog.'
    $registryData=Get-Content (Join-Path $reuseProject '.devkit\ui-targets\registry.json') -Raw|ConvertFrom-Json
    Assert-True ((@($registryData.targets|Where-Object {$_.context.kind -eq 'Web'}).Count -gt 0) -and (@($registryData.targets|Where-Object {$_.context.kind -eq 'Native'}).Count -eq 1)) '38. Context-specific registry entries were not retained.'

    # 39-45: capability detection without upgrades or onboarding.
    $oldCaps=& $capabilityScript -ProjectPath $unsupported -Json|ConvertFrom-Json
    Assert-True ($oldCaps.uiAutomationVersion -eq '19.4.0' -and -not $oldCaps.fuzzySelector) '39. Older UI Automation dependency detection failed.'
    $supportedCaps=& $capabilityScript -ProjectPath $reuseProject -Json|ConvertFrom-Json
    Assert-True $supportedCaps.semanticDom '40. Semantic selector support evidence was missed.'
    Assert-True (-not $oldCaps.semanticDom) '41. Semantic selectors were falsely claimed.'
    Assert-True $supportedCaps.targetValidation '42. Target validation support evidence was missed.'
    Assert-True (-not $oldCaps.targetValidation) '43. Target validation was falsely claimed.'
    $objectProject=New-Project 'object-repository' -ObjectRepository
    Assert-True ((& $capabilityScript -ProjectPath $objectProject -Json|ConvertFrom-Json).objectRepository) '44. Object Repository availability was missed.'
    $objectCandidate=[ordered]@{strategy='ObjectRepository';objectRepositoryReference='ObjectRepository/UploadButton';validationStatus='PASS';validationLevel='LIVE';validationMethod='fixture';validationDurationMs=1;matchCount=1;actualRole='button'}
    Assert-True ((Invoke-Resolve $objectProject web.object 'Object target' @($objectCandidate)).strategy -eq 'ObjectRepository') 'Object Repository interoperability failed.'
    Assert-True (-not $oldCaps.objectRepository) '45. Object Repository was falsely required.'
    $nonUiProject=New-Project 'non-ui' -NoUiAutomation
    $nonUiCapabilities=& $capabilityScript -ProjectPath $nonUiProject -Json|ConvertFrom-Json
    Assert-True (-not $nonUiCapabilities.uiAutomationDependencyPresent -and -not $nonUiCapabilities.strictSelector -and -not (Test-Path (Join-Path $nonUiProject '.devkit\ui-targets'))) 'Non-UI capability inspection created targeting state or claimed UI support.'
    $negativeEvidenceProject=New-Project 'negative-evidence' -Evidence 'Semantic selectors are not supported. Computer Vision unavailable. Target validation unsupported.'
    $negativeCapabilities=& $capabilityScript -ProjectPath $negativeEvidenceProject -Json|ConvertFrom-Json
    Assert-True (-not $negativeCapabilities.semanticDom -and -not $negativeCapabilities.computerVision -and -not $negativeCapabilities.targetValidation) 'Negative capability evidence was misread as support.'

    # Validation progression, compact bindings, and process-local capability reuse.
    $progressionProject=New-Project 'progression'
    $staticCandidate=New-Candidate StrictSelector "<webctrl id='progression' role='button' />" PASS STATIC
    $pending=Invoke-Resolve $progressionProject web.progression Progression @($staticCandidate)
    Assert-True ($pending.status -eq 'VALIDATION_REQUIRED' -and $null -eq $pending.binding) 'Unproven target exposed an accepted binding.'
    $staticCandidate.validationLevel='LIVE'
    $promoted=Invoke-Resolve $progressionProject web.progression Progression @($staticCandidate)
    Assert-True ($promoted.status -eq 'RESOLVED' -and $promoted.binding.primary.descriptor -eq $staticCandidate.descriptor) 'Static-to-live progression was blocked as duplicate discovery.'
    $promotedReuse=Invoke-Resolve $progressionProject web.progression Progression
    Assert-True ($promotedReuse.status -eq 'REUSED' -and $promotedReuse.binding.targetFingerprint -eq $promoted.binding.targetFingerprint) 'Reused binding did not match the accepted target.'
    Assert-True ($promoted.metrics.browserExplorationOperations -eq 0 -and $promoted.metrics.candidateEvaluationCount -eq 1 -and $promoted.timingScope -eq 'RESOLVER_ONLY_NOT_END_TO_END_UI_CAPTURE') 'Candidate processing was reported as browser exploration.'
    $failedCandidate=New-Candidate StrictSelector "<webctrl id='failed-progress' role='button' />" FAIL LIVE 0
    Invoke-Resolve $progressionProject web.failed-progress Failed @($failedCandidate)|Out-Null
    $failedCandidate.validationStatus='PASS'; $failedCandidate.matchCount=1
    $failedAgain=Invoke-Resolve $progressionProject web.failed-progress Failed @($failedCandidate)
    Assert-True ($failedAgain.status -eq 'UNRESOLVED_TARGET' -and $failedAgain.attempts[-1].reason -eq 'PREVIOUS_IDENTICAL_ATTEMPT_PREVENTED') 'Equivalent failed discovery was revived by a claimed validation change.'
    $directProject=New-Project 'direct-validation'
    & $manager -Action Upsert -ProjectPath $directProject -TargetJson (New-TargetJson web.direct Direct)|Out-Null
    $direct=& $resolver -ProjectPath $directProject -TargetId web.direct -LogicalName Direct -Domain example.test -Page /upload -ExpectedRole button -ReuseValidationStatus PASS -ReuseValidationMethod fixture -ReuseMatchCount 1 -ReuseActualRole button -Json|ConvertFrom-Json
    Assert-True ($direct.status -eq 'REUSED') 'Fresh live proof did not replace a missing prior environment fingerprint.'
    $forced=& $resolver -ProjectPath $directProject -TargetId web.direct -LogicalName Direct -Domain example.test -Page /upload -ForceRediscovery -ReuseValidationStatus PASS -ReuseMatchCount 1 -ReuseActualRole button -Json|ConvertFrom-Json
    Assert-True ($forced.status -ne 'REUSED') 'Live proof bypassed explicit rediscovery.'
    $mismatched=& $resolver -ProjectPath $directProject -TargetId web.direct -LogicalName Direct -Domain example.test -Page /upload -ExpectedTargetFingerprint ('0' * 64) -ReuseValidationStatus PASS -ReuseMatchCount 1 -ReuseActualRole button -Json|ConvertFrom-Json
    Assert-True ($mismatched.status -ne 'REUSED') 'Live proof bypassed target-definition mismatch.'

    $cacheProject=New-Project 'capability-cache' -Evidence 'Semantic DOM target. Validate target.'
    $coldCaps=& $capabilityScript -ProjectPath $cacheProject -Json|ConvertFrom-Json
    $warmCaps=& $capabilityScript -ProjectPath $cacheProject -Json|ConvertFrom-Json
    Assert-True ($coldCaps.cacheStatus -eq 'COMPUTED' -and $warmCaps.cacheStatus -eq 'REUSED') 'Unchanged capability analysis was not reused.'
    $evidenceFile=Join-Path $cacheProject '.local\docs\packages\UiPath.UIAutomation.Activities\features.md'
    $evidenceTime=(Get-Item $evidenceFile).LastWriteTimeUtc
    Write-Text $evidenceFile 'Semantic DOM unsupported. Validate target.'
    (Get-Item $evidenceFile).LastWriteTimeUtc=$evidenceTime
    $changedCaps=& $capabilityScript -ProjectPath $cacheProject -Json|ConvertFrom-Json
    Assert-True ($changedCaps.cacheStatus -eq 'COMPUTED' -and -not $changedCaps.semanticDom -and $changedCaps.evidenceFingerprint -ne $warmCaps.evidenceFingerprint) 'Documentation-content change reused stale capabilities.'
    New-Item -ItemType Directory -Path (Join-Path $cacheProject ObjectRepository)|Out-Null
    $orCaps=& $capabilityScript -ProjectPath $cacheProject -Json|ConvertFrom-Json
    Assert-True ($orCaps.cacheStatus -eq 'COMPUTED' -and $orCaps.objectRepository) 'Object Repository change reused stale capabilities.'
    Write-Text (Join-Path $cacheProject project.json) '{"dependencies":{}}'
    $removedCaps=& $capabilityScript -ProjectPath $cacheProject -Json|ConvertFrom-Json
    Assert-True ($removedCaps.cacheStatus -eq 'COMPUTED' -and -not $removedCaps.strictSelector) 'Dependency change reused stale capabilities.'

    $batchProject=New-Project 'screen-batch'
    $batchResolver=Join-Path $root 'scripts\Resolve-UiTargets.ps1'
    $requests=@(
        [ordered]@{targetId='web.first';logicalName='First';expectedRole='button';candidates=@((New-Candidate StrictSelector "<webctrl id='first' role='button' />"))},
        [ordered]@{targetId='web.second';logicalName='Second';expectedRole='button';candidates=@((New-Candidate StrictSelector "<webctrl id='second' role='button' />"))}
    )
    $batch=& $batchResolver -ProjectPath $batchProject -Domain example.test -Page /upload -TargetsJson (ConvertTo-Json -InputObject $requests -Depth 10 -Compress) -Json|ConvertFrom-Json
    Assert-True ($batch.status -eq 'PASS' -and $batch.targetsAccepted -eq 2 -and $batch.uiCaptureComplete -and $batch.results[1].capabilityCacheStatus -eq 'REUSED') 'Screen batch failed accepted-target coverage or capability reuse.'
    Assert-True ($batch.results[0].evidencePath -ne $batch.results[1].evidencePath -and (Test-Path (Join-Path $batchProject $batch.results[0].evidencePath)) -and (Test-Path (Join-Path $batchProject $batch.results[1].evidencePath)) -and (Test-Path (Join-Path $batchProject $batch.evidencePath))) 'Batch overwrote target evidence or omitted its summary.'
    $requests[1].targetId='web.unresolved'; $requests[1].logicalName='Unresolved'; $requests[1].candidates=@()
    $partial=& $batchResolver -ProjectPath $batchProject -Domain example.test -Page /upload -TargetsJson (ConvertTo-Json -InputObject $requests -Depth 10 -Compress) -Json|ConvertFrom-Json
    Assert-True ($partial.status -eq 'BLOCKED' -and -not $partial.uiCaptureComplete -and $partial.targetsAccepted -eq 1 -and $null -eq $partial.results[1].binding) 'Unresolved batch target bypassed the capture gate.'
    Assert-True (Test-Path (Join-Path $batchProject $batch.evidencePath)) 'Later batch overwrote prior summary evidence.'
    $invalidBatchFailed=$false
    try { & $batchResolver -ProjectPath $batchProject -TargetsJson '[{"targetId":"../escape","logicalName":"Invalid"}]'|Out-Null } catch { $invalidBatchFailed=$true }
    Assert-True $invalidBatchFailed 'Invalid batch target path was accepted.'
    $duplicateBatchFailed=$false
    try { & $batchResolver -ProjectPath $batchProject -TargetsJson '[{"targetId":"web.same","logicalName":"One"},{"targetId":"web.same","logicalName":"Two"}]'|Out-Null } catch { $duplicateBatchFailed=$true }
    Assert-True $duplicateBatchFailed 'Duplicate batch IDs were accepted.'

    $registryBytes=(Get-Item (Join-Path $reuseProject '.devkit\ui-targets\registry.json')).Length
    $evidenceBytes=(Get-Item (Join-Path $reuseProject '.ai\evidence\ui-target-resolution.json')).Length
    Write-Host ("[METRIC] Registry lookup: {0} ms" -f $reused.timings.registryLookupMs)
    Write-Host ("[METRIC] Validated reuse: {0} ms" -f $reused.timings.targetResolutionMs)
    Write-Host ("[METRIC] New target discovery: {0} ms" -f $newResult.timings.discoveryMs)
    Write-Host ("[METRIC] Target validation evidence: {0} ms" -f $newResult.timings.validationMs)
    Write-Host ("[METRIC] Registry write: {0} ms" -f $newResult.timings.registryWriteMs)
    Write-Host ("[METRIC] Registry/evidence bytes: {0}/{1}" -f $registryBytes,$evidenceBytes)
    Write-Host '[PASS] UI Target Registry, selector quality, reuse/fallback, native/web, and capability tests'
} finally { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
