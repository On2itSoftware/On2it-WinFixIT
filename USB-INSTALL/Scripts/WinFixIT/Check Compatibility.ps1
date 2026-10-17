# Check Compatibility.ps1
# =======================
#
#      Purpose: This script checks the capability of a PC to be upgraded to Windows 11.
#
#       Method: It runs completely silently and Checks whether in is being run from:
#                   - an installation USB using WinPE, 
#                   - or from a full copy of Windows already installed on th PC.
#
#               It then checks the CPU, RAM, Total Storage, and Firmware,
#               against Microsofts official Requirements.   
#
#               In so doing it writes a Win11-CompatibilityChecker-Results.txt file
#               thatc contains:
#                    [PASSED]  - for features that will allow a FULL Install
#                    [WARNING] - for features that might require a BYPASS Install
#                    [FAILED]  - for features that would prevent Windows 11 from running
#
#               This File is then passed to Win11-CompatibilityChecker-UserAdvice.ps1 to enable the User to 
#               decide what to do.
#
#  Designed by: Brian McGuigan
#           of: On2it Software ltd
#      Code by: Copilot
#      Version: 1
#        Dated: 09-Sep-2025
#       Status: FULLY-TESTED

#  Tests Completed: PE.1, PE.2, PE.3a, PE.3c.  It was decided PE.3b and PE.4 were irellevant.
#                   OS.1, OS.2, OS.3, OS.4, OS.5.
#  To be Completed: NOTHING
#            
#      Version: 2
#        Dated: 09-Sep-2025
#  Modified to: Remove ":" from CPU and RAM Heading text that was causing 
#               Win11-CompatibilityChecker-UserAdvice to display text as Bright yellow.
#  Modified by: Brian McGuigan
#           of: On2it Software ltd
#       Status: FULLY-TESTED
#
#      Version: 3
#        Dated: 14-Sep-2025
#  Modified to: Dot-Source Check-OSenvironment.ps1 rathe than use its oown Environment checkin.
#               All debugging the the $Results array Was therefore Removed.
#  Modified by: Brian McGuigan
#           of: On2it Software ltd
#       Status: FULLY-TESTED
#
#      Version: 4
#        Dated: 14-Sep-2025
#  Modified to: be Dot.Sourced rather than run as an undependant Script
#               All debugging the the $Results array Was therefore Removed.
#  Modified by: Brian McGuigan
#           of: On2it Software ltd
#       Status: Yet TO BE TESTED


function CHECK-Compatibility {
<#  
    CHECK-Compatibility has four main Sections that evaluate the Host PC's capabilites against 
    Microsofts requirements to be able to run Windows 11  The sections are:
        - PROCESSOR,
        - MEMORY,
        - STORAGE,
        - FIRMWARE.

    As each Section runs it displays its name. Whilst it is running an asynchronous 
    Dot Animation process displays a series of dot accross the screen to satiffy the User 
    that the machine is acually doing something.  AT the end of the section its results 
    displayed, similar to this:
        PROCESSOR   [PASSED]
        MEMORY      [PASSED]
        STORAGE     [FAILED]
        FIRMWARE    [WARNING]

    Apart from this overall summary, the user will not see anything.  Individual Results 
    of each test in a $Results Array. At the end of the Process the $Reluts are written yo:
        Win11-CompatibilityChecker-Results.txt 
    
    Win11-CompatibilityChecker-UserAdvice.ps1 is then called so that the user may see the Results, and decide
    Wht to do,
#>


# =================================================================================
# Code that USED TO BE exectuted when the Script was first loaded. 
# =================================================================================

# Get the drive root that $PSScriptRoot lives on
$usbRoot = (Get-Item -LiteralPath $PSScriptRoot).PSDrive.Root

# Results must survive on a writable partition even when USB-INSTALL is set read-only
# for distribution, so they live on the second (On2it-WinFixIT) partition instead -
# falling back to USB-INSTALL only if that partition wasn't found.
$logDir  = if ($usbSecondPartition) { Join-Path $usbSecondPartition.TrimEnd('\') 'Logs' } else { Join-Path $usbRoot 'Logs' }
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -Path $logDir -ItemType Directory | Out-Null
}

$ResultsPath = Join-Path $logDir 'Win11-CompatibilityChecker-Results.txt'

# --- Counters ---
# Track number of passed, failed, and warning checks
$script:passed          = 0
$script:failed          = 0
$script:warning         = 0
$script:warnNotDetected = 0

$Debug_Mode = $false # Set $true/$false to Enable/Disable debugging

# ======================================================================================
# HEADER - Display and write to Win11-CompatibilityChecker-Results.txt file
# ======================================================================================

# Initialise results array BEFORE adding anything to it
$Results = @()

Display-CompatibilityHeader `
    -ComputerName $env:COMPUTERNAME `
    -Results ([ref]$Results)

## =====================================================================================
# PROCESSOR
# =====================================================================================

Display-Section-Header -Section "PROCESSOR"

$start   = Get-Date
$status  = "PASSED"

try {
    $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue
    Display-Section-ProgressDot

    if ($cpu) {
        $coreWord = if ($cpu.NumberOfCores -eq 1) { 'core' } else { 'cores' }
        $Results += "PROCESSOR:  CPU: $($cpu.Name.Trim()) [$($cpu.NumberOfCores) $coreWord $([math]::Round($cpu.MaxClockSpeed/1000,2)) GHz]"
        $Results += "            Minimum requirements are x64 architecture  - 2 cores 1.0 GHz Processor."

        if ($cpu.Architecture -ne 9 -or ($cpu.MaxClockSpeed/1000) -lt 1.0 -or $cpu.NumberOfCores -lt 2) {
            $status = "FAILED"
            $Results += LogAndCount "[FAILED]  - CPU does not meet Windows 11 minimum requirements."
        }
        else {
            $Results += LogAndCount "[PASSED]  - This CPU meets Windows 11 requirements."
        }
        Display-Section-ProgressDot
    }
    else {
        $status = "WARNING"
        $Results += LogAndCount "[WARNING] - CPU info not detected."
        Display-Section-ProgressDot
    }
}
catch {
    $status = "WARNING"
    $Results += LogAndCount "[WARNING] - Exception during CPU check: $($_.Exception.Message)"
}

Display-Section-Status -Status $status

$Results += "" # Add a Blank line to the $Results Array between Scctions

# =====================================================================================
# MEMORY
# =====================================================================================

Display-Section-Header -Section "MEMORY"

$start   = Get-Date
$status  = "PASSED"

try {
    if (-not $memGB) {
        $memGB = [math]::Round(
            (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory / 1GB
        )
    }

    $Results += "MEMORY:     Windows 11 has minimum requirement of only 4GB"
    Display-Section-ProgressDot

    if ($memGB -lt 4) {
        $status = "FAILED"
        $Results += LogAndCount "[FAILED]  - Installed RAM below 4 GB, does not meet Windows 11 minimum requirements."
    } else {
        $Results += LogAndCount "[PASSED]  - This PC has $memGB GB of RAM."
    }
    Display-Section-ProgressDot

}
catch {
    $status = "WARNING"
    $Results += LogAndCount "[WARNING] - Unable to determine installed RAM."
    $Results += "            This may be due to missing WMI support, restricted permissions."
}

Display-Section-Status -Status $status

$Results += "" # Add a Blank line to the $Results Array between Scctions

# =======================================================================================
# STORAGE 
# =======================================================================================

Display-Section-Header -Section "STORAGE"

$start   = Get-Date
$status  = "PASSED"

$Results += "STORAGE:    Official Requirement is a minimum of   64 GB on the System Drive. "
$Results += "            But to be realistic you need at least 500 GB for most working machines."

try {
    $totalGB  = $null
    $freeGB   = $null
    $driveLabel = "System Drive Capacity"
    Display-Section-ProgressDot

    $storageInWinPE = ($env:SystemDrive -eq 'X:' -or $env:SystemRoot -match '^(?i)X:\\Windows')

    if ($storageInWinPE) {
        # In WinPE the system drive is the boot USB — not the Windows install target.
        # Get-Disk is not available in WinPE; use WMI instead.
        # Take the largest disk — the internal drive will always exceed the USB in size.
        $targetDisk = Get-WmiObject Win32_DiskDrive -ErrorAction SilentlyContinue |
                      Where-Object { $_.Size -gt 0 } |
                      Sort-Object { [long]$_.Size } -Descending |
                      Select-Object -First 1
        if ($targetDisk) {
            $totalGB    = [math]::Round([long]$targetDisk.Size / 1GB)
            $freeGB     = 0
            $driveLabel = "Target Drive Capacity"
        }
        Display-Section-ProgressDot
    } else {
        if (-not $osDrive) { $osDrive = $env:SystemDrive }
        $osDriveLetter = $osDrive.TrimEnd(':')

        try {
            if (Get-Command Get-Volume -ErrorAction SilentlyContinue -CommandType Cmdlet) {
                $vol = Get-Volume -DriveLetter $osDriveLetter -ErrorAction Stop
                $totalGB = [math]::Round($vol.Size / 1GB)
                $freeGB  = [math]::Round($vol.SizeRemaining / 1GB)
            } else {
                $vol = Get-WmiObject Win32_Volume -Filter "DriveLetter='${osDriveLetter}:'" -ErrorAction Stop
                $totalGB = [math]::Round($vol.Capacity / 1GB)
                $freeGB  = [math]::Round($vol.FreeSpace / 1GB)
            }
            Display-Section-ProgressDot
        }
        catch {
            $bootDisk = Get-Disk | Where-Object IsBoot -eq $true
            if ($bootDisk) {
                $totalGB = [math]::Round($bootDisk.Size / 1GB)
                $freeGB  = 0
            }
            Display-Section-ProgressDot
        }
    }

    if ($totalGB) {
#       $Results += ("            {0,-34}{1,7} GB, Free space  {2} GB" -f "System drive capacity", $totalGB, $freeGB)
        if ($totalGB -gt 64) {
            $Results += LogAndCount (
                "[PASSED]  - {0,-34}{1,7} GB Free Space {2} GB" -f $driveLabel, $totalGB, $freeGB)
        } else {
            $Results += LogAndCount `
                "[FAILED]  - Storage capacity below 64 GB, does not meet Windows 11 minimum requirements."
        }
        Display-Section-ProgressDot

    } else {
        if ($allDisks -and ($maxGB -ge 64)) {
            $status = "WARNING"
            $Results += LogAndCount "[INFO]    - Could not tie capacity to OS drive, but at least one drive exceeds 64 GB."
        } else {
            $status = "FAILED"
            $Results += LogAndCount "[FAILED]  - No drive meets the 64 GB minimum requirement."
        }
        Display-Section-ProgressDot
    }

    $allDisks = Get-WmiObject Win32_DiskDrive -ErrorAction SilentlyContinue | Where-Object { $_.Size -gt 0 }
    if ($allDisks) {
        $diskSizes = $allDisks | ForEach-Object { [long]$_.Size }
        $sumGB = [math]::Round(($diskSizes | Measure-Object -Sum).Sum / 1GB)
        $maxGB = [math]::Round(($diskSizes | Measure-Object -Maximum).Maximum / 1GB)
        $Results += ("            {0,-34}{1,7} GB" -f "Largest single drive", $maxGB)
        $Results += ("            {0,-34}{1,7} GB" -f "Total storage all drives", $sumGB)
        Display-Section-ProgressDot

    }
}
catch {
    $status = "WARNING"
    $Results += LogAndCount "[WARNING] - Storage capacity check failed: $($_.Exception.Message)"
    Display-Section-ProgressDot
}

Display-Section-Status -Status $status

$Results += "" # Add a Blank line to the $Results Array between Scctions

# ==========================================================================================================
#          FIRMWARE - PARTITION STYLE / SECURE BOOT / TPM
# ==========================================================================================================

Display-Section-Header -Section "FIRMWARE"

$start   = Get-Date
$status  = "PASSED"


$Results += "FIRMWARE:   A FULL Install of Windows 11 requires UEFI firmware with Secure Boot enabled,"
$Results += "            TPM 2.0, and a system disk using the GPT partition style."
$Results += "          - A BYPASS Install circumvents these requirements -- see advice below."

$SimulatedWinPE = $inWinPE -and ($env:SystemRoot -notlike "X:\Windows")
Display-Section-ProgressDot

if ($inWinPE) {
    $status = "WARNING"
    $Results += LogAndCount "[WARNING]   Unable to determine partition style, Secure Boot, and TPM 2.0 status"
    $Results += "            because the USB environment does not include the drivers needed for these checks."
    Display-Section-ProgressDot

    try {
        $firmwareType = $forceFirmwareType
        if (-not $firmwareType) {
            try {
                $firmwareType = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control" -Name PEFirmwareType -ErrorAction Stop).PEFirmwareType
            }
            catch {
                $firmwareType = $env:firmware_type  # "UEFI" or "Legacy" when set by WinPE
            }
        }
        if ($firmwareType -eq 2 -or $firmwareType -match 'UEFI') {
            $Results += LogAndCount "[PASSED]    UEFI firmware detected."
        } elseif ($firmwareType) {
            $Results += LogAndCount "[WARNING]   Legacy BIOS detected."
            $Results += "            Windows 11 requires UEFI firmware for a FULL Install."
            $Results += "            You will HAVE to use a BYPASS Install."
        } else {
            $Results += LogAndCount "[WARNING]   Unable to determine firmware type."
        }
        Display-Section-ProgressDot

    }
    catch {
        $Results += LogAndCount "[WARNING]   Unable to determine firmware type."
    }
}
else {
    # Partition Style
    try {
        if (-not $partitionStyle) {
            $osDriveLetter = ($env:SystemDrive).TrimEnd(':')
            $osDiskNumber  = (Get-Partition -DriveLetter $osDriveLetter).DiskNumber
            $partitionStyle = (Get-Disk -Number $osDiskNumber -ErrorAction Stop).PartitionStyle
        }
        Display-Section-ProgressDot

        if ($partitionStyle -eq 'GPT') {
            $Results += LogAndCount "[PASSED]    Partition style is GPT."
        } else {
            $status = "FAILED"
            $Results += LogAndCount "[FAILED]    Partition style is $partitionStyle. Windows 11 requires GPT for a FULL Install."
        }
        Display-Section-ProgressDot
    }
    catch {
        $status = "WARNING"
        $Results += LogAndCount "[WARNING]   Unable to determine partition style."
    }
    Display-Section-ProgressDot

    # Secure Boot
    try {
        if (-not $sbEnabled) {
            Display-Section-ProgressDot
            $sbEnabled = Confirm-SecureBootUEFI -ErrorAction Stop
        }
        Display-Section-ProgressDot

        if ($sbEnabled) {
            $Results += LogAndCount "[PASSED]    Secure Boot is enabled."
        } else {
            $status = "WARNING"
            $Results += LogAndCount "[WARNING]   Secure Boot is disabled."
            $Results += "            Windows 11 requires Secure Boot for a FULL Install."
            $Results += "            You will HAVE to use a BYPASS Install."
        }
        Display-Section-ProgressDot

    }
    catch {
        $status = "WARNING"
        $Results += LogAndCount "[WARNING]   Unable to determine Secure Boot status."
    }
    Display-Section-ProgressDot

    # TPM 2.0
    try {
        if (-not $tpm) {
            $tpm = Get-WmiObject -Namespace "Root\CIMV2\Security\MicrosoftTpm" -Class Win32_Tpm -ErrorAction Stop
        }
        Display-Section-ProgressDot

        if ($tpm -and $tpm.SpecVersion -match '2\.0') {
            $Results += LogAndCount "[PASSED]    TPM 2.0 detected."
        } else {
            $status = "WARNING"
            $Results += LogAndCount "[WARNING]   TPM 2.0 not detected. Windows 11 requires TPM 2.0 for a FULL Install."
        }
        Display-Section-ProgressDot

    }
    catch {
        $status = "WARNING"
        $Results += LogAndCount "[WARNING]   Unable to determine TPM status."
        Display-Section-ProgressDot
    }

    # Firmware Type
    try {
        if (-not $firmwareType) {
            try {
                $firmwareType = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control" -Name PEFirmwareType -ErrorAction Stop).PEFirmwareType
            }
            catch {
                $envFirmware = $env:firmware_type
                if ($envFirmware) {
                    $firmwareType = $envFirmware  # Returns "UEFI" or "Legacy"
                } else {
                    $firmwareType = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).BootupState
                }
            }
            Display-Section-ProgressDot
        }
        Display-Section-ProgressDot

        if ($firmwareType -eq 2 -or $firmwareType -match 'UEFI') {
            $Results += LogAndCount "[PASSED]    UEFI firmware detected."
        } else {
            Display-Section-ProgressDot
            $status = "WARNING"
            $Results += LogAndCount "[WARNING]   Legacy BIOS detected."
            $Results += "            Windows 11 requires UEFI firmware for a FULL Install."
            $Results += "            You will HAVE to use a BYPASS Install."
        }
    }
    catch {
        $status = "WARNING"
        $Results += LogAndCount "[WARNING]   Unable to determine firmware type."
    }
}

Display-Section-Status -Status $status

$Results += "" # Add a Blank line to the $Results Array between Sections

# ========================================================================================

# Pause so that overall Summary can be read by User
Write-Host "Press <Enter> to continue ..." -ForegroundColor Yellow
$null = Read-Host

# =======================================================================================
# SUMMARY
# =======================================================================================
if ($Debug_Mode) {
    Write-Host "`nCompatibility Check Totals:" -ForegroundColor Cyan
    Write-Host "[WARNING] - $script:warning warnings issued. ($script:warnNotDetected for issues that could not be evaluated)" -ForegroundColor Yellow
    Write-Host "[FAILED]  - $script:failed checks failed."   -ForegroundColor Red
    Write-Host "[DEBUG]   - Results saved to: $ResultsPath" -ForegroundColor Green
}


# Append summary block to $Results
# -------------------------------
if ($Debug_Mode) {

    # Warnings (always show, even if zero)
    $Results += "[WARNING] - {0} warning{1} issued. ({2} unresolved issue{3})" -f `
        $script:warning, $(if ($script:warning -eq 1) { '' } else { 's' }), `
        $script:warnNotDetected, $(if ($script:warnNotDetected -eq 1) { '' } else { 's' })

    # Failed
    $Results += "[FAILED]  - {0} check{1} failed." -f $script:failed, $(if ($script:failed -eq 1) { '' } else { 's' })
}
# ==========================================================================================
#  Write "Win11-CompatibilityChecker-Results.txt" from $Results Array
# ===========================================================================================

# Write results to the Logs folder resolved at the top of this function
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
}

# Indent the report body by 2 spaces - keeps the text off the very left edge, which
# reads better on screen and makes it easier to screenshot cleanly.  The banner (two
# '=' rules and the centred title) and blank lines are left exactly as they are.
$Results = $Results | ForEach-Object {
    if ($_ -match '^\s*$' -or $_ -match '^=+$' -or $_ -match 'Compatibility Results for ') {
        $_
    } else {
        '  ' + $_
    }
}

try {
    if ($Results -and $Results.Count -gt 0) {
        $Results | Out-File -FilePath $ResultsPath -Encoding ASCII
    }
}
catch {
    Write-Host "[ERROR] Failed to write results to $ResultsPath"
    Write-Host "        $($_.Exception.Message)"
}


Give-CompatibilityAdvice `
    -Warning          $script:warning `
    -Failed           $script:failed `
    -WarnNotDetected  $script:warnNotDetected `
    -ResultsPath      $ResultsPath

}  # END of - function CHECK-Compatibility




function LogAndCount {
    param ([string]$Message)  # The message string to logged, counted and returned

#   PURPOSE:
#       If in Debug_Mode, Echo $Message to Console.  
#       Count [FAILED] and [WARNING] messages. 
#
#   SIDE EFFECTS:
#       Updates $script:failed, $script:warning, $script:warnNotDetected
#       Appends the message to $Results
#
    # If in Debug_Mode, Echo $Message to Console. 
    if ($script:Debug_Mode) { Write-Host $Message -ForegroundColor Cyan }

    if ($Message.StartsWith("[FAILED]")) {
        $script:failed++
    }
    elseif ($Message.StartsWith("[WARNING]")) {
        $script:warning++

        if ($Message.ToLower().Contains("not detected") -or
            $Message.ToLower().Contains("unable to determine")) {
            $script:warnNotDetected++
        }
    }

    return $Message
}


# =======================================================================================

# --- Display the section header and initialise dot counter ---
function Display-Section-Header {
    param([string]$Section)

    $script:CurrentSection = $Section
    $script:DotCount = 0
    Write-Host ("{0,-10}:" -f $Section) -ForegroundColor Yellow -NoNewline
} # end Display-Section-Header

# =======================================================================================

# --- Increment dot counter and display that many dots ---
function Display-Section-ProgressDot {
    $script:DotCount++
    $dots = "." * $script:DotCount
    Write-Host ("`r{0,-10}: {1}" -f $script:CurrentSection, $dots) -ForegroundColor White -NoNewline
} # end Display-Section-ProgressDot

# =======================================================================================

# --- Clear dots and display final status ---
function Display-Section-Status {
    param([string]$Status)

    # Always print the section name in yellow
    Write-Host ("`r{0,-10}:  " -f $script:CurrentSection) -ForegroundColor Yellow -NoNewline

    # Then print the status in its own colour
    switch ($Status) {
        "FAILED"  { Write-Host "[FAILED]"  -ForegroundColor Red }
        "WARNING" { Write-Host "[WARNING]" -ForegroundColor White }
        default   { Write-Host "[PASSED]"  -ForegroundColor Green }
    }
} # end Display-Section-Status



 
# END of - CHECK-Compatibility.ps1