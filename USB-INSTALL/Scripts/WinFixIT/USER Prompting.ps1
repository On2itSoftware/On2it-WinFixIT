<# USER Prompting.ps1
   ==================
This Script is dot-sourced into all the Scripts that Prompt the User for a choice.

It contains the following functions:
    Prompt-ForUserChoice 
    Reposition-CursorToRow 
    Resolve-ColourTokens 
    Clear-Screen
    Accept-UserInput
    Set-Cursor

It also:
    Initialises Prompt Tracking Variables
    Defines Colour Codes used throughout system
                
   Designed by: Brian McGuigan (On2it Software Ltd)
       Code by: Copilot
       Version: 4
          Date: 26-Sep-25
#>

# =========================================================================================
function Prompt-ForUserChoice {
    param (
        [Parameter(Mandatory = $true)][string[]]$PromptRows,    # MULTIPLE ROWS - WYSIWYG
        [Int32]$PromptStartRow,                                 # Optional - forces UI to use this Row for prompting          
        [string[]]$ValidChoices,                                # That the User may respond with
        [switch]$SuppressChoices = $false,                      # Do NOT display $ValidChoices in Prompt   
        [switch]$OverwritePreviousPrompt = $false,              # Display Prompt on same Row as previous Prompt
        [string]$ReturnKey_Pressed = "",                        # Text returned if User just presses <Return> Key
        [string]$MessageToBeDisplayedBelowPrompt = ""           # Optional Message to display below Prompt
    )
#
# Purpose:
#   Prompt the user for a choice until they return a valid choice.
#   Supports overwriting the previous prompt or starting on a new line.
#
# Debugging:
#   All debug output is written to a log file to avoid disturbing UI layout.
#   Log entries are timestamped and show cursor positions, line counts, and calculated targets.
#
# Anchor Guard:
#   Ensures $script:PreviousPromptRow is set exactly once per prompt cycle.
#   Prevents silent overwrites that cause cursor drift.
#
# Spacer Row:
#   Always clears the error row and advances one row to leave a visible blank line
#   between prompts, even if no error was shown.

$localDEBUG_Mode = $false

# Ensure $ValidChoices ALWAYS exists and is ALWAYS an array
# ---------------------------------------------------------
# If the variable does not exist at all (informational menu), create it
if (-not (Get-Variable -Name ValidChoices -Scope Local -ErrorAction SilentlyContinue)) {
    $ValidChoices = @()
}
# If the variable exists but is $null, fix it
if ($null -eq $ValidChoices) {
    $ValidChoices = @()
}
# Normalise into an array (PowerShell binding quirk fix)
$ValidChoices = @($ValidChoices)

# --- SPECIAL CASE: ANY TEXT ALLOWED ---
$allowANYinput = $false
if ($ValidChoices.Count -eq 1 -and `
    $ValidChoices[0].Trim().ToUpper() -eq 'ANY') {
    $allowANYinput = $true
}
# Normalise each line: expand variables, strip CR, trim trailing spaces
$PromptRows = $PromptRows | ForEach-Object {
    $line = $_
    foreach ($var in Get-Variable) {
        $line = $line -replace ('\$' + [regex]::Escape($var.Name)), [string]$var.Value
        $line = $line -replace ('\$\{' + [regex]::Escape($var.Name) + '\}'), [string]$var.Value
    }
    $line -replace "`r", '' -replace '\s+$',''
}

# Split any embedded newlines (multi-line prompt strings from Get-ScenarioFromUSB) into separate rows
$PromptRows = $PromptRows | ForEach-Object { $_ -split "`n" }

# Ensure blank lines consume a row
$PromptRows = $PromptRows | ForEach-Object {
    if ($_ -match '^\s*$') { ' ' } else { $_ }
}

if ($PromptRows.Length -eq 0) {
    $PromptRows = @(' ')
}

    if ($PromptRows.Length -eq 0) {
        $PromptRows = @(' ')
    }
    # Buffer width
    $HostUIbufferWidth = $Host.UI.RawUI.BufferSize.Width

    # Count physical rows consumed by the prompt
    $totalRowsInCurrentPrompt = 0
    foreach ($line in $PromptRows) {
        $visible = ($line -replace $ANSI, '')
        $len     = [Math]::Max(1, $visible.Length)
        $wraps   = [Math]::Floor(($len - 1) / $HostUIbufferWidth)
        $totalRowsInCurrentPrompt += 1 + $wraps
    }
    # Normalize valid choices for comparison
    $ValidChoices_InUpperCase = $ValidChoices | ForEach-Object { $_.ToString().ToUpper() }

    # Append choice hint to last line.  An empty '' in $ValidChoices means "just
    # pressing Return is also valid" - show that as the Return-key label rather
    # than letting it join into a bare trailing "/" (e.g. "FULL/BYPASS/").
    if (-not $SuppressChoices) {
        $typedChoices = @($ValidChoices_InUpperCase | Where-Object { $_ -ne '' })
        if ($ValidChoices -contains '') {
            # "just press Return" is also valid - list the typed choices with commas
            # and spell the Return option out, rather than a bare trailing "/".
            $returnLabel   = if ($ReturnKey_Pressed) { $ReturnKey_Pressed } else { '<Return>' }
            $InlineChoices = ($typedChoices -join ', ')
            $InlineChoices = if ($InlineChoices) { "$InlineChoices or $returnLabel" } else { $returnLabel }
        }
        else {
            # Simple typed-only list stays tight, e.g. "Y/N"
            $InlineChoices = ($typedChoices -join '/')
        }
        $PromptRows[-1] = "$($PromptRows[-1]) ($InlineChoices)"
    }

    # Decide START and END Positions for Current Prompt
    # -------------------------------------------------
    if (-not $script:LastPromptRowStartPosition) { $script:LastPromptRowStartPosition = 0 }
    if (-not $script:CurrentRowPosition) { $script:CurrentRowPosition = 0 }
    
    # If you want to OVERWRITE Previous Prompt (and there was one).
    if ($OverwritePreviousPrompt -and $script:LastPromptRowStartPosition -gt 0) {
        # Use ANSI relative cursor movement to reach the start of the previous prompt.
        # This avoids any dependency on absolute buffer-row arithmetic.
        $rowsUp = $script:LastPromptRowCount - 1
        if ($rowsUp -gt 0) { Write-Host "$esc[$($rowsUp)A" -NoNewline }
        Write-Host "`r" -NoNewline  # column 0

        # Clear each row of the previous prompt using ESC[2K (clears entire line)
        for ($i = 0; $i -lt $script:LastPromptRowCount; $i++) {
            Write-Host $ClrLine -NoNewline
            if ($i -lt $script:LastPromptRowCount - 1) {
                Write-Host "`n`r" -NoNewline  # next row, column 0
            }
        }
        # Return to start of cleared area
        if ($script:LastPromptRowCount -gt 1) {
            Write-Host "$esc[$($script:LastPromptRowCount - 1)A" -NoNewline
        }
        Write-Host "`r" -NoNewline  # column 0 of first cleared row

        # Recalibrate ScreenStartBufferRow from the actual physical cursor position.
        # CursorTop here is the true buffer row for logical row LastPromptRowStartPosition.
        $script:ScreenStartBufferRow = [Console]::CursorTop - $script:LastPromptRowStartPosition

        $CurrentPromptRowStartPosition = $script:LastPromptRowStartPosition
        Reposition-CursorToRow $CurrentPromptRowStartPosition  # now a reliable no-op
    }
    else { # NOT OVERWRITING Previous Prompt 
        If ($script:LastPromptRowStartPosition -gt 0) { 
            # But there WAS a previous Prompt.  So, start TWO rows down to leave a BLANK ROW
            # it's +1 because we Incremented $script:CurrentRowPosition, at the nd of the Previous Prompt
            $CurrentPromptRowStartPosition = $script:CurrentRowPosition + 1  
        }
        else { # There WAS NO previous Prompt.  So, start ONE row down below Scenario header
            $CurrentPromptRowStartPosition = $script:CurrentRowPosition  
        } 
    }
    # Menus generated by Display-MenuFor will only ever have one Row AND will have a specified $PromptStartRow.
    # --------------------------------------------------------------------------------------------------------
    # So, if there is only one row in current Prompt AND a Prompt Start Row has been specified
    If(($totalRowsInCurrentPrompt -eq 1) -and ($PromptStartRow -gt 0)){
        # Use the specified $PromptStartRow
        $CurrentPromptRowStartPosition = $PromptStartRow
        $CurrentPromptRowEndPosition   = $PromptStartRow
    } else {
        # Use $totalRowsInCurrentPrompt to deduce $CurrentPromptRowEndPosition
        $CurrentPromptRowEndPosition = $CurrentPromptRowStartPosition + $totalRowsInCurrentPrompt - 1
    }

    # Ensure buffer is tall enough to accommodate the prompt
    # ---------------------------------------------------------
    $rawui = $Host.UI.RawUI
    $bufferSize = $rawui.BufferSize

    if ($CurrentPromptRowEndPosition -ge $bufferSize.Height) {
        $bufferSize.Height = $CurrentPromptRowEndPosition + 3
        $rawui.BufferSize = $bufferSize
    }

    $ValidChoice = $false
    $PreviousInvalidUserInput = ""

    # Repeat until User Inputs a Valid Choice
    # =======================================
    while (-not $ValidChoice) {

        # Ensure the first character of the Prompt prints exactly at the calculated start row, column-0
        Reposition-CursorToRow $CurrentPromptRowStartPosition

        # Initialise
        $rowsPrinted  = 0
        $colourPrefix = ''
        $colourActive = $false

        # DISPLAY ALL lines of PROMPT - except last
        # -----------------------------------------
        for ($i = 0; $i -lt ($PromptRows.Count - 1); $i++) {
            $line = $PromptRows[$i]

            # Build a dynamic list of all defined colour variables (anything whose value looks like an ANSI code)
            $colourVars = Get-Variable |
                Where-Object { $_.Value -is [string] -and $_.Value -match '^\x1B\[[0-9;]*m$' } |
                Select-Object -ExpandProperty Value

            foreach ($cv in $colourVars) {
                if ($line.StartsWith($cv)) {
                    $colourPrefix = $cv
                    $colourActive = $true
                    break
                }
            }
            $visibleLen = ($line -replace $ANSI, '').Length
            $wraps      = [Math]::Floor(($visibleLen - 1) / $HostUIbufferWidth)

            if ($visibleLen -gt $maxVisibleLen) {
                $segment1 = $line.Substring(0, $maxVisibleLen)
                $segment2 = $line.Substring($maxVisibleLen)

                if ($colourActive) {
                    Write-Host "$colourPrefix$segment1" -NoNewline
                    Write-Host "$colourPrefix$segment2"
                }
                else {
                    Write-Host $segment1 -NoNewline
                    Write-Host $segment2
                }
            }
            else {
                if ($colourActive) { Write-Host "$colourPrefix$line" }
                else { Write-Host $line }
            }

            $rowsPrinted += 1 + $wraps

            if ($line.Contains($Reset)) {
                $colourActive = $false
                $colourPrefix = ''
            }
        } # END of - DISPLAY ALL lines of PROMPT - except last
        # Ensure ALL Prompts end the same way
        $LastPromptRow = ($PromptRows[-1].TrimEnd()) + " : "

        if ($localDEBUG_Mode){
            Write-Host "[DEBUG] Prompt-ForUserChoice: Current Row Position = $script:CurrentRowPosition"
        }
        # When Printing Menus in Display-MenuFor we deliberately printed Blank Rows at the end WITHOUT counting them.
        # So, $script:CurrentRowPosition will be above the bottom of the Screen - to avoid scrolling 

        # Now call GET-UserInput using $script:CurrentRowPosition
        $UserInput = GET-UserInput `
            -Prompt $LastPromptRow `
            -PreviousInvalidInput $PreviousInvalidUserInput `
            -PromptRow $PromptRowEndPosition `
            -MessageToBeDisplayedBelowPrompt $MessageToBeDisplayedBelowPrompt `
            -TotalPromptRows $totalRowsInCurrentPrompt

        $UserInput_InUpperCase = $UserInput.Trim().ToUpper()

        # RETURN-TO LOGIC (correct position)
        # ----------------------------------
        if ($UserInput.Trim() -eq '' -and $ReturnKey_Pressed) {
            # Carry forward $script:Variables to next call of Function - same bookkeeping
            # as the normal exit path below, otherwise the next Prompt is positioned from
            # stale row-tracking state and renders too high on screen.
            $script:LastPromptRowStartPosition = $CurrentPromptRowStartPosition
            $script:LastPromptRowCount         = $totalRowsInCurrentPrompt
            $script:CurrentRowPosition         = $CurrentPromptRowEndPosition + 1
            return $ReturnKey_Pressed
        }

        # Ensure buffer is tall enough for the error row
        $rawui = $Host.UI.RawUI
        $bufferSize = $rawui.BufferSize
        if ($ErrorRow -ge $bufferSize.Height) {
            $bufferSize.Height = $ErrorRow + 1
            $rawui.BufferSize = $bufferSize
        }
        # Ensure visible window is tall enough
        $windowSize = $rawui.WindowSize
        if ($ErrorRow -ge $windowSize.Height) {
            $windowSize.Height = $ErrorRow + 1
            $rawui.WindowSize = $windowSize
        }

        # VALIDATION Logic 
        # ----------------
        if (($allowANYinput) -or
            ($ValidChoices_InUpperCase -contains $UserInput_InUpperCase)) {
            $ValidChoice = $true
            # We do not need to generate $MessageToBeDisplayedBelowPrompt 
            # as it was generated in RUN-Installer and passed in as Parameter! 
            $PreviousInvalidUserInput = ""
         }
        else {
            # INVALID CHOICE: Make sure $ErrorMessage is passed to re-prompt
            $ValidChoice = $false
            $ErrorMessage = "$R ERROR - Invalid Response $Rst"
            $MessageToBeDisplayedBelowPrompt = $ErrorMessage
            $PreviousInvalidUserInput = $UserInput 

        } # END of - VALIDATION Logic
     #>   
    } # END of - while (-not $ValidChoice)

    # Carry forward $script:Variables to next call of Function
    $script:LastPromptRowStartPosition = $CurrentPromptRowStartPosition
    $script:LastPromptRowCount         = $totalRowsInCurrentPrompt
    $script:CurrentRowPosition         = $CurrentPromptRowEndPosition + 1
 
    if ($allowANYinput) {
        return $UserInput
    }
    else {
        return $UserInput_InUpperCase
    }

} # END of - function Prompt-ForUserChoice

 
# ==========================================================================================
function GET-UserInput {
    param(
        [string]$Prompt,                        
        [string]$PreviousInvalidInput,          
        [int]$PromptRow,                        
        [string]$MessageToBeDisplayedBelowPrompt,
        [int]$TotalPromptRows                   # NEW — number of physical rows in the prompt
    )
    Write-Host "$Col1" -NoNewline   # MOVE to start of Prompt Row
    Write-Host $ClrLine -NoNewline  # CLEAR Prompt Row

    # 4. Print $Prompt + faint $PreviousInvalidInput
    Write-Host "$Prompt$Faint$PreviousInvalidInput$rst" -NoNewline

    # DISPLAY - Message-To-Be-Displayed-Below-Prompt, if there is one.
    # ---------------------------------------------------------------
    $MessageWasShown = $MessageToBeDisplayedBelowPrompt.Trim() -ne ''

    # SUCCESS messages ($W White prefix) auto-clear after a few idle seconds. ERROR messages
    # ($R Red prefix) must stay on screen until the User acts - never auto-clear those.
    $IsSuccessMessage = $MessageWasShown -and (-not $MessageToBeDisplayedBelowPrompt.TrimStart().StartsWith($R))

    if ($MessageWasShown) {
        Write-Host ""                                           # Move Cursor down to next Row
        # The above statement will MOVE the CURSOR on the SCREEN and the BUFFER
        Write-Host $ClrLine -NoNewline                          # CLEAR Message Row - else a shorter message
                                                                 # leaves trailing characters from whatever
                                                                 # was previously written on this row
        Write-Host $MessageToBeDisplayedBelowPrompt -NoNewline  # Display Message BELOW Prompt - as required
        Write-Host $Up1 -NoNewline                              # Return to $PromptRow ON SCREEN
        # The above statement will MOVE the CURSOR on the SCREEN ONLY!
        # So, we need to:
        $script:CurrentRowPosition -= 1 # to keep it accurate

        # Clear the Message so it doesn't repeat
        $MessageToBeDisplayedBelowPrompt = ""
    }
    # Whether there was a Message, or not
    Write-Host "$Col1" -NoNewline                               # MOVE to start of Prompt Row
    Write-Host $Prompt -NoNewline                               # Re-display JUST the $Prompt to leave Cusor at end


    # 7. ACCEPT - User Input
    # A SUCCESS Message shown below the Prompt is auto-cleared after a few seconds of no input,
    # so it doesn't linger indefinitely once the User has read it. ERROR messages are left alone.
    $UserInput = Accept-UserInput -MessagePresent:$IsSuccessMessage

    return $UserInput
    
} # END of - function GET-UserInput


# ====================================================================================
function Accept-UserInput {
    param(
        [switch]$NoEcho,
        [switch]$MessagePresent    # A SUCCESS message is showing on the row below the prompt - clear it if the User is idle
    )

    $rawui = $Host.UI.RawUI
    $UserInput  = ""
    $Done       = $false
    $hoveredRow = $null

    # Auto-clear a below-prompt message (e.g. a SUCCESS message) after this many idle milliseconds,
    # so it doesn't linger on screen indefinitely once the User has had a chance to read it.
    $MessageClearAfterMs = 5000
    $MessageIdleMs       = 0
    $MessageCleared      = -not $MessagePresent

    # Capture scroll lower bound — cursor is at the prompt when Accept-UserInput is called
    $script:ScreenEndBufferRow = [Console]::CursorTop

    # Scroll to top AFTER prompt is written but BEFORE input is read
    if ($script:ScrollToTopAfterReposition) {
        [Console]::SetWindowPosition(0, $script:ScreenStartBufferRow)
        $script:ScrollToTopAfterReposition = $false
    }

    # Use mouse-aware input when Display-MenuFor has clickable rows (options or URLs) and the type compiled
    $useMouseInput = ($null -ne ('WinFixIT.MouseInput' -as [type])) -and
                     (($null -ne $script:RowToOption -and $script:RowToOption.Count -gt 0) -or
                      ($null -ne $script:RowToURL     -and $script:RowToURL.Count     -gt 0))

    # Acquire the input handle unconditionally: $rawui.ReadKey() (used below whenever there is
    # nothing clickable on screen - e.g. the very first CHECK/INSTALL/.../EXIT prompt) silently
    # clears ENABLE_QUICK_EDIT_MODE and never restores it. Every path through this function
    # needs the means to re-assert it, not just the mouse-aware one.
    $hasConsoleModeApi = $null -ne ('WinFixIT.MouseInput' -as [type])
    if ($hasConsoleModeApi) {
        $hInput = [WinFixIT.MouseInput]::GetStdHandle([WinFixIT.MouseInput]::STD_INPUT_HANDLE)
        [uint32]$origMode = 0
        [WinFixIT.MouseInput]::GetConsoleMode($hInput, [ref]$origMode) | Out-Null
    }

    if ($useMouseInput) {
        # Enable mouse input; disable Quick Edit so clicks are not captured as text selection
        $newMode = ($origMode -bor 0x0010 -bor 0x0080) -band (-bnot 0x0040)
        [WinFixIT.MouseInput]::SetConsoleMode($hInput, [uint32]$newMode) | Out-Null
    }

    # If the scroll-to-top feature captured a key before the prompt was shown, process it first
    if ($script:PendingFirstKey) {
        $key = $script:PendingFirstKey
        $script:PendingFirstKey = $null
        switch ($key.VirtualKeyCode) {
            13 { $Done = $true }
            8  { <# nothing to backspace on empty input #> }
            default {
                if ($key.Character) {
                    $UserInput += $key.Character
                    if (-not $NoEcho) { Write-Host $key.Character -NoNewline }
                }
            }
        }
    }

    while (-not $Done) {

        # If a below-prompt message (e.g. SUCCESS) is still showing, poll for input rather than
        # blocking indefinitely, so an idle User (no keypress, no click) sees it auto-clear after
        # $MessageClearAfterMs. Only that one row is erased and redrawn blank - the prompt and
        # cursor position are untouched. Once cleared (or once input is actually pending), this
        # block is skipped and behaviour reverts to the original blocking reads below.
        if (-not $MessageCleared) {
            $hasPendingInput = $false
            if ($useMouseInput) {
                [uint32]$evCount = 0
                [WinFixIT.MouseInput]::GetNumberOfConsoleInputEvents($hInput, [ref]$evCount) | Out-Null
                $hasPendingInput = $evCount -gt 0
            }
            else {
                $hasPendingInput = $rawui.KeyAvailable
            }

            if (-not $hasPendingInput) {
                Start-Sleep -Milliseconds 100
                $MessageIdleMs += 100
                if ($MessageIdleMs -ge $MessageClearAfterMs) {
                    $savedTop = [Console]::CursorTop; $savedLeft = [Console]::CursorLeft
                    Write-Host "$Down1$ClrLine" -NoNewline
                    [Console]::SetCursorPosition($savedLeft, $savedTop)
                    $MessageCleared = $true
                }
                continue
            }
        }

        if ($useMouseInput) {

            $rec  = New-Object WinFixIT.INPUT_RECORD
            [uint32]$read = 0
            [WinFixIT.MouseInput]::ReadConsoleInput($hInput, [ref]$rec, 1, [ref]$read) | Out-Null

            if ($rec.EventType -eq [WinFixIT.MouseInput]::KEY_EVENT_TYPE -and $rec.KeyEvent.bKeyDown -ne 0) {

                switch ($rec.KeyEvent.wVirtualKeyCode) {
                    13 { $Done = $true }
                    8  {
                        if ($UserInput.Length -gt 0) {
                            $UserInput = $UserInput.Substring(0, $UserInput.Length - 1)
                            if (-not $NoEcho) { Write-Host "`b `b" -NoNewline }
                        }
                    }
                    default {
                        $ch = $rec.KeyEvent.uChar
                        if ($ch -and $ch -ne [char]0) {
                            $UserInput += $ch
                            if (-not $NoEcho) { Write-Host $ch -NoNewline }
                        }
                    }
                }
            }
            elseif ($rec.EventType -eq [WinFixIT.MouseInput]::MOUSE_EVENT_TYPE -and
                    $rec.MouseEvent.dwEventFlags -eq 0 -and
                    ($rec.MouseEvent.dwButtonState -band [WinFixIT.MouseInput]::FROM_LEFT_1ST_BUTTON_PRESSED)) {

                $clickRow = $rec.MouseEvent.dwMousePosition.Y - $script:ScreenStartBufferRow
                if ($null -ne $script:RowToURL -and $script:RowToURL.ContainsKey($clickRow) -and
                    -not $script:RowToOption.ContainsKey($clickRow)) {
                    Start-Process "explorer.exe" $script:RowToURL[$clickRow]
                }
                elseif ($script:RowToOption.ContainsKey($clickRow)) {
                    $UserInput = $script:RowToOption[$clickRow]
                    if (-not $NoEcho) { Write-Host $UserInput -NoNewline }
                    $Done = $true
                }
            }
            elseif ($rec.EventType -eq [WinFixIT.MouseInput]::MOUSE_EVENT_TYPE -and
                    ($rec.MouseEvent.dwEventFlags -band 4)) {
                try {
                    # MOUSE_WHEELED — scroll the console window, clamped to the current menu's content
                    # Promote to int64 first (uint32 always fits); shift right 16 to get the high
                    # word (0-65535); sign-extend to a signed delta (>32767 means negative).
                    $highWord = [int](([long]$rec.MouseEvent.dwButtonState) -shr 16) -band 0xFFFF
                    $delta    = if ($highWord -gt 32767) { $highWord - 65536 } else { $highWord }
                    $lines    = 3
                    $newTop   = [Console]::WindowTop + $(if ($delta -gt 0) { -$lines } else { $lines })
                    # Clamp: can't scroll above the menu start; can't push the prompt off the bottom
                    $winH   = $Host.UI.RawUI.WindowSize.Height
                    $minTop = if ($null -ne $script:ScreenStartBufferRow) { $script:ScreenStartBufferRow } else { 0 }
                    $maxTop = if ($null -ne $script:ScreenEndBufferRow) {
                        [Math]::Min(
                            [Console]::BufferHeight - $winH,
                            [Math]::Max($minTop, $script:ScreenEndBufferRow - $winH + 3)
                        )
                    } else {
                        [Console]::BufferHeight - $winH
                    }
                    $newTop = [Math]::Max($minTop, [Math]::Min($newTop, $maxTop))
                    [Console]::SetWindowPosition(0, $newTop)
                } catch {}
            }
            elseif ($rec.EventType -eq [WinFixIT.MouseInput]::MOUSE_EVENT_TYPE -and
                    ($rec.MouseEvent.dwEventFlags -band 1)) {
                # MOUSE_MOVED — hover-highlight headings ($W name) and URL rows (blue+underline)
                $mouseScreenRow = $rec.MouseEvent.dwMousePosition.Y - $script:ScreenStartBufferRow
                $isHeadingRow   = $null -ne $script:RowToHeading   -and $script:RowToHeading.ContainsKey($mouseScreenRow)
                $isUrlRow       = $null -ne $script:RowToPlainText -and $script:RowToPlainText.ContainsKey($mouseScreenRow)
                $newHoverRow    = if ($isHeadingRow -or $isUrlRow) { $mouseScreenRow } else { $null }
                if ($newHoverRow -ne $hoveredRow) {
                    # Preserve the user's current scroll position - repositioning the cursor
                    # below to paint the hover highlight can otherwise drag the visible
                    # window back down (e.g. after the user scrolled up to browse a long
                    # LIBRARY - Contents list).
                    $preservedWindowTop = [Console]::WindowTop

                    # Revert previously hovered row
                    if ($null -ne $hoveredRow) {
                        $savedTop = [Console]::CursorTop; $savedLeft = [Console]::CursorLeft
                        [Console]::SetCursorPosition(0, $script:ScreenStartBufferRow + $hoveredRow)
                        if ($null -ne $script:RowToHeading -and $script:RowToHeading.ContainsKey($hoveredRow)) {
                            $h = $script:RowToHeading[$hoveredRow]
                            Write-Host "$ClrLine$Y$($h.Prefix)$($h.Name)$Rst" -NoNewline
                        } elseif ($null -ne $script:RowToPlainText -and $script:RowToPlainText.ContainsKey($hoveredRow)) {
                            Write-Host "$ClrLine$Gy$($script:RowToPlainText[$hoveredRow])$Rst" -NoNewline
                        }
                        [Console]::SetCursorPosition($savedLeft, $savedTop)
                    }
                    # Highlight newly hovered row
                    if ($null -ne $newHoverRow) {
                        $savedTop = [Console]::CursorTop; $savedLeft = [Console]::CursorLeft
                        [Console]::SetCursorPosition(0, $script:ScreenStartBufferRow + $newHoverRow)
                        if ($isHeadingRow) {
                            $h = $script:RowToHeading[$newHoverRow]
                            Write-Host "$ClrLine$Y$($h.Prefix)$W$Underline$($h.Name)$Rst" -NoNewline
                        } else {
                            $plain  = $script:RowToPlainText[$newHoverRow]
                            $indent = $plain.Length - $plain.TrimStart().Length
                            Write-Host "$ClrLine$Gy$(' ' * $indent)$Blue$Underline$($plain.TrimStart())$Rst" -NoNewline
                        }
                        [Console]::SetCursorPosition($savedLeft, $savedTop)
                    }
                    $hoveredRow = $newHoverRow
                    [Console]::SetWindowPosition(0, $preservedWindowTop)
                }
            }
        }
        else {

            $key = $rawui.ReadKey("NoEcho,IncludeKeyDown")

            # $rawui.ReadKey() clears ENABLE_QUICK_EDIT_MODE and never restores it - re-assert
            # it after every keystroke so mouse text-selection keeps working between prompts.
            if ($hasConsoleModeApi) {
                [uint32]$curMode = 0
                [WinFixIT.MouseInput]::GetConsoleMode($hInput, [ref]$curMode) | Out-Null
                [WinFixIT.MouseInput]::SetConsoleMode($hInput, ($curMode -bor 0x0040 -bor 0x0080)) | Out-Null
            }

            switch ($key.VirtualKeyCode) {

                13 {   # ENTER
                    $Done = $true
                }

                8 {    # BACKSPACE
                    if ($UserInput.Length -gt 0) {
                        $UserInput = $UserInput.Substring(0, $UserInput.Length - 1)
                        if (-not $NoEcho) {
                            Write-Host "`b `b" -NoNewline
                        }
                    }
                }

                default {
                    if ($key.Character) {
                        $UserInput += $key.Character
                        if (-not $NoEcho) {
                            Write-Host $key.Character -NoNewline
                        }
                    }
                }
            }
        }
    }

    if ($useMouseInput -and $hasConsoleModeApi) {
        # Restore the ambient mode but force Quick Edit back on regardless of what $origMode
        # said - it may already have been left disabled by an earlier prompt in this session.
        [WinFixIT.MouseInput]::SetConsoleMode($hInput, ($origMode -bor 0x0040 -bor 0x0080)) | Out-Null
    }

    if ($null -ne $hoveredRow) {
        $preservedWindowTop = [Console]::WindowTop
        [Console]::SetCursorPosition(0, $script:ScreenStartBufferRow + $hoveredRow)
        if ($null -ne $script:RowToHeading -and $script:RowToHeading.ContainsKey($hoveredRow)) {
            $h = $script:RowToHeading[$hoveredRow]
            Write-Host "$ClrLine$Y$($h.Prefix)$($h.Name)$Rst" -NoNewline
        } elseif ($null -ne $script:RowToPlainText -and $script:RowToPlainText.ContainsKey($hoveredRow)) {
            Write-Host "$ClrLine$Gy$($script:RowToPlainText[$hoveredRow])$Rst" -NoNewline
        }
        [Console]::SetCursorPosition(0, $script:ScreenEndBufferRow)
        [Console]::SetWindowPosition(0, $preservedWindowTop)
    }

    $UserInput.Trim()

} # END of - function Accept-UserInput


# ====================================================================================
function Build-KeywordRowMap {
# Scans the console buffer from the last Clear-Screen to the current cursor position,
# looking for rows whose visible text (after TrimStart) starts with one of $Keywords.
# Returns a hashtable of logical-row → keyword for use as $script:RowToOption.
# Wraps GetBufferContents in try/catch so failures (e.g. in WinPE) degrade silently.
# ====================================================================================
    param([string[]]$Keywords)
    $rowToOption = @{}
    try {
        $bufWidth = $Host.UI.RawUI.BufferSize.Width
        $startBuf = $script:ScreenStartBufferRow
        $endBuf   = [Console]::CursorTop
        $rect     = New-Object System.Management.Automation.Host.Rectangle(
                        0, $startBuf, $bufWidth - 1, $endBuf)
        $cells    = $Host.UI.RawUI.GetBufferContents($rect)
        $rows     = $cells.GetLength(0)
        $cols     = $cells.GetLength(1)
        for ($rowNum = 0; $rowNum -lt $rows; $rowNum++) {
            $sb = New-Object System.Text.StringBuilder
            for ($colNum = 0; $colNum -lt $cols; $colNum++) {
                [void]$sb.Append($cells.GetValue($rowNum, $colNum).Character)
            }
            $trimmed = $sb.ToString().TrimStart()
            foreach ($kw in $Keywords) {
                if ($trimmed.ToUpper().StartsWith($kw)) {
                    $rowToOption[$rowNum] = $kw
                    break
                }
            }
        }
    }
    catch { }
    return $rowToOption
} # END of - function Build-KeywordRowMap


# ==========================================================================================
function Reposition-CursorToRow {
# ==========================================================================================
    param (
        [Parameter(Mandatory)]
        [int]$TargetRow
    )
    # TargetRow is relative to the top of the screen after the last Clear-Screen call.
    # $script:ScreenStartBufferRow records [Console]::CursorTop immediately after Clear-Host,
    # giving us the true buffer offset without relying on WindowPosition.Y (which is unreliable).

    $bufferRow = $script:ScreenStartBufferRow + $TargetRow
    $bufferRow = [Math]::Min($bufferRow, $Host.UI.RawUI.BufferSize.Height - 1)
    if ($bufferRow -lt 0) { $bufferRow = 0 }

    [Console]::SetCursorPosition(0, $bufferRow)

} # END of - Reposition-CursorToRow


# =========================================================================================
function Resolve-ColourTokens {
# ==========================================================================================
<#
    .SYNOPSIS
        Expands embedded colour tokens in scenario text.

    .DESCRIPTION
        Takes a string containing variables like $Y, $C, $Rst, etc.
        and evaluates them so they render as ANSI sequences when printed.
        Intended for trusted scenario-file content only.

    .PARAMETER Text
        The string to expand.

    .NOTES
        Uses Invoke-Expression for simplicity - only safe if scenario
        files are trusted and under maintainer control.
#>
    param (
        [Parameter(Mandatory = $true)][string]$Text
    )

    return (Invoke-Expression "`"$Text`"")

}  # END of - function Resolve-ColourTokens


# ================================================================================================
function Clear-Screen {
# ================================================================================================
#  Clears the visible console buffer AND reinitialises the script-scope
#  prompt/display tracking variables used for deterministic positioning.
#
#  Why:
#    - $script:CurrentRowPosition, $script:LastPromptRowStartPosition, and $script:LastPromptRowCount
#      are our own "UI GPS" - they track where we are on the screen without relying
#      on $Host.UI cursor reads.
#    - After a Clear-Host, the visible buffer is empty but our counters still hold
#      old values. If we don't reset them, the next prompt or display will start
#      far down the screen or overwrite earlier content.
#
#  Usage:
#    Call Clear-Screen whenever you want a true fresh start for the UI.
#    This ensures all subsequent positioning is in sync with the cleared buffer.
#
#  Future-You:
#    DO NOT replace with Clear-Host directly unless you also reset these variables.
# ================================================================================================

    # Clear the console.
    # This acan be temporarily commented out to see syntax Errors when Script is first read
    Clear-Host
    $script:ScreenStartBufferRow       = [Console]::CursorTop  # true buffer offset after clear
    $script:CurrentRowPosition         = 0
    $script:LastPromptRowStartPosition = 0
    $script:LastPromptRowCount         = 0

    try {
        $rawui = $Host.UI.RawUI
        $bufferSize = $rawui.BufferSize
        $windowSize = $rawui.WindowSize

        # Ensure buffer is at least as wide and tall as the window we want
        if ($bufferSize.Width -lt $windowSize.Width) {
            $bufferSize.Width = $windowSize.Width
        }
        if ($bufferSize.Height -lt $windowSize.Height) {
            $bufferSize.Height = $windowSize.Height
        }
        $rawui.BufferSize = $bufferSize

        # Now safe to sync window width to buffer width
        $rawui.WindowSize = New-Object System.Management.Automation.Host.Size(
            $bufferSize.Width,
            $windowSize.Height
        )
    }
    catch {
        # In WinPE or restricted hosts, this may fail - ignore quietly
    }
}  # END of -function Clear-Screen




# =================================================================================================
function Set-Cursor {
    param(
        [int]$Row,
        [int]$Col
    )
    $ui = $Host.UI.RawUI
    $maxRow = $ui.BufferSize.Height - 1
    $maxCol = $ui.BufferSize.Width - 1
    if ($Row -gt $maxRow) { $Row = $maxRow }
    if ($Col -gt $maxCol) { $Col = $maxCol }
    $ui.CursorPosition = New-Object System.Management.Automation.Host.Coordinates $Col, $Row
}

# ================================================================================================
function ON-LastRowOfScreen {
    param(
        [int]$Row
    )

    $rawui        = $Host.UI.RawUI
    $windowTop    = $rawui.WindowPosition.Y
    $windowHeight = $rawui.WindowSize.Height

    # Convert visible-window row → buffer row if needed
    # If $Row is already a buffer row, this does nothing harmful.
    if ($Row -lt $windowHeight) {
        $Row = $windowTop + $Row
    }

    $lastVisibleRow = $windowTop + $windowHeight - 1

    return ($Row -eq $lastVisibleRow)

} # END of - ON-LastRowOfScreen


# =================================================================================================
#  Initialise Prompt Tracking Variables -
# -------------------------------------------------------------------------------------------------
#  These variables are used by Prompt-ForUserChoice to keep track of where prompts start and end
#  in the console buffer, without relying on $Host.UI cursor reads (which can be unreliable).
#
#  Why they exist:
#    - $script:CurrentRowPosition
#        Our own "row counter" that advances deterministically based on what we print.
#        This is the authoritative record of the last row printed in the session.
#
#    - $script:LastPromptRowStartPosition
#        The row number (from our own tracking) where the previous prompt started.
#        Used when overwriting a previous prompt or calculating where the next one should begin.
#
#    - $script:LastPromptRowCount
#        How many rows the previous prompt occupied (from our own tracking).
#        Useful for logging/debugging, but not relied on for positioning.
#
#  Why initialise here:
#    - This file is always dot-sourced before Main-Line runs, so these variables will be set
#      before Prompt-ForUserChoice is ever called.
#    - Placing them here keeps them co-located with the function that depends on them.
#    - Initialising them prevents $null values and ensures predictable behaviour on first use.
#
#  Future-You: DO NOT REMOVE unless you also remove all references to these variables in
#  Prompt-ForUserChoice and any related positioning logic. Without them, prompt positioning
#  will break in cold-start scenarios.
# =================================================================================================

if ($null -eq $script:ScreenStartBufferRow)      { $script:ScreenStartBufferRow = 0 }
if ($null -eq $script:CurrentRowPosition)        { $script:CurrentRowPosition = 0 }
if ($null -eq $script:LastPromptRowStartPosition){ $script:LastPromptRowStartPosition = 0 }
if ($null -eq $script:LastPromptRowCount)        { $script:LastPromptRowCount = 0 }
$script:PendingFirstKey      = $null
$script:RowToOption          = $null
$script:ScreenEndBufferRow   = $null

# ── One-time console window setup ────────────────────────────────────────────────────────
# Guarded by a $global: flag so it runs exactly once per PowerShell session regardless of
# how many times this file is dot-sourced (e.g. by the main script AND by Launch-Menu.ps1).
if (-not $global:WinFixIT_ConsoleReady) {
    try {
        # Compile the Win32 helper type once per session
        if (-not ('WinFixIT.ConsoleHelper' -as [type])) {
            Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
namespace WinFixIT {
    public struct RECT { public int Left, Top, Right, Bottom; }
    public class ConsoleHelper {
        [DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hwnd, int nCmdShow);
        [DllImport("user32.dll")] public static extern bool MoveWindow(System.IntPtr hwnd, int x, int y, int width, int height, bool repaint);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr hwnd, out RECT lpRect);
    }
}
'@ -ErrorAction Stop
        }

        if (-not ('WinFixIT.MouseInput' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace WinFixIT {
    [StructLayout(LayoutKind.Sequential)]
    public struct COORD { public short X; public short Y; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct KEY_EVENT_RECORD {
        public int    bKeyDown;
        public ushort wRepeatCount;
        public ushort wVirtualKeyCode;
        public ushort wVirtualScanCode;
        public char   uChar;
        public uint   dwControlKeyState;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSE_EVENT_RECORD {
        public COORD  dwMousePosition;
        public uint   dwButtonState;
        public uint   dwControlKeyState;
        public uint   dwEventFlags;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct INPUT_RECORD {
        [FieldOffset(0)] public ushort             EventType;
        [FieldOffset(4)] public KEY_EVENT_RECORD   KeyEvent;
        [FieldOffset(4)] public MOUSE_EVENT_RECORD MouseEvent;
    }

    public class MouseInput {
        public const int    STD_INPUT_HANDLE             = -10;
        public const uint   ENABLE_MOUSE_INPUT           = 0x0010;
        public const uint   ENABLE_EXTENDED_FLAGS        = 0x0080;
        public const uint   ENABLE_QUICK_EDIT_MODE       = 0x0040;
        public const ushort KEY_EVENT_TYPE               = 0x0001;
        public const ushort MOUSE_EVENT_TYPE             = 0x0002;
        public const uint   FROM_LEFT_1ST_BUTTON_PRESSED = 0x0001;

        [DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int n);
        [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint mode);
        [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint mode);
        [DllImport("kernel32.dll")] public static extern bool ReadConsoleInput(IntPtr h, out INPUT_RECORD rec, uint len, out uint read);
        [DllImport("kernel32.dll")] public static extern bool GetNumberOfConsoleInputEvents(IntPtr h, out uint count);
        [DllImport("kernel32.dll")] public static extern bool PeekConsoleInput(IntPtr h, out INPUT_RECORD rec, uint len, out uint read);
    }
}
'@ -ErrorAction Stop
        }

        # Set console column width first — pixel width follows from font metrics, not screen %
        $targetCols = 100
        $bs = $Host.UI.RawUI.BufferSize
        $ws = $Host.UI.RawUI.WindowSize
        $setCols = [Math]::Min($targetCols, $Host.UI.RawUI.MaxWindowSize.Width)
        if ($bs.Width -lt $setCols) { $bs.Width = $setCols; $Host.UI.RawUI.BufferSize = $bs }
        if ($ws.Width -ne $setCols) { $ws.Width = $setCols; $Host.UI.RawUI.WindowSize = $ws }
        Start-Sleep -Milliseconds 150   # let the console self-size to the new column count

        # Measure the pixel width the console chose for those columns
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $wa   = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $hwnd = [WinFixIT.ConsoleHelper]::GetForegroundWindow()
        $rect = New-Object WinFixIT.RECT
        [WinFixIT.ConsoleHelper]::GetWindowRect($hwnd, [ref]$rect) | Out-Null
        $winW = [Math]::Min($rect.Right - $rect.Left, $wa.Width)

        # Position: top-left, content-driven width, full screen height
        [WinFixIT.ConsoleHelper]::ShowWindow($hwnd, 1)  | Out-Null   # SW_SHOWNORMAL — un-maximise first
        [WinFixIT.ConsoleHelper]::MoveWindow($hwnd, $wa.X, $wa.Y, $winW, $wa.Height, $true) | Out-Null
        Start-Sleep -Milliseconds 250   # allow the resize event to propagate to the console
    }
    catch { <# silently ignore — resize is cosmetic; correctness fixes are elsewhere #> }

    # Ensure the scroll buffer is deep enough that no menu ever triggers a buffer scroll
    # (buffer scrolling pins CursorTop at the last row and mis-positions the prompt)
    $bs = $Host.UI.RawUI.BufferSize
    if ($bs.Height -lt 500) { $bs.Height = 500; $Host.UI.RawUI.BufferSize = $bs }

    $global:WinFixIT_ConsoleReady = $true
}


# ==========================================================================================
# COLOUR DEFINITIONS and  CURSOR CONTROL SEQUENCES
# ==========================================================================================

<# Defines ANSI colour codes and cursor control for console output with meaningful names.

.SYNOPSIS
    Common colour definitions for console output.

.DESCRIPTION
    This script defines a standard set of ANSI colour codes with meaningful names
    (e.g. $Green_Bright, $Yellow_Amber) for consistent use across all project scripts.
    It also enables Virtual Terminal Processing so ANSI escape sequences render correctly
    in supported Windows consoles.

.USAGE
    1. Place Common-Colours.ps1 in the same folder as your scripts (or a known include path).
    2. At the very top of your script, dot-source this file:

           . "$PSScriptRoot\Common-Colours.ps1"

       This will import all colour variables into your script's scope.

    3. Use the variables in Write-Host or string output, wrapping text between the colour
       and $Reset, for example:

           Write-Host "${Yellow_Bright}G'Day, ${UseFirstName}${Reset}"
           Write-Host "${Grey_Light}This USB will check your PC...${Reset}"
           Write-Host "${Green_Vivid}PASS${Reset} - All checks succeeded."
           Write-Host "${Red_Vivid}FAIL${Reset} - CPU not supported."

.NOTES
    - Always wrap coloured text with $Reset at the end to avoid colour bleed.
    - If colours print as "e[92m" instead of rendering, ensure you're running in
      Windows Terminal or have disabled "Use legacy console" in console properties.
    - This file can be extended with additional colours or helper functions as needed.
#>

# Section: Colour Variable Usage
# Purpose: Clarify when braces `{}` are required around colour variables to ensure correct parsing and output.
# Notes:
#   - Applies to direct variable use in strings, especially scenario-driven UI text.
#   - Avoids silent errors and unintended concatenation.

# Braces NOT required when:
#   - The variable is clearly delimited by surrounding characters (e.g., spaces, punctuation).
#   - There is no risk of the parser misinterpreting the variable name.

# Write-Host "$R This is red text."         # Safe: $R followed by space
# Write-Host "$GB: Balanced green alert."   # Safe: $GB followed by punctuation

# Braces REQUIRED when:
#   - The variable is immediately followed by alphanumeric characters that could be parsed as part of the variable name.
#   - You need to isolate the variable from adjacent text.

# Write-Host "${R}ed alert!"                # Required: avoids parsing as $Red
# Write-Host "${GB}alance achieved."        # Required: avoids parsing as $GBalance

# Rule of Thumb:
#   - If the character after the variable is a letter, digit, or underscore, use braces.
#   - If it's a space, punctuation, or line break, braces are optional.

# COLOUR DEFINITIONS
# ------------------
# Base escape
$esc   = [char]27
$Reset = "$esc[0m"
$ANSI = "$esc`[[0-9;]*m"

# --- Full semantic names (for maintainers) ---
$Bright_White     = "$esc[97m"
$Cyan             = "$esc[96m"
$Green            = "$esc[92m"
$Grey_Light       = "$esc[37m"
$Grey_Dark        = "$esc[90m"  # Bright black fallback
$Red              = "$esc[91m"
$Yellow           = "$esc[93m"
$Yellow_Balanced  = "$esc[93m"  # Bright yellow fallback
$Faint            = "$esc[2m"
$Grey_Light_Faint = "$esc[2;37m"
$Grey_Dark_Faint  = "$esc[2;90m"

$Bold             = "$esc[1m"
$NoBold           = "$esc[22m"
$Italic           = "$esc[3m"
$NoItalic         = "$esc[23m"
$Underline        = "$esc[4m"
$NoUnderline      = "$esc[24m"
$Blue             = "$esc[94m"

# --- Abbreviated aliases (for scenario text) ---
$C    = $Cyan
$G    = $Green
$Gy   = $Grey_Light
$Gyd  = $Grey_Dark
$R    = $Red
$W    = $Bright_White
$Y    = $Yellow
$Yb   = $Yellow_Balanced
$Rst  = $Reset

$Bld  = $Bold
$NBld = $NoBold
$I    = $Italic
$N    = $NoItalic
$Ul   = $Underline
$NUl  = $NoUnderline
$Bl   = $Blue

# CURSOR CONTROL SEQUENCES
# ------------------------
$ClrLine = "$esc[2K"    # Clear entire line
$Col1    = "$esc[1G"    # Move to column 1
$Up1     = "$esc[1A"    # Move up 1 line
$Up2     = "$esc[2A"    # Move up two lines
$Up3     = "$esc[3A"    # Move up three lines
$Down1   = "$esc[1B"    # Move down 1 line
$Down2   = "$esc[2B"    # Move down 2 lines

$RememberCursorPosition  = "$esc[s"    
$ReturnToCursorPosition  = "$esc[u"


