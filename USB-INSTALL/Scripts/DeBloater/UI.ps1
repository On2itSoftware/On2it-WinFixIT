# =============================================================================================
# PRO Version switch — set $true to enable PRO features and show PRO-only UI controls
$script:PRO_Version = $false 
# =============================================================================================
function Main-Line {
# PURPOSE:
#   This is the main entry point of the script. It initializes the form, displays it,   
#   and manages the overall flow of the application. 
#   It also sets up a transcript to capture console output for debugging purposes.
#
#   It is called at the end of  Win11-DeBloater.ps1, after Winn11-DEBLoater-UI.ps1 has been Dot-SOurced

    # --- Begin transcript to capture all console output ---
    $logsFolder = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'Logs'
    if (-not (Test-Path $logsFolder)) { New-Item $logsFolder -ItemType Directory -Force | Out-Null }
    $logPath = Join-Path $logsFolder 'DeBloater-DEBUG-output.txt'
    if (Test-Path $logPath) {
        try {
            Stop-Transcript | Out-Null
        } catch {}
    }
    Start-Transcript -Path $logPath -Append

    # Enable WinForms visual styles BEFORE anything else
    # [void][System.Windows.Forms.Application]::EnableVisualStyles()
    Define-Form
    Display-Form

    Stop-Transcript
    # Wait briefly to ensure transcript file is released
    Start-Sleep -Milliseconds 500
    # Now it is safe to delete the log file
    if (Test-Path $logPath) {
        try {
            Remove-Item $logPath -Force
        } catch {
            Write-Host "[DEBUG] Could not remove debug log: $($_.Exception.Message)"
        }
    }
}
# END of - function Main-Line


# =========================================================================================
function Define-Form {
    # PURPOSE:
    #   This function is responsible for defining the structure and content of the form. 
    #   It reads the form definition from an RTF file, builds the form and its panels,
    #   sets up tooltips, and creates the groups and Options based on the parsed data. 
    
    #   Error handling is included to catch any issues during the form definition process.
    $localDEBUG_Mode = $false

    try {
        Read-FormDefinition
        # DEBUG: Display all group/option definitions and advice after loading, if debug mode is on
        if ($LocalDEBUG_Mode) {
            foreach ($group in $script:groups) {
                Write-Host "[DEBUG] Group: $($group.Name)" -ForegroundColor Yellow
                foreach ($option in $group.Options) {
                    Write-Host "[DEBUG]  Option: $($option.Name)" -ForegroundColor Cyan
                    if ($option.PSObject.Properties["Advice"] -and $option.Advice) {
                        Write-Host "[DEBUG]   Advice (RTF):" -ForegroundColor Green
                        Write-Host $option.Advice -ForegroundColor Green
                    } else {
                        Write-Host "[DEBUG]   No advice found for this option!" -ForegroundColor Red
                    }
                    Pause
                }
            }
        }
        if (-not $script:groups -or $script:groups.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Error: No groups loaded. Check your RTF file or Read-FormDefinition.", "Initialization Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
            return
        }
        Build-FormAndPanels
        if (-not $script:form -or -not $script:panelLeft) {
            [System.Windows.Forms.MessageBox]::Show("Error: Form or panelLeft not initialized.", "Initialization Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
            return
        }
        Setup-ScrollTip
        Create-GroupsAndOptions
        Control-InteractionHandlers
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Exception during form definition: $($_.Exception.Message)", "Initialization Exception", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }
} # END of - function Define-Form


# =======================================================================================
function Read-FormDefinition {
    # PURPOSE : Parse the RTF definition file into structured groups/Options/advice
    #    [GROUP   - Group name] specifies a Group name,
    #    [SELECT  - MODE], where MODE can be ALL or NONE, specifies whether ALL Options in the Group are to be
    #               pre-selected when the Form is first displayed, or not.  
    #    [OPTION  - Remove Outlook for Windows] specifies a particular Recommended OPTION, 
    #               like ‘Remove Outlook for Windows’, for example. followed by ADVICE for that Option.  
    #               If a User un-checks an Option, the Option will change according to the rules spelt out in 
    #               Modify-RecommendedOption, below.  Most of the time the same Advice can still be used 
    #               – with a change of Advice Heading to match the new Option.  
    #               In some circumstances new Advice can be generated with ‘Boiler Plate Text’.  
    #               Less frequently it is necessary to specify specific alternative advice.  With a Block like this:
    #    [ALTERNATIVE - INSTALL Outlook for Windows]  Followed by the alternative Advice for the new Option.    
    
    # Set to $true to enable debug output during parsing (prints each line and internal state changes)
    $LocalDEBUG_Mode = $false
    
    If ($LocalDEBUG_Mode) { Write-Host "[DEBUG] Read-FormDefinition started" -ForegroundColor Yellow }

    # --- Global structures used by UI and logic ---
    $script:AdviceFontSize = 20   # 10pt    

    $script:groups         = @()   # list of group objects
    $script:adviceByGroup  = @{}   # groupName -> RTF advice
    $script:adviceByGroupAndOption = @{}   # OptionText (full) -> RTF advice

    # --- Local parsing state (NOT script-scoped) ---
    $currentGroup        = $null
    $currentOption       = $null
    $currentAltName      = $null   # full text from [ALTERNATIVE - ...]
    $optionAdviceBuffer  = @()     # advice for current OPTION
    $altAdviceBuffer     = @()     # advice for current ALTERNATIVE
    $groupIntro          = @()     # group-level intro
    $startParsing        = $false

    # --- Load RTF file ---
    $rtfPath = Join-Path $PSScriptRoot "UI-GroupsAndOptions.rtf"
    $raw     = Get-Content $rtfPath -Raw -Encoding UTF8

    If ($LocalDEBUG_Mode) { Write-Host "[DEBUG] RTF file loaded, length: $($raw.Length) characters" -ForegroundColor Yellow }

    # --- Iterate through lines ---
    foreach ($line in $raw -split "`r?`n") {
        $rawLine = $line
        # Strip RTF control words for parsing
        $clean = ($line -replace '\\(par|fs\d+|b|ul|i|margt\d+|ansi|rtf1)', '' -replace '[{}]', '').Trim()
        # Wait until first [GROUP - ...]
        if ($clean -match '^\[GROUP - ') { $startParsing = $true }
        if (-not $startParsing) { continue }

        If ($LocalDEBUG_Mode) { Write-Host "[DEBUG] Parsing line: $clean" -ForegroundColor Yellow }
        
        # -----------------------------------------------------------------------
        # BEGIN GROUP
        # -----------------------------------------------------------------------
        if ($clean -match '^\[GROUP - (.+)\]') {

            # Close previous OPTION if still open
            if ($currentOption) {

                if ($LocalDEBUG_Mode) {
                    Write-Host "[DEBUG] Finalizing OPTION: $($currentOption.Name) in group $($currentGroup.Name)" -ForegroundColor Magenta
                    Write-Host "[DEBUG] optionAdviceBuffer contents (Count: $($optionAdviceBuffer.Count)):" -ForegroundColor Magenta
                    if ($optionAdviceBuffer.Count -eq 0) {
                        Write-Host "[DEBUG] No advice lines collected for OPTION: $($currentOption.Name) in group $($currentGroup.Name)" -ForegroundColor Red
                    } else {
                        $optionAdviceBuffer | ForEach-Object { Write-Host $_ -ForegroundColor Cyan }
                    }
                }
                
                $adviceText = Build-Rtf $optionAdviceBuffer
                Remember-BasicOptionName `
                    -GroupName  $currentGroup.Name `
                    -OptionName $currentOption.Name `
                    -AdviceText $adviceText                
                $currentOption | Add-Member -NotePropertyName Advice -NotePropertyValue $adviceText -Force
                $currentGroup.Options += $currentOption
                $currentOption      = $null
                $optionAdviceBuffer = @()
            }

            # Close previous ALTERNATIVE if still open
            if ($currentAltName) {
                if ($altAdviceBuffer.Count -eq 0) {
                    Write-Host "[DEBUG] No advice lines collected for ALTERNATIVE: $currentAltName in group $($currentGroup.Name)" -ForegroundColor Red
                } else {
                    Write-Host "[DEBUG] Advice lines for ALTERNATIVE: $currentAltName in group $($currentGroup.Name):" -ForegroundColor Cyan
                    $altAdviceBuffer | ForEach-Object { Write-Host $_ -ForegroundColor Cyan }
                }
                $altAdviceText = Build-Rtf $altAdviceBuffer
                Remember-BasicOptionName `
                    -GroupName  $currentGroup.Name `
                    -OptionName $currentAltName `
                    -AdviceText $altAdviceText                
                $currentAltName  = $null
                $altAdviceBuffer = @()
            }

            # Close previous group if still open
            if ($currentGroup) {
                $groupText = Build-Rtf $groupIntro
                $script:adviceByGroup[$currentGroup.Name] = $groupText
                $script:groups += $currentGroup
            }

            # Start new group
            $currentGroup = [PSCustomObject]@{
                Name    = $matches[1].Trim()
                Options = @()
            }

            $groupIntro         = @()
            $optionAdviceBuffer = @()
            $altAdviceBuffer    = @()
        }

        # -----------------------------------------------------------------------
        # GROUP DEFAULT MODE
        # -----------------------------------------------------------------------
        elseif ($clean -match '^\[SELECT - (.+)\]') {
            if ($currentGroup) {
                $currentGroup | Add-Member -NotePropertyName DefaultMode -NotePropertyValue ($matches[1].Trim().ToUpper()) -Force
            }
        }

        # -----------------------------------------------------------------------
        # BEGIN OPTION
        # -----------------------------------------------------------------------
        elseif ($clean -match '^\[OPTION - (.+)\]') {

            # Close previous OPTION if open
            if ($currentOption) {
                $adviceText = Build-Rtf $optionAdviceBuffer
                Remember-BasicOptionName `
                    -GroupName  $currentGroup.Name `
                    -OptionName $currentOption.Name `
                    -AdviceText $adviceText                
                $currentOption | Add-Member -NotePropertyName Advice -NotePropertyValue $adviceText -Force
                $currentGroup.Options += $currentOption
                $optionAdviceBuffer = @()
            }

            # Close previous ALTERNATIVE if still open
            if ($currentAltName) {
                $altAdviceText = Build-Rtf $altAdviceBuffer
                 Remember-BasicOptionName `
                     -GroupName  $currentGroup.Name `
                     -OptionName $currentAltName `
                     -AdviceText $altAdviceText                
                $currentAltName  = $null
                $altAdviceBuffer = @()
            }

            # Start new OPTION
            $currentOption = [PSCustomObject]@{
                Name          = $matches[1].Trim()
                DefaultMode   = $currentGroup.DefaultMode
                Recommended   = ($currentGroup.DefaultMode -eq 'ALL')
            }

            $optionAdviceBuffer = @()
        }

        # -----------------------------------------------------------------------
        # BEGIN ALTERNATIVE
        # -----------------------------------------------------------------------
        elseif ($clean -match '^\[ALTERNATIVE - (.+)\]') {

            # Close previous OPTION advice if we were still inside it
            if ($currentOption -and $optionAdviceBuffer.Count -gt 0) {
                $adviceText = Build-Rtf $optionAdviceBuffer
                if (-not $script:adviceByGroupAndOption.ContainsKey($currentGroup.Name)) {
                    $script:adviceByGroupAndOption[$currentGroup.Name] = @{}
                }
                $script:adviceByGroupAndOption[$currentGroup.Name][$currentOption.Name] = $adviceText
                $currentOption | Add-Member -NotePropertyName Advice -NotePropertyValue $adviceText -Force
                $currentGroup.Options += $currentOption
                $currentOption      = $null
                $optionAdviceBuffer = @()
            }

            # Close previous ALTERNATIVE if still open
            if ($currentAltName) {
                $altAdviceText = Build-Rtf $altAdviceBuffer
                Remember-BasicOptionName `
                    -GroupName  $currentGroup.Name `
                    -OptionName $currentAltName `
                    -AdviceText $altAdviceText            
            }

            # Start new ALTERNATIVE (this does NOT become an option in groups)
            $currentAltName  = $matches[1].Trim()  # full text e.g. "INSTALL Outlook for Windows"
            $altAdviceBuffer = @()
        }

        # -----------------------------------------------------------------------
        # END OPTION / ALTERNATIVE BLOCK (==== separator)
        # -----------------------------------------------------------------------

        elseif ($clean -match '^=+') {

                if ($currentOption) {
                    $adviceText = Build-Rtf $optionAdviceBuffer
                    Remember-BasicOptionName `
                        -GroupName  $currentGroup.Name `
                        -OptionName $currentOption.Name `
                        -AdviceText $adviceText
                    $currentOption | Add-Member -NotePropertyName Advice -NotePropertyValue $adviceText -Force
                    $currentGroup.Options += $currentOption
                    $currentOption      = $null
                    $optionAdviceBuffer = @()
                }
            elseif ($currentAltName) {
                $altAdviceText = Build-Rtf $altAdviceBuffer
                Remember-BasicOptionName `
                    -GroupName  $currentGroup.Name `
                    -OptionName $currentAltName `
                    -AdviceText $altAdviceText                
                $currentAltName  = $null
                $altAdviceBuffer = @()
            }
        }

        # -----------------------------------------------------------------------
        # OPTION-LEVEL ADVICE
        # -----------------------------------------------------------------------
        elseif ($currentOption -and $rawLine.Trim()) {
            $optionAdviceBuffer += $rawLine
            if ($LocalDEBUG_Mode) {
                Write-Host "[DEBUG] Added to optionAdviceBuffer for OPTION: $($currentOption.Name) in group $($currentGroup.Name): $rawLine" -ForegroundColor Green
            }
        }

        # -----------------------------------------------------------------------
        # ALTERNATIVE-LEVEL ADVICE
        # -----------------------------------------------------------------------
        elseif ($currentAltName -and $rawLine.Trim()) {
            $altAdviceBuffer += $rawLine
            if ($LocalDEBUG_Mode) {
                Write-Host "[DEBUG] Added to altAdviceBuffer for ALTERNATIVE: $($currentAltName) in group $($currentGroup.Name): $rawLine" -ForegroundColor Green
            }
        }

        # -----------------------------------------------------------------------
        # GROUP-LEVEL INTRO
        # -----------------------------------------------------------------------
        elseif ($currentGroup -and -not $currentOption -and -not $currentAltName -and $rawLine.Trim()) {
            $groupIntro += $rawLine
        }
        If ($LocalDEBUG_Mode) { Pause }

    } # END foreach line

    # ---------------------------------------------------------------------------
    # FINALIZE LAST OPTION
    # ---------------------------------------------------------------------------
    if ($currentOption) {
        $adviceText = Build-Rtf $optionAdviceBuffer
        Remember-BasicOptionName `
            -GroupName  $currentGroup.Name `
            -OptionName $currentOption.Name `
            -AdviceText $adviceText
        $currentOption | Add-Member -NotePropertyName Advice -NotePropertyValue $adviceText -Force
        $currentGroup.Options += $currentOption
    }

    # ---------------------------------------------------------------------------
    # FINALIZE LAST ALTERNATIVE
    # ---------------------------------------------------------------------------
    if ($currentAltName) {
        $altAdviceText = Build-Rtf $altAdviceBuffer
         Remember-BasicOptionName `
            -GroupName  $currentGroup.Name `
            -OptionName $currentAltName `
            -AdviceText $altAdviceText
    }

    # ---------------------------------------------------------------------------
    # FINALIZE LAST GROUP
    # ---------------------------------------------------------------------------
    if ($currentGroup) {
        $groupText = Build-Rtf $groupIntro
        $script:adviceByGroup[$currentGroup.Name] = $groupText
        $script:groups += $currentGroup
    }

    # ---------------------------------------------------------------------------
    # BUILD FALLBACK ENTRIES FOR REWRITTEN TEXTS
    #
    # For each real OPTION (e.g. "Remove Outlook for Windows"):
    #   - Ensure "INSTALL Outlook for Windows", "ADD Outlook for Windows", etc.
    #     have advice entries, falling back to the OPTION advice if no explicit
    #     [ALTERNATIVE - ...] exists in the RTF.
    # ---------------------------------------------------------------------------
    $actionPrefixes = @('Remove','INSTALL','ADD','KEEP','DISABLE','ENABLE')

    foreach ($group in $script:groups) {
        foreach ($opt in $group.Options) {

            $optionKey = $opt.Name  # e.g. "Remove Outlook for Windows"
            $groupName = $group.Name

            if ($script:adviceByGroupAndOption.ContainsKey($groupName) -and $script:adviceByGroupAndOption[$groupName].ContainsKey($optionKey)) {
                $defaultAdvice = $script:adviceByGroupAndOption[$groupName][$optionKey]
            } else {
                $defaultAdvice = $null
            }

            # Extract the base name: everything after the first action word
            if ($optionKey -match '^(Remove|KEEP|DISABLE|DELETE|SHOW|HIDE|PIN)\s+(the\s+)?(.+)$') {
                $baseName = $matches[3]

                foreach ($prefix in $actionPrefixes) {
                    $fullKey = "$prefix $baseName"
                    if ($script:adviceByGroupAndOption.ContainsKey($groupName)) {
                        if (-not $script:adviceByGroupAndOption[$groupName].ContainsKey($fullKey)) {
                            $script:adviceByGroupAndOption[$groupName][$fullKey] = $defaultAdvice
                        }
                    }
                }
            }
        }
    }
    If ($LocalDEBUG_Mode) { Pause }

} # END of - function Read-FormDefinition


# ============================================================================================
function Build-FormAndPanels {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # --- Form ---
    $script:form = New-Object System.Windows.Forms.Form
    $script:form.Text = "On2it Software - Windows 11 DeBloater"
    $script:form.Size = [System.Drawing.Size]::new(945,650)   # taller form to fit bottom groups
    $script:form.StartPosition = "CenterScreen"

    # WinFixIT.ico sits at the root parallel to Scripts, both on the raw
    # USB-INSTALL partition and in the installed Local-INSTALL copy - two
    # levels up from this file (DeBloater -> Scripts -> root) in both cases.
    $script:_iconPath = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'WinFixIT.ico'
    if (Test-Path -LiteralPath $script:_iconPath) {
        $script:form.Icon = New-Object System.Drawing.Icon($script:_iconPath)
    }

    $script:OptionFont = New-Object System.Drawing.Font($script:form.Font.FontFamily, 10)

    # Shared ToolTip for option checkboxes ---
    $script:optionTip = New-Object System.Windows.Forms.ToolTip
    $script:optionTip.ShowAlways   = $true
    $script:optionTip.InitialDelay = 400
    $script:optionTip.ReshowDelay  = 200
    $script:optionTip.AutoPopDelay = 5000

    
    $script:scrollTimer = New-Object System.Windows.Forms.Timer
    $script:scrollTimer.Interval = 50

    # --- Left panel that contains Options list ---
    $script:panelLeft = New-Object System.Windows.Forms.Panel
    $script:panelLeft.Location   = [System.Drawing.Point]::new(10,10)
    $script:panelLeft.Size       = [System.Drawing.Size]::new(430,465)
    $script:panelLeft.AutoScroll = $true
    $script:panelLeft.Anchor     = 'Top,Left,Bottom'
    $script:form.Controls.Add($script:panelLeft)

    # After $panelLeft is added to the form, add divider
    $script:panelDivider = New-Object System.Windows.Forms.Panel
    $script:panelDivider.Height    = 4
    $script:panelDivider.Width     = $script:panelLeft.Width
    $script:panelDivider.BackColor = [System.Drawing.Color]::White
    $script:panelDivider.Location  = [System.Drawing.Point]::new($script:panelLeft.Left, $script:panelLeft.Bottom)
    $script:panelDivider.Anchor    = 'Bottom,Left,Right'
    $script:form.Controls.Add($script:panelDivider)
    $script:form.Controls.SetChildIndex($script:panelDivider, 0)

    # --- Advice Panel (framed) ---
    $script:advicePanel = New-Object System.Windows.Forms.Panel
    $script:advicePanel.Location    = [System.Drawing.Point]::new(450,20)
    $script:advicePanel.Size        = [System.Drawing.Size]::new(462,450)
    $script:advicePanel.BorderStyle = 'FixedSingle'
    $script:advicePanel.Anchor      = 'Top,Left,Right,Bottom'
    $script:form.Controls.Add($script:advicePanel)


    # --- Group heading label (always shows current group name) ---
    $script:GroupHeading = New-Object System.Windows.Forms.Label
    $script:GroupHeading.Location = [System.Drawing.Point]::new(10, 15)
    $script:GroupHeading.Size     = [System.Drawing.Size]::new(430, 18)
    $script:GroupHeading.Font     = New-Object System.Drawing.Font(
        $script:form.Font.FontFamily, 
        12,
        [System.Drawing.FontStyle]::Bold
    )
    $script:GroupHeading.Text     = ""
    $script:GroupHeading.AutoSize = $false
    $script:advicePanel.Controls.Add($script:GroupHeading)

    # --- Advice heading inside panel (now below group heading) ---
    $script:adviceHeading = New-Object System.Windows.Forms.Label
    $script:adviceHeading.Location = [System.Drawing.Point]::new(10, 40)
    $script:adviceHeading.Size     = [System.Drawing.Size]::new(430, 20)
    $script:adviceHeading.Font     = New-Object System.Drawing.Font(
        $script:form.Font.FontFamily,
        10,
        [System.Drawing.FontStyle]::Bold
    )
    $script:adviceHeading.AutoSize = $false
    $script:advicePanel.Controls.Add($script:adviceHeading)

    # --- Advice content Rich Text Box ---
    $script:adviceRTbox = New-Object System.Windows.Forms.RichTextBox
    $script:adviceRTbox.Location   = [System.Drawing.Point]::new(10, 60)
    $script:adviceRTbox.Size       = [System.Drawing.Size]::new(435, 375)
    $script:adviceRTbox.ReadOnly   = $true
    $script:adviceRTbox.BorderStyle = 'None'
    $script:adviceRTbox.BackColor  = $script:advicePanel.BackColor
    $script:adviceRTbox.DetectUrls = $true
    $script:adviceRTbox.ScrollBars = 'Vertical'
    $script:adviceRTbox.Anchor     = 'Top,Left,Right,Bottom'

    $script:advicePanel.Controls.Add($script:adviceRTbox)

    # RTF color table: 0,51,53 is \red0\green51\blue53
    $rtfColorTable = "{\colortbl ;\red0\green51\blue53;}"

    # Group Heading: plain text for UI label (RTF only for print)
    $script:defaultGroupHeading = "The DeBloater can be run in two modes:"

    # Default advice content: Calibri 12pt, black, valid RTF
    # Fonttbl: f0 Arial; f1 Calibri. Color table: black only.
    $script:defaultAdvice = @(
        "{\rtf1\ansi\fs22"
        "\b Initial Run \b0 \par"
        "\b * \b0 All Options on the left default to our recommendations.\par"
        "\b   \b0 To follow all of them, simply click the \par"
        "   \fs20\b PERFORM Selected Options \b0\fs22 Button, below.\par"
        "\b * \b0 To see advice on any Group, Option or Button and make your \par"
        "   own selections, simply point at what you are interested in.  \par"
        "   Advice will appear HERE. \par"
        "\b * \b0 If an Option is not currently installed, and you wish to \par"
        "   keep it - you will be offered the choice to INSTALL it.\par"
        "\b * \b0 To reset, use the \fs20\b Select ALL Recommended \b0\fs22 Button \par"
        "   below, or the \fs20\b Select ALL Recommended Options \b0\fs22 Checkbox \par"
        "   in each Group, to select or de-select every Option in the Group.  \par"
        "\b * \b0 As each Option runs, a Task Log will display HERE. \par"
        "   Controls will appear below, to choose detail level or print it.\par"
        "\b * \b0 any Options that remain un-ticked, will NOT run. \par"
        "   So you can be selective about which options you want to run, \par"
        "   and which you wish to ignore.  \par"
        "\par"
        "\b Subsequent Runs\b0\par"
        "You can re-run the DeBloater at any time, if you change your \par"
        "mind about any Option.  \par"
        "(Most larger Apps will require manual re-installation.)\par"
        "\par"
        "\b If the Advice Panel is not large enough \b0 to show all the advice, scroll bars will appear.  "
        "To see all the Advice at the same time, simply enlarge the form window by dragging the edges or corners.  \par"
        "\par"
        "\b To re-display this advice, \b0 simply point at the \fs20\b Advice Panel \b0\fs22 Heading, above.\par"
        "}"
    ) -join "`n"
    $script:adviceRTbox.Rtf = $script:defaultAdvice
    $script:GroupHeading.Text = $script:defaultGroupHeading
    $script:adviceHeading.Text = ""
    $script:advicePanel.Controls.Add($script:adviceRTbox)

    # Advice Panel label (straddling top border)
    $script:adviceLabel = New-Object System.Windows.Forms.Label
    $script:adviceLabel.Text   = "Advice Panel"
    $script:adviceLabel.Font   = New-Object System.Drawing.Font($script:form.Font.FontFamily, 12, [System.Drawing.FontStyle]::Bold)
    $script:adviceLabel.AutoSize   = $true
    $script:adviceLabel.BackColor  = $script:form.BackColor
    $script:adviceLabel.CreateControl()
    $script:labelHeight   = $script:adviceLabel.Height
    $script:midlineOffset = [math]::Floor($labelHeight / 2)
    $script:adviceLabel.Location = [System.Drawing.Point]::new($script:advicePanel.Left + 10, $script:advicePanel.Top - $script:midlineOffset)
    $script:form.Controls.Add($script:adviceLabel)

    $script:form.Controls.SetChildIndex($script:adviceLabel, 0)

    # --- Log Box (overlays advice area when in log mode, inset to show frame) ---
    $script:TaskLogRTbox = New-Object System.Windows.Forms.RichTextBox
    $script:TaskLogRTbox.Multiline   = $true
    $script:TaskLogRTbox.ReadOnly    = $true
    $script:TaskLogRTbox.ScrollBars  = 'Vertical'
    $script:TaskLogRTbox.BackColor   = $script:advicePanel.BackColor
    $script:TaskLogRTbox.BorderStyle = 'None'
    $script:TaskLogRTbox.Font        = New-Object System.Drawing.Font($script:form.Font.FontFamily, 9)
    $script:TaskLogRTbox.Visible     = $false
    $script:TaskLogRTbox.Enabled     = $false
    $script:TaskLogRTbox.Size        = [System.Drawing.Size]::new($script:advicePanel.Size.Width - 20, $script:advicePanel.Size.Height - 30)
    $script:TaskLogRTbox.Location    = [System.Drawing.Point]::new($script:advicePanel.Location.X + 10, $script:advicePanel.Location.Y + 20)
    $script:TaskLogRTbox.Anchor      = 'Top,Left,Right,Bottom'
    $script:form.Controls.Add($script:TaskLogRTbox)
    $script:form.Controls.SetChildIndex($script:TaskLogRTbox, 0)

    # --- Options Group (bottom left, framed) ---
    $script:optionsControlPanel = New-Object System.Windows.Forms.Panel
    $script:optionsControlPanel.BorderStyle = 'FixedSingle'
    $script:optionsControlPanel.Size        = [System.Drawing.Size]::new(147,80)
    $script:optionsControlPanel.Location    = [System.Drawing.Point]::new(
        $script:panelLeft.Left + 10,
        $script:panelDivider.Bottom + 32
    )
    $script:optionsControlPanel.Anchor      = 'Bottom,Left'
    $script:form.Controls.Add($script:optionsControlPanel)

    # --- Options Panel Label ---
    $script:optionsControlPanelLabel = New-Object System.Windows.Forms.Label
    $script:optionsControlPanelLabel.Text      = "Select OPTIONS"    
    $script:optionsControlPanelLabel.Font      = New-Object System.Drawing.Font(
        $script:form.Font.FontFamily, 10, [System.Drawing.FontStyle]::Bold
    )
    $script:optionsControlPanelLabel.AutoSize  = $true
    $script:optionsControlPanelLabel.BackColor = $script:form.BackColor
    $script:optionsControlPanelLabel.Anchor    = 'Bottom,Left'
    $script:optionsControlPanelLabel.CreateControl()

    $script:optLblMid = [math]::Floor($script:optionsControlPanelLabel.Height / 2)

    $script:optionsControlPanelLabel.Location = [System.Drawing.Point]::new(
        $script:optionsControlPanel.Left + 10,
        $script:optionsControlPanel.Top - $script:optLblMid + 2
    )

    $script:form.Controls.Add($script:optionsControlPanelLabel)
    $script:form.Controls.SetChildIndex($script:optionsControlPanelLabel, 0)

    # --- Buttons inside Options panel: Reset ---
    $script:btnSelectAllRecommended = New-Object System.Windows.Forms.Button
    $script:btnSelectAllRecommended.Text     = "ALL Recommended"
    $script:btnSelectAllRecommended.Size     = [System.Drawing.Size]::new(125,30)
    $script:btnSelectAllRecommended.Location = [System.Drawing.Point]::new(10,10)
    $script:btnSelectAllRecommended.Tag = @{
        Heading = "Select ALL Recommended OPTIONS"
        Advice  = "{\rtf1\ansi\fs22 " +
              "This Button resets ALL Options in every Group to their Recommended Values. \par" +
              " \par " +
              "You can still manually adjust individual Options afterwards." +
              "}"
    }

    $script:btnSelectAllRecommended.Font = New-Object System.Drawing.Font(
        "Segoe UI", 9, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Point
    )
    $script:btnSelectAllRecommended.Anchor = 'Bottom,Left'

    $script:btnClearAll = New-Object System.Windows.Forms.Button
    $script:btnClearAll.Text = "CLEAR ALL"
    $script:btnClearAll.Size = [System.Drawing.Size]::new(125,30)
    $script:btnClearAll.Location = [System.Drawing.Point]::new(10,42)
    $script:btnClearAll.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Point)
    $script:btnClearAll.Anchor = 'Bottom,Left'
    $script:btnClearAll.Tag = @{
        Heading = "CLEAR All OPTIONS" 
        Advice  = "{\rtf1\ansi\fs22 " +
            "\b This Button clears all Options in every Group. " +
            "\b0 You can still manually adjust individual Options afterwards. \par" +
            " \par " +
            "\b Note:\b0 This is NOT the same as un-checking every Option manually.  " +
            "Because, when you uncheck an Option, it implies you want to do the opposite.  " +
            "So the Option changes to a feasible alternative (e.g. from REMOVE to KEEP or INSTALL).  " +
            "But the Checkbox remains ticked - because you are still wanting that Option to run. " +
            "but do something different.  \par" +
            " \par " +
            "\b0 Whereas, when you click \b Clear All\b0, you are explicitly saying " +
            "you do NOT want to select ANY of the Options or their alternatives.  " +
            "So every Checkbox becomes un-ticked, and every Option becomes de-selected. \par" +
            " \par " +
            "This effectively says 'I want none of these'. " +
            "You can then manually tick only the few Options you want, and leave the rest un-ticked.  \par" +
            " \par " +
            "For when you click \b PERFORM Selected Options\b0, only the ticked Options will run, " +
            "and the un-ticked Options will be ignored and the Options will remain unchanged. " +
            "}"
    }

    $script:optionTip.SetToolTip(
        $script:btnClearAll,
        "Unchecks every option in every group - see Advice Panel for details"
    )

    $script:optionsControlPanel.Controls.Add($script:btnClearAll)
    $script:optionsControlPanel.Controls.Add($script:btnSelectAllRecommended)
    $script:optionsControlPanel.Controls.SetChildIndex($script:btnSelectAllRecommended, 0)

    # ============================================================================================
    # --- Bottom Button Bar: [Options] [Print] [Task Log Required] [PERFORM] [Post-PERFORM Print]
    # ============================================================================================
    $optionsFrame = $script:optionsControlPanel

    # ============================================================================================
    # --- Pre-PERFORM Print Panel ---
    # Contains: Selected ADVICE | Create WORD Document
    # ============================================================================================
    $script:printControlPanel = New-Object System.Windows.Forms.Panel
    $script:printControlPanel.BorderStyle = 'FixedSingle'
    $script:printControlPanel.Size        = [System.Drawing.Size]::new(185, 80)
    $script:printControlPanel.Location    = [System.Drawing.Point]::new($optionsFrame.Right + 10, $optionsFrame.Top)
    $script:printControlPanel.Anchor      = 'Bottom,Left'
    $script:form.Controls.Add($script:printControlPanel)

    # --- Print Panel Label (straddling top border) ---
    $script:lblPrintControlPanel = New-Object System.Windows.Forms.Label
    $script:lblPrintControlPanel.Text      = "Print"
    $script:lblPrintControlPanel.Font      = New-Object System.Drawing.Font($script:form.Font.FontFamily, 10, [System.Drawing.FontStyle]::Bold)
    $script:lblPrintControlPanel.AutoSize  = $true
    $script:lblPrintControlPanel.BackColor = $script:form.BackColor
    $script:lblPrintControlPanel.Anchor    = 'Bottom,Left'
    $script:lblPrintControlPanel.CreateControl()
    $script:printLblMid = [math]::Floor($script:lblPrintControlPanel.Height / 2)
    $script:lblPrintControlPanel.Location = [System.Drawing.Point]::new(
        $script:printControlPanel.Left + 10,
        $script:printControlPanel.Top - $script:printLblMid + 2)
    $script:form.Controls.Add($script:lblPrintControlPanel)
    $script:form.Controls.SetChildIndex($script:lblPrintControlPanel, 0)

    # --- Button: Selected ADVICE ---
    $script:btnPrintAdvice = New-Object System.Windows.Forms.Button
    $script:btnPrintAdvice.Text     = "Selected ADVICE"
    $script:btnPrintAdvice.Size     = [System.Drawing.Size]::new(160, 30)
    $script:btnPrintAdvice.Location = [System.Drawing.Point]::new(10, 8)
    $script:btnPrintAdvice.Font     = New-Object System.Drawing.Font(
        "Segoe UI", 9, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Point)
    $script:optionTip.SetToolTip($script:btnPrintAdvice, "Prints the current content of the Advice Panel")
    $script:printControlPanel.Controls.Add($script:btnPrintAdvice)

    # --- Button: Create WORD Document ---
    $script:btnCreateDocumentation = New-Object System.Windows.Forms.Button
    $script:btnCreateDocumentation.Text     = "Create WORD Document"
    $script:btnCreateDocumentation.Size     = [System.Drawing.Size]::new(160, 30)
    $script:btnCreateDocumentation.Location = [System.Drawing.Point]::new(10, 42)
    $script:btnCreateDocumentation.Font     = New-Object System.Drawing.Font(
        "Segoe UI", 9, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Point)
    $script:btnCreateDocumentation.Tag = @{
        Heading = "Create WORD Document"
        Advice  = "{\rtf1\ansi\fs22\b0 " +
            "This Button creates a WORD Document, containing all the Advice content for selected Groups and Options. \par \par " +
            "You will be prompted to choose a save location for the Word file.  " +
            "If the document already exists, it will be appended with the current content of the Advice Panel.  \par \par " +
            "This means, you can build a custom WORD Document by navigating to selected Groups and Options, " +
            "and clicking this Button at each one in turn. \par \par " +
            "The Document will be formatted with headings and styling, so it can be easily read or printed. }"
    }
    $script:optionTip.SetToolTip(
        $script:btnCreateDocumentation,
        "Append the current Advice Panel content to the WORD Documentation file.")
    $script:printControlPanel.Controls.Add($script:btnCreateDocumentation)

    # ============================================================================================
    # --- Task Log Panel (pre-PERFORM, always visible, renamed "Task Log Required") ---
    # ============================================================================================
    $script:TaskLogControlPanel = New-Object System.Windows.Forms.Panel
    $script:TaskLogControlPanel.BorderStyle = 'FixedSingle'
    $script:TaskLogControlPanel.Size        = [System.Drawing.Size]::new(156, 80)
    $script:TaskLogControlPanel.Anchor      = 'Bottom,Left'
    $script:TaskLogControlPanel.Location    = [System.Drawing.Point]::new(
        $script:printControlPanel.Right + 10,
        $optionsFrame.Top)
    $script:form.Controls.Add($script:TaskLogControlPanel)

    $script:lblTaskLogControlPanel = New-Object System.Windows.Forms.Label
    $script:lblTaskLogControlPanel.Text      = "Task Log Required"
    $script:lblTaskLogControlPanel.Font      = New-Object System.Drawing.Font(
        $script:form.Font.FontFamily, 10, [System.Drawing.FontStyle]::Bold)
    $script:lblTaskLogControlPanel.AutoSize  = $true
    $script:lblTaskLogControlPanel.BackColor = $script:form.BackColor
    $script:lblTaskLogControlPanel.CreateControl()
    $script:taskLogLblMid = [math]::Floor($script:lblTaskLogControlPanel.Height / 2)
    $script:lblTaskLogControlPanel.Location  = [System.Drawing.Point]::new(
        $script:TaskLogControlPanel.Left + 10,
        $script:TaskLogControlPanel.Top - $script:taskLogLblMid)
    $script:form.Controls.Add($script:lblTaskLogControlPanel)
    $script:form.Controls.SetChildIndex($script:lblTaskLogControlPanel, 0)

    # --- ComboBox inside Task Log Panel ---
    $script:cmbTaskLogOptions = New-Object System.Windows.Forms.ComboBox
    $script:cmbTaskLogOptions.Location      = [System.Drawing.Point]::new(10, 10)
    $script:cmbTaskLogOptions.Size          = [System.Drawing.Size]::new(134, 25)
    $script:cmbTaskLogOptions.DropDownStyle = 'DropDownList'
    $script:cmbTaskLogOptions.FlatStyle     = [System.Windows.Forms.FlatStyle]::System
    [void]$script:cmbTaskLogOptions.Items.AddRange(@("Continuous","Detailed","Summary"))
    $script:cmbTaskLogOptions.SelectedItem = "Continuous"
    $script:optionTip.SetToolTip(
        $script:cmbTaskLogOptions,
        "Chooses how the Task Log is displayed - see Advice Panel above for details")
    $script:TaskLogControlPanel.Controls.Add($script:cmbTaskLogOptions)

    $script:cmbTaskLogOptions.Tag = @{
        Heading = "Task Log Required"
        Advice  = @(
            "{\rtf1\ansi\fs22"
            "\b0 Choose the Task Log type BEFORE clicking \b PERFORM Selected Options\b0: \par "
            "\b    Continuous\b0  streams Detailed results without pauses. \par "
            "\b    Detailed\b0  shows the detail of every Task, \par "
            "        with pauses in-between. \par "
            "\b    Summary\b0  shows only the results of previous tasks, \par "
            "        and details of the latest task, with pauses in-between. \par "
            "\par"
            "To continue from a pause, click the \b Continue \b0 Button, \par "
            "which will appear when required. \par "
            "\par"
            "(You can copy text from the Task Log while paused, if you wish.) \par "
            "}"
        ) -join "`n"
    }

    # --- Continue button inside Task Log panel ---
    $script:btnContinue = New-Object System.Windows.Forms.Button
    $script:btnContinue.Text     = "Continue"
    $script:btnContinue.Size     = [System.Drawing.Size]::new(134, 40)
    $script:btnContinue.Location = New-Object System.Drawing.Point(10, 35)
    $script:btnContinue.Font     = New-Object System.Drawing.Font(
        $script:form.Font.FontFamily,15,
        [System.Drawing.FontStyle]::Bold,
        [System.Drawing.GraphicsUnit]::Point)
    $script:btnContinue.Visible  = $false
    $script:TaskLogControlPanel.Controls.Add($script:btnContinue)

    $script:btnContinue_TaskTip = New-Object System.Windows.Forms.ToolTip
    $script:btnContinue_TaskTip.ShowAlways   = $true
    $script:btnContinue_TaskTip.InitialDelay = 400
    $script:btnContinue_TaskTip.ReshowDelay  = 200
    $script:btnContinue_TaskTip.AutoPopDelay = 5000
    $script:btnContinue_TaskTip.SetToolTip(
        $script:btnContinue,
        "Click to proceed to the next task after reviewing the current log entry.")

    # ============================================================================================
    # --- PERFORM Selected Options Button (right of Task Log Required) ---
    # ============================================================================================
    $script:btnPerformSelectedOptions = New-Object System.Windows.Forms.Button
    $script:btnPerformSelectedOptions.Text     = "PERFORM`nSelected`nOptions"
    $script:btnPerformSelectedOptions.Size     = [System.Drawing.Size]::new(110, 80)
    $script:btnPerformSelectedOptions.Anchor   = 'Bottom,Left'
    $script:btnPerformSelectedOptions.Visible  = $true
    $script:btnPerformSelectedOptions.Location = [System.Drawing.Point]::new(
        $script:TaskLogControlPanel.Right + 10,
        $optionsFrame.Top)

    $script:optionTip.SetToolTip(
        $script:btnPerformSelectedOptions,
        "Executes all currently selected options - see Advice Panel for details")

    $script:btnPerformSelectedOptions.Tag = @{
        Heading = "PERFORM Selected Options"
        Advice  = @(
            "{\rtf1\ansi\fs22"
            "\b0 This Button actually\b  PERFORMS\b0  all the currently \b Selected Options\b0  on the left.  "
            "A \b Task Log\b0  will appear here once execution begins.  \par"
            "\par"
            "\b Before making any changes, the DeBloater will automatically create a System Restore Point.\b0  "
            "This typically takes 10-30 seconds.  Please be patient and do not interrupt the process.  "
            "If you ever need to undo the changes, go to "
            "\b Settings > System > About > System Protection > System Restore\b0 . \par"
            "\par"
            "Use the \b Task Log Required\b0  dropdown to the left to choose between: \par"
            "\b       Continuous \b0 Task Log,\par"
            "\b       Detailed \b0 Task Log, or \par"
            "\b       Summary \b0 Task Log\par"
            "BEFORE clicking this Button. \par"
            "\par"
            "Point at the \b Task Log Required\b0  dropdown for more details. \par"
            "}"
        ) -join "`n"
    }

    $script:btnPerformSelectedOptions.Font = New-Object System.Drawing.Font(
        "Segoe UI", 10, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Point)
    $script:btnPerformSelectedOptions.TextAlign = 'MiddleCenter'
    $script:form.Controls.Add($script:btnPerformSelectedOptions)
    $script:form.Controls.SetChildIndex($script:btnPerformSelectedOptions, 0)

    # ============================================================================================
    # --- Post-PERFORM Print Panel (hidden until after PERFORM completes) ---
    # Contains: OPTIONS Selected | Task Log
    # ============================================================================================
    $script:postPerformPanel = New-Object System.Windows.Forms.Panel
    $script:postPerformPanel.BorderStyle = 'FixedSingle'
    $script:postPerformPanel.Size        = [System.Drawing.Size]::new(150, 80)
    $script:postPerformPanel.Anchor      = 'Bottom,Left'
    $script:postPerformPanel.Location    = [System.Drawing.Point]::new(
        $script:btnPerformSelectedOptions.Right + 10,
        $optionsFrame.Top)
    $script:postPerformPanel.Visible     = $false
    $script:form.Controls.Add($script:postPerformPanel)

    $script:lblPostPerformPanel = New-Object System.Windows.Forms.Label
    $script:lblPostPerformPanel.Text      = "Print"
    $script:lblPostPerformPanel.Font      = New-Object System.Drawing.Font(
        $script:form.Font.FontFamily, 10, [System.Drawing.FontStyle]::Bold)
    $script:lblPostPerformPanel.AutoSize  = $true
    $script:lblPostPerformPanel.BackColor = $script:form.BackColor
    $script:lblPostPerformPanel.Anchor    = 'Bottom,Left'
    $script:lblPostPerformPanel.CreateControl()
    $script:postPerformLblMid = [math]::Floor($script:lblPostPerformPanel.Height / 2)
    $script:lblPostPerformPanel.Location = [System.Drawing.Point]::new(
        $script:postPerformPanel.Left + 10,
        $script:postPerformPanel.Top - $script:postPerformLblMid + 2)
    $script:lblPostPerformPanel.Visible  = $false
    $script:form.Controls.Add($script:lblPostPerformPanel)
    $script:form.Controls.SetChildIndex($script:lblPostPerformPanel, 0)

    # --- Button: OPTIONS Selected (print list of what was run) ---
    $script:btnPrintOptionsSelected = New-Object System.Windows.Forms.Button
    $script:btnPrintOptionsSelected.Text     = "OPTIONS Selected"
    $script:btnPrintOptionsSelected.Size     = [System.Drawing.Size]::new(130, 30)
    $script:btnPrintOptionsSelected.Location = New-Object System.Drawing.Point(10, 8)
    $script:btnPrintOptionsSelected.Font     = New-Object System.Drawing.Font(
        "Segoe UI", 9, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Point)
    $script:btnPrintOptionsSelected.Tag = @{
        Heading = "Print OPTIONS Selected"
        Advice  = "{\rtf1\ansi\fs22\b0 " +
            "This Button prints a list of all the Options you selected and ran, " +
            "so that you have a record of the choices you made. \par \par " +
            "This is useful for documenting what changes were applied to this machine, " +
            "or for comparing settings across multiple PCs. }"
    }
    $script:optionTip.SetToolTip($script:btnPrintOptionsSelected, "Print a list of the Options that were run")
    $script:postPerformPanel.Controls.Add($script:btnPrintOptionsSelected)

    # --- Button: Task Log (print the task log) ---
    $script:btnPrintTaskLog          = New-Object System.Windows.Forms.Button
    $script:btnPrintTaskLog.Text     = "Task Log"
    $script:btnPrintTaskLog.Font     = New-Object System.Drawing.Font($script:form.Font.FontFamily, 9, [System.Drawing.FontStyle]::Bold)
    $script:btnPrintTaskLog.Size     = [System.Drawing.Size]::new(130, 30)
    $script:btnPrintTaskLog.Location = New-Object System.Drawing.Point(10, 42)
    $script:btnPrintTaskLog.Tag = @{
        Heading = "Print Task Log"
        Advice  = "{\rtf1\ansi\fs22" +
            "\b0 This Button prints a copy of the \b Task Log\b0  that was generated " +
            "when you clicked \b PERFORM Selected Options\b0 .  \par" +
            "\par " +
            "The Task Log records every task that ran, showing whether each one " +
            "\b succeeded\b0 , was \b skipped\b0  (because the item was not present on this machine), " +
            "or \b failed\b0  (with a reason). \par" +
            "\par " +
            "Printing it gives you a permanent record of exactly what was changed on this machine. " +
            "This is useful for: \par" +
            "\b    *  \b0 Your own records, \par" +
            "         in case you need to undo something manually later. \par" +
            "\b    *  \b0 Comparing what was applied across several machines. \par" +
            "\b    *  \b0 Handing to a colleague or client as evidence of \par" +
            "         the work done. \par" +
            "}"
    }
    $script:postPerformPanel.Controls.Add($script:btnPrintTaskLog)

    $script:btnPrintTaskLog.Add_Click({
        # Use the raw log arrays (not RTbox.Text) so HEADER:: markers are preserved
        $mode     = $script:cmbTaskLogOptions.SelectedItem
        $rawLines = switch ($mode) {
            "Summary" { $script:SummaryTaskLog + $script:CurrentTaskLog }
            default   { $script:DetailedTaskLog }
        }

        # Build formatted line descriptors: {Text, Style, Indent}
        $script:taskLogLines = @()

        foreach ($line in $rawLines) {
            $matchLine = $line.TrimStart()
            if ($matchLine -like "HEADER::*") {
                $script:taskLogLines += [PSCustomObject]@{ Text = $matchLine.Substring(8); Style = 'Bold';   Indent = 0 }
            } elseif ($matchLine -like "FOOTER::*") {
                $script:taskLogLines += [PSCustomObject]@{ Text = $matchLine.Substring(8); Style = 'Bold';   Indent = 0 }
            } elseif ($line -eq "") {
                $script:taskLogLines += [PSCustomObject]@{ Text = "";                      Style = 'Normal'; Indent = 0 }
            } else {
                $script:taskLogLines += [PSCustomObject]@{ Text = $line;                   Style = 'Normal'; Indent = 1 }
            }
        }

        $script:taskLogLineIndex = 0

        $printDoc = New-Object System.Drawing.Printing.PrintDocument
        $printDoc.Add_PrintPage({
            param($sender, $e)
            $fontTitle  = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
            $fontBold   = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
            $fontNormal = New-Object System.Drawing.Font("Segoe UI", 10)
            $brush      = [System.Drawing.Brushes]::Black
            $indentPx   = 20
            $x0         = [float]$e.MarginBounds.X
            $y          = [float]$e.MarginBounds.Y
            $pageBottom = [float]($e.MarginBounds.Y + $e.MarginBounds.Height)

            while ($script:taskLogLineIndex -lt $script:taskLogLines.Count) {
                $line = $script:taskLogLines[$script:taskLogLineIndex]
                $font = switch ($line.Style) {
                    'Title'  { $fontTitle }
                    'Bold'   { $fontBold }
                    default  { $fontNormal }
                }
                $lineHeight = $font.GetHeight($e.Graphics) + 2

                if ($y + $lineHeight -gt $pageBottom) {
                    $e.HasMorePages = $true
                    break
                }
                if ($line.Text) {
                    $x = $x0 + ($line.Indent * $indentPx)
                    $e.Graphics.DrawString($line.Text, $font, $brush, $x, $y)
                }
                $y += $lineHeight
                $script:taskLogLineIndex++
            }

            if ($script:taskLogLineIndex -ge $script:taskLogLines.Count) {
                $e.HasMorePages = $false
            }
            $fontTitle.Dispose()
            $fontBold.Dispose()
            $fontNormal.Dispose()
        })

        $printDialog = New-Object System.Windows.Forms.PrintDialog
        $printDialog.Document = $printDoc
        if ($printDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $script:taskLogLineIndex = 0
            $printDoc.Print()
        }
    })

    $script:btnPrintTaskLog_Tip = New-Object System.Windows.Forms.ToolTip
    $script:btnPrintTaskLog_Tip.ShowAlways   = $true
    $script:btnPrintTaskLog_Tip.InitialDelay = 400
    $script:btnPrintTaskLog_Tip.ReshowDelay  = 200
    $script:btnPrintTaskLog_Tip.AutoPopDelay = 5000
    $script:btnPrintTaskLog_Tip.SetToolTip($script:btnPrintTaskLog, "Print the Task Log for your records.")

    # ============================================================================================
    # --- SAVE Options Used Button (PRO feature, hidden until implemented) ---
    # ============================================================================================
    $script:btnSaveOptionsUsed = New-Object System.Windows.Forms.Button
    $script:btnSaveOptionsUsed.Text     = "SAVE`nOptions`nUsed"
    $script:btnSaveOptionsUsed.Size     = [System.Drawing.Size]::new(80, 80)
    $script:btnSaveOptionsUsed.Anchor   = 'Bottom,Left'
    $script:btnSaveOptionsUsed.Visible  = $false
    $script:btnSaveOptionsUsed.Location = [System.Drawing.Point]::new(
        $script:postPerformPanel.Right + 10,
        $optionsFrame.Top)
    $script:btnSaveOptionsUsed.Font = New-Object System.Drawing.Font(
        $script:form.Font.FontFamily, 9, [System.Drawing.FontStyle]::Bold,
        [System.Drawing.GraphicsUnit]::Point)
    $script:btnSaveOptionsUsed.Tag = @{
        Heading = "SAVE Options Used"
        Advice  = "{\rtf1\ansi\fs22" +
            "\b0 This \b PRO\b0  feature saves the complete set of Options you selected and ran " +
            "as a named \b Option Set\b0 .  \par" +
            "\par " +
            "A saved Option Set can be reloaded at any time - on this machine or any other - " +
            "so that you do not have to make the same selections again from scratch. \par" +
            "\par " +
            "This is especially useful when you: \par" +
            "\b    *  \b0 Maintain \b multiple PCs\b0  and want to apply the same standard \par" +
            "         build to each one. \par" +
            "\b    *  \b0 Set up new machines regularly and want a \par" +
            "         consistent starting point. \par" +
            "\b    *  \b0 Want to record \b exactly\b0  what was done, \par" +
            "         so you can repeat it later. \par" +
            "\par " +
            "When a saved Option Set is loaded on a different machine, the DeBloater " +
            "automatically \b skips\b0  any Options that do not apply to that machine. " +
            "Nothing is lost and nothing is overwritten - it simply ignores what is not present. \par" +
            "}"
    }
    $script:optionTip.SetToolTip($script:btnSaveOptionsUsed, "Save the Options used for reuse on this or another machine (PRO)")
    $script:form.Controls.Add($script:btnSaveOptionsUsed)

    # ============================================================================================
    # --- Hover/idle logic wiring ---
    # ============================================================================================
    $script:isHoveringOverOption = $false

    # ============================================================================================
    # --- Resize logic ---
    # ============================================================================================
    $script:initialFormWidth  = $null
    $script:initialFormHeight = $null

    # ============================================================================================
    # --- Initial visibility ---
    # ============================================================================================
    $script:TaskLogControlPanel.Visible    = $true
    $script:lblTaskLogControlPanel.Visible = $true
    $script:cmbTaskLogOptions.Visible      = $true
    $script:btnContinue.Visible            = $false
    $script:postPerformPanel.Visible       = $false
    $script:lblPostPerformPanel.Visible    = $false

    # PRO mode: force-show PRO buttons so they can be sized and screenshotted
    if ($script:PRO_Version) {
        $script:btnSaveOptionsUsed.Visible = $true
        $script:btnContinue.Visible        = $true
    }

} # END of - function Build-FormAndPanels


# =======================================================================================

function Build-Rtf($content) {
# PURPOSE:
#   Converts plain text advice into a minimal RTF document with consistent styling.

    # Empty or null content -> return $null
    if ([string]::IsNullOrWhiteSpace($content)) {
        return $null
    }

    # Join lines if passed an array
    if ($content -is [System.Array]) {
        $content = $content -join "`r`n"
    }

    # Ensure content is treated as a string
    $content = [string]$content

    # If already an RTF document, return as-is (normalize ending)
    if ($content.TrimStart().StartsWith("{\rtf1")) {
        return ($content.TrimEnd() -replace '\}+$','') + "}"
    }

    # Escape literal backslashes only in plain text
    $escaped = $content -replace '\\', '\\\\'

    # Wrap plain text in minimal RTF skeleton
    return "{\rtf1\ansi\fs$($script:AdviceFontSize) $escaped}"

} # END of - function Build-Rtf


# =======================================================================================
function Remember-BasicOptionName {
    param(
        [string]$GroupName,
        [string]$OptionName,
        [string]$AdviceText
    )
    # PURPOSE : Store advice under both the full option/alternative name AND its "basic" form.
    #
    # WHY THIS EXISTS:
    #   The RTF definition file allows multiple textual variants of the same underlying option:
    #       - "Remove Outlook for Windows"
    #       - "INSTALL Outlook for Windows"
    #       - "ADD Outlook for Windows"
    #       - "KEEP Outlook for Windows"
    #
    #   These all refer to the same conceptual item ("Outlook for Windows"), but the UI hover
    #   logic performs lookups using:
    #       1. The exact text
    #       2. A canonical form
    #       3. A "basic" (action-free) form
    #
    #   The original loader only stored the exact text, causing hover lookups to fail whenever
    #   the UI rewrote the action word (e.g. REMOVE -> INSTALL).
    #
    # WHAT THIS FUNCTION DOES:
    #   - Stores the advice under the *raw* option/alternative name.
    #   - Computes the *basic* option name by removing action words and filler words.
    #   - Stores the advice under the basic name as well (if not already present).
    #
    # ARCHITECTURAL ROLE:
    #   This centralises all advice-key registration so the loader no longer duplicates logic
    #   in nine different places. It eliminates a maintenance hazard and ensures consistent
    #   behaviour across OPTION, ALTERNATIVE, GROUP transitions, and finalisation blocks.
    #
    # ASSUMPTIONS:
    #   - $script:adviceByGroupAndOption = @{} is initialised by Read-FormDefinition.
    #   - $Name is the full text from [OPTION - ...] or [ALTERNATIVE - ...].
    #   - $Text is the fully built RTF advice string.
    #
    # INVARIANTS:
    #   - The raw key ALWAYS exists.
    #   - The basic key ALWAYS exists unless explicitly overridden in the RTF.

    # 
    $localDEBUG_Mode = $false

    If ($localDEBUG_Mode){
        Write-Host "[DEBUG] Remember-BasicOptionName Group Name: $GroupName and Option Name: $OptionName"
    }
    # --- Ensure group hashtable exists ---
    if (-not $script:adviceByGroupAndOption.ContainsKey($GroupName) -or $null -eq $script:adviceByGroupAndOption[$GroupName]) {
        $script:adviceByGroupAndOption[$GroupName] = @{}
    }
    # --- Store raw key ---
    $script:adviceByGroupAndOption[$GroupName][$OptionName] = $AdviceText

    # --- Build basic option name ---
    # Only strip action word and 'the' if 'the' immediately follows the action word
    $basic = BasicOptionNameOf `
        -CurrentOptionName $OptionName

     If ($localDEBUG_Mode){
        Write-Host "[DEBUG] Remember-BasicOptionName - OptionName: '$OptionName' -> basic: '$basic' -> GroupName: '$GroupName'" -ForegroundColor Yellow
        Pause
    }

    # Special: Also store for 'PIN' variants (for hover lookups)
    if ($OptionName -match '^(PIN)\s+(the\s+)?(.+)$') {
        $pinBasic = $matches[3].Trim()
        if (-not $script:adviceByGroupAndOption.ContainsKey($pinBasic)) {
            $script:adviceByGroupAndOption[$pinBasic] = $AdviceText
        }
    }

    # --- Store raw key in group+option hashtable ---
    if (-not $script:adviceByGroupAndOption.ContainsKey($GroupName)) {
        $script:adviceByGroupAndOption[$GroupName] = @{}
    }
    $script:adviceByGroupAndOption[$GroupName][$OptionName] = $AdviceText

    # --- Build basic option name again for group+option hashtable ---
    $basic = BasicOptionNameOf `
        -CurrentOptionName $OptionName

    # --- Store basic key if missing in group+option hashtable ---
    if (-not $script:adviceByGroupAndOption[$GroupName].ContainsKey($basic)) {
        $script:adviceByGroupAndOption[$GroupName][$basic] = $AdviceText
    }

    # Special: Also store for 'PIN' variants (for hover lookups) in group+option hashtable
    if ($OptionName -match '^(PIN)\s+(the\s+)?(.+)$') {
        $pinBasic = $matches[3].Trim()
        if (-not $script:adviceByGroupAndOption[$GroupName].ContainsKey($pinBasic)) {
            $script:adviceByGroupAndOption[$GroupName][$pinBasic] = $AdviceText
        }
    }
} # end Remember-BasicOptionName


# =======================================================================================
function BasicOptionNameOf {
    param(
        [Parameter(Mandatory)][string]$CurrentOptionName
    )
    # Fix any potentialRTF whitespace corruption
    $basic = $CurrentOptionName `
        -replace '\u00A0', ' ' `
        -replace '[\u2000-\u200B]', ' ' `
        -replace '\s+', ' '
    $basic = $basic.Trim()
<#
    # Special case: Microsoft Edge - always maps to RTF key "Microsoft Edge SELECTED"
    if ($CurrentOptionName -match '^SELECT\s+Microsoft Edge$' -or 
        $CurrentOptionName -match '^Microsoft Edge\s+SELECTED$') {
        return "Microsoft Edge SELECTED"
    }

    # Special case: Browser Choice - map SELECT X back to INSTALL X
    if ($CurrentOptionName -match '^SELECT\s+(.+)$') {
        return "INSTALL $($matches[1].Trim())"
    }
    if ($CurrentOptionName -match '^(.+)\s+SELECTED$') {
        return "INSTALL $($matches[1].Trim())"
    }
#>
    # All other options - strip action prefixes
    $basic = $basic `
        -replace '^(ADD|KEEP|Remove|DELETE|SHOW|HIDE|PIN|ENABLE|DISABLE)\s+(the\s+)?', '' `
        -replace ',\s*(ON|FROM|to)\s+the\s+(Desktop|Taskbar)$', '' `
        -replace '\b(on|to|from)\b', '' `
        -replace '[,]', '' `
        -replace '\s+', ' '

   return $basic.Trim()

} # END of - function BasicOptionNameOf


# =======================================================================================
function Setup-ScrollTip {
    # PURPOSE: 
    #       Sets up a tooltip that appears when the user hovers over the scrollbar area of panelLeft, 
    #       prompting them to use the scrollbar to see all options.

    if (-not $script:scrollTip) {
        $script:scrollTip = New-Object System.Windows.Forms.ToolTip
        $script:scrollTip.ShowAlways   = $true
        $script:scrollTip.InitialDelay = 400
        $script:scrollTip.ReshowDelay  = 200
        $script:scrollTip.AutoPopDelay = 4000
    }
} # END of - function Setup-ScrollTip 


# ==========================================================================
function Create-GroupsAndOptions {
# PURPOSE:
#   This function iterates through the groups and their options, creates the corresponding UI controls,
#   and adds them to the form. It also sets up the event handlers for interactivity.

    # --- Set fixed panel width ---
    $script:OptionPanelWidth = 380

    $y = 10   # starting vertical offset

    if (-not $script:panelLeft) {
        [System.Windows.Forms.MessageBox]::Show("Error: panelLeft is not initialized. Form controls cannot be added.", "Initialization Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }

    foreach ($group in $script:groups) {

        # Hide PRO-only group in FREE version
        if (-not $script:PRO_Version -and $group.Name -eq 'PRO Version Only') { continue }

        # Build the group panel
        $groupPanel = Create-Group -group $group

        if (-not $groupPanel) {
            [System.Windows.Forms.MessageBox]::Show("Error: groupPanel is not initialized for group $($group.Name).", "Initialization Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
            continue
        }

        # Position the group panel
        $groupPanel.Location = New-Object System.Drawing.Point(10, $y)

        # Add to the left panel
        if ($script:panelLeft -and $groupPanel) {
            $script:panelLeft.Controls.Add($groupPanel)
        } else {
            [System.Windows.Forms.MessageBox]::Show("Error: Cannot add groupPanel to panelLeft. One or both are not initialized.", "Initialization Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
            continue
        }

        # --- NOW position the group label OUTSIDE the panel, straddling the border ---
        # DEBUG: List all controls and their Tag.Kind in this groupPanel
        foreach ($ctrl in $groupPanel.Controls) {
            $kind = $null
            if ($ctrl.Tag -and $ctrl.Tag.PSObject.Properties["Kind"]) {
                $kind = $ctrl.Tag.Kind
            }
         }
        # Find the label that was added to the group panel
        $groupLabels = @($groupPanel.Controls | Where-Object { $_.Tag -and $_.Tag.Kind -eq 'GroupLabel' })
        if (-not $groupLabels -or $groupLabels.Count -eq 0) {
        } elseif ($groupLabels.Count -gt 1) {
            foreach ($lbl in $groupLabels) {
                $groupPanel.Controls.Remove($lbl)
                $midlineOffset = [math]::Floor($lbl.Height / 2.5)
                $lbl.Location = [System.Drawing.Point]::new(
                    $groupPanel.Left + 10,
                    $groupPanel.Top - $midlineOffset
                )
                $script:panelLeft.Controls.Add($lbl)
                $script:panelLeft.Controls.SetChildIndex($lbl, 0)
            }
        } else {
            $lbl = $groupLabels[0]
            $groupPanel.Controls.Remove($lbl)
            $midlineOffset = [math]::Floor($lbl.Height / 2.5)
            $lbl.Location = [System.Drawing.Point]::new(
                $groupPanel.Left + 10,
                $groupPanel.Top - $midlineOffset
            )
            $script:panelLeft.Controls.Add($lbl)
            $script:panelLeft.Controls.SetChildIndex($lbl, 0)
        }

        # Increment y for next group
        $y += $groupPanel.Height + 15
    }

    # Ensure mouse wheel works when form opens
    Enable-PanelWheel $script:panelLeft

    # --- Apply deduction logic for all options (fix Recall default) ---
    foreach ($ctrl in $script:panelLeft.Controls) {
        if ($ctrl.Tag -and $ctrl.Tag.Kind -eq 'Group') {
            foreach ($subCtrl in $ctrl.Controls) {
                if ($subCtrl -is [System.Windows.Forms.Panel]) {
                    foreach ($child in $subCtrl.Controls) {
                        if ($child -is [System.Windows.Forms.CheckBox] -and $child.Tag.Kind -eq 'Option') {
                            if ($child.Tag.DefaultMode -notin @('ONE', 'NONE', 'DIY ONLY', 'REMOVE ONLY')) {
                                $script:TickCheckbox = $false
                                Modify-RecommendedOption `
                                    -checkbox          $child `
                                    -IsRecommendedMode $true
                                if ($child.Text -eq 'CANNOT INSTALL Recall') {
                                    $child.Checked = $false
                                    if ($child.Tag.Label) { $child.Tag.Label.Text = $child.Text }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

} # END of - function Create-GroupsAndOptions


# ==========================================================================
# function - Create-Group
# ==========================================================================
function Create-Group {
    # PURPOSE:
    #   This function creates the UI controls for a single group, including the group label,
    #   the "Select All" checkbox (or "Select ONE" label for ONE groups),
    #   and the individual option checkboxes.
    #   It also sets up the event handlers for interactivity.
    param(
        [Parameter(Mandatory)]
        $group
    )

    # --- Group Panel ---
    $groupLPanel = New-Object System.Windows.Forms.Panel
    $groupLPanel.BorderStyle = 'FixedSingle'
    $groupLPanel.Tag         = [PSCustomObject]@{ Kind='Group'; Group=$group.Name }
    $groupLPanel.Width       = $script:OptionPanelWidth + 20

    # --- Group Label ---
    $groupLabel = New-Object System.Windows.Forms.Label
    $groupLabel.Text      = $group.Name
    $groupLabel.Font      = New-Object System.Drawing.Font($script:form.Font.FontFamily,12,[System.Drawing.FontStyle]::Bold)
    $groupLabel.AutoSize  = $true
    $groupLabel.BackColor = $script:form.BackColor
    $groupLabel.CreateControl()
    $groupLabel.Tag       = [PSCustomObject]@{ Kind='GroupLabel'; Group=$group.Name }
    $groupLabel.Location  = New-Object System.Drawing.Point(10, 10)

    $groupLabel.Add_MouseEnter({
        $groupName = $this.Text
        $script:GroupHeading.Text  = $groupName
        $script:adviceHeading.Text = ""
        if ($script:adviceByGroup.ContainsKey($groupName)) {
            $script:adviceRTbox.Rtf = $script:adviceByGroup[$groupName]
        }
    })

    # --- Select ALL / Select ONE control ---
    # $topControlBottom tracks where the options panel should start
    $topControlBottom = 13

    if ($group.DefaultMode -eq 'ONE' -or $group.DefaultMode -eq 'DIY ONLY') {

        # --- "Select ONE" label ---
        $selectONElabel           = New-Object System.Windows.Forms.Label
        $selectONElabel.Text      = "Select ONE Option"
        $selectONElabel.AutoSize  = $true
        $selectONElabel.Font      = New-Object System.Drawing.Font($script:form.Font.FontFamily, 9, [System.Drawing.FontStyle]::Bold)
        $selectONElabel.Location  = New-Object System.Drawing.Point(10, 13)
        $selectONElabel.BackColor = $script:form.BackColor
        $selectONElabel.Tag = [PSCustomObject]@{
            Kind    = 'SelectOne'
            Group   = $group.Name
            Heading = "Select ONE Option"
            Info    = "{\rtf1\ansi\fs$($script:AdviceFontSize) " +
                      "\b0 Please select \b ONE \b0 of the browsers shown. \par\par " +
                      "KEEP Microsoft Edge is selected by default, as it is already installed.  " +
                      "If you prefer a different browser, simply tick it - " +
                      "the others will be cleared automatically. \par\par " +
                      "The Advice Panel for each browser includes a download link.  " +
                      "Simply click it to go to the download page, then download and " +
                      "run the installer yourself. }"
        }
        $selectONElabel.Add_MouseEnter({
            if ($script:isScrolling) { return }
            $script:isHoveringOverOption = $true
            $script:GroupHeading.Text  = $this.Tag.Group
            $script:adviceHeading.Text = $this.Tag.Heading
            $script:adviceRTbox.Rtf    = $this.Tag.Info
        })
        $selectONElabel.CreateControl()
        if ($group.DefaultMode -eq 'DIY ONLY') {
            $selectONElabel.Text        = "Point at an Option for DIY Instructions"
            $selectONElabel.Tag.Heading = "Point at an Option for DIY Instructions"
            $selectONElabel.Tag.Info    = "{\rtf1\ansi\fs$($script:AdviceFontSize) " +
                "\b0 Simply point at any of the Recommended Options below to receive " +
                "DIY instructions HERE in the Advice Panel, on how to do it for yourself. \par\par " +
                "We have had to do it this way, because Microsoft's security does not " +
                "permit anything to be pinned to or removed from the Start Menu or Taskbar, unless " +
                "it is done by \b YOU\b0 , the User, through the standard Windows interface. \par\par " +
                "You will NOT be able to Select any of these options, as they are ADVICE ONLY.  " +
                "You HAVE to do it for yourself - SORRY.  }"
        }
        $topControlBottom = $selectONElabel.Bottom + 2
        $groupLPanel.Controls.Add($selectONElabel)

    } else {
        # --- "Select All" checkbox ---
        $selectALLoptions = New-Object System.Windows.Forms.CheckBox

        $defaultChecked = $true
        if ($group.PSObject.Properties.Name -contains 'DefaultMode') {
            if ($group.DefaultMode -eq 'NONE') {
                $defaultChecked = $false
                $selectALLoptions.Text = "Select ALL Options"
            } else {
                $selectALLoptions.Text = "Select ALL Recommended Options"
            }
        }

        $selectALLoptions.AutoSize = $true
        $selectALLoptions.Font     = New-Object System.Drawing.Font($script:form.Font.FontFamily, 9, [System.Drawing.FontStyle]::Bold)
        $selectALLoptions.Location = New-Object System.Drawing.Point(10, 13)
        $selectALLoptions.Checked  = $defaultChecked
        $selectALLoptions.Tag = [PSCustomObject]@{
            Kind             = 'SelectAll'
            Group            = $group.Name
            OptionCheckboxes = $null
            GroupPanel       = $groupLPanel
            Info             = "{\rtf1\ansi\fs$($script:AdviceFontSize) " +
                "\b0 This will Select/Deselect all Recommended Options in the Group. \par " +
                "\par " +
                "If you un-check \b $($selectALLoptions.Text)\b0, all the checkboxes in $($group.Name) " +
                "will be cleared.  The Options themselves will not change.  " +
                "You will then be able to select individual Options as you wish. \par " +
                "\par " +
                "Leaving an option unchecked means it will be ignored when you click " +
                "the \b PERFORM Selected Options \b0 Button, below. \par " +
                "\par " +
                "If you check \b $($selectALLoptions.Text)\b0, it will reset ALL the Options in $($group.Name) " +
                "to our original recommended Options and check them all.  \par " +
                "\par " +
                "Please be aware that setting/unsetting multiple Options is not instantaneous.  " +
                "So, please wait for the checkboxes to update.  }"
        }

        # Show advice on hover
        $selectALLoptions.Add_MouseEnter({
            if ($script:isScrolling) { return }
            if ($script:TaskLogRTbox.Visible) { Restore-AdvicePanel }
            $script:isHoveringOverOption = $true
            $script:GroupHeading.Text  = $this.Tag.Group
            $script:adviceHeading.Text = $this.Text
            $script:adviceRTbox.Rtf    = $this.Tag.Info
        })

        # Handle user click - we control exactly what happens, no cascading events
        $selectALLoptions.Add_Click({
            $optionCheckboxes = $this.Tag.OptionCheckboxes
            if (-not $optionCheckboxes -or $optionCheckboxes.Count -eq 0) { return }

            $script:isBulkUpdate = $true
            $script:SkipModifyRecommendedOption = $true

            if ($this.Checked) {
                # Reset all options to their Original/Recommended values and check them
                foreach ($cb in $optionCheckboxes) {
                    $cb.Tag.CurrentOption = $cb.Tag.OriginalOption
                    $cb.Text              = $cb.Tag.OriginalOption
                    if ($cb.Tag.Label) { $cb.Tag.Label.Text = $cb.Tag.OriginalOption }
                    $cb.Checked = $true
                }
                # Now apply Modify-RecommendedOption to adjust for PC configuration
                $script:SkipModifyRecommendedOption = $false
                foreach ($cb in $optionCheckboxes) {
                    Modify-RecommendedOption -checkbox $cb -IsRecommendedMode $true
                }
            } else {
                # Simply uncheck all - leave option text as-is
                foreach ($cb in $optionCheckboxes) {
                    $cb.Checked = $false
                }
                $script:SkipModifyRecommendedOption = $false
            }

            $script:isBulkUpdate = $false
            Restore-AdvicePanel
        }) # END of - Select All Click handler

        
        $selectALLoptions.CreateControl()
        $topControlBottom = $selectALLoptions.Bottom + 2
        $groupLPanel.Controls.Add($selectALLoptions)

    } # END of - if/else DefaultMode ONE vs ALL/NONE

    # --- Build Options for this group ---
    $optionsResult    = Create-Options -group $group
    $groupControls    = $optionsResult.Controls
    $optionCheckboxes = $optionsResult.Checkboxes

    # Store Option checkboxes in Select All tag (not needed for ONE groups)
    if ($group.DefaultMode -ne 'ONE') {
        if ($group.DefaultMode -notin @('ONE', 'DIY ONLY')) {
            $selectALLoptions.Tag.OptionCheckboxes = $optionCheckboxes
        }       
    }

    # --- Add group label to panel ---
    $groupLPanel.Controls.Add($groupLabel)

    # --- Create and populate the Options panel ---
    $optionLPanel          = New-Object System.Windows.Forms.Panel
    $optionLPanel.Location = New-Object System.Drawing.Point(10, $topControlBottom)

    $RowPosition      = 0
    $spaceBetweenRows = 0

    foreach ($control in $groupControls) {
        $control.CheckBox.Location = New-Object System.Drawing.Point(10, $RowPosition)
        $control.Label.Location    = [System.Drawing.Point]::new(25, ($RowPosition + 2))
        $control.Label.AutoSize    = $false
        $control.Label.Width       = $script:OptionPanelWidth - 40
        $RowPosition += $control.CheckBox.Height + $spaceBetweenRows
        $optionLPanel.Controls.Add($control.CheckBox)
        $optionLPanel.Controls.Add($control.Label)
    }

    $optionLPanel.Width  = $script:OptionPanelWidth
    $optionLPanel.Height = $RowPosition

    $groupLPanel.Controls.Add($optionLPanel)
    $groupLPanel.Height = $optionLPanel.Bottom + 10

    return $groupLPanel

} # END of - function Create-Group

# ==========================================================================
# function - Create-Options
# ==========================================================================
function Create-Options{
    # PURPOSE:
    #   This function creates the UI controls for the Options within a group, including the checkboxes and labels. 
    #   It also sets up the event handlers for interactivity.    
    param(
        [Parameter(Mandatory)]
        $group
    )
    
    # --- Build Option rows for this group ---
    $groupControls = @()
    $optionCheckboxes = @()

    foreach ($option in $group.Options) {
        $optionCheckbox = New-Object System.Windows.Forms.CheckBox
        $optionCheckboxes += $optionCheckbox
        $optionCheckbox.Text = $option.Name
        $optionCheckbox.AutoSize = $false    
        $optionCheckbox.Width = $script:OptionPanelWidth
# <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
# Set checkbox state and enabled status based on group DefaultMode
        if ($group.PSObject.Properties.Name -contains 'DefaultMode' -and $group.DefaultMode -eq 'ONE') {
            $optionCheckbox.Checked = ($group.Options.IndexOf($option) -eq 0)
        } elseif ($group.PSObject.Properties.Name -contains 'DefaultMode' -and $group.DefaultMode -eq 'NONE') {
            $optionCheckbox.Checked = $false
        } elseif ($group.PSObject.Properties.Name -contains 'DefaultMode' -and $group.DefaultMode -eq 'DIY ONLY') {
            # DIY ONLY - options are advice only, cannot be checked
            $optionCheckbox.Checked  = $false
        } elseif ($group.PSObject.Properties.Name -contains 'DefaultMode' -and $group.DefaultMode -eq 'REMOVE ONLY') {
            # REMOVE ONLY - only Remove options can be checked, KEEP options are disabled
            if ($option.Name -like 'KEEP*') {
                $optionCheckbox.Checked = $false
            } else {
                $optionCheckbox.Checked = $option.Recommended
            }
        } else {
            $optionCheckbox.Checked = $option.Recommended
        }
# <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<        
        $optionCheckbox.Font = $script:OptionFont

        $optionLabel = New-Object System.Windows.Forms.Label
        $optionLabel.Text = $option.Name
        $optionLabel.AutoSize = $false
        $optionLabel.Width = $script:OptionPanelWidth
        $optionLabel.Font = $script:OptionFont
        $optionLabel.BackColor = $script:form.BackColor

        $optionCheckbox.Tag = [PSCustomObject]@{
            Kind             = 'Option'
            CurrentOption    = $option.Name
            OriginalOption   = $option.Name
            Label            = $optionLabel
            GroupName        = $group.Name
            DefaultMode      = $group.DefaultMode
            OptionCheckboxes = $null
        }

        $optionCheckbox.Add_MouseEnter({
            $script:GroupHeading.Text = $this.Tag.GroupName
            Display-AdviceFor `
                -GroupName          $this.Tag.GroupName `
                -CURRENT_OptionName $this.Tag.CurrentOption
        })

        $optionCheckbox.Add_CheckedChanged({
            if ($script:isBulkUpdate) { return }
            
            # DIY ONLY groups cannot be checked - uncheck immediately
            if ($this.Tag.DefaultMode -eq 'DIY ONLY') {
                $script:isBulkUpdate = $true
                $this.Checked = $false
                $script:isBulkUpdate = $false
                return
            }

            if ($this.Checked -and $this.Tag.DefaultMode -eq 'ONE') {
                $script:isBulkUpdate = $true
                foreach ($cb in $this.Tag.OptionCheckboxes) {
                    if ($cb -ne $this) { $cb.Checked = $false }
                }
                $script:isBulkUpdate = $false
            }            
            $script:TickCheckbox = $false
            Modify-RecommendedOption `
                -checkbox $this `
                -IsRecommendedMode $false
            Display-AdviceFor `
                -GroupName $this.Tag.GroupName `
                -CURRENT_OptionName $this.Tag.CurrentOption
        })

        $groupControls += [PSCustomObject]@{
            CheckBox = $optionCheckbox
            Label    = $optionLabel
        }
    }

    # Update all checkbox Tags with the complete OptionCheckboxes list
    foreach ($ctrl in $groupControls) {
        $ctrl.CheckBox.Tag.OptionCheckboxes = $optionCheckboxes
    }

    return @{ Controls = $groupControls; Checkboxes = $optionCheckboxes }

} # END of - function Create-Options

# =============================================================================================
# Function: Display-Form
# =========================================================================================
function Display-Form {
# PURPOSE:
#   This function displays the form and ensures that the scroll region is properly initialized after the form 
#   is shown. It also includes error handling to catch any issues with the form or panel initialization.

    if (-not $script:form) {
        [System.Windows.Forms.MessageBox]::Show("Error: Form not initialized.", "Display Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }
    $script:form.ShowDialog() | Out-Null

    # --- Force scroll region to initialize AFTER form is visible ---
    if ($script:panelLeft) {
        $script:panelLeft.PerformLayout()
        $script:panelLeft.Invalidate()
        $script:panelLeft.Update()
    } else {
        [System.Windows.Forms.MessageBox]::Show("Error: panelLeft not initialized.", "Display Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
} # END of - function Display-Form


# ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#   END of Group and Options Creation Functions
# ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++





# ========================================================================================
# function Control-InteractionHandlers
# ========================================================================================
function Control-InteractionHandlers {
    # PURPOSE:
    #   This function contains the event handlers for Control interactions, 
    #   such as mouse enter and checkbox state changes for Options. 
  
    # NOTE: The actual event handlers for the Controls are defined inline within the 
    # functions above when creating each Control.    

    # This function serves as a placeholder for ALL Control interaction handlers 
    # that may be needed in the future, and to centralize event handlers 
    # for better organization and readability. 

    # This also allows us to easily manage and update the ALL Control interactions 
    # in one place, without having to navigate through the Option creation code, 
    # thus improving maintainability and scalability of the script as we add more features 
    # or Options in the future.
    
    
    # After $script:closeBtn is created, only add to $waitForm if it exists
    $script:closeBtn = New-Object System.Windows.Forms.Button
    $script:closeBtn.Text = "Close"
    $script:closeBtn.Size = [System.Drawing.Size]::new(100,32)
    $script:closeBtn.Location = [System.Drawing.Point]::new(200,140)
    $script:closeBtn.Visible = $false
    
    if ($null -ne $waitForm -and $waitForm.PSObject.Properties["Controls"]) {
        $waitForm.Controls.Add($script:closeBtn)
        $script:closeBtn.Add_Click({ $waitForm.Close() })
    }

    # Helpers for $script:adviceLabel
    # ------------------------------- 
    $script:adviceLabel.Add_MouseEnter({
        if ($script:isScrolling) { return }

        # Only trigger if mouse is actually over the label text
        $pos = $script:adviceLabel.PointToClient([System.Windows.Forms.Cursor]::Position)
        if ($pos.X -lt 0 -or $pos.X -gt $script:adviceLabel.Width -or
            $pos.Y -lt 0 -or $pos.Y -gt $script:adviceLabel.Height) {
            return
        }
        $script:isHoveringOverOption = $false
        $script:GroupHeading.Text    = $script:defaultGroupHeading
        $script:adviceHeading.Text   = ""
        $script:adviceRTbox.Rtf      = $script:defaultAdvice
        
    }) # END of adviceLabel MouseEnter
   

    # Helpers for $script:advicePanel
    # -------------------------------
    # Mouse enter event handler for the advice panel to restore it when user hovers over it
    $script:advicePanel.Add_MouseEnter({
        if ($script:isHoveringOverOption) {
            Restore-AdvicePanel
        }
    })

    # Mouse leave event handler for the advice panel to reset hovering state
    $script:advicePanel.Add_MouseLeave({
        $script:isHoveringOverOption = $false
        if ($script:isScrolling) { return }
        # Restore-AdvicePanel
    })


    # Helpers for $script:adviceRTbox
    # -------------------------------
    # Add LinkClicked event handler to open URLs
    $script:adviceRTbox.Add_LinkClicked({
        param($sender, $e)
        if ($e.LinkText) {
            try {
                Start-Process $e.LinkText
            } catch {}
        }
    })

    # Helpers for $script:btnClearAll
    # -------------------------------
    $script:btnClearAll.Add_MouseEnter({
        if ($script:isScrolling) { return }
        $script:isHoveringOverOption = $true
        if ($this.Tag.Heading -and $this.Tag.Advice) {
            $script:GroupHeading.Text  = $this.Tag.Heading
            $script:adviceHeading.Text = ""
            $script:adviceRTbox.Rtf    = $this.Tag.Advice
        } 
    })

    $script:btnClearAll.Add_Click({ On-ClearAllClick })
    
    # Helpers for $script:btnContinue
    # -------------------------------
    $script:btnContinue.Add_Click({ On-ContinueClick })

    # Helpers for $script:btnCreateDocumentation
    # ------------------------------------------
    $script:btnCreateDocumentation.Add_Click({ Export-AdvicePanelToWord })

    $script:btnCreateDocumentation.Add_MouseEnter({
        if ($script:isScrolling) { return }
        $script:isHoveringOverOption = $true
        if ($this.Tag.Heading -and $this.Tag.Advice) {
            $script:GroupHeading.Text  = $this.Tag.Heading
            $script:adviceHeading.Text = ""
            $script:adviceRTbox.Rtf    = $this.Tag.Advice
        }
    })
      

    # Helpers for $script:btnPerformSelectedOptions     
    # --------------------------------------------
    $script:btnPerformSelectedOptions.Add_MouseEnter({
        if ($script:isScrolling) { return }
        $script:isHoveringOverOption = $true
        if ($this.Tag.Heading -and $this.Tag.Advice) {
            $script:GroupHeading.Text  = $this.Tag.Heading
            $script:adviceHeading.Text = ""
            $script:adviceRTbox.Rtf    = $this.Tag.Advice
        }
    })

    $script:btnPerformSelectedOptions.Add_MouseLeave({
        if ($script:isScrolling) { return }
        $script:isHoveringOverOption = $false
    })

    # When User clicks the PERFORM/STOP button:
    #   - If in STOP RUN mode, set the stop flag and let the current task finish.
    #   - Otherwise, start the run.
    $script:btnPerformSelectedOptions.Add_Click({
        if ($script:btnPerformSelectedOptions.Text -eq "STOP`nRUN") {
            $script:stopRequested = $true
        } else {
            Perform-SelectedOptions
        }
    })
    # NOTE: function Perform-SelectedOptions is in Back-End.ps1, 
    #       This is the link between the front-end and back-end, where the button click 
    #       in the UI triggers the execution of the core logic to apply the selected Options 
    #       This separation of concerns allows for better organization and maintainability of 
    #       the code, as

    # Helpers for $script:btnPrintOptionsSelected
    # -------------------------------------------
    $script:btnPrintOptionsSelected.Add_Click({ Print-OptionsSelected })

    $script:btnPrintOptionsSelected.Add_MouseEnter({
        if ($script:isScrolling) { return }
        $script:isHoveringOverOption = $true
        if ($this.Tag.Heading -and $this.Tag.Advice) {
            $script:GroupHeading.Text  = $this.Tag.Heading
            $script:adviceHeading.Text = ""
            $script:adviceRTbox.Rtf    = $this.Tag.Advice
        }
    })

    # Helpers for $script:btnPrintTaskLog
    # ------------------------------------
    $script:btnPrintTaskLog.Add_MouseEnter({
        if ($script:isScrolling) { return }
        $script:isHoveringOverOption = $true
        if ($this.Tag.Heading -and $this.Tag.Advice) {
            $script:GroupHeading.Text  = $this.Tag.Heading
            $script:adviceHeading.Text = ""
            $script:adviceRTbox.Rtf    = $this.Tag.Advice
        }
    })

    # Helpers for $script:btnSaveOptionsUsed
    # ----------------------------------------
    $script:btnSaveOptionsUsed.Add_MouseEnter({
        if ($script:isScrolling) { return }
        $script:isHoveringOverOption = $true
        if ($this.Tag.Heading -and $this.Tag.Advice) {
            $script:GroupHeading.Text  = $this.Tag.Heading
            $script:adviceHeading.Text = ""
            $script:adviceRTbox.Rtf    = $this.Tag.Advice
        }
    })

    # Helpers for $script:btnPrintAdvice
    # ----------------------------------
    $script:btnPrintAdvice.Add_Click({ Print-AdvicePanel })


    # Helpers for $script:btnSelectAllRecommended
    # ----------------------------
    $script:btnSelectAllRecommended.Add_MouseEnter({
        if ($script:isScrolling) { return }
        $script:isHoveringOverOption = $true
            if ($this.Tag.Heading -and $this.Tag.Advice) {
                $script:GroupHeading.Text  = $this.Tag.Heading
                $script:adviceHeading.Text = ""
                $script:adviceRTbox.Rtf    = $this.Tag.Advice
            } 
    })


    # Helpers for $script:cmbTaskLogOptions
    # -------------------------------------
    $script:cmbTaskLogOptions.Add_MouseEnter({
        if ($script:isScrolling) { return }
        $script:isHoveringOverOption = $true
        if ($this.Tag.Heading -and $this.Tag.Advice) {
            $script:GroupHeading.Text  = $this.Tag.Heading
            $script:adviceHeading.Text = ""
            $script:adviceRTbox.Rtf    = $this.Tag.Advice
        }
    })


    $script:cmbTaskLogOptions.Add_SelectedIndexChanged({
        # When user selects a different Option from the Task Log Options combo box,
        # update the Task Log rich text box and hide the Continue button
        Update-TaskLogRTbox  # This function is in Back-End.ps1, 
                             # and updates the Task Log rich text box 
        $script:btnContinue.Visible = $false
    })


    # Helpers for $script:form  
    # ------------------------
    $script:form.Add_MouseMove({
        # When mouse moves over the form, if user was previously hovering over an Option, 
        # check if they have moved away from the advice panel, 
        # and if so, restore the advice panel to show general advice   
        if ($script:isScrolling) { return }
        $pos = $script:form.PointToClient([System.Windows.Forms.Cursor]::Position)

        $insideAdvicePanel = (
            $pos.X -ge $script:advicePanel.Left  -and
            $pos.X -le ($script:advicePanel.Left + $script:advicePanel.Width) -and
            $pos.Y -ge $script:advicePanel.Top   -and
            $pos.Y -le ($script:advicePanel.Top  + $script:advicePanel.Height)
        )
        # (Reserved for future use)
    })

    $script:form.Add_Resize({
        # When the form is resized, adjust the sizes and positions of the advice panel 
        #and its contents accordingly to maintain a responsive layout.

        # Capture initial size on first resize event (when form is actually shown)
        if ($null -eq $script:initialFormWidth) {
            $script:initialFormWidth  = $script:form.ClientSize.Width
            $script:initialFormHeight = $script:form.ClientSize.Height
            return  # Don't adjust on first resize
        }
        $deltaWidth  = $script:form.ClientSize.Width - $script:initialFormWidth
        $deltaHeight = $script:form.ClientSize.Height - $script:initialFormHeight

        $script:panelLeft.Height    = 465 + $deltaHeight
        $script:advicePanel.Width   = 462 + $deltaWidth
        $script:advicePanel.Height  = 465 + $deltaHeight
        $script:adviceHeading.Width = 462 + $deltaWidth
        $script:adviceRTbox.Width   = 442 + $deltaWidth
        $script:adviceRTbox.Height  = 425 + $deltaHeight
        $script:adviceRTbox.Height  = 425 + $deltaHeight
        $script:TaskLogRTbox.Width  = 442 + $deltaWidth
        $script:TaskLogRTbox.Height = 425 + $deltaHeight

        $script:panelDivider.Width             = $script:panelLeft.Width
        $script:panelDivider.Location          = [System.Drawing.Point]::new($script:panelLeft.Left, $script:panelLeft.Bottom)
        $script:optionsControlPanel.Top        = $script:panelDivider.Bottom + 32
        $script:optionsControlPanelLabel.Top   = $script:optionsControlPanel.Top - $script:optLblMid
        $script:printControlPanel.Top          = $script:optionsControlPanel.Top
        $script:lblPrintControlPanel.Top       = $script:printControlPanel.Top - $script:printLblMid + 2
        $script:TaskLogControlPanel.Top        = $script:optionsControlPanel.Top
        $script:lblTaskLogControlPanel.Top     = $script:TaskLogControlPanel.Top - $script:taskLogLblMid
        $script:btnPerformSelectedOptions.Top  = $script:optionsControlPanel.Top
        $script:postPerformPanel.Top           = $script:optionsControlPanel.Top
        $script:lblPostPerformPanel.Top        = $script:postPerformPanel.Top - $script:postPerformLblMid + 2
        $script:btnSaveOptionsUsed.Top         = $script:optionsControlPanel.Top
    })


    # Helpers for $script:panelLeft (scroll tip)
    # ------------------------------------------
    $script:panelLeft.Add_MouseMove({
        # When mouse moves over the left panel, 
        # check if it's near the scrollbar and show a tooltip if it is. 
        # This helps users discover that there are more Options to scroll through.     
        if ($script:isScrolling) { return }
        $screenPos   = [System.Windows.Forms.Cursor]::Position
        $panelBounds = $script:panelLeft.RectangleToScreen($script:panelLeft.ClientRectangle)

        $hoverZoneWidth  = 100
        $hoverZoneLeft   = $panelBounds.Right - $hoverZoneWidth

        # Dynamically find the top of the first visible Option checkbox
        $hoverZoneTop = $panelBounds.Top
        $found = $false

        foreach ($ctrl in $script:panelLeft.Controls) {
            if ($found) { break }
            if ($ctrl -is [System.Windows.Forms.Panel]) {
                foreach ($child in $ctrl.Controls) {
                    if ($child -is [System.Windows.Forms.CheckBox] -and $child.Visible) {
                        # Get Y of checkbox relative to panelLeft's visible area
                        $panelScreenY = $script:panelLeft.PointToScreen([System.Drawing.Point]::Empty).Y
                        $optionPanelY = $ctrl.PointToScreen([System.Drawing.Point]::Empty).Y
                        $relativeY = $optionPanelY - $panelScreenY
                        $hoverZoneTop = $panelBounds.Top + $relativeY + $ctrl.Height
                        $found = $true
                        break
                    }
                }
            }
        }
        $hoverZoneBottom = $panelBounds.Bottom

        $insideScrollbarZone = (
            $script:panelLeft.VerticalScroll.Visible -and
            $screenPos.X -ge $hoverZoneLeft -and
            $screenPos.X -le $panelBounds.Right -and
            $screenPos.Y -ge $hoverZoneTop -and
            $screenPos.Y -le $hoverZoneBottom
        )
        if ($insideScrollbarZone) {
            $debugMsg = "ScrollTip: Y=$($screenPos.Y), Top=$($hoverZoneTop), Bottom=$($hoverZoneBottom)"
            $script:scrollTip.SetToolTip($script:panelLeft, "Use the Scrollbar to see ALL Options available.\n$debugMsg")
        } else {
            $debugMsg = "ScrollTip: Y=$($screenPos.Y), Top=$($hoverZoneTop), Bottom=$($hoverZoneBottom)"
            $script:scrollTip.SetToolTip($script:panelLeft, $debugMsg)
        }
    })

    $script:panelLeft.Add_MouseLeave({
        # When mouse leaves the left panel, hide the tooltip.
        if ($script:isScrolling) { return }
        $script:scrollTip.SetToolTip($script:panelLeft, "")
    })
    


    # Helpers for $script:panelLeft
    # -----------------------------    
    $script:panelLeft.Add_MouseEnter({
        # When mouse enters the Options panel, if user was previously hovering over an Option, restore the advice panel to show general advice
        $script:panelLeft.Focus()
    })

    $script:panelLeft.Add_MouseLeave({
        # When mouse leaves the Options panel, if user was previously hovering over an Option, restore the advice panel to show general advice
        if ($script:isScrolling) { return }
        $script:scrollTip.SetToolTip($script:panelLeft, "")
    })

    $script:panelLeft.Add_MouseMove({
        # When mouse moves within the Options panel, 
        # if user is near the scrollbar, 
        # show a tooltip to indicate that they can scroll to see more Options
        $screenPos   = [System.Windows.Forms.Cursor]::Position
        $panelBounds = $script:panelLeft.RectangleToScreen($script:panelLeft.ClientRectangle)

        $hoverZoneWidth  = 100
        $hoverZoneLeft   = $panelBounds.Right - $hoverZoneWidth
        $hoverZoneTop    = $panelBounds.Top
        $hoverZoneBottom = $panelBounds.Bottom

        $insideScrollbarZone = (
            $script:panelLeft.VerticalScroll.Visible -and
            $screenPos.X -ge $hoverZoneLeft -and
            $screenPos.X -le $panelBounds.Right -and
            $screenPos.Y -ge $hoverZoneTop -and
            $screenPos.Y -le $hoverZoneBottom
        )

        if ($insideScrollbarZone) {
            $script:scrollTip.SetToolTip($script:panelLeft, "Use the Scrollbar to see ALL Options available.")
        } else {
            $script:scrollTip.SetToolTip($script:panelLeft, "")
        }
    })

    $script:panelLeft.Add_MouseWheel({
        # When user scrolls with mouse wheel over the Options panel, 
        # set isScrolling flag to true and start/reset the scroll timer 
        # to prevent advice panel from changing while scrolling
        $script:isScrolling = $true
        $script:scrollTimer.Start()
    })

    $script:panelLeft.Add_Scroll({
        # When user scrolls with the scrollbar, 
        # set isScrolling flag to true and start/reset the scroll timer 
        # to prevent advice panel from changing while scrolling
        $script:isScrolling = $true
        $script:scrollTimer.Stop()
        $script:scrollTimer.Start()
    })

 
    # Click event handler for the 'Reset to Defaults' button 
    # to reset all Options to their default states
    $script:btnSelectAllRecommended.Add_Click({   
        $confirmation = [System.Windows.Forms.MessageBox]::Show("Are you sure you want to reset all Options to their default states?", "Confirm Reset", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($confirmation -eq [System.Windows.Forms.DialogResult]::Yes) {
            On-ResetDefaultsClick
        }
    })


    $script:scrollTimer.Add_Tick({
        # After a short delay of no scrolling, 
        # reset the isScrolling flag and restore the advice panel to show general advice
        $script:isScrolling = $false
        $script:scrollTimer.Stop()
    })
    
} # END of - function Control-InteractionHandlers


# ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# Functions called by Control Interaction Handlers - like Restore-AdvicePanel and
# BoilerPlateText, are defined below this line to keep the code organized and maintainable.
# They are lised in alphabetical order as several of them are called from multiple places, 
# and this way we can easily find them when needed.
# ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++


# =======================================================================================
# function - Already-PinnedToStartMenu  
# =======================================================================================
function Already-PinnedToStartMenu {
# PURPOSE: Robustly check if an app is pinned toStart Menu by parsing the Start Menu layout.
#          This is more reliable than checking the binary database directly, which can have encoding and formatting
#          inconsistencies. By exporting the Start Layout to JSON, we can perform a structured search for the app name.

    param(
        [Parameter(Mandatory=$true)]
        [string]$AppName
    )

    # Use Export-StartLayout and JSON parsing for robust detection
    $tempJson = Join-Path $env:TEMP "StartLayout.json"
    try {
        Export-StartLayout -Path $tempJson -ErrorAction Stop
        $json = Get-Content $tempJson -Raw | ConvertFrom-Json
        # Try to get PackageName/AppID from $script:AppLookup if available
        $lookup = $null
        if ($script:AppLookup -and $script:AppLookup.ContainsKey($AppName)) {
            $lookup = $script:AppLookup[$AppName]
        }
        $possibleMatches = @($AppName)
        if ($lookup) {
            if ($lookup.PackageName) { $possibleMatches += $lookup.PackageName }
            if ($lookup.AppID) { $possibleMatches += $lookup.AppID }
        }
        foreach ($item in $json.pinnedList) {
            foreach ($prop in $item.PSObject.Properties) {
                if ($null -ne $prop.Value -and $prop.Value -is [string]) {
                    foreach ($needle in $possibleMatches) {
                        if ($prop.Value -like "*$needle*") {
                            return $true
                        }
                    }
                }
            }
        }
        return $false
    } catch {
        return $false
    }

} # END of - function Already-PinnedToStartMenu


# ========================================================================== 
# function - BoilerPlateText
# ========================================================================== 
function BoilerPlateText {
    param(
        [Parameter(Mandatory)][string]$groupName,
        [Parameter(Mandatory)][string]$CURRENT_OptionName
    )
    $localDEBUG_Mode = $false

    $normalizedGroupName = $groupName -replace 'Task[ -]?Bar', 'Taskbar'

    $isRelevantOption = (
        (   $CURRENT_OptionName.StartsWith('Please PIN') -or
            $CURRENT_OptionName.StartsWith('Please ADD')
        ) -and $CURRENT_OptionName.EndsWith('MANUALLY')
    ) -or (
        $groupName -match 'Select Default Browser'
    )

    if ($localDEBUG_Mode) {
        Write-Host "[DEBUG] BoilerPlateText called with:" -ForegroundColor Cyan
        Write-Host "  groupName: $groupName" -ForegroundColor Cyan
        Write-Host "  CURRENT_OptionName: $CURRENT_OptionName" -ForegroundColor Cyan
        Write-Host "  isRelevantOption: $isRelevantOption" -ForegroundColor Cyan
    }

    # FIX: this guard must be OUTSIDE the debug block so it fires in production
    if (-not $isRelevantOption) {
        return ""
    }

    # ... rest of the boilerplate generation unchanged ...
    If ($localDEBUG_Mode) {
        if ($SpecifiedText) {
            if ($localDEBUG_Mode) { Write-Host "  Returning SpecifiedText (not relevant option)" -ForegroundColor Cyan }
            return $SpecifiedText
        }
    }
    # Strip "Please" from $CURRENT_OptionName
    $OptionRequested = $CURRENT_OptionName -replace '^\s*Please ', ''

    # Extract app name by removing known prefixes and suffixes
    $appText = $CURRENT_OptionName
    $appText = $appText -replace '^\s*Please PIN(/UNPIN)?\s*', ''
    $appText = $appText -replace '^\s*Please ADD\s*', ''
    $appText = $appText -replace '^\s*Please INSTALL\s*', ''
    $appText = $appText -replace '\s*- MANUALLY$', ''
    $appText = $appText -replace '\s*MANUALLY$', ''
    $appText = $appText -replace '\s*Service$', ''
    $appText = $appText -replace '\s*to Taskbar$', ''
    $appText = $appText.Trim()
    
    if ($normalizedGroupName -match 'Start Menu') {
        $boilerplate = @"
{\rtf1
\b \fs22Reason - for having to $OptionRequested\b0 \par
Microsoft does not permit apps to be automatically pinned to the Start Menu for security and reasons.  
This prevents unwanted apps, malware, or third-party installers from cluttering your Start Menu or 
overriding your preferences without your knowledge.\par
\par
Only you, as the user, can choose which apps appear there, ensuring your Start Menu remains organized 
and free from unwanted shortcuts.\par
\par
\b To PIN $appText to the Start Menu : \b0 \par
    1. Click the \b Start Button \b0 .\par
    2. In the \b View: \b0 Control on the right, select \b "List"\b0.\par
    3. Find $appText in your List of Apps.\par
    4. \b Right-click "$appText"\b0. \par
    5. Select \b "Pin to Start Menu" \b0 .\par
\par
To unpin $appText, \b right-click \b0 its icon in the \b Start Menu \b0 and select \b Unpin from Start Menu\b0.\par
\par
\b Note: \b0 This tool cannot automate pinning apps, for the reasons given above.  
You must PIN or UNPIN them manually using the steps above.\par
}
"@
    } elseif ($normalizedGroupName -match 'Taskbar') {
        $normalizedgroupname = 'Taskbar'
        $boilerplate = @"
{\rtf1
\b \fs22Reason - for having to $OptionRequested\b0 \par
Microsoft does not permit apps to be automatically pinned to the Taskbar for security reasons.  
This prevents unwanted apps, malware, or third-party installers from cluttering your Taskbar or overriding your preferences without your knowledge.\par
\par
Only you, as the user, can choose which apps appear there, ensuring your Taskbar remains organized and free from unwanted shortcuts.\par
\par
\b To PIN $appText to the Taskbar : \b0 \par
    1. Click the \b Start Button \b0 to open the Start Menu, \par
    2. Find $appText in your list of apps, \par
    3. \b Right-click "$appText"\b0. \par
    4. Select \b "Pin to Taskbar" \b0.\par
\par
To unpin $appText, \b right-click \b0 its icon on the \b Taskbar \b0 and select \b Unpin from Taskbar\b0.\par
\par
\b Note: \b0 This tool cannot automate pinning apps, for the reasons given above.  
You must PIN them manually using the steps above.\par
}
"@
   } elseif ($normalizedGroupName -match 'Select Default Browser') {

        $browserName = $CURRENT_OptionName `
            -replace '^INSTALL\s+', '' `
            -replace '^SELECT\s+', '' `
            -replace '\s+SELECTED$', ''

        if ($CURRENT_OptionName -like "* SELECTED") {
            $boilerplate = @"
{\rtf1\ansi\fs22
\b $browserName \b0 is currently your Default Browser.  
Ticking or unticking its Checkbox will make no difference.  
This Option is for information only.  
On a new Windows installation it will normally be \b Microsoft Edge SELECTED\b0.  \par
\par
Before you can select anything else, you will have to install it and then select it:\par
\b * INSTALL \b0  enables you to install as many of the Browsers shown as you like.\par
\b * SELECT \b0  indicates that it has already been installed.  
Selecting any one of them will uncheck all other Browsers.  
When you subsequently click \b PERFORM Selected Options\b0, it will become your Default Browser.\par
}
"@
        } elseif ($CURRENT_OptionName -like "INSTALL *") {
            $boilerplate = @"
{\rtf1\ansi\fs22
\b $browserName \b0 is not currently installed.\par
\par
\b INSTALL $browserName \b0 will install $browserName when you subsequently click 
\b PERFORM Selected Options\b0.  (You may INSTALL as many Browsers, at a time, as you like.)  \par
\b   * SELECT $browserName \b0 will be displayed if installation successful.  \par
\b   * INSTALL $browserName \b0 will remain if installation unsuccessful.  \par
}
"@
        } elseif ($CURRENT_OptionName -like "SELECT *") {
            $boilerplate = @"
{\rtf1\ansi\fs22
\b $browserName \b0 is already installed, and is \b available \b0 for selection as your Default Browser.  
When you do so, the Checkboxes of all other installed Browsers will be cleared, because you can only have one default.\par
\par
When you click \b PERFORM Selected Options\b0 :\par
    1. \b Settings > Apps > Default Apps\b0  will be opened for you.\par
    2. Scroll down to find \b $browserName\b0 .  Click it.\par
    3. You will see \b Make $browserName your default browser\b0  at the top.\par
    4. Click \b Set Default\b0 .\par
}
"@
        }
    }


    If ($localDEBUG_Mode) {
        Write-Host "[DEBUG] BoilerPlateText returning (first 200 chars):" -ForegroundColor Cyan
        Write-Host ($boilerplate.Substring(0, [Math]::Min(200, $boilerplate.Length))) -ForegroundColor Cyan
    }
    return $boilerplate

} # END of - function BoilerPlateText

# =======================================================================================
# function - Concatenate-RTF
# =======================================================================================
function Concatenate-RTF {
    param(
        [Parameter(Mandatory)][string]$rtf1,
        [Parameter(Mandatory)][string]$rtf2
    )

    if ([string]::IsNullOrWhiteSpace($rtf1) -and `
        [string]::IsNullOrWhiteSpace($rtf2)) { return $null }

    $isMinimalRtf = { param($rtf) $rtf -match '^\{\\rtf1\\s*\\par\s*\}$' }

    if ([string]::IsNullOrWhiteSpace($rtf1) `
        -or (&$isMinimalRtf $rtf1)) {
        if (-not [string]::IsNullOrWhiteSpace($rtf2) -and `
            -not (&$isMinimalRtf $rtf2)) `
            { return $rtf2 }
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($rtf2) `
        -or (&$isMinimalRtf $rtf2)) {
        if (-not [string]::IsNullOrWhiteSpace($rtf1) -and `
            -not (&$isMinimalRtf $rtf1)) { return $rtf1 }
        return $null
    }

    # Strip outer braces from both bodies
    $body1 = $rtf1 -replace '^\{\\rtf1[^\r\n]*', '' # Remove opening declaration
    $body1 = $body1.Trim().TrimEnd('}').Trim()

    $body2 = $rtf2 -replace '^\{\\rtf1[^\r\n]*', '' # Remove opening declaration  
    $body2 = $body2.Trim().TrimEnd('}').Trim()

    # Merge with shared header and paragraph break
    $merged = "{\rtf1\ansi\fs22 $body1 \par $body2 }"
    return $merged

} # END of - function Concatenate-RTF


# ========================================================================== 
# function - Display-AdviceFor
# ========================================================================== 

function Display-AdviceFor {
    # PURPOSE:      
    #   This function displays the advice for the Option as shown in the UI (CurrentOption) 
    #   It updates the advice heading to match the current Option name.         

    param(
        [Parameter(Mandatory)][string]$GroupName,
        [Parameter(Mandatory)][string]$CURRENT_OptionName
    )
    $localDEBUG_Mode = $false
    if ($localDEBUG_Mode) {
        Write-Host "[DEBUG] Display-AdviceFor called with:" -ForegroundColor Cyan
        Write-Host "  GroupName: '$GroupName'" -ForegroundColor Cyan
        Write-Host "  CURRENT_OptionName: '$CURRENT_OptionName'" -ForegroundColor Cyan
    }

    # Always update the advice heading to match the current Option name
    $script:adviceHeading.Text = $CURRENT_OptionName

    # --- Initialise ---
    $adviceRtf       = ""
    $boilerText      = ""
    $isBrowserChoice = ($GroupName -eq 'Select Default Browser')
    $isManuallyOption = (
        ($CURRENT_OptionName.StartsWith('Please PIN') -or
         $CURRENT_OptionName.StartsWith('Please ADD')
        ) -and $CURRENT_OptionName.EndsWith('MANUALLY')
    )

    # --- Find advice ---

    # 1. Exact match - specific advice for the full current option name 
    if ($script:adviceByGroupAndOption.ContainsKey($GroupName) -and 
        $script:adviceByGroupAndOption[$GroupName].ContainsKey($CURRENT_OptionName)) {
        $adviceRtf = $script:adviceByGroupAndOption[$GroupName][$CURRENT_OptionName]
        if ($localDEBUG_Mode) { Write-Host "[DEBUG] Path: Exact match - Key: $CURRENT_OptionName" -ForegroundColor Green }
    }

    # 2. Special Case: Please PIN/ADD ... MANUALLY
    elseif ($isManuallyOption) {
        if ($script:adviceByGroupAndOption.ContainsKey($GroupName) -and 
            $script:adviceByGroupAndOption[$GroupName].ContainsKey($CURRENT_OptionName.Trim())) {
            $adviceRtf = $script:adviceByGroupAndOption[$GroupName][$CURRENT_OptionName.Trim()]
        }
        if ($localDEBUG_Mode) { Write-Host "[DEBUG] Path: PIN/ADD MANUALLY" -ForegroundColor Yellow }
    }

    # 3. Special Case: Select Default Browser group
    elseif ($isBrowserChoice) {
        $basic = BasicOptionNameOf -CurrentOptionName $CURRENT_OptionName
        if ($script:adviceByGroupAndOption.ContainsKey($GroupName) -and
            $script:adviceByGroupAndOption[$GroupName].ContainsKey($basic)) {
            $adviceRtf = $script:adviceByGroupAndOption[$GroupName][$basic]
            if ($localDEBUG_Mode) { Write-Host "[DEBUG] Path: Browser Choice - Found advice for: '$basic'" -ForegroundColor Green }
        } else {
            if ($localDEBUG_Mode) { Write-Host "[DEBUG] Path: Browser Choice - No advice for: '$basic'" -ForegroundColor Red }
        }
    }

    # 4. Special Case: Remove ... PIN or KEEP ... pinned
    elseif (
        $CURRENT_OptionName -match '^Remove (.+?) PIN from the (Start Menu|Taskbar)$' -or
        $CURRENT_OptionName -match '^KEEP (.+?) pinned to (Start Menu|Taskbar)$'
    ) {
        if ($CURRENT_OptionName -match '^Remove (.+?) PIN from the (Start Menu|Taskbar)$') {
            $item     = $matches[1].Trim()
            $location = $matches[2].Trim()
        } elseif ($CURRENT_OptionName -match '^KEEP (.+?) pinned to (Start Menu|Taskbar)$') {
            $item     = $matches[1].Trim()
            $location = $matches[2].Trim()
        } else {
            $item     = ''
            $location = ''
        }
        $keepForm   = "KEEP $item pinned to $location"
        $removeForm = "Remove $item PIN from the $location"
        if ($script:adviceByGroupAndOption.ContainsKey($GroupName)) {
            if ($script:adviceByGroupAndOption[$GroupName].ContainsKey($keepForm)) {
                $adviceRtf = $script:adviceByGroupAndOption[$GroupName][$keepForm]
                if ($localDEBUG_Mode) { Write-Host "[DEBUG] Path: Canonical KEEP form - Key: $keepForm" -ForegroundColor Yellow }
            } elseif ($script:adviceByGroupAndOption[$GroupName].ContainsKey($removeForm)) {
                $adviceRtf = $script:adviceByGroupAndOption[$GroupName][$removeForm]
                if ($localDEBUG_Mode) { Write-Host "[DEBUG] Path: Canonical REMOVE form - Key: $removeForm" -ForegroundColor Yellow }
            }
        }
    }

    # 5. Try group+basic key (for fallback/stripped variants)
    elseif ($script:adviceByGroupAndOption.ContainsKey($GroupName)) {
        $basic = BasicOptionNameOf -CurrentOptionName $CURRENT_OptionName
        if ($script:adviceByGroupAndOption[$GroupName].ContainsKey($basic)) {
            $adviceRtf = $script:adviceByGroupAndOption[$GroupName][$basic]
            if ($localDEBUG_Mode) { Write-Host "[DEBUG] Path: Basic key fallback - Key: $basic" -ForegroundColor Yellow }
        } else {
            if ($localDEBUG_Mode) { Write-Host "[DEBUG] Path: No basic key advice found - Key tried: $basic" -ForegroundColor Red }
        }
    }

    # --- Append BoilerPlateText where needed ---
    if ($isBrowserChoice -or $isManuallyOption) {
        $boilerText = BoilerPlateText -groupName $GroupName -CURRENT_OptionName $CURRENT_OptionName
    } else {
        $boilerText = ""
    }

    # --- Combine advice and boilerplate ---
    $safeAdvice = Ensure-RtfHeaderFooter $adviceRtf
    $safeBoiler = Ensure-RtfHeaderFooter $boilerText

    if ($safeAdvice -and $safeAdvice -ne '{\rtf1\ansi\fs22 \par}') {
        if ($safeBoiler -and $safeBoiler -ne '{\rtf1\ansi\fs22 \par}') {
            If ($isBrowserChoice){
                # Because $safeAdvice is so long, User may not see $safeBoiler
                $adviceRtf = Concatenate-RTF $safeBoiler $safeAdvice 
            } else{
                $adviceRtf = Concatenate-RTF $safeAdvice $safeBoiler
            }
        } else {
            $adviceRtf = $safeAdvice
        }
    } elseif ($safeBoiler -and $safeBoiler -ne '{\rtf1\ansi\fs22 \par}') {
        $adviceRtf = $safeBoiler
    }

    # 6. Final fallback: if no advice found, show a default message
    if (-not $adviceRtf) {
        $adviceRtf = "{\rtf1\ansi\fs22 \par No advice available for this option.}"
    }

    try {
        $script:adviceRTbox.Rtf = $adviceRtf
    } catch {
        $plain = $adviceRtf -replace '(?s)\\par', "`n" -replace '{\\rtf1.*?}', '' -replace '[{}\\]', ''
        $script:adviceRTbox.Text = $plain.Trim()
    }

} # END of - function Display-AdviceFor
 

# =======================================================================================
# function - Ensure-RtfHeaderFooter
# =======================================================================================
function Ensure-RtfHeaderFooter {
    param([string]$rtf)
    if ([string]::IsNullOrWhiteSpace($rtf)) {
        return $null
    }
    $trimmed = $rtf.Trim()
    # If it's already minimal/empty RTF, treat as empty
    if ($trimmed -eq '{\rtf1\ansi\fs22 \par}' -or $trimmed -eq '{\rtf1  \par }' -or $trimmed -match '^\{\\rtf1.*?\\par\s*\}$') {
        return $null
    }
    if ($rtf -notmatch '^\{\\rtf1') {
        return "{\rtf1\ansi\fs22 $rtf}"
    }
    return $rtf
}

# =======================================================================================
# function - Enable-PanelWheel
# =======================================================================================
function Enable-PanelWheel($ctrl) { 
    # PURPOSE: Enables mouse wheel scrolling for a given control and all its child controls,
    #          by redirecting the MouseWheel event to the parent panelLeft's AutoScrollPosition.

    # IT HAS TO BELEFT IN THIS FUNCTION, it cannot be added in Define-Form
    # or the handler will capture the wrong panelLeft variable and not scroll at all.
    
    # Add MouseWheel event handler to the control.  
    # So, it has to be added to every control in the hierarchy under panelLeft, 
    # since MouseWheel events do not bubble up.   

    # The handler calculates the new scroll position based on the wheel delta 
    # and updates panelLeft's AutoScrollPosition accordingly.
    $ctrl.Add_MouseWheel({
        $delta = $_.Delta

        # Always scroll the REAL panelLeft, never a captured variable
        $current = -$script:panelLeft.AutoScrollPosition.Y
        $newY = $current - [int]($delta / 2)  # Reduce scroll speed by dividing delta
        if ($newY -lt 0) { $newY = 0 }

        $script:panelLeft.AutoScrollPosition =
            New-Object System.Drawing.Point(0, $newY)
    })

    foreach ($child in $ctrl.Controls) {
        Enable-PanelWheel $child
    }
} # END of - function Enable-PanelWheel


# =======================================================================================
# function - Enter-StopRunMode
# =======================================================================================
function Enter-StopRunMode {
    # PURPOSE: Transforms the PERFORM button into a STOP RUN button while a run is in progress.
    #          Called at the very start of Perform-SelectedOptions.
    $script:btnPerformSelectedOptions.Text      = "STOP`nRUN"
    $script:btnPerformSelectedOptions.BackColor = [System.Drawing.Color]::Red
    $script:btnPerformSelectedOptions.ForeColor = [System.Drawing.Color]::Black
    $script:btnPerformSelectedOptions.Font      = New-Object System.Drawing.Font(
        "Arial Black",
        18,
        [System.Drawing.FontStyle]::Bold,
        [System.Drawing.GraphicsUnit]::Point)
    $script:btnPerformSelectedOptions.Tag = @{
        Mode    = 'StopRun'
        Heading = "STOP RUN"
        Advice  = "{\rtf1\ansi\fs22\b0 " +
            "Click this Button to \b STOP \b0 the run \b after the current task completes\b0 .  \par\par " +
            "Any tasks that have \b already completed\b0  will remain in effect.  " +
            "Tasks that have \b not yet started\b0  will be skipped. \par\par " +
            "After stopping, the Recommended Options on the left will be updated " +
            "to reflect the current state of your PC. }"
    }
} # END of - function Enter-StopRunMode


# =======================================================================================
# function - Exit-StopRunMode
# =======================================================================================
function Exit-StopRunMode {
    # PURPOSE: Restores the PERFORM button to its normal state after a run ends (complete or stopped).
    #          Also shows the post-PERFORM print panel.
    $script:btnPerformSelectedOptions.Text      = "PERFORM`nSelected`nOptions"
    $script:btnPerformSelectedOptions.BackColor = $script:form.BackColor
    $script:btnPerformSelectedOptions.ForeColor = [System.Drawing.SystemColors]::ControlText
    $script:btnPerformSelectedOptions.Font      = New-Object System.Drawing.Font(
        "Segoe UI", 10, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Point)
    $script:btnPerformSelectedOptions.Tag = @{
        Mode    = 'Perform'
        Heading = "PERFORM Selected Options"
        Advice  = @(
            "{\rtf1\ansi\fs22"
            "\b0 This Button actually\b  PERFORMS\b0  all the currently \b Selected Options\b0  on the left.  "
            "A \b Task Log\b0  will appear here once execution begins.  \par"
            "\par"
            "\b Before making any changes, the DeBloater will automatically create a System Restore Point.\b0  "
            "This typically takes 10-30 seconds.  Please be patient and do not interrupt the process.  "
            "If you ever need to undo the changes, go to "
            "\b Settings > System > About > System Protection > System Restore\b0 . \par"
            "\par"
            "Use the \b Task Log Required\b0  dropdown to the left to choose between: \par"
            "\b       Continuous \b0 Task Log,\par"
            "\b       Detailed \b0 Task Log, or \par"
            "\b       Summary \b0 Task Log\par"
            "BEFORE clicking this Button. \par"
            "\par"
            "Point at the \b Task Log Required\b0  dropdown for more details. \par"
            "}"
        ) -join "`n"
    }
    $script:btnPerformSelectedOptions.Enabled = $true

    # Show post-PERFORM print panel
    if ($script:postPerformPanel)    { $script:postPerformPanel.Visible    = $true }
    if ($script:lblPostPerformPanel) { $script:lblPostPerformPanel.Visible = $true }
} # END of - function Exit-StopRunMode


# =======================================================================================
# Function - Export-AdvicePanelToWord
# =======================================================================================

function Export-AdvicePanelToWord {
# PURPOSE:
#   Exports the current Advice Panel content to a Word document, appending if the file already exists.

    param()
    # Prompt user to select documentation file path the first time this is called in a session
    if (-not (Get-Variable -Name WordFilePath -Scope Script -ErrorAction SilentlyContinue)) {
        $script:WordFilePath = $null
    }
    if (-not $script:WordFilePath) {
        Add-Type -AssemblyName System.Windows.Forms
        $saveFileDialog = New-Object System.Windows.Forms.SaveFileDialog
        $saveFileDialog.Title = "Select or Create Documentation File (Append if exists)"
        $saveFileDialog.Filter = "Word Documents (*.docx)|*.docx|All Files (*.*)|*.*"
        $saveFileDialog.InitialDirectory = [Environment]::GetFolderPath('MyDocuments')
        $saveFileDialog.FileName = "DeBloater-Advice.docx"
        $saveFileDialog.OverwritePrompt = $false
        $saveFileDialog.CheckFileExists = $false
        $saveFileDialog.CheckPathExists = $true
        if ($saveFileDialog.ShowDialog($script:form) -eq [System.Windows.Forms.DialogResult]::OK) {
            $script:WordFilePath = $saveFileDialog.FileName
        } else {
            # User cancelled, abort save
            return
        }
    }

    # ...existing code...
    $isLocked = $false
    $lockedReason = ""
    # Additional: Check if winword process has file open (USB reliability)
    if (-not $isLocked -and (Test-Path $script:WordFilePath)) {
        try {
            $openFile = $false
            $fileName = [System.IO.Path]::GetFileName($script:WordFilePath)
            $procList = Get-Process -Name winword -ErrorAction SilentlyContinue
            foreach ($proc in $procList) {
                $handleOutput = (Get-Process -Id $proc.Id | Get-ProcessOpenFile | Where-Object { $_.Name -like "*$fileName" })
                if ($handleOutput) {
                    $openFile = $true
                    $lockedReason = "Open by winword process."
                    "Process check: File is open by winword process." | Out-File -FilePath $logPath -Append -Encoding UTF8
                    break
                }
            }
            if ($openFile) { $isLocked = $true }
        } catch {}
    }
        # Enhanced: Check if Word document is open in any running Word instance (COM) or locked by file system
        $logPath = $global:DeBloaterErrorLog
        if (Test-Path $script:WordFilePath) {
            # 1. Try file lock check (as before)
            try {
                $fs = [System.IO.File]::Open($script:WordFilePath, 'Open', 'Write', 'None')
                $fs.Close()
            } catch {
                $isLocked = $true
                $lockedReason = "File lock: " + $_.Exception.Message
                "File lock check: $($lockedReason)" | Out-File -FilePath $logPath -Append -Encoding UTF8
            }
            # 2. Check all running Word instances for open document
            $docClosed = $false
            try {
                $wordApp = [Runtime.InteropServices.Marshal]::GetActiveObject('Word.Application')
                if ($wordApp -ne $null) {
                    $docClosed = $false
                    foreach ($doc in $wordApp.Documents) {
                        if ($doc.FullName -eq $script:WordFilePath) {
                            # Force save and close the document
                            $doc.Save()
                            $doc.Close()
                            $docClosed = $true
                            $lockedReason = "Document was open in Word and has been saved and closed automatically."
                            "COM check: File was open in Word instance and has been closed." | Out-File -FilePath $logPath -Append -Encoding UTF8
                            break
                        }
                    }
                    # Always quit Word application after closing the document, even if other documents are open
                    $wordApp.Quit()
                    $lockedReason = "Document was open in Word, has been saved, closed, and Word application exited automatically. (All Word windows closed.)"
                    $isLocked = $false
                    [System.Runtime.Interopservices.Marshal]::ReleaseComObject($wordApp) | Out-Null
                }
            } catch {
                # Ignore if no running instance
            }
        }
        if ($isLocked -and -not $docClosed) {
            [System.Windows.Forms.MessageBox]::Show(
                "The documentation Word file is currently open or locked. Please close it in Word and try again.\n($lockedReason)",
                "Document In Use",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            "Displayed warning message box for locked document." | Out-File -FilePath $logPath -Append -Encoding UTF8
            # Only re-initialize the form if all required script variables are present
            if ($script:form -and $script:panelLeft -and $script:groups) {
                try { Define-Form } catch {}
            }
            return
        }
    # Ensure Word is installed
    $word = $null
    $doc = $null
    $selection = $null
    $wordCreated = $false
    try {
        try {
            $word = [Runtime.InteropServices.Marshal]::GetActiveObject('Word.Application')
        } catch {
            $word = $null
        }
        if (-not $word) {
            $word = New-Object -ComObject Word.Application
            $wordCreated = $true
        }
        $word.Visible = $false
        if (Test-Path $script:WordFilePath) {
            $doc = $word.Documents.Open($script:WordFilePath)
            $doc.Activate()
            $selection = $word.Selection
            $selection.EndKey(6) # Move to end of document
            $selection.TypeParagraph()
        } else {
            $doc = $word.Documents.Add()
            $selection = $word.Selection
            # Save as new file
            $doc.SaveAs([ref]$script:WordFilePath)
        }
    } catch {
        $msg = $_.Exception.Message
        [System.Windows.Forms.MessageBox]::Show(
            "Could not open or create Word document: $msg",
            "Document Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
        if ($word) { try { $word.Quit() } catch {} }
        if ($word) { try { [System.Runtime.Interopservices.Marshal]::ReleaseComObject($word) | Out-Null } catch {} }
        return
    }
    if (-not $doc -or -not $selection) {
        [System.Windows.Forms.MessageBox]::Show(
            "Word document or selection could not be initialized.",
            "Document Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
        if ($word) { try { $word.Quit() } catch {} }
        if ($word) { try { [System.Runtime.Interopservices.Marshal]::ReleaseComObject($word) | Out-Null } catch {} }
        return
    }

    # Insert Group heading as Heading 2
    $groupHeading = $script:GroupHeading.Text
    if ($groupHeading) {
        $selection.Style = 'Heading 2'
        $selection.TypeText($groupHeading)
        $selection.TypeParagraph()
    }

    # Insert Advice heading as Heading 3
    $adviceHeading = $script:adviceHeading.Text
    if ($adviceHeading) {
        $selection.Style = 'Heading 3'
        $selection.TypeText($adviceHeading)
        $selection.TypeParagraph()
    }


    # Set style to Normal for advice content (Word style, not RTF)
    $selection.Style = 'Normal'

    # Get current advice content (RTF) from the visible advice panel
    $rtf = $script:adviceRTbox.Rtf
    if ($script:adviceRTbox.Visible -eq $false -and $script:TaskLogRTbox.Visible) {
        $rtf = $script:TaskLogRTbox.Rtf
    }


    # Use clipboard to preserve formatting from RichTextBox to Word
    Add-Type -AssemblyName System.Windows.Forms
    $rtb = New-Object System.Windows.Forms.RichTextBox
    $rtb.Rtf = $rtf
    $rtb.SelectAll()
    $rtb.Copy()
    $selection.Paste()

    # Save or SaveAs
    $saveSuccess = $false
    try {
        if (-not (Test-Path $WordFilePath)) {
            $doc.SaveAs([ref]$WordFilePath)
        } else {
            $doc.Save()
        }
        $saveSuccess = $true
    } catch {
        $saveSuccess = $false
    }

    $doc.Close()
    if ($word) { try { $word.Quit() } catch {} }
    if ($word) { try { [System.Runtime.Interopservices.Marshal]::ReleaseComObject($word) | Out-Null } catch {} }
    Remove-Variable word, doc, selection, rtb, range -ErrorAction SilentlyContinue

    # Show 'Please Wait' dialog while waiting for Word to update the file
    $script:waitForm = New-Object System.Windows.Forms.Form
    $script:waitForm.Text = "Please WAIT"
    $script:waitForm.Size = [System.Drawing.Size]::new(520,220)
    $script:waitForm.StartPosition = "CenterScreen"
    $script:waitForm.FormBorderStyle = 'FixedDialog'
    $script:waitForm.ControlBox = $false
    $script:waitForm.MinimizeBox = $false
    $script:waitForm.MaximizeBox = $false
    $script:waitForm.ShowInTaskbar = $false
    $script:waitForm.TopMost = $true
    $script:waitForm.BackColor = [System.Drawing.Color]::White

    $waitLabel = New-Object System.Windows.Forms.Label
    $waitLabel.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
    $waitLabel.Size = [System.Drawing.Size]::new(500,60)
    $waitLabel.Location = [System.Drawing.Point]::new(10,20)
    $waitLabel.TextAlign = 'TopLeft'
    $waitLabel.Anchor = 'Top,Left,Right'
    $waitLabel.BackColor = [System.Drawing.Color]::White

    $fileAction = if (-not (Test-Path $WordFilePath)) { "written to:" } else { "appended to:" }
    $waitLabel.Text = "PLEASE WAIT... While your Advice is being $fileAction`n$($script:WordFilePath)"
    $script:waitForm.Controls.Add($waitLabel)

    # Add a second label for the smaller font message
    $waitLabel2 = New-Object System.Windows.Forms.Label
    $waitLabel2.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
    $waitLabel2.Size = [System.Drawing.Size]::new(500,30)
    $waitLabel2.Location = [System.Drawing.Point]::new(10, $waitLabel.Bottom + 5)
    $waitLabel2.TextAlign = 'TopLeft'
    $waitLabel2.Anchor = 'Top,Left,Right'
    $waitLabel2.BackColor = [System.Drawing.Color]::White
    $waitLabel2.Text = "As soon as the 'Close' Button appears, you may continue."
    $script:waitForm.Controls.Add($waitLabel2)

    $script:closeBtn = New-Object System.Windows.Forms.Button
    $script:closeBtn.Text = "Close"
    $script:closeBtn.Size = [System.Drawing.Size]::new(100,32)
    $script:closeBtn.Location = [System.Drawing.Point]::new(200,140)
    $script:closeBtn.Visible = $false
    $script:waitForm.Controls.Add($script:closeBtn)
    $script:closeBtn.Add_Click({ $script:waitForm.Close() })

    $script:waitForm.Show()
    $script:waitForm.TopMost = $true
    $script:waitForm.BringToFront()
    $script:waitForm.Refresh()

    # Post-save verification: check file exists and is updated
    $fileSaved = $false
    if ($saveSuccess -and (Test-Path $WordFilePath)) {
        $fileInfo = Get-Item $WordFilePath
        $now = Get-Date
        $maxWait = 10
        $waited = 0
        while ($waited -lt $maxWait -and -not $fileSaved) {
            Start-Sleep -Seconds 1
            [System.Windows.Forms.Application]::DoEvents()
            $waited += 1
            $fileInfo = Get-Item $WordFilePath
            if ($fileInfo.LastWriteTime -gt ($now.AddMinutes(-2))) {
                $fileSaved = $true
            }
        }
    }
    $script:closeBtn.Visible = $true
    while ($waitForm.Visible) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
    }

    if (-not $fileSaved) {
        [System.Windows.Forms.MessageBox]::Show(
            "Save failed or file not updated. Please check if the document is open in Word or on a USB drive.",
            "Save Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }
} # END of - Function Export-AdvicePanelToWord


# =======================================================================================
# function - Get-EdgeShortcutName
# =======================================================================================
function Get-EdgeShortcutName {
    $taskbarPath = "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
    # PURPOSE:
    #   This function checks the user's Taskbar pinned shortcuts for Microsoft Edge and returns the name    of the shortcut if found, or null if not found.
    #   It does this by looking in the User Pinned Taskbar directory for .lnk files, and checking if any of them point to msedge.exe.       
    #   This is necessary because the name of the Edge shortcut can vary based on the version of Edge and Windows, and may not be consistent across systems.    
    #   By identifying the actual name of the Edge shortcut, the script can then correctly modify its text in the UI to reflect the current state (e.g., "PIN to Taskbar" vs "UNPIN from Taskbar"). 
    #   Note: This function only checks for Edge shortcuts in the Taskbar pinned directory, not in the Start Menu or Desktop.
    
    # Look for any .lnk that contains 'edge' in the target or name
    foreach ($lnk in Get-ChildItem $taskbarPath -Filter *.lnk) {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($lnk.FullName)
        if ($shortcut.TargetPath -match "msedge.exe") {
            return [System.IO.Path]::GetFileNameWithoutExtension($lnk.Name)
        }
    }
    return $null
    
} # END of - function Get-EdgeShortcutName


# =======================================================================================
function Modify-RecommendedOption {
        param(
        [Parameter(Mandatory)] $checkbox,
        [bool]$IsRecommendedMode = $false
    )
    # PURPOSE: 
    #       This function is called whenever an Option checkbox is clicked, and when Resetting Defaults.
    #       Modifies the text and state of the given checkbox based on the current configuration of the PC.
    #
    #       There are 6 main branches of logic in this function, which are evaluated in order.  
    #       Each branch has its own criteria for matching the option and its own logic for how to modify 
    #       the option text and state:
    #           BRANCH 1: Do nothing (exact name match)
    #               Criteria: Option name matches exactly a predefined list of options that should not be modified.
    #           BRANCH 2: Recall (by name)
    #               Criteria: Option name contains 'Recall', with specific handling for:
    #                   'KEEP Recall', 
    #                   'Remove Recall', and 
    #                   'CANNOT INSTALL Recall' states.
    #           BRANCH 3: Start Menu PIN options
    #               Criteria: Option name matches patterns related to pinning apps to the Start Menu, such as:
    #                   'PIN <APP> to Start Menu', 
    #                   'UNPIN <APP> from Start Menu', 
    #                   'KEEP <APP> pinned to Start Menu', 
    #                   'Remove <APP> PIN from Start Menu', and 
    #                   'Please ADD - MANUALLY' states, or
    #                   'Please PIN - MANUALLY' states.     
    #           BRANCH 4: Taskbar options
    #               Criteria: Option name matches patterns related to taskbar customization, such as:
    #                   'KEEP <App>, ON the Taskbar', 
    #                   'Remove <App>, FROM from the Taskbar'
    #                   'Please ADD <App>  - MANUALLY'
    #           BRANCH 5: Desktop shortcut options
    #               Criteria: Option name matches patterns related to desktop shortcuts, such as:   
    #                   'CREATE Desktop Shortcut', 
    #                   'REMOVE Desktop Shortcut', 
    #                   'KEEP Desktop Shortcut', 
    #                   'Remove Desktop Shortcut', and 
    #                   'Please CREATE - MANUALLY' states.
    #           BRANCH 6: Default (all other options)   
    #               Criteria: Option name matches the general patterns of: 
    #                   'KEEP <app>', 
    #                   'Remove <app>', and 
    #                   'Please INSTALL <app> - MANUALLY', 
    #               where <app> can be any application or feature name.
       
    $localDEBUG_Mode = $false

    If ($localDEBUG_Mode) {
        Write-Host "[DEBUG] Modify-RecommendedOption called - Option: $($checkbox.Text) - isBulkUpdate: $($script:isBulkUpdate)" -ForegroundColor Red
    }

    # If $IsRecommendedMode is $true, this function does not need to be run, 
    # It is used when we want to set the options to their recommended state, or clear all the Option checkboxes.
    if ($script:SkipModifyRecommendedOption) {
        return
    }
    # If there is only ONE Option in the Group
    if ($checkbox.Tag.DefaultMode -eq 'ONE') { return }

    # DIY ONLY options are advice-only — never auto-check them
    if ($checkbox.Tag.DefaultMode -eq 'DIY ONLY') { return }

    $modifiedOption = $checkbox.Tag.CurrentOption

    $dbgName = $null
    if ($checkbox.Tag -and $checkbox.Tag.PSObject.Properties.Name -contains 'OriginalOption') {
        $dbgName = $checkbox.Tag.OriginalOption
    } elseif ($checkbox.Tag -and $checkbox.Tag.PSObject.Properties.Name -contains 'Option') {
        $dbgName = $checkbox.Tag.Option
    } else {
        $dbgName = $checkbox.Text
    }
    # When the calling routine sets $this.Checked = $true 
    # as a result of $script:TickCheckbox being set to $true by this function,  
    # this function will be recalled, thus undoing the previous modification.
    # We therefore need to ensure that when this happens, this function exits without making further changes.
    if ($script:TickCheckbox) {
        $script:TickCheckbox = $false
        if ($checkbox.Checked) {
            return
        }
        # If unchecked, allow normal processing
    }   

    
    $original = $checkbox.Tag.OriginalOption
    $currentOption  = $checkbox.Tag.CurrentOption
 
    # Enforce string assignment
    $currentOption = [string]$currentOption
    $original = [string]$original
    $CURRENT_OptionName = $currentOption.Trim()

    # BRANCH 1: Do nothing (exact name match)
    # ---------------------------------------
    # If $CURRENT_OptionName matches exactly any of the predefined options that should not be modified, 
    #then do nothing and always keep the original text and state, regardless of the checkbox state.
    $doNothingOptions = @(
        'Turn BitLocker OFF',
        'Create and Sign in with a Local Account',
        'Remove Microsoft Account entirely',
        'USE Search Button Icon, IN the Taskbar',
        'Please PIN/UNPIN CoPilot - MANUALLY'
    )
    if ($doNothingOptions -contains $CURRENT_OptionName) {
        # Do nothing: always keep as original, regardless of checked state
        $checkbox.Text = $original
        $checkbox.Tag.CurrentOption = $original
        $script:TickCheckbox = $false
        return
    } # END of BRANCH 1 - Do nothing (exact name match)

    # BRANCH 2: Recall (by name)
    # --------------------------
    # This branch handles all options related to "Recall", 
    # which have multiple states and require checking the actual installation status of Recall 
    # to determine the correct option text and state.
    if ($CURRENT_OptionName -like '*Recall*') {
        # ...existing code...
        if (-not (RecallSupported)) {
            # ...existing code...
            $currentOption = 'CANNOT INSTALL Recall'
            $checkbox.Text = $currentOption
            $checkbox.Tag.CurrentOption = $currentOption
            $checkbox.Checked = $false
            if ($checkbox.Tag.Label) { $checkbox.Tag.Label.Text = $currentOption }
            $script:TickCheckbox = $false
            return
        } elseif ($CURRENT_OptionName -eq 'KEEP Recall') {
            # ...existing code...
            if ($checkbox.Checked -eq $false) {
                $currentOption = 'Remove Recall'
            }
        } elseif ($CURRENT_OptionName -eq 'Remove Recall') {
            if ($checkbox.Checked -eq $false) {
                # If unchecked, revert to KEEP or manual install
                if (Get-AppxPackage -AllUsers | Where-Object { $_.Name -match 'Recall' }) {
                    $currentOption = 'KEEP Recall'
                } else {
                    $currentOption = 'Please INSTALL Recall - MANUALLY'
                    $script:TickCheckbox = $false
                }
            }
        } elseif ($CURRENT_OptionName -eq 'CANNOT INSTALL Recall') {
            $checkbox.Checked = $false
            if ($checkbox.Tag.Label) { $checkbox.Tag.Label.Text = $currentOption }
        } elseif ($CURRENT_OptionName -eq 'Please INSTALL Recall - MANUALLY') {
            if ($checkbox.Checked -eq $false) {
                $currentOption = 'Remove Recall'
            } else {
                $currentOption = $CURRENT_OptionName
            }
        }
        $checkbox.Text = $currentOption
        $checkbox.Tag.CurrentOption = $currentOption
        if ($currentOption -eq 'CANNOT INSTALL Recall') {
            $checkbox.Checked = $false
            if ($checkbox.Tag.Label) { $checkbox.Tag.Label.Text = $currentOption }
            $script:TickCheckbox = $false
        } else {
            $script:TickCheckbox = $true
        }
        return

    } # END of BRANCH 2 - Recall (by name)


    # BRANCH 3: Start Menu/Taskbar PIN Option Logic - TESTED and WORKING
    # =============================================
    # This branch handles all options related to pinning items to the Start Menu or Taskbar, 
    # which have multiple states and require checking the actual pinned status of the item to determine 
    # the correct option text and state.
    # These Options need to be handled in a special branch because they do not follow the standard 
    # KEEP/Remove/Please ... MANUALLY pattern, and because they require checking the actual
    # pinned status of the item to determine the correct option text and state.
    #
    # Microsoft do not allow programmatically pinning or unpinning items to the Start Menu or Taskbar.  
    # So, we have to use the checkbox state and text as a way to guide the user to manually ADD or PIN the item,
    # or to programmatically REMOVE or UNPIN the item.  
    # 
    # the Opptions in this branch have 4 states:
    #     "Remove $ItemPINNED PIN from the $LocationPinned",
    #     "KEEP $ItemPINNED pinned to $LocationPinned", or
    #     "Please ADD $ItemPINNED - MANUALLY", or   
    #     "Please PIN $ItemPINNED - MANUALLY"


    if ((   
            $CURRENT_OptionName.StartsWith('Please ADD') -or 
            $CURRENT_OptionName -match 'PIN|Pinned'
        ) -and (
            $CURRENT_OptionName.EndsWith('Start Menu') -or 
            $CURRENT_OptionName.EndsWith('Taskbar') -or 
            $CURRENT_OptionName.EndsWith('Task Bar') -or 
            $CURRENT_OptionName.EndsWith('MANUALLY'))
        ) {
        # Then it unquestionably is a PIN option, which have 4 states:
        #     "Remove $ItemPINNED PIN from the $LocationPinned", 
        #     "KEEP $ItemPINNED pinned to $LocationPinned", or
        #     "Please ADD $ItemPINNED - MANUALLY", or
        #     "Please PIN $ItemPINNED - MANUALLY"
        #
        # Where $LocationPinned = "Start Menu" or "Taskbar"

        # the purpose of this branch is to toggle between these 3 states based on the current pinned status of the item
        # and the user's interaction with the checkbox, while also ensuring that the user is guided to:
        #       - manually pin or 
        #       - programmatically unpin 
        # the item as needed, as programmatic pinning is not permitted by Microsoft.

        $localDEBUG_Mode = $false
   

        If ($localDEBUG_Mode) { Write-Host "[DEBUG] BRANCH 3 - optionName: '$CURRENT_OptionName'" }


        # Case 1. - "Remove $ItemPINNED PIN from the $LocationPinned" 
        # -----------------------------------------------------------
        if ($CURRENT_OptionName -match '^Remove (.+) PIN from the (.+)$') {
            $ItemPINNED = $matches[1].Trim()
            $LocationPinned = $matches[2].Trim()
            $Item = $ItemPINNED
            If ($localDEBUG_Mode) { Write-Host "[DEBUG] $CURRENT_OptionName matched 'Remove $ItemPINNED PIN from the $LocationPinned'" }
            if ($checkbox.Checked -eq $false) {
                if (Already-PinnedToStartMenu -AppName $ItemPINNED) {
                    $modifiedOption = "KEEP $ItemPINNED pinned to $LocationPinned"
                } else {
                    $modifiedOption = "Please PIN $ItemPINNED - MANUALLY"
                }
                If ($localDEBUG_Mode) { Write-Host "[DEBUG] Case 1 - setting ModifiedOption to '$modifiedOption'" }
                $checkbox.Text = $modifiedOption
                $checkbox.Tag.CurrentOption = $modifiedOption
                if ($checkbox.Tag.Label) { $checkbox.Tag.Label.Text = $modifiedOption }
                $script:TickCheckbox = $true
                $checkbox.Checked = $true
                $script:TickCheckbox = $false
            }
            If ($localDEBUG_Mode) {
                $testResult = Test-ShortcutActive -AppName $Item -ShortcutType 'Taskbar'
                Write-Host "[DEBUG] BRANCH 3 - Test-ShortcutActive for '$Item' (Taskbar) returned: $testResult" -ForegroundColor Yellow
            }
        }


        # Case 2. - "KEEP $ItemPINNED pinned to$LocationPinned"
        # ----------------------------------------------------------
        $localDEBUG_Mode = $false # Case 2 TESTED and WORKING
        
        If ($localDEBUG_Mode) { Write-Host "[DEBUG] Case 2 for optionName: '$CURRENT_OptionName'" }

        if (($CURRENT_OptionName -match '^KEEP (.+) pinned to (.+)$')) {

            $ItemPINNED = $matches[1].Trim()
            $LocationPinned = $matches[2].Trim()

            If ($localDEBUG_Mode) { Write-Host "[DEBUG] $CURRENT_OptionName matched 'KEEP $ItemPINNED pinned to$LocationPinned'" }

            if ($checkbox.Checked -eq $false) {
                $modifiedOption = "Remove $ItemPINNED PIN from the $LocationPinned"

                If ($localDEBUG_Mode) { Write-Host "[DEBUG] Checkbox was unchecked, setting ModifiedOption to '$modifiedOption'" }

                $checkbox.Text = $modifiedOption
                $checkbox.Tag.CurrentOption = $modifiedOption

                if ($checkbox.Tag.Label) { $checkbox.Tag.Label.Text = $modifiedOption }
            
                # $Checkbox.Checked MUST be set to true to prevent PERFORM-SelecedOptions ignoring it
                # -----------------------------------------------------------------------------------  
                # $script:TickCheckbox is used to prevent the checkbox change from triggering another modification cycle, 
                # which would revert the change we just made to the option text and state.        
                $script:TickCheckbox = $true
                $checkbox.Checked = $true
                $script:TickCheckbox = $false
            }
            return
        } # End of Case 2. - "KEEP $ItemPINNED pinned to$LocationPinned"

        # Case 3. - "Please ADD/PIN $ItemPINNED - MANUALLY" -  TO BE RE-TESTED
        # -------------------------------------------------
        if (($CURRENT_OptionName -match '^Please PIN (.+) - MANUALLY$') -or `
            ($CURRENT_OptionName -match '^Please ADD (.+) - MANUALLY$') -or `
            ($CURRENT_OptionName -match '^Remove (.+) - MANUALLY$')) {

            If ($localDEBUG_Mode) { Write-Host "[DEBUG] Case 3 for optionName: '$CURRENT_OptionName'" }

            $ItemPINNED = $matches[1].Trim()
 
            # Try to infer location from group or original text, as $locationPinned is not explicitly stated in this option state, 
            # but we need it to construct the next option text.
            $LocationPinned = $null
            $debugGroup = if ($checkbox.Tag -and $checkbox.Tag.PSObject.Properties.Name -contains 'Group') { $checkbox.Tag.Group } else { '' }
            if ($original -match 'Start Menu') { $LocationPinned = 'Start Menu' }
            elseif ($original -match 'Taskbar') { $LocationPinned = 'Taskbar' }
            elseif ($debugGroup -match 'Start Menu') { $LocationPinned = 'Start Menu' }
            elseif ($debugGroup -match 'Taskbar') { $LocationPinned = 'Taskbar' }
            else { $LocationPinned = 'Start Menu' } # Default fallback

            if ($checkbox.Checked -eq $false) {
                $modifiedOption = "Remove $ItemPINNED PIN from the $LocationPinned"

                $checkbox.Text = $modifiedOption
                $checkbox.Tag.CurrentOption = $modifiedOption

                if ($checkbox.Tag.Label) { $checkbox.Tag.Label.Text = $modifiedOption }
            
                # $Checkbox.Checked MUST be set to true to prevent PERFORM-SelecedOptions ignoring it
                # -----------------------------------------------------------------------------------  
                # $script:TickCheckbox is used to prevent the checkbox change from triggering another modification cycle, 
                # which would revert the change we just made to the Option.        
                $script:TickCheckbox = $true
                $checkbox.Checked = $true
                $script:TickCheckbox = $false
            }
        } # End of Case 3. - "Please PIN/ADD $ItemPINNED - MANUALLY"

        return

    } # End of BRANCH 3 - Start Menu/Taskbar PIN Option Logic


# BRANCH 4: Taskbar Options
    if ($CURRENT_OptionName.EndsWith('Taskbar')) {
        $localDEBUG_Mode = $false
        $modifiedOption = $checkbox.Tag.CurrentOption

        If ($localDEBUG_Mode) { Write-Host "[DEBUG] BRANCH 4 - Taskbar options - optionName: '$CURRENT_OptionName'" }

        if ($CURRENT_OptionName -match '^KEEP (.+), ON the Taskbar$') {
            $app = $matches[1].Trim()
            if ($checkbox.Checked -eq $false) {
                $modifiedOption = "Remove $app, FROM the Taskbar"
                $checkbox.Text = $modifiedOption
                $checkbox.Tag.CurrentOption = $modifiedOption
                $script:TickCheckbox = $true
                $checkbox.Checked = $true
                $script:TickCheckbox = $false
                return
            }
        } elseif ($CURRENT_OptionName -match '^Remove (.+), FROM the Taskbar$') {
            $app = $matches[1].Trim()
            if ($checkbox.Checked -eq $false) {
                $testResult = Test-ShortcutActive -AppName $app -ShortcutType 'Taskbar'
                if (-not $testResult) {
                    $modifiedOption = "Please ADD $app - MANUALLY"
                } else {
                    $modifiedOption = "KEEP $app, ON the Taskbar"
                }
                $checkbox.Text = $modifiedOption
                $checkbox.Tag.CurrentOption = $modifiedOption
                $script:TickCheckbox = $true
                $checkbox.Checked = $true
                $script:TickCheckbox = $false
                return
            }
        } elseif ($CURRENT_OptionName -match '^Please ADD (.+) - MANUALLY$' -or $CURRENT_OptionName -match '^Please ADD (.+) MANUALLY$') {
            $app = $matches[1].Trim()
            if ($checkbox.Checked -eq $false) {
                $modifiedOption = "Remove $app, FROM the Taskbar"
            }
            $checkbox.Text = $modifiedOption
            $checkbox.Tag.CurrentOption = $modifiedOption
            $script:TickCheckbox = $true
            $checkbox.Checked = $true
            $script:TickCheckbox = $false
            return
        }

        # Only update if $modifiedOption was changed
        if ($null -eq $modifiedOption) {
            $modifiedOption = $checkbox.Tag.CurrentOption
        }
        if ($checkbox.Text -ne $modifiedOption) {
            $checkbox.Text = $modifiedOption
            $checkbox.Tag.CurrentOption = $modifiedOption
        }
        $script:TickCheckbox = $true
        $checkbox.Checked = $true
        $script:TickCheckbox = $false
        return
    } # End of BRANCH 4 - Taskbar Options


    # BRANCH 5: Desktop shortcut options
    # ----------------------------------
    # States:
    #   "KEEP <item>, ON the Desktop"      - shortcut present, leave it alone
    #   "Remove <item>, FROM the Desktop"  - remove it (PERFORM handles "wasn't there")
    #   "ADD <item>, to the Desktop"       - shortcut absent, PERFORM will create it
    #                                        (advice tells user what will happen)
    #
    # The distinction between KEEP and ADD matters because the ADVICE is different:
    #   KEEP = "it's there, we'll leave it"
    #   ADD  = "it's not there, we'll add it for you"  (Desktop CAN be automated)
    #
    # ALL states leave the checkbox TICKED - UI captures intent, PERFORM handles reality.

    if ($CURRENT_OptionName -match 'Desktop') {
        If ($localDEBUG_Mode) { Write-Host "[DEBUG] BRANCH 5 - Desktop - optionName: '$CURRENT_OptionName'" }

        # --- IsRecommendedMode: called on form load to set correct initial state ---
        if ($IsRecommendedMode) {
            if ($CURRENT_OptionName -match '^KEEP (.+), ON the Desktop$') {
                $item         = $matches[1].Trim()
                $desktopPath  = [Environment]::GetFolderPath('Desktop')
                $shortcutPath = Join-Path $desktopPath "$item.lnk"
                if (-not (Test-Path $shortcutPath)) {
                    # Not present on load: switch to ADD so advice and PERFORM are correct
                    $modifiedOption = "ADD $item, to the Desktop"
                    $checkbox.Text = $modifiedOption
                    $checkbox.Tag.CurrentOption = $modifiedOption
                    if ($checkbox.Tag.Label) { $checkbox.Tag.Label.Text = $modifiedOption }
                    $script:TickCheckbox = $true
                    $checkbox.Checked = $true
                    $script:TickCheckbox = $false
                }
                # Present: leave as KEEP, checked - no change
            }
            # Remove <item>, FROM the Desktop on load: leave as-is, checked
            return
        }

        # --- User interaction ---

        if ($CURRENT_OptionName -match '^KEEP (.+), ON the Desktop$') {
            $item = $matches[1].Trim()
            if ($checkbox.Checked -eq $false) {
                # User doesn't want to keep it - intent is to remove it
                $modifiedOption = "Remove $item, FROM the Desktop"
                $checkbox.Text = $modifiedOption
                $checkbox.Tag.CurrentOption = $modifiedOption
                if ($checkbox.Tag.Label) { $checkbox.Tag.Label.Text = $modifiedOption }
                $script:TickCheckbox = $true
                $checkbox.Checked = $true
                $script:TickCheckbox = $false
            }
            return
        }

        elseif ($CURRENT_OptionName -match '^ADD (.+), to the Desktop$') {
            $item = $matches[1].Trim()
            if ($checkbox.Checked -eq $false) {
                # User doesn't want it added - intent is to remove/leave removed
                # PERFORM will handle "wasn't there" gracefully
                $modifiedOption = "Remove $item, FROM the Desktop"
                $checkbox.Text = $modifiedOption
                $checkbox.Tag.CurrentOption = $modifiedOption
                if ($checkbox.Tag.Label) { $checkbox.Tag.Label.Text = $modifiedOption }
                $script:TickCheckbox = $true
                $checkbox.Checked = $true
                $script:TickCheckbox = $false
            }
            return
        }

        elseif ($CURRENT_OptionName -match '^Remove (.+), FROM the Desktop$') {
            $item = $matches[1].Trim()
            if ($checkbox.Checked -eq $false) {
                # Check whether it's actually present to give the correct advice
                $desktopPath  = [Environment]::GetFolderPath('Desktop')
                $shortcutPath = Join-Path $desktopPath "$item.lnk"
                if (Test-Path $shortcutPath) {
                    # Present: KEEP - advice will say "we'll leave it alone"
                    $modifiedOption = "KEEP $item, ON the Desktop"
                } else {
                    # Absent: ADD - advice will say "it's not there, we'll add it"
                    $modifiedOption = "ADD $item, to the Desktop"
                }
                $checkbox.Text = $modifiedOption
                $checkbox.Tag.CurrentOption = $modifiedOption
                if ($checkbox.Tag.Label) { $checkbox.Tag.Label.Text = $modifiedOption }
                $script:TickCheckbox = $true
                $checkbox.Checked = $true
                $script:TickCheckbox = $false
            }
            return
        }

        return
    } # End of BRANCH 5: Desktop shortcut options


    # BRANCH 6: Select Default Browser
    # --------------------------------
    # Handles the 'Select Default Browser' group.
    # Three possible states per browser:
    #   "INSTALL X"                  - not installed, unchecked
    #   "SELECT X"                   - installed, not default, unchecked  
    #   "X SELECTED"                 - installed, IS default, checked
   
    if ($checkbox.Tag.GroupName -eq 'Select Default Browser') {

        # --- Browser detection lookup ---
        $browserLookup = @{
            'Microsoft Edge'  = @{ DisplayName = 'Microsoft Edge';    ProgId = 'MSEdgeHTM'    }
            'Google Chrome'   = @{ DisplayName = 'Google Chrome';     ProgId = 'ChromeHTML'   }
            'Firefox'         = @{ DisplayName = 'Mozilla Firefox';   ProgId = 'FirefoxURL'   }
            'Brave'           = @{ DisplayName = 'Brave';             ProgId = 'BraveHTML'    }
            'Opera'           = @{ DisplayName = 'Opera';             ProgId = 'OperaStable'  }
        }

        # --- Extract browser name from current option ---
        $browserName = $CURRENT_OptionName `
            -replace '^INSTALL\s+', '' `
            -replace '^SELECT\s+', '' `
            -replace '\s+SELECTED$', '' `
            -replace '^Please INSTALL\s+', '' `
            -replace '\s+-\s+MANUALLY$', ''
        $browserName = $browserName.Trim()

        $lookup = $browserLookup[$browserName]

        # --- Detect installation ---
        $isInstalled = $false
        if ($lookup) {
            $win32 = Get-ChildItem `
                "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
                "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall" `
                -ErrorAction SilentlyContinue |
                ForEach-Object { Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue } |
                Where-Object { 
                    $_.PSObject.Properties.Name -contains 'DisplayName' -and 
                    $_.DisplayName -like "*$($lookup.DisplayName)*" 
                }
            if ($win32) { $isInstalled = $true }
            
            # Also check HKCU - Brave and Opera install per-user
            if (-not $isInstalled) {
                $win32HKCU = Get-ChildItem `
                    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall" `
                    -ErrorAction SilentlyContinue |
                    ForEach-Object { Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue } |
                    Where-Object { 
                        $_.PSObject.Properties.Name -contains 'DisplayName' -and 
                        $_.DisplayName -like "*$($lookup.DisplayName)*" 
                    }
                if ($win32HKCU) { $isInstalled = $true }
            }

            # Fallback: check Appx (for Edge)
            if (-not $isInstalled) {
                $appx = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | 
                    Where-Object { $_.Name -like "*Edge*" -and $browserName -eq 'Microsoft Edge' }
                if ($appx) { $isInstalled = $true }
            }
        }

        # --- Detect default browser ---
        $isDefault = $false
        if ($isInstalled -and $lookup) {
            $progId = (Get-ItemProperty `
                "HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\http\UserChoice" `
                -ErrorAction SilentlyContinue).ProgId
            if ($progId -like "*$($lookup.ProgId)*") { $isDefault = $true }
        }

        # --- Set option text based on detected state ---
        if ($IsRecommendedMode -or $checkbox.Checked -eq $false) {
            if ($isInstalled -and $isDefault) {
                $modifiedOption = "$browserName SELECTED"
                $script:TickCheckbox = $true
                $checkbox.Checked = $true
                $script:TickCheckbox = $false
            } elseif ($isInstalled) {
                $modifiedOption = "SELECT $browserName"
                $checkbox.Checked = $false
            } else {
                $modifiedOption = "INSTALL $browserName"
                $checkbox.Checked = $false
            }
        } elseif ($checkbox.Checked -eq $true) {
            if ($CURRENT_OptionName -like "INSTALL *") {
                # User wants to install - keep checked for PERFORM to action
                $modifiedOption = $CURRENT_OptionName
            } elseif ($CURRENT_OptionName -like "SELECT *") {
                # $modifiedOption = "$browserName SELECTED"
                # Uncheck all other SELECT or SELECTED browser options
                foreach ($cb in $checkbox.Tag.OptionCheckboxes) {
                    if ($cb -ne $checkbox -and 
                        ($cb.Tag.CurrentOption -like "SELECT *" -or 
                         $cb.Tag.CurrentOption -like "* SELECTED")) {
                        $script:isBulkUpdate = $true
                        $cb.Checked = $false
                        $script:isBulkUpdate = $false
                        # Update text to SELECT X
                        $cbBrowserName = $cb.Tag.CurrentOption `
                            -replace '^SELECT\s+', '' `
                            -replace '\s+SELECTED$', ''
                        $cb.Text = "SELECT $cbBrowserName"
                        $cb.Tag.CurrentOption = "SELECT $cbBrowserName"
                    }
                }
  
            } elseif ($CURRENT_OptionName -like "* SELECTED") {
                # Already selected - do nothing
                $modifiedOption = $CURRENT_OptionName
            }
        }

        $checkbox.Text = $modifiedOption
        $checkbox.Tag.CurrentOption = $modifiedOption
        if ($checkbox.Tag.Label) { $checkbox.Tag.Label.Text = $modifiedOption }

        return

    } # END of - BRANCH 6 Browser Choice branch
     

    # BRANCH 7: ENABLE / DISABLE Options
    # -----------------------------------
    # Handles simple two‑state options such as:
    #   "ENABLE <Feature>"
    #   "DISABLE <Feature>"
    #
    # These behave like KEEP/Remove pairs: toggling the checkbox flips the state.
    #
    if ($CURRENT_OptionName -match '^(ENABLE|DISABLE)\s+(.+)$') {
        $state  = $matches[1].ToUpper()
        $feature = $matches[2].Trim()

        if ($checkbox.Checked -eq $false) {
            # User unticked → flip the state
            if ($state -eq 'ENABLE') {
                $modifiedOption = "DISABLE $feature"
            } else {
                $modifiedOption = "ENABLE $feature"
            }

            $checkbox.Text = $modifiedOption
            $checkbox.Tag.CurrentOption = $modifiedOption

            if ($checkbox.Tag.Label) { $checkbox.Tag.Label.Text = $modifiedOption }

            # Prevent recursive modification
            $script:TickCheckbox = $true
            $checkbox.Checked = $true
            $script:TickCheckbox = $false
        }

        return
    }


    # BRANCH 8: DEFAULT (all other Options)
    # -------------------------------------
    # This branch handles all other options that do not fall into the previous specific categories,
    # and follow the general patterns of:
    #     "Remove <app>",
    #     "KEEP <app>", 
    #     "ADD <app>", 
    #     "SHOW <app>", 
    #     "HIDE <app>", and
    #     "Please ADD <app> - MANUALLY", or
    #     "Please INSTALL <app> - MANUALLY"
    # Where <app> can be any application or feature name.
    
    If ($localDEBUG_Mode) { Write-Host "[DEBUG] BRANCH 6 - Default (all other options) - optionName: '$CURRENT_OptionName'" }

    $removePattern         = '^Remove (.+)$'
    $keepPattern           = '^KEEP (.+)$'
    $addPattern            = '^ADD (.+)$'
    $showPattern           = '^SHOW (.+)$'
    $hidePattern           = '^HIDE (.+)$'
    $manualPattern         = '^Please INSTALL (.+) - MANUALLY$'
    $manualAddPattern      = '^Please ADD (.+) - MANUALLY$'
    $manualAddPatternNoDash = '^Please ADD (.+) MANUALLY$'

    $optionNameStr = [string]$CURRENT_OptionName

    if ($optionNameStr -match $showPattern) {
        $app = [string]$matches[1]
        $app = $app.Trim()
        if ($checkbox.Checked -eq $false) {
            $modifiedOption = "HIDE $app"
        }
    } elseif ($optionNameStr -match $hidePattern) {
        $app = [string]$matches[1]
        $app = $app.Trim()
        if ($checkbox.Checked -eq $false) {
            $modifiedOption = "SHOW $app"
        }
    } elseif ($optionNameStr -match $keepPattern) {
        $app = [string]$matches[1]
        $app = $app.Trim()
        if ($checkbox.Checked -eq $false) {
            $modifiedOption = "Remove $app"
        } elseif ($IsRecommendedMode) {
            # On load - check if app is actually installed
            # Registry-only and service options are always present — skip install check
            $isRegistryOnly = $script:RegistryLookup.Values | Where-Object { $_.DisplayName -eq $app }
            if ($isRegistryOnly) { return }
            $isServiceOption = $script:ServiceLookup.Values | Where-Object { $_.DisplayName -eq $app }
            if ($isServiceOption) { return }

            $isInstalled = $false
            try {
                if ($app -eq 'Microsoft 365') {
                    $c2rProducts = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration" -ErrorAction SilentlyContinue
                    $isInstalled = ($c2rProducts -and $c2rProducts.ProductReleaseIds -match 'O365')
                } elseif ($app -eq 'Microsoft Teams') {
                    $isInstalled = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'MSTeams' -or $_.Name -like '*Teams*' }).Count -gt 0
                } elseif ($app -eq 'Xbox') {
                    $isInstalled = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Microsoft.GamingApp' -or $_.Name -eq 'Microsoft.GamingServices' }).Count -gt 0
                } else {
                    $isInstalled = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*$app*" }).Count -gt 0
                }
            } catch {}
            if (-not $isInstalled) {
                $modifiedOption = "Please INSTALL $app - MANUALLY"
                $checkbox.Text = $modifiedOption
                $checkbox.Tag.CurrentOption = $modifiedOption
            }
        }
    } elseif ($optionNameStr -match $removePattern) {
        $app = [string]$matches[1]
        $app = $app.Trim()
        if ($checkbox.Checked -eq $false) {
            # Registry-only and service options are always present — toggle back to KEEP
            $isRegistryOnly = $script:RegistryLookup.Values |
                Where-Object { $_.DisplayName -eq $app }
            $isServiceOption = $script:ServiceLookup.Values |
                Where-Object { $_.DisplayName -eq $app }
            if ($isRegistryOnly -or $isServiceOption) {
                $modifiedOption = "KEEP $app"
            } else {
                $altOption = "Please INSTALL $app - MANUALLY"
                $groupName = $null
                if ($checkbox.Tag -and $checkbox.Tag.PSObject.Properties.Name -contains 'Group') {
                    $groupName = $checkbox.Tag.Group
                } elseif ($checkbox.Tag -and $checkbox.Tag.PSObject.Properties.Name -contains 'ParentGroup') {
                    $groupName = $checkbox.Tag.ParentGroup
                } elseif (Get-Variable -Name GroupName -Scope Script -ErrorAction SilentlyContinue) {
                    $groupName = $script:GroupName
                }
                $isInstalled = $false
                try {
                    if ($app -eq 'Microsoft 365') {
                        $isInstalled = @(Get-AppxPackage -AllUsers | Where-Object { 
                            $_.Name -like '*Microsoft365*' -or 
                            $_.PackageFamilyName -like '*Microsoft.365*'
                        }).Count -gt 0
                        # Also check Click-to-Run registry for subscription products only
                        if (-not $isInstalled) {
                            $c2rProducts = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration" -ErrorAction SilentlyContinue
                            if ($c2rProducts -and $c2rProducts.ProductReleaseIds -match 'O365') {
                                $isInstalled = $true
                            }
                        }
                    } elseif ($app -eq 'Xbox') {
                        $isInstalled = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { 
                            $_.Name -eq 'Microsoft.GamingApp' -or 
                            $_.Name -eq 'Microsoft.GamingServices'
                        }).Count -gt 0                
                    } elseif ($app -eq 'Microsoft Teams') {
                        $isInstalled = @(Get-AppxPackage -AllUsers | Where-Object { 
                            $_.Name -eq 'MSTeams' -or $_.Name -like '*Teams*' 
                        }).Count -gt 0
                    } else {
                        $isInstalled = @(Get-AppxPackage -AllUsers | Where-Object { 
                            $_.Name -like "*$app*" 
                        }).Count -gt 0
                    }
                } 
                catch {}

                if (-not $isInstalled) {
                    $modifiedOption = $altOption
                } else {
                    $modifiedOption = "KEEP $app"
                }
            }
        } else {
            $modifiedOption = $checkbox.Tag.CurrentOption
        }
    } elseif ($optionNameStr -match $manualPattern) {
        $app = [string]$matches[1]
        $app = $app.Trim()
        if ($checkbox.Checked -eq $false) {
            $modifiedOption = "Remove $app"
        } else {
            $modifiedOption = $optionNameStr
        }
    } elseif ($optionNameStr -match $manualAddPattern -or $optionNameStr -match $manualAddPatternNoDash) {
        $app = [string]$matches[1]
        $app = $app.Trim()
        $isTaskbar = $false
        if ($checkbox.Tag -and $checkbox.Tag.PSObject.Properties.Name -contains 'Group' -and $checkbox.Tag.Group -match 'Taskbar') {
            $isTaskbar = $true
        } elseif ($optionNameStr -match '(?i)Taskbar') {
            $isTaskbar = $true
        }
        if ($isTaskbar) {
            if ($checkbox.Checked -eq $false) {
                $modifiedOption = "Remove $app, FROM the Taskbar"
            } else {
                $modifiedOption = $optionNameStr
            }
        } else {
            if ($checkbox.Checked -eq $false) {
                $modifiedOption = "Remove $app"
            } else {
                $modifiedOption = $optionNameStr
            }
        }
    } elseif ($optionNameStr -match $addPattern) {
        $app = [string]$matches[1]
        $app = $app.Trim()
        if ($checkbox.Checked -eq $false) {
            $modifiedOption = "Remove $app"
        }
    } else {
        $modifiedOption = $checkbox.Tag.CurrentOption
    }
    $checkbox.Text = $modifiedOption
    $checkbox.Tag.CurrentOption = $modifiedOption

    $script:TickCheckbox = $true
    $checkbox.Checked = $true
    $script:TickCheckbox = $false
       
} # END of - function Modify-RecommendedOption


# =======================================================================================
# function - On-ClearAllClick
# =======================================================================================
function On-ClearAllClick {

    # Show non-modal "Please Wait" form
    $waitForm = New-Object System.Windows.Forms.Form
    $waitForm.Text = "WinFixIT - Please Wait"
    $waitForm.Size = [System.Drawing.Size]::new(430, 120)
    $waitForm.StartPosition = "CenterScreen"
    $waitForm.FormBorderStyle = "FixedDialog"
    $waitForm.ControlBox = $false
    $waitForm.TopMost = $true

    $waitLabel = New-Object System.Windows.Forms.Label
    $waitLabel.Text = $waitLabel.Text = "Please wait until the Recommended Options " +
        "have been re-set to: " + 
        [Environment]::NewLine +
        "   - reflect the amended state of your PC, and" +
        [Environment]::NewLine +
        "   - the Checkboxes have been cleared..."
    $waitLabel.Location = [System.Drawing.Point]::new(20, 20)
    $waitLabel.Size = [System.Drawing.Size]::new(400, 80)
    $waitLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $waitLabel.TextAlign = [System.Drawing.ContentAlignment]::TopLeft  
    $waitForm.Controls.Add($waitLabel)

    $waitForm.Show()
    [System.Windows.Forms.Application]::DoEvents()

    # Re-evaluate all options to reflect current state of PC
    On-ResetDefaultsClick

    # Then clear all checkboxes without triggering Modify-RecommendedOption
    $script:isBulkUpdate = $true
    foreach ($ctrl in $script:panelLeft.Controls) {
        foreach ($subCtrl in $ctrl.Controls) {
            # Uncheck the group-level "Select ALL Recommended Options" checkbox
            if ($subCtrl -is [System.Windows.Forms.CheckBox] -and
                $subCtrl.Tag -and
                $subCtrl.Tag.Kind -eq 'SelectAll') {
                $subCtrl.Checked = $false
            }
            # Uncheck all individual option checkboxes
            if ($subCtrl -is [System.Windows.Forms.Panel]) {
                foreach ($child in $subCtrl.Controls) {
                    if ($child -is [System.Windows.Forms.CheckBox] -and
                        $child.Tag -and
                        $child.Tag.Kind -eq 'Option') {
                        $child.Checked = $false
                    }
                }
            }
        }
    }
    $script:isBulkUpdate = $false
    Restore-AdvicePanel

    # Close the wait form
    $waitForm.Close()
    $waitForm.Dispose()

} # END of - function On-ClearAllClick

# =======================================================================================
# function - On-ContinueClick 
# =======================================================================================
Function On-ContinueClick {
    # PURPOSE: 
    #   Called when the user clicks the Continue button during task execution.
    #   Sets the flag that Pause-UntilContinueButtonPressed is waiting for,
    #   allowing task execution to proceed to the next task.

    $script:UserPressedContinue = $true

} # END of - function On-ContinueClick


# =======================================================================================
# function -  On-ResetDefaultsClick
# =======================================================================================
function On-ResetDefaultsClick {
# PURPOSE: Resets all Options in every Group to their default state as defined in the original XML configuration.  
#       It does not reload the XML but instead, relies on the OriginalOption property stored in each checkbox's Tag 
#       to restore the default state and text.
#       After resetting the OriginalOption, it calls Modify-RecommendedOption for each Option to ensure that 
#       the RecommendedOption is compatible with the configuration of the PC and sets the new RecommendedOption, 
#       accordingly.  It also ensures that if the RecommendedOption is "CANNOT INSTALL Recall", 
#       then the checkbox is set to unchecked, as this state is not actionable by the user.


    $script:isBulkUpdate = $true

    foreach ($group in $script:groups) {
        if ($group.DefaultMode -eq 'ONE') {
            # For ONE groups, check only the first option
            foreach ($ctrl in $script:panelLeft.Controls) {
                if ($ctrl.Tag -and $ctrl.Tag.Kind -eq 'Group' -and $ctrl.Tag.Group -eq $group.Name) {
                    foreach ($subCtrl in $ctrl.Controls) {
                        if ($subCtrl -is [System.Windows.Forms.Panel]) {
                            $isFirst = $true
                            foreach ($child in $subCtrl.Controls) {
                                if ($child -is [System.Windows.Forms.CheckBox] -and $child.Tag.Kind -eq 'Option') {
                                    $child.Checked           = $isFirst
                                    $child.Tag.CurrentOption = $child.Tag.OriginalOption
                                    $child.Text              = $child.Tag.OriginalOption
                                    if ($child.Tag.Label) { $child.Tag.Label.Text = $child.Tag.OriginalOption }
                                    $isFirst = $false
                                }
                            }
                        }
                    }
                }
            }
            continue
        }
        $defaultChecked = $true
        if ($group.PSObject.Properties.Name -contains 'DefaultMode') {
            if ($group.DefaultMode -eq 'NONE' -or $group.DefaultMode -eq 'DIY ONLY') { $defaultChecked = $false }
        }

        foreach ($ctrl in $script:panelLeft.Controls) {
            if ($ctrl.Tag -and $ctrl.Tag.Kind -eq 'Group' -and $ctrl.Tag.Group -eq $group.Name) {
                foreach ($subCtrl in $ctrl.Controls) {
                    if ($subCtrl.Tag -and $subCtrl.Tag.Kind -eq 'SelectAll') {
                        $subCtrl.Checked = $defaultChecked
                    }
                    if ($subCtrl -is [System.Windows.Forms.Panel]) {
                        foreach ($child in $subCtrl.Controls) {
                            if ($child -is [System.Windows.Forms.CheckBox] -and $child.Tag.Kind -eq 'Option') {
                                # Reset text and state to original Option
                                $child.Checked           = $defaultChecked
                                $child.Tag.CurrentOption = $child.Tag.OriginalOption
                                $child.Text              = $child.Tag.OriginalOption
                            }
                        }
                    }
                }
            }
        }
    }

    # Now call Modify-RecommendedOption for all Options to ensure deduction logic is applied after UI state is set
    foreach ($ctrl in $script:panelLeft.Controls) {
        if ($ctrl.Tag -and $ctrl.Tag.Kind -eq 'Group') {
            foreach ($subCtrl in $ctrl.Controls) {
                if ($subCtrl -is [System.Windows.Forms.Panel]) {
                    foreach ($child in $subCtrl.Controls) {
                        if ($child -is [System.Windows.Forms.CheckBox] -and $child.Tag.Kind -eq 'Option') {
                            $script:TickCheckbox = $false
                            Modify-RecommendedOption `
                                -checkbox          $child `
                                -IsRecommendedMode $true
                        if ($child.Text -eq 'CANNOT INSTALL Recall') {
                                $child.Checked = $false
                                if ($child.Tag.Label) { $child.Tag.Label.Text = $child.Text }
                            }
                        }
                    }
                }
            }
        }
    }
<#
    # --- Ensure Recall is always unchecked if CANNOT INSTALL Recall is set ---
    foreach ($ctrl in $script:panelLeft.Controls) {
        if ($ctrl.Tag -and $ctrl.Tag.Kind -eq 'Group') {
            foreach ($subCtrl in $ctrl.Controls) {
                if ($subCtrl -is [System.Windows.Forms.Panel]) {
                    foreach ($child in $subCtrl.Controls) {
                        if ($child -is [System.Windows.Forms.CheckBox] -and $child.Tag.Kind -eq 'Option') {
                            if ($child.Text -eq 'CANNOT INSTALL Recall') {
                                $child.Checked = $false
                                if ($child.Tag.Label) { $child.Tag.Label.Text = $child.Text }
                            }
                        }
                    }
                }
            }
        }
    }
#>
    $script:isBulkUpdate = $false
    Restore-AdvicePanel
    if ($script:btnPrintAdvice) { $script:btnPrintAdvice.Visible = $true }

} # END of - function On-ResetDefaultsClick


# =======================================================================================
# function - Print-AdvicePanel
# =======================================================================================
function Print-OptionsSelected {
    # PURPOSE: Print a formatted report of all checked options, grouped by Group,
    #          with a header showing machine name and date/time, bold group headings,
    #          and indented option lines.

    $machineName = $env:COMPUTERNAME
    $dateTime    = Get-Date -Format "dd MMMM yyyy   HH:mm"

    # Build list of line descriptors: {Text, Style, Indent}
    # Style: 'Title' | 'Bold' | 'Normal'
    $script:printLines = @()
    $script:printLines += [PSCustomObject]@{ Text = "OPTIONS Selected Report"; Style = 'Title'; Indent = 0 }
    $script:printLines += [PSCustomObject]@{ Text = "$machineName     $dateTime"; Style = 'Normal'; Indent = 0 }
    $script:printLines += [PSCustomObject]@{ Text = ""; Style = 'Normal'; Indent = 0 }

    foreach ($ctrl in $script:panelLeft.Controls) {
        if ($ctrl.Tag -and $ctrl.Tag.Kind -eq 'Group') {
            $groupName    = $ctrl.Tag.Group
            $groupChecked = @()
            foreach ($subCtrl in $ctrl.Controls) {
                if ($subCtrl -is [System.Windows.Forms.Panel]) {
                    foreach ($child in $subCtrl.Controls) {
                        if ($child -is [System.Windows.Forms.CheckBox] -and
                            $child.Tag.Kind -eq 'Option' -and $child.Checked) {
                            $groupChecked += $child.Tag.CurrentOption
                        }
                    }
                }
            }
            if ($groupChecked.Count -gt 0) {
                $script:printLines += [PSCustomObject]@{ Text = $groupName; Style = 'Bold'; Indent = 0 }
                foreach ($opt in $groupChecked) {
                    $script:printLines += [PSCustomObject]@{ Text = $opt; Style = 'Normal'; Indent = 1 }
                }
                $script:printLines += [PSCustomObject]@{ Text = ""; Style = 'Normal'; Indent = 0 }
            }
        }
    }

    $script:printLineIndex = 0

    $printDoc = New-Object System.Drawing.Printing.PrintDocument
    $printDoc.Add_PrintPage({
        param($s, $e)
        $fontTitle  = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
        $fontBold   = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
        $fontNormal = New-Object System.Drawing.Font("Segoe UI", 10)
        $brush      = [System.Drawing.Brushes]::Black
        $indentPx   = 30
        $x0         = [float]$e.MarginBounds.X
        $y          = [float]$e.MarginBounds.Y
        $pageBottom = [float]($e.MarginBounds.Y + $e.MarginBounds.Height)

        while ($script:printLineIndex -lt $script:printLines.Count) {
            $line = $script:printLines[$script:printLineIndex]
            $font = switch ($line.Style) {
                'Title'  { $fontTitle }
                'Bold'   { $fontBold }
                default  { $fontNormal }
            }
            $lineHeight = $font.GetHeight($e.Graphics) + 4

            # If this line won't fit, stop and signal another page is needed
            if ($y + $lineHeight -gt $pageBottom) {
                $e.HasMorePages = $true
                break
            }

            if ($line.Text) {
                $x = $x0 + ($line.Indent * $indentPx)
                $e.Graphics.DrawString($line.Text, $font, $brush, $x, $y)
            }
            $y          += $lineHeight
            $script:printLineIndex++
        }

        if ($script:printLineIndex -ge $script:printLines.Count) {
            $e.HasMorePages = $false
        }

        $fontTitle.Dispose()
        $fontBold.Dispose()
        $fontNormal.Dispose()
    })

    $dlg = New-Object System.Windows.Forms.PrintDialog
    $dlg.Document = $printDoc
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:printLineIndex = 0
        $printDoc.Print()
    }
} # END of - function Print-OptionsSelected


function Print-AdvicePanel {
    # PURPOSE: Print the Advice Panel using Windows Print Dialog with specified formatting

    Add-Type -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Printing;
using System.Windows.Forms;
public class AdvicePanelPrinter {
    public static string GroupHeading = "";
    public static string AdviceHeading = "";
    public static string AdviceText = "";
    public static void Print() {
        PrintDocument doc = new PrintDocument();
        doc.DocumentName = "Advice Panel";
        doc.PrintPage += new PrintPageEventHandler(PrintPage);
        PrintDialog dlg = new PrintDialog();
        dlg.Document = doc;
        if (dlg.ShowDialog() == DialogResult.OK) {
            doc.Print();
        }
        doc.Dispose();
    }
    private static void PrintPage(object sender, PrintPageEventArgs e) {
        float y = e.MarginBounds.Top;
        float left = e.MarginBounds.Left;
        Color headingColor = Color.FromArgb(0,51,53);
        // Group Heading: 16pt Arial Bold, RGB(0,51,53)
        if (!string.IsNullOrEmpty(GroupHeading)) {
            using (Font groupFont = new Font("Arial", 16, FontStyle.Bold))
            using (SolidBrush groupBrush = new SolidBrush(headingColor)) {
                // Draw a white rectangle behind the heading to ensure color visibility
                SizeF size = e.Graphics.MeasureString(GroupHeading, groupFont);
                e.Graphics.FillRectangle(Brushes.White, left, y, size.Width, size.Height);
                e.Graphics.DrawString(GroupHeading, groupFont, groupBrush, left, y);
                y += size.Height + 8;
            }
        }
        // Advice Heading: 14pt Arial Bold Italic, RGB(0,51,53)
        if (!string.IsNullOrEmpty(AdviceHeading)) {
            using (Font adviceHeadFont = new Font("Arial", 14, FontStyle.Bold | FontStyle.Italic))
            using (SolidBrush adviceHeadBrush = new SolidBrush(headingColor)) {
                SizeF size = e.Graphics.MeasureString(AdviceHeading, adviceHeadFont);
                e.Graphics.FillRectangle(Brushes.White, left, y, size.Width, size.Height);
                e.Graphics.DrawString(AdviceHeading, adviceHeadFont, adviceHeadBrush, left, y);
                y += size.Height + 8;
            }
        }
        // Advice: 12pt Calibri, black
        if (!string.IsNullOrEmpty(AdviceText)) {
            using (Font adviceFont = new Font("Calibri", 12, FontStyle.Regular))
            using (Brush adviceBrush = Brushes.Black) {
                RectangleF layout = new RectangleF(left, y, e.MarginBounds.Width, e.MarginBounds.Bottom - y);
                e.Graphics.DrawString(AdviceText, adviceFont, adviceBrush, layout);
            }
        }
    }
}
"@ -ReferencedAssemblies @('System.Drawing.dll','System.Windows.Forms.dll')

    # Gather text for printing
    $groupHeading  = if ($script:GroupHeading -and $script:GroupHeading.Text) { $script:GroupHeading.Text } else { '' }
    $adviceHeading = ''
    if ($script:adviceHeading -and $script:adviceHeading.Text) {
        $ah = $script:adviceHeading.Text.Trim()
        if ($ah -and $ah -ne 'Advice Panel') {
            $adviceHeading = $ah
        }
    }
    $adviceText    = if ($script:adviceRTbox -and $script:adviceRTbox.Text) { $script:adviceRTbox.Text } else { '' }

    [AdvicePanelPrinter]::GroupHeading = $groupHeading
    [AdvicePanelPrinter]::AdviceHeading = $adviceHeading
    [AdvicePanelPrinter]::AdviceText = $adviceText
    [AdvicePanelPrinter]::Print()

} # END of - function Print-AdvicePanel


# =======================================================================================
# function - RecallSupported
# =======================================================================================
function RecallSupported {
    # PURPOSE: 
    #       Checks if the 'Recall' app is supported on the current hardware by examining 
    #       the CPU model.

    try {
        $cpu = (Get-CimInstance Win32_Processor).Name
    } catch {
        return $false
    }

    if ($cpu -match 'Snapdragon' -or
        $cpu -match 'X Elite'   -or
        $cpu -match 'X Plus') {
        return $true
    }
    return $false

} # END of - function RecallSupported


# =======================================================================================
# function - Restore-AdvicePanel
# =======================================================================================
function Restore-AdvicePanel {
    # PURPOSE: Shows correct OPTION or ALTERNATIVE advice based on current full checkbox text.
    #          Falls back to OPTION advice if ALTERNATIVE missing.

    # --- Hide Task Log UI ---
    $script:TaskLogRTbox.Visible = $false
    $script:TaskLogRTbox.SendToBack()
    $script:btnContinue.Visible  = $false

    # --- Show Advice Panel UI ---
    $script:advicePanel.Visible     = $true
    $script:adviceHeading.Visible   = $true
    $script:adviceRTbox.Visible     = $true
    if ($script:btnPrintAdvice) { $script:btnPrintAdvice.Visible = $true }

    # --- Set Group Heading ---
    if ($script:selectedOption -and $script:selectedOption.Tag -and $script:selectedOption.Tag.PSObject.Properties.Name -contains 'Group') {
        $script:GroupHeading.Text = $script:selectedOption.Tag.Group
    } elseif ($script:selectedOption -and $script:selectedOption.Tag -and $script:selectedOption.Tag.PSObject.Properties.Name -contains 'GroupName') {
        $script:GroupHeading.Text = $script:selectedOption.Tag.GroupName
    } else {
        $script:GroupHeading.Text = ""
    }

    # --- No selection? Do NOT overwrite current advice ---
    if (-not $script:selectedOption) {
        if ($script:btnPrintAdvice) { $script:btnPrintAdvice.Visible = $true }
        return
    }
    # --- Primary lookup key (current visible text) ---
    $key = $script:selectedOption.Text.Trim()
    $adviceRtf = $null
    $heading = $key
    $boilerplate = $null
    if ($script:selectedOption.Tag -and $script:selectedOption.Tag.PSObject.Properties.Name -contains 'Group') {
        $groupName = $script:selectedOption.Tag.Group
        $CURRENT_OptionName = $script:selectedOption.Text

        $boilerplate = BoilerPlateText `
            -groupName $groupName `
            -CURRENT_OptionName $CURRENT_OptionName # This is needed as some BoilerPlateText depends on the Option content.
    }

    if ($script:btnPrintAdvice) { $script:btnPrintAdvice.Visible = $true }

    if ($script:adviceByGroupAndOption.ContainsKey($key)) {
        $adviceRtf = $script:adviceByGroupAndOption[$key]
    } elseif ($script:adviceByGroupAndOption.ContainsKey("$key Service")) {
        $adviceRtf = $script:adviceByGroupAndOption["$key Service"]
    } elseif ($script:selectedOption.Tag -and $script:selectedOption.Tag.PSObject.Properties.Name -contains 'OriginalOption') {
        $orig = $script:selectedOption.Tag.OriginalOption
        if ($orig -and $script:adviceByGroupAndOption.ContainsKey($orig)) {
            $adviceRtf = $script:adviceByGroupAndOption[$orig]
        }
    } elseif ($key -match '^(Remove|INSTALL|ADD|KEEP|DISABLE|ENABLE)\s+(.+)$') {
        $baseName = $matches[2]
        $fallback = "Remove $baseName"
        if ($script:adviceByGroupAndOption.ContainsKey($fallback)) {
            $heading = $fallback
            $adviceRtf = $script:adviceByGroupAndOption[$fallback]
        }
    }
    if (-not $adviceRtf) {
        $adviceRtf = "{\rtf1\ansi\fs22 \par No advice available.}"
    }
    if ($heading -and $heading -ne 'Advice Panel') {
        $script:adviceHeading.Text = $heading
    } else {
        $script:adviceHeading.Text = ''
    }
    if ($boilerplate -and $adviceRtf) {
        $script:adviceRTbox.Rtf = Concatenate-RTF -rtf1 $adviceRtf -rtf2 $boilerplate
    } else {
        $script:adviceRTbox.Rtf = $adviceRtf
    }
} # END of - function Restore-AdvicePanel


# =======================================================================================
# function - Test-ShortcutActive
# =======================================================================================

function Test-ShortcutActive {
    # PURPOSE: Tests if a shortcut for a given app is active in the specified location (Start Menu, Taskbar, Desktop).  
    #     For Start Menu, it first tries to export the Start Menu layout to JSON and parse it for pinned items, which is more reliable. If that fails (e.g. due to permissions), it falls back to checking for .lnk files in the Start Menu folders.    
    #     For Taskbar and Desktop, it checks for the presence of .lnk files in the respective directories, with some flexibility for partial matches and common synonyms (e.g. File Explorer vs File Manager).  
    #     The function returns $true if a matching shortcut is found, and $false otherwise.   
    #     Note: This function does not attempt to modify any shortcuts; it only checks for their presence.    
    # Usage example: Test-ShortcutActive -AppName "Microsoft Edge" -ShortcutType "Start Menu" 
    #      This would check if Microsoft Edge is pinned toStart Menu.
    param(
        [string]$AppName,
        [string]$ShortcutType  # "Start Menu", "Taskbar", "Desktop"
    )


    $path = $null
    if ($ShortcutType -eq 'Start Menu') {
        # Export Start Menu layout to JSON and parse for pin
        $tempJson = Join-Path $env:TEMP "StartLayout.json"
        try {
            Export-StartLayout -Path $tempJson -ErrorAction Stop
            $json = Get-Content $tempJson -Raw | ConvertFrom-Json
            # Build possible matches: AppName, AppID, PackageName from $script:AppLookup
            $possibleMatches = @($AppName)
            if ($script:AppLookup -and $script:AppLookup.ContainsKey($AppName)) {
                $lookup = $script:AppLookup[$AppName]
                if ($lookup.PackageName) { $possibleMatches += $lookup.PackageName }
                if ($lookup.AppID) { $possibleMatches += $lookup.AppID }
            }
            foreach ($item in $json.pinnedList) {
                foreach ($prop in $item.PSObject.Properties) {
                    if ($null -ne $prop.Value -and $prop.Value -is [string]) {
                        foreach ($needle in $possibleMatches) {
                            if ($prop.Value -like "*${needle}*") {
                                return $true
                            }
                        }
                    }
                }
            }
            return $false
        } catch {
            # Fallback to .lnk check if export fails
            $userPath   = Join-Path $env:APPDATA   "Microsoft\Windows\Start Menu\Programs"
            $systemPath = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs"
            $userLnk    = Join-Path $userPath   "$AppName.lnk"
            $systemLnk  = Join-Path $systemPath "$AppName.lnk"
            return ((Test-Path $userLnk) -or (Test-Path $systemLnk))
        }
    } elseif ($ShortcutType -eq 'Taskbar') {
        $path = "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\Taskbar"
        # --- Special cases for Copilot and Search Box/Button ---
        $appNameLower = $AppName.ToLowerInvariant()

        if ($appNameLower -in @('search', 'search box', 'search button', 'searchbar', 'search bar')) {
            
            # Robust detection for Search Box/Button pinned to Taskbar (Windows 11+ and legacy)
            $searchRegPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'
            $searchValue = $null
            try {
                $searchValue = Get-ItemPropertyValue -Path $searchRegPath -Name 'SearchboxTaskbarMode' -ErrorAction Stop
            } catch {}
            if ($null -ne $searchValue) {
                # 0 = hidden, 1 = icon, 2 = box, 3 = button (varies by build)
                if ($searchValue -ge 1) { return $true } else { return $false }
            }
            # Fallback: look for shortcut in Taskbar pinned folder (legacy/Win10)
            $shell = New-Object -ComObject WScript.Shell
            foreach ($file in Get-ChildItem -Path $path -Filter '*.lnk' -ErrorAction SilentlyContinue) {
                try {
                    $shortcut = $shell.CreateShortcut($file.FullName)
                    if (($shortcut.Description -match 'search') -or ($shortcut.TargetPath -match 'search')) {
                        return $true
                    }
                } catch {}
            }
            return $false
        }
    } elseif ($ShortcutType -eq 'Desktop') {
        $path = [System.Environment]::GetFolderPath('Desktop')
    } else {
        $path = $null
    }

    if ($null -ne $path) {
        # Try exact match first
        $shortcutFile = Join-Path $path "$AppName.lnk"
        if (Test-Path $shortcutFile) { return $true }
        # If not found, try robust case-insensitive and partial match
        $files = Get-ChildItem -Path $path -Filter '*.lnk' -ErrorAction SilentlyContinue
        $appNameLower = $AppName.ToLowerInvariant()
        # Handle common synonyms for File Explorer/Manager
        $synonyms = @{}
        $synonyms['File Manager'] = @('File Explorer', 'Explorer')
        $synonyms['File Explorer'] = @('File Manager', 'Explorer')
        $synonyms['Explorer'] = @('File Manager', 'File Explorer')
        foreach ($file in $files) {
            $fileBase = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
            $fileBaseLower = $fileBase.ToLowerInvariant()
            if ($fileBaseLower -eq $appNameLower) { return $true }
            if ($fileBaseLower -like "*${appNameLower}*" -or $appNameLower -like "*${fileBaseLower}*") { return $true }
            if ($synonyms.ContainsKey($AppName)) {
                foreach ($alt in $synonyms[$AppName]) {
                    $altLower = $alt.ToLowerInvariant()
                    if ($fileBaseLower -eq $altLower -or $fileBaseLower -like "*${altLower}*" -or $altLower -like "*${fileBaseLower}*") { return $true }
                }
            }
            # Try to check shortcut target path for the app name (if possible)
            try {
                $shell = New-Object -ComObject WScript.Shell
                $shortcut = $shell.CreateShortcut($file.FullName)
                if ($shortcut.TargetPath) {
                    $targetLower = $shortcut.TargetPath.ToLowerInvariant()
                    if ($targetLower -like "*${appNameLower}*") { return $true }
                }
            } catch {}
        }
        return $false
    } else {
        return $false
    }
} # END of - function Test-ShortcutActive


# =======================================================================================
# function - Verify-Microsoft365SubscriptionInstalled - CURRENTY UNUSED
# =======================================================================================
function Verify-Microsoft365SubscriptionInstalled {
    # PURPOSE:      
    #       Checks if a Microsoft 365 subscription (Click-to-Run/Appx) is installed on the system 
    #       by looking for specific indicators of installation. This includes checking for 
    #       Appx/UWP (Store/modern Office 365/365 A1/A3/A5)
    #       Click-to-Run (C2R) - OfficeClickToRun.exe (subscription only)
    
    # 1. Appx/UWP (Store/modern Office 365/365 A1/A3/A5)
    $appx = Get-AppxPackage -AllUsers | Where-Object {
        $_.Name -match 'Microsoft.Office.Desktop' -or $_.Name -match 'Microsoft.365' -or $_.Name -match 'OfficeHub'
    }
    if ($appx) { return $true }

    # 2. Click-to-Run (C2R) - OfficeClickToRun.exe (subscription only)
    $c2rPaths = @(
        "$env:ProgramFiles\Common Files\Microsoft Shared\ClickToRun\OfficeClickToRun.exe",
        "$env:ProgramFiles(x86)\Common Files\Microsoft Shared\ClickToRun\OfficeClickToRun.exe"
    )
    foreach ($path in $c2rPaths) {
        if (Test-Path $path) {
            # Check for subscription license in registry (not perpetual)
            $subKey = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
            if (Test-Path $subKey) {
                $config = Get-ItemProperty -Path $subKey -ErrorAction SilentlyContinue
                if ($config.ProductReleaseIds -match 'O365' -or $config.ProductReleaseIds -match '365ProPlus') {
                    return $true
                }
            }
        }
    }

    return $false
}
# END of - function Verify-Microsoft365SubscriptionInstalled


