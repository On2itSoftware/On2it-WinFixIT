function Give-CompatibilityAdvice {
    param(
        [Parameter(Mandatory = $true)][int]$Warning,          # The number of [WARNING] Messages 
        [Parameter(Mandatory = $true)][int]$Failed,           # The number of [FAILED]  Messages 
        [Parameter(Mandatory = $true)] [int]$WarnNotDetected, # The number of [WARNING] Issues 
                                                              # that could not be resolved one way or the other
        [Parameter(Mandatory = $true)] [string]$ResultsPath,  # The Path to the Win11-CompatibilityChecker-Results.txt File
                                                              # This can be varied for testing purposes
        [switch]$IgnorePreviousChoice                         # If used it ignores any Previous Choice made by the user, 
                                                              # recorded on the Results File.
    )

    # Helper: does a line match any expected pattern?
    function Test-LineMatchesExpected {
        param(
            [string] $Line,
            [string[]] $Patterns
        )
        foreach ($p in $Patterns) {
            if ($Line -match $p) { return $true }
        }
        return $false
    }

  
    # =======================================================================================================================
    # START of MAIN LOGIC - READ RESULTS FILE 
    # =======================================================================================================================

    # Validate results file
    if (-not (Test-Path -LiteralPath $ResultsPath)) {
        Write-Host "[ERROR]  Results file not found: $ResultsPath"
        return
    }

    # Only check for a prior choice if we're NOT ignoring it
    if (-not $IgnorePreviousChoice) {
        $choiceMatch = Select-String -LiteralPath $ResultsPath -Pattern '^[ ]*USER Chose - (.+)$' | Select-Object -Last 1
        if ($choiceMatch) {
            $userChoice = $choiceMatch.Matches[0].Groups[1].Value.Trim()
            Write-Host "[INFO]  Existing choice found: $userChoice"
            & (Join-Path $PSScriptRoot 'Implement-UserDecision.ps1') -Choice $userChoice
            return
        }
    }

    # =========================================================================================================
    # DISPLAY RESULTS WITH POSITIVE FILTER AND CONSISTENT COLOUR FORMATTING
    # =========================================================================================================

    # Whitelist of recognised line patterns
    $ExpectedPatterns = @(
        '^Windows11',                    # Header line (e.g., "Windows11 Computer Compatibility Results for - PCNAME")
        '^=+',                           # Equals underline (any length, e.g., "=======")
        '^-+$',                          # Single dash underline (e.g., "-------")
        '^_{2,}$',                       # Double underscore underline (two or more underscores)
        '^\s*$',                         # Wholly blank line (empty or only whitespace)
        '^\s{2,}\S',                     # Indented content: 2+ leading spaces, then non-space
        '^\s*\[PASSED\]',                # Status: PASSED
        '^\s*\[WARNING\]',               # Status: WARNING
        '^\s*\[FAILED\]',                # Status: FAILED
        '^(\s{0,4})([A-Z ]+:)(\s*)(.*)$' # Section headings: up to 4 leading spaces, ALL-CAPS token ending with colon
    )

    Clear-Screen
    $inHeader   = $false
    $lineNumber = 0

    Get-Content -LiteralPath $ResultsPath | ForEach-Object {
        $line = $_
        $lineNumber++

        # Top banner: cyan rules around the centred title (3 lines). On the title
        # line the "- <PC name>" tail is white, the rest yellow.
        if ($lineNumber -le 3) {
            if ($lineNumber -eq 2) {
                if ($line -match '^(.*Results for )(- .*)$') {
                    Write-AndCount "$Yellow$($Matches[1])$Bright_White$($Matches[2])$Reset"
                } else {
                    Write-AndCount "$Yellow$line$Reset"
                }
            } else {
                Write-AndCount "$Cyan$line$Reset"
            }
            return
        }

        # Skip audit entries
        if ($line -match '^\s*USER Chose -') { return }

        # Only process recognised lines
        if (-not (Test-LineMatchesExpected -Line $line -Patterns $ExpectedPatterns)) { return }

        # Start of a header (ALL CAPS token ending with :)
        if ($line -match '^(\s{0,4})([A-Z ]+:)') {
            $inHeader = $true
            Write-AndCount "$Yellow$line$Reset"
            return
        }

        # End of header when the status dash appears - column 13, since the
        # report body is now indented 2 spaces (was column 11).
        if ($inHeader -and $line.Length -ge 13 -and $line[12] -eq '-') {
            $inHeader = $false
        }

        # If still inside header, colour it
        if ($inHeader) {
            Write-AndCount "$Yellow$line$Reset"
            return
        }

        # PASSED / WARNING / FAILED - preserve whatever indent the line already carries
        if ($line -match '^(\s*)\[PASSED\]') {
            $indent = $Matches[1]
            $rest   = $line -replace '^\s*\[PASSED\]', ''
            Write-AndCount "$indent$Green[PASSED]$Reset$rest"
            return
        }
        if ($line -match '^(\s*)\[WARNING\]') {
            $indent = $Matches[1]
            $rest   = $line -replace '^\s*\[WARNING\]', ''
            Write-AndCount "$indent$Bright_White[WARNING]$Reset$rest"
            return
        }
        if ($line -match '^(\s*)\[FAILED\]') {
            $indent = $Matches[1]
            $rest   = $line -replace '^\s*\[FAILED\]', ''
            Write-AndCount "$indent$Red[FAILED]$Reset$rest"
            return
        }

        # Default
        Write-AndCount "$Gy$line$Reset"
    }

    # =========================================================================================================
    # If NOT in WinPE allow User to Print - asked first, before the install choice, since the user
    # may just want to print the Results and decide on FULL/BYPASS/Return later.
    # =========================================================================================================

    $inWinPE = $env:SystemRoot -like '*X:\Windows*'

    if (-not $inWinPE) {
        $printChoice = Prompt-ForUserChoice `
            -PromptRows @(" ", "$Y Would you like to print the above Results?") `
            -ValidChoices @("Y","N")

        if ($printChoice.Trim().ToUpper() -eq 'Y') {

            $defaultPrinter = Get-Printer 2>$null | Where-Object Default -eq $true
            if (-not $defaultPrinter) {
                $defaultPrinter = Get-CimInstance Win32_Printer | Where-Object Default -eq $true
            }

            if (-not $defaultPrinter) {
                Write-Host "$redB No default printer is set. Please configure one before printing.$reset"
            }
            else {
                Write-Host "$greenB Default printer detected: $($defaultPrinter.Name)$reset"

                try {
                    Get-Content -LiteralPath $ResultsPath | Out-Printer -Name $defaultPrinter.Name
                    Write-Host "$greenB Results file sent to the default printer via spooler.$reset"
                }
                catch {
                    Write-Host "$yellowB Direct spooler print failed: $($_.Exception.Message)$reset"
                    Write-Host "$greyLight Attempting Notepad print method...$reset"

                    try {
                        $fullResultsPath = (Resolve-Path -LiteralPath $ResultsPath).Path
                        Start-Process -FilePath "notepad.exe" -ArgumentList "/p `"$fullResultsPath`""
                        Write-Host "$greenB Results file sent to Notepad for printing.$reset"
                    }
                    catch {
                        Write-Host "$redB Printing failed via both methods: $($_.Exception.Message)$reset"
                    }
                }
            }
        }
        else {
            Write-Host "$greyLight Results file not printed.$reset"
        }
    }
    else {
        Write-Host "$greyLight Printing is not available in WinPE. Skipping print prompt.$reset"
    }

    # ================================================================================================================
    # DISPLAY ADVICE - Based on Parameters received
    # ================================================================================================================

    $PromptRows   = @()
    $ValidChoices = @()

    if ($Failed -gt 0) {
        $PromptRows = @(
            " ",
            " ${R}SORRY${Reset}. Your machine does not meet the minimum hardware requirements to run Windows 11.",
            " You will either have to:",
            "   - Upgrade your hardware to overcome the issues that were ${Red}[FAILED]${Reset} above.",
            "   - Buy a new computer.",
            "   - Continue using what you have.",
            " ",
            "${Y} Please ENTER"
        )
        $ValidChoices = @('')
    }
    elseif ($Warning -gt 0 -and $Warning -eq $WarnNotDetected) {
        $PromptRows = @(
            " ",
            " ${Y}Your Installation Options are:${Reset}",
            " ${Y}FULL${Reset} Install",
            "    Your machine MIGHT be fully capable of running Windows 11, as ALL the ${W}[WARNING]s${Reset} were",
            "    about things that could not be checked. But, if you choose a Full Install, it could fail.",
            "    If it fails the Installer will simply stop, and you will have wasted your time, that's all.",
            " ${Y}BYPASS${Reset} Install",
            "    This can be used to install Windows 11 on older machines that are capable of running Windows 11,",
            "    but which do not have the security enhancements necessary for a FULL Install.",
            "    Since ALL the ${W}[WARNING]s${Reset} were about things that could not be checked, this is your SAFE option.",
            "    But, of course, you will not have Windows 11 enhanced security features.",
            "    And, according to Microsoft, it could lead to future problems.",
            "    However, if you are confident that your Machine DOES have ALL the features ",
            "    that could not be checked,then you might get away with a FULL Install.",
            " ",
            "${Y} Please ENTER"
        )
        $ValidChoices = @('FULL','BYPASS','')
    }
    elseif ($Warning -gt 0 -and $Warning -ne $WarnNotDetected) {
        $PromptRows = @(
            " ",
            " ${Y}Your ONLY Installation Option is:${Reset}",
            " ${Y}BYPASS Install${reset}",
            "    This can be used to install Windows 11 on older machines that are capable of running ",
            "    Windows 11 that do not have the security enhancements necessary for a FULL install.",
            "    Since you have some ${W}[WARNING]s${Reset} above a FULL Install, is not an option.",
            " ",
            "${Y} Please ENTER"
        )
        $ValidChoices = @('BYPASS','')
    }
    else {
        $PromptRows = @(
            " ",
            "${Y} Your PC meets all requirements for Windows 11.${reset}",
            " So, BOTH installation options are possible:",
            " ${Y}FULL Install${reset}",
            "    Your machine is fully capable of running Windows 11, including all the additional",
            "    security features it enables. This should be your PREFERRED OPTION.",
            " ${Y}BYPASS Install${reset}",
            "    This is normally used to install Windows 11 on older machines that are capable of running it,",
            "    but lack the security enhancements required for a FULL INSTALL.",
            "    On YOUR machine, it is unnecessary to select this option.",
            "    Particularly because, according to Microsoft, it could lead to future problems.",
            " ",
            "${Y} Please ENTER"
        )
        $ValidChoices = @('FULL','BYPASS','')
    }

    # Prompt for User's Choice - using Dot-Sourced Function
    $userChoice = Prompt-ForUserChoice `
        -PromptRows   $PromptRows `
        -ValidChoices $ValidChoices `
        -ReturnKey_Pressed '<Return>'

    # Record the user's choice and execute the corresponding action
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()

    # Remove any "USER Chose -" lines from previous $ResultsPath
    (Get-Content $ResultsPath | Where-Object {$_ -notmatch '^USER Chose -'}) |
        Set-Content $ResultsPath

    # Add NEW "User Chose -" line to end of $ResultsPath
    try {
        "USER Chose - $userChoice" | Add-Content -LiteralPath $ResultsPath
    }
    catch {
        Write-Host "[ERROR] Failed to write choice to results file: $($_.Exception.Message)"
        $script:CurrentRowPosition += 1
    }

    if ($UserChoice -in @('FULL','BYPASS')) {
        # Safety net: if Install Windows.ps1 failed to load at startup, re-load it now
        if (-not (Get-Command 'INSTALL-Windows' -ErrorAction SilentlyContinue)) {
            . (Join-Path $PSScriptRoot 'WinFixIT\Install Windows.ps1')
        }
        INSTALL-Windows
        return
    }
} # END of - function Give-CompatibilityAdvice 




