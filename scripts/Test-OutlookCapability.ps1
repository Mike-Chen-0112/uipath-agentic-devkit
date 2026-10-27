[CmdletBinding()]
param(
    [string]$TargetBotPath = (Get-Location).Path,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$TargetBotPath = (Resolve-Path $TargetBotPath).Path
$localDirectory = Join-Path $TargetBotPath '.rpa-ai\local'
$resultPath = Join-Path $localDirectory 'outlook-capability.json'
$projectPath = Join-Path $TargetBotPath 'project.json'

function Get-OutlookPackageAvailable {
    if (-not (Test-Path $projectPath -PathType Leaf)) { return $false }
    try {
        $project = Get-Content $projectPath -Raw | ConvertFrom-Json
        $names = @($project.dependencies.PSObject.Properties.Name)
        return [bool]($names | Where-Object { $_ -match '(?i)^UiPath\.(Outlook|Mail|MicrosoftOffice365)\.Activities($|\.)' })
    } catch {
        return $false
    }
}

function Test-OutlookMailboxAccess {
    $application = $null
    $namespace = $null
    $inbox = $null
    try {
        $application = New-Object -ComObject Outlook.Application
        $namespace = $application.GetNamespace('MAPI')
        $inbox = $namespace.GetDefaultFolder(6)
        [void]$inbox.Name
        return $true
    } catch {
        return $false
    } finally {
        foreach ($comObject in @($inbox, $namespace, $application)) {
            if ($null -ne $comObject -and [System.Runtime.InteropServices.Marshal]::IsComObject($comObject)) {
                try { [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($comObject) } catch { }
            }
        }
    }
}

$packageAvailable = Get-OutlookPackageAvailable
$mailboxAccessible = if ($packageAvailable) { Test-OutlookMailboxAccess } else { $false }
$available = $packageAvailable -and $mailboxAccessible
$reason = if (-not $packageAvailable) {
    'No supported UiPath Outlook activity package is declared in project.json.'
} elseif (-not $mailboxAccessible) {
    'Outlook COM mailbox/default Inbox access was not available for this user and machine.'
} else {
    'UiPath Outlook activity package is declared and the default Inbox was accessed without changing mailbox state.'
}

$result = [ordered]@{
    schemaVersion = 1
    OUTLOOK_ACTIVITY_AVAILABLE = $available
    packageAvailable = $packageAvailable
    mailboxAccessible = $mailboxAccessible
    probe = 'Outlook COM MAPI default Inbox access'
    checkedAtUtc = [DateTime]::UtcNow.ToString('o')
    reason = $reason
}

New-Item -ItemType Directory -Force -Path $localDirectory | Out-Null
$jsonText = $result | ConvertTo-Json -Depth 4
[System.IO.File]::WriteAllText($resultPath, $jsonText + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))

if ($Json) {
    Write-Output $jsonText
} else {
    Write-Host "OUTLOOK_ACTIVITY_AVAILABLE = $($available.ToString().ToLowerInvariant())"
    Write-Host "Capability result: $resultPath"
    Write-Host $reason
}