<#  WinFixIT.ps1
    ============

       Purpose: Launches the On2it-WinFixIT in the correct mode
                based on the current environment and any prior user choices.
       
        Method: Structured for maximum readability:
                    1. MAIN-LINE first - the storyboard.
                    2. Subroutines called by Main-Line.
                    3. Run-In-Full-Windows-OS, 
                            then its subroutines.
                    4. Run-in-WinPE-Following-a-Run-in-Windows, 
                            then its subroutines (not previously specified).
                    5. Run-in-WinPE-Without-a-Previous-Run-in-Windows, 
                    6. Dot-sourced shared subroutines.
                    7. Execution entry point at the very end.

                This, somewhat unusual, layout keeps the "big picture" visible before
                the reader dives into the weeds, while still satisfying PowerShell's
                single-pass parsing rules.

   Designed by: Brian McGuigan
            of: On2it Software ltd
       Code by: Copilot
       Version: 1
         Dated: 3-Mar-26
        Status: 
#>  
$script:IntroScenarioAlreadyDisplayed = $false

# =====================================================================================
#  MAIN-LINE
# =====================================================================================
function Main-Line {  # Called by Last line in Script
    # This function determines the SCENARIO that the System is being called in
    # and calls the appropriate function that handles each Scenario:
    #    SCENARIO 1:  Run-In-Full-Windows-OS
    #    SCENARIO 2:  Run-in-WinPE-Following-a-Run-in-Windows
    #    SCENARIO 3:  Run-in-WinPE-Without-a-Previous-Run-in-Windows
    #    SCENARIO 4:  Run-in-WinPE-No-Windows-On-PC

    $InWinPE = (Is-OSenvironment-WinPE).IsWinPE
    #$Debug_Mode = $true
#   $InWinPE = $true              # DEBUG: Force WinPE scenarios (2, 3 or 4)
#   $Debug_ForceScenario4 = $true # DEBUG: bypass Windows-on-PC check → forces Scenario 4

    if (-not $InWinPE) {
        # SCENARIO 1: Full Windows  TESTED
        Run-In-Full-Windows-OS
    }
    else {
        # SCENARIO 2, 3, or 4: Running in WinPE
        # First determine whether Windows exists on any local drive —
        # this is the primary branch: no Windows on PC always means Scenario 4,
        # regardless of whether a results file is present.
        $usbDrive    = Split-Path -Path $PSScriptRoot -Qualifier
        $windowsOnPC = $null -ne (Get-PSDrive -PSProvider FileSystem |
            Where-Object {
                $_.Root -notlike "$usbDrive*" -and           # not the USB
                $_.Root -ne 'X:\' -and                       # not WinPE itself
                (Test-Path (Join-Path $_.Root 'Windows\System32'))
            } |
            Select-Object -First 1)

        if (-not $windowsOnPC -or $Debug_ForceScenario4) {
            # SCENARIO 4: WinPE, no Windows on PC (bare-metal install)
            Run-in-WinPE-No-Windows-On-PC

        } else {
            # Windows exists on PC — now check for a results file from a prior Windows run
            # Results live on the second (On2it-WinFixIT) partition. On a real USB that's
            # its own drive root, so the broad drive scan below finds it; in Development
            # it's a subfolder of D:, not a drive root, so check it directly first.
            $resultsFile = 'Win11-CompatibilityChecker-Results.txt'
            $usbRoot = if ($usbSecondPartition -and (Test-Path (Join-Path $usbSecondPartition "Logs\$resultsFile"))) {
                $usbSecondPartition
            } else {
                Get-PSDrive -PSProvider FileSystem |
                    Where-Object { Test-Path (Join-Path $_.Root "Logs\$resultsFile") } |
                    Select-Object -First 1 -ExpandProperty Root
            }

            if ($usbRoot) {
                # Results file found — read the last recorded choice
                $filePath = Join-Path $usbRoot "Logs\$resultsFile"
                $lastLine = Get-Content -LiteralPath $filePath -ErrorAction SilentlyContinue |
                            Where-Object { $_.Trim() -ne '' } |
                            Select-Object -Last 1

                if ($null -ne $lastLine -and $lastLine -in 'USER Chose - FULL', 'USER Chose - BYPASS') {
                    # SCENARIO 2: WinPE following a run in Windows with a recorded choice
                    Run-in-WinPE-Following-a-Run-in-Windows
                } else {
                    # Results file exists but no valid choice recorded — treat as no prior run
                    Run-in-WinPE-Without-a-Previous-Run-in-Windows
                }
            } else {
                # SCENARIO 3: WinPE, Windows on PC, no prior compatibility run
                Run-in-WinPE-Without-a-Previous-Run-in-Windows
            }
        }
    }
}  # END of - function Main-Line


# ====================================================================================
#  SCENARIO 1: Run-In-Full-Windows-OS
# ====================================================================================

    # STATUS: TO BE RE--TESTED
    <#
        .SYNOPSIS
            Handles the "Run from within Windows" scenario.

        .DESCRIPTION
            - Locates the USB root and verifies required files.
            - Loads scenario data from the .rtf file via Get-ScenarioFromUSB.
            - Displays the 'First Opened' scenario, 
              followed by the 'MAIN-MENU' Scenario, using Display-ScenarioSelected,).
            - Calls Prompt-ForUserChoice to render the prompt cleanly (no overwrite).
            - Calls:
                - Win11-CompatibilityChecker.ps1,
                - Win11-INSTALL, this is dot-sourced in Win11-INSTALL.ps1
                - On2it-WinFixIT-OTHERapplications.ps1, 
                - Opens the User Manual, or
                - Exits the system.
    #>
 function Run-In-Full-Windows-OS {

    $usbRoot = if ($env:WINFIXITROOT) { "$($env:WINFIXITROOT.TrimEnd('\'))\Local-INSTALL" } else { Split-Path -Path $PSScriptRoot -Parent }

    # --- INTRODUCTION SCREEN (once only) ---
    if (-not $script:IntroScenarioAlreadyDisplayed) {

        $IntroScenario = Get-ScenarioFromUSB `
            -UsbRoot $usbRoot `
            -SubFolder 'Scripts' `
            -RTFfileName 'WinFixIT\Display Scenarios.rtf' `
            -ScenarioPattern 'DISPLAY WHEN - First Opened'

        if ($IntroScenario) {
            Clear-Screen

            # Build stamp - Brian, 2026-08-21. Printed BEFORE the scenario,
            # not after: the scenario content itself ends with its own
            # [CLEAR] "Press ANY Key to continue..." directive, so anything
            # written after Display-ScenarioSelected returns only exists for
            # the instant between that clear and the next screen's own Clear-
            # Host - confirmed for real: "Something flashed and disappeared."
            # Printed first instead, so it's part of the same screen the user
            # actually reads and pauses on. Auto-derived from the newest
            # file's own timestamp under Scripts, deliberately NOT a hand-
            # maintained version number - we lost real time twice in one
            # session to PRODUCTION silently lagging Development, exactly the
            # kind of drift a manually-bumped number would also be prone to.
            $scriptsRoot = Join-Path $usbRoot 'Scripts'
            $newestFile  = Get-ChildItem -LiteralPath $scriptsRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            $buildStamp  = if ($newestFile) { $newestFile.LastWriteTime.ToString('dd/MM/yyyy') } else { 'unknown' }
            Write-Host "  Scripts updated: $buildStamp" -ForegroundColor DarkGray

            Display-ScenarioSelected -Scenario $IntroScenario
        }
        $script:IntroScenarioAlreadyDisplayed = $true
    }

    # --- MAIN MENU LOOP ---
    do {

        $MenuScenario = Get-ScenarioFromUSB `
            -UsbRoot $usbRoot `
            -SubFolder 'Scripts' `
            -RTFfileName 'WinFixIT\Display Scenarios.rtf' `
            -ScenarioPattern 'DISPLAY WHEN - MAIN MENU Required'

        if (-not $MenuScenario) {
            Write-Host "$R ERROR - Failed to load MAIN MENU scenario.$Rst"
            break
        }

        Clear-Screen
        Display-ScenarioSelected -Scenario $MenuScenario -TrackKeywords @('CHECK','INSTALL','DEBLOAT','READ','OPEN','EXIT')

        $rawPrompt = $MenuScenario.Prompts[0]
        $Prompt = (Invoke-Expression "`"$rawPrompt`"") + " "

        $UserChoice = Prompt-ForUserChoice `
            -PromptRows $Prompt `
            -ValidChoices @('CHECK','INSTALL','DEBLOAT','READ','OPEN','EXIT') `
            -SuppressChoices `
            -ReturnKey_Pressed '<Return>'
        $script:RowToOption = $null

        If ($UserChoice -ne '<Return>') {

            $result = $null

            switch ($UserChoice.ToUpper()) {
                'CHECK'   {$result = Check-Compatibility}
                'INSTALL' {$result = Install-Windows}
                'DEBLOAT' {$result = & (Join-Path $PSScriptRoot 'DeBloater.ps1')}
                'READ'    {$result = Display-UserManual}
                'OPEN'   {
                    # --- PowerShell Version Check ---
                    $PSMaj = $PSVersionTable.PSVersion.Major
                    if ($PSMaj -lt 7) {
                        Write-Host ""
                        Write-Host "===================================================================="
                        Write-Host "  WARNING: You are running under Windows PowerShell $PSMaj"
                        Write-Host "       Hyperlinks will NOT be clickable in this environment."
                        Write-Host "       Please run this tool using PowerShell 7 (pwsh.exe), or later."
                        Write-Host "===================================================================="
                        Write-Host ""
                        Write-Host "  Install PowerShell 7 now? (Y/N) [Y]: " -NoNewline -ForegroundColor Yellow
                        $installPS7Now = Read-Host
                        if ($installPS7Now -notmatch '^[Nn]') {
                            # Uses the fully offline "PowerShell Core (Portable)" package
                            # (a plain file copy of a pre-extracted PS7 build - no download)
                            # rather than the winget-based option. Confirmed 2026-07-11: the
                            # winget option needs internet, which isn't available on every PC
                            # WinFixIT runs on (Test-PC has none) - it silently failed every
                            # single time there, including after the restart it itself suggested.
                            $psInstallerBat = Join-Path $usbSecondPartition 'Install\Utilities\System Utilities\PowerShell Core (Portable)\Start.bat'
                            $ps7InstallPath = 'C:\Program Files\PowerShell7\pwsh.exe'
                            if (Test-Path -LiteralPath $psInstallerBat) {
                                Write-Host ""
                                Write-Host "  Installing PowerShell 7 (portable, offline copy) - please wait..." -ForegroundColor Cyan
                                $installResult = RUN-Installer -Pathname $psInstallerBat
                                Write-Host ""
                                Write-Host "  $installResult"
                                Write-Host ""
                                if (Test-Path -LiteralPath $ps7InstallPath) {
                                    # A plain file copy doesn't register itself anywhere, so
                                    # the .bat launchers' own "where pwsh" checks would never
                                    # find it without this - add its folder to the machine
                                    # PATH so every future WinFixIT launch picks it up.
                                    try {
                                        $ps7Folder   = Split-Path $ps7InstallPath -Parent
                                        $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
                                        if ($machinePath -notlike "*$ps7Folder*") {
                                            [Environment]::SetEnvironmentVariable('Path', "$machinePath;$ps7Folder", 'Machine')
                                        }
                                        Write-Host "  PowerShell 7 is now installed. Restart WinFixIT to use it -" -ForegroundColor Green
                                        Write-Host "  it's picked up automatically next time, no extra steps needed." -ForegroundColor Green
                                    } catch {
                                        Write-Host "  PowerShell 7 is installed at $ps7InstallPath, but couldn't" -ForegroundColor Yellow
                                        Write-Host "  add it to PATH automatically ($_). WinFixIT's .bat launchers" -ForegroundColor Yellow
                                        Write-Host "  won't find it on their own until that's added by hand." -ForegroundColor Yellow
                                    }
                                } else {
                                    Write-Host "  PowerShell 7 wasn't found at the expected location after" -ForegroundColor Yellow
                                    Write-Host "  install ($ps7InstallPath) - check the output above." -ForegroundColor Yellow
                                }
                            } else {
                                Write-Host ""
                                Write-Host "  ERROR: Couldn't find the PowerShell 7 installer at:" -ForegroundColor Red
                                Write-Host "    $psInstallerBat" -ForegroundColor Red
                                Write-Host "  You can still install it yourself via 'OPEN Library' ->" -ForegroundColor Red
                                Write-Host "  'Utilities' -> 'System Utilities' -> 'PowerShell Core (Portable)'" -ForegroundColor Red
                            }
                            Write-Host ""
                            Pause
                        }
                    } # end: version check

                    $InstallFolderPath = Join-Path $usbSecondPartition 'Install'
                    $result = Display-MenuFor `
                        -FolderPath $InstallFolderPath
                }  
                'EXIT' {
                    Write-Host ""
                    Write-Host "Exiting On2it-WinFixIT.  "
                    Write-Host "So long, and thanks for all the fish.  I hope the answer you got, was better than '42'. (HHGTTG)!"
                    Write-Host "COME AGAIN SOON! 😊"
                    break
                }
            }
            # If user enters 'EXIT' Close WinFixIT
            if ($UserChoice -eq 'EXIT') { break }

        } # END of - $UserChoice -ne '<Return>'

    } while ($true)  # Continue intil User enteres 'EXIT

}  # END of - function Run-In-Full-Windows-OS
 

# ====================================================================================
#  SCENARIO 2: Run-in-WinPE-Following-a-Run-in-Window
# ====================================================================================

function Run-in-WinPE-Following-a-Run-in-Windows {
<#   STATUS: FULLY-TESTED
    .SYNOPSIS
        WinPE with a prior choice already made in Windows.
    .DESCRIPTION
        - Displays the 'First Opened' scenario,    
        - Displays 'Compatibility Check ALREADY COMPLETED in Windows' Scenario 
          from the On2it-WinFixIT-Scenarios.rtf file, 
          with placeholders replaced for the user's previous choice, 
          read from 'Logs\Win11-CompatibilityChecker-Results.txt' 
        - Prompts to confirm or change it.
        - Allows User to choose beteen a 'FULL Install' or 'BYPASS Install'.
    #>

    $usbRoot = if ($env:WINFIXITROOT) { "$($env:WINFIXITROOT.TrimEnd('\'))\Local-INSTALL" } else { Split-Path -Path $PSScriptRoot -Parent }

    # --- INTRODUCTION SCREEN (once only) ---
    if (-not $script:IntroScenarioAlreadyDisplayed) {

        $IntroScenario = Get-ScenarioFromUSB `
            -UsbRoot $usbRoot `
            -SubFolder 'Scripts' `
            -RTFfileName 'WinFixIT\Display Scenarios.rtf' `
            -ScenarioPattern 'DISPLAY WHEN - First Opened'

        if ($IntroScenario) {
            Clear-Screen

            # Build stamp - Brian, 2026-08-21. Printed BEFORE the scenario,
            # not after: the scenario content itself ends with its own
            # [CLEAR] "Press ANY Key to continue..." directive, so anything
            # written after Display-ScenarioSelected returns only exists for
            # the instant between that clear and the next screen's own Clear-
            # Host - confirmed for real: "Something flashed and disappeared."
            # Printed first instead, so it's part of the same screen the user
            # actually reads and pauses on. Auto-derived from the newest
            # file's own timestamp under Scripts, deliberately NOT a hand-
            # maintained version number - we lost real time twice in one
            # session to PRODUCTION silently lagging Development, exactly the
            # kind of drift a manually-bumped number would also be prone to.
            $scriptsRoot = Join-Path $usbRoot 'Scripts'
            $newestFile  = Get-ChildItem -LiteralPath $scriptsRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            $buildStamp  = if ($newestFile) { $newestFile.LastWriteTime.ToString('dd/MM/yyyy') } else { 'unknown' }
            Write-Host "  Scripts updated: $buildStamp" -ForegroundColor DarkGray

            Display-ScenarioSelected -Scenario $IntroScenario
        }
        $script:IntroScenarioAlreadyDisplayed = $true
    }
               
    # --- Get prior choice from results log ---
    # Results live on the second (On2it-WinFixIT) partition so they survive USB-INSTALL
    # being read-only - fall back to $usbRoot only if that partition wasn't found.
    $resultsRoot = if ($usbSecondPartition) { $usbSecondPartition } else { $usbRoot }
    $resultsPath = Join-Path $resultsRoot 'Logs\Win11-CompatibilityChecker-Results.txt'
    $lastLine = Get-Content -LiteralPath $resultsPath |
                Where-Object { $_ -and $_.Trim() -ne '' } |
                Select-Object -Last 1

    switch -Regex ($lastLine.Trim()) {
        '^USER Chose - FULL$'   { $choiceText = 'FULL';   $altChoice = 'BYPASS' }
        '^USER Chose - BYPASS$' { $choiceText = 'BYPASS'; $altChoice = 'FULL'   }
        default {
            Write-Host "$R ERROR - Unrecognised choice in results file: '$lastLine'.$Rst"
            exit
        }
    }
    # Use pre-resolved $usbRoot from script load

    # --- Load scenario text ---
    $RTFfilename = 'WinFixIT\Display Scenarios.rtf'
    
    $ScenarioSelected = Get-ScenarioFromUSB `
        -UsbRoot $usbRoot `
        -SubFolder 'Scripts' `
        -RTFfileName $RTFfilename `
        -ScenarioPattern '^\[DISPLAY WHEN\s*-\s*Booted from USB with a choice already made in Windows\]'

    if (-not $ScenarioSelected) {
        Write-Host "$R ERROR - Could not find Scenario 2.$Rst"
        exit
    }
    # Replace placeholders in header text before display
    $ScenarioSelected.DisplayHeader = $ScenarioSelected.DisplayHeader |
    ForEach-Object { $_ -replace '<Option Selected>', $choiceText }

    # --- Replace placeholders in scenario text before display ---
    $ScenarioSelected.Prompts[0] = $ScenarioSelected.Prompts[0] -replace '<Option Selected>', $choiceText
    $ScenarioSelected.Prompts[1] = $ScenarioSelected.Prompts[1] -replace '<Other Option>', $altChoice

    # --- Display scenario header (with [PAUSE] and placeholder replacement) ---
    Clear-Screen   # clear the screen before displaying Scenario
    Display-ScenarioSelected -Scenario $ScenarioSelected

    # Call the prompt function to display the question and accept input.
     $firstAnswer = Prompt-ForUserChoice `
        -PromptRows $ScenarioSelected.Prompts[0] `
        -ValidChoices @('Y','N')

    if ($firstAnswer -eq 'N') {

        # Display the second prompt, overwriting the previous one on the same line.
        # This keeps the UI clean and avoids stacking multiple prompts vertically.
        $secondAnswer = Prompt-ForUserChoice `
            -PromptRows $ScenarioSelected.Prompts[1] `
            -ValidChoices @('Y','N') `
            -OverwritePreviousPrompt

        if ($secondAnswer -eq 'Y') {
            INSTALL-Windows
            return
        }
    }
    else {
        INSTALL-Windows
        return
    }

    Write-Host ""
    Write-Host "$Gy No installation was performed."
    Write-Host " You may restart your PC or close this window.$Rst"
    Write-Host ""

}  # End of - function Run-in-WinPE-Following-a-Run-in-Windows 


# =======================================================================================
#  SCENARIO 3: WinPE with no prior choice
# =======================================================================================
function Run-in-WinPE-Without-a-Previous-Run-in-Windows {
#    STATUS: TO BE TESTED
    <#
    .SYNOPSIS
        WinPE with no prior choice made in Windows.
    .DESCRIPTION
        - Displays the 'First Opened' scenario,  
        - Displays the 'WITHOUT a Compatibility Check in Windows' Scenario 
          from the On2it-WinFixIT-Scenarios.rtf file, 
        - prompts the user to restart in Windows or 
          continue from USB with warnings about inconclusive results.
    #>
    
    $usbRoot = if ($env:WINFIXITROOT) { "$($env:WINFIXITROOT.TrimEnd('\'))\Local-INSTALL" } else { Split-Path -Path $PSScriptRoot -Parent }

    # --- INTRODUCTION SCREEN (once only) ---
    if (-not $script:IntroScenarioAlreadyDisplayed) {

        $IntroScenario = Get-ScenarioFromUSB `
            -UsbRoot $usbRoot `
            -SubFolder 'Scripts' `
            -RTFfileName 'WinFixIT\Display Scenarios.rtf' `
            -ScenarioPattern 'DISPLAY WHEN - First Opened'

        if ($IntroScenario) {
            Clear-Screen

            # Build stamp - Brian, 2026-08-21. Printed BEFORE the scenario,
            # not after: the scenario content itself ends with its own
            # [CLEAR] "Press ANY Key to continue..." directive, so anything
            # written after Display-ScenarioSelected returns only exists for
            # the instant between that clear and the next screen's own Clear-
            # Host - confirmed for real: "Something flashed and disappeared."
            # Printed first instead, so it's part of the same screen the user
            # actually reads and pauses on. Auto-derived from the newest
            # file's own timestamp under Scripts, deliberately NOT a hand-
            # maintained version number - we lost real time twice in one
            # session to PRODUCTION silently lagging Development, exactly the
            # kind of drift a manually-bumped number would also be prone to.
            $scriptsRoot = Join-Path $usbRoot 'Scripts'
            $newestFile  = Get-ChildItem -LiteralPath $scriptsRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            $buildStamp  = if ($newestFile) { $newestFile.LastWriteTime.ToString('dd/MM/yyyy') } else { 'unknown' }
            Write-Host "  Scripts updated: $buildStamp" -ForegroundColor DarkGray

            Display-ScenarioSelected -Scenario $IntroScenario
        }
        $script:IntroScenarioAlreadyDisplayed = $true
    }

    # Use pre-resolved $usbRoot from script load
    $RTFfilename = 'WinFixIT\Display Scenarios.rtf'
    $sc = Get-ScenarioFromUSB `
        -UsbRoot $usbRoot `
        -SubFolder 'Scripts' `
        -RTFfileName $RTFfilename `
        -ScenarioPattern '^\[DISPLAY WHEN\s*-\s*Booted from USB with no prior choice in Windows\]'

    if (-not $sc) {
        Write-Host "$R ERROR - Failed to load scenario 3 metadata.$Rst"
        exit
    }

    # --- Add scenario name for placeholder replacement if needed ---
    $sc | Add-Member -NotePropertyName ScenarioName -NotePropertyValue 'Booted from USB with no prior choice in Windows'

    # --- Display scenario header (with [PAUSE] support) ---
    Clear-Screen # Clear screen
    Display-ScenarioSelected -Scenario $sc

    # --- Prompt 1: gentle but clear ---
    $firstAnswer = Prompt-ForUserChoice `
        -PromptRows $sc.Prompts[0] `
        -ValidChoices @('Y','N') 

    if ($firstAnswer -eq 'Y') {
        Write-Host ""
        Write-Host "$Gy You chose to restart in Windows.$Rst"  
        Write-Host "$Gy Please remove the USB and restart your PC.$Rst"
        exit
    }

    
    # --- Prompt 2: more insistent ---
    $secondAnswer = Prompt-ForUserChoice `
        -PromptRows $sc.Prompts[1] `
        -ValidChoices @('Y','N')

    if ($secondAnswer -eq 'Y') {
        CHECK-Compatibility
        INSTALL-Windows
        return
    } else {
        Write-Host "$Gy Terminating so you can restart in Windows.$Rst"
        exit
    }

    Write-Host ""
    Write-Host "$Gy No installation was performed."
    Write-Host " You may restart your PC or close this window.$Rst"
    Write-Host ""

}  # END of - function Run-in-WinPE-Without-a-Previous-Run-in-Windows


# =======================================================================================
#  SCENARIO 4: WinPE, no Windows on PC at all (bare-metal install)
# =======================================================================================
function Run-in-WinPE-No-Windows-On-PC {
#    STATUS: NEW - UNTESTED
    <#
    .SYNOPSIS
        WinPE with no Windows installation on the PC.
    .DESCRIPTION
        - Displays the 'First Opened' scenario (once only).
        - Displays the 'Booted from USB with no Windows on PC' scenario.
        - Prompts the user to proceed with a compatibility check and installation.
          Unlike Scenario 3, there is no Windows to return to, so the advice is
          entirely forward-looking.
    #>

    $usbRoot = if ($env:WINFIXITROOT) { "$($env:WINFIXITROOT.TrimEnd('\'))\Local-INSTALL" } else { Split-Path -Path $PSScriptRoot -Parent }

    # --- INTRODUCTION SCREEN (once only) ---
    if (-not $script:IntroScenarioAlreadyDisplayed) {

        $IntroScenario = Get-ScenarioFromUSB `
            -UsbRoot $usbRoot `
            -SubFolder 'Scripts' `
            -RTFfileName 'WinFixIT\Display Scenarios.rtf' `
            -ScenarioPattern 'DISPLAY WHEN - First Opened'

        if ($IntroScenario) {
            Clear-Screen

            # Build stamp - Brian, 2026-08-21. Printed BEFORE the scenario,
            # not after: the scenario content itself ends with its own
            # [CLEAR] "Press ANY Key to continue..." directive, so anything
            # written after Display-ScenarioSelected returns only exists for
            # the instant between that clear and the next screen's own Clear-
            # Host - confirmed for real: "Something flashed and disappeared."
            # Printed first instead, so it's part of the same screen the user
            # actually reads and pauses on. Auto-derived from the newest
            # file's own timestamp under Scripts, deliberately NOT a hand-
            # maintained version number - we lost real time twice in one
            # session to PRODUCTION silently lagging Development, exactly the
            # kind of drift a manually-bumped number would also be prone to.
            $scriptsRoot = Join-Path $usbRoot 'Scripts'
            $newestFile  = Get-ChildItem -LiteralPath $scriptsRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            $buildStamp  = if ($newestFile) { $newestFile.LastWriteTime.ToString('dd/MM/yyyy') } else { 'unknown' }
            Write-Host "  Scripts updated: $buildStamp" -ForegroundColor DarkGray

            Display-ScenarioSelected -Scenario $IntroScenario
        }
        $script:IntroScenarioAlreadyDisplayed = $true
    }

    $RTFfilename = 'WinFixIT\Display Scenarios.rtf'
    $sc = Get-ScenarioFromUSB `
        -UsbRoot $usbRoot `
        -SubFolder 'Scripts' `
        -RTFfileName $RTFfilename `
        -ScenarioPattern '^\[DISPLAY WHEN\s*-\s*Booted from USB with no Windows on PC\]'

    if (-not $sc) {
        Write-Host "$R ERROR - Failed to load scenario 4 metadata.$Rst"
        exit
    }

    # --- Display scenario content ---
    Clear-Screen
    Display-ScenarioSelected -Scenario $sc

    # --- Prompt 1: run Compatibility Check first? ---
    $firstAnswer = Prompt-ForUserChoice `
        -PromptRows $sc.Prompts[0] `
        -ValidChoices @('Y','N')

    if ($firstAnswer -eq 'Y') {
        CHECK-Compatibility
        # CHECK-Compatibility calls Give-CompatibilityAdvice, which handles the install decision.
        return
    }

    # --- Prompt 2: skip the check, go straight to install? (overwrites Prompt 1) ---
    $secondAnswer = Prompt-ForUserChoice `
        -PromptRows $sc.Prompts[1] `
        -ValidChoices @('Y','N') `
        -OverwritePreviousPrompt

    if ($secondAnswer -eq 'Y') {
        INSTALL-Windows
        return
    }

    Write-Host ""
    Write-Host "$Gy No installation was performed."
    Write-Host " You may restart your PC or close this window.$Rst"
    Write-Host ""

}  # END of - function Run-in-WinPE-No-Windows-On-PC


# ===========================================================================================================
# function Display-UserManual 
# ===========================================================================================================

function Display-UserManual {


    $usbRoot = Split-Path $PSScriptRoot -Parent
    # The manual itself lives on the second (On2it-WinFixIT) partition - a more
    # natural place for someone to look than the WinPE boot partition - but the
    # viewer tool it's read with stays alongside the rest of USB-INSTALL's Tools.
    $manualPDF  = Join-Path $usbSecondPartition 'WinFixIT - User Manual.pdf'
    $viewerEXE  = Join-Path $usbRoot 'Tools\PDF-Viewer\SumatraPDF.exe'

    if (Test-Path $manualPDF) {

        if (Test-Path $viewerEXE) {
            # Launch PDF using SumatraPDF
            Start-Process $viewerEXE -ArgumentList "`"$manualPDF`""
        }
        else {
            # Fall back to Windows default PDF handler
            Start-Process $manualPDF
        }
    }
    else {
        Write-Host "User Manual not found at: $manualPDF"
    }
}


# =================================================================================
# Code that is exectuted when the Script is first loaded.  It does NOT contain function definitions.
# =================================================================================

# Log all runtime errors (terminating and non-terminating) to the Logs folder
trap {
    $logsFolder = Join-Path (Split-Path $PSScriptRoot -Parent) 'Logs'
    if (-not (Test-Path $logsFolder)) { New-Item $logsFolder -ItemType Directory -Force | Out-Null }
    $errLog = Join-Path $logsFolder 'runtime-errors.log'
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') RUNTIME ERROR: $_" | Out-File $errLog -Append
    "  Script : $($_.InvocationInfo.ScriptName)" | Out-File $errLog -Append
    "  Line   : $($_.InvocationInfo.ScriptLineNumber)" | Out-File $errLog -Append
    "  Code   : $($_.InvocationInfo.Line.Trim())" | Out-File $errLog -Append
    continue
}

#  DOT-SOURCE SHARED SUBROUTINES
# ==============================
$Error.Clear()
. "$PSScriptRoot\WinFixIT\USER Prompting.ps1"
. "$PSScriptRoot\WinFixIT\Display Scenarios.ps1"
. "$PSScriptRoot\WinFixIT\Install Windows.ps1"
. "$PSScriptRoot\WinFixIT\Check Compatibility.ps1"
. "$PSScriptRoot\WinFixIT\Check Compatibility - UserAdvice.ps1"
. "$PSScriptRoot\WinFixIT\Extensible Dynamic Menus.ps1"

# Log any load failures to a file so WinPE errors can be diagnosed
if ($Error.Count -gt 0) {
    $logsFolder = Join-Path (Split-Path $PSScriptRoot -Parent) 'Logs'
    if (-not (Test-Path $logsFolder)) { New-Item $logsFolder -ItemType Directory -Force | Out-Null }
    $startupLog = Join-Path $logsFolder 'startup-errors.log'
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') WinFixIT startup errors:" | Out-File $startupLog -Append
    $Error | ForEach-Object { "  $_" | Out-File $startupLog -Append }
    $Error.Clear()
    Write-Host ""
    Write-Host ">>> Startup errors detected - press Enter to continue <<<"
    $null = Read-Host
}

 
# Set the console window icon (title bar + taskbar) from WinFixIT.ico
$script:_iconPath = if ($env:WINFIXITROOT) {
    "$($env:WINFIXITROOT.TrimEnd('\'))\WinFixIT.ico"
} else {
    "$(Split-Path -Path $PSScriptRoot -Parent)\WinFixIT.ico"
}
try {
    if ((Test-Path $script:_iconPath) -and -not ('WinFixITWindow' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WinFixITWindow {
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern IntPtr LoadImage(IntPtr h, string name, uint type, int cx, int cy, uint load);
}
'@
    }
    if (Test-Path $script:_iconPath) {
        $hwnd = [WinFixITWindow]::GetConsoleWindow()
        if ($hwnd -ne [IntPtr]::Zero) {
            $bigIco   = [WinFixITWindow]::LoadImage([IntPtr]::Zero, $script:_iconPath, 1, 0,  0,  0x10)
            $smallIco = [WinFixITWindow]::LoadImage([IntPtr]::Zero, $script:_iconPath, 1, 16, 16, 0x10)
            [void][WinFixITWindow]::SendMessage($hwnd, 0x80, [IntPtr]1, $bigIco)
            [void][WinFixITWindow]::SendMessage($hwnd, 0x80, [IntPtr]0, $smallIco)
        }
    }
} catch { }

# ---------------------------------------------------------------------------
#  Disable Console QuickEdit Mode - Windows pauses ALL output to a console
#  window the instant someone clicks into it (even just to bring it into
#  focus, or an accidental drag-select), and freezes it there until Escape
#  or Enter is pressed to release the selection. Found for real, 2026-08-20
#  (Brian): a local install on Pams-PC looked hung mid-copy with no error at
#  all - it was this. The underlying robocopy isn't even affected (its
#  output is redirected to a file, not the console - see Install-WinFixIT-
#  Local.ps1's Invoke-RobocopyDotsOnly), only the visible dots stop dead -
#  but a student/customer has no way to know that, or what to do about it.
#  Disabling QuickEdit here means a click can no longer freeze this window
#  at all, for the rest of the session - done once, as early as possible, so
#  it covers every scenario (menus, copies, installs) from the very start.
# ---------------------------------------------------------------------------
try {
    if (-not ('WinFixITConsole' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WinFixITConsole {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll")]
    public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
    [DllImport("kernel32.dll")]
    public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
}
'@
    }
    $STD_INPUT_HANDLE       = -10
    $ENABLE_QUICK_EDIT_MODE = 0x0040
    $ENABLE_EXTENDED_FLAGS  = 0x0080

    $stdIn = [WinFixITConsole]::GetStdHandle($STD_INPUT_HANDLE)
    $mode  = 0
    if ([WinFixITConsole]::GetConsoleMode($stdIn, [ref]$mode)) {
        $newMode = ($mode -band (-bnot $ENABLE_QUICK_EDIT_MODE)) -bor $ENABLE_EXTENDED_FLAGS
        [void][WinFixITConsole]::SetConsoleMode($stdIn, $newMode)
    }
} catch { }

# Resolve the current script's filename once (works in script scope, not function scope)
$script:CurrentPs1FileName = if ($PSCommandPath) {
    [System.IO.Path]::GetFileName($PSCommandPath)
} else {
    # Fallbacks for odd hosts
    [System.IO.Path]::GetFileName($MyInvocation.MyCommand.Path)
}
# --- Locate USB root using a guaranteed anchor file ---
$usbRootInfo = Get-USBRoot-And-RequiredFiles `
    -Ps1FileName $script:CurrentPs1FileName `
    -RequiredFiles @('RUN - On2it-WinFixIT.bat')

$usbRoot             = $usbRootInfo.UsbRoot
$usbSecondPartition  = $usbRootInfo.UsbSecondPartition
$usbCoursesPartition = $usbRootInfo.UsbCoursesPartition

# Set Environment variables for OPEN Command to work in function RUN-Install
$env:USB_INSTALL = $usbRoot
$env:USB_POSTINSTALL = $usbSecondPartition
# Empty string, not $null - Install-WinFixIT-Local.ps1 checks
# [string]::IsNullOrEmpty($env:USB_COURSES), and assigning $null to an
# environment variable in PowerShell actually DELETES it rather than
# setting it, which would make a later check against it behave
# inconsistently depending on what a PREVIOUS session in the same shell
# happened to leave behind.
$env:USB_COURSES = if ($usbCoursesPartition) { $usbCoursesPartition } else { '' }

# =========================================================================
#  START - at the beginning (a very good place to start)
# =========================================================================

Main-Line  # This is the LAST line to be read and the FIRST to be executed

# END of - On2it-WinFixIT.ps1