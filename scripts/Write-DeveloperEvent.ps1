[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('Start','End','Instant')][string]$Action,
    [string]$ProjectPath = (Get-Location).Path,
    [string]$LedgerPath,
    [ValidateSet('HOST_MODEL_GAP','SCAFFOLDING','PACKAGE','UIA','UI_TARGET','OBJECT_REPOSITORY','SOURCE_READ','SOURCE_EDIT','SOURCE_REPAIR','MAPPER','GRAPHIFY','VALIDATION','EVIDENCE','STATE','FINALIZATION','USER_WAIT','EXTERNAL_INTERRUPTION','UNKNOWN')][string]$Category = 'UNKNOWN',
    [string]$Subcategory = '',
    [string]$Operation = '',
    [string]$EventId = '',
    [string]$ParentEventId = '',
    [ValidateSet('PASS','FAIL','BLOCKED','TIMEOUT','SKIPPED','UNAVAILABLE')][string]$Status = 'PASS',
    [string]$CommandType = 'IN_PROCESS',
    [Nullable[int]]$ProcessId,
    [Nullable[int]]$ExitCode,
    [switch]$TimedOut,
    [string]$ArtifactsJson = '[]',
    [string]$EditCycleId = '',
    [string]$Reason = '',
    [Nullable[int64]]$BytesBefore,
    [Nullable[int64]]$BytesAfter,
    [string]$HashBefore = '',
    [string]$HashAfter = '',
    [string]$NowUtc,
    [switch]$Json
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'DeveloperTelemetry.psm1') -Force
try { $artifacts=@($ArtifactsJson|ConvertFrom-Json) } catch { throw "ArtifactsJson is invalid: $($_.Exception.Message)" }
if ($Action -in @('Start','Instant') -and -not $Operation) { throw 'Operation is required.' }
if ($Action -eq 'End' -and -not $EventId) { throw 'EventId is required for End.' }
$result = switch ($Action) {
    'Start' { Start-DeveloperEvent -ProjectPath $ProjectPath -LedgerPath $LedgerPath -Category $Category -Subcategory $Subcategory -Operation $Operation -ParentEventId $ParentEventId -CommandType $CommandType -ProcessId $ProcessId -Artifacts $artifacts -EditCycleId $EditCycleId -Reason $Reason -BytesBefore $BytesBefore -BytesAfter $BytesAfter -HashBefore $HashBefore -HashAfter $HashAfter -NowUtc $NowUtc }
    'End' { Stop-DeveloperEvent -ProjectPath $ProjectPath -LedgerPath $LedgerPath -EventId $EventId -Status $Status -ExitCode $ExitCode -TimedOut:$TimedOut -ProcessId $ProcessId -Artifacts $artifacts -EditCycleId $EditCycleId -Reason $Reason -BytesBefore $BytesBefore -BytesAfter $BytesAfter -HashBefore $HashBefore -HashAfter $HashAfter -NowUtc $NowUtc }
    'Instant' { Add-DeveloperInstantEvent -ProjectPath $ProjectPath -LedgerPath $LedgerPath -Category $Category -Subcategory $Subcategory -Operation $Operation -ParentEventId $ParentEventId -Status $Status -Artifacts $artifacts -EditCycleId $EditCycleId -Reason $Reason -BytesBefore $BytesBefore -BytesAfter $BytesAfter -HashBefore $HashBefore -HashAfter $HashAfter -NowUtc $NowUtc }
}
if ($Json) { $result|ConvertTo-Json -Depth 10 } else { $result }
