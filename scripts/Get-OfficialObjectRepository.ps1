[CmdletBinding()]
param(
    [string]$TargetBotPath = (Get-Location).Path,
    [switch]$ApprovedDevelopment,
    [switch]$NonSensitiveDevelopmentData,
    [ValidateRange(1,300)][int]$TimeoutSeconds = 90,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$TargetBotPath = (Resolve-Path -LiteralPath $TargetBotPath).Path
if (-not (Test-Path -LiteralPath (Join-Path $TargetBotPath 'project.json') -PathType Leaf)) {
    throw 'BUSINESS_PROJECT_REQUIRED: an existing UiPath project.json is required.'
}
if (-not $ApprovedDevelopment -or -not $NonSensitiveDevelopmentData) {
    throw 'APPROVED_NON_SENSITIVE_DEVELOPMENT_CONTEXT_REQUIRED'
}

. (Join-Path $PSScriptRoot 'Resolve-DevKitTool.ps1')
Import-Module (Join-Path $PSScriptRoot 'UiPathCliContract.psm1') -Force
$uip = Resolve-DevKitTool -Name uip -TargetBotPath $TargetBotPath -Required
$commands = @()
$repository = $null
foreach ($phase in @('capability','lookup')) {
    $tokens = if ($phase -eq 'capability') { @('rpa','get-object-repository','--help') }
        else { @('rpa','get-object-repository','--project-dir',$TargetBotPath,'--timeout',"$TimeoutSeconds",'--output','json') }
    $started = [DateTime]::UtcNow
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $uip @tokens 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    $commands += [ordered]@{
        category = 'OBJECT_REPOSITORY'; subcategory = $phase; file = $uip
        exitCode = $exitCode; sideEffecting = $false
        durationSeconds = [Math]::Round(([DateTime]::UtcNow - $started).TotalSeconds, 3)
    }
    $raw = ($output | Out-String).Trim()
    $hasError = @($output | Where-Object { $_ -is [Management.Automation.ErrorRecord] }).Count -gt 0
    if ($exitCode -ne 0 -or $hasError) {
        throw "OFFICIAL_OBJECT_REPOSITORY_UNAVAILABLE: $phase failed; verify installed command help and project context."
    }
    if ($phase -eq 'capability') {
        $help = Read-VerifiedCliHelp -Response @{ status = 'PASS'; error = ''; output = $raw } -CommandPath 'uip rpa get-object-repository'
        Assert-VerifiedCliOptions -Help $help -Option @('--project-dir','--timeout','--output')
        continue
    }
    if (-not $raw -or $raw -notmatch '^\s*[\{\[]') { throw 'OFFICIAL_OBJECT_REPOSITORY_INVALID_JSON' }
    try { $repository = $raw | ConvertFrom-Json -ErrorAction Stop }
    catch { throw 'OFFICIAL_OBJECT_REPOSITORY_INVALID_JSON' }
    if ($repository -isnot [pscustomobject] -or $repository.Result -cne 'Success' -or
        $null -eq $repository.Data -or $repository.Data -isnot [pscustomobject]) {
        throw 'OFFICIAL_OBJECT_REPOSITORY_ERROR_RESULT'
    }
    $pending = New-Object System.Collections.Queue
    $pending.Enqueue($repository)
    while ($pending.Count) {
        $entry = $pending.Dequeue()
        if ($entry -is [pscustomobject]) {
            foreach ($property in $entry.PSObject.Properties) {
                $value = $property.Value
                if (($property.Name -in @('error','errors') -and $value) -or
                    ($property.Name -eq 'success' -and $value -eq $false) -or
                    ($property.Name -in @('result','status') -and $value -is [string] -and $value -match '^(error|failed|failure)$')) {
                    throw 'OFFICIAL_OBJECT_REPOSITORY_ERROR_RESULT'
                }
                if ($null -ne $value) { $pending.Enqueue($value) }
            }
        } elseif ($entry -is [array]) {
            foreach ($item in $entry) { if ($null -ne $item) { $pending.Enqueue($item) } }
        }
    }
}
$result = [ordered]@{
    schemaVersion = 1
    status = 'INVENTORY_UNVERIFIED'
    source = 'uip rpa get-object-repository'
    projectPath = $TargetBotPath
    tool = $uip
    commands = $commands
    includesReferencedLibraries = $false
    liveProof = 'NOT_VERIFIED'
    captureCompletionAuthority = $false
    repository = $repository
}
if ($Json) { $result | ConvertTo-Json -Depth 64 }
else { [pscustomobject]$result }