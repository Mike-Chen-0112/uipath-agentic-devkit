[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][AllowEmptyString()][string]$InputText,
    [string]$Workflow='',
    [switch]$ResultOnly,
    [switch]$Json
)
$ErrorActionPreference='Stop'
$items=New-Object Collections.Generic.List[object]
$shapeErrors=New-Object Collections.Generic.List[string]
$script:recognized=$false

function Get-PropertyValue {
    param($Object,[string[]]$Names)
    if($null -eq $Object){return $null}
    foreach($name in $Names){
        $property=$Object.PSObject.Properties | Where-Object Name -ieq $name | Select-Object -First 1
        if($property){return $property.Value}
    }
    return $null
}
function Add-Diagnostic {
    param([string]$Severity,[string]$Message,$Object)
    if(-not $Message){$Message='Native diagnostic did not provide a message.'}
    [void]$items.Add([ordered]@{
        workflow=if(Get-PropertyValue $Object @('workflow','file','filePath','path')){[string](Get-PropertyValue $Object @('workflow','file','filePath','path'))}else{$Workflow}
        severity=$Severity.ToUpperInvariant()
        error=$Message
        activity=Get-PropertyValue $Object @('activity','activityName','displayName')
        property=Get-PropertyValue $Object @('property','propertyName')
        code=Get-PropertyValue $Object @('code','ruleId','id')
    })
}
function Visit-Node {
    param($Node,[string]$DefaultSeverity='')
    if($null -eq $Node){return}
    if($Node -is [string]){
        if($DefaultSeverity){Add-Diagnostic $DefaultSeverity ([string]$Node) $null;$script:recognized=$true}
        else{[void]$shapeErrors.Add('Unexpected text in a diagnostics collection.')}
        return
    }
    if($Node -is [array]){
        foreach($child in $Node){Visit-Node $child $DefaultSeverity}
        return
    }
    if($Node -isnot [pscustomobject]){
        [void]$shapeErrors.Add('Unexpected scalar in a diagnostic result.')
        return
    }
    $severity=Get-PropertyValue $Node @('severity','level','diagnosticSeverity')
    $message=Get-PropertyValue $Node @('message','error','description','errorMessage')
    if($severity -or $DefaultSeverity){
        $selectedSeverity=if($DefaultSeverity){$DefaultSeverity}else{[string]$severity}
        if($selectedSeverity -notmatch '^(?i:error|warning|warn|info|information|verbose|trace)$'){
            [void]$shapeErrors.Add('Unknown diagnostic severity.')
        }else{
            if($selectedSeverity -eq 'WARN'){$selectedSeverity='WARNING'}
            Add-Diagnostic $selectedSeverity ([string]$message) $Node
            $script:recognized=$true
        }
    }
    foreach($property in $Node.PSObject.Properties){
        $name=$property.Name
        $value=$property.Value
        if($name -in @('success','isValid','isSuccess','hasErrors')){
            if($value -isnot [bool]){[void]$shapeErrors.Add("Expected boolean $name.");continue}
            $script:recognized=$true
            if(($name -eq 'hasErrors' -and $value) -or ($name -ne 'hasErrors' -and -not $value)){
                Add-Diagnostic 'ERROR' "Native result reports $name=$value" $Node
            }
        }elseif($name -in @('result','status')){
            if($value -isnot [string] -or $value -notmatch '^(?i:success|succeeded|pass|passed|valid|error|failed|failure|invalid)$'){
                [void]$shapeErrors.Add("Unknown native $name.")
            }else{
                $script:recognized=$true
                if($value -match '^(?i:error|failed|failure|invalid)$'){Add-Diagnostic 'ERROR' "Native result reports $name=$value" $Node}
            }
        }elseif($name -eq 'errorCount'){
            if($value -isnot [ValueType] -or [string]$value -notmatch '^\d+$'){
                [void]$shapeErrors.Add('Expected a nonnegative integer errorCount.')
            }else{
                $script:recognized=$true
                if([decimal]$value -gt 0){Add-Diagnostic 'ERROR' "Native result reports errorCount=$value" $Node}
            }
        }elseif(-not $ResultOnly -and $name -in @('errors','validationErrors','diagnostics','warnings','ruleViolations')){
            if($null -eq $value){$script:recognized=$true;continue}
            if($value -isnot [array]){
                [void]$shapeErrors.Add("Expected an array for $name.")
                continue
            }
            $script:recognized=$true
            $default=if($name -in @('errors','validationErrors')){'ERROR'}elseif($name -eq 'warnings'){'WARNING'}else{''}
            foreach($entry in $value){
                if($null -eq $entry){[void]$shapeErrors.Add("Null diagnostic entry in $name.");continue}
                if(-not $default -and $entry -is [pscustomobject] -and -not (Get-PropertyValue $entry @('severity','level','diagnosticSeverity'))){
                    [void]$shapeErrors.Add("Diagnostic in $name has no severity.")
                }
                Visit-Node $entry $default
            }
        }elseif($name -eq 'runResult'){
            $runtime=$value
            if($runtime -is [string]){
                try{$runtime=ConvertFrom-Json -InputObject $runtime -ErrorAction Stop}
                catch{[void]$shapeErrors.Add('Malformed serialized runResult JSON.');continue}
            }
            if($null -eq $runtime -or $runtime -is [array] -or $runtime -isnot [pscustomobject] -or (Get-PropertyValue $runtime @('hasErrors')) -isnot [bool]){
                [void]$shapeErrors.Add('Expected runResult object with boolean HasErrors.')
                continue
            }
            $debugState=Get-PropertyValue $runtime @('debugState')
            if($null -ne $debugState -and $debugState -ne 'Completed'){
                [void]$shapeErrors.Add('Runtime response does not represent completed execution.')
            }
            Visit-Node $runtime
        }elseif($name -in @('data','buildResult','validationResult','analyzerResult')){
            if($null -ne $value){Visit-Node $value}
        }elseif($name -eq 'errorMessage' -and $value -and -not $severity -and -not $DefaultSeverity){
            if($value -isnot [string]){[void]$shapeErrors.Add('Expected text errorMessage.')}
            elseif(-not $ResultOnly){Add-Diagnostic 'ERROR' ([string]$value) $Node;$script:recognized=$true}
        }
    }
}

$jsonRead=$false
$trimmed=$InputText.Trim()
if($trimmed){
    try{
        $value=ConvertFrom-Json -InputObject $trimmed -ErrorAction Stop
        $jsonRead=$true
    }catch{
        foreach($match in [regex]::Matches($InputText,'(?m)^[ \t]*(?=[\{\[])')){
            try{$value=ConvertFrom-Json -InputObject $InputText.Substring($match.Index).Trim() -ErrorAction Stop;$jsonRead=$true;break}catch{continue}
        }
    }
}
if($jsonRead){
    if($trimmed -eq '[]'){$script:recognized=$true}
    Visit-Node $value
}
if(-not $ResultOnly){
    foreach($line in @($InputText -split "`r?`n")){
        $text=$line.Trim()
        if($text -match '^(?i:no diagnostics found\.?|no errors found\.?|0 errors\.?)$'){$script:recognized=$true;continue}
        if($text -match '^(?i:(?:\[[^\]]+\]\s*)?)(?<severity>error|warning|info)\s*[:\]\-]\s*(?<message>.+)$'){
            Add-Diagnostic $Matches.severity $Matches.message $null
            $script:recognized=$true
        }
    }
}
$dedup=@($items | Group-Object {($_.workflow,$_.severity,$_.error,$_.activity,$_.property -join '|')} | ForEach-Object {$_.Group[0]})
$errors=@($dedup | Where-Object severity -eq 'ERROR')
$fingerprintText=@($errors | ForEach-Object {"$($_.workflow)|$($_.severity)|$($_.error)|$($_.activity)|$($_.property)"} | Sort-Object) -join "`n"
$sha=[Security.Cryptography.SHA256]::Create()
try{$fingerprint=if($fingerprintText){([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($fingerprintText))) -replace '-','').ToLowerInvariant()}else{$null}}finally{$sha.Dispose()}
$result=[ordered]@{
    schemaVersion=2;workflow=$Workflow;diagnostics=$dedup;diagnosticCount=$dedup.Count
    errorCount=$errors.Count;diagnosticFingerprint=$fingerprint
    contentParsed=$script:recognized -and $shapeErrors.Count -eq 0
    parseErrors=@($shapeErrors)
}
if($Json){$result | ConvertTo-Json -Depth 10}else{[pscustomobject]$result}
