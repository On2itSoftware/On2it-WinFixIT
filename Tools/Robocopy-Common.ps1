<#  Robocopy-Common.ps1
    ====================
       Purpose: Shared robocopy-with-dots helper used by BOTH the in-house
                Clone-WinFixIT-USB.ps1 build and the public Build-Your-USB.ps1
                build. Dot-sourced by each -- do NOT inline a second copy.

                A byte-identical copy of this file lives in the public repo at
                On2it-WinFixIT-USB-Public\Tools\Robocopy-Common.ps1. Run
                "COPY - Shared Scripts to Public Repo.bat" after editing this
                file to push the change to that copy (it still needs a manual
                `git add/commit/push` in the public repo after that to
                actually publish it).

        Method: Invoke-RobocopyDotsOnly runs robocopy as a background process
                and prints a dot per second until it exits, so a long copy
                doesn't sit silent. Builds one properly-quoted command-line
                string itself rather than passing the raw args array to
                Start-Process -ArgumentList, which does NOT reliably quote
                array elements containing spaces (e.g. "On2it Software
                Courses") -- confirmed 2026-07-12, silently split into bogus
                extra arguments and made robocopy fail with exit 16.

   Designed by: Brian McGuigan
            of: On2it Software Ltd
       Code by: Claude
       Version: 1
         Dated: 17-Jul-26
        Status: NEW
#>

function Invoke-RobocopyDotsOnly {
    param(
        [string[]]$RobocopyArgs,
        # This function has no progress signal of its own (unlike
        # Invoke-RobocopyDotsWithETA below) to detect a genuine stall, so this
        # is a generous wall-clock backstop rather than true stall detection.
        # Confirmed 2026-07-18: a copy can hang indefinitely with no error at
        # all if e.g. the destination USB drive stops responding mid-write -
        # nothing before this caught that. 60 min comfortably covers even a
        # multi-GB single file (the large-file pass) on a slow USB drive.
        [int]$MaxMinutes = 60
    )
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    $argString = ($RobocopyArgs | ForEach-Object {
        if ($_ -match '\s') { '"' + ($_ -replace '\\+$', '') + '"' } else { $_ }
    }) -join ' '
    $proc = Start-Process -FilePath 'robocopy.exe' -ArgumentList $argString -NoNewWindow -PassThru `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile

    $startTime = Get-Date
    while (-not $proc.HasExited) {
        Write-Host -NoNewline '.'
        Start-Sleep -Seconds 1

        if (((Get-Date) - $startTime).TotalMinutes -ge $MaxMinutes) {
            try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { }
            Write-Host ""
            Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
            throw "Copy stalled -- still running after $MaxMinutes minutes with no sign of finishing. Check the USB drive is still connected (or that the PC didn't go to sleep) and re-run this script."
        }
    }
    Write-Host ''
    Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
    return $proc.ExitCode
}

# Same as Invoke-RobocopyDotsOnly, but also prints MB copied + a rough ETA every
# ~60s for copies big enough to need one, measured via the destination volume's
# free-space delta. Redraws the dots/status in place on 2 fixed console rows
# (same proven technique as Invoke-DownloadWithDots in Build-Your-USB.ps1 --
# fresh row/width computed at each redraw, not stored once up front, so it
# self-corrects instead of drifting if the console is resized or scrolled) --
# falls back to plain scrolling if cursor positioning isn't available.
# Deliberately NOT named Invoke-RobocopyWithDots -- Clone-WinFixIT-USB.ps1
# already defines its own (more complex, stall-detecting) function by that
# name, and since its dot-source of this file runs AFTER that definition, a
# same-named function here would silently overwrite it.
# ExpectedTotalMB is optional -- pass 0 (or omit) for a copy too small/fast to
# bother with an ETA, and it behaves exactly like Invoke-RobocopyDotsOnly.
function Invoke-RobocopyDotsWithETA {
    param(
        [string[]]$RobocopyArgs,
        [char]$DestDriveLetter,
        [double]$ExpectedTotalMB = 0
    )
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    $argString = ($RobocopyArgs | ForEach-Object {
        if ($_ -match '\s') { '"' + ($_ -replace '\\+$', '') + '"' } else { $_ }
    }) -join ' '
    $proc = Start-Process -FilePath 'robocopy.exe' -ArgumentList $argString -NoNewWindow -PassThru `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile

    $startFreeBytes = (Get-Volume -DriveLetter $DestDriveLetter -ErrorAction SilentlyContinue).SizeRemaining
    $canMeasure     = ($ExpectedTotalMB -gt 0) -and ($null -ne $startFreeBytes)

    $canRedraw = $false
    try {
        $null = [Console]::WindowWidth   # just probing that cursor/console control works at all
        $canRedraw = $true
    } catch { }

    $startTime      = Get-Date
    $lastStatusTime = $startTime
    $lastStatusRow  = $null   # tracks where to land the cursor cleanly once the loop ends
    $lastProgressMB = 0
    $stalledChecks  = 0
    $MAX_STALLED_CHECKS = 5   # ~5 minutes of zero progress (checked once per 60s tick) -- same
                              # threshold and shape as the download's stall detector. Confirmed
                              # 2026-07-18: Pam's PC had its display sleep mid-copy and the copy
                              # itself hung with no error, just dots that stopped meaning anything.

    while (-not $proc.HasExited) {
        Write-Host -NoNewline '.'
        Start-Sleep -Seconds 1

        if ($canMeasure -and ((Get-Date) - $lastStatusTime).TotalSeconds -ge 60) {
            $lastStatusTime = Get-Date
            $currentFree = (Get-Volume -DriveLetter $DestDriveLetter -ErrorAction SilentlyContinue).SizeRemaining
            if ($null -ne $currentFree) {
                $writtenMB = [math]::Max(0, [math]::Round(($startFreeBytes - $currentFree) / 1MB, 0))

                if ($writtenMB -le $lastProgressMB) {
                    $stalledChecks++
                    if ($stalledChecks -ge $MAX_STALLED_CHECKS) {
                        try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { }
                        Write-Host ""
                        Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
                        throw "Copy stalled -- no progress for $MAX_STALLED_CHECKS minutes. Check the USB drive is still connected (or that the PC didn't go to sleep) and re-run this script."
                    }
                } else {
                    $stalledChecks = 0
                }
                $lastProgressMB = $writtenMB

                $elapsedMin = ((Get-Date) - $startTime).TotalMinutes
                $rateMBmin  = if ($elapsedMin -gt 0) { $writtenMB / $elapsedMin } else { 0 }
                # NTFS cluster rounding means actual disk space consumed (what
                # free-space-delta measures) can end up slightly ABOVE the raw
                # source byte-sum passed in as ExpectedTotalMB, especially with
                # many thousands of small files (confirmed 2026-07-18: written
                # exceeded expected near the end of a large copy) - show "almost
                # done" rather than just silently dropping the ETA text.
                $etaText = if ($writtenMB -ge $ExpectedTotalMB) {
                    " (almost done)"
                } elseif ($rateMBmin -gt 0) {
                    " (about $([math]::Ceiling(($ExpectedTotalMB - $writtenMB) / $rateMBmin)) min remaining)"
                } else { "" }
                $statusLine = "  {0:N0} MB copied so far{1}" -f $writtenMB, $etaText

                if ($canRedraw) {
                    try {
                        $windowWidth = [Console]::WindowWidth
                        Write-Host ""
                        $statusRow = [Console]::CursorTop
                        $dotsRow   = $statusRow - 1
                        $lastStatusRow = $statusRow

                        [Console]::SetCursorPosition(0, $statusRow)
                        Write-Host -NoNewline (' ' * ($windowWidth - 1))
                        [Console]::SetCursorPosition(0, $statusRow)
                        Write-Host -NoNewline $statusLine -ForegroundColor DarkGray

                        [Console]::SetCursorPosition(0, $dotsRow)
                        Write-Host -NoNewline (' ' * ($windowWidth - 1))
                        [Console]::SetCursorPosition(0, $dotsRow)
                    } catch {
                        $canRedraw = $false
                    }
                } else {
                    Write-Host ""
                    Write-Host $statusLine -ForegroundColor DarkGray
                    Write-Host -NoNewline "  "
                }
            }
        }
    }

    if ($canRedraw -and $null -ne $lastStatusRow) {
        try { [Console]::SetCursorPosition(0, $lastStatusRow + 1) } catch { Write-Host "" }
    } else {
        Write-Host ""
    }

    Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
    return $proc.ExitCode
}

# Splits a source folder's files into "large" (>= 1GB, matches the in-house
# build's $LARGE_FILE_THRESHOLD_BYTES) and everything else. Without this split,
# one or two multi-GB files (bundled ISOs, portable app archives) skew the
# free-space-delta ETA above badly -- confirmed 2026-07-18: NTFS/robocopy can
# reserve a large file's full size on disk the moment it starts, so free space
# stops dropping incrementally while robocopy is still mid-write on that one
# file, which looks exactly like a stall to the ETA math (climbing "min
# remaining" instead of counting down, same shape as the download stall bug).
function Get-LargeFileSplit {
    param(
        [string]$SourceRoot,
        [double]$ThresholdBytes = 1GB
    )
    $allFiles = Get-ChildItem -LiteralPath $SourceRoot -Recurse -File -Force -ErrorAction SilentlyContinue
    $largeFiles = @($allFiles | Where-Object { $_.Length -ge $ThresholdBytes })
    $smallBytes = ($allFiles | Where-Object { $_.Length -lt $ThresholdBytes } | Measure-Object -Property Length -Sum).Sum
    if (-not $smallBytes) { $smallBytes = 0 }
    [PSCustomObject]@{
        LargeFiles = $largeFiles
        SmallMB    = [math]::Ceiling($smallBytes / 1MB)
    }
}

# Copies each large file individually first (dots only -- there's no reliable
# way to show progress within a single huge file), then runs the normal
# full-tree small-pass args for everything else with a live MB/ETA. Robocopy's
# default same-size/timestamp skip means the small-file pass won't re-copy what
# the large-file pass already placed.
function Invoke-RobocopyLargeThenSmall {
    param(
        [string]$SourceRoot,
        [char]$DestDriveLetter,
        [System.IO.FileInfo[]]$LargeFiles,
        [double]$SmallMB,
        [string[]]$SmallPassArgs
    )
    $sourceRootTrim = $SourceRoot.TrimEnd('\')

    if ($LargeFiles.Count -gt 0) {
        Write-Host "  Copying $($LargeFiles.Count) large file$(if ($LargeFiles.Count -ne 1) { 's' }) first (no live progress within each -- please wait)..." -ForegroundColor Cyan
        foreach ($file in $LargeFiles) {
            $relativePath = $file.FullName.Substring($sourceRootTrim.Length).TrimStart('\')
            $relativeDir  = Split-Path $relativePath -Parent
            $srcDir  = if ($relativeDir) { Join-Path $sourceRootTrim $relativeDir } else { $sourceRootTrim }
            $destDir = if ($relativeDir) { "$DestDriveLetter`:\$relativeDir" } else { "$DestDriveLetter`:\" }

            Write-Host ("  Copying {0} ({1:N0} MB)..." -f $file.Name, [math]::Round($file.Length / 1MB, 0)) -ForegroundColor Cyan
            $exitCode = Invoke-RobocopyDotsOnly -RobocopyArgs @(
                "$srcDir\", "$destDir\", $file.Name,
                '/J', '/COPY:DAT', '/DCOPY:DAT', '/R:2', '/W:5', '/NFL', '/NDL', '/NJH', '/NJS'
            )
            if ($exitCode -ge 8) { throw "Robocopy failed copying '$($file.Name)' (exit $exitCode)." }
        }
        Write-Host ""
    }

    Write-Host ("  Copying remaining files... ({0:N0} MB)" -f $SmallMB) -ForegroundColor Cyan
    return Invoke-RobocopyDotsWithETA -DestDriveLetter $DestDriveLetter -ExpectedTotalMB $SmallMB -RobocopyArgs $SmallPassArgs
}
