function Read-VerifiedCliHelp {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Response, [Parameter(Mandatory=$true)][string]$CommandPath)
    if ($Response.status -ne 'PASS' -or $Response.error -or $Response.timed_out -or
        ($null -ne $Response.exit_code -and $Response.exit_code -ne 0) -or
        -not $Response.output) { throw 'OFFICIAL_HELP_UNAVAILABLE' }
    $text = [regex]::Replace([string]$Response.output, '\x1b\[[0-?]*[ -/]*[@-~]', '')
    $options = @()
    $usage = ''
    if ($text.TrimStart() -match '^[\{\[]') {
        $envelope = $text | ConvertFrom-Json
        if ($envelope -isnot [pscustomobject] -or $envelope.Data -isnot [pscustomobject] -or
            $envelope.Result -cne 'Success' -or $envelope.Code -cne 'Help' -or $envelope.Error -or $envelope.Errors -or
            $envelope.Data.Usage -isnot [string] -or
            $envelope.Data.Command -cne ($CommandPath -split ' ')[-1]) { throw 'OFFICIAL_HELP_IDENTITY_MISMATCH' }
        $usage = [string]$envelope.Data.Usage
        foreach ($entry in @($envelope.Data.Options) + @($envelope.Data.GlobalOptions)) {
            if ($entry.Flags -notmatch '^(?<flags>--?[A-Za-z][A-Za-z0-9-]*(?:,\s*--?[A-Za-z][A-Za-z0-9-]*)*)(?:\s+(?:<[^<>]+>|\[[^\[\]]+\]))?$') { throw 'OFFICIAL_HELP_OPTIONS_MALFORMED' }
            $options += @([regex]::Matches($Matches.flags, '--?[A-Za-z][A-Za-z0-9-]*') | ForEach-Object Value)
        }
    } else {
        foreach ($encoding in @([Console]::OutputEncoding, [Text.Encoding]::Default, [Text.Encoding]::GetEncoding(1252), [Text.Encoding]::GetEncoding(437))) {
            foreach ($code in @(0x250c,0x2500,0x2510,0x2502,0x2514,0x2518)) {
                $border = $encoding.GetString([Text.Encoding]::UTF8.GetBytes([string][char]$code))
                if ($border -ne '?') { $text = $text.Replace($border, '') }
            }
        }
        $text = $text -replace '[\u2500-\u257f]', ''
        if ($text -match '(?im)^\s*(?:error\b|fatal\b|exception\b|\[error\])') { throw 'OFFICIAL_HELP_ERROR' }
        $usageMatch = [regex]::Match($text, '(?ms)^\s*Usage:?\s*(?<usage>.*?)(?=^\s*(?:Options|Global Options|Arguments|Commands|Subcommands|Examples):?\s*$|\z)')
        if ($usageMatch.Success) { $usage = ($usageMatch.Groups['usage'].Value -replace '\s+', ' ').Trim() }
        $section = ''
        foreach ($line in ($text -split '\r?\n')) {
            if ($line.Trim() -match '^(Usage|Options|Global Options|Arguments|Commands|Subcommands|Examples):?$') { $section = $Matches[1]; continue }
            if ($section -in @('Options','Global Options') -and $line -match '^\s*(?<flags>--?[A-Za-z][A-Za-z0-9-]*(?:,\s*--?[A-Za-z][A-Za-z0-9-]*)*)(?=\s|$)') {
                $options += @([regex]::Matches($Matches.flags, '--?[A-Za-z][A-Za-z0-9-]*') | ForEach-Object Value)
            }
        }
    }
    $pattern = '^' + [regex]::Escape($CommandPath) + '(?:\s+(?:--?[A-Za-z][A-Za-z0-9-]*|<[^<>]+>|\[[^\[\]]+\]|\{[^{}]+\}|\.\.\.))*\s*$'
    if ($usage -cnotmatch $pattern -or $options -cnotcontains '--help') { throw 'OFFICIAL_HELP_IDENTITY_MISMATCH' }
    return [pscustomobject]@{ schemaVersion=1; commandPath=$CommandPath; usage=$usage; options=@($options | Select-Object -Unique) }
}

function Assert-VerifiedCliOptions {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Help, [string[]]$Option = @())
    foreach ($flag in $Option) {
        if ($Help.options -cnotcontains $flag) { throw "OFFICIAL_OPTION_UNAVAILABLE: $($Help.commandPath) $flag" }
    }
}

Export-ModuleMember -Function Read-VerifiedCliHelp,Assert-VerifiedCliOptions