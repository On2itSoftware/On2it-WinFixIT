<# INSTALL-Windows.ps1
   =================
       Purpose: This script:
                    - Explains Windows Installation Options dependent upon, whether the system was started in Windows or WinPE, and
                    - Stresses the importance of performing a backup, before Installing Windows,
                Then, dependent upon circumstances, offers the User the choice of:
                    - FULL Install,
                    - BYPASS Install,
                    - Re-running the Windows11 Compatibility Checker, or
                    - <Return> so that they can re-start their machine.
                    
        Method: - Reads 'Win11-INSTALL.rtf' file, to determine the Choice the User made in Win11-CompatibilityCheckwer-UserAdvice.ps1
                - Reads Scripts\Win11-INSTALL.rtf file,
                - Displays Installation Options and reminds User to Take BACKUP,
                - displays somewhat differing options when;
                    - Boooted from USB, or
                    - run from within Widows.
                - Displays content of Install\Windows\ISO Descriptions.txt
                  from the On2it-WinFixIT Partition
                - Allows the User to select the ISO to perform either a:
                    - FULL Install, that uses Windows 11's enhanced security,
                    - BYPASS Install, that bypasses those security feature 
                - If they are running in a full Windows OS they will also get the choice of
                  the installation Type they want: whether to:
                    - KEEP their files, apps and settings; or just keep",
                    - PERSONAL files only, remove apps and reset settings.",
                    - CLEAN Install - wiping all files, apps, and settings.",
                - if they are running in WinPE, because they booted from the USB, then only a
                    - CLEAN Install, is available, So, they will not be offered a choice.
                - they will also be offered the opportunity of:
                    - running the Windows11 Compatibility Checker, 
                    - or <Return> 
                If they proceed to an actual install, Install-SelectedWindowsISO will:
                    - Install the ISO Selected 
                    - with the Installation Type reqested
                What was actually installed is then recorded in the 
                On2it-WinFixIT INSTALL\Logs\Win11-CompatibilityChecker-Results.txt file

   Designed by: Brian McGuigan
            of: On2it Software ltd
       Code by: Copilot & Claude
       Version: 3 (Install-SelectedWindowsISO now shows a Show-RemoveUSBWarning
                screen immediately before launching Setup, in all three launch
                paths -- confirmed for real, 2026-10-17, against a live
                Test-PC install: Setup reboots partway through to continue
                from the hard disk, and if the BIOS boot order still has the
                USB first -- needed in the first place to reach WinPE/WinFixIT
                on a machine with no existing OS -- that reboot boots back into
                the USB and lands on WinFixIT's own Introduction screen instead
                of continuing Setup, which looks like the install vanished.
                Removing the USB (or fixing the boot order) and letting the PC
                boot the internal disk lets Setup continue exactly where it
                left off -- nothing is lost -- but a user who doesn't know this
                will be confused, hence the warning. Version 2's registry-keys
                fix for the BYPASS mechanism itself is now confirmed working
                end-to-end, Test-PC reached "Ready to install" and completed
                the Windows 11 install without the hardware-requirements
                block reappearing.)
         Dated: 17-Oct-26
#>

function INSTALL-Windows {

    $DoNOT_INSTALL = $false# Set to $true to simulate the installation process without actually performing it, 
                            # which is useful for testing and development.

    $Debug_Mode = $false    # Set to $true to enable debug mode, which will output the actions that would be taken instead of executing them. 
                            # This is useful for testing and development to see the flow of the script without making any changes.        

    # Determine USB root and standard folders
    $currentFolder  = Split-Path -Parent $PSCommandPath      # F:\Scripts\WinFixIT
    $ScriptsFolder  = Split-Path -Parent $currentFolder      # F:\Scripts
    $USBroot        = Split-Path -Parent $ScriptsFolder      # F:\

    $usbInfo = Get-USBRoot-And-RequiredFiles `
        -Ps1FileName 'Install Windows.ps1' `
        -RequiredFiles @() `
        -Debug_Mode:$false
    $USB_SecondPartition = $usbInfo.UsbSecondPartition

    Clear-screen

    # 1. Always show Scenario 1: Understanding Installation Options
    # --------------------------------------------------------------
    Display-ScenarioSelected (Get-ScenarioFromUSB `
        -UsbRoot $USBroot `
        -SubFolder 'Scripts\WinFixIT' `
        -RTFfileName 'Install Windows.rtf' `
        -ScenarioPattern '(?i)^\s*\[DISPLAY WHEN\s*[---]\s*Display Installation Options\s*\]'
    )

    Clear-screen

    # 2. Scenario 2: Booted from USB
    # ------------------------------
    if ((Is-OSenvironment-WinPE).IsWinPE) {
        Display-ScenarioSelected (Get-ScenarioFromUSB `
            -UsbRoot $USBroot `
            -SubFolder 'Scripts\WinFixIT' `
            -RTFfileName 'Install Windows.rtf' `
            -ScenarioPattern '(?i)^\s*\[DISPLAY WHEN\s*[---]\s*Booted from USB\s*\]'
        )
    } 
   
    else {
    # 3. Scenario 3: Run from within Windows
    # ---------------------------------------
        Display-ScenarioSelected (Get-ScenarioFromUSB `
            -UsbRoot $USBroot `
            -SubFolder 'Scripts\WinFixIT' `
            -RTFfileName 'Install Windows.rtf' `
            -ScenarioPattern '(?i)^\s*\[DISPLAY WHEN\s*[---]\s*Run from within Windows\s*\]')
    }


    # Alway add TEXT from ISO Descriptions.txt to the bottom of the screen
    # --------------------------------------------------------------------
    # This file contains additional information about the various ISO files on the USB, 
    # that describes the source and any restrictions on them, which may have been imposed,
    # by their Supplier - licencing and so on.
    if (-not $USB_SecondPartition) {
        Write-Warning "On2it-WinFixIT partition not found. Cannot display ISO descriptions."
    }
    else {
        Display-TextFrom `
            -UsbRoot $USB_SecondPartition `
            -SubFolder 'Install\Windows' `
            -TXTfilename 'ISO Descriptions.txt'
    }

    
    # 5. Get users decision - FULL / BYPASS / CHECK
    #    ------------------------------------------
    $SelectedInstallation = Select-InstallationRequired   # returns PSCustomObject with .ISOselected

    $ISOselected = $SelectedInstallation.ISOselected

    If ($Debug_Mode) {
        Write-Host "[DEBUG] User selected ISO='$ISOselected'"
        Start-Sleep -Seconds 5
    }

  # 6. Execute user's decision
    $setupLaunched = $false
    switch ($ISOselected.ToUpper()) {
        'FULL' {
            $isoPath = Join-Path $USB_SecondPartition 'Install\Windows\FULL Install.iso'
            $setupLaunched = Install-SelectedWindowsISO `
                -IsoPath $isoPath `
                -Debug_Mode:$DoNOT_INSTALL
            $ActualMode = "FULL"
        }
        'BYPASS' {
            $isoPath = Join-Path $USB_SecondPartition 'Install\Windows\BYPASS Install.iso'
            $setupLaunched = Install-SelectedWindowsISO `
                -IsoPath $isoPath `
                -ApplyBypassRegistryKeys `
                -Debug_Mode:$DoNOT_INSTALL
            $ActualMode = "BYPASS"
        }
        'CHECK'    { CHECK-Compatibility; return } # CALL the Checker and then EXIT, so that they can re-start the script after checking.
        '<Return>' { return } # User chose to cancel installation, so just EXIT the function, which will return them to the command prompt, where they can re-start the script after checking or when they are ready.
        default    { Write-Host "Invalid choice. Installation cancelled."; return }
    }

    # Only record an outcome if Setup actually launched - confirmed 2026-07-11 (real
    # incident): this used to log "ACTUALLY Installed" unconditionally, so a silent
    # failure (e.g. the AIM driver failing to load in WinPE) still got recorded as a
    # successful install, which was actively misleading when diagnosing what happened.
    if (-not $setupLaunched) {
        return
    }

    # 8. Update existingResults File
    # Results live on the second (On2it-WinFixIT) partition so they survive USB-INSTALL
    # being read-only - fall back to $usbRoot only if that partition wasn't found.
    $resultsRoot = if ($USB_SecondPartition) { $USB_SecondPartition } else { $usbRoot }
    $resultsFile = Join-Path $resultsRoot "Logs\Win11-CompatibilityChecker-Results.txt"

    if (Test-Path -LiteralPath $resultsFile) {
        # Strip any old outcome lines
        $lines = Get-Content -LiteralPath $resultsFile | Where-Object {
            ($_ -notmatch '^ACTUALLY Installed')
        }
        Set-Content -LiteralPath $resultsFile -Value $lines

        # Append fresh outcome
        $outcomeLines = @(
            "ACTUALLY Installed  - $ActualMode Install"
        )
        Add-Content -LiteralPath $resultsFile -Value $outcomeLines
    }
    else {
        # No $resultsFile exists - So, create one with just the Outcome.
        $newFileLines = @(
            "Windows11 Installation Outcome for - $env:COMPUTERNAME"
            "========================================================"
            " "
            "[NOTE] User did not run Compatibility Checker or seek advice before installing."
            " "
            "ACTUALLY Installed  - $ActualMode Install"
        )
        Set-Content -LiteralPath $resultsFile -Value $newFileLines
    }

} # END of - INSTALL-Windows

# =================================================================================
# function Select-InstallationRequired
# =================================================================================
# This function prompts the user to select whether they want to do a:
#    - FULL Install, a
#    - BYPASS Install, or
#    - CHECK Compatibility, or
#    - <Return>.
#
# The function also checks whether the user has already run the Compatibility Checker 
# and made a choice, by looking for the 'Win11-CompatibilityChecker-Results.txt' file on the USB, 
# and if it finds a previous choice, it offers to repeat that choice or try the other option.
#
# It returns a PSCustomObject with one property:
#   $.ISOselected (FULL, BYPASS, CHECK, or <Return>).
#
function Select-InstallationRequired {
    [CmdletBinding()]
    param (
        [switch]$Debug_Mode
    )

    [string]$ISOselected = $null

    # --- Detect Compatibility Checker results ---
    $resultsFile = 'Win11-CompatibilityChecker-Results.txt'

    # Results live on the second (On2it-WinFixIT) partition. On a real USB that's its
    # own drive root, so the broad drive scan below finds it; in Development it's a
    # subfolder of D:, not a drive root, so check it directly first.
    $usbRoot = if ($usbSecondPartition -and (Test-Path (Join-Path $usbSecondPartition "Logs\$resultsFile"))) {
        $usbSecondPartition
    } else {
        Get-PSDrive -PSProvider FileSystem |
            Where-Object { Test-Path (Join-Path $_.Root "Logs\$resultsFile") } |
            Select-Object -First 1 -ExpandProperty Root
    }

    if ($usbRoot) {
        $ISOalreadySelected = Get-Content -LiteralPath (Join-Path $usbRoot "Logs\$resultsFile") |
            Where-Object { $_ -match '\S' } | Select-Object -Last 1

        # Strip "USER Chose - " prefix if present
        if ($ISOalreadySelected -match '^USER Chose\s*-\s*(.+)$') {
            $ISOalreadySelected = $matches[1]
        }
        # Treat <Return> as no choice made
        if ($ISOalreadySelected -eq '<Return>') {
            $ISOalreadySelected = $null
        }
    }
   
    if ($ISOalreadySelected -eq "FULL") {
        $OptionNotSelected = "BYPASS"
    }
    elseif ($ISOalreadySelected -eq "BYPASS") {
        $OptionNotSelected = "FULL"
    }
    else {
        # Treat as though never tested or cancelled
        $ISOalreadySelected = $null
    }

    $InWinPE = (Is-OSenvironment-WinPE).IsWinPE

    # SOFTWARE TESTING BLOCK - to simulate different scenarios - uncomment as needed
    # ==============================================================================
    # $ISOalreadySelected = "FULL"   # Simulate previous FULL install choice
    # $ISOalreadySelected = "BYPASS" # Simulate previous BYPASS install choice
    # $ISOalreadySelected = $null    # Simulate no previous choice (never tested or cancelled)
    # $InWinPE = $true               # Simulate being in WinPE environment   
    # $InWinPE = $false              # Simulate being in full Windows environment
    # $Debug_Mode = $false              # Simulate Debug Mode (no actual install)
    # ==============================================================================

    # Branch 1: Compatibility already Checked and FULL or BYPASS already Selected - TESTED
    # ===========================================================================
    if ($ISOalreadySelected) {
        Write-Host ""
        $PromptRows = @(
            "$Y You have already Compatibility Checked this PC and chosen to do a '$ISOalreadySelected Install'.",
            " ",
            "$Y Would you like to do a '$ISOalreadySelected Install' right NOW?${Reset}"
        ) 
        $Response = Prompt-ForUserChoice `
            -PromptRows $PromptRows `
            -ValidChoices @('Y','N')
 
        if ($Response -match '^[Yy]$') {
            $ISOselected = $ISOalreadySelected
        }
        else {
             $Response = Prompt-ForUserChoice `
                -PromptRows "$Y Would you like to do a '$OptionNotSelected Install' instead, right NOW?${Reset}" `
                -ValidChoices @('Y','N') `
                -OverwritePreviousPrompt

            if ($Response -match '^[Yy]$') {
                $ISOselected = $OptionNotSelected
            }
            else {
                $ISOselected = '<Return>'
            }
        }
        if ($Debug_Mode) {
            Write-Host "[DEBUG] After Branch 1, ISOselected = '$ISOselected'"
            Start-Sleep -Seconds 5
        }
    }

    # Branch 2: Compatibility Checker not yet run or cancelled   - TESTED
    # ========================================================
    else {
        $PromptRows = @(
            "$Y You have not yet run the Windows 11 Compatibility Checker. ",
            "$Y Would you like to do so NOW?${Reset}"
        ) 
        $Response = Prompt-ForUserChoice `
            -PromptRows $PromptRows `
            -ValidChoices @('Y','N') `
            -OverwritePreviousPrompt
 

        # If they want to run the Checker, 
        if ($Response -match '^[Yy]$') {
            # and they are in WinPE, 
            if ($InWinPE) {
                # warn them about inconclusive results and ask them to confirm
                $PromptRows = @(
                    "$C You realise, that if you run the Windows 11 Compatibility Checker right NOW, it WILL produce ",
                    " inconclusive results.  So, you will ALWAYS be advised to run a$Y 'BYPASS Install'$C - to be safe.",
                    " ",
                    " If you want to be really sure whether your machine will be able to take a$Y 'FULL Install' $C ",
                    ' of Windows 11, you should answer "N" to the next question.' + ${Reset},
                    "$Y Are you ABSOLUTELY SURE you want to run the Compatibility Checker NOW?${Reset}"
                )
                $Response = Prompt-ForUserChoice `
                    -PromptRows $PromptRows `
                    -ValidChoices @('Y','N') `
                    -OverwritePreviousPrompt

                if ($Response -match '^[Yy]$') { $ISOselected = 'CHECK' }
            }
        } 
    }

    # Branch 3: If Insallation not already CANCEled AND User has decided NOT to CHECK Compatibility
    # --------------------------------------------------------------------------------------------
    If (($null -eq $ISOalreadySelected) -and ($ISOselected -ne "<Return>") -and ($ISOselected -ne "CHECK")) {
        # Ask whether they would like to install windows 11 instead
        $PromptRows = @(
            "$Y Would you like to install Windows 11 NOW, anyway?${Reset}"
        )
    
        $Response = Prompt-ForUserChoice `
            -PromptRows $PromptRows `
            -ValidChoices @('Y','N') `
            -OverwritePreviousPrompt
             
        if ($Response -match '^[Nn]$') { $ISOselected = '<Return>' } # TESTED
    }

    # Branch 4: User Decision - TESTED
    # ====================================
    if (($null -eq $ISOselected) `
        -or ($ISOselected -eq "")) 
        {
        $PromptRows = @(
            "$W You must first decide whether you want to do a:${Reset}",
            "$W   - FULL Install${Reset} that uses Windows 11's enhanced security, or a",
            "$W   - BYPASS Install${Reset} that bypasses those security features, because your PC does not support them.",
            " ",
            " If you are uncertain of your PC's capabilities, please answer$Y CHECK${Reset} below.",
            " Please enter either:$Y FULL${Rst},$Y BYPASS${Rst},$Y CHECK${Rst} or just <Return> :"
        )
        $Response = Prompt-ForUserChoice `
            -PromptRows $PromptRows `
            -ValidChoices @('FULL','BYPASS','CHECK','') `
            -OverwritePreviousPrompt `
            -ReturnKey_Pressed '<Return>' `
            -SuppressChoices # From being appended to end of prompt

        if ($Response -ne '<Return>') {
            $ISOselected = $Response.Trim().ToUpper()
        } else {
            $ISOselected = '<Return>'
        }
    }

    # At this point $ISOselected should be FULL, BYPASS, CHECK, or <Return>
    
If ($Debug_Mode) {
    Write-Host "[DEBUG] Final ISOselected = '$ISOselected'"
    Start-Sleep -Seconds 5             
}
    return [PSCustomObject]@{
        ISOselected = $ISOselected
    }

}  # END of - function Select-InstallationRequired

# =================================================================================
# function Set-Windows11BypassRegistryKeys
# =================================================================================
#          Purpose: Sets the exact registry values Windows 11 Setup's hardware
#                   compatibility check actually reads, for a BYPASS Install.
#
#           Method: Traced from Rufus's own source (res/setup/setup.c, Pete
#                   Batard, GPL-3.0 -- same licence as this repo, same author
#                   as the vendored Fido.ps1). For Windows 11 builds 26000+
#                   (covers both 25H2, build 26200, and 26H2, build 26300),
#                   deleting or emptying sources\appraiserres.dll is no longer
#                   enough on its own -- the real check still runs, it just
#                   needs these registry values present first, so it reads
#                   them as genuine hardware readings and reports "compliant"
#                   regardless of actual hardware. Clears a few stale
#                   AppCompatFlags cache keys first, in case a previous
#                   blocked attempt left markers behind -- same as Rufus does.
#
#       Written by: Brian McGuigan
#               of: On2it Software Ltd
#          Code by: Claude
#          Version: 1
#             Date: 17-Oct-2026
function Set-Windows11BypassRegistryKeys {
    [CmdletBinding()]
    param ()

    $compatFlagsBase = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags'

    foreach ($staleKey in 'CompatMarkers', 'Shared', 'TargetVersionUpgradeExperienceIndicators') {
        $path = Join-Path $compatFlagsBase $staleKey
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $hwReqChkPath = Join-Path $compatFlagsBase 'HwReqChk'
    if (-not (Test-Path -LiteralPath $hwReqChkPath)) {
        New-Item -Path $hwReqChkPath -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $hwReqChkPath -Name 'HwReqChkVars' -Type MultiString -Value @(
        'SQ_SecureBootCapable=TRUE'
        'SQ_SecureBootEnabled=TRUE'
        'SQ_TpmVersion=2'
        'SQ_RamMB=8192'
    )

    $moSetupPath = 'HKLM:\SYSTEM\Setup\MoSetup'
    if (-not (Test-Path -LiteralPath $moSetupPath)) {
        New-Item -Path $moSetupPath -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $moSetupPath -Name 'AllowUpgradesWithUnsupportedTPMOrCPU' -Type DWord -Value 1

}  # END of - function Set-Windows11BypassRegistryKeys

# =================================================================================
# function Show-RemoveUSBWarning
# =================================================================================
#          Purpose: Warns the User, immediately before Setup is launched, that
#                   Windows Setup will reboot the PC partway through
#                   installation to continue from the hard disk -- and that if
#                   this USB stick is still plugged in with the BIOS boot
#                   order favouring USB, that reboot will boot back into the
#                   USB and land on WinFixIT's own Introduction screen instead
#                   of continuing the Windows install.
#
#           Method: Confirmed for real, 2026-10-17 (Brian, live Test-PC
#                   install): this happened, looked like the install had been
#                   lost, but removing the USB and letting the PC boot the
#                   internal disk let Setup continue exactly where it left
#                   off -- nothing was actually lost. Requires a keypress so
#                   the User can't miss it before the unattended file-copy
#                   phase begins.
#
#       Written by: Brian McGuigan
#               of: On2it Software Ltd
#          Code by: Claude
#          Version: 1
#             Date: 17-Oct-2026
function Show-RemoveUSBWarning {
    [CmdletBinding()]
    param ()

    Write-Host ""
    Write-Host "$Y IMPORTANT -- before Windows installation begins:$Rst"
    Write-Host ""
    Write-Host "  Partway through, this PC will reboot automatically to"
    Write-Host "  continue installing from the hard disk."
    Write-Host ""
    Write-Host "  If this USB stick is still plugged in -- and your BIOS boot"
    Write-Host "  order still favours it -- that reboot will boot back into"
    Write-Host "  this USB instead of continuing the Windows install. It will"
    Write-Host "  look like the installation has vanished and you're back at"
    Write-Host "  the WinFixIT Introduction screen."
    Write-Host ""
    Write-Host "  If that happens: it's NOT lost. Just remove the USB stick"
    Write-Host "  and let the PC reboot again -- Windows installation will"
    Write-Host "  continue exactly where it left off."
    Write-Host ""
    Write-Host "$Y Press Enter to begin the Windows installation...$Rst" -NoNewline
    $null = Read-Host

}  # END of - function Show-RemoveUSBWarning

# =================================================================================
# function Install-SelectedWindowsISO
# =================================================================================
# This function takes the path to the ISO file and the installation type as parameters,
# mounts the ISO, locates setup.exe, and runs it with the specified installation type.
# After the installation process completes, it dismounts the ISO.  It also logs the steps taken and any errors encountered to a log file on the USB.
# The $Debug_Mode switch can be used to simulate the installation process without actually performing it, which is useful for testing and development.
# When $Debug_Mode is enabled, the function will output the actions it would take instead of executing them.
#
# Note: The actual installation code is currently commented out to prevent accidental execution during testing.  To enable it, simply uncomment the relevant block of code.
# The function also includes error handling to catch and log any issues that arise during the mounting or installation process.
#
# $ApplyBypassRegistryKeys is set by the caller only for a BYPASS Install --
# a FULL Install must never have these keys applied, since it's meant to
# enforce the real requirements.
function Install-SelectedWindowsISO {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$IsoPath,
        [switch]$ApplyBypassRegistryKeys,
        [switch]$Debug_Mode
    )

    $currentFolder = Split-Path -Parent $PSCommandPath   # …\Scripts\WinFixIT
    $ScriptsFolder = Split-Path -Parent $currentFolder   # …\Scripts
    $usbRoot       = Split-Path -Parent $ScriptsFolder   # USB root (e.g. F:\, or X:\ in WinPE)

    $logsFolder = Join-Path $usbRoot 'Logs'
    if (-not (Test-Path $logsFolder)) { New-Item -Path $logsFolder -ItemType Directory -Force | Out-Null }

    $logFile = Join-Path $usbRoot 'Logs\Install-Windows.log'
    Set-Content -Path $logFile -Value $null -ErrorAction SilentlyContinue

    Write-Log -Message "Installing from ISO: $IsoPath /DynamicUpdate disable" -LogFile $logFile

    # Only $true once Setup has actually been launched - every early-return/failure
    # path below leaves this $false, so the caller can tell a genuine install from
    # a silent failure instead of assuming success just because this function returned.
    $setupLaunched = $false

    if (-not (Test-Path -LiteralPath $IsoPath)) {
        Write-Log "ISO file not found: $IsoPath"
        Write-Host ""
        Write-Host "$R Installation FAILED:$Rst ISO file not found."
        Write-Host "  $IsoPath"
        Write-Host ""
        Write-Host "Press Enter to return..." -NoNewline
        $null = Read-Host
        return $setupLaunched
    }

    if ($Debug_Mode) {
        Write-Host "$Y DEBUG MODE: No changes will be made."
        Write-Host " function Install-SelectedWindowsISO would:"
        Write-Host "   - Mount:$W $IsoPath${Rst}, locate setup.exe therein, and "
        Write-Host "   - Run:  $W Setup.exe /DynamicUpdate disable${Rst}"
        Write-Host "   - dismount ISO after completion"
        Start-Sleep -Seconds 30
        return $setupLaunched
    }

    $runningInWinPE = ($env:SystemDrive -eq 'X:' -or $env:SystemRoot -match '^(?i)X:\\Windows')

    if ($runningInWinPE) {

        # Mount-DiskImage is not available in WinPE -- use alternative methods.
        # Option 1: pre-extracted folder alongside the ISO (same name, no .iso extension).
        # Option 2: aim_ll.exe (Arsenal Image Mounter) in Scripts\WinFixIT\Support\ on the USB.
        $extractedFolder = $IsoPath -replace '\.iso$', ''
        $setupExe        = Join-Path $extractedFolder 'setup.exe'

        if (Test-Path $setupExe) {
            Write-Log "WinPE: using pre-extracted Windows files at: $extractedFolder"
            if ($ApplyBypassRegistryKeys) {
                Write-Log "Applying BYPASS registry keys before launching Setup..."
                Set-Windows11BypassRegistryKeys
            }
            Show-RemoveUSBWarning
            Write-Log "LAUNCHING - Windows Setup"
            Write-Log "..."
            Start-Process $setupExe -ArgumentList "/DynamicUpdate disable" -WorkingDirectory $extractedFolder -Wait
            Write-Log "COMPLETED - Windows Setup"
            $setupLaunched = $true
            return $setupLaunched
        }

        # Pre-extracted folder not found -- try aim_ll.exe (Arsenal Image Mounter).
        # Requires three files in Scripts\WinFixIT\Support\ on the USB first partition:
        #   aim_ll.exe    from C:\Program Files\AIM Toolkit\
        #   aimapi.dll    from C:\Program Files\AIM Toolkit\
        #   aimwrfltr.sys from C:\Windows\System32\drivers\
        $utilitiesFolder = Join-Path $usbRoot 'Scripts\WinFixIT\Support'
        $aimLL           = Join-Path $utilitiesFolder 'aim_ll.exe'

        if (-not (Test-Path $aimLL)) {
            Write-Log "FAILED: aim_ll.exe not found in Scripts\WinFixIT\Support\"
            Write-Host ""
            Write-Host "$R Installation cannot proceed in WinPE.$Rst"
            Write-Host "  ISO mounting requires Arsenal Image Mounter (AIM Toolkit)."
            Write-Host ""
            Write-Host "  Copy these three files to Scripts\WinFixIT\Support\ on the USB:"
            Write-Host "    aim_ll.exe    (from C:\Program Files\AIM Toolkit\)"
            Write-Host "    aimapi.dll    (from C:\Program Files\AIM Toolkit\)"
            Write-Host "    aimwrfltr.sys (from C:\Windows\System32\drivers\)"
            Write-Host ""
            Write-Host "Press Enter to return..." -NoNewline
            $null = Read-Host
            return $setupLaunched
        }

        try {
            Write-Log "Loading Arsenal Image Mounter driver..."
            $aimInstallOut = & $aimLL --install $utilitiesFolder 2>&1
            Write-Log "AIM install exit code: $LASTEXITCODE  output: $($aimInstallOut -join ' | ')"
            Start-Sleep -Milliseconds 500

            $usedLetters = (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue).Name
            $freeLetter  = 'D','E','F','G','H','I','J','K','L','M','N','O','P','Q','R','S','T','U','V','W','Y','Z' |
                           Where-Object { $_ -notin $usedLetters } | Select-Object -First 1
            if (-not $freeLetter) { throw "No free drive letter available to mount ISO." }

            $aimMountOut = & $aimLL -a -t file -o ro -f $IsoPath -m "${freeLetter}:" 2>&1
            Write-Log "AIM mount exit code: $LASTEXITCODE  output: $($aimMountOut -join ' | ')"
            Start-Sleep -Milliseconds 500
            Write-Log "ISO mounted at drive ${freeLetter}: (via Arsenal Image Mounter)"

            $mountRoot = "${freeLetter}:\"
            $rootItems = Get-ChildItem $mountRoot -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
            Write-Log "Contents of ${mountRoot}: $($rootItems -join ', ')"

            $setupExe = "${freeLetter}:\setup.exe"
            if (Test-Path $setupExe) {
                if ($ApplyBypassRegistryKeys) {
                    Write-Log "Applying BYPASS registry keys before launching Setup..."
                    Set-Windows11BypassRegistryKeys
                }
                Show-RemoveUSBWarning
                Write-Log "LAUNCHING - Windows Setup"
                Write-Log "..."
                Start-Process $setupExe -ArgumentList "/DynamicUpdate disable" -WorkingDirectory "${freeLetter}:\" -Wait
                Write-Log "COMPLETED - Windows Setup"
                $setupLaunched = $true
            } else {
                Write-Log "setup.exe not found in mounted ISO."
            }
            & $aimLL -d -m "${freeLetter}:" 2>$null
            Write-Log "ISO dismounted."
        }
        catch {
            Write-Log "FAILED to mount or run ISO via AIM: $_"
            Write-Log "  at line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
            Write-Host ""
            Write-Host "$R Installation FAILED:$Rst $_"
            Write-Host "Press Enter to return..." -NoNewline
            $null = Read-Host
            $setupLaunched = $false
        }

    } else {

        # Normal Windows -- use Mount-DiskImage (Storage module)
        try {
            $mount       = Mount-DiskImage -ImagePath $IsoPath -PassThru -ErrorAction Stop
            $driveLetter = ($mount | Get-Volume).DriveLetter
            Write-Log "ISO mounted at drive $driveLetter`:"

            $setupExe = Join-Path "$driveLetter`:" 'setup.exe'
            if (Test-Path $setupExe) {
                if ($ApplyBypassRegistryKeys) {
                    Write-Log "Applying BYPASS registry keys before launching Setup..."
                    Set-Windows11BypassRegistryKeys
                }
                Show-RemoveUSBWarning
                Write-Log "LAUNCHING - Windows Setup"
                Write-Log "..."
                Start-Process $setupExe -ArgumentList "/DynamicUpdate disable" -WorkingDirectory "$driveLetter`:" -Wait
                Write-Log "COMPLETED - Windows Setup"
                $setupLaunched = $true
            } else {
                Write-Log "setup.exe not found in mounted ISO."
            }
            Dismount-DiskImage -ImagePath $IsoPath
            Write-Log "ISO dismounted."
        }
        catch {
            Write-Log "FAILED to mount or run install: $_"
            Write-Host ""
            Write-Host "$R Installation FAILED:$Rst $_"
            Write-Host "Press Enter to return..." -NoNewline
            $null = Read-Host
            $setupLaunched = $false
        }
    }

    return $setupLaunched

}  # END of - function Install-SelectedWindowsISO


# =================================================================================
# function Write-Log
# =================================================================================
# This function writes a message to a log file, prefixed with a timestamp.  It also has the ability to remember the last log file used, so that subsequent calls without a specified log file will continue to write to the same file.  If a new log file is specified, it will switch to that one and remember it for future calls.
# The log file is created if it does not already exist.  This function is useful for consistent logging throughout the script, and allows for easy redirection of log output by simply specifying a different log file when needed.
# The function also includes error handling to ensure that any issues with file access or writing are logged appropriately.
# Note: The log file path is determined by the $usbRoot variable, which should be set to the root of the USB drive being used for the installation process.  The default log file is 'Logs\Win11-INSTALL.log' within that root.
# The function can be called with just a message to log, and it will use the last log file used or the default if none has been set.  Alternatively, a specific log file can be provided for that entry, which will also become the new active log file for subsequent entries.
# Example usage:
#   Write-Log -Message "This is a log entry."
#   Write-Log -Message "This is another entry, but in a different log file." -LogFile "Logs\AnotherLog.log"
# Subsequent calls to Write-Log without a LogFile parameter will continue to write to "Logs\AnotherLog.log" until a new log file is specified.
# Note: The function assumes that the $usbRoot variable is properly set and that the Logs directory exists or can be created.  It also assumes that the script has permission to write to the specified log files.
# The function uses a static-like variable $script:ActiveLogFile to remember the last log file used across multiple calls, which allows for flexible logging without needing to specify the log file every time.
# Note: The function also ensures that the log file exists before attempting to write to it, creating it if necessary.  This prevents errors from trying to write to a non-existent file.
# The function also formats the log entries with a timestamp and a tab before the message for better readability in the log file.
function Write-Log {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Message,

        # Optional override; if supplied, becomes the new active log
        [string]$LogFile
    )
    # STATIC-like behaviour: remember the last-used log file
    if ($LogFile) {
        # Caller supplied a log file → remember it
        $script:ActiveLogFile = $LogFile
    }
    elseif (-not $script:ActiveLogFile) {
        # No remembered log → compute USB root from script location and use default
        $script:ActiveLogFile = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))) 'Logs\Win11-INSTALL.log'
    }
    # If the log file doesn't exist, create it 
    if (-not (Test-Path $script:ActiveLogFile)) {
        New-Item -Path $script:ActiveLogFile -ItemType File -Force | Out-Null
    }
    # Timestamp
    $Timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

    # Append entry
    Add-Content -Path $script:ActiveLogFile -Value "$Timestamp`t$Message"

} # END of - function Write-Log



