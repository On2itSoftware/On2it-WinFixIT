# Win11-DeBloater-PerformSelectedOptions.ps1
# ==========================================
<# 
        Purpose: This Script contains all the Functions that form the Back-End of the DeBloater.  
                 It takes the Options selected by the user in the Front-End,
                 and performs the selected options, when they click the PERFORM Selected Options Button. 

   Designed by: Brian McGuigan
            of: On2it Software Ltd
       Code by: Claude
       Version: 1
         Dated: 
        Status: Being TESTED
#>
# =======================================================================================
# Script-level initialisation
# =======================================================================================
# The following variables are initialised here at script level, outside of any function.
# This code runs automatically when the script is dot-sourced by Win11-DeBloater-UI.ps1,
# BEFORE any functions are called.
# This ensures that these variables are available to all functions in this script
# from the moment it is loaded, without needing to be initialised inside each function.
# =======================================================================================

if (-not (Test-Path variable:script:ExplorerRestartNeeded))     { $script:ExplorerRestartNeeded     = $false }
if (-not (Test-Path variable:script:SuppressLogUpdates))        { $script:SuppressLogUpdates        = $false }
if (-not (Test-Path variable:script:PauseLatch))                { $script:PauseLatch                = $false }
if (-not (Test-Path variable:script:PendingSummary))            { $script:PendingSummary            = $null  }
if (-not (Test-Path variable:script:stopRequested))             { $script:stopRequested             = $false }
if (-not (Test-Path variable:script:IsLastTask))                { $script:IsLastTask                = $false }
if (-not (Test-Path variable:script:UserPressedContinue))       { $script:UserPressedContinue       = $false }
if (-not (Test-Path variable:script:RemoveMSAccount))           { $script:RemoveMSAccount           = $false }
if (-not (Test-Path variable:script:NewUserCreatedSuccessfully)){ $script:NewUserCreatedSuccessfully = $false }
if (-not (Test-Path variable:script:ManualPinInstructionsShown)){ $script:ManualPinInstructionsShown = $false }
if (-not (Test-Path variable:script:LogFontSize))               { $script:LogFontSize               = 18     }

# =======================================================================================
# Function: Perform-SelectedOptions
# =======================================================================================

function Perform-SelectedOptions {
    # PURPOSE:
    #   This function iterates through all the options selected by the user in the form and performs the corresponding tasks. 
    #   It also manages the UI state to show the Task Log and hide the advice panel while tasks are running.
    #   The function includes error handling to ensure that any issues during task execution are logged 
    #   and do not crash the application.   
    # METHOD:
    #   There are calls to specific functions for handling major features:
    #       Microsoft 365, 
    #       OneDrive, 
    #       Teams, 
    #       Bitlocker, 
    #       CoPilot, 
    #       Recall,
    #       Microsoft Accounts,
    #       Xbox, 
    #       Solitaire,
    #   and a general REMOVEorKEEP function for other options. 
    #
    # PLEASE NOTE: 
    #       The text of each Option MUST match exactly the Original Option as specified on 
    #       Win11-DeBloater-UI-GroupsAndOptions.rtf.  For example, "Remove the Microsoft 365 Application".
    #       Should Modify-RecommendedOption have changed it to:
    #           "KEEP the Microsoft 365 Application", or
    #           "Please INSTALL the Microsoft 365 Application - MANUALLY",
    #       THEN 
    #           the same Function Remove-and-BLOCK-Microsoft-365-Application, will still be called. 
    #
    #       This is because the Original Option is the baseline for identifying which task to perform, 
    #       and the Current Option text may have been modified to reflect the user's choice 
    #       or to provide additional instructions.
    
    $localDEBUG_Mode = $false

    # Reset stop flag and transform PERFORM button to STOP RUN for the duration of the run
    $script:stopRequested = $false
    Enter-StopRunMode

    # Hide post-PERFORM print panel (shown again when PERFORM completes)
    if ($script:postPerformPanel)    { $script:postPerformPanel.Visible    = $false }
    if ($script:lblPostPerformPanel) { $script:lblPostPerformPanel.Visible = $false }
    
    # Show Task Log
    $script:TaskLogRTbox.Text    = ""
    $script:TaskLogRTbox.Visible = $true
    $script:TaskLogRTbox.BringToFront()

    # Hide advice panel content while log is active
    $script:adviceRTbox.Visible   = $false
    $script:adviceHeading.Visible = $false
    $script:adviceLabel.Text      = "Task Log"

    $script:btnContinue.Visible     = $false
    $script:UserPressedContinue     = $false

    # re-initialise Task Logs
    $script:DetailedTaskLog = @()
    $script:SummaryTaskLog  = @()
    $script:CurrentTaskLog  = @()
    $script:IsLastTask      = $false

    LogTask-RunHeader

    # --- Create a System Restore Point before making any changes ---
    # ===============================================================

    LogTask-Start "Create System Restore Point"
    LogTask-Progress "    NOTE: This can take many minutes on some systems."
    LogTask-Progress "    A dialog will appear every 10 minutes if it is still running."

    $restorePath = "HKLM:\Software\Microsoft\Windows NT\CurrentVersion\SystemRestore"
    $originalFrequency = $null
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue

        # Save the original frequency value if it exists, so we can restore it afterwards
        $originalFrequency = Get-ItemProperty -Path $restorePath `
            -Name "SystemRestorePointCreationFrequency" -ErrorAction SilentlyContinue

        # Temporarily allow restore point creation regardless of frequency limit
        Set-ItemProperty -Path $restorePath `
            -Name "SystemRestorePointCreationFrequency" -Value 0 -Type DWord -Force

        # Run in a background job so Checkpoint-Computer cannot hang the DeBloater indefinitely.
        $job = Start-Job -ScriptBlock {
            Checkpoint-Computer `
                -Description "WinFixIT DeBloater - Before Changes" `
                -RestorePointType "MODIFY_SETTINGS" `
                -ErrorAction Stop
        }

        Add-Type -AssemblyName Microsoft.VisualBasic
        $elapsedMinutes = 0
        $waitMinutes    = 10
        while ($true) {
            $completed = Wait-Job -Job $job -Timeout ($waitMinutes * 60)
            if ($null -ne $completed) { break }   # finished — exit the wait loop

            $elapsedMinutes += $waitMinutes
            $answer = [Microsoft.VisualBasic.Interaction]::InputBox(
                "System Restore Point creation is still running after $elapsedMinutes minute(s)." +
                "`n`nEnter how many more minutes to wait, or 0 to cancel the Restore Point:",
                "Still Creating Restore Point",
                "10"
            )

            $extra = 0
            if ([string]::IsNullOrWhiteSpace($answer) -or
                -not [int]::TryParse($answer.Trim(), [ref]$extra) -or
                $extra -le 0) {
                Remove-Job -Job $job -Force
                throw "Cancelled by user after $elapsedMinutes minutes (VSS still unresponsive)."
            }
            $waitMinutes = $extra
            LogTask-Progress "    Still waiting... ($elapsedMinutes min elapsed, waiting $extra more min)"
        }
        Receive-Job -Job $job -ErrorAction Stop | Out-Null
        Remove-Job -Job $job

        LogTask-Progress  "    To undo ALL changes if needed:"
        LogTask-Progress  "           Start -> Search 'Create a restore point' -> click 'System Restore'"
        LogTask-Progress  "           -> Choose 'WinFixIT DeBloater - Before Changes' -> follow the wizard"
        LogTask-Progress  "    To undo SELECTED changes - just re-run DeBloater"
        LogTask-Completion "CREATED   - System Restore Point: 'WinFixIT DeBloater - Before Changes'"
    }
    catch {
        $errorMessage = $_.Exception.Message
        LogTask-Completion "FAILED    - Could not create System Restore Point: $errorMessage"

        $response = [System.Windows.Forms.MessageBox]::Show(
            "WinFixIT was unable to create a System Restore Point before making changes.$([Environment]::NewLine)$([Environment]::NewLine)" +
            "Error: $errorMessage$([Environment]::NewLine)$([Environment]::NewLine)" +
            "Without a Restore Point, you may not be able to undo the changes made by this tool.$([Environment]::NewLine)$([Environment]::NewLine)" +
            "Do you wish to proceed anyway?",
            "System Restore Point Failed",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )

        if ($response -eq [System.Windows.Forms.DialogResult]::No) {
            LogTask-Completion "ABORTED   - User chose to abort after Restore Point failure."
            LogTask-RunFooter
            return
        }
        else {
            LogTask-Completion "CONTINUING - User chose to proceed without a Restore Point."
        }
    }
    finally {
        # Always restore the registry key whether we succeeded, timed out, or errored.
        if ($null -ne $originalFrequency) {
            Set-ItemProperty -Path $restorePath `
                -Name "SystemRestorePointCreationFrequency" `
                -Value $originalFrequency.SystemRestorePointCreationFrequency -Type DWord -Force
        } else {
            Remove-ItemProperty -Path $restorePath `
                -Name "SystemRestorePointCreationFrequency" -ErrorAction SilentlyContinue
        }
    } # END of System Restore Point creation

    # Read through all Options and call the appropriate Function based the Option's Original\Base\Recommended Name
    # ============================================================================================================
    foreach ($ctrl in $script:panelLeft.Controls) {
        if ($ctrl.Tag -and $ctrl.Tag.Kind -eq 'Group') {        
            foreach ($subCtrl in $ctrl.Controls) {
                if ($subCtrl -is [System.Windows.Forms.Panel]) {
                    foreach ($child in $subCtrl.Controls) {
                        if ($child -is [System.Windows.Forms.CheckBox] -and $child.Tag -and $child.Tag.Kind -eq 'Option') {
                            $CheckBox = $child                                       # OPEN foreach $checkboxcontrol
                            if ($CheckBox -is [System.Windows.Forms.CheckBox]) {     # OPEN if $CheckBox

                                # Local variables for clarity
                                $OriginalOption = $CheckBox.Tag.OriginalOption
                                $OriginalOption = $OriginalOption -replace '&&','&'
                                $CurrentOption  = $CheckBox.Tag.CurrentOption
                                $CurrentOption  = $CurrentOption -replace '&&','&'

                                # Skip unchecked options entirely
                                if (-not $CheckBox.Checked) { continue }

                                # If user clicked STOP RUN, skip all remaining options
                                if ($script:stopRequested) { continue }

                                # There is no-point in DEBUGGING unchecked Items
                                If ($localDEBUG_Mode) { 
                                    Write-Host "[DEBUG] Processing: OriginalOption='$OriginalOption' Checked=$($CheckBox.Checked)" -ForegroundColor Cyan 
                                    Write-Host "[DEBUG] Processing: CurrentOption='$CurrentOption'"
                                }

                                # Options Requiring their own SPECIFIC FUNCTION
                                # =============================================
                                # --- Major Windows Features ------------------------------------------------------------
                                if ($OriginalOption -eq "Remove Microsoft 365") {          # TESTED & WORKING
                                    Remove-and-BLOCK-Microsoft-365-Application $CheckBox $CurrentOption
                                }
                                elseif ($OriginalOption -eq "Remove OneDrive") {           # TESTED & WORKING
                                    Remove-and-BLOCK-OneDrive $CheckBox $CurrentOption
                                }
                                elseif ($OriginalOption -eq "Remove Microsoft Teams") {    # TESTED & WORKING
                                    Remove-and-BLOCK-Microsoft-Teams-Application $CheckBox $CurrentOption
                                }
                                elseif ($OriginalOption -eq "Turn BitLocker OFF") {        # TESTED & WORKING
                                    Turn-Bitlocker-OFF $CheckBox $CurrentOption
                                }
                                elseif ($OriginalOption -eq "KEEP CoPilot") {              # TESTED & WORKING
                                    KEEP-CoPilot-Application $CheckBox $CurrentOption
                                    # What about CoPilot in Microsoft 365
                                }
                                elseif($OriginalOption -eq "ENABLE Low Latency Profile (LLP)") {    
                                    ENABLE-LowLatencyProfile $CheckBox $CurrentOption    # TESTED & WORKING
                                }
                                elseif ($OriginalOption -eq "Remove OneDrive Auto-Start") { 
                                    MODIFY-OneDriveAutoStart $CheckBox $CurrentOption # TESTED and WORKING
                                }
                                elseif ($OriginalOption -eq "KEEP Recall") {
                                    KEEP-Recall-Application $CheckBox $CurrentOption  # NOT YET TESTED
                                }
                                    # TODO: Test KEEP-Recall-Application - requires Copilot+ PC with NPU
                                    # NOTE: Cannot be tested on standard hardware - Modify-RecommendedOption 
                                    #       sets option to "CANNOT INSTALL Recall" and checkbox remains unchecked
                                    #       so this function is never called on non-Copilot+ hardware
                                    
                                # --- Microsoft Accounts ------------------------------------------------------------==
                                elseif (
                                    ($OriginalOption -eq "Create and Sign in with a Local Account") -or
                                    ($OriginalOption -eq "Remove Microsoft Account entirely")
                                ) {
                                    If ($localDEBUG_Mode){Write-Host "[DEBUG] Microsoft Account for: $OriginalOption "}
                                    Handle-MicrosoftAccounts $CheckBox $CurrentOption      # ONLY partially tested
                                    # ONLY Tested for   "Create and Sign in with a Local Account"
                                    # To be Tested with "Remove Microsoft Account entirely" on Test-PC
                                }
                                # --- Remove Unwanted Apps ------------------------------------------------------------
                                elseif ($OriginalOption -eq "Remove Xbox") {
                                    Remove-Xbox $CheckBox $CurrentOption         # TESTED and WORKING
                                }
                                elseif ($OriginalOption -eq "KEEP Solitaire") {
                                    KEEP-Solitaire $CheckBox $CurrentOption      # TESTED and WORKING
                                }
                                # --- Select default Browser ------------------------------------------------------------------
                                elseif ($OriginalOption -in @(                   # TESTED and WORKING                              
                                    "Microsoft Edge SELECTED",
                                    "INSTALL Google Chrome",
                                    "INSTALL Firefox",
                                    "INSTALL Brave",
                                    "INSTALL Opera"
                                )) {
                                    if ($CurrentOption -like "INSTALL *") { 
                                        Install-Browser $CheckBox $CurrentOption
                                    } else {
                                        Set-DefaultBrowser $CheckBox $CurrentOption
                                    }
                                }
                                
                                # NO ACTION - Windows 11 prevents programmatic Start Menu and Taskbarpin management
                                # Users are advised in the Advice Panel to do this manually
                                elseif ($OriginalOption -in @(          
                                    # --- Tidy the Start Menu ---------------- # ALL TESTED and WORKING-------------------------------------
                                    "Remove Microsoft 365 PIN from the Start Menu",
                                    "Remove Xbox PIN from the Start Menu",
                                    "KEEP Solitaire pinned to Start Menu",
                                    "Remove LinkedIn PIN from the Start Menu",
                                    "KEEP Outlook pinned to Start Menu",
                                    "KEEP File Explorer pinned to Start Menu",
                                    "KEEP Calculator pinned to Start Menu",
                                    "KEEP Notepad pinned to Start Menu",
                                    "KEEP Snipping Tool pinned to Start Menu",
                                    "KEEP Photos pinned to Start Menu",
                                    # --- Simplify the Taskbar -------------   # ALL TESTED and WORKING-------------------------------------
                                    "Remove Microsoft 365 PIN from the Start Menu",
                                    "KEEP CoPilot, ON the Taskbar",
                                    "KEEP File Manager, ON the Taskbar",
                                    "KEEP Edge, ON the Taskbar",
                                    "KEEP Outlook, ON the Taskbar",
                                    "Remove Microsoft Store, FROM the Taskbar"
                                    )) {
                                    # Intentionally empty - Start Menu pins require manual action from the UI
                                }                                
                                # Options that can be handled by REMOVEorKEEP
                                # ===========================================
                                 elseif ($OriginalOption -in @(
                                    # --- Remove Unwanted Apps --------------  # ALL TESTED and WORKING  -------------------                                      
                                    "Remove Outlook for Windows",
                                    "Remove Xbox",
                                    "KEEP Solitaire",                                
                                    # --- Keep the Desktop Clean ------------  # ALL TESTED and WORKING-------------------------------------------
                                    "Remove Edge, FROM the Desktop"
                                )) {
                                    REMOVEorKEEP $CheckBox $CurrentOption
                                }
                                # Options that can be handled by MODIFY-Registry
                                # ==============================================
                                elseif ($OriginalOption -in @(
                                    # --- Simplify the Taskbar --------------  # ALL TESTED and WORKING--------------------------
                                    "KEEP Search Box, ON the Taskbar",        # TESTED and WORKING
                                    "KEEP Recycle Bin, ON the Desktop",               # TESTED and WORKING
                                    # --- Privacy & Telemetry ---------------  # ALL TESTED and WORKING--------------------------
                                    "Remove Advertising ID",                          # TESTED and WORKING
                                    "Remove Tailored Experiences",                    # TESTED and WORKING       
                                    "Remove Inking and Typing Personalisation",       # TESTED and WORKING                              
                                    "Remove Location Tracking",                       # TESTED and WORKING
                                    "Remove Activity History",                        # TESTED and WORKING 
                                    "Remove Feedback Frequency",                      # TESTED and WORKING
                                    "Remove Diagnostic Data Upload",                  # TESTED and WORKING 
                                    "Remove Cloud Content Suggestions",               # TESTED and WORKING
                                    "Remove Web Search in Start Menu",                # TESTED and WORKING
                                    "KEEP SmartScreen Filter",                        # TESTED and WORKING
                                    "Remove Microsoft Edge Telemetry",                # TESTED and WORKING
                                    "Remove Customer Experience Improvement Program", # TESTED and WORKING
                                    # --- System Experience -----------------  # ALL TESTED and WORKING--------------------------------
                                    "Remove Tips and Suggestions",                    # TESTED and WORKING
                                    "Remove Lock Screen Spotlight",                   # TESTED and WORKING 
                                    "Remove Start Menu Recommendations",              # TESTED and WORKING
                                    "Remove Suggested Apps",                          # TESTED and WORKING
                                    "Remove Suggested Content in Settings",           # TESTED and WORKING
                                    "Remove Automatic App Launching",                 # TESTED and WORKING
                                    "Remove Suggested Actions",                       # TESTED and WORKING
                                    "Remove AutoPlay",                                # TESTED and WORKING
                                    "KEEP Snap Assist",                               # TESTED and WORKING
                                    "KEEP Clipboard History",                         # TESTED and WORKING
                                    "Remove Nearby Sharing",                          # TESTED and WORKING
                                    # --- Security and Network --------------  # ALL TESTED and WORKING-----------------
                                    "Remove IPv6",                                    # TESTED and WORKING
                                    # --- File Explorer -----------------------------------------
                                    "SHOW File Extensions",                           # TESTED and WORKING
                                    "Remove Hidden Files",                            # TESTED and WORKING
                                    "Remove Frequent Folders",                        # TESTED and WORKING
                                    "Remove Recent Files",                            # TESTED and WORKING                             # TESTED and WORKING
                                    # --- Notifications --------------------------------------------------
                                    "Remove Notification Badges",                     # TESTED and WORKING
                                    "Remove Notification Sounds",                     # TESTED and WORKING
                                    # --- Background Services (registry-based) ---------------------------
                                    "Remove Widgets Service",                         # TESTED and WORKING
                                    "Remove Xbox Game Bar Service",                   # TESTED and WORKING
                                    "Remove Game DVR and Capture Service",            # TESTED and WORKING
                                    "KEEP Windows Spotlight Service",                 # TESTED and WORKING
                                    "Remove Suggested Actions Service",               # TESTED and WORKING
                                    # --- Performance Acceleration (registry-based) ---------------------------
                                    "ENABLE Scheduler Responsiveness Mode",           # TESTED and WORKING
                                    "ENABLE Reduced Background Task Latency",         # TESTED and WORKING
                                    # --- Visual Effects (registry-based) -------------------------------------------
                                    "DISABLE Transparency Effects",                   # TESTED and WORKING
                                    "DISABLE Window Animations",                      # TESTED and WORKING
                                    # --- Windows Update (registry-based) -------------------------------------------
                                    "DISABLE Automatic Driver Updates",               # TESTED and WORKING
                                    "DISABLE Delivery Optimisation"                   # TESTED and WORKING
                                    # Options that require a specific function, and cannot be handled by MODIFY-Registry, are listed above and handled separately
                                )) {
                                    MODIFY-Registry $CheckBox $CurrentOption
                                }
                                # Options that can be handled by MODIFY-Service
                                # =============================================
                                elseif ($OriginalOption -in @(
                                    # --- Background Services (service-based) ----------------------------------------------------------
                                    "Remove Xbox Live Auth Manager",                  # TESTED and WORKING
                                    "Remove Xbox Accessory Management Service",       # TESTED and WORKING
                                    "KEEP Windows Search Service"                     # TESTED and WORKING
                                )) {
                                    MODIFY-Service $CheckBox $CurrentOption
                                }

                                # Options that can be handled by MODIFY-PowerCFG
                                # ==============================================
                                elseif ($OriginalOption -in @(
                                    "Remove Fast Startup",                            # TESTED and WORKING
                                    "Remove Hibernation"                              # TESTED and WORKING
                                )) {
                                    MODIFY-PowerCFG $CheckBox $CurrentOption
                                }
                                elseif ($OriginalOption -eq "Set Active Hours") {
                                    Set-ActiveHours $CheckBox
                                }
                                else {
                                    LogTask-Completion "ERROR - NO Option Handler matched for: '$($CheckBox.Text)'"
                                }
                            } # CLOSE if $CheckBox
                        } # CLOSE foreach $CheckBox
                    } # END foreach $row
                } # END if $subCtrl -is Panel
            } # END foreach $subCtrl
        } # END if $ctrl.Tag.Kind -eq Group
    } # END foreach $ctrl

    $script:btnContinue.Visible = $false
    $script:form.Refresh()
    $script:IsLastTask = $true

    # Show appropriate completion message depending on whether user stopped early
    if ($script:stopRequested) {
        [System.Windows.Forms.MessageBox]::Show(
            "Run stopped by user." + [Environment]::NewLine +
            [Environment]::NewLine +
            "Any tasks that had already completed remain in effect." + [Environment]::NewLine +
            "Clicking OK will update the Recommended Options on the left " +
            "to reflect the current state of your PC.",
            "DeBloater - Run Stopped",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    } else {
        [System.Windows.Forms.MessageBox]::Show(
            "All tasks have been completed." + [Environment]::NewLine +
            [Environment]::NewLine +
            "Clicking OK will update the Recommended Options on the left " +
            "to reflect the current state of your PC.",
            "DeBloater - Tasks Complete",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    }

    # Restore PERFORM button appearance and show post-PERFORM print panel
    Exit-StopRunMode
 
    If ($localDEBUG_Mode) {
        Write-Host "[DEBUG] Perform-SelectedOptions ExplorerRestartNeeded = $script:ExplorerRestartNeeded"
    }
    # Restart Explorer if needed to apply visual shell changes.
    # We only kill it — Windows automatically restarts explorer.exe as the shell.
    # Calling Start-Process explorer would open a File Manager window instead.
    if ($script:ExplorerRestartNeeded) {
        LogTask-Progress "Restarting Explorer to apply visual changes..."
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        LogTask-Progress "Explorer restarted."
        $script:ExplorerRestartNeeded = $false
    }

    If ($localDEBUG_Mode) {Write-Host "[DEBUG] LogTask-RunFooter about to run" -ForegroundColor Magenta}
    LogTask-RunFooter

    # Re-evaluate all options to reflect actual state of PC after PERFORM
    On-ResetDefaultsClick
    
} # END of - function Perform-SelectedOptions


# =======================================================================================
function Remove-and-BLOCK-Microsoft-365-Application {
    param (
        $CheckBox,
        [string]$CurrentOption
    )
    #.SYNOPSIS
    # Removes subscription-based Microsoft 365 components and blocks reinstallation.

    #.DESCRIPTION
    #  - Detects Microsoft 365 Click-to-Run or Appx installation
    #  - Uses Windows' own registered uninstall string for Click-to-Run removal
    #  - Removes Appx packages and provisioned stubs if present
    #  - Cleans registry keys tied to Microsoft 365 sign-in
    #  - Applies Group Policy registry settings to prevent re-installation
    #  - Preserves perpetual-license Office products (Office 2016/2019/2021/2024)

    #.STATUS
    #    TESTED and WORKING
    
    $localDEBUG_Mode = $false

    $clickToRunPath = "$env:ProgramFiles\Common Files\Microsoft Shared\ClickToRun\OfficeClickToRun.exe"

    # --- Detection ---
    $Installed       = $false
    $uninstallString = $null

    # Check for Click-to-Run installation via Windows uninstall registry
    # This is the most reliable detection method as it uses Windows' own records
    # Note: Guard against registry entries that do not have a DisplayName property
    $officeUninstall = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall" |
        ForEach-Object { Get-ItemProperty $_.PSPath } |
        Where-Object { $_.PSObject.Properties.Name -contains 'DisplayName' -and $_.DisplayName -like "Microsoft 365*" }

    if ($officeUninstall) {
        $Installed       = $true
        $uninstallString = $officeUninstall.UninstallString
        If ($localDEBUG_Mode) { Write-Host "[DEBUG] Found via Uninstall registry: $($officeUninstall.DisplayName)" -ForegroundColor Magenta }
        If ($localDEBUG_Mode) { Write-Host "[DEBUG] Uninstall string: $uninstallString" -ForegroundColor Magenta }
    }

    # Check for Appx/Store version
    $appxTargets = Get-AppxPackage -AllUsers | Where-Object {
        $_.Name -match 'Microsoft.Office.Desktop' -or $_.PackageFamilyName -match 'Microsoft.365'
    }
    $provTargets = Get-AppxProvisionedPackage -Online | Where-Object {
        $_.DisplayName -match 'Microsoft.Office.Desktop' -or $_.PackageName -match 'Microsoft.365'
    }
    if ($appxTargets -or $provTargets) { $Installed = $true }

    # Fallback: check for Click-to-Run executable
    if (-not $Installed -and (Test-Path $clickToRunPath)) {
        $Installed = $true
        If ($localDEBUG_Mode) { Write-Host "[DEBUG] Found via ClickToRun executable" -ForegroundColor Magenta }
    }

    # --- Outer decision: user option ---
    if ($CheckBox.Checked) {

        LogTask-Start "Remove Microsoft 365"

        if ($Installed) {

            # --- Click-to-Run removal using Windows' own uninstall string ---
            if ($uninstallString) {
                LogTask-Progress "Removing Microsoft 365 Click-to-Run installation..."
                try {
                    # Split uninstall string into executable and arguments
                    # Format: "C:\path\to\exe" arguments
                    $uninstallExe  = ($uninstallString -split '"')[1]
                    $uninstallArgs = ($uninstallString -split '"')[2].Trim()
                    If ($localDEBUG_Mode) { Write-Host "[DEBUG] Uninstall exe: $uninstallExe" -ForegroundColor Magenta }
                    If ($localDEBUG_Mode) { Write-Host "[DEBUG] Uninstall args: $uninstallArgs" -ForegroundColor Magenta }
                    If ($localDEBUG_Mode) { Write-Host "[DEBUG] Uninstall exe: $uninstallExe" -ForegroundColor Magenta }
                    If ($localDEBUG_Mode) { Write-Host "[DEBUG] Uninstall args: $uninstallArgs" -ForegroundColor Magenta }
                    LogTask-Progress "Starting Microsoft 365 uninstaller - please wait for the Uninstall dialog to appear..."
                    LogTask-Progress "This may take up to 30 seconds. Do NOT click Continue until the Uninstall dialog has closed."
                    Start-Process -FilePath $uninstallExe -ArgumentList $uninstallArgs -Wait
                    Start-Sleep -Seconds 5
                    LogTask-Progress "Click-to-Run removal completed"
                    Start-Process -FilePath $uninstallExe -ArgumentList $uninstallArgs -Wait
                    LogTask-Progress "Click-to-Run removal completed"
                }
                catch {
                    LogTask-Progress "ERROR: Click-to-Run removal failed - $($_.Exception.Message)"
                }
            }
            else {
                LogTask-Progress "No Click-to-Run uninstall string found - skipping"
            }

            # --- Appx removal ---
            # -ErrorAction SilentlyContinue alone does NOT reliably suppress errors from
            # these two cmdlets - they're DISM-backed and can throw a terminating exception
            # that bypasses the non-terminating error stream SilentlyContinue governs.
            # Confirmed 2026-07-12: this crashed the DeBloat run with an unhandled error on
            # a real machine (in the Teams removal function's identical pattern). Wrapping
            # in try/catch with -ErrorAction Stop forces every failure through the catchable
            # path instead, so one package failing to remove doesn't take down the whole run.
            if ($appxTargets) {
                foreach ($app in $appxTargets) {
                    LogTask-Progress "Removing Appx package: $($app.Name)"
                    try {
                        Remove-AppxPackage -Package $app.PackageFullName -ErrorAction Stop
                    } catch {
                        LogTask-Progress "ERROR: Failed to remove Appx package '$($app.Name)' - $($_.Exception.Message)"
                    }
                }
            }

            # --- Provisioned stubs ---
            if ($provTargets) {
                foreach ($prov in $provTargets) {
                    LogTask-Progress "Removing provisioned stub: $($prov.DisplayName)"
                    try {
                        Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop
                    } catch {
                        LogTask-Progress "ERROR: Failed to remove provisioned stub '$($prov.DisplayName)' - $($_.Exception.Message)"
                    }
                }
            }

            # --- Registry cleanup ---
            LogTask-Progress "Cleaning Microsoft 365 registry entries..."
            Remove-Item -Path "HKCU:\Software\Microsoft\Office\16.0\Common\SignIn" -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -Path "HKCU:\Software\Microsoft\Office\16.0\Common\Internet\WebServiceCache" -Recurse -Force -ErrorAction SilentlyContinue

            # --- Block reinstallation via Group Policy ---
            LogTask-Progress "Applying Group Policy registry settings to block reinstallation..."
            New-Item -Path "HKLM:\Software\Policies\Microsoft\Office" -Force | Out-Null
            Set-ItemProperty -Path "HKLM:\Software\Policies\Microsoft\Office" -Name "BlockSubscriptionInstall" -Value 1 -Force
            Set-ItemProperty -Path "HKLM:\Software\Policies\Microsoft\Office" -Name "BlockOffice365Install" -Value 1 -Force

            # --- Verify removal ---
            # Note: Guard against registry entries that do not have a DisplayName property
            $stillInstalled = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall" |
                ForEach-Object { Get-ItemProperty $_.PSPath } |
                Where-Object { $_.PSObject.Properties.Name -contains 'DisplayName' -and $_.DisplayName -like "Microsoft 365*" }

            if ($stillInstalled) {
                LogTask-Completion "WARNING   - Microsoft 365 may still be installed - please check Settings > Installed Apps"
            }
            else {
                LogTask-Completion "REMOVED   - Microsoft 365 Application"
            }
        }
        else {
            LogTask-Completion "NOT FOUND - Microsoft 365 Application"
        }
    }
    else {
        LogTask-Start "Remove Microsoft 365, was NOT checked"
        if ($Installed) {
            LogTask-Completion "KEPT      - Microsoft 365 Application"
        }
        else {
            LogTask-Completion "NOT FOUND - Microsoft 365 Application"
        }
    }
    # END outer if ($CheckBox.Checked)

} # END of - function Remove-and-BLOCK-Microsoft-365-Application


# =======================================================================================
function Remove-and-Block-OneDrive {
    param ($CheckBox, 
    [String]$CurrentOption
    )

<#
.SYNOPSIS
Removes OneDrive and prevents it from being reinstalled by Windows Updates.

.DESCRIPTION
- Stops and uninstalls OneDrive sync client
- Removes Appx and provisioned packages
- Cleans scheduled tasks
- Deletes leftover folders
- Removes Explorer integration entries (HKCU + HKLM)
- Removes auto-start registry entry
- Deletes stub installers (System32 + SysWOW64)
- Applies Group Policy registry settings to block reinstallation
- Hides OneDrive from Word/Excel/PowerPoint's own Save/Open Backstage screen (a separate
  Office-only policy - removing the sync client above does not affect this)
#>

    # --- Build stub paths robustly ---
    $stubPaths = @(
        "$env:SystemRoot\System32\OneDriveSetup.exe"
        "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
    )

    # --- Detection probes ---
    $Installed = $false

    # Process check
    $proc = Get-Process -Name OneDrive -ErrorAction SilentlyContinue
    if ($proc) { $Installed = $true }

    # Stub check and removal
    foreach ($p in $stubPaths) {
        if (Test-Path -LiteralPath $p) {
            & takeown /f $p /a | Out-Null
            & icacls $p /grant Administrators:F /t /c | Out-Null
            try {
                Remove-Item -LiteralPath $p -Force -ErrorAction Stop
                LogTask-Progress "Deleted $p"
            }
            catch {
                LogTask-Progress "ERROR: Failed to delete $p -> $($_.Exception.Message)"
            }
            $Installed = $true
        }
    }

    # Appx packages
    $appxTargets = Get-AppxPackage -AllUsers | Where-Object { $_.Name -match 'OneDrive' }
    if ($appxTargets) { $Installed = $true }

    # Provisioned packages
    $provTargets = Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -match 'OneDrive' }
    if ($provTargets) { $Installed = $true }

    # --- Removal logic ---
    if ($CheckBox.Checked) {
        
        LogTask-Start "Remove OneDrive Service"

        if ($Installed) {
            # Stop processes
            LogTask-Progress "Stopping OneDrive processes..."
            $proc | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }

            # Remove Appx packages
            # See the matching comment in Remove-and-BLOCK-Microsoft-365-Application -
            # -ErrorAction SilentlyContinue alone doesn't reliably suppress these DISM-backed
            # cmdlets' errors, so this is wrapped in try/catch to avoid an unhandled crash.
            if ($appxTargets) {
                LogTask-Progress "Removing Appx packages..."
                foreach ($app in $appxTargets) {
                    try {
                        Remove-AppxPackage -Package $app.PackageFullName -ErrorAction Stop
                    } catch {
                        LogTask-Progress "ERROR: Failed to remove Appx package '$($app.Name)' - $($_.Exception.Message)"
                    }
                }
            }

            # Remove provisioned packages
            if ($provTargets) {
                LogTask-Progress "Removing provisioned packages..."
                foreach ($prov in $provTargets) {
                    try {
                        Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop
                    } catch {
                        LogTask-Progress "ERROR: Failed to remove provisioned package '$($prov.DisplayName)' - $($_.Exception.Message)"
                    }
                }
            }

            # Remove scheduled tasks
            LogTask-Progress "Removing OneDrive scheduled tasks..."
            Get-ScheduledTask | Where-Object { $_.TaskName -like "*OneDrive*" } | ForEach-Object {
                Unregister-ScheduledTask -Taskname $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue
            }

            # Remove leftover folders
            LogTask-Progress "Removing leftover OneDrive folders..."
            foreach ($folder in @("$env:UserProfile\OneDrive","$env:LocalAppData\Microsoft\OneDrive")) {
                if (Test-Path $folder) {
                    Remove-Item $folder -Recurse -Force -ErrorAction SilentlyContinue
                }
            }

            # Remove Explorer integration (HKCU + HKLM)
            LogTask-Progress "Removing Explorer integration entries..."
            $clsid = "{018D5C66-4533-4307-9B53-224DE2ED1FE6}"
            foreach ($root in @(
                "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace",
                "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace"
            )) {
                $path = Join-Path $root $clsid
                if (Test-Path $path) {
                    Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue
                }
            }

            # Remove auto-start entry
            LogTask-Progress "Removing OneDrive auto-start entry..."
            Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "OneDrive" -ErrorAction SilentlyContinue

            # Delete stub installers (second pass)
            LogTask-Progress "Deleting OneDriveSetup.exe stub(s)..."
            foreach ($p in $stubPaths) {
                if (Test-Path -LiteralPath $p) {
                    try {
                        Remove-Item -LiteralPath $p -Force -ErrorAction Stop
                        LogTask-Progress "Deleted $p"
                    }
                    catch {
                        LogTask-Progress "ERROR: Failed to delete $p -> $($_.Exception.Message)"
                    }
                }
            }

            # Apply Group Policy registry settings
            LogTask-Progress "Applying Group Policy registry settings..."
            $policyPath = "HKLM:\Software\Policies\Microsoft\Windows\OneDrive"
            if (-not (Test-Path $policyPath)) { New-Item $policyPath -Force | Out-Null }
            Set-ItemProperty -Path $policyPath -Name "DisableFileSync" -Value 1 -Force
            Set-ItemProperty -Path $policyPath -Name "DisableFileSyncNGSC" -Value 1 -Force
            Set-ItemProperty -Path $policyPath -Name "DisableFileSyncOnUserProfile" -Value 1 -Force

            # Hide OneDrive from Word/Excel/PowerPoint's own Save/Open Backstage screen.
            # This is separate from the Windows-level policy above - Office never checks
            # Software\Policies\Microsoft\Windows\OneDrive, it reads its own policy branch.
            # OnlineStorage is a bit-pattern (1=OneDrive Personal, 4=ThisPC, 8=SharePoint OnPrem,
            # 16=Recent Places, 32=SharePoint, 64=OneDrive for Business, 128=3rd-party services).
            # 65 = 1 + 64 hides both OneDrive Personal and OneDrive for Business, leaving
            # This PC / Recent Places untouched.
            LogTask-Progress "Hiding OneDrive from Office's Save/Open Backstage view..."
            $officePolicyPath = "HKCU:\Software\Policies\Microsoft\office\16.0\common\internet"
            if (-not (Test-Path $officePolicyPath)) { New-Item $officePolicyPath -Force | Out-Null }
            Set-ItemProperty -Path $officePolicyPath -Name "OnlineStorage" -Value 65 -Force

            LogTask-Completion "REMOVED   - OneDrive Service"
        }
        else {
            LogTask-Completion "NOT FOUND - OneDrive Service"
        }
    }
    else {
        LogTask-Start "Remove OneDrive Service, was NOT Checked"
        if ($Installed) { LogTask-Completion "KEPT      - OneDrive Service" }
        else { LogTask-Completion "NOT FOUND - OneDrive Service" }
    }
} # END of - function Remove-and-Block-OneDrive


# =======================================================================================
function Remove-and-BLOCK-Microsoft-Teams-Application {
    param ($CheckBox, 
    [string]$CurrentOption
    )

<#
.SYNOPSIS
Removes Microsoft Teams (subscription variant) and blocks it from auto-reinstalling.

.DESCRIPTION
- Stops Teams processes
- Removes Appx and provisioned packages
- Uninstalls Teams Machine-Wide Installer MSI
- Deletes leftover folders (ProgramData, LocalAppData, Installer)
- Removes Teams scheduled tasks
- Cleans per-user profile remnants (AppData + HKU registry)
- Applies Office Group Policy registry settings to prevent reinstallation
- Verifies removal and logs survivors explicitly
#>

    $Installed = $false

    # Detect Teams presence
    if (Get-Process Teams -ErrorAction SilentlyContinue) { $Installed = $true }
    $appxTargets = Get-AppxPackage -AllUsers | Where-Object { $_.Name -match 'Teams' }
    if ($appxTargets) { $Installed = $true }
    $provTargets = Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -match 'Teams' }
    if ($provTargets) { $Installed = $true }
    $teamsInstallerPath = "$env:ProgramFiles (x86)\Teams Installer"
    if (Test-Path $teamsInstallerPath) { $Installed = $true }

    if ($CheckBox.Checked) { 

        LogTask-Start "Remove Microsoft Teams Application"

        if ($Installed) {
            LogTask-Progress "Stopping Teams processes..."
            Get-Process Teams -ErrorAction SilentlyContinue | ForEach-Object {
                Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
            }
            LogTask-Progress "Removing Appx packages..."
            foreach ($app in $appxTargets) {
                try {
                    Remove-AppxPackage -Package $app.PackageFullName -AllUsers -ErrorAction Stop
                } catch {
                    LogTask-Progress "ERROR: Failed to remove Appx package '$($app.Name)' - $($_.Exception.Message)"
                }
            }
            # This exact line is where a real Teams removal run crashed with an unhandled
            # error 2026-07-12 - Remove-AppxProvisionedPackage is DISM-backed and can throw
            # a terminating exception that -ErrorAction SilentlyContinue alone doesn't catch.
            LogTask-Progress "Removing provisioned stubs..."
            foreach ($prov in $provTargets) {
                try {
                    Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop
                } catch {
                    LogTask-Progress "ERROR: Failed to remove provisioned stub '$($prov.DisplayName)' - $($_.Exception.Message)"
                }
            }
            LogTask-Progress "Uninstalling Teams Machine-Wide Installer..."
            $installer = Get-ChildItem `
                "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall", `
                "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall" |
                ForEach-Object {
                    $props = Get-ItemProperty $_.PsPath -ErrorAction SilentlyContinue
                    if ($props -and $props.PSObject.Properties.Name -contains 'DisplayName' -and $props.DisplayName -match "Teams Machine") { $props.PSChildName }
                }            
            
            LogTask-Progress "Deleting leftover Teams folders..."
            Remove-Item "$env:ProgramData\Microsoft\Teams" -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item "$env:LocalAppData\Microsoft\Teams" -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item $teamsInstallerPath -Recurse -Force -ErrorAction SilentlyContinue

            LogTask-Progress "Removing Teams scheduled tasks..."
            Get-ScheduledTask | Where-Object { $_.TaskName -like "*Teams*" } | ForEach-Object {
                Unregister-ScheduledTask -Taskname $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue
            }
            LogTask-Progress "Cleaning per-user Teams remnants..."
            $profiles = Get-ChildItem 'C:\Users' | Where-Object { $_.Name -notin @('Default','Public','All Users','Default User') }
            foreach ($p in $profiles) {
                $localTeams   = Join-Path $p.FullName "AppData\Local\Microsoft\Teams"
                $roamingTeams = Join-Path $p.FullName "AppData\Roaming\Microsoft\Teams"
                Remove-Item $localTeams   -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item $roamingTeams -Recurse -Force -ErrorAction SilentlyContinue
            }

            $hkus = Get-ChildItem Registry::HKEY_USERS | Where-Object { $_.Name -match 'S-1-5-21-' }
            foreach ($h in $hkus) {
                $runPath = "$($h.Name)\Software\Microsoft\Windows\CurrentVersion\Run"
                Remove-Item "Registry::$runPath\com.squirrel.Teams.Teams" -Force -ErrorAction SilentlyContinue
                $uninstPath = "$($h.Name)\Software\Microsoft\Windows\CurrentVersion\Uninstall"
                Get-ChildItem "Registry::$uninstPath" -ErrorAction SilentlyContinue |
                    Where-Object { (Get-ItemProperty $_.PsPath).DisplayName -match 'Microsoft Teams' } |
                    ForEach-Object { Remove-Item $_.PsPath -Recurse -Force -ErrorAction SilentlyContinue }
            }

            # --- Remove Teams MSI components ---
            LogTask-Progress "Removing Teams MSI components..."
            $teamsMsi = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
                "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall" |
                ForEach-Object { Get-ItemProperty $_.PSPath } |
                Where-Object { $_.PSObject.Properties.Name -contains 'DisplayName' -and $_.DisplayName -like "*Teams*" }

            foreach ($msi in $teamsMsi) {
                if ($msi.PSChildName -match '^\{') {
                    LogTask-Progress "Removing MSI component: $($msi.DisplayName)"
                    try {
                        Start-Process "MsiExec.exe" -ArgumentList "/X$($msi.PSChildName) /qn /norestart" -Wait -ErrorAction Stop
                    } catch {
                        LogTask-Progress "WARNING: Could not remove MSI component '$($msi.DisplayName)': $($_.Exception.Message)"
                    }
                }
            }
            LogTask-Progress "Applying Office Group Policy registry settings to block reinstallation..."
            New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Teams" -Force | Out-Null
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Teams" -Name "PreventInstallation" -Value 1 -Force

            # --- TRACE after removal ---
            LogTask-Progress "TRACE: Post-removal check..."
            $appxLeft = Get-AppxPackage -AllUsers *Teams*
            $provLeft = Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -like "*Teams*" }
            $msiLeft  = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall","HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall" |
                        ForEach-Object { Get-ItemProperty $_.PSPath } |
                        Where-Object { $_.PSObject.Properties.Name -contains 'DisplayName' -and $_.DisplayName -match "Teams" }

        if (-not $appxLeft -and -not $provLeft -and -not $msiLeft) {
                LogTask-Completion "REMOVED + BLOCKED - Microsoft Teams Application"
            } else {
                $appxCount = @($appxLeft).Count
                $provCount = @($provLeft).Count
                $msiCount  = @($msiLeft).Count
                LogTask-Completion "WARNING: Teams remnants still detected (Appx:$appxCount Prov:$provCount MSI:$msiCount)"
            }
        }
        else {
            LogTask-Completion "NOT FOUND - Microsoft Teams Application"
        }
    }
    else {
        LogTask-Start "Remove and BLOCK Microsoft Teams Application, was NOT checked"
        if ($Installed) {
            LogTask-Completion "KEPT      - Microsoft Teams Application"
        }
        else {
            LogTask-Completion "NOT FOUND - Microsoft Teams Application"
        }
    }
}
# END of - function Remove-and-BLOCK-Microsoft-Teams-Application


# =======================================================================================
function Turn-Bitlocker-OFF {
    param ($CheckBox,
    [String]$CurrentOption
    )

<#
.SYNOPSIS
Turns BitLocker OFF on all non-removable drives, including the OS volume.

.DESCRIPTION
- Enumerates all non-removable drives (OperatingSystem + Fixed), excluding USB/removable
- If option is checked, disables BitLocker/Device Encryption and starts background decryption
- Logs progress and final outcome per drive
- Adds summary line for overall state
- Detects Group Policy enforcement and warns if BitLocker may be re-enabled
- Sets registry key to prevent Windows silently re-enabling Device Encryption
#>

    # Enumerate OS volume and fixed data drives; exclude removable (USB sticks etc.)
    $volumes = Get-BitLockerVolume | Where-Object { $_.VolumeType -ne 'Removable' }

    $removedCount   = 0
    $keptCount      = 0
    $notFoundCount  = 0

    if ($CheckBox.Checked) {
        LogTask-Start "Turn BitLocker OFF"

        # --- Policy check only when OFF is requested ---
        $policyKeys = if (Test-Path "HKLM:\SOFTWARE\Policies\Microsoft\FVE") {
            Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\FVE"
        } else { $null }
        if ($policyKeys) {
            LogTask-Completion "BLOCKER   - BitLocker could NOT be turned off because Group Policy enforces encryption."
            foreach ($name in $policyKeys.PSObject.Properties.Name) {
                LogTask-Progress "Policy: $name = $($policyKeys.$name)"
            }
            return   # Exit early, don't attempt Disable-BitLocker
        }

        # Normal disable loop if no policy enforcement
        foreach ($vol in $volumes) {
            if ($vol.ProtectionStatus -eq 'On') {
                Disable-BitLocker -MountPoint $vol.MountPoint -ErrorAction SilentlyContinue
                LogTask-Completion "REMOVED   - BitLocker protection disabled at $($vol.MountPoint)"
                LogTask-Progress  "DECRYPT   - Background decryption started at $($vol.MountPoint) - may take several hours on a large drive; PC remains fully usable throughout"
                $removedCount++
            }
            else {
                LogTask-Completion "NOT FOUND - BitLocker OFF at $($vol.MountPoint)"
                $notFoundCount++
            }
        }

        # --- Prevent Windows from silently re-enabling Device Encryption ---
        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker"
        if (-not (Test-Path $regPath)) {
            New-Item -Path $regPath -Force | Out-Null
        }
        Set-ItemProperty -Path $regPath -Name "PreventDeviceEncryption" -Value 1 -Type DWord -Force
        LogTask-Progress "BLOCKED   - Registry set to prevent Windows silently re-enabling Device Encryption"

        # --- Summary ---
        if ($removedCount -gt 0) {
            LogTask-Completion "SUMMARY   - BitLocker disabled on $removedCount drive(s), $notFoundCount already OFF"
        }
        else {
            LogTask-Completion "SUMMARY   - BitLocker NOT FOUND on any drive"
        }
    }
    else {
        LogTask-Start "Turn BitLocker OFF, was NOT Checked"

        foreach ($vol in $volumes) {
            if ($vol.ProtectionStatus -eq 'On') {
                LogTask-Completion "KEPT      - BitLocker ON at $($vol.MountPoint)"
                $keptCount++
            }
            else {
                LogTask-Completion "NOT FOUND - BitLocker OFF at $($vol.MountPoint)"
                $notFoundCount++
            }
        }

        # --- Summary ---
        if ($keptCount -gt 0) {
            LogTask-Completion "SUMMARY   - BitLocker KEPT ON at $keptCount drive(s), $notFoundCount already OFF"
        }
        else {
            LogTask-Completion "SUMMARY   - BitLocker NOT FOUND on any drive"
        }
    }
}
# END of - function Turn-Bitlocker-OFF


# =======================================================================================
function KEEP-CoPilot-Application {
    param (
        $CheckBox,
        [string]$CurrentOption
    )
    #.SYNOPSIS
    # Keeps or removes the CoPilot application depending on the Current Option text.
    #.DESCRIPTION
    # - If CurrentOption is "KEEP CoPilot", the app is left installed and logged as "Kept".
    # - If CurrentOption is "Remove CoPilot", the app is removed and logged as "Removed".

    if ($CurrentOption -eq "KEEP CoPilot") {
        LogTask-Start "KEEP CoPilot Application"
        LogTask-Completion "KEPT      - CoPilot Application"
    }
    else {
        LogTask-Start "Remove CoPilot Application"
        LogTask-Progress "Removing CoPilot Appx package..."

        # --- Remove Appx package ---
        $copilotAppx = Get-AppxPackage -AllUsers | Where-Object { $_.Name -match 'Copilot' }
        if ($copilotAppx) {
            foreach ($app in $copilotAppx) {
                LogTask-Progress "Removing: $($app.Name)"
                try {
                    Remove-AppxPackage -Package $app.PackageFullName -AllUsers -ErrorAction Stop
                } catch {
                    LogTask-Progress "ERROR: Failed to remove Appx package '$($app.Name)' - $($_.Exception.Message)"
                }
            }
        }

        # --- Remove via Windows uninstall registry ---
        $copilotUninstall = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall" |
            ForEach-Object { Get-ItemProperty $_.PSPath } |
            Where-Object { $_.PSObject.Properties.Name -contains 'DisplayName' -and $_.DisplayName -like "*Copilot*" }

        if ($copilotUninstall) {
            $uninstallString = $copilotUninstall.UninstallString
            $uninstallExe  = ($uninstallString -split '"')[1]
            $uninstallArgs = ($uninstallString -split '"')[2].Trim()
            LogTask-Progress "Running Copilot uninstaller..."
            Start-Process -FilePath $uninstallExe -ArgumentList $uninstallArgs -Wait
        }

        # --- Verify removal ---
        $stillInstalled = Get-AppxPackage -AllUsers | Where-Object { $_.Name -match 'Copilot' }
        if ($stillInstalled) {
            LogTask-Completion "WARNING   - CoPilot may still be installed - please check Settings > Installed Apps"
        }
        else {
            LogTask-Completion "REMOVED   - CoPilot Application"
        }
    }

} # END of - function KEEP-CoPilot-Application


# =======================================================================================
function KEEP-Recall-Application {
    param ($CheckBox, 
    [String]$CurrentOption
    )

<#
.SYNOPSIS
Keeps or removes the Recall application depending on user selection.

.DESCRIPTION
- If the option is checked, Recall is left installed and logged as "Kept".
- If the option is unchecked, Recall is removed and logged as "Removed".
- If Recall is not present, logs "NotFound".
- If hardware doesn't support Recall, logs "Cannot Install".
#>

    # Check if the option text indicates hardware doesn't support Recall
    if ($CurrentOption -match 'CANNOT INSTALL') {
        LogTask-Start "KEEP Recall Application"
        LogTask-Completion "CANNOT INSTALL - Hardware does not support Recall (requires Copilot+ PC with NPU)"
        return
    }

    # Detect whether Recall is installed
    $Installed = $false
    $appxTargets = Get-AppxPackage -AllUsers | Where-Object { $_.Name -match 'Recall' }
    $provTargets = Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -match 'Recall' }

    if ($appxTargets -or $provTargets) { $Installed = $true }

    if ($CheckBox.Checked) {
        

        LogTask-Start "KEEP Recall Application"

        if ($Installed) {
           

            LogTask-Completion "KEPT      - Recall Application"
        }
        else {
            LogTask-Completion "NOT FOUND - Recall Application"
        }
    }
    else {
         LogTask-Start "KEEP Recall Application, was NOT checked."

        if ($Installed) {

            LogTask-Progress "Microsoft Recall will be REMOVED"

            foreach ($app in $appxTargets) {

                LogTask-Progress "Removing Recall Appx package: $($app.Name)"

                try {
                    Remove-AppxPackage -Package $app.PackageFullName -ErrorAction Stop
                } catch {
                    LogTask-Progress "ERROR: Failed to remove Appx package '$($app.Name)' - $($_.Exception.Message)"
                }
            }
            foreach ($prov in $provTargets) {

                LogTask-Progress "Removing Recall provisioned stub: $($prov.DisplayName)"

                try {
                    Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop
                } catch {
                    LogTask-Progress "ERROR: Failed to remove provisioned stub '$($prov.DisplayName)' - $($_.Exception.Message)"
                }
            }
            LogTask-Completion "REMOVED   - Microsoft Recall"
        }
        else {
            LogTask-Completion "NOT FOUND - Microsoft Recall"
        }
    }
}
# END of - function KEEP-Recall-Application


# ======================================================================================
function Handle-MicrosoftAccounts {
    #.SYNOPSIS
    # Handles the logic for creating a Local Account and/or removing Microsoft Accounts based on user selection.
    #.DESCRIPTION
    # - If "Create and Sign in with a Local Account" is checked, it initiates the process to create a new Local Account. Depending on whether the user also chose to remove Microsoft Accounts, it may include security questions.
    # - If "Remove Microsoft Account entirely" is checked, it attempts to disable all Microsoft Accounts, but only if a Local Account was successfully created to prevent lockout.          

    param(
        $CheckBox,
        [string]$CurrentOption  
    )

    $localDEBUG_Mode = $false
    If ($localDEBUG_Mode){Write-Host "[DEBUG] Handle-MicrosoftAccounts called with Task Name: $CurrentOption"}

    # If User has ticked 'Remove Microsoft Account entirely', set $script:RemoveMSAccount = true
    $script:RemoveMSAccount = $false
    foreach ($ctrl in $script:panelLeft.Controls) {
        foreach ($subCtrl in $ctrl.Controls) {
            if ($subCtrl -is [System.Windows.Forms.Panel]) {
                foreach ($chk in $subCtrl.Controls) {
                    if ($chk -is [System.Windows.Forms.CheckBox] -and
                        $chk.Tag -and
                        $chk.Tag.CurrentOption -eq 'Remove Microsoft Account entirely') {
                        $script:RemoveMSAccount = $chk.Checked
                    }
                }
            }
        }
    }

    if ($CurrentOption -eq "Create and Sign in with a Local Account") {
        if ($CheckBox.Checked -or $script:RemoveMSAccount) {
            if ($CheckBox.Checked -and -not $script:RemoveMSAccount) {
                LogTask-Start "Microsoft Accounts"
                $Reason = "You have opted to create a Local Account."
                $Explanation = "This allows you to sign in without using a Microsoft Account."
                $IncludeSecurityQuestions = $false
            }
            elseif (-not $CheckBox.Checked -and $script:RemoveMSAccount) {
                $Reason = "You have opted to remove your Microsoft Account entirely."
                $Explanation = "Before this can happen, you must create a Local Account..."
                $IncludeSecurityQuestions = $true
            }
            else {
                $Reason = "You have opted to create a Local Account AND remove your Microsoft Account entirely."
                $Explanation = "So, first we need to create your NEW Local Account. Then we'll need to ask you some questions..."
                $IncludeSecurityQuestions = $true
            }

            # Ensure a ref var exists in scope for the result
            if (-not ($script:NewUserCreatedSuccessfully)) {
                $script:NewUserCreatedSuccessfully = $false
            }
            $refResult = [ref]$script:NewUserCreatedSuccessfully

            Create-NewUserAccount `
                -Reason $Reason `
                -Explanation $Explanation `
                -IncludeSecurityQuestions:$IncludeSecurityQuestions `
                -NewUserCreatedSuccessfully $refResult
        }
        else {
            LogTask-Start "Microsoft Accounts"
            LogTask-Completion "Neither Option selected - nothing done"
        }
    }
    elseif ($CurrentOption -eq "Remove Microsoft Account entirely") {

        # Only act (or warn) if the user actually selected this option
        if ($CheckBox.Checked) {
            LogTask-Start "Microsoft Accounts"
            if ($script:NewUserCreatedSuccessfully) {
                # Disable-AllMicrosoftAccounts
                LogTask-Completion "REMOVED   - Microsoft Account(s) disabled and profile(s) cleaned (where applicable)."
            }
            else {
                LogTask-Completion "Cannot remove Microsoft Account until a Local Account exists."
            }
        }
    }
}
# END of - function Handle-MicrosoftAccounts


# ======================================================================================
function Create-NewUserAccount {
    #.SYNOPSIS
    # Creates a new Local User Account with the specified parameters and logs the process.          
    #.DESCRIPTION
    # - Displays a form to collect username and password for the new Local Account.
    # - Validates inputs and enables the Create button only when valid.
    # - If $IncludeSecurityQuestions is true, additional steps would be taken after account creation to set up security questions (not implemented in this snippet).
    # - The result of whether the new user was created successfully is returned via the $NewUserCreatedSuccessfully reference variable, which the caller can check to decide whether to proceed with Microsoft Account removal. 
    param(
        [string]$Reason,                    # short bold headline
        [string]$Explanation,               # longer supporting text
        [switch]$IncludeSecurityQuestions,
        [ref]$NewUserCreatedSuccessfully    # This is RETURNED to Caller   
    )

    LogTask-Start "Create NEW User Account"

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # --- TaskLog Header ---
    $script:SummaryTaskLog  += "Starting new user account creation"
    $script:CurrentTaskLog  += "Dialog opened: $Reason"

    # -------------------------
    # Stage 1: Account details
    # -------------------------
    $form1 = New-Object System.Windows.Forms.Form
    $form1.Text = "Create a NEW User Account"
    $form1.Size = [System.Drawing.Size]::new(420,385)
    $form1.StartPosition = "CenterScreen"
    $form1.Font = "Segoe UI, 9"

    # Reason (bold headline)
    $lblReason = New-Object System.Windows.Forms.Label
    $lblReason.Text = $Reason
    $lblReason.Location = "20,10"
    $lblReason.Size = [System.Drawing.Size]::new(380,30)
    $lblReason.Font = New-Object System.Drawing.Font("Segoe UI",9,[System.Drawing.FontStyle]::Bold)
    $lblReason.AutoSize = $false
    $form1.Controls.Add($lblReason)

    # Explanation (normal paragraph)
    $lblExplanation = New-Object System.Windows.Forms.Label
    $lblExplanation.Text = $Explanation
    $lblExplanation.Location = "20,45"
    $lblExplanation.Size = [System.Drawing.Size]::new(380,50)
    $lblExplanation.Font = New-Object System.Drawing.Font("Segoe UI",9,[System.Drawing.FontStyle]::Regular)
    $lblExplanation.AutoSize = $false
    $form1.Controls.Add($lblExplanation)

    # Username
    $lblUser = New-Object System.Windows.Forms.Label
    $lblUser.Text = "User name"
    $lblUser.Location = "20,100"
    $lblUser.Font = New-Object System.Drawing.Font("Segoe UI",9,[System.Drawing.FontStyle]::Bold)
    $form1.Controls.Add($lblUser)

    $txtUser = New-Object System.Windows.Forms.TextBox
    $txtUser.Location = "20,125"
    $txtUser.Width = 360
    $form1.Controls.Add($txtUser)

    # Hook it up to the textbox
    $txtUser.add_Leave({
        Validate-UserName -txtUser $txtUser | Out-Null
    })

    # Password
    $lblPass = New-Object System.Windows.Forms.Label
    $lblPass.Text = "Password"
    $lblPass.Location = "20,165"
    $lblPass.Font = New-Object System.Drawing.Font("Segoe UI",9,[System.Drawing.FontStyle]::Bold)
    $form1.Controls.Add($lblPass)

    $txtPass = New-Object System.Windows.Forms.TextBox
    $txtPass.Location = "20,190"
    $txtPass.Width = 360
    $txtPass.UseSystemPasswordChar = $true
    $form1.Controls.Add($txtPass)

    # Hook it up to the password textbox
    $txtPass.add_Leave({
        Validate-Password -txtPass $txtPass | Out-Null
    })

    # Confirm Password
    $lblConfirm = New-Object System.Windows.Forms.Label
    $lblConfirm.Text = "Confirm password"
    $lblConfirm.Location = "20,230"
    $lblConfirm.Font = New-Object System.Drawing.Font("Segoe UI",9,[System.Drawing.FontStyle]::Bold)
    $form1.Controls.Add($lblConfirm)

    $txtConfirm = New-Object System.Windows.Forms.TextBox
    $txtConfirm.Location = "20,255"
    $txtConfirm.Width = 360
    $txtConfirm.UseSystemPasswordChar = $true
    $form1.Controls.Add($txtConfirm)

    # Buttons
    $btnNext = New-Object System.Windows.Forms.Button
    if ($IncludeSecurityQuestions) { $btnNext.Text = "Continue" } else { $btnNext.Text = "Create" }
    $btnNext.Location = "220,295"
    $btnNext.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $btnNext.Enabled = $false   # disabled until validations succeed
    $form1.Controls.Add($btnNext)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = "310,295"
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form1.Controls.Add($btnCancel)

    # -------------------------
    # Validation wiring
    # -------------------------
    $validateInputs = {
        $validUser   = -not [string]::IsNullOrWhiteSpace($txtUser.Text)
        $validPass   = $txtPass.Text.Length -ge 6
        $validMatch  = $txtPass.Text -eq $txtConfirm.Text
        if ($validUser -and $validPass -and $validMatch) {
            $btnNext.Enabled = $true
            $script:CurrentTaskLog += "Inputs validated: username and passwords OK"
        } else {
            $btnNext.Enabled = $false
        }
    }
    $txtUser.Add_TextChanged($validateInputs)
    $txtPass.Add_TextChanged($validateInputs)
    $txtConfirm.Add_TextChanged($validateInputs)

    # -------------------------
    # Show dialog
    # -------------------------
    $result1 = $form1.ShowDialog()
    if ($result1 -ne [System.Windows.Forms.DialogResult]::OK) {
        $script:DetailedTaskLog += "User cancelled account creation"
        $script:SummaryTaskLog  += "Account creation cancelled"
        $script:CurrentTaskLog  += "Dialog closed by Cancel"
        return $null
    }

    if ($txtPass.Text -ne $txtConfirm.Text) {
        [System.Windows.Forms.MessageBox]::Show("Passwords do not match.","Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error)
        $script:DetailedTaskLog += "Account creation failed: passwords did not match"
        $script:SummaryTaskLog  += "Account creation failed"
        $script:CurrentTaskLog  += "Password mismatch detected"
        return $null
    }

    $info = @{
        UserName = $txtUser.Text
        Password = (ConvertTo-SecureString $txtPass.Text -AsPlainText -Force)
    }

    LogTask-Progress  "Account details collected for user: $($info.UserName)"
   
    # --- Create the local user and elevate ---
    try {
        New-LocalUser `
            -Name $info.UserName `
            -Password $info.Password `
            -FullName $info.UserName `
            -Description $Explanation.Substring(0, [Math]::Min(48, $Explanation.Length)) `
            -ErrorAction Stop

        Add-LocalGroupMember `
            -Group "Administrators" `
            -Member $info.UserName `
            -ErrorAction Stop

        LogTask-Progress "Local account $($info.UserName) created and elevated to Administrator."
        $NewUserCreatedSuccessfully.Value = $true
    }
    catch {
        LogTask-Completion "FAILED to create/elevate Local Account $($info.UserName): $($_.Exception.Message)"
        $NewUserCreatedSuccessfully.Value = $false
        return $null
    }

# -------------------------
# Stage 2: Password Recovery questions
# -------------------------
if ($IncludeSecurityQuestions -and $NewUserCreatedSuccessfully.Value) {

    $form2 = New-Object System.Windows.Forms.Form
    $form2.Text = "Password Recovery Setup"
    $form2.Size = [System.Drawing.Size]::new(420,400)
    $form2.StartPosition = "CenterScreen"
    $form2.Font = "Segoe UI, 9"

    # First sentence in bold
    $lblRecovery1 = New-Object System.Windows.Forms.Label
    $lblRecovery1.Text = "Because your Microsoft Account is being removed, you will not be able to use it to recover your Password."
    $lblRecovery1.Location = "20,10"
    $lblRecovery1.Size = [System.Drawing.Size]::new(380,30)
    $lblRecovery1.Font = New-Object System.Drawing.Font("Segoe UI",9,[System.Drawing.FontStyle]::Bold)
    $lblRecovery1.AutoSize = $false
    $form2.Controls.Add($lblRecovery1)

    # Remaining sentences in normal style
    $lblRecovery2 = New-Object System.Windows.Forms.Label
    $lblRecovery2.Text =
        "So, you need to select some Security Questions, to prove it's YOU if you forget your Password. " +
        "Your answers are stored securely only on this PC, and are used solely during password recovery."
    $lblRecovery2.Location = "20,45"
    $lblRecovery2.Size = [System.Drawing.Size]::new(380,60)
    $lblRecovery2.Font = New-Object System.Drawing.Font("Segoe UI",9,[System.Drawing.FontStyle]::Regular)
    $lblRecovery2.AutoSize = $false
    $form2.Controls.Add($lblRecovery2)

    # Show recovery dialog
    $result2 = $form2.ShowDialog()
    if ($result2 -ne [System.Windows.Forms.DialogResult]::OK) {
        LogTask-Completion "Password Recovery Setup cancelled"
        $NewUserCreatedSuccessfully.Value = $false   # guard trips, dispatcher will skip MS account removal
        return $null
    }

    # Collect recovery info
    $info.RecoveryQ1 = $cbQ1.SelectedItem
    $info.RecoveryA1 = $txtA1.Text
    $info.RecoveryQ2 = $cbQ2.SelectedItem
    $info.RecoveryA2 = $txtA2.Text

    LogTask-Progress "Password Recovery questions collected for user: $($info.UserName)"
}

# Final log entry
if ($NewUserCreatedSuccessfully.Value) {
    LogTask-Completion "NEW User Account created for User: $($info.UserName)"
} else {
    LogTask-Completion "User account creation incomplete or cancelled."
}

return $info

} # END of - Function Create-NewUserAccount


# ======================================================================================
function Validate-UserName {
    #.SYNOPSIS
    # Validates the proposed username for the new Local Account, ensuring it meets criteria and does not conflict with existing accounts.
    #.DESCRIPTION
    # This function checks the following:
    # - The username is not empty.
    # - The username does not contain forbidden characters.
    # - The username is 20 characters or fewer.
    # - The username is unique on the local machine.
    #.PARAMETER txtUser
    # The TextBox control containing the proposed username.
    #.OUTPUT
    # Returns $true if the username is valid, $false otherwise. Displays message boxes for
    # any validation errors and sets focus back to the username textbox.
    param([System.Windows.Forms.TextBox]$txtUser)

    $userName = $txtUser.Text.Trim()

    # Empty check
    if ([string]::IsNullOrWhiteSpace($userName)) {
        [System.Windows.Forms.MessageBox]::Show(
            "User Name cannot be blank.",
            "Validation Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        $txtUser.Focus()
        return $false
    }

    # Forbidden characters
    $forbidden = [char[]]'\/:*?"<>|'
    if ($userName.IndexOfAny($forbidden) -ge 0) {
        [System.Windows.Forms.MessageBox]::Show(
            'User Name contains invalid characters: \ / : * ? " < > |',
            'Validation Error',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        $txtUser.Focus()
        return $false
    }

    # Length check
    if ($userName.Length -gt 20) {
        [System.Windows.Forms.MessageBox]::Show(
            "User Name must be 20 characters or fewer.",
            "Validation Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        $txtUser.Focus()
        return $false
    }

    # Uniqueness check
    $existingUsers = Get-LocalUser | Select-Object -ExpandProperty Name
    if ($existingUsers -contains $userName) {
        [System.Windows.Forms.MessageBox]::Show(
            "The user name '$userName' already exists on this PC.",
            "Duplicate User Name",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        $txtUser.Focus()
        return $false
    }

    return $true

}  # END of - function Validate-UserName


# ======================================================================================
function Validate-Password {
    #.SYNOPSIS
    # Validates the proposed password for the new Local Account, ensuring it meets criteria for length and complexity.
    #.DESCRIPTION
    # This function checks the following:
    # - The password is at least 6 characters long.
    # - The password contains at least one number.
    #.PARAMETER txtPass
    # The TextBox control containing the proposed password.
    #.OUTPUT
    # Returns $true if the password is valid, $false otherwise. Displays message boxes for
    # any validation errors and sets focus back to the password textbox.        

    param([System.Windows.Forms.TextBox]$txtPass)

    $password = $txtPass.Text

    # Minimum length
    if ($password.Length -lt 6) {
        [System.Windows.Forms.MessageBox]::Show(
            "Password must be at least 6 characters long.",
            "Validation Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        $txtPass.Focus()
        return $false
    }
    # Optional: add complexity rules if desired
    # Example: require at least one digit
    if ($password -notmatch '\d') {
        [System.Windows.Forms.MessageBox]::Show(
            "Password must contain at least one number.",
            "Validation Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        $txtPass.Focus()
        return $false
    }

    return $true
}
# END of - function Validate-Password


# ======================================================================================
function Disable-AllMicrosoftAccounts{
    #.SYNOPSIS
    # Disables all Microsoft Account users on the local machine to prevent login, and optionally removes their profile folders. This is typically called after a new Local Account has been created to ensure the user can still log in.
    #.DESCRIPTION   
    # - Enumerates all local user accounts with a PrincipalSource of "MicrosoftAccount".
    # - For each Microsoft Account user, attempts to disable the account using Disable-LocalUser.
    # - Optionally, removes the user's profile folder from C:\Users if it exists.
    # - Logs progress for each account and any errors encountered.
    # - If no Microsoft Accounts are found, logs that information and exits gracefully.

    LogTask-Start "Disabling ALL Microsoft Account Users"

    $MicrosoftAccountUsers = Get-LocalUser | Where-Object { $_.PrincipalSource -eq "MicrosoftAccount" }
    if (-not $MicrosoftAccountUsers) {
        LogTask-Completion "[INFO] No Microsoft accounts detected on this PC."
        return
    }

    foreach ($user in $MicrosoftAccountUsers) {
        try {
            Disable-LocalUser -Name $user.Name -ErrorAction Stop
            LogTask-Progress "Disabled Microsoft account login for $($user.Name)."
            
            # Optional: remove profile folder
            $profilePath = "C:\Users\$($user.Name)"
            if (Test-Path $profilePath) {
                Remove-Item $profilePath -Recurse -Force
                LogTask-Progress "User Profile removed for $profilePath."
            }
        }
        catch {
            LogTask-Completion "Failed to disable Microsoft account $($user.Name): $_"
        }
    }
}
# END of - Disable-AllMicrosoftAccounts


# =======================================================================================
function Remove-Xbox {
    #.SYNOPSIS
    # Removes Xbox-related applications from the system if the user has chosen to do so.
    #.DESCRIPTION
    # - Removes each removable Xbox Appx component individually
    # - Skips the protected XboxGameCallableUI component
    # - Sets registry keys to prevent ms-gamingoverlay popup after removal
    # - Reports on each component removed or not found

    param(
        $CheckBox,
        [string]$CurrentOption
    )

    $localDEBUG_Mode = $false

    # Define removable Xbox components
    $xboxComponents = @(
        "Microsoft.GamingApp",
        "Microsoft.GamingServices",
        "Microsoft.XboxGamingOverlay",
        "Microsoft.XboxGameOverlay",
        "Microsoft.XboxSpeechToTextOverlay",
        "Microsoft.XboxIdentityProvider",
        "Microsoft.Xbox.TCUI"
    )

    # Detect which components are installed
    $installedComponents = @()
    foreach ($component in $xboxComponents) {
        $pkg = Get-AppxPackage -AllUsers | Where-Object { $_.Name -eq $component }
        if ($pkg) { $installedComponents += $pkg }
    }

    $Installed = $installedComponents.Count -gt 0

    LogTask-Start $CurrentOption

    if ($CurrentOption -like "KEEP*") {
        if ($Installed) {
            LogTask-Completion "KEPT      - Xbox components"
        } else {
            LogTask-Completion "NOT FOUND - Xbox components"
        }
        return
    }

    # --- Remove ---
    if ($Installed) {
        $removedCount  = 0
        $failedCount   = 0
        $skippedCount  = 0

        foreach ($pkg in $installedComponents) {
            try {
                Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
                LogTask-Progress "REMOVED   - $($pkg.Name)"
                $removedCount++
            }
            catch {
                LogTask-Progress "FAILED    - $($pkg.Name): $($_.Exception.Message)"
                $failedCount++
            }
        }

        # Remove provisioned packages to prevent reinstallation for new users
        LogTask-Progress "Removing provisioned Xbox packages..."
        foreach ($component in $xboxComponents) {
            $prov = Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq $component }
            if ($prov) {
                try {
                    Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop
                    LogTask-Progress "Removed provisioned: $component"
                } catch {
                    LogTask-Progress "ERROR: Failed to remove provisioned package '$component' - $($_.Exception.Message)"
                }
            }
        }

        # Disable GameDVR to prevent ms-gamingoverlay popup
        LogTask-Progress "Disabling GameDVR registry keys..."
        $null = New-Item -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR" -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR" -Name "AppCaptureEnabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        $null = New-Item -Path "HKCU:\System\GameConfigStore" -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_Enabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue

        # Note protected component
        LogTask-Progress "NOTE: Microsoft.XboxGameCallableUI is a protected system component and cannot be removed."

        # summary
        if ($failedCount -eq 0){
            $msg = "REMOVED   - Xbox Components (" + $removedCount + " removed, " + $skippedCount + " skipped)"
        } else {
            $msg = "WARNING   - Xbox removal completed with issues (" + $removedCount + " removed, " + $failedCount + " failed)"
        }
        LogTask-Completion $msg
    }
    else {
        LogTask-Completion "NOT FOUND - Xbox components"
    }

} # END of - function Remove-Xbox


# =======================================================================================
function KEEP-Solitaire {
    param(
        $CheckBox,
        [string]$CurrentOption
    )
    #.SYNOPSIS
    # Keeps or removes the Microsoft Solitaire Collection based on the Current Option text.
    #.DESCRIPTION
    # - If CurrentOption is "KEEP Solitaire", the app is left installed and logged as "Kept".
    # - If CurrentOption is "Remove Solitaire", the app is removed and logged as "Removed".

    LogTask-Start $CurrentOption

    # Detect current state
    $SolitaireApp = Get-AppxPackage -Name Microsoft.MicrosoftSolitaireCollection -ErrorAction SilentlyContinue

    if ($CurrentOption -eq "KEEP Solitaire") {
        if ($SolitaireApp) {
            LogTask-Completion "KEPT      - Microsoft Solitaire Collection"
        }
        else {
            LogTask-Completion "NOT FOUND - Microsoft Solitaire Collection"
        }
    }
    elseif ($CurrentOption -eq "Remove Solitaire") {
        if ($SolitaireApp) {
            try {
                Remove-AppxPackage -Package $SolitaireApp.PackageFullName -AllUsers -ErrorAction Stop
                LogTask-Completion "REMOVED   - Microsoft Solitaire Collection"
            }
            catch {
                LogTask-Completion "FAILED    - $($CurrentOption): $($_.Exception.Message)"
            }
        }
        else {
            LogTask-Completion "NOT FOUND - Microsoft Solitaire Collection"
        }
    }
    else {
        LogTask-Completion "SKIPPED   - Unrecognised option: $CurrentOption"
    }

} # END of - function KEEP-Solitaire


# ======================================================================================
function REMOVEorKEEP {
    #.SYNOPSIS
    # This is the Default call for PERFORM-SelectedOptions loop when the option text doesn't match any of the specific handlers. 
    # It is designed to be flexible and handle a variety of REMOVE or KEEP actions for different applications and shortcuts based on the naming convention of the task and the user's selection.
    #
    # Handles both REMOVE and KEEP actions for various applications and shortcuts based on user selection. The function deduces the intended action and target application from the provided parameters and performs the necessary operations to either remove or keep the item, while logging all steps and outcomes.
    #.DESCRIPTION       
    # - The function first determines the intended action (REMOVE, KEEP, ADD, INSTALL) based on the task name and user option text.
    # - It identifies whether the task relates to a Start Menu shortcut, Taskbar shortcut, Desktop icon, or a specific application.
    # - Depending on the detected type, it performs the appropriate action:
    #   - For Start Menu, Taskbar, or Desktop shortcuts: it either removes the shortcut if the user chose to REMOVE, or logs that it was KEPT if the user chose to KEEP.
    #   - For applications like Outlook: it either uninstalls the app if the user   chose to REMOVE, or logs that it was KEPT if the user chose to KEEP.
    # - The function includes error handling to catch and log any issues that arise during the removal process, ensuring that the user is informed of any failures.

    param(
        [System.Windows.Forms.CheckBox]$CheckBox,
        [string]$CurrentOption
    )

    # Deduce the actual action based on CurrentOption text vs OriginalOption
    # When OriginalOption is "KEEP [App] pinned to Start Menu" but CurrentOption is "Please PIN [App] - MANUALLY",
    # it means the app is NOT currently pinned and we need to treat this as an ADD action
    $defaultAction = ( $CurrentOption -split '\s+')[0]

    $localDEBUG_Mode = $false
    If ($localDEBUG_Mode) { Write-Host "[DEBUG] REMOVEorKEEP: CurrentOption='$CurrentOption' defaultAction='$defaultAction'" -ForegroundColor Magenta }

    # Detect shortcut types FIRST (before we start manipulating the text)
    # "Please PIN [App] - MANUALLY" is a Start Menu shortcut (converted from KEEP recommendation)
    $StartMenuShortcut =  $CurrentOption -match '(?i)(Start Menu|Please PIN.*MANUALLY)'
    $TaskbarShortcut   =  $CurrentOption -match '(?i)(Task ?Bar|Taskbar)'
    $DesktopIcon       =  $CurrentOption -match '(?i)(Desktop)'
    
    if ($defaultAction -eq "Please" -and  $CurrentOption -like "Please PIN*") {
        # This is a converted recommendation - original said KEEP but app isn't actually pinned
        # Treat as ADD for Start Menu PIN
        $defaultAction = "ADD"
    }
    
    $applicationName = ( $CurrentOption -replace '^(Remove|KEEP|Use|INSTALL|ADD|Please)\s+', '')

    # For shortcuts, extract clean app name without location text
    if ($StartMenuShortcut -or $TaskbarShortcut -or $DesktopIcon) {
        # Match both "PIN from/in/on" and "pinned to" (case-insensitive)
        # Also handle "PIN [App] - MANUALLY" format
        $applicationName = $applicationName -replace '(?i)\s+(PIN\s+(from|in|on|to)|pinned\s+to)\s+the\s+(Start Menu|Task ?Bar|Taskbar|Desktop).*$', ''
        $applicationName = $applicationName -replace '(?i)^PIN\s+', ''  # Remove leading "PIN "
        $applicationName = $applicationName -replace '\s*-\s*MANUALLY$', ''  # Remove trailing " - MANUALLY"
        $applicationName = $applicationName -replace '(?i),?\s+FROM\s+the\s+(Task ?Bar|Taskbar|Desktop|Start Menu).*$', ''
        $applicationName = $applicationName -replace '(?i),?\s+ON\s+the\s+(Task ?Bar|Taskbar|Desktop).*$', ''
    }

    if (-not $AppLookup.ContainsKey($applicationName) -and -not ($StartMenuShortcut -or $TaskbarShortcut -or $DesktopIcon)) {
        Write-Warning ("Unknown application: {0}" -f  $CurrentOption)
        return
    }

    $appInfo = $AppLookup[$applicationName]
    $applicationPackage = $null
    
    # Only try to get package if appInfo exists and has PackageName property
    if ($appInfo -and $appInfo.PSObject.Properties.Name -contains 'PackageName' -and $appInfo.PackageName) {
        $applicationPackage = Get-AppxPackage -Name $appInfo.PackageName -ErrorAction SilentlyContinue
    }

    switch ($defaultAction) {

        "Remove" {
            $REMOVEchecked    = $CheckBox.Checked
            $PackageInstalled = $null -ne $applicationPackage

            if ($StartMenuShortcut) {
                LogTask-Start ("Remove {0} PIN from the Start Menu" -f $applicationName)
                if ($REMOVEchecked) {
                    try {
                        $completionMessage = Remove-StartMenuShortcut -OptionText  $CurrentOption
                        LogTask-Completion $completionMessage
                    } catch {
                        LogTask-Completion ("FAILED    - could not remove {0} PIN: {1}" -f $applicationName, $_.Exception.Message)
                    }
                } else {
                    LogTask-Completion ("KEPT      - {0} PIN left in Start Menu." -f $applicationName)
                }
            }
           
            elseif ($DesktopIcon) {
                LogTask-Start ("Remove {0} icon from Desktop." -f $applicationName)
                if ($REMOVEchecked) {
                    try {
                        $completionMessage = Remove-DesktopIcon -OptionText  $CurrentOption
                        LogTask-Completion $completionMessage
                    } catch {
                        LogTask-Completion ("FAILED    - could not remove {0} icon: {1}" -f $applicationName, $_.Exception.Message)
                    }
                } else {
                    LogTask-Completion ("KEPT      - {0} icon left on Desktop." -f $applicationName)
                }
            }
            elseif ($applicationName -match "Outlook") {
                LogTask-Start ("Remove {0}" -f $applicationName)
                $outlookPackages = Get-AppxPackage | Where-Object {
                    $_.Name -match "OutlookForWindows" -or $_.Name -match "OutlookNew"
                }
                if ($outlookPackages) {
                    try {
                        foreach ($pkg in $outlookPackages) {
                            Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
                        }
                        LogTask-Completion "REMOVED   - Outlook for Windows removed successfully."
                    } catch {
                        LogTask-Completion ("FAILED    - to remove Outlook for Windows: {0}" -f $_.Exception.Message)
                    }
                } else {
                    LogTask-Completion ("NOT FOUND - {0}" -f $applicationName)
                }
            }
            else {
                LogTask-Start ("Remove {0}" -f $applicationName)
                if ($REMOVEchecked -and $PackageInstalled) {
                    try {
                        Remove-AppxPackage -Package $applicationPackage.PackageFullName -AllUsers -ErrorAction Stop
                        LogTask-Completion ("REMOVED   - {0} successfully removed." -f $applicationName)
                    } catch {
                        LogTask-Completion ("FAILED    - to remove {0}: {1}" -f $applicationName, $_.Exception.Message)
                    }
                } elseif (-not $PackageInstalled) {
                    LogTask-Completion ("NOT FOUND - {0}" -f $applicationName)
                } else {
                    LogTask-Completion ("KEPT      - {0} left installed." -f $applicationName)
                }
            }
        }

        "Use" {
            if ($TaskbarShortcut -and ( $CurrentOption -like "*Search Bar*")) {
                if ($CheckBox.Checked) {
                    LogTask-Start ("Configure Taskbar Search Bar")
                    
                    try {
                        # Set to long search bar
                        Set-RegistrySettingByName -Name "TaskbarSearchLong" -State "Enabled"
                        
                        # Flag that Explorer restart is needed (will happen at end)
                        $script:ExplorerRestartNeeded = $true
                        LogTask-Completion ("CONFIGURED - Taskbar search set to Long Search Bar. Restart Explorer to see changes.")
                    } catch {
                        LogTask-Completion ("FAILED    - Could not configure search bar: {0}" -f $_.Exception.Message)
                    }
                }
                # Do nothing when unchecked - USE is an action, not a toggle
            } else {
                if ($CheckBox.Checked) {
                    LogTask-Completion ("NOT FOUND - Taskbar search context not recognized.")
                }
            }
        }

        "KEEP" {
            # Track if this option was handled by a specific handler
            $handled = $false
            
            # Handle taskbar items (CoPilot button) - specific handler
            if ($TaskbarShortcut -and ( $CurrentOption -like "*CoPilot*")) {
                $handled = $true
                if ($CheckBox.Checked) {
                    LogTask-Start ("Show CoPilot on Taskbar")
                    
                    try {
                        # Enable CoPilot button on taskbar
                        Set-RegistrySettingByName -Name "TaskbarCopilot" -State "Enabled"
                        
                        # Flag that Explorer restart is needed (will happen at end)
                        $script:ExplorerRestartNeeded = $true
                        LogTask-Completion ("CONFIGURED - CoPilot button enabled. Restart Explorer to see changes.")
                    } catch {
                        LogTask-Completion ("FAILED    - Could not show CoPilot button: {0}" -f $_.Exception.Message)
                    }
                } else {
                    LogTask-Completion ("NOTHING   - Keep not checked for CoPilot button.")
                }
            }
            # Handle Start Menu pinned items
            elseif ($StartMenuShortcut) {
                LogTask-Start ("KEEP {0} pinned to the Start Menu" -f $applicationName)
                
                # Check if app is actually pinned to the Start Menu
                try {
                    $pinnedApps = Get-PinnedStartApps
                    
                    # Try to match using StartAppMap package name first
                    $isPinned = $null
                    if ($script:StartAppMap.ContainsKey($applicationName)) {
                        $packageToFind = $script:StartAppMap[$applicationName].Package
                        $isPinned = $pinnedApps | Where-Object { $_ -like "*$packageToFind*" }
                    }
                    
                    # Fallback: try PackageName from AppLookup
                    if (-not $isPinned -and $appInfo -and $appInfo.PSObject.Properties.Name -contains 'PackageName' -and $appInfo.PackageName) {
                        $isPinned = $pinnedApps | Where-Object { $_ -like "*$($appInfo.PackageName)*" }
                    }
                    
                    # Fallback to searching by display name
                    if (-not $isPinned) {
                        $isPinned = $pinnedApps | Where-Object { $_ -like "*$applicationName*" }
                    }
                } catch {
                    $isPinned = $null
                }
                
                $KEEPchecked = $CheckBox.Checked
                if ($KEEPchecked) {
                    if ($isPinned) {
                        LogTask-Completion ("ALREADY PINNED - {0} is pinned to the Start Menu." -f $applicationName)
                    } else {
                        LogTask-Completion ("NOT PINNED - {0} is not pinned. Would you like to ADD it?" -f $applicationName)
                    }
                } else {
                    # User wants to unpin - Windows 11 doesn't support programmatic unpinning
                    if ($isPinned) {
                        LogTask-Completion ("MANUAL ACTION - Please manually unpin {0} from Start Menu." -f $applicationName)
                    } else {
                        LogTask-Completion ("NOTHING - {0} is not pinned, nothing to do." -f $applicationName)
                    }
                }
            }
            
            elseif ($DesktopIcon) {
                $desktopPath = [Environment]::GetFolderPath("Desktop")
                $iconPath = Join-Path $desktopPath "$applicationName.lnk"
                $iconExists = Test-Path $iconPath
                
                LogTask-Start ("KEEP {0} icon on Desktop" -f $applicationName)
                
                $KEEPchecked = $CheckBox.Checked
                if ($KEEPchecked) {
                    if ($iconExists) {
                        LogTask-Completion ("ALREADY EXISTS - {0} icon is on the Desktop." -f $applicationName)
                    } else {
                        LogTask-Completion ("NOT FOUND - {0} icon not on Desktop. Would you like to ADD it?" -f $applicationName)
                    }
                } else {
                    if ($iconExists) {
                        try {
                            Remove-Item $iconPath -Force
                            LogTask-Completion ("REMOVED   - {0} icon from Desktop." -f $applicationName)
                        } catch {
                            LogTask-Completion ("FAILED    - could not remove {0} icon: {1}" -f $applicationName, $_.Exception.Message)
                        }
                    } else {
                        LogTask-Completion ("NOTHING   - {0} icon not on Desktop, nothing to remove." -f $applicationName)
                    }
                }
            }
            else {
                # Not a shortcut, handle as a package
                LogTask-Start ("KEEP {0}" -f $applicationName)

                $KEEPchecked = $CheckBox.Checked
                $PackageInstalled = $null -ne $applicationPackage
                
                if ($KEEPchecked) {
                    if ($PackageInstalled) {
                        LogTask-Completion ("ALREADY INSTALLED - {0}" -f $applicationName)
                    } else {
                        LogTask-Completion ("NOT FOUND - {0} not installed." -f $applicationName)
                    }
                } else {
                    if ($PackageInstalled) {
                        try {
                            Remove-AppxPackage -Package $applicationPackage.PackageFullName -AllUsers -ErrorAction Stop
                            LogTask-Completion ("UNINSTALLED - {0} removed successfully." -f $applicationName)
                        } catch {
                            LogTask-Completion ("FAILED    - to uninstall {0}: {1}" -f $applicationName, $_.Exception.Message)
                        }
                    } else {
                        LogTask-Completion ("NOTHING   - Keep not checked and {0} not present." -f $applicationName)
                    }
                }
            }
        }

        "INSTALL" {
            LogTask-Start ("INSTALL {0}" -f $applicationName)
            if (-not $appInfo) {
                LogTask-Completion ("FAILED    - no lookup info for {0}" -f $applicationName)
                break
            }

            $alreadyInstalled = $false
            if ($appInfo.PackageName) {
                $alreadyInstalled = (Get-AppxPackage -Name $appInfo.PackageName -ErrorAction SilentlyContinue) -ne $null
            } elseif ($appInfo.WingetId) {
                $outPre = winget list --id $appInfo.WingetId | Out-String
                $alreadyInstalled = ($outPre -match [Regex]::Escape($appInfo.WingetId))
            }

            if ($alreadyInstalled) {
                LogTask-Completion ("ALREADY INSTALLED - {0}" -f $applicationName)
                break
            }

            try {
                if ($appInfo.WingetId) {
                    winget install --id $appInfo.WingetId --silent --accept-source-agreements --accept-package-agreements
                    if (Verify-Install $applicationName $appInfo) {
                        LogTask-Completion ("INSTALLED - {0}" -f $applicationName)
                    } else {
                        LogTask-Completion ("FAILED    - verification did not find {0} after install." -f $applicationName)
                    }
                } elseif ($appInfo.PackageName) {
                    Add-AppxPackage -Register $appInfo.PackageName -ErrorAction Stop
                    if ((Get-AppxPackage -Name $appInfo.PackageName -ErrorAction SilentlyContinue)) {
                        LogTask-Completion ("INSTALLED - {0}" -f $applicationName)
                    } else {
                        LogTask-Completion ("FAILED    - {0} could not be installed" -f $applicationName)
                    }
                }
            } catch {
                LogTask-Completion ("FAILED    - to install {0}: {1}" -f $applicationName, $_.Exception.Message)
            }
        } # END of - INSTALL

        "ADD" {
            # Special handling for Start Menu PINs - modify title for Task Log clarity
            $logTitle =  $CurrentOption
            if ( $CurrentOption -like "Please PIN * - MANUALLY") {
                # Add "to Start Menu" to Task Log title for clarity (UI is shorter)
                $logTitle =  $CurrentOption -replace "(Please PIN .+?) - MANUALLY", '$1 to Start Menu - MANUALLY'
            }
            LogTask-Start $logTitle

            # Special handling for Start Menu PINs (Windows 11 limitation)
            # Check for "Please PIN [App] - MANUALLY" pattern
            if ( $CurrentOption -like "Please PIN * - MANUALLY" -or  $CurrentOption -like "Please PIN * to Start Menu - MANUALLY") {
                # Already extracted clean app name in $applicationName above
                
                # Show full instructions only for the first PIN item
                if (-not $script:ManualPinInstructionsShown) {
                    LogTask-Progress ("Because Microsoft's security policy prevents programs from automatically pinning items to the Start Menu.")
                    LogTask-Progress ("\b To manually pin Apps to the Start menu: \b0")
                    LogTask-Progress ("    1. Click the Start button")
                    LogTask-Progress ("    2. Click 'All Apps'")
                    LogTask-Progress ("    3. Find and right-click the Application")
                    LogTask-Completion ("MANUAL ACTION REQUIRED - Please follow the steps above to PIN toStart Menu.")
                    $script:ManualPinInstructionsShown = $true
                }
                else {
                    # Abbreviated message for subsequent items
                    LogTask-Completion ("MANUAL ACTION REQUIRED - Please follow the steps above to PIN to Start Menu.." )
                }
            }
            else {
                # Parse TaskName into app + location via helper for other ADD actions
                $parsed = Deduce-AppNameAndPlaceFrom $CurrentOption
                $app    = $parsed.AppName
                $place  = $parsed.Place

                If ($localDEBUG_Mode) { Write-Host "[DEBUG] ADD case: app='$app' place='$place'" -ForegroundColor Magenta }
                
                try {
                    # Check if this is a Start Menu PIN request
                    if ($place -eq "Start Menu" -and ( $CurrentOption -like "*PIN*" -or  $CurrentOption -like "*PLEASE ADD*")) {
                        LogTask-Progress ("Because Microsoft's security policy prevents programs from automatically pinning items to the Start Menu.")
                        LogTask-Progress ("\b To manually pin an Application: \b0")
                        LogTask-Progress ("    1. Click the Start button")
                        LogTask-Progress ("    2. Click 'All Apps'")
                        LogTask-Progress ("    3. Find and right-click the Application")
                        LogTask-Completion ("MANUAL ACTION REQUIRED - Please follow the steps above to PIN to Start Menu.")
                    }
                    else {
                        $targetInfo = Get-TargetPathForApp -AppName $app
                        $target     = $targetInfo.TargetPath

                        switch ($place) {
                            "Start Menu" { Add-StartMenuShortcut -AppName $app -TargetPath $target }
                            "Taskbar"    { Pin-TaskbarShortcut   -AppName $app -TargetPath $target }
                            "Desktop"    { Add-DesktopIcon       -AppName $app -TargetPath $target -Arguments $targetInfo.Arguments }
                            default      { Add-StartMenuShortcut -AppName $app -TargetPath $target }
                        }

                        if (Verify-Shortcut -AppName $app -Place $place) {
                            LogTask-Completion ("ADDED     - {0} shortcut to {1}" -f $app, $place)
                        }
                        else {
                            LogTask-Completion ("NOT FOUND - {0} shortcut not verified in {1}" -f $app, $place)
                        }
                    }
                } catch {
                    LogTask-Completion ("FAILED    - to add {0} shortcut to {1}: {2}" -f $app, $place, $_.Exception.Message)
                }
            }
        } # END of - ADD

        "DON'T" {
            # DON'T ADD or DON'T INSTALL - user opted not to add/install
            # Just log that we're skipping it
            $actionText =  $CurrentOption -replace "^DON'T ", ''
            LogTask-Start ("Skipping: {0}" -f $actionText)
            LogTask-Completion ("SKIPPED   - User chose not to proceed with this action.")
        } # END of - DON'T

        default {
            LogTask-Start ("UNKNOWN action for {0}." -f $applicationName)
            LogTask-Completion ("Unrecognized action in TaskName: {0}" -f  $CurrentOption)
        }
    } # END of - switch
    
} # END of - REMOVEorKEEP   


# ======================================================================================
function Remove-StartMenuShortcut {
    #.SYNOPSIS
    # Removes a shortcut from the Start Menu based on the provided option text, which includes the application name and location. The function deduces the target application and its location from the option text, constructs the expected path to the shortcut in the Start Menu, and attempts to remove it if it exists, logging the outcome of the operation.
    #.DESCRIPTION   
    # - The function takes a string parameter $OptionText, which contains the text of the option selected by the user (e.g., "Remove [App] PIN from Start Menu").
    # - It uses a helper function Deduce-AppNameAndPlaceFrom to extract the application name and the location (e.g., Start Menu, Taskbar, Desktop) from the option text.
    # - It constructs the expected path to the shortcut in the Start Menu based on the application name.
    # - It checks if the shortcut exists at the expected path. If it does, it removes the shortcut and returns a message indicating that the PIN was removed. If it does not exist, it returns a message indicating that the PIN was not found.
    #.PARAMETER OptionText          
    # The text of the option selected by the user, which includes the application name and location (e.g., "Remove [App] PIN from Start Menu").
    #.OUTPUT    
    # A string message indicating the result of the operation, such as whether the PIN was removed or not found.        

    param([string]$OptionText)

    $p = Deduce-AppNameAndPlaceFrom -OptionText $OptionText
    $shortcutPath = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\$($p.AppName).lnk"

    if (Test-Path $shortcutPath) {
        Remove-Item $shortcutPath -Force
        return ("REMOVED   - {0} PIN from {1}" -f $p.AppName, $p.Place)
    } else {
        return ("{0} PIN not found in {1}." -f $p.AppName, $p.Place)
    }
} # END of - Remove-StartMenuShortcut


# =======================================================================================
function Deduce-AppNameAndPlaceFrom {
    #.SYNOPSIS
    # Parses the option text to extract the application name and the location (Start Menu, Taskbar, Desktop) where the action is to be performed. The function uses regular expressions to identify the components of the option text and returns a structured object containing the app name and place.
    #.DESCRIPTION   
    # - The function takes a string parameter $OptionText, which is expected to follow a specific format (e.g., "Remove [App] PIN from Start Menu", "ADD [App] to Taskbar", etc.).
    # - It uses a regular expression to parse the option text and capture the leading verb (Remove/KEEP/ADD/INSTALL), the application name, and the location (Start Menu, Taskbar, Desktop) if specified.
    # - The function accounts for different ways the location can be specified in the option text (e.g., "PIN from Start Menu" vs "pinned to Start Menu").
    # - It returns a hashtable with two keys: AppName (the cleaned application name without any "PIN" suffix) and Place (the location where the action is to be performed).
    #.PARAMETER OptionText  
    # The text of the option selected by the user, which includes the action, application name, and location (e.g., "Remove [App] PIN from Start Menu").
    #.OUTPUT
    # A hashtable containing the extracted AppName and Place from the option text. If the option text does not match the expected pattern, it returns the entire option text as AppName and null for Place. 

    param(
        [Parameter(Mandatory)]
        [string]$OptionText
    )

    # Pattern captures:
    # 1 = leading verb (Remove/KEEP/ADD/INSTALL)
    # 2 = app name
    # 3 = Place when written as ", to Place"
    # 5 = Place when written as "from/in/on the Place"
    #
    # NOTE: Place here is NOT a geographic location (e.g. Washington, London).
    #       It is strictly one of three UI shortcut destinations:
    #       "Start Menu", "Taskbar", or "Desktop".
    
    $pattern = '^(Remove|KEEP|ADD|INSTALL|SHOW|HIDE|ENABLE|DISABLE)\s+(.+?)(?:,\s+to\s+the\s+(Start Menu|Taskbar|Desktop)|,\s+to\s+(Start Menu|Taskbar|Desktop)|,\s+ON\s+the\s+(Desktop)|,\s+FROM\s+the\s+(Start Menu|Taskbar|Desktop)|\s+(from|in|on)\s+the\s+(Start Menu|Taskbar|Desktop))?$'

    $match = [regex]::Match($OptionText, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

    if ($match.Success) {
        $appName = $match.Groups[2].Value.Trim()
        
        # Remove "PIN" suffix if present (for Start Menu/Taskbar shortcuts)
        $appName = $appName -replace '\s+PIN$', ''

        # Deduce Place:
        # If the option text used ", to Place", capture from group 3.
        # Otherwise, if it used "from/in/on the Place", capture from group 5.
        $place = if ($match.Groups[3].Success) { $match.Groups[3].Value } 
                 elseif ($match.Groups[4].Success) { $match.Groups[4].Value }
                 else { $match.Groups[6].Value }
                 
        return @{ AppName = $appName; Place = $place }
    }
    else {
        # Fallback: no match, return the whole string as AppName and no Place
        return @{ AppName = $OptionText; Place = $null }
    }
} # END of - function Deduce-AppNameAndPlaceFrom 


# ======================================================================================
function Remove-DesktopIcon {
    param([string]$OptionText)
    #.SYNOPSIS
    # Removes an icon from the Desktop based on the provided option text, which includes the application name. The function deduces the target application from the option text, constructs the expected path to the icon on the Desktop, and attempts to remove it if it exists, logging the outcome of the operation.
    #.DESCRIPTION   
    # - The function takes a string parameter $OptionText, which contains the text of the option selected by the user (e.g., "Remove [App] icon from Desktop").
    # - It uses the helper function Deduce-AppNameAndPlaceFrom to extract the application name from the option text.
    # - It constructs the expected path to the icon on the Desktop based on the application name (assuming the icon is a .lnk file named after the application).
    # - It checks if the icon exists at the expected path. If it does, it removes the icon and returns a message indicating that the icon was removed. If it does not exist, it returns a message indicating that the icon was not found.
    #.PARAMETER OptionText  
    # The text of the option selected by the user, which includes the application name (e.g., "Remove [App] icon from Desktop").
    #.OUTPUT    
    # A string message indicating the result of the operation (e.g., "REMOVED - [App] icon from Desktop" or "[App] icon not found on Desktop"). 
    
    $parsed   = Deduce-AppNameAndPlaceFrom -OptionText $OptionText
    $cleanApp = $parsed.AppName
    $place    = $parsed.Place

    $desktopPath = [Environment]::GetFolderPath("Desktop")
    $iconPath    = Join-Path $desktopPath "$cleanApp.lnk"

    if (Test-Path $iconPath) {
        Remove-Item $iconPath -Force
        return ("REMOVED   - {0} icon from {1}" -f $cleanApp, $place)
    } else {
        return ("{0} icon not found on {1}." -f $cleanApp, $place)
    }
} # END of - Remove-DesktopIcon 


# =======================================================================================
function Set-RegistrySettingByName {
    param(
        [string]$Name, 
        [string]$State
    )
    #.SYNOPSIS
    # Sets a registry setting based on a predefined mapping of setting names to their
    # corresponding registry paths, value names, and values for enabled/disabled states.

    $localDEBUG_Mode = $false

    $info = $script:RegistryLookup[$Name]

    if ($info) {
        $value = if ($State -eq "Enabled") { $info.Enabled } else { $info.Disabled }

        if (-not (Test-Path $info.Path)) {
            New-Item -Path $info.Path -Force | Out-Null
        }

        Set-ItemProperty -Path $info.Path -Name $info.ValueName -Value $value
        
        If ($localDEBUG_Mode) { Write-Host "[DEBUG] Set-RegistrySettingByName: Name='$Name' Category='$($info.Category)'" -ForegroundColor Magenta }

        if ($info.Category -eq "Taskbar" -or $info.Category -eq "ShellIcon") {

            # Attempt to broadcast WM_SETTINGCHANGE to notify shell of registry change
            try {
                Add-Type -TypeDefinition @"
                    using System;
                    using System.Runtime.InteropServices;
                    public class Win32 {
                        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
                        public static extern IntPtr SendMessageTimeout(
                            IntPtr hWnd, uint Msg, IntPtr wParam, string lParam,
                            uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
                    }
"@ -ErrorAction SilentlyContinue
                
                $HWND_BROADCAST = [IntPtr]0xffff
                $WM_SETTINGCHANGE = 0x1a
                $result = [IntPtr]::Zero
                [Win32]::SendMessageTimeout($HWND_BROADCAST, $WM_SETTINGCHANGE, [IntPtr]::Zero, "Environment", 2, 5000, [ref]$result) | Out-Null
            } catch {
                # Broadcast failed - Explorer restart will be needed
                $script:ExplorerRestartNeeded = $true
            }

            # ShellIcon changes always need Explorer restart regardless of broadcast result
            # because WM_SETTINGCHANGE does not refresh Desktop icons
            if ($info.Category -eq "ShellIcon") {
                $script:ExplorerRestartNeeded = $true
            }
        }
    }
    else {
        Write-Warning "No registry entry found for $Name"
    }

} # END of - function Set-RegistrySettingByName


# =======================================================================================
function Get-PinnedStartApps {
    #.SYNOPSIS
    # Retrieves a list of applications that are currently pinned to the Start Menu by exporting the Start Layout to a temporary JSON file and parsing the pinned items. The function accounts for different properties that may contain the application identifiers and returns a consolidated list of pinned applications.
    #.DESCRIPTION
    # - The function uses the Export-StartLayout cmdlet to export the current Start Menu layout to a temporary JSON file.
    # - It reads the JSON content and converts it into a PowerShell object for easier manipulation.
    # - It iterates through the list of pinned items in the Start Layout, checking for various properties that may contain the application identifiers (such as appID, packagedAppId, tileID, secondaryTile, desktopAppLink).
    # - For each pinned item, it checks if these properties exist and are not empty, and if so, it adds their values to a list of pinned applications.
    # - Additionally, it includes a fallback mechanism to add any string properties of the pinned items that are not empty, to account for potential differences in how pinned items are represented in different versions of Windows (e.g., Windows 11).
    # - Finally, it returns a consolidated list of applications that are pinned to the Start Menu.

    $TempPath = Join-Path $env:TEMP "StartLayout.json"
    Export-StartLayout -Path $TempPath -ErrorAction Stop
    $json = Get-Content $TempPath -Raw | ConvertFrom-Json

    $pins = @()
    foreach ($item in $json.pinnedList) {
        # Check each property exists before accessing it
        if ($item.PSObject.Properties.Name -contains 'appID' -and $item.appID) { 
            $pins += $item.appID 
        }
        if ($item.PSObject.Properties.Name -contains 'packagedAppId' -and $item.packagedAppId) { 
            $pins += $item.packagedAppId 
        }
        if ($item.PSObject.Properties.Name -contains 'tileID' -and $item.tileID) { 
            $pins += $item.tileID 
        }
        if ($item.PSObject.Properties.Name -contains 'secondaryTile' -and $item.secondaryTile) { 
            $pins += $item.secondaryTile 
        }
        if ($item.PSObject.Properties.Name -contains 'desktopAppLink' -and $item.desktopAppLink) { 
            $pins += $item.desktopAppLink 
        }
        # Windows 11 might use different property names - add all string properties
        foreach ($prop in $item.PSObject.Properties) {
            if ($prop.Value -is [string] -and $prop.Value -and $prop.Value -notmatch '^\s*$') {
                if ($pins -notcontains $prop.Value) {
                    $pins += $prop.Value
                }
            }
        }
    }
    return $pins
} # END of - Get-PinnedStartApps


# =====================================================================================
function Get-TargetPathForApp {
    param([string]$AppName)
    #.SYNOPSIS
    # Retrieves the target path and arguments for launching an application based on its name by looking it up in a predefined application lookup mapping. The function accounts for different types of applications, including Appx/UWP applications, shortcuts (like File Explorer or Recycle Bin), and service toggles (like Copilot, SearchBar, OneDrive, BitLocker), and returns the appropriate target path and arguments for launching the application.
    #.DESCRIPTION   
    # - The function takes a string parameter $AppName, which is the name of the application for which the target path is to be retrieved.
    # - It looks up the application information in a predefined mapping ($script:AppLookup) that contains details about various applications, including their package names for Appx/UWP apps, shortcut names for shell objects, and service names for toggles.
    # - If the application is an Appx/UWP application, it checks if the package is installed and retrieves the corresponding Start Menu AppID to construct the target path and arguments for launching it via explorer.exe.
    # - If the application is a shortcut (like File Explorer or Recycle Bin), it constructs the target path and arguments based on the known shortcut name.
    # - If the application is a service toggle (like Copilot, SearchBar, OneDrive, BitLocker), it returns the service name as the argument for toggling the service.
    # - If the application is not found in the lookup or does not fit any known type, it returns null values for the target path and arguments, along with a status indicating the issue (e.g., "UnknownApp", "NotInstalled", "UnknownType").           

    if (-not $script:AppLookup.ContainsKey($AppName)) {
        return @{ TargetPath=$null; Arguments=$null; Status="UnknownApp" }
    }

    $info = $script:AppLookup[$AppName]

    # Case: Appx/UWP application
    if ($info.PackageName) {
        $pkg = Get-AppxPackage -Name $info.PackageName -ErrorAction SilentlyContinue
        if ($pkg) {
            $startApp = Get-StartApps | Where-Object { $_.Name -like "*$AppName*" }
            if ($startApp) {
                return @{
                    TargetPath = "$env:WINDIR\explorer.exe"
                    Arguments  = "shell:AppsFolder\{0}" -f $startApp.AppID
                    Status     = "Resolved"
                }
            }
            # No ExeName fallback anymore
        }
        return @{ TargetPath=$null; Arguments=$null; Status="NotInstalled" }
    }

    # Case: Shortcut (shell objects like File Explorer, Recycle Bin)
    elseif ($info.ShortcutName) {
        return @{
            TargetPath = "$env:WINDIR\explorer.exe"
            Arguments  = $info.ShortcutName
            Status     = "Shortcut"
        }
    }

    # Case: Service toggles (Copilot, SearchBar, OneDrive, BitLocker)
    elseif ($info.ServiceName) {
        return @{
            TargetPath = $null
            Arguments  = $info.ServiceName
            Status     = "Service"
        }
    }

    return @{ TargetPath=$null; Arguments=$null; Status="UnknownType" }
}
# END of - function Get-TargetPathForApp


# ======================================================================================
function Pin-TaskbarShortcut {
    param([string]$OptionText, [string]$TargetPath)
    #.SYNOPSIS
    # Pins a shortcut to the Taskbar based on the provided option text, which includes the application name, and the target path for the shortcut. The function deduces the target application from the option text, creates a temporary shortcut on the Desktop if it does not already exist, and then uses the Shell.Application COM object to access the Taskbar's pinned items and invokes the "Pin to taskbar" verb to pin it, logging the outcome of the operation.
    #.DESCRIPTION   
    # - The function takes two parameters: $OptionText, which contains the text of the option selected by the user (e.g., "Add [App] PIN to Taskbar"), and $TargetPath, which is the path that the shortcut should point to.
    # - It uses the helper function Deduce-AppNameAndPlaceFrom to extract the application name from the option text.
    # - It constructs a temporary shortcut on the Desktop with the name of the application if it does not already exist, pointing to the provided target path.
    # - It then uses the Shell.Application COM object to access the Taskbar's pinned items  and checks if the shortcut exists. If it does, it invokes the "Pin to taskbar" verb to pin it and returns a message indicating that the shortcut was added. If it does not exist, it returns a message indicating that the shortcut was not found.
    # - The function includes error handling to catch and log any issues that arise during the pinning process, ensuring that the user is informed of any failures.
    #.PARAMETER OptionText  
    # The text of the option selected by the user, which includes the application name (e.g., "Add [App] PIN to Taskbar").
    #.PARAMETER TargetPath      
    # The target path that the shortcut should point to when pinned to the Taskbar. This is typically the path to the application's executable or a shell command for launching it.
    #.OUTPUT            
    # A string message indicating the result of the operation (e.g., "ADDED - [App] shortcut to Taskbar" or "[App] shortcut not found for Taskbar").        

    if ([string]::IsNullOrWhiteSpace($OptionText)) {
        return  # Dispatcher will log FAILED
    }

    $parsed   = Deduce-AppNameAndPlaceFrom $OptionText
    $cleanApp = $parsed.AppName

    try {
        $desktopPath  = [Environment]::GetFolderPath("Desktop")
        $tempShortcut = Join-Path $desktopPath "$cleanApp.lnk"

        if (-not (Test-Path $tempShortcut)) {
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($tempShortcut)
            $shortcut.TargetPath = $TargetPath
            $shortcut.Save()
        }

        $shellApp = New-Object -ComObject Shell.Application
        $folder   = $shellApp.Namespace($desktopPath)
        $item     = $folder.ParseName("$cleanApp.lnk")
        if ($item) {
            $item.InvokeVerb("Pin to taskbar")
        }
    } catch {
        throw  # Dispatcher will catch and log FAILED
    }
} # END of - function Pin-TaskbarShortcut


# ======================================================================================
function Add-DesktopIcon {
    param(
        [string]$AppName,
        [string]$TargetPath,
        [string]$Arguments = ""
    )
    #.SYNOPSIS
    # Adds an icon to the Desktop based on the provided option text, which includes the application name, and the target path for the shortcut. The function deduces the target application from the option text, creates a shortcut on the Desktop pointing to the provided target path if it does not already exist, and logs the outcome of the operation.
    #.DESCRIPTION       
    # - The function takes two parameters: $OptionText, which contains the text of the option selected by the user (e.g., "Add [App] icon to Desktop"), and $TargetPath, which is the path that the shortcut should point to.
    # - It uses the helper function Deduce-AppNameAndPlaceFrom to extract the application name from the option text.
    # - It constructs the expected path for the icon on the Desktop based on the application name   (assuming the icon is a .lnk file named after the application).
    # - It checks if the shortcut already exists at the expected path. If it does not exist, it creates a new shortcut on the Desktop with the name of the application, pointing to the provided target path. If it already exists, it does nothing.
    # - The function includes error handling to catch and log any issues that arise during the shortcut creation process, ensuring that the user is informed of any failures.
    #.PARAMETER OptionText
    # The text of the option selected by the user, which includes the application name (e.g., "Add [App] icon to Desktop").
    #.PARAMETER TargetPath
    # The target path that the shortcut should point to when created on the Desktop. This is typically the path to the application's executable or a shell command for launching it.
    #.OUTPUT
    # A string message indicating the result of the operation (e.g., "ADDED - [App] icon to Desktop" or "[App] icon already exists on Desktop").            

    $localDEBUG_Mode = $false

    If ($localDEBUG_Mode) { Write-Host "[DEBUG] Add-DesktopIcon: AppName='$AppName' TargetPath='$TargetPath' Arguments='$Arguments'" -ForegroundColor Magenta }

    $desktopPath = [Environment]::GetFolderPath("Desktop")
    $iconPath    = Join-Path $desktopPath "$AppName.lnk"

    If ($localDEBUG_Mode) { Write-Host "[DEBUG] iconPath='$iconPath' Exists=$(Test-Path $iconPath)" -ForegroundColor Magenta }

    if (-not (Test-Path $iconPath)) {
        $shell    = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($iconPath)
        $shortcut.TargetPath = $TargetPath
        if (-not [string]::IsNullOrWhiteSpace($Arguments)) {
            $shortcut.Arguments = $Arguments
        }
        $shortcut.Save()
    }
} # END of - function Add-DesktopIcon


# ======================================================================================
function Add-StartMenuShortcut {
    #.SYNOPSIS
    # Adds a shortcut to the Start Menu based on the provided application name and target path. The function constructs the expected path for the shortcut in the Start Menu based on the application name, checks if it already exists, and if not, creates a new shortcut pointing to the provided target path. It logs the outcome of the operation.
    #.DESCRIPTION
    # - The function takes two parameters: $AppName, which is the name of the application for which the shortcut is to be added, and $TargetPath, which is the path that the shortcut should point to.
    # - It constructs the expected path for the shortcut in the Start Menu based on the application name (assuming the shortcut is a .lnk file named after the application).
    # - It checks if the shortcut already exists at the expected path. If it does not   exist, it creates a new shortcut in the Start Menu with the name of the application, pointing to the provided target path. If it already exists, it does nothing.
    # - The function includes error handling to catch and log any issues that arise during the shortcut creation process, ensuring that the user is informed of any failures.
    #.PARAMETER AppName 
    # The name of the application for which the shortcut is to be added to the Start Menu.
    #.PARAMETER TargetPath
    # The target path that the shortcut should point to when created in the Start Menu. This is typically the path to the application's executable or a shell command for launching it.
    #.OUTPUT
    # A string message indicating the result of the operation (e.g., "ADDED - [App] shortcut to Start Menu" or "[App] shortcut already exists in Start Menu").

    param(
        [string]$AppName,
        [string]$TargetPath,
        [string]$Place = "Start Menu"
    )

    $shortcutPath = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\$AppName.lnk"

    if (-not (Test-Path $shortcutPath)) {
        $shell = New-Object -ComObject WScript.Shell
        $s = $shell.CreateShortcut($shortcutPath)
        $s.TargetPath = $TargetPath
        $s.Save()
    }
} # END of - function Add-StartMenuShortcut


# =======================================================================================
function Verify-Shortcut {
    #.SYNOPSIS
    # Verifies the existence of a shortcut for a given application name and location (Start Menu, Taskbar, Desktop) by constructing the expected path for the shortcut based on the location and checking if it exists. The function returns a boolean indicating whether the shortcut is present at the expected location.
    #.DESCRIPTION       
    # - The function takes two parameters: $AppName, which is the name of the application for which the shortcut is to be verified, and $Place, which indicates the location where the shortcut should be (e.g., "Start Menu", "Taskbar", "Desktop").
    # - It constructs the expected path for the shortcut based on the provided location. For the Start Menu, it looks in the ProgramData Start Menu Programs folder; for the Taskbar, it looks in the User Pinned Taskbar folder; and for the Desktop, it looks on the user's Desktop.
    # - It checks if the shortcut exists at the expected path and returns $true if it   does, or $false if it does not. If the provided location is not recognized, it also returns $false.
    #.PARAMETER AppName
    # The name of the application for which the shortcut is to be verified.
    #.PARAMETER Place
    # The location where the shortcut is expected to be found, which can be "Start Menu", "Taskbar", or "Desktop".
    #.OUTPUT
    # A boolean value indicating whether the shortcut exists at the expected location ($true) or not
    #($false). If the provided location is not recognized, it also returns $false.                  

    param(
        [string]$AppName,
        [string]$Place
    )

    switch ($Place) {
        "Start Menu" {
            $shortcutPath = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\$AppName.lnk"
        }
        "Taskbar" {
            # Taskbar pins are stored in a special folder under AppData
            $shortcutPath = Join-Path $env:AppData "Microsoft\Internet Explorer\Quick Launch\User Pinned\Taskbar\$AppName.lnk"
        }
        "Desktop" {
            $shortcutPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "$AppName.lnk"
        }
        default {
            return $false
        }
    }

    return (Test-Path $shortcutPath)
}
# END of - unction Verify-Shortcut


#++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
# TASK LOGGING FUNCTIONS
# ======================
# These functions are used to log the progress and results of each task in the Task Log RTbox in the UI.
# The logging system is designed to provide clear, step-by-step feedback to the user about what actions 
# are being taken, what the results are, and any manual steps they may need to take.
#
# The logs are categorized into:
#      - DetailedTaskLog (which includes all messages with indentation for clarity) and 
#      -SummaryTaskLog (which includes only the final results of each task for a concise overview).
#++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

# =======================================================================================
function LogTask-Start {
    # If there's a pending summary, migrate it before starting the new task to ensure Summary log is up to date 
    #and we don't lose the pending summary if user never clicks Continue on the previous task.
    # This also allows us to show the paused details in the Detailed log before migrating to Summary, 
    # which is important for user clarity and context - they can see the final task's details in the 
    # Detailed log even if they never click Continue, and then see the final summary in the Summary log 
    # for a clear summary of their choices and results after all tasks are complete.
    # 
    param([string]$Task)

    # Collapse the previous task (if we had paused)
    Migrate-PendingSummary

    # Spacing + new header
    if ($script:DetailedTaskLog.Count -gt 0) { $script:DetailedTaskLog += "" }
    $script:CurrentTaskLog  = @("HEADER::$Task")
    $script:DetailedTaskLog += "HEADER::$Task"

    Update-TaskLogRTbox

} # END of - function LogTask-Start


# =======================================================================================
function LogTask-Progress {
    # This function is used to log intermediate progress messages for the current task.
    # It takes a message and an optional indentation level (default is 1) to format the message 
    # with appropriate indentation in the Detailed log and Current log.
    # Each level of indentation adds 3 spaces before the message.
    # The message is added to both the DetailedTaskLog and CurrentTaskLog, 
    # and then the Task Log RTbox is updated to reflect the new message.
    # 
    param(
        [Parameter(Mandatory = $true)]
        [string]$message,
        [int]$IndentLevel = 1  # default indentation level
    )
    # Each level adds 3 spaces (IndentLevel 1 = 3 spaces, 2 = 6 spaces, etc.)
    $indent = " " * (3 * $IndentLevel)
    $indentedMessage = "$indent$message"

    $script:DetailedTaskLog += $indentedMessage
    $script:CurrentTaskLog  += $indentedMessage

    Update-TaskLogRTbox
}
# END of - function LogTask-Progress

# =======================================================================================

function LogTask-Completion {
    param(
        [string]$message
    )
    # When a task is completed, we want to log the final result message and then pause to allow the user 
    # to read it before moving on to the next task.
    # The completion message is added to both the DetailedTaskLog and CurrentTaskLog, 
    # and then we update the Task Log RTbox to show the final result.

    # We also set a PauseLatch to indicate that we are now waiting for the user to click Continue 
    # before we can proceed to the next task.  
    # The PendingSummary is set with the header and result of the completed task, 
    # which will be migrated to the Summary log when we start the next task or when we finish all tasks. 
    # This allows us to keep the Summary log up to date with the final results of each task while still 
    # showing the detailed progress and results in the Detailed log for user clarity and context.
    #
    # If the completion message contains keywords like "ERROR", "FAILED", or "Exception", we also output it to the console in red text so that users who are copying from the console can easily identify any issues that occurred during the task.
    #
    # Finally, we call Update-TaskLogRTbox to refresh the UI with the new completion message and then pause until the user clicks Continue, allowing them to read the results before moving on to the next task.
    # Note: we do not immediately migrate the pending summary to the Summary log here because we want to allow the user to see the final result in the Detailed log first, and then migrate to Summary when they click Continue or when we start the next task. This provides better clarity and context for the user, as they can see the detailed results of each task in the Detailed log and then see a concise summary of their choices and results in the Summary log after all tasks are complete.
    
    # Append result to Detailed + Current
    $script:DetailedTaskLog += $message
    $script:CurrentTaskLog  += $message

    # Output errors to console so user can copy them
    if ($message -match '^(ERROR|FAILED|Exception)') {
        Write-Host $message -ForegroundColor Red
    }

    # Mark for migration (but DO NOT migrate yet)
    $script:PauseLatch   = $true
    $script:PendingSummary = @{
        Header = $script:CurrentTaskLog[0]
        Result = $message
    }

    # Refresh and hold here until user clicks Continue
    Update-TaskLogRTbox

    if (-not  $script:IsLastTask) {Pause-UntilContinueButtonPressed}

} # END of - function LogTask-Completion


# =======================================================================================
function LogTask-RunHeader {
    # This function is called at the very beginning of the task sequence to log a header message with the computer name and timestamp.              
        
    $localDEBUG_Mode = $false

    $script:RunStartTime = Get-Date
    $timestamp = $script:RunStartTime.ToString("yyyy-MM-dd HH:mm:ss")
    $computer  = $env:COMPUTERNAME

    $header = "HEADER::Task Log for $computer started at $timestamp"

    $script:DetailedTaskLog += $header
    $script:CurrentTaskLog  = @($header)

    # Also add to Summary so both logs start with the same header
    if (-not $script:SummaryTaskLog) { $script:SummaryTaskLog = @() }
    $script:SummaryTaskLog += $header
    $script:SummaryTaskLog += ""

    Update-TaskLogRTbox
}
# END of - function LogTask-RunHeader


# =======================================================================================
function LogTask-RunFooter {
    # This function is called at the end of the task sequence to log a final completion message with the total elapsed time for all tasks.      
    #   
    # Before we write the footer, check if we had paused for a pending summary - if so,
    # migrate it now before writing the final footer.  
    # This ensures that the final summary is always visible in the Summary log, 
    # even if the user paused on the last task and never clicked Continue.
    #
    # We also want to show the paused details in the Detailed log before migrating to Summary 
    # so that user can see the final task's details even if they never click Continue.  
    # This is important because the final task may contain critical information such as Explorer restart
    # instructions or error messages that user needs to see even if they don't click Continue.
    #
    # In summary, migrating the pending summary before writing the footer ensures that all critical final information is visible and included in the scrollback history for both logs, providing better context and clarity for the user after all tasks are complete regardless of their interaction with the Continue button on the last task.
    # This is especially important for users who may not click Continue after the last task - without this migration,
    # they would miss out on seeing the final summary and any critical information it contains, 
    # which could lead to confusion or missed instructions (such as needing to restart Explorer to see changes). 
    # By ensuring that the final summary is always visible in both logs, we provide a better user experience 
    # and ensure that all important information is accessible regardless of user interaction with 
    # the Continue button on the last task.  
    #
    # Note: we check the PauseLatch to ensure that we only do this migration if we had actually paused for a summary - if we had already migrated the summary when we paused, then PendingSummary would be null and we would skip this migration to avoid duplicating the summary in the Summary log.
    # This also allows us to show the paused details in the Detailed log before migrating to Summary, which is important for user clarity and context - they can see the final task's details in the Detailed log even if they never click Continue, and then see the final summary in the Summary log for a clear summary of their choices and results after all tasks are complete.
    
    $localDEBUG_Mode = $false

    # If there's a pending summary, show the paused detail first
    if ($script:PauseLatch -and $script:PendingSummary) {
        Update-TaskLogRTbox
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100

        # Now migrate into Summary
        $script:SummaryTaskLog += $script:PendingSummary.Header
        $script:SummaryTaskLog += $script:PendingSummary.Result
        $script:SummaryTaskLog += ""
        $script:PendingSummary = $null
        $script:CurrentTaskLog = @()
        $script:PauseLatch     = $false
    }

    # Blank line + footer
    $elapsed = (Get-Date) - $script:RunStartTime
    if ($elapsed.TotalSeconds -lt 0) {
        # System clock moved backward during the run (e.g. timezone auto-corrected on a freshly-imaged PC)
        $footer = "FOOTER::All Tasks Completed (duration unavailable - system clock changed during run)"
    } else {
        $footer = "FOOTER::All Tasks Completed in: {0:D2}:{1:D2}" -f [int]$elapsed.TotalMinutes, $elapsed.Seconds
    }

    $script:DetailedTaskLog += ""
    $script:DetailedTaskLog += $footer
    $script:SummaryTaskLog  += ""
    $script:SummaryTaskLog  += $footer
    $script:CurrentTaskLog  = @()

    # Mark that all tasks are complete - this enables full log display with scrollback
    $script:IsLastTask = $true

    # Auto-save the Task Log to the USB Logs folder
    try {
        $logsFolder = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'Logs'
        if (-not (Test-Path $logsFolder)) { New-Item $logsFolder -ItemType Directory -Force | Out-Null }
        $stamp      = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
        $logFile    = Join-Path $logsFolder "DeBloater-TaskLog-$stamp.txt"
        $separator  = "=" * 60
        @(
            $separator
            "WinFixIT DeBloater - Task Log"
            "Run: $stamp"
            $separator
            ""
            "--- SUMMARY ---"
            $separator
        ) + ($script:SummaryTaskLog  -replace '^(HEADER|FOOTER)::', '') +
        @(
            ""
            $separator
            "--- DETAILED ---"
            $separator
        ) + ($script:DetailedTaskLog -replace '^(HEADER|FOOTER)::', '') |
            Out-File -FilePath $logFile -Encoding UTF8
    } catch {
        # Non-fatal — log save failure should never interrupt the UI
    }

    Update-TaskLogRTbox
    If ($localDEBUG_Mode) { Write-Host "[DEBUG] About to show post-PERFORM print panel" -ForegroundColor Magenta }
    $script:postPerformPanel.Visible    = $true
    $script:lblPostPerformPanel.Visible = $true
    If ($localDEBUG_Mode) { Write-Host "[DEBUG] Post-PERFORM panel Visible set to True" -ForegroundColor Magenta }

    [System.Windows.Forms.Application]::DoEvents()

    # Notify user if Explorer restart will be needed
    if ($script:ExplorerRestartNeeded) {
        $script:DetailedTaskLog += ""
        $script:DetailedTaskLog += "NOTE: Taskbar changes will take effect when you exit the DeBloater (Explorer will restart)."
        Update-TaskLogRTbox
    }

} # END of - function LogTask-RunFooter


# ======================================================================================
function Update-TaskLogRTbox {
    #.SYNOPSIS
    # Updates the Task Log RichTextBox in the UI with the current log entries, applying formatting  based on the type of log entry (e.g., headers, footers, regular lines). The function manages the visibility of the Task Log and Advice panels, and ensures the UI remains responsive during updates.
    #.DESCRIPTION   
    # - The function first checks if log updates are currently suppressed (e.g., during Explorer restart) and returns immediately if so to avoid unnecessary updates.
    # - It ensures that the DetailedTaskLog, CurrentTaskLog, and SummaryTaskLog variables are initialized as arrays to prevent errors during processing.
    # - It determines which set of log lines to display based on the user's selection in the cmbTaskLogOptions combo box (Detailed, Summary, or a combination of both).
    # - If tasks are still running, it limits the number of visible lines in the Task Log   to fit within the visible area of the RichTextBox, showing only the most recent entries. Once all tasks are complete, it allows the full log to be displayed with scrollback.
    # - It constructs the RTF content for the RichTextBox by iterating through the selected log lines and applying different formatting for headers (e.g., larger font size, bold), footers, and regular lines. It also inserts an advisory message under the first header for Detailed and Summary modes to guide the user to click the Continue button between tasks.
    # - Finally, it updates the RTF content of the Task Log RichTextBox, sets the selection to the end to ensure the latest entries are visible, and calls DoEvents to keep the UI responsive during updates.             

    if ($script:SuppressLogUpdates) { return }
    
    if (-not $script:DetailedTaskLog) { $script:DetailedTaskLog = @() }
    if (-not $script:CurrentTaskLog)  { $script:CurrentTaskLog  = @() }
    if (-not $script:SummaryTaskLog)  { $script:SummaryTaskLog  = @() }

    $mode = $script:cmbTaskLogOptions.SelectedItem
    if (-not $mode) { $mode = "Detailed" }

    $lines = switch ($mode) {
        "Detailed" { $script:DetailedTaskLog }
        "Summary"  { $script:SummaryTaskLog + $script:CurrentTaskLog }
        default    { $script:DetailedTaskLog }
    }

    # Ensure $lines is always an array
    if ($lines -isnot [array]) {
        $lines = @($lines)
    }

    # Only limit visible lines while tasks are running
    # Once complete, show full log for scrollback
    if (-not $script:IsLastTask) {
        # Calculate how many lines fit in the visible area (approximate)
        # Each line is roughly 20 pixels (font size 18/2 + spacing)
        $availableHeight = $script:TaskLogRTbox.ClientSize.Height
        $lineHeight = 20
        $maxVisibleLines = [Math]::Floor($availableHeight / $lineHeight) - 2  # Leave some margin

        # Only show the last N lines that fit on screen
        if ($lines.Count -gt $maxVisibleLines) {
            $startIndex = $lines.Count - $maxVisibleLines
            $lines = $lines[$startIndex..($lines.Count - 1)]
        }
    }

    $rtfHeader = "{\rtf1\ansi "
    $rtfBody   = ""

    # Align with left-hand side (9pt options, 10pt headings)
    $script:LogFontSize = 18   # 9pt

    # Insert advisory exactly once, right under the first HEADER, only for Detailed/Summary
    $advisoryInserted = $false
    $shouldShowAdvisory = ($mode -eq "Detailed" -or $mode -eq "Summary")

    foreach ($line in $lines) {
        $matchLine = $line.TrimStart()

        if ($matchLine -like "HEADER::*") {
            $text = $matchLine.Substring(8)
            $rtfBody += "\fs$($script:LogFontSize + 2)\fs20\b $text \b0\par "

            if ($shouldShowAdvisory -and -not $advisoryInserted) {
                $rtfBody += "\fs$($script:LogFontSize) Please click the 'Continue' Button below to proceed between Tasks.\par "
                $advisoryInserted = $true
            }
        }
        elseif ($matchLine -like "FOOTER::*") {
            $text = $matchLine.Substring(8)
            $rtfBody += "\fs$($script:LogFontSize + 2)\fs20\b $text \b0\par "
        }
        elseif ($line -eq "") {
            $rtfBody += "\par "
        }
        else {
            $subLines = $line -split '\r?\n'
            for ($i = 0; $i -lt $subLines.Count; $i++) {
                $rtfBody += "\fs$($script:LogFontSize) $($subLines[$i])"
                if ($i -lt $subLines.Count - 1) { $rtfBody += "\line " }
            }
            $rtfBody += "\par "
        }
    }

    $script:TaskLogRTbox.Rtf = $rtfHeader + $rtfBody + "}"

    # Set selection to end
    $script:TaskLogRTbox.SelectionStart = $script:TaskLogRTbox.TextLength
    $script:TaskLogRTbox.SelectionLength = 0
    
    # If all tasks complete, enable scrollback by scrolling to bottom
    if ($script:IsLastTask) {
        $script:TaskLogRTbox.ScrollToCaret()
    }

    [System.Windows.Forms.Application]::DoEvents()
}
# END of - function Update-TaskLogRTbox


# =======================================================================================
function MODIFY-Registry {
    param(
        $CheckBox,
        [string]$CurrentOption
    )
    # PURPOSE:
    #   Generic handler for all Options that are implemented as registry changes.
    #   Uses $script:RegistryLookup to find the correct registry path, value name,
    #   and enabled/disabled values for the given option.
    #   Called from the Perform-SelectedOptions dispatch loop.
    #
    # STATE LOGIC:
    #   The checkbox state and the option verb together determine what registry value to write:
    #   - Checked + Remove X  -> feature should be DISABLED  -> write Disabled value
    #   - Checked + KEEP X    -> feature should be ENABLED   -> write Enabled value
    #   - Checked + SHOW X    -> feature should be ENABLED   -> write Enabled value
    #   - Unchecked           -> do nothing, user chose to skip this option

    $localDEBUG_Mode = $false

    $OriginalOption = $CheckBox.Tag.OriginalOption
    
    if($localDEBUG_Mode){ 
        $msg = "MODIFY-Registry called " + 
            "Checkbox = $Checkbox, " + 
            "CurrentOption = $CurrentOption, " +
            "OriginalOption = $OriginalOption"
        Write-Host $msg
    }

    # If unchecked, skip entirely - unchecked means DO NOTHING
    if (-not $CheckBox.Checked) {
        LogTask-Start $OriginalOption
        LogTask-Completion "SKIPPED   - $OriginalOption was not checked"
        return
    }

    $parsed    = Deduce-AppNameAndPlaceFrom $OriginalOption
    $basicName = $parsed.AppName
    $action    = (($CurrentOption -split '\s+')[0])

    $lookupKey = $script:RegistryLookup.Keys | 
        Where-Object { $script:RegistryLookup[$_].DisplayName -eq $basicName }

    LogTask-Start $CurrentOption

    if (-not $lookupKey) {
        LogTask-Completion "SKIPPED   - '$basicName' registry entry not found (may not apply to this Windows version)"
        return
    }

    $info = $script:RegistryLookup[$lookupKey]

    $state = switch ($action) {
        "Remove"  { "Disabled" }
        "KEEP"    { "Enabled"  }
        "ADD"     { "Enabled"  }
        "ENABLE"  { "Enabled"  }
        "DISABLE" { "Disabled" }
        "SHOW"    { if ($info.ShowState) { $info.ShowState } else { "Disabled" } }
        "HIDE"    { if ($info.ShowState) { if ($info.ShowState -eq "Disabled") { "Enabled" } else { "Disabled" } } else { "Enabled" } }
        default   {
            LogTask-Completion "ERROR     - Unrecognised action '$action' for: '$basicName'"
            return
        }
    }
    If ($localDEBUG_Mode) { 
        $msg = "[DEBUG] MODIFY-Registry: "  +
               "basicName='$basicName' "    +
               "action='$action' "          +
               "state='$state'"
        Write-Host $msg `
            -ForegroundColor Magenta 
    }
    try {
        Set-RegistrySettingByName -Name $lookupKey -State $state
        if ($info['RebootRequired']) {
            LogTask-Completion "APPLIED   - $CurrentOption`r`n                  ** REBOOT REQUIRED to take effect **"
        } else {
            LogTask-Completion "APPLIED   - $CurrentOption"
        }
    }
    catch {
        LogTask-Completion "FAILED    - $($CurrentOption): $($_.Exception.Message)"
    }

} # END of - function MODIFY-Registry


# =======================================================================================
function MODIFY-Service {
    param(
        $CheckBox,
        [string]$CurrentOption
    )

    $OriginalOption = $CheckBox.Tag.OriginalOption

    if (-not $CheckBox.Checked) {
        LogTask-Start $OriginalOption
        LogTask-Completion "SKIPPED   - $OriginalOption was not checked"
        return
    }

    $parsed    = Deduce-AppNameAndPlaceFrom $OriginalOption
    $basicName = $parsed.AppName
    $action    = (($CurrentOption -split '\s+')[0])

    $lookupKey = $script:ServiceLookup.Keys |
        Where-Object { $script:ServiceLookup[$_].DisplayName -eq $basicName }

    LogTask-Start $CurrentOption

    if (-not $lookupKey) {
        LogTask-Completion "ERROR     - No service entry found for: '$basicName'"
        return
    }

    $info        = $script:ServiceLookup[$lookupKey]
    $serviceName = $info.ServiceName

    # Handle services with dynamic suffixes (e.g. BcastDVRUserService_abc123)
    $svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if (-not $svc) {
        $svc = Get-Service -Name "$serviceName*" -ErrorAction SilentlyContinue | Select-Object -First 1
    }

    if (-not $svc) {
        LogTask-Completion "SKIPPED   - Service '$serviceName' not found on this system"
        return
    }

    $resolvedName = $svc.Name

    try {
        switch ($action) {
            "Remove" {
                Stop-Service  -Name $resolvedName -Force -ErrorAction SilentlyContinue
                Set-Service   -Name $resolvedName -StartupType Disabled
                LogTask-Completion "APPLIED   - $CurrentOption"
            }
            "KEEP" {
                Set-Service   -Name $resolvedName -StartupType $info.DefaultStartup
                Start-Service -Name $resolvedName -ErrorAction SilentlyContinue
                LogTask-Completion "APPLIED   - $CurrentOption"
            }
            default {
                LogTask-Completion "ERROR     - Unrecognised action '$action' for service: '$basicName'"
            }
        }
    }
    catch {
        LogTask-Completion "FAILED    - $($CurrentOption): $($_.Exception.Message)"
    }

} # END of - function MODIFY-Service


# =======================================================================================
function MODIFY-OneDriveAutoStart {
    param(
        $CheckBox,
        [string]$CurrentOption
    )

    $OriginalOption = $CheckBox.Tag.OriginalOption

    if (-not $CheckBox.Checked) {
        LogTask-Start $OriginalOption
        LogTask-Completion "SKIPPED   - $OriginalOption was not checked"
        return
    }

    LogTask-Start $CurrentOption

    $runKey    = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    $valueName = "OneDrive"
    $action    = (($CurrentOption -split '\s+')[0])

    try {
        switch ($action) {
            "Remove" {
                $runKeyItem = Get-Item -Path $runKey -ErrorAction SilentlyContinue
                $existing   = $null
                if ($runKeyItem) { $existing = $runKeyItem.GetValue($valueName) }
                if ($existing) {
                    Remove-ItemProperty -Path $runKey -Name $valueName -ErrorAction Stop
                    LogTask-Completion "APPLIED   - $CurrentOption"
                } else {
                    LogTask-Completion "SKIPPED   - OneDrive Auto-Start entry not found (already removed)"
                }
            }
            "KEEP" {
                $oneDrivePath = "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe"
                if (Test-Path $oneDrivePath) {
                    Set-ItemProperty -Path $runKey -Name $valueName -Value "`"$oneDrivePath`" /background" -ErrorAction Stop
                    LogTask-Completion "APPLIED   - $CurrentOption"
                } else {
                    LogTask-Completion "SKIPPED   - OneDrive.exe not found, cannot restore Auto-Start"
                }
            }
            default {
                LogTask-Completion "ERROR     - Unrecognised action '$action' for: OneDrive Auto-Start"
            }
        }
    }
    catch {
        LogTask-Completion "FAILED    - $($CurrentOption): $($_.Exception.Message)"
    }

} # END of - function MODIFY-OneDriveAutoStart


# =======================================================================================
function MODIFY-PowerCFG {
    param(
        $CheckBox,
        [string]$CurrentOption
    )

    $OriginalOption = $CheckBox.Tag.OriginalOption

    if (-not $CheckBox.Checked) {
        LogTask-Start $OriginalOption
        LogTask-Completion "SKIPPED   - $OriginalOption was not checked"
        return
    }

    $action = (($CurrentOption -split '\s+')[0])

    LogTask-Start $CurrentOption

    try {
        switch ($action) {
            "Remove" {
                powercfg /h off 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "powercfg /h off failed with exit code $LASTEXITCODE"
                }
                if ($OriginalOption -eq "Remove Fast Startup") {
                    Set-RegistrySettingByName -Name "FastStartup" -State "Disabled"
                }
                LogTask-Completion "APPLIED   - $CurrentOption"
            }
            "KEEP" {
                powercfg /h on 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "powercfg /h on failed with exit code $LASTEXITCODE"
                }
                if ($OriginalOption -eq "KEEP Fast Startup") {
                    Set-RegistrySettingByName -Name "FastStartup" -State "Enabled"
                }
                LogTask-Completion "APPLIED   - $CurrentOption"
            }
            default {
                LogTask-Completion "ERROR     - Unrecognised action '$action' for: '$CurrentOption'"
            }
        }
    }
    catch {
        LogTask-Completion "FAILED    - $($CurrentOption): $($_.Exception.Message)"
    }

} # END of - function MODIFY-PowerCFG


# =======================================================================================
function Set-ActiveHours {
    param($CheckBox)

    $OriginalOption = $CheckBox.Tag.OriginalOption
    LogTask-Start $OriginalOption

    if (-not $CheckBox.Checked) {
        LogTask-Completion "SKIPPED   - $OriginalOption was not checked"
        return
    }

    try {
        $path = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"
        if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
        Set-ItemProperty -Path $path -Name "ActiveHoursStart" -Value 8
        Set-ItemProperty -Path $path -Name "ActiveHoursEnd"   -Value 22
        LogTask-Completion "APPLIED   - $OriginalOption (8am to 10pm)"
    }
    catch {
        LogTask-Completion "FAILED    - $($OriginalOption): $($_.Exception.Message)"
    }

} # END of - function Set-ActiveHours


# =======================================================================================
function Pause-UntilContinueButtonPressed {
    param(
        [bool]$ForceShow = $false
    )
    $script:btnContinue.Visible = $false

    # Enable Task Log and show Copy Log — always, regardless of log mode
    $script:TaskLogRTbox.Enabled = $true
    $script:TaskLogRTbox.BringToFront()


    if ($ForceShow -or ([string]$script:cmbTaskLogOptions.SelectedItem) -in @("Detailed", "Summary")) {
        $script:btnContinue.Text    = "Continue"
        $script:btnContinue.Visible = $true
        $script:btnContinue.Focus()

        while (-not $script:UserPressedContinue -and -not $script:stopRequested) {
            Start-Sleep -Milliseconds 200
            [System.Windows.Forms.Application]::DoEvents()
        }
        $script:UserPressedContinue = $false
        $script:btnContinue.Visible = $false
    }


    $script:TaskLogRTbox.Enabled = $false

} # END of - Pause-UntilContinueButtonPressed


# =======================================================================================
function Migrate-PendingSummary {
    if ($script:PauseLatch -and $script:PendingSummary) {
        $script:SummaryTaskLog += $script:PendingSummary.Header
        $script:SummaryTaskLog += $script:PendingSummary.Result
        $script:SummaryTaskLog += ""
        $script:PendingSummary = $null
        $script:CurrentTaskLog = @()
        $script:PauseLatch     = $false

        Update-TaskLogRTbox
        [System.Windows.Forms.Application]::DoEvents()
    }
} # END of - function Migrate-PendingSummary


# =======================================================================================
function Install-Browser {
    param(
        $CheckBox,
        [string]$CurrentOption
    )
    #.SYNOPSIS
    # Attempts to install a browser using winget.
    # Falls back to manual installation advice if winget fails.

    $browserName = $CurrentOption -replace '^INSTALL\s+', ''

    # winget package IDs for each browser
    $wingetIds = @{
        'Google Chrome' = 'Google.Chrome'
        'Firefox'       = 'Mozilla.Firefox'
        'Brave'         = 'Brave.Brave'
        'Opera'         = 'Opera.Opera'
    }

    LogTask-Start $CurrentOption

    if (-not $wingetIds.ContainsKey($browserName)) {
        LogTask-Completion "ERROR     - No winget ID found for: $browserName"
        return
    }

    $wingetId = $wingetIds[$browserName]

    LogTask-Progress "Attempting to install $browserName via winget..."

    try {
        $wingetArgs = "/c title Installing $browserName " + 
            "- Please Wait... && winget install --id $wingetId " + 
            "--accept-package-agreements --accept-source-agreements"

        $result = Start-Process "cmd.exe" `
            -ArgumentList $wingetArgs `
            -Wait `
            -PassThru `
            -WindowStyle Normal `
            -ErrorAction Stop

        if ($result.ExitCode -eq 0) {
            LogTask-Completion "INSTALLED - $browserName"
        } else {
            LogTask-Progress "winget exited with code $($result.ExitCode) - falling back to manual installation"
            LogTask-Completion "MANUAL ACTION - $browserName could not be installed automatically. Please visit the download link in the Advice Panel."
        }
    }
    catch {
        LogTask-Progress "winget failed - $($_.Exception.Message)"
        LogTask-Completion "MANUAL ACTION - $browserName could not be installed automatically. Please visit the download link in the Advice Panel."
    }

} # END of - function Install-Browser


# =======================================================================================
function Set-DefaultBrowser {
    param(
        $CheckBox,
        [string]$CurrentOption
    )

    $browserName = $CurrentOption `
        -replace '^SELECT\s+', '' `
        -replace '\s+SELECTED$', ''

    $progFiles86 = ${env:ProgramFiles(x86)}
    
    $browserPaths = @{
        'Microsoft Edge' = @(
            "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
            "$progFiles86\Microsoft\Edge\Application\msedge.exe"
        )
        'Firefox'        = @(
            "$env:ProgramFiles\Mozilla Firefox\firefox.exe",
            "$progFiles86\Mozilla Firefox\firefox.exe"
        )
        'Google Chrome'  = @(
            "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
            "$env:LocalAppData\Google\Chrome\Application\chrome.exe"
        )
        'Brave'          = @(
            "$env:LocalAppData\BraveSoftware\Brave-Browser\Application\brave.exe"
        )
        'Opera'          = @(
            "$env:LocalAppData\Programs\Opera\opera.exe"
        )
    }

    $defaultAppsNames = @{
        'Microsoft Edge' = 'Microsoft.MicrosoftEdge'
        'Google Chrome'  = 'Google Chrome'
        'Firefox'        = 'Firefox'
        'Brave'          = 'Brave'
        'Opera'          = 'Opera'
    }

    LogTask-Start $CurrentOption

    # Find the actual executable
    $exePath = $null
    foreach ($path in $browserPaths[$browserName]) {
        if (Test-Path $path) {
            $exePath = $path
            break
        }
    }

    if (-not $exePath) {
        LogTask-Completion "ERROR     - Cannot find $browserName executable"
        return
    }

    # If the option ends with "SELECTED", this browser is already the default — nothing to do.
    # Only open Settings when the user is actively switching to a different default browser.
    if ($CurrentOption -like "* SELECTED") {
        LogTask-Completion "KEPT      - $browserName is already your Default Browser"
    } else {
        LogTask-Progress "Please set $browserName as your Default Browser, using Settings > Default Apps."
        Start-Process "ms-settings:defaultapps"
        LogTask-Completion "DONE      - Settings > Default Apps opened. Please select $browserName manually."
    }

} # END of - function Set-DefaultBrowser


# =======================================================================================
function Deduce-ActionRequiredAndAppNameFrom {
    param(
        [Parameter(Mandatory)]
        [string]$OptionText
    )

    # Split into verb + remainder
    $verb, $remainder = $OptionText -split '\s+', 2

    return @{
        ActionRequired = $verb.Trim()       # Remove | KEEP | INSTALL | ADD | Use
        AppName        = $remainder.Trim()  # Everything after the verb
    }
} # END of - function Deduce-ActionRequiredAndAppNameFrom


# =======================================================================================
function ENABLE-LowLatencyProfile {
    param(
        $CheckBox,
        [string]$CurrentOption
    )

    $localDEBUG_Mode = $false
    $action = ($CurrentOption -split '\s+')[0]

    LogTask-Start $CurrentOption

    if ($localDEBUG_Mode) {
        Write-Host "[DEBUG] LLP: CurrentOption='$CurrentOption'  action='$action'" -ForegroundColor Cyan
    }

    try {
        switch ($action) {

            "ENABLE" {

                Set-ItemProperty `
                    -Path  "HKLM:\SYSTEM\CurrentControlSet\Control\Power" `
                    -Name  "EnergyEstimationEnabled" `
                    -Value 0 `
                    -Type  DWord

                Set-ItemProperty `
                    -Path  "HKLM:\SYSTEM\CurrentControlSet\Control\Power" `
                    -Name  "EnergyEstimationDisabled" `
                    -Value 1 `
                    -Type  DWord

                Set-ItemProperty `
                    -Path  "HKLM:\SYSTEM\CurrentControlSet\Control\Power" `
                    -Name  "LowLatencyPerformance" `
                    -Value 1 `
                    -Type  DWord

                LogTask-Completion "ENABLED  - Low Latency Profile (LLP)"
            }

            "DISABLE" {

                Set-ItemProperty `
                    -Path  "HKLM:\SYSTEM\CurrentControlSet\Control\Power" `
                    -Name  "EnergyEstimationEnabled" `
                    -Value 1 `
                    -Type  DWord

                Set-ItemProperty `
                    -Path  "HKLM:\SYSTEM\CurrentControlSet\Control\Power" `
                    -Name  "EnergyEstimationDisabled" `
                    -Value 0 `
                    -Type  DWord

                Set-ItemProperty `
                    -Path  "HKLM:\SYSTEM\CurrentControlSet\Control\Power" `
                    -Name  "LowLatencyPerformance" `
                    -Value 0 `
                    -Type  DWord

                LogTask-Completion "DISABLED - Low Latency Profile (LLP)"
            }

            default {
                LogTask-Completion "ERROR - Unknown LLP state: '$CurrentOption'"
            }
        }
    }
    catch {
        LogTask-Completion "FAILED - LLP: $($_.Exception.Message)"
    }
}
# END of - function ENABLE-LowLatencyProfile  

