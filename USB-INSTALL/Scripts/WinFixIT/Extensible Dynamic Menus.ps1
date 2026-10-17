# Extensible Dynamic Menus.ps1
# ============================
#
# This Script implements  a Multi-Level Menu system, driven only by the Contents of the Files and # # # # Folders in a Root Folders. 
#    - Menu Folders have a ‘Menu Introduction.txt’ File,
#    - Option Folders have an ‘Option Description.txt’ File,
#        - Installable Options have a ‘Start.bat’ File,
#        - Hyperlink or information only Folders, just have an ‘Option Description.txt’ File.
#
# Given this information it is not necessary to have a separate Menu Index, as all the information 
# necessary is in the Folder Structure itself.  
#
# Menu Creation Rules
# -------------------
# The following rules enable you to create any Menu required:
#    - Menu Header       = <ParentFolderName> + “ – “ + <CurrentFolderName> + “ Menu”
#         EXCEPT the first level below the LIBRARY root: when <ParentFolderName> is
#         "Install", the "Install – " prefix is dropped and the header is just
#         <CurrentFolderName> + " Menu".  Otherwise a header like
#         "Install – Documentation & Reference" wrongly implies something is about
#         to be installed.  The LIBRARY root itself uses $TopLevelTitle.
#    - Menu Introduction = TextFrom(<CurrentFolderName>\“Menu Introduction.txt”)
#    - Option Header     = <SubFolderName>
#    - Option Text       = TextFrom(<SubFolderName>\” Menu Introduction.txt”) OR
#		           TextFrom(<SubFolderName>\” Option Description.txt”)
# Option Types
# ------------
# When creating Options, we have to decide whether it is a:
#    - Sub-Menu,         because its <SubFolderName> contains a “Menu Introduction.txt” file.
#    - Actionable,       because its <SubFolderName> contains a “Start.bat” file.
#    - Information only, because it contains neither.  
#
# Information only OPtions supply only information. So:
#    - they will not receive an Option Number in the Menu.  
#    - Nor, will its Option Header be highlighted.  
#      This is to prevent Users thinking they have an active Option Number.
#
# Then on selection of an Option, the system knows:
#    - If Sub-Menu   Option Selected - DisplayMenuFor(<SubFolderName>)
#    - If Actionable Option Selected - Execute(<SubFolderName>\”Start.Bat”)

# =============================================================================================
function Display-MenuFor {
    param(
        [Parameter(Mandatory=$true)][string]$FolderPath,
        [string]$TopLevelTitle = "On2it-WinFixIT - LIBRARY Menu",
        [string]$LibraryRoot = "",
        # Set by a standalone entry point (e.g. Launch-Menu.ps1) that has no enclosing menu
        # loop of its own - so <Return> at the LIBRARY root would otherwise unwind out of
        # Display-MenuFor entirely and end the whole process with no way back.
        [switch]$NoCallerToReturnTo
    )

    $localDEBUG_Mode = $false
    if (-not $LibraryRoot) { $LibraryRoot = $FolderPath }

    # Validate folder
    if (-not (Test-Path -LiteralPath $FolderPath)) {
        Write-Host "$R Folder not found:$Rst $FolderPath"
        cmd /c pause
        return
    }

    # Determine parent and current folder names
    $parent      = Split-Path $FolderPath -Parent
    $parentName  = Split-Path $parent -Leaf
    $currentName = Split-Path $FolderPath -Leaf
 

    If($localDEBUG_Mode){
        Write-Host "[DEBUG] Display-MenuFor Parent      = $parent"
        Write-Host "[DEBUG] Display-MenuFor ParentName  = $parentName"
        Write-Host "[DEBUG] Display-MenuFor CurrentName = $currentName"
        Write-Host "[DEBUG] Display-MenuFor grandParent = $grandParent"
        Pause
    }

    $isTreeRoot = ($FolderPath.TrimEnd('\') -ieq $LibraryRoot.TrimEnd('\'))

    # Build menu header text
    if ($isTreeRoot) {
        # This IS the root of the Library tree that was opened - use the top-level title
        $menuHeader = $TopLevelTitle
    }
    else {
        # if the parent folder is named "Install" (the root of the Install tree), use only the current folder name
        If ($ParentName -eq "Install") { 
             $menuHeader = $currentName + " Menu"
        }
        else {
            # All deeper levels use parent/current folder names
            $menuHeader = $parentName + " - " + $currentName + " Menu"
        }
    }

    # Load Menu Introduction.txt (if present)
    $introPath = Join-Path $FolderPath 'Menu Introduction.txt'
    $introLines = @()
    if (Test-Path -LiteralPath $introPath) {
        $introLines = Get-Content -LiteralPath $introPath -ErrorAction SilentlyContinue
    }

    $MessageReturned = ""

    # Main menu loop
    while ($true) {

        # Enumerate subfolders in creation order - re-scanned EVERY redraw (not
        # just once on entry), so an action that adds/removes content (e.g.
        # "COPY Course Notes") shows up immediately on return instead of
        # needing the whole menu closed and reopened. Fixed 2026-08-03
        # (Brian, real hardware): the one-time scan was why newly-copied
        # Course Notes never appeared without a full restart - true for
        # every menu in WinFixIT, not just Courses, so this is a general
        # correctness fix, not a Courses-specific one. Cheap enough
        # (Get-ChildItem on one folder level) to not be noticeable.
        $subFolders = Get-ChildItem -Path $FolderPath -Directory |
            Where-Object { $_.Name -ne 'Windows' } |
            Sort-Object CreationTime

        # Build option objects
        $options = @()

        foreach ($sf in $subFolders) {

            $menuIntro = Join-Path $sf.FullName 'Menu Introduction.txt'
            $optDesc   = Join-Path $sf.FullName 'Option Description.txt'
            $startBat  = Join-Path $sf.FullName 'Start.bat'

            $type = 'InfoOnly'

            if (Test-Path -LiteralPath $menuIntro) {
                $type = 'SubMenu'
            }
            elseif (Test-Path -LiteralPath $startBat) {
                $type = 'Actionable'
            }

            $options += [PSCustomObject]@{
                Name        = $sf.Name
                Path        = $sf.FullName
                Type        = $type
                IntroPath   = $menuIntro
                DescPath    = $optDesc
                StartPath   = $startBat
            }
        }

        # If every option is InfoOnly there is nothing to select — drop "Menu" from the
        # title. Idempotent (-replace on text already stripped is a no-op), so re-running
        # this every redraw alongside the now-repeated scan above is harmless.
        $hasActionable = $options | Where-Object { $_.Type -ne 'InfoOnly' }
        if (-not $hasActionable) {
            $menuHeader = $menuHeader -replace '\s*Menu$', ''
        }

        $script:CurrentRowPosition = 0
        Clear-Host
        # Windows Terminal silently collapses the buffer height back down to the window
        # height on every Clear-Host after the first one, discarding whatever was scrolled
        # past (not just hiding it) - re-assert it here, every redraw, not just once at
        # session start, or long menus lose their "row 0" and all row-tracking breaks.
        $bs = $Host.UI.RawUI.BufferSize
        if ($bs.Height -lt 500) { $bs.Height = 500; $Host.UI.RawUI.BufferSize = $bs }
        $script:ScreenStartBufferRow = [Console]::CursorTop

        # Read actual console width each redraw so layout adapts to window resizes
        $lineWidth  = $Host.UI.RawUI.BufferSize.Width
        $headerText = $menuHeader.Trim()
        $padding    = [math]::Max(0, ($lineWidth - $headerText.Length) / 2)
        $centeredHeader = (' ' * [math]::Floor($padding)) + $headerText

        if ($centeredHeader -like '*On2it-WinFixIT*') {
            $prefix, $suffix = $centeredHeader -split 'On2it-WinFixIT', 2
            $colouredHeader  = "$prefix$Y" + 'On2it-WinFixIT' + "$W$suffix$Rst"
        }
        else {
            # Split parent/child headers into Yellow (left) and White (right).
            # Match only a SPACED " - " (the separator this script inserts between
            # <ParentFolderName> and <CurrentFolderName>), never a bare hyphen -
            # otherwise a folder name like "Anti-Virus Menu" would mis-split as
            # "Anti" / "Virus Menu".  Single-name headers (e.g. "Applications Menu")
            # have no " - " and print whole in Yellow.
            if ($centeredHeader -match '^(.*?) - (.*)$') {
                $left  = $Matches[1].TrimEnd()
                $right = $Matches[2].TrimStart()
                $colouredHeader = "$Y$left$W - $right$Rst"
            }
            else {
                # No " - " separator — print whole header in Yellow
                $colouredHeader = "$Y$centeredHeader$Rst"
            }

        }

        # Render header
        Write-Host ("$C" + ('=' * $lineWidth) + "$Rst")
        Write-Host $colouredHeader
        Write-Host ("$C" + ('=' * $lineWidth) + "$Rst")

        # Adjust row counter for header lines
        $script:CurrentRowPosition += 3

        # Menu Introduction
        foreach ($line in $introLines) {
            $expanded = Expand-ColourCodes $line
            $wrapped  = Wrap-IndentedText -Text $expanded -Indent 1 -MaxWidth $lineWidth
            foreach ($row in $wrapped) { Write-AndCount $row }
        }

        # Render options
        $index = 1
        $actionableOptions = @('')
        $rowToOption    = @{}
        $rowToHeading   = @{}
        $rowToPlainText = @{}
        $rowToURL       = @{}

        # Enable mouse input before rendering so clicks on already-visible rows are captured
        $mouseType   = 'WinFixIT.MouseInput' -as [type]
        $hasPeek     = $mouseType -and ($mouseType.GetMethod('PeekConsoleInput') -ne $null)
        $hStdinEarly = $null
        if ($mouseType) {
            $hStdinEarly = [WinFixIT.MouseInput]::GetStdHandle([WinFixIT.MouseInput]::STD_INPUT_HANDLE)
            $earlyMode   = [uint32]0
            [WinFixIT.MouseInput]::GetConsoleMode($hStdinEarly, [ref]$earlyMode) | Out-Null
            $mouseMode   = ($earlyMode -band -bnot [WinFixIT.MouseInput]::ENABLE_QUICK_EDIT_MODE) -bor `
                           [WinFixIT.MouseInput]::ENABLE_MOUSE_INPUT -bor `
                           [WinFixIT.MouseInput]::ENABLE_EXTENDED_FLAGS
            [WinFixIT.MouseInput]::SetConsoleMode($hStdinEarly, $mouseMode) | Out-Null
        }
        $earlyChoice = $null

        foreach ($opt in $options) {

            $isActionable = ($opt.Type -eq 'Actionable' -or $opt.Type -eq 'SubMenu')

            # Add a blank line before EVERY Option
            Write-AndCount ""

            $optStartRow = $script:CurrentRowPosition   # row where heading will land

            if ($isActionable) {
                Write-AndCount "$Y $index. $($opt.Name)$Rst"
                $rowToHeading[$optStartRow] = @{ Prefix = " $index. "; Name = $opt.Name }
                $actionableOptions += "$index"
            }
            else {
                Write-AndCount "$Y $($opt.Name)$Rst"
            }

            # Load description text
            $descFile = $opt.DescPath
            if ($opt.Type -eq 'SubMenu') {
                $descFile = $opt.IntroPath
            }

            # --- Read Option Description.txt preserving blank lines ---
            if (Test-Path -LiteralPath $descFile) {

                # Split $descFile into separate $lines
                # ------------------------------------
                #   \n   = Match a newline (LF). This is required.
                #   \r?  = Match an optional carriage return (CR) before it.
                #          This allows the split to work with both:
                #              Windows files   (CRLF = "\r\n")
                #              Linux/macOS files (LF = "\n")
                #
                #   Result: Split on ANY normal newline without keeping the delimiter,
                #           and without generating phantom blank lines.
                $raw   = Get-Content -LiteralPath $descFile -Raw -Encoding UTF8
                $lines = $raw -split "\r?\n"


                # Remove trailing blank lines but keep internal ones
                while ($lines.Count -gt 0 -and $lines[-1] -match '^\s*$') {
                    $lines = $lines[0..($lines.Count - 2)]
                }

                foreach ($line in $lines) {

                    $line = $line.TrimEnd()

                    if ($line -match '^\s*$') {
                        Write-AndCount ""                     # keep blank line
                    }
                    elseif ($line -match '^\s*(https?://\S+)\s*$') {
                        $url     = $Matches[1]
                        $urlRow  = $script:CurrentRowPosition
                        $expanded = Expand-ColourCodes $line
                        $wrapped  = @(Wrap-IndentedText -Text $expanded -Indent 4 -MaxWidth $lineWidth)
                        foreach ($row in $wrapped) { Write-AndCount "$Gy$row$Rst" }
                        if ($wrapped.Count -gt 0) {
                            $rowToPlainText[$urlRow] = $wrapped[0]
                            $rowToURL[$urlRow]       = $url
                        }
                    }
                    else {
                        $expanded = Expand-ColourCodes $line
                        $wrapped  = Wrap-IndentedText -Text $expanded -Indent 4 -MaxWidth $lineWidth
                        foreach ($row in $wrapped) { Write-AndCount $row }
                    }
                }
            } else {
                $wrapped = Wrap-IndentedText -Text "(No description provided.)" -Indent 4 -MaxWidth $lineWidth
                foreach ($row in $wrapped) { Write-AndCount "$Gy$row$Rst" }
            }

            if ($isActionable) {
                $optEndRow = $script:CurrentRowPosition - 1
                for ($rowNum = $optStartRow; $rowNum -le $optEndRow; $rowNum++) {
                    $rowToOption[$rowNum] = "$index"
                }
                $script:RowToOption = $rowToOption   # live update so queued clicks already resolve
                $index++

                # Drain queued mouse events looking for a click on an already-rendered row.
                # Mouse-move events pile up before the click, so we loop past them.
                # Non-mouse events (keyboard etc.) are left in the buffer untouched.
                if ($hasPeek -and $null -ne $hStdinEarly) {
                    $keepLooking = $true
                    while ($keepLooking) {
                        $pk = New-Object WinFixIT.INPUT_RECORD; $pkRead = [uint32]0
                        if (-not ([WinFixIT.MouseInput]::PeekConsoleInput($hStdinEarly, [ref]$pk, 1, [ref]$pkRead) -and $pkRead -gt 0)) { break }
                        if ($pk.EventType -eq [WinFixIT.MouseInput]::MOUSE_EVENT_TYPE) {
                            # Consume this mouse event (move, wheel, or click)
                            $dc = New-Object WinFixIT.INPUT_RECORD; $dr = [uint32]0
                            [WinFixIT.MouseInput]::ReadConsoleInput($hStdinEarly, [ref]$dc, 1, [ref]$dr) | Out-Null
                            if ($dc.MouseEvent.dwEventFlags -eq 0 -and
                                ($dc.MouseEvent.dwButtonState -band [WinFixIT.MouseInput]::FROM_LEFT_1ST_BUTTON_PRESSED)) {
                                $cr = $dc.MouseEvent.dwMousePosition.Y - $script:ScreenStartBufferRow
                                if ($rowToOption.ContainsKey($cr)) {
                                    $earlyChoice = $rowToOption[$cr]
                                    $keepLooking = $false
                                }
                            }
                        } else {
                            $keepLooking = $false   # keyboard/other — leave in buffer, stop searching
                        }
                    }
                }
                if ($null -ne $earlyChoice) { break }
            }
        }

        if ($null -ne $earlyChoice) {
            # User clicked a visible row before the menu finished rendering — skip the prompt
            $script:RowToOption    = $null
            $script:RowToHeading   = $null
            $script:RowToPlainText = $null
            $script:RowToURL       = $null
            $choice = $earlyChoice
        }
        else {
            if ($actionableOptions.Count -gt 1) {
                $promptText = "$Y CLICK an OPTION, Enter (1-$($index-1)), Contents or <Return>"
                $validChoicesForPrompt = @(1..($index-1) | ForEach-Object { "$_" }) + 'CONTENTS'
            }
            else {
                $promptText = "$Y Please Enter - Contents or <Return>"
                $validChoicesForPrompt = @('CONTENTS')
            }

            # At the LIBRARY root of a standalone session, <Return> has nowhere to go - offer EXIT instead
            if ($NoCallerToReturnTo -and $isTreeRoot) {
                $promptText += ", or EXIT"
                $validChoicesForPrompt += 'EXIT'
            }

            Write-AndCount ""       # PROMPT Row
            Write-AndCount ""       # MESSAGE Row
            Write-AndCount ""       # BUFFER ROW

            $PromptRowInBuffer = [Console]::CursorTop - 2
            Write-Host $Up2 -NoNewline

            $script:ScrollToTopAfterReposition = $true
            $script:RowToOption    = $rowToOption
            $script:RowToHeading   = $rowToHeading
            $script:RowToPlainText = $rowToPlainText
            $script:RowToURL       = $rowToURL
            $choice = Prompt-ForUserChoice `
                -PromptRows @($promptText) `
                -PromptStartRow $PromptRowInBuffer `
                -ValidChoices $validChoicesForPrompt `
                -SuppressChoices `
                -ReturnKey_Pressed '<Return>' `
                -MessageToBeDisplayedBelowPrompt $MessageReturned
            $script:RowToOption    = $null
            $script:RowToHeading   = $null
            $script:RowToPlainText = $null
            $script:RowToURL       = $null
        }

        if ($choice -eq '<Return>') {
            if ($script:ReturnAddress) {
                $addr = $script:ReturnAddress
                $script:ReturnAddress = ""
                Display-MenuFor -FolderPath $addr -LibraryRoot $LibraryRoot -NoCallerToReturnTo:$NoCallerToReturnTo
                return
            }

            # Nothing above us to return to and no enclosing loop will catch this - just
            # unwind out to Launch-Menu.ps1, which closes the window (no in-place prompt
            # redraw here, which is what was throwing off the row-position tracking).
            return
        }

        if ($choice -eq 'EXIT' -and $NoCallerToReturnTo -and $isTreeRoot) {
            Write-Host ""
            Write-Host "$Gy Closing... $Rst"
            return
        }

        if ($choice -ieq 'CONTENTS') {
            $script:ReturnAddress = $FolderPath
            Show-LibraryContents -LibraryRoot $LibraryRoot -NoCallerToReturnTo:$NoCallerToReturnTo
            continue
        }

        # Match by number against actionable options
        $actionableList = @($options | Where-Object { $_.Type -ne 'InfoOnly' })
        $selected = $null
        $asInt = 0
        if ([int]::TryParse($choice, [ref]$asInt)) {
            if ($asInt -ge 1 -and $asInt -le $actionableList.Count) {
                $selected = $actionableList[$asInt - 1]
            }
        }
        if (-not $selected) {
            $MessageReturned = "$R No match for '$choice' $Rst"
            continue
        }

        # Sub-Menu
        if ($selected.Type -eq 'SubMenu') {
            $MessageReturned = ""
            Display-MenuFor $selected.Path -LibraryRoot $LibraryRoot -NoCallerToReturnTo:$NoCallerToReturnTo
            continue
        }

        # Actionable
        if ($selected.Type -eq 'Actionable') {

            if (-not (Test-Path -LiteralPath $selected.StartPath)) {
                Write-Host "$R Start.bat not found for '$($selected.Name)'.$Rst"
                cmd /c pause
                continue
            }

            if ($localDEBUG_Mode) {
                Write-Host ""
                Write-Host "==============================================================="
                Write-Host "DEBUG: About to launch ACTIONABLE item"
                Write-Host "DEBUG: Selected.Name      = $($selected.Name)"
                Write-Host "DEBUG: Selected.Path      = $($selected.Path)"
                Write-Host "DEBUG: Selected.Type      = $($selected.Type)"
                Write-Host "DEBUG: Selected.StartPath = $($selected.StartPath)"
                Write-Host "==============================================================="
                Write-Host ""
                Pause
            }

            try {
                $MessageReturned = RUN-Installer `
                    -Pathname $selected.StartPath `
                    -LibraryRoot $LibraryRoot
            }
            catch {
                $wfErrLog = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'Logs\WinFixIT-errors.log'
                Add-Content -Path $wfErrLog -Value "$(Get-Date) | $($selected.Name) | $($_.Exception.Message)"
                $MessageReturned `
                    = "$R Error running installer for '$($selected.Name)'. See Logs\WinFixIT-errors.log on the USB.$Rst"
            }

            continue

        } # End of - if ($selected.Type -eq 'Actionable')

    } # End of - while Main Loop

} # END of - function Display-MenuFor


# ====================================================================================================
function RUN-Installer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Pathname,
        # Needed only for "OPEN <file> -ENCRYPTED" lines (Course Notes) - it's
        # passed through so the OPEN handler below can locate CourseProtection.ps1
        # (which itself looks for the trigger file in WinFixIT\Support, not
        # anywhere near here). Both call sites in Display-MenuFor/
        # Show-LibraryContents already have this in scope and pass it through;
        # ordinary RUN/COPY/OPEN Start.bat files never need it.
        [string]$LibraryRoot
    )
#
# This function:
#    - accepts a Pathname in one of the following forms:
#          • Full path to a Start.bat file
#          • Relative path to a Start.bat file
#          • Path to a folder containing Start.bat (Start.bat is assumed)  [TBD if needed]
#
# Start.bat may take any of these forms:
#
#    RUN setup.exe
#    RUN installer.exe /SILENT /NORESTART
#    RUN "SubFolder\My Installer.exe" /quiet
#    RUN setup.exe /S /NORESTART WAIT
#    RUN setup.exe WAIT /S /NORESTART
#
#    COPY file.txt "\Temp"
#    COPY "My File.txt" "\Program Files\MyApp"
#    COPY "Drivers\Audio\setup.inf" "\Windows\INF"
#    COPY rufus-4.13p.exe WAIT "\Tools\Rufus"
#    COPY config.json "\MyApp\Config"
#
#    OPEN File.txt                                      Uses Notepad.exe
#    OPEN "Windows TroubleShooting (Offline).pdf"       Uses SumatraPDF.exs
#    OPEN "Windows TroubleShooting (Offline).doc"       Used WORD if available. otherwise Wordpad.exe
#    OPEN "Windows TroubleShooting (Offline).docs"      Used WORD if available. otherwise Wordpad.exe#
#    OPEN "<SubFolder>\<filename>"                      if file is in SubFolder
#    OPEN "01 - Basic Word.encrypted"                    Course Notes: ANY ".encrypted" file is
#                                                        always treated as an encrypted Course Note -
#                                                        a made-up extension used for nothing else
#                                                        anywhere in WinFixIT, so the extension alone
#                                                        is the signal, no separate flag needed.
#                                                        Decrypts in memory and shows in the
#                                                        locked-down PDFium viewer instead of handing
#                                                        the file to Windows (see CourseProtection\
#                                                        PrivateMechanism-EXPLAINED.md - a plain
#                                                        .encrypted file has no file association
#                                                        anyway, and these files are also meant to be
#                                                        marked Hidden, which is rather the point).
#                                                        Needs -LibraryRoot
#                                                        passed to RUN-Installer, which both call
#                                                        sites already do.
#
#    NOTE:
#       • COPY destinations MUST be absolute or system-rooted.
#       • A leading "\" means "use the actual SystemDrive".
#       • If a technician writes "C:\Something", the "C:" is replaced with the real SystemDrive.
#       • Relative paths (e.g., "Tools", "MyApp\Config") are NOT allowed and will be rejected.
#
# It then:
#    1. Reads the first line of Start.bat
#    2. Tokenizes the line with full quote support
#    3. Validates that the first token is either RUN or COPY
#
#    If RUN:
#        • The executable path must exist relative to the Start.bat folder (USB)
#        • WAIT may appear anywhere and is optional
#        • Any remaining tokens become the argument string
#
#    If COPY:
#        • The source file must exist in the Start.bat folder (USB)
#        • The destination folder MUST resolve to the SystemDrive
#        • A leading "\" is interpreted as "<SystemDrive>\..."
#        • A drive letter (e.g., "C:\") is replaced with the actual SystemDrive
#        • Relative paths are invalid and rejected
#        • Any WAIT token is ignored
#        • COPY must have exactly two meaningful tokens: <SourceFile> <DestinationFolder>
#
#    IF OPEN
#        • The executable path must exist relative to the Start.bat folder (USB)
#
#    4. If any validation fails:
#           • A formatted ERROR message is written to the status row
#           • No execution occurs
#
#    5. If validation succeeds:
#           • COPY performs a file copy into the resolved SystemDrive destination
#           • RUN launches the executable with optional arguments and optional WAIT
#           • A formatted SUCCESS message is written to the status row
#
#    Application Name:
#           • ALWAYS taken from the folder name containing Start.bat.
#
#    Status Row:
#           • Messages are written to $script:CurrentRowPosition + 1
#           • Cursor is restored to $script:LastPromptRowStartPosition, column 0
#
# ====================================================================================================

    $localDEBUG_Mode = $false

    $ErrorFlagged = $false
    $ErrorText    = ""
    $Directive    = ""
    $FullExe      = ""
    $Arguments    = ""
    $WaitFlag     = $false
    $FullSource   = ""
    $DestFolder   = ""
    $AppName      = ""

    # ------------------------------------------------------------
    # BASIC PATH / APPNAME RESOLUTION
    # ------------------------------------------------------------
    if (-not (Test-Path $Pathname)) {
        $base    = Split-Path -Path $Pathname -Parent
        $AppName = Split-Path -Path $base -Leaf
        $ErrorText = "ERROR - $AppName NOT Installed, Start.bat not found"
        return $ErrorText
    }
    $base    = Split-Path -Path $Pathname -Parent
    $AppName = Split-Path -Path $base -Leaf

    # ------------------------------------------------------------
    # VALIDATION BLOCK (NO EXCEPTIONS)
    # ------------------------------------------------------------
    If ($localDEBUG_Mode) {
        Write-Host "[DEBUG] RUN-Installer - VALIDATION BLOCK"
    }
    $line = Get-Content -Path $Pathname | Where-Object { $_.Trim() -ne "" } | Select-Object -First 1
    $line = $line.Replace([char]0, '\')

    # Check Start.bat was not Empty
    if (-not $line) {
        return "ERROR - $AppName NOT Installed, Start.bat is empty or missing a valid directive"
    }
    $line = $line.Trim()


    # If Start.bat does NOT begin with RUN, COPY or OPEN→ execute Start.bat directly
    if ($line -notmatch '^(?i)(RUN|COPY|OPEN)\b') {

        # Execute Start.bat as-is
        Start-Process -FilePath $Pathname -Wait

        # Success message consistent with your UI style
        return "$W SUCCESS: $AppName executed$Rst"
    }
    if (-not $ErrorFlagged) {
        $tokens = [System.Management.Automation.PSParser]::Tokenize($line, [ref]$null) |
            Where-Object { $_.Type -in 'Command','String','CommandArgument' } |
            Select-Object -ExpandProperty Content

        if ($tokens.Count -lt 1) {
            $ErrorFlagged = $true
            $ErrorText    = "ERROR - $AppName NOT Installed, unable to parse Start.bat line"
        }
    }
    if (-not $ErrorFlagged) {
        $Directive = $tokens[0].ToString().ToUpperInvariant()

        if ($Directive -notin @('RUN','COPY','OPEN')) {
            $ErrorFlagged = $true
            $ErrorText    = "ERROR - Start.Bat does NOT contain RUN, COPY or OPEN Command"
        }
    }
    # ------------------------------------------------------------
    # VALIDATE RUN
    # ------------------------------------------------------------
    if (-not $ErrorFlagged -and $Directive -eq 'RUN') {

        if ($tokens.Count -lt 2) {
            $ErrorFlagged = $true
            $ErrorText    = "ERROR - $AppName NOT Installed, RUN requires: RUN <ExecutablePath> [Arguments] [WAIT]"
        }
        else {
            $ExePath = $tokens[1]
 
            # First try relative to Start.bat folder
            $FullExe = Join-Path $base $ExePath

            if (-not (Test-Path $FullExe)) {

                # If relative failed, try absolute path
                if (Test-Path $ExePath) {
                    $FullExe = $ExePath
                }
                else {
                    $ErrorFlagged = $true
                    $ErrorText    = "ERROR - $AppName NOT Installed, executable not found"
                }
            }

            if (-not $ErrorFlagged) {
                if ($tokens -contains 'WAIT') {
                    $WaitFlag = $true
                    $tokens   = $tokens | Where-Object { $_ -ne 'WAIT' }
                }

                if ($tokens.Count -gt 2) {
                    $Arguments = ($tokens[2..($tokens.Count-1)]) -join ' '
                }
            }
        }
    } # END of - Validate RUN
 
    # ------------------------------------------------------------
    # Validate COPY
    # ------------------------------------------------------------
    if (-not $ErrorFlagged -and $Directive -eq 'COPY') {

        if ($tokens.Count -lt 3) {
            $ErrorFlagged = $true
            $ErrorText    = "ERROR - $AppName NOT Installed, COPY requires: COPY <SourceFile> <DestinationFolder>"
        }
        elseif ($tokens.Count -gt 3) {
            $ErrorFlagged = $true
            $ErrorText    = "ERROR - $AppName NOT Installed, COPY has too many arguments"
        }
        else {
            $SourceFile = $tokens[1]
            $DestFolder = $tokens[2]

            $FullSource = Join-Path $base $SourceFile
            $SourceFolder = Split-Path $FullSource -Leaf

            # Allow source to be a FILE or a FOLDER
            if (-not (Test-Path -LiteralPath $FullSource)) {
                $ErrorFlagged = $true
                $ErrorText    = "ERROR - $SourceFolder NOT Copied to $DestFolder, source missing"
            }

            if (-not $ErrorFlagged) {
                # ------------------------------------------------------------
                # RESOLVE DESTINATION FOLDER (SYSTEM DRIVE RULES)
                # ------------------------------------------------------------

                # 1. Drive letter form (C:\Something)
                if ($DestFolder -match '^[A-Za-z]:\\') {
                    $DestFolder = $DestFolder.Substring(2)
                    $DestFolder = Join-Path $env:SystemDrive $DestFolder.TrimStart("\")
                }
                # 2. System-rooted form (\Something)
                elseif ($DestFolder.StartsWith("\")) {
                    $DestFolder = Join-Path $env:SystemDrive $DestFolder.TrimStart("\")
                }
                # 3. Relative path → INVALID
                else {
                    $ErrorFlagged = $true
                    $ErrorText    = "ERROR - $SourceFolder NOT Copied to $DestFolder, destination must be absolute or system-rooted"
                }
            }
            if (-not $ErrorFlagged -and -not (Test-Path $DestFolder)) {
                New-Item -ItemType Directory -Path $DestFolder -Force | Out-Null
            }
        }

    } # END of - VALIDATE COPY

    # ------------------------------------------------------------
    # VALIDATE OPEN
    # ------------------------------------------------------------
    if (-not $ErrorFlagged -and $Directive -eq 'OPEN') {

        if ($tokens.Count -lt 2) {
            $ErrorFlagged = $true
            $ErrorText    = "ERROR - $AppName NOT Installed, OPEN requires: OPEN <DocumentPath>"
        }
        else {
            # Use regex to extract path — PSParser mangles backslash sequences like \0 inside quoted strings
            if ($line -match '(?i)^OPEN\s+"([^"]+)"') {
                $DocPath = $Matches[1]
            } elseif ($line -match '(?i)^OPEN\s+(\S+)') {
                $DocPath = $Matches[1]
            } else {
                $DocPath = $tokens[1]
            }

            # .encrypted is a made-up extension used for nothing else
            # anywhere in WinFixIT - it exists only so Course Notes can be
            # encrypted - so the extension alone is treated as "this is an
            # encrypted Course Note", no separate flag needed on the OPEN
            # line.
            $IsEncrypted = [System.IO.Path]::GetExtension($DocPath) -ieq '.encrypted'

            # Try relative to Start.bat folder, normalising any .. references
            $FullDoc = [System.IO.Path]::GetFullPath((Join-Path $base $DocPath))

            if (-not (Test-Path $FullDoc)) {

                # Try absolute path
                if (Test-Path $DocPath) {
                    $FullDoc = $DocPath
                }
                else {
                    $ErrorFlagged = $true
                    $ErrorText    = "ERROR - $AppName NOT Installed, document not found"
                }
            }

            if (-not $ErrorFlagged -and $IsEncrypted -and -not $LibraryRoot) {
                $ErrorFlagged = $true
                $ErrorText    = "ERROR - $AppName NOT Installed, OPENing an encrypted Course Note needs a LibraryRoot"
            }
        }
    } # END of -  VALIDATE OPEN



    # ------------------------------------------------------------
    # IF ANY VALIDATION FAILED, set $ErrorText
    # ------------------------------------------------------------

    If ($ErrorFlagged) {

        if (-not $ErrorText) {
            $ErrorText = "ERROR - $AppName NOT Installed, unknown validation failure"
        }
        # Insert colour codes: $R at start, $Rst before first comma
        $firstComma = $ErrorText.IndexOf(',')
        if ($firstComma -gt 0) {
            $ErrorText = "$R " + $ErrorText.Insert($firstComma, "$Rst")
        }
        else {
            # No comma found — colour entire message
            $ErrorText = "$R $ErrorText$Rst"
        }
        return $ErrorText

    } # END of - $ErrorFlagged


    # ------------------------------------------------------------
    # EXECUTION BLOCK (ONLY IF VALIDATION PASSED)
    # ------------------------------------------------------------
    If ( -not $ErrorFlagged) {

        if ($Directive -eq 'COPY') {

            # ------------------------------------------------------------
            # DETECT FOLDER vs FILE
            # ------------------------------------------------------------
            if (Test-Path -LiteralPath $FullSource -PathType Container) {

                # ------------------------------------------------------------
                # FOLDER COPY (PACKAGE MODE)
                # Copy CONTENTS of the folder recursively into DestFolder
                # ------------------------------------------------------------
                if ($localDEBUG_Mode) {
                    Write-Host "[DEBUG] COPY (Folder)"
                    Write-Host "  FullSource : $FullSource"
                    Write-Host "  DestFolder : $DestFolder"
                }

                # Normalise destination path
                $resolved = Resolve-Path $DestFolder -ErrorAction SilentlyContinue
                $DestFolder = if ($resolved) { $resolved.Path } else { $DestFolder }

                # Extract the sub-folder name
                $SubFolder = Split-Path $DestFolder -Leaf

                # System folder roots
                $SystemRoots = @('Program Files', 'Program Files (x86)', 'Windows', 'Users', '')

                # If destination is a system folder root,
                if ($SystemRoots -contains $SubFolder) {
                    $DestFolder = Join-Path $DestFolder $SourceFolder
                    $SubFolder = $SourceFolder
                }

                # Ensure destination folder exists
                if (-not (Test-Path -LiteralPath $DestFolder)) {
                    New-Item -ItemType Directory -Path $DestFolder -Force | Out-Null
                }
                # Enumerate existing contents (force array so directories count)
                $existing = @(Get-ChildItem -LiteralPath $DestFolder -Force -ErrorAction SilentlyContinue)

                # If folder exists and matches package name → CLEAR IT
                if ($existing.Count -gt 0 -and ($SubFolder -eq $AppName)) {
                    Remove-Item -LiteralPath (Join-Path $DestFolder '*') -Recurse -Force -ErrorAction Stop
                }
                # Perform the copy
                Copy-Item (Join-Path $FullSource '*') $DestFolder -Recurse -Force

                # Sanity check: destination must contain something
                $destItems = Get-ChildItem -LiteralPath $DestFolder -Recurse -ErrorAction SilentlyContinue
                if (-not $destItems) {
                    $ErrorText = "$R ERROR - $AppName NOT Copied to $DestFolder$Rst, destination empty after folder copy"
                    return $ErrorText
                }

                # Success for folder copy (use REAL source folder, not menu name)
                $SourceFolder = Split-Path $FullSource -Leaf
                $SuccessText = "$W SUCCESS: $SourceFolder COPIED to $DestFolder $Rst"
                return $SuccessText

            }

            # ------------------------------------------------------------
            # FILE COPY (EXISTING LOGIC)
            # ------------------------------------------------------------
            $Leaf     = Split-Path $FullSource -Leaf
            $DestFile = Join-Path $DestFolder $Leaf

            Copy-Item $FullSource $DestFile -Force

            if (-not (Test-Path -LiteralPath $DestFile)) {
                $ErrorText = "$R ERROR - $Leaf NOT Copied to $DestFolder$Rst, destination file missing"
                return $ErrorText
            }

            $srcInfo  = Get-Item -LiteralPath $FullSource
            $destInfo = Get-Item -LiteralPath $DestFile

            if ($srcInfo.Length -ne $destInfo.Length) {
                $ErrorText = "$R ERROR - $Leaf NOT Copied to $DestFolder$Rst, size mismatch"
                return $ErrorText
            }

            # Create/replace Start Menu shortcut for .exe files
            if ([System.IO.Path]::GetExtension($DestFile) -ieq '.exe') {
                $ShortcutPath = "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\$AppName.lnk"
                $wsh          = New-Object -ComObject WScript.Shell
                $shortcut     = $wsh.CreateShortcut($ShortcutPath)
                $shortcut.TargetPath       = $DestFile
                $shortcut.WorkingDirectory = $DestFolder
                $shortcut.Description      = $AppName
                $shortcut.IconLocation     = "$DestFile,0"
                $shortcut.Save()
            }

            $SuccessText = "$W SUCCESS: $Leaf COPIED to $DestFolder $Rst"
            return $SuccessText

        } # END of - COPY

        # ------------------------------------------------------------
        # EXECUTE RUN
        # ------------------------------------------------------------
        if ($Directive -eq 'RUN') {
            $exeDir = Split-Path $FullExe -Parent
            if ($WaitFlag) {
                Start-Process -FilePath $FullExe -ArgumentList $Arguments -WorkingDirectory $exeDir -Wait
            }
            else {
                Start-Process -FilePath $FullExe -ArgumentList $Arguments -WorkingDirectory $exeDir
            }

            $SuccessText = "$W $AppName Installer Finished.  PLEASE: check SUCCESS/FAILURE yourself. $Rst"
            return $SuccessText

        } # END of - RUN

        # ------------------------------------------------------------
        # EXECUTE OPEN  (Modern Windows-native version)
        # ------------------------------------------------------------
        if ($Directive -eq 'OPEN') {

            if ($IsEncrypted) {
                try {
                    . (Join-Path $PSScriptRoot 'CourseProtection\CourseProtection.ps1')

                    # Trigger file (Switch.dat) lives in WinFixIT\Support - a folder
                    # already full of unrelated driver files/scripts - NOT in
                    # CourseProtection and NOT in the visible Courses tree next to
                    # OPEN - On2it Software Courses.bat. Nothing about its name or
                    # location connects it to Course Notes for a casual browser.
                    # Brian, 2026-08-10: "I don't want to hide it anywhere associated
                    # with Courses/Protection/Key."
                    $triggerFolder = Join-Path $PSScriptRoot 'Support'

                    $courseKey = Get-CourseDecryptionKey -UsbTriggerFolder $triggerFolder
                    if (-not $courseKey) {
                        return "$R ERROR - $AppName NOT Opened, could not unlock this Course Note on this PC$Rst"
                    }

                    Open-EncryptedCourseNote -EncryptedPdfPath $FullDoc -Key $courseKey -UsbTriggerFolder $triggerFolder -TitleBarText $AppName
                    # Open-EncryptedCourseNote is fire-and-forget (launches a
                    # hidden background process and returns immediately - see
                    # its own header comment for why it can't -Wait). So this
                    # can only ever confirm the LAUNCH succeeded, never that
                    # the viewer actually displayed anything - claiming
                    # "SUCCESS" here was misleading. Brian, 2026-08-17 (Pams-PC
                    # test): "I don't like it Displaying SUCCESS, unless we
                    # KNOW it has succeeded." Matches the existing honest
                    # wording already used for the same class of problem a few
                    # lines above (RUN's installer message).
                    return "$W $AppName launching - PLEASE: check it actually opened.$Rst"
                }
                catch {
                    return "$R ERROR - Unable to open encrypted document: $($_.Exception.Message) $Rst"
                }
            }

            try {
                Start-Process -FilePath $FullDoc
                return "$W SUCCESS: $AppName opened$Rst"
            }
            catch {
                return "$R ERROR - Unable to open document: $FullDoc $Rst"
            }
        } # END of - OPEN

    } # END of -not $ErrorFlagged) 

} # END of - Function RUN-Installer


# ====================================================================================================
function Build-LibraryContents {
# ====================================================================================================
#  Recursively walks $RootPath, collecting every folder that contains either
#  'Menu Introduction.txt' (SubMenu) or 'Option Description.txt' (Actionable/InfoOnly).
#  Returns a flat array of PSCustomObjects with: Number, Name, Path, Type, Depth.
#  Numbers start at 0 — Show-LibraryContents assigns them after the full list is built.
# ====================================================================================================
    param(
        [Parameter(Mandatory=$true)][string]$RootPath,
        [int]$Depth = 0
    )

    $result = @()

    $subFolders = Get-ChildItem -Path $RootPath -Directory |
        Where-Object { $_.Name -ne 'Windows' } |
        Sort-Object CreationTime

    foreach ($sf in $subFolders) {
        $menuIntro = Join-Path $sf.FullName 'Menu Introduction.txt'
        $optDesc   = Join-Path $sf.FullName 'Option Description.txt'
        $startBat  = Join-Path $sf.FullName 'Start.bat'

        $hasMenu   = Test-Path -LiteralPath $menuIntro
        $hasOption = Test-Path -LiteralPath $optDesc

        if (-not $hasMenu -and -not $hasOption) { continue }

        $type = if     ($hasMenu)                          { 'SubMenu'     }
                elseif (Test-Path -LiteralPath $startBat)  { 'Actionable'  }
                else                                        { 'InfoOnly'    }

        $result += [PSCustomObject]@{
            Number = 0
            Name   = $sf.Name
            Path   = $sf.FullName
            Type   = $type
            Depth  = $Depth
        }

        if ($hasMenu) {
            $result += Build-LibraryContents -RootPath $sf.FullName -Depth ($Depth + 1)
        }
    }

    return $result

} # END of - function Build-LibraryContents


# ====================================================================================================
function Show-LibraryContents {
# ====================================================================================================
#  Displays the LIBRARY - Contents page: a flat, indented, numbered list of every Menu and Option
#  in the LIBRARY tree.  The user can jump directly to any item by clicking it or entering its number.
#  Pressing <Return> jumps back to $script:ReturnAddress (set by the caller) and clears it.
# ====================================================================================================
    param(
        [Parameter(Mandatory=$true)][string]$LibraryRoot,
        [switch]$NoCallerToReturnTo
    )

    # Build the list once — folder structure does not change mid-session
    $allItems = @(Build-LibraryContents -RootPath $LibraryRoot)

    # Assign sequential numbers to navigable items (SubMenu and Actionable only)
    $num = 1
    foreach ($item in $allItems) {
        if ($item.Type -ne 'InfoOnly') { $item.Number = $num++ }
    }
    $maxNum = $num - 1

    $statusMessage = ""

    while ($true) {

        $script:CurrentRowPosition = 0
        Clear-Host
        # Windows Terminal silently collapses the buffer height back down to the window
        # height on every Clear-Host after the first one, discarding whatever was scrolled
        # past (not just hiding it) - re-assert it here, every redraw, not just once at
        # session start, or long menus lose their "row 0" and all row-tracking breaks.
        $bs = $Host.UI.RawUI.BufferSize
        if ($bs.Height -lt 500) { $bs.Height = 500; $Host.UI.RawUI.BufferSize = $bs }
        $script:ScreenStartBufferRow = [Console]::CursorTop

        $lineWidth = $Host.UI.RawUI.BufferSize.Width

        # Header
        $headerText    = "LIBRARY - Contents"
        $padding       = [math]::Max(0, ($lineWidth - $headerText.Length) / 2)
        $centredHeader = (' ' * [math]::Floor($padding)) + $headerText

        Write-Host ("$C" + ('=' * $lineWidth) + "$Rst")
        Write-Host "$Y$centredHeader$Rst"
        Write-Host ("$C" + ('=' * $lineWidth) + "$Rst")
        $script:CurrentRowPosition += 3

        Write-AndCount ""
        Write-AndCount " ${W}CLICK or enter a Menu or Option number or to jump directly there.$Rst"
        Write-AndCount " ${Gy}The un-numbered rows are the Information only Options within each Menu.$Rst"
        Write-AndCount " ${Gy}Press <Return> to go back to where you came from.$Rst"
        Write-AndCount ""

        # Contents list — track which buffer row each clickable item lands on
        $rowToOption    = @{}
        $rowToHeading   = @{}
        $rowToPlainText = @{}
        foreach ($item in $allItems) {
            $indent = ' ' * (3 + $item.Depth * 3)
            if ($item.Type -eq 'InfoOnly') {
                Write-AndCount "$Gy$indent$($item.Name)$Rst"
            }
            else {
                $itemRow = $script:CurrentRowPosition
                Write-AndCount "$Y$indent$($item.Number). $($item.Name)$Rst"
                $rowToOption[$itemRow]  = "$($item.Number)"
                $rowToHeading[$itemRow] = @{ Prefix = "$indent$($item.Number). "; Name = $item.Name }
            }
        }

        Write-AndCount ""   # PROMPT Row
        Write-AndCount ""   # MESSAGE Row
        Write-AndCount ""   # BUFFER Row

        $PromptRowInBuffer = [Console]::CursorTop - 2
        Write-Host $Up2 -NoNewline

        $promptText = "$Y CLICK AN OPTION, Enter (1-$maxNum), or <Return>"
        $validChoicesForPrompt = if ($maxNum -ge 1) { 1..$maxNum | ForEach-Object { "$_" } } else { @() }

        $script:ScrollToTopAfterReposition = $true
        $script:RowToOption    = $rowToOption
        $script:RowToHeading   = $rowToHeading
        $script:RowToPlainText = $rowToPlainText
        $script:RowToURL       = $null
        $choice = Prompt-ForUserChoice `
            -PromptRows @($promptText) `
            -PromptStartRow $PromptRowInBuffer `
            -ValidChoices $validChoicesForPrompt `
            -SuppressChoices `
            -ReturnKey_Pressed '<Return>' `
            -MessageToBeDisplayedBelowPrompt $statusMessage
        $script:RowToOption    = $null
        $script:RowToHeading   = $null
        $script:RowToPlainText = $null
        $script:RowToURL       = $null

        $statusMessage = ""

        # Return — jump straight back to where the user came from
        if ($choice -eq '<Return>') {
            if ($script:ReturnAddress) {
                $addr = $script:ReturnAddress
                $script:ReturnAddress = ""
                Display-MenuFor -FolderPath $addr -LibraryRoot $LibraryRoot -NoCallerToReturnTo:$NoCallerToReturnTo
            }
            return
        }

        # Match by number
        $target = $null
        $asInt  = 0
        if ([int]::TryParse($choice, [ref]$asInt)) {
            $target = $allItems | Where-Object { $_.Number -eq $asInt } | Select-Object -First 1
        }

        if (-not $target) {
            $statusMessage = "$R No match for '$choice' $Rst"
            continue
        }

        # Navigate to SubMenu — user can explore; Return from inside will jump home
        if ($target.Type -eq 'SubMenu') {
            Display-MenuFor -FolderPath $target.Path -LibraryRoot $LibraryRoot -NoCallerToReturnTo:$NoCallerToReturnTo
            # If ReturnAddress was consumed by a Return press inside, exit Contents too
            if (-not $script:ReturnAddress) { return }
            continue
        }

        # Run Actionable — then jump straight back to ReturnAddress
        if ($target.Type -eq 'Actionable') {
            try {
                RUN-Installer -Pathname (Join-Path $target.Path 'Start.bat') -LibraryRoot $LibraryRoot | Out-Null
            }
            catch {
                $statusMessage = "$R Error running '$($target.Name)': $($_.Exception.Message) $Rst"
                continue
            }
            if ($script:ReturnAddress) {
                $addr = $script:ReturnAddress
                $script:ReturnAddress = ""
                Display-MenuFor -FolderPath $addr -LibraryRoot $LibraryRoot -NoCallerToReturnTo:$NoCallerToReturnTo
            }
            return
        }

    } # End while

} # END of - function Show-LibraryContents


# ====================================================================================================
function Wrap-IndentedText {
    param(
        [string]$Text,
        [int]$Indent = 4,
        [int]$MaxWidth = 100
    )

    # If the text is visually blank, return a real blank line
    if ($Text -replace '[\p{Z}\p{C}\s]', '' -eq '') {
        return @('')
    }

    # Build indentation prefix
    $prefix = ' ' * $Indent

    # Effective wrapping width (subtract indentation)
    $wrapWidth = $MaxWidth - $Indent

    # 1. Expand colour codes (produces ANSI)
    $expanded = Expand-ColourCodes $Text

    # 2. Strip ONLY the bracketed part of ANSI sequences (safe, no \x1B)
    $visible = $expanded -replace '\[[0-9;]*m'

    # If the line fits, return it as-is — preserves multiple spaces for column alignment
    if ($visible.Length -le $wrapWidth) {
        return @("$prefix$expanded")
    }

    # 3. Split visible text into words (only reached when line exceeds wrap width)
    $visibleWords  = $visible  -split '\s+'
    $expandedWords = $expanded -split '\s+'

    $lines = @()
    $currentVisible  = ""
    $currentExpanded = ""

    for ($i = 0; $i -lt $visibleWords.Count; $i++) {
        $vWord = $visibleWords[$i]
        $eWord = $expandedWords[$i]

        if ($currentVisible.Length + $vWord.Length + 1 -gt $wrapWidth) {
            $lines += "$prefix$currentExpanded"
            $currentVisible  = $vWord
            $currentExpanded = $eWord
        }
        else {
            if ($currentVisible -eq "") {
                $currentVisible  = $vWord
                $currentExpanded = $eWord
            }
            else {
                $currentVisible  += " $vWord"
                $currentExpanded += " $eWord"
            }
        }
    }

    if ($currentExpanded -ne "") {
        $lines += "$prefix$currentExpanded"
    }

    return $lines

}   # END of - function Wrap-IndentedText


# ======================================================================================
function Expand-ColourCodes {
# ======================================================================================
    param([string]$Text)

    # LONGEST TOKENS FIRST
    $Text = $Text.Replace('$Rst', $Rst)
    $Text = $Text.Replace('$Gy',  $Gy)
    $Text = $Text.Replace('$W',   $W)
    $Text = $Text.Replace('$Y',   $Y)
    $Text = $Text.Replace('$R',   $R)

    return $Text
}


# =============================================================================================
function Write-AndCount {
    param([string]$Text)

    # Emit the text
    Write-Host $Text

    # Increment by the number of logical lines printed (handles embedded newlines)
    $script:CurrentRowPosition += ($Text -split "(`r`n|`n)").Count
}

# Initialise ReturnAddress for LIBRARY Contents navigation
if ($null -eq $script:ReturnAddress) { $script:ReturnAddress = "" }