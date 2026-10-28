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

# Ephemeral official Object Repository inventory, not capture or live target proof.
# Never write raw OR metadata to evidence/telemetry or infer a fixed vendor schema.
. (Join-Path $PSScriptRoot 'Resolve-DevKitTool.ps1')
$uip = Resolve-DevKitTool -Name uip -TargetBotPath $TargetBotPath -Required
$previousPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $output = @(& $uip rpa get-object-repository --project-dir $TargetBotPath --timeout $TimeoutSeconds --output json 2>&1)
    $exitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $previousPreference
}
if ($exitCode -ne 0) {
    throw "OFFICIAL_OBJECT_REPOSITORY_UNAVAILABLE: CLI exit $exitCode; verify installed command help and project context."
}

$raw = ($output | Out-String).Trim()
if (-not $raw -or $raw -notmatch '^\s*[\{\[]') { throw 'OFFICIAL_OBJECT_REPOSITORY_INVALID_JSON' }
try { $repository = $raw | ConvertFrom-Json -ErrorAction Stop }
catch { throw 'OFFICIAL_OBJECT_REPOSITORY_INVALID_JSON' }
if ($null -eq $repository) { throw 'OFFICIAL_OBJECT_REPOSITORY_EMPTY_RESULT' }
if ($repository -is [pscustomobject] -and $repository.PSObject.Properties.Name -contains 'success' -and $repository.success -eq $false) {
    throw 'OFFICIAL_OBJECT_REPOSITORY_ERROR_RESULT'
}
$result = [ordered]@{
    schemaVersion = 1
    status = 'INVENTORY_UNVERIFIED'
    source = 'uip rpa get-object-repository'
    projectPath = $TargetBotPath
    includesReferencedLibraries = $false
    liveProof = 'NOT_VERIFIED'
    captureCompletionAuthority = $false
    repository = $repository
}
if ($Json) { $result | ConvertTo-Json -Depth 64 }
else { Write-Host '[INFO] Official Object Repository inventory obtained; targets still require live validation.' }
