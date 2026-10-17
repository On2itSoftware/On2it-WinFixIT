<#  Display Scenarios.ps1
    =====================
    This script contains all the Functions necessary to enable other scripts in the system to:
        Get-ScenarioFromUSB
        Display-TextFrom a TXT File
        Display-ScenarioSelected
    and Determine:
        Is-OSenvironment-WinPE 
        Get-USBRoot-And-RequiredFiles
        
        Designed by: Brian McGuigan
            of: On2it Software ltd
       Code by: Copilot
       Version: 1
         Dated: 2-Mar-26
        Status: 
#>

# =================================================================================

function Get-ScenarioFromUSB {
<#mUS
    STATUS: RE-TESTED

    .SYNOPSIS
        Loads and parses a single scenario block from a tagged presentation file on the USB.

    .DESCRIPTION
        - Resolves the scenario file path from UsbRoot + Ps1FileName, or UsbRoot + SubFolder + Ps1FileName when -SubFolder is specified.
        - Finds the scenario block starting at a [DISPLAY WHEN - <name>] marker (filtered via -ScenarioPattern).
        - Parses lines into DisplayHeader and Prompts arrays with original ordering preserved.
        - Prompts can be multi-line; embedded CRLFs are preserved exactly as in source.
        - Pacing directives are preserved inline for the renderer:
            * [PAUSE] remains as-is in DisplayHeader (renderer handles waiting).
            * [CLEAR] is stored literally as: "[CLEAR] <message>"
              so the renderer clears the screen exactly where it appears.
              If the message contains the literal word "ANY" (case-insensitive),
              the renderer waits for any key before clearing; otherwise it clears immediately.

    .NOTES
        - Environment-neutral: callers choose the scenario via -ScenarioPattern.
        - Deterministic, read-only parsing. No global mutations.
#>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$UsbRoot,
        [Parameter(Mandatory)][string]$RTFfileName,
        [Parameter(Mandatory)][string]$ScenarioPattern,
        [string]$SubFolder = 'Scripts',
        [switch]$Debug_Mode
    )
    $filePath = if ($SubFolder) {
        Join-Path "$UsbRoot\$SubFolder" $RTFfileName
    } else {
        Join-Path "$UsbRoot" $RTFfileName
    }

    if ($Debug_Mode) {
        Write-Host "[DEBUG] Scenario file path: $filePath" -ForegroundColor Cyan
    }
    if (-not (Test-Path -LiteralPath $filePath)) {
        throw "Scenario file not found: $filePath"
    }
    # --- Read file content ---
    $fileContent = Get-Content -LiteralPath $filePath

    # --- Locate the scenario block (case-insensitive, first match only) ---
    $match = $fileContent | Select-String -Pattern "(?i)$ScenarioPattern" | Select-Object -First 1
    if (-not $match) {
        throw "Scenario pattern not found in $filePath"
    }

    # Force an integer, even if something upstream tries to hand us an array
    $startIndex = [int]$match.LineNumber

    if ($Debug_Mode) {
        Write-Host "[DEBUG] startIndex (int): $startIndex" -ForegroundColor Cyan
    }

    # --- Extract block from startIndex to EOF or next [DISPLAY WHEN] ---
    $endIndex = $fileContent.Length - 1
    $scenarioLines = $fileContent[($startIndex - 1) .. $endIndex]

    # Find the next [DISPLAY WHEN] after the start; skip the first (current) match
    $nextMatch = $scenarioLines | Select-String -Pattern '^\s*\[DISPLAY WHEN' | Select-Object -Skip 1 -First 1
    if ($nextMatch) {
        $nextDisplayIndex = [int]$nextMatch.LineNumber
        if ($Debug_Mode) {
            Write-Host "[DEBUG] nextDisplayIndex (int): $nextDisplayIndex" -ForegroundColor Cyan
        }
        $scenarioLines = $scenarioLines[0 .. ($nextDisplayIndex - 2)]
    }

    # --- Parse into DisplayHeader and Prompts arrays ---
    $DisplayHeader = @()
    $Prompts = @()
    $currentPrompt = @()

    foreach ($line in $scenarioLines) {

        # Only process lines that are NOT scenario tags
        if ($line -notmatch '^\s*\[DISPLAY WHEN') {

            if ($line -match '^\s*\[CLEAR\]\s*(?<msg>.*)$') {
                $msg = $matches['msg']
                $DisplayHeader += "[CLEAR] $msg"
            }
            elseif ($line -match '^\s*\[PROMPT\]\s*(?<prompt>.*)$') {
                if ($currentPrompt.Count) {
                    $Prompts += ($currentPrompt -join "`r`n")
                    $currentPrompt = @()
                }
                $currentPrompt += $matches['prompt']
            }
            # Skip a full row of '===============================' (with optional spaces)
            elseif  ($line -match '^\s*=+\s*$') {
                  # Intentionally do nothing: separators are not part of the scenario object
            }
            else {
                # Skip bare RTF structural braces (e.g. closing '}' at end of .rtf file)
                if ($line -match '^\s*[{}]\s*$') { continue }

                if ($currentPrompt.Count) {
                    $currentPrompt += $line
                } else {
                    $DisplayHeader += $line
                }
            }
        } # end if not a scenario tag

    } # NEXT $line

    if ($currentPrompt.Count) {
        $Prompts += ($currentPrompt -join "`r`n")
    }

    # --- Return structured object ---
    [PSCustomObject]@{
        DisplayHeader = $DisplayHeader
        Prompts       = $Prompts
    }
} # END of function Get-ScenarioFromUSB

# =================================================================================
function Display-TextFrom {
# This function is used to display text from a specified .txt file on the USB, 
# with support for embedded colour tokens and Current Row Position counting.

    param(
        [Parameter(Mandatory)][string]$UsbRoot,
        [Parameter(Mandatory)][string]$SubFolder,
        [Parameter(Mandatory)][string]$TXTfilename
    )

    $path = Join-Path (Join-Path $UsbRoot $SubFolder) $TXTfilename

    # If there is no file, just return silently as there is nothing to display. 
    if (-not (Test-Path -LiteralPath $path)) {
        return
    }
    $lines = Get-Content -LiteralPath $path

    foreach ($line in $lines) {
        $expanded = $ExecutionContext.InvokeCommand.ExpandString($line)
        Write-Host $expanded
        $script:CurrentRowPosition++
    }
    Write-Host ""
    $script:CurrentRowPosition++
    Write-Host ""
    $script:CurrentRowPosition++

} # END of - function Display-TextFrom


# =================================================================================

function Display-ScenarioSelected {
    param (
        [Parameter(Mandatory)][pscustomobject]$Scenario,
        [string[]]$TrackKeywords = @()   # when set, returns a logical-row → keyword map
    )
    # This function displays a selected Scenario.
    # When TrackKeywords is supplied it also returns a hashtable mapping the logical row
    # of each matching line to its keyword — ready to assign to $script:RowToOption.

    $keywordRows = @{}
    $headingRows = @{}

    $rawui = $Host.UI.RawUI
    $estimatedScenarioHeight = $Scenario.DisplayHeader.Count + 5  # small margin

    # Extend buffer height only
    if ($rawui.BufferSize.Height -lt $estimatedScenarioHeight) {
        $rawui.BufferSize = New-Object System.Management.Automation.Host.Size(
            $rawui.BufferSize.Width,
            $estimatedScenarioHeight
        )
    }
    foreach ($OriginalTextLine in $Scenario.DisplayHeader) {

        # --- Branch 1: Handle a [PAUSE] directive ---
        if ($OriginalTextLine -match '^\s*\[PAUSE\]\s*(?<PauseMessage>.+)?$') {

            $pauseMsg = $matches['PauseMessage']
            if (-not $pauseMsg) {
                $pauseMsg = "${Gy}Please press ANY key to continue...${Rst}"
            } else {
                $pauseMsg = Resolve-ColourTokens $pauseMsg
            }

            Write-Host $pauseMsg
            [void][Console]::ReadKey($true)
            $script:CurrentRowPosition += 1

        # --- Branch 2: Handle a [CLEAR] directive ---
        } elseif ($OriginalTextLine -match '^\s*\[CLEAR\]\s*(?<OriginalMessage_AfterTag>.*)$') {

            $OriginalMessage_AfterTag = $matches['OriginalMessage_AfterTag']
            Write-Host ($ExecutionContext.InvokeCommand.ExpandString($OriginalMessage_AfterTag))

            $plain = $OriginalMessage_AfterTag -replace '\$\w+|\$\{[^}]+\}', ''
            if ($plain -match '(?i)\bANY\b') {
                [void][Console]::ReadKey($true)
            }

            Clear-Screen
            $keywordRows = @{}   # rows reset to 0 after a screen clear
            $headingRows = @{}
        }

        # --- Branch 3: Handle normal text or blank lines ---
        else {
            $lineToPrint = if ($OriginalTextLine -match '^\s*$') { ' ' } else { $OriginalTextLine }

            # Strip PS variable tokens — needed for accurate wrap count AND keyword matching.
            # $lineToPrint holds raw RTF text like "$Y CHECK$Rst"; Invoke-Expression expands
            # those to ANSI codes at render time, but here they are still literal characters
            # that would inflate $visibleLen and push $CurrentRowPosition ahead of reality.
            $stripped = $lineToPrint -replace '\$\{[^}]+\}', '' -replace '\$[A-Za-z_][A-Za-z0-9_]*', ''

            # Track keyword rows during rendering (avoids any buffer-scan dependency)
            if ($TrackKeywords.Count -gt 0) {
                $trimmed = $stripped.TrimStart()
                foreach ($kw in $TrackKeywords) {
                    if ($trimmed.ToUpper().StartsWith($kw)) {
                        $keywordRows[$script:CurrentRowPosition] = $kw
                        # Split into yellow text and any $W suffix so hover underlines only the yellow part
                        $_yt = $lineToPrint -replace '^\$Y' -replace '\$(?:Rst|Reset)\s*$', ''
                        $_sf = ''
                        if ($_yt -match '^(.+?)(\$W.+)$') { $_yt = $matches[1]; $_sf = $matches[2] }
                        $headingRows[$script:CurrentRowPosition] = @{ Prefix = $_yt -replace '^(\s*).*','$1'; Name = $_yt.TrimStart(); Suffix = $_sf; Raw = $lineToPrint }
                        break
                    }
                }
            }

            Write-Host ($ExecutionContext.InvokeCommand.ExpandString($lineToPrint))

            $visibleLen = ($stripped -replace $ANSI, '').Length
            $bufWidth   = $Host.UI.RawUI.BufferSize.Width
            $wraps      = if ($bufWidth -gt 0) { [int][Math]::Floor([Math]::Max(1,$visibleLen) / $bufWidth) } else { 0 }
            $script:CurrentRowPosition += 1 + $wraps
        }
    }

    # Write the map directly into the script-scope variable so it is ready for
    # Accept-UserInput without any risk of pipeline-capture turning it into an array.
    if ($TrackKeywords.Count -gt 0) {
        $script:RowToOption  = $keywordRows
        $script:RowToHeading = $headingRows
    }

} # END of - function Display-ScenarioSelected
 

# =======================================================================================

function Is-OSenvironment-WinPE {
    [CmdletBinding()]
    param (
        [switch]$Debug_Mode
    )
<#
.SYNOPSIS
    Detects whether the current PowerShell session is running in a Windows PE (WinPE) environment.

.DESCRIPTION
    This function checks for the presence of WinPE by:
      1. Looking for the WinPEShl.exe file in the standard WinPE location.
      2. Falling back to checking if $env:SystemRoot points to X:\Windows.
    If WinPE is detected, the OS drive is assumed to be X:.
    If not in WinPE, the OS drive is derived from $env:SystemRoot.

    Returns a PSCustomObject with:
      - IsWinPE [bool]  : $true if running in WinPE, otherwise $false.
      - OSDrive [string]: Drive letter of the OS volume.

.PARAMETER Debug_Mode
    Optional switch. When specified, the function writes debug information
    about the detected environment and OS drive to the host.

.EXAMPLE
    # Basic usage - store result and check environment
    $envInfo = Is-OSenvironment-WinPE
    if ($envInfo.IsWinPE) {
        Write-Host "Running in WinPE"
    } else {
        Write-Host "Running in full Windows"
    }

.EXAMPLE
    # One-liner to check only the boolean
    if ((Is-OSenvironment-WinPE).IsWinPE) {
        Write-Host "WinPE detected"
    }

.EXAMPLE
    # Retrieve OS drive directly
    $osDrive = (Is-OSenvironment-WinPE).OSDrive
    Write-Host "OS Drive is $osDrive"

.EXAMPLE
    # Debug mode - shows detection steps and results
    $envInfo = Is-OSenvironment-WinPE -Debug_Mode
    if ($envInfo.IsWinPE) {
        Write-Host "Running in WinPE from $($envInfo.OSDrive)"
    }
#>    
    # Defaults
    $isWinPE = $false
    $osDrive = $null

    # --- Branch 1: WinPE by environment drive/root ---
    if ($env:SystemDrive -eq 'X:' -or $env:SystemRoot -match '^(?i)X:\\Windows') {
        $isWinPE = $true
        $osDrive = 'X:'

    # --- Branch 2: WinPE by registry sentinel (MiniNT) ---
    } elseif (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT') {
        # MiniNT key exists in WinPE/Setup, not in normal Windows
        $isWinPE = $true
        # Prefer SystemDrive if present; else fall back to X:
        $osDrive = if ($env:SystemDrive) { $env:SystemDrive } else { 'X:' }

    # --- Branch 3: Full Windows ---
    } else {
        $isWinPE = $false
        # Derive OS drive from SystemRoot (e.g., "C:\Windows" -> "C:")
        $osDrive = Split-Path -Qualifier $env:SystemRoot
    }

    if ($Debug_Mode) {
        $envType = if ($isWinPE) { "WinPE" } else { "Full Windows OS" }
        Write-Host "[DEBUG] Environment detected: $envType" -ForegroundColor Yellow
        Write-Host "[DEBUG] OS Drive: $osDrive" -ForegroundColor Yellow
        Write-Host "[DEBUG] SystemDrive: $($env:SystemDrive) | SystemRoot: $($env:SystemRoot)" -ForegroundColor Yellow
        Write-Host "[DEBUG] MiniNT key present: $([bool](Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT'))" -ForegroundColor Yellow
        
        Write-Host "[DEBUG] IsWinPE: $isWinPE" -ForegroundColor Yellow
    }
# $IsWinPE = $true  # Temporary DEBUG to force logic to branch for testing

    [PSCustomObject]@{
        IsWinPE = $isWinPE
        OSDrive = $osDrive
    }
}  # END of - function Is-OSenvironment-WinPE


# =====================================================================================================

function Get-USBRoot-And-RequiredFiles {
    [CmdletBinding()]
    param (
        [string]$Ps1FileName,
        [string[]]$RequiredFiles,
        [switch]$Debug_Mode
    )

    # --- Local install: paths supplied via environment variable, no USB probing needed ---
    if ($env:WINFIXITROOT) {
        $base = $env:WINFIXITROOT.TrimEnd('\')
        $localCourses = "$base\On2it Software Courses\"
        return [PSCustomObject]@{
            UsbRoot             = "$base\Local-INSTALL\"
            UsbSecondPartition  = "$base\On2it-WinFixIT\"
            # $null (not an empty/non-existent path) when Course Notes were
            # never installed locally - a client USB with no Courses content
            # never gets this folder created at all, so its absence here is
            # a real, meaningful signal, not just a missing folder. See
            # Install-WinFixIT-Local.ps1.
            UsbCoursesPartition = if (Test-Path (Join-Path $localCourses 'OPEN - On2it Software Courses.bat')) { $localCourses } else { $null }
        }
    }

    # --- Locate the primary On2it-WinFixIT INSTALL partition ---
    $usbRootDrive = Get-PSDrive -PSProvider FileSystem |
        Where-Object {
            Test-Path (Join-Path $_.Root 'Scripts\WinFixIT\Install Windows.rtf')
        } |
        Select-Object -First 1

    # --- Locate the On2it-WinFixIT partition ---
    $usbSecondDrive = Get-PSDrive -PSProvider FileSystem |
        Where-Object {
            Test-Path (Join-Path $_.Root 'Install\Windows\ISO Descriptions.txt')
        } |
        Select-Object -First 1

    # --- Locate the On2it Software Courses partition, if this USB has one -
    # optional (a client USB legitimately has none), and only ever needed
    # from Full Windows (installing/opening Course Notes locally), never
    # WinPE bare-metal setup, so no unlettered-volume probing needed here
    # the way $usbSecondDrive above needs it. ---
    $usbCoursesDrive = Get-PSDrive -PSProvider FileSystem |
        Where-Object {
            Test-Path (Join-Path $_.Root 'OPEN - On2it Software Courses.bat')
        } |
        Select-Object -First 1

    # In WinPE only the boot partition gets a drive letter automatically.
    # If the On2it-WinFixIT partition wasn't found, probe each unlettered volume by
    # temporarily assigning a drive letter and checking for the anchor file.
    if (-not $usbSecondDrive) {
        try {
            $unlettered = Get-WmiObject Win32_Volume -ErrorAction SilentlyContinue |
                Where-Object { -not $_.DriveLetter -and $_.DriveType -ne 5 -and $_.Capacity -gt 0 }

            $usedLetters = (Get-PSDrive -PSProvider FileSystem).Name
            $freeLetter  = 'D','E','F','G','H','I','J','K','L','M','N','O','P','Q','R','S','T','U','V','W','Y','Z' |
                Where-Object { $_ -notin $usedLetters } |
                Select-Object -First 1

            if ($freeLetter -and $unlettered) {
                $mountPoint = "${freeLetter}:"
                foreach ($vol in $unlettered) {
                    & mountvol $mountPoint $vol.DeviceID 2>$null
                    Start-Sleep -Milliseconds 300

                    if (Test-Path (Join-Path "${mountPoint}\" 'Install\Windows\ISO Descriptions.txt')) {
                        # Found it — keep the letter assigned
                        $usbSecondDrive = Get-PSDrive -PSProvider FileSystem |
                            Where-Object { $_.Name -eq $freeLetter } |
                            Select-Object -First 1
                        break
                    }
                    & mountvol $mountPoint /D 2>$null   # not this one — remove and try next
                }
            }
        }
        catch { <# silently ignore — caller handles a null UsbSecondPartition #> }
    }

    # --- Fallback: running from a local copy (Development/PRODUCTION tree) where
    #     Scripts is nested rather than sitting at a drive root. Derive UsbRoot from
    #     this script's own location, and UsbSecondPartition from its sibling folder —
    #     works identically regardless of how deep the tree is nested. ---
    if (-not $usbRootDrive) {
        $candidateRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
        if ($candidateRoot -and (Test-Path (Join-Path $candidateRoot 'Scripts\WinFixIT\Install Windows.rtf'))) {
            $usbRootDrive = [PSCustomObject]@{ Root = "$candidateRoot\" }
        }
    }

    # Sibling-folder derivation only makes sense when $usbRootDrive is a nested
    # Development/PRODUCTION folder path, not a real booted drive letter -- a
    # bare drive root like "Y:\" has no filesystem "parent" to navigate from,
    # and Split-Path -Parent on "Y:" (no trailing backslash, after TrimEnd)
    # throws "The value of argument 'Path' is not valid" rather than failing
    # gracefully. Confirmed for real, 2026-10-16, Brian live run on Test-PC:
    # this fired on an entirely normal, real USB simply because it has no
    # Courses partition -- which is genuinely optional ("a client USB
    # legitimately has none", per the comment above). There was nothing wrong
    # with the USB at all; this fallback just should never have been
    # attempted against a real drive letter in the first place.
    $usbRootIsBareDriveLetter = $usbRootDrive -and ($usbRootDrive.Root.TrimEnd('\') -match '^[A-Za-z]:$')

    if (-not $usbSecondDrive -and $usbRootDrive -and -not $usbRootIsBareDriveLetter) {
        $siblingCandidate = Join-Path (Split-Path -Path $usbRootDrive.Root.TrimEnd('\') -Parent) 'On2it-WinFixIT'
        if (Test-Path (Join-Path $siblingCandidate 'Install\Windows\ISO Descriptions.txt')) {
            $usbSecondDrive = [PSCustomObject]@{ Root = "$siblingCandidate\" }
        }
    }

    if (-not $usbCoursesDrive -and $usbRootDrive -and -not $usbRootIsBareDriveLetter) {
        $coursesSiblingCandidate = Join-Path (Split-Path -Path $usbRootDrive.Root.TrimEnd('\') -Parent) 'On2it Software Courses'
        if (Test-Path (Join-Path $coursesSiblingCandidate 'OPEN - On2it Software Courses.bat')) {
            $usbCoursesDrive = [PSCustomObject]@{ Root = "$coursesSiblingCandidate\" }
        }
    }

    if ($Debug_Mode) {
        Write-Host "[DEBUG] Script file: $Ps1FileName" -ForegroundColor Cyan
        Write-Host "[DEBUG] Primary USB root: $($usbRootDrive.Root)" -ForegroundColor Cyan
        Write-Host "[DEBUG] Secondary USB partition: $($usbSecondDrive.Root)" -ForegroundColor Cyan
    }

    # --- Verify required files exist in primary USB root ---
    if ($RequiredFiles -and $usbRootDrive) {
        foreach ($file in $RequiredFiles) {
            $pathToCheck = Join-Path $usbRootDrive.Root $file
            if (-not (Test-Path -LiteralPath $pathToCheck)) {
                throw "Required file missing: $pathToCheck"
            }
        }
    }

    # --- Return all three roots ---
    [PSCustomObject]@{
        UsbRoot             = if ($usbRootDrive) { $usbRootDrive.Root } else { $null }
        UsbSecondPartition  = if ($usbSecondDrive) { $usbSecondDrive.Root } else { $null }
        UsbCoursesPartition = if ($usbCoursesDrive) { $usbCoursesDrive.Root } else { $null }
    }
} # END of - function Get-USBRoot-And-RequiredFiles


# =======================================================================================

function Display-CompatibilityHeader {
    param(
        [string]$ComputerName = $env:COMPUTERNAME,
        [ref]$Results
    )
    # Displays the header for the Windows 11 Computer Compatibility Results in the
    # standard WinFixIT screen format: a cyan rule, a centred yellow title, a cyan rule.

    $barWidth    = 98
    $bar         = "=" * $barWidth
    $titlePrefix = "Windows 11 Computer Compatibility Results for "
    $titlePC     = "- $ComputerName"
    $title       = $titlePrefix + $titlePC

    # Centre the title within the bar
    $pad          = [Math]::Max(0, [Math]::Floor(($barWidth - $title.Length) / 2))
    $centredTitle = (" " * $pad) + $title

    Write-Host ""
    Write-Host ""
    Write-Host $bar -ForegroundColor Cyan
    Write-Host ((" " * $pad) + $titlePrefix) -ForegroundColor Yellow -NoNewline
    Write-Host $titlePC -ForegroundColor White
    Write-Host $bar -ForegroundColor Cyan
    Write-Host ""

    $Results.Value += ,$bar
    $Results.Value += ,$centredTitle
    $Results.Value += ,$bar
    $Results.Value += ,""
}

# =======================================================================================
