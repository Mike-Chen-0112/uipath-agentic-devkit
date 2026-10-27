[CmdletBinding()]
param([string]$ProjectPath=(Get-Location).Path,[string]$StatePath,[string]$LedgerPath,[string]$NowUtc,[double]$ToleranceMilliseconds=5,[switch]$Json)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'DeveloperTelemetry.psm1') -Force
$result=Test-DeveloperTimingConsistencyData -ProjectPath $ProjectPath -StatePath $StatePath -LedgerPath $LedgerPath -NowUtc $NowUtc -ToleranceMilliseconds $ToleranceMilliseconds
if($Json){$result|ConvertTo-Json -Depth 12}else{$result}
if($result.status -eq 'FAIL' -and -not $Json){throw "Execution timing consistency failed: $($result.failures -join '; ')"}
