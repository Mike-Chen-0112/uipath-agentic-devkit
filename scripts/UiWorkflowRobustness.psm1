# Static runtime-robustness scan for UI activities in XAML (classic ui:* and modern uix:N* activities).
$script:UiActionNames = @(
    'Click','DoubleClick','ClickImage','ClickText','Hover','HoverImage','HoverText','TypeInto','TypeSecureText','SetText',
    'SelectItem','SelectMultipleItems','Check','SendHotkey',
    'NClick','NTypeInto','NSelectItem','NCheck','NHover','NKeyboardShortcuts','NSetText','NDragAndDrop'
)
$script:UiVerificationNames = @(
    'NCheckState','ElementExists','WaitUiElementAppear','WaitUiElementVanish','OnUiElementAppear','OnUiElementVanish',
    'WaitImageAppear','WaitImageVanish','RetryScope','NWaitScreenReady'
)

function Get-UiNodeLabel {
    param([System.Xml.XmlNode]$Node)
    $display = @($Node.Attributes | Where-Object { $_.LocalName -eq 'DisplayName' } | Select-Object -First 1)
    if ($display.Count -and $display[0].Value) { return "$($Node.LocalName) '$($display[0].Value)'" }
    return $Node.LocalName
}

function Get-UiSelectorStrings {
    param([System.Xml.XmlNode]$Node)
    $values = New-Object System.Collections.Generic.List[string]
    foreach ($element in @($Node) + @($Node.SelectNodes('.//*'))) {
        foreach ($attribute in @($element.Attributes)) {
            if ($attribute.LocalName -match '(?i)selector' -and $attribute.Value -and $attribute.Value -notmatch '^\s*\{x:Null\}\s*$') { $values.Add([string]$attribute.Value) }
        }
        if ($element.LocalName -match '(?i)\.(Full|Fuzzy|Scope)?Selector(Argument)?$' -and $element.InnerText) { $values.Add([string]$element.InnerText) }
    }
    return $values.ToArray()
}

function Get-UiAttributeValue {
    param([System.Xml.XmlNode]$Node, [string]$Name)
    $attribute = @($Node.Attributes | Where-Object { $_.LocalName -eq $Name } | Select-Object -First 1)
    if ($attribute.Count) { return [string]$attribute[0].Value }
    return $null
}

function Get-UiWorkflowRobustnessFindings {
    param([System.Xml.XmlDocument]$Document)
    $findings = New-Object System.Collections.Generic.List[object]
    $add = { param($Severity,$Code,$Message) [void]$findings.Add([ordered]@{ severity = $Severity; code = $Code; message = $Message }) }
    $all = @($Document.SelectNodes('//*'))
    $actions = @($all | Where-Object { $script:UiActionNames -contains $_.LocalName })
    if ($actions.Count -eq 0) { return $findings.ToArray() }

    foreach ($action in $actions) {
        $label = Get-UiNodeLabel $action
        $continue = Get-UiAttributeValue $action 'ContinueOnError'
        if ($continue -and $continue -match '(?i)^\s*\[?\s*true\s*\]?\s*$') {
            & $add 'ERROR' 'UI_CONTINUE_ON_ERROR' "$label sets ContinueOnError=True; a failed UI action would be silently ignored."
        }
        $selectors = @(Get-UiSelectorStrings $action)
        $hasReference = $action.LocalName -match 'Text$' -or @(@($action) + @($action.SelectNodes('.//*')) | Where-Object {
            @($_.Attributes | Where-Object { $_.LocalName -match '^(Reference|ElementId|ContentHash|Image|ImageBase64|Element|InUiElement)$' -and $_.Value -and $_.Value -notmatch '^\s*\{x:Null\}\s*$' }).Count -gt 0 -or
            $_.LocalName -match '(?i)\.(Element|InUiElement|Image)$'
        }).Count -gt 0
        $hasOffset = @(@($action) + @($action.SelectNodes('.//*')) | Where-Object {
            $_.LocalName -match '(?i)^(CursorPosition|ClickOffset|PointOffset)' -or
            @($_.Attributes | Where-Object { $_.LocalName -match '^(OffsetX|OffsetY|PositionX|PositionY|Position)$' -and $_.Value }).Count -gt 0
        }).Count -gt 0
        if ($hasOffset -and $selectors.Count -eq 0 -and -not $hasReference) {
            & $add 'ERROR' 'UI_COORDINATE_ONLY' "$label targets screen coordinates without a selector, Object Repository reference, or image."
        }
        foreach ($selector in $selectors) {
            if ($selector -match '(?i)\b(pid|hwnd|processid|sessionid)\s*=\s*[''"]?\d+' -or $selector -match '(?i)\b(token|session|sid)\s*=\s*[''"][A-Za-z0-9_\-]{16,}') {
                & $add 'ERROR' 'UI_VOLATILE_SELECTOR' "$label selector contains a process id, window handle, or session token."
            }
            if ($selector -match '(?i)\bidx\s*=\s*[''"]?(?!1[''"\s/>]|\*)\d+') {
                & $add 'WARN' 'UI_SELECTOR_IDX' "$label selector depends on idx; prefer a stable attribute or anchor."
            }
            if ($selector -match '(?i)\btitle\s*=\s*[''"][^''"*]*(\d{3,}|\d{1,2}[/.-]\d{1,2}[/.-]\d{2,4})[^''"*]*[''"]') {
                & $add 'WARN' 'UI_DYNAMIC_TITLE' "$label window/tab title contains numbers or dates; use a wildcard or attach by URL."
            }
        }
        if ($action.LocalName -eq 'TypeInto' -and (Get-UiAttributeValue $action 'EmptyField') -notmatch '(?i)true') {
            & $add 'WARN' 'UI_TYPE_WITHOUT_CLEAR' "$label does not clear the field before typing."
        }
        if ($action.LocalName -eq 'NTypeInto' -and (Get-UiAttributeValue $action 'EmptyFieldMode') -match '(?i)^None$') {
            & $add 'WARN' 'UI_TYPE_WITHOUT_CLEAR' "$label does not clear the field before typing."
        }
        $timeoutMs = Get-UiAttributeValue $action 'TimeoutMS'
        $timeoutSeconds = Get-UiAttributeValue $action 'Timeout'
        $milliseconds = $null
        if ($timeoutMs -match '^\s*\d+\s*$') { $milliseconds = [double]$timeoutMs }
        elseif ($timeoutSeconds -match '^\s*\d+(\.\d+)?\s*$') { $milliseconds = [double]$timeoutSeconds * 1000 }
        if ($null -ne $milliseconds -and ($milliseconds -lt 3000 -or $milliseconds -gt 300000)) {
            & $add 'WARN' 'UI_TIMEOUT_EXTREME' "$label timeout is $([Math]::Round($milliseconds / 1000, 1)) s; use 3-300 s, preferably from Config."
        }
    }

    foreach ($delay in @($all | Where-Object { $_.LocalName -eq 'Delay' })) {
        & $add 'WARN' 'UI_FIXED_DELAY' "$(Get-UiNodeLabel $delay) waits a fixed time in a UI workflow; wait for the element or use Check App State."
    }
    $hasVerification = @($all | Where-Object {
        $script:UiVerificationNames -contains $_.LocalName -or $_.LocalName -match '(?i)Verify' -or
        @($_.Attributes | Where-Object { $_.LocalName -match '(?i)^Verify' -and $_.Value -and $_.Value -notmatch '(?i)^(false|\{x:Null\}|None)$' }).Count -gt 0
    }).Count -gt 0
    if (-not $hasVerification) {
        & $add 'WARN' 'UI_NO_STATE_VERIFICATION' 'UI actions are never verified; add Check App State, an element wait, Verify execution, or a Retry Scope with a condition after submit/navigation steps.'
    }
    return $findings.ToArray()
}

Export-ModuleMember -Function Get-UiWorkflowRobustnessFindings
