<#  Install-WinFixIT-Local.ps1
    ===========================
       Purpose: Installs WinFixIT to the local PC so it runs without the USB.
                Copies both USB partitions to C:\Program Files\WinFixIT\,
                creates a local launcher bat, and adds a Start Menu shortcut.

                Also copies the On2it Software Courses partition locally, if
                the USB has one (a client USB legitimately doesn't), and adds
                a second Start Menu shortcut for it - Brian, 2026-08-22:
                "once we have 'installed' WinFixIT on a PC, we still won't be
                able to view Course Notes without the USB." "There is no-
                point in creating an 'On2it Software Courses' Folder if there
                is no content on the USB" - so this is entirely skipped when
                $env:USB_COURSES is empty.

                Deliberately does NOT reuse the USB's own "OPEN - On2it
                Software Courses.bat" as-is - that file scans every drive
                letter for a REAL USB, falling back to a path on Brian's own
                dev machine if none is found. It has no concept of "installed
                locally, no USB, no dev tree" at all, so copying it verbatim
                would silently fail (or only work by accident if a USB
                happens to be plugged in) on a student's PC. Instead this
                generates its own small local launcher with the local paths
                baked in - the exact same pattern already used a few lines
                below for WinFixIT's own local launcher/shortcut.

        Calls from: Y:\Install\Applications\WinFixIT\Start.bat
        Environment: $env:USB_INSTALL and $env:USB_POSTINSTALL set by
                WinFixIT.ps1 (both required); $env:USB_COURSES too (empty
                string, not unset, when this USB has no Courses content).

   Designed by: Brian McGuigan
            of: On2it Software Ltd
       Code by: Claude
       Version: 2 (also installs Course Notes locally, when present)
         Dated: 22-Aug-26
        Status: TESTED
#>

# ---------------------------------------------------------------------------
#  Paths
# ---------------------------------------------------------------------------
$WinFixITRoot  = "C:\Program Files\WinFixIT"
$LocalInstall  = "$WinFixITRoot\Local-INSTALL"
$PostInstall   = "$WinFixITRoot\On2it-WinFixIT"
$LauncherPath  = "$WinFixITRoot\WinFixIT.bat"
$IconDest      = "$WinFixITRoot\WinFixIT.ico"
$ShortcutPath  = "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\WinFixIT.lnk"

$UsbInstall    = $env:USB_INSTALL.TrimEnd('\')
$UsbPostInstall= $env:USB_POSTINSTALL.TrimEnd('\')
$IconSource    = "$UsbInstall\WinFixIT.ico"

# --- Course Notes (optional - empty string when this USB has none) ---
$UsbCourses         = if ($env:USB_COURSES) { $env:USB_COURSES.TrimEnd('\') } else { '' }
$hasCourses         = -not [string]::IsNullOrEmpty($UsbCourses)
$CoursesLocal       = "$WinFixITRoot\On2it Software Courses"
$CoursesLauncherPath= "$WinFixITRoot\On2it Software Courses.bat"
$CoursesIconDest    = "$WinFixITRoot\On2it.ico"
$CoursesShortcutPath= "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\On2it Software Courses.lnk"
# Expected to live at the Courses partition ROOT (parallel to WinFixIT.ico
# living at USB-INSTALL's root) - not created by this script. Staged there
# by Copy - Selected Courses into PRODUCTION.ps1 (added 2026-08-22, once
# Brian picked the "Notebook Tag" concept and Claude built the actual
# artwork). Missing icon is still handled the same non-fatal way as
# WinFixIT's own icon below, e.g. on an older USB built before this existed.
$CoursesIconSource  = "$UsbCourses\On2it.ico"

# ---------------------------------------------------------------------------
#  Confirm elevated
# ---------------------------------------------------------------------------
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host ""
    Write-Host "  ERROR: This script must be run as Administrator." -ForegroundColor Red
    Write-Host "  Please re-launch WinFixIT as Administrator and try again."
    Write-Host ""
    Pause
    exit 1
}

# ---------------------------------------------------------------------------
#  Confirm env vars are set
# ---------------------------------------------------------------------------
if (-not $env:USB_INSTALL -or -not $env:USB_POSTINSTALL) {
    Write-Host ""
    Write-Host "  ERROR: USB partition paths not found." -ForegroundColor Red
    Write-Host "  Please run this option from within WinFixIT, not standalone."
    Write-Host ""
    Pause
    exit 1
}

# ---------------------------------------------------------------------------
#  Summary before proceeding
# ---------------------------------------------------------------------------
Clear-Host
Write-Host ""
Write-Host "  ================================================================" -ForegroundColor Cyan
Write-Host "    WinFixIT - Local PC Install" -ForegroundColor White
Write-Host "  ================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  This will copy WinFixIT to your PC so it runs without the USB." -ForegroundColor Gray
Write-Host ""
Write-Host "  From  : $UsbInstall\"                               -ForegroundColor Gray
Write-Host "    To  : $LocalInstall\"                             -ForegroundColor Gray
Write-Host ""
Write-Host "  From  : $UsbPostInstall\"                           -ForegroundColor Gray
Write-Host "    To  : $PostInstall\"                              -ForegroundColor Gray
Write-Host ""
if ($hasCourses) {
    Write-Host "  From  : $UsbCourses\"                               -ForegroundColor Gray
    Write-Host "    To  : $CoursesLocal\"                             -ForegroundColor Gray
    Write-Host ""
}
Write-Host "  Shortcut will be added to the Start Menu.$(if ($hasCourses) { ' (and one for Course Notes too)' })" -ForegroundColor Gray
Write-Host ""

Write-Host "  Proceed? (Y/N): " -NoNewline -ForegroundColor Yellow
$confirm = Read-Host
if ($confirm -notmatch '^[Yy]') {
    Write-Host ""
    Write-Host "  Cancelled." -ForegroundColor Yellow
    Write-Host ""
    Pause
    exit 0
}

# ---------------------------------------------------------------------------
#  Create target directories
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "  Creating folders..." -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $WinFixITRoot  | Out-Null
New-Item -ItemType Directory -Force -Path $LocalInstall  | Out-Null
# $PostInstall is deliberately NOT pre-created here - the "already exists locally,
# update from USB?" prompt further down checks Test-Path $PostInstall to decide
# whether this is a fresh install or a re-install. Pre-creating it unconditionally
# meant that check was always true (even on a genuinely fresh install), so the
# default "N" answer silently skipped the entire ~20 GB copy while the rest of the
# script still reported "Installation Complete!" - confirmed for real 2026-07-12,
# left On2it-WinFixIT completely empty after a "successful" install. Robocopy
# creates the destination folder itself when the copy actually runs, so this
# isn't even needed for that - only removing it fixes the false "already exists" check.

# ---------------------------------------------------------------------------
#  Runs robocopy in the background, printing a dot roughly once a second so a
#  large copy (On2it-WinFixIT can be ~20 GB from USB) never looks hung. No
#  live MB/rate/ETA - see CLONE-WinFixIT-USB.ps1's Invoke-RobocopyDotsOnly:
#  neither free-space polling nor robocopy's own log can be trusted for
#  accurate progress within a copy, so this deliberately doesn't try - just a
#  heartbeat and the real elapsed time once it's actually done.
# ---------------------------------------------------------------------------
function Invoke-RobocopyDotsOnly {
    param([string[]]$RobocopyArgs)
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    # Start-Process -ArgumentList does NOT reliably quote array elements containing
    # spaces (e.g. "C:\Program Files\...") - it just joins them with spaces, so a
    # space-containing path silently splits into multiple bogus arguments and
    # robocopy fails with exit 16 ("Invalid Parameter"). Confirmed 2026-07-12 - this
    # is exactly what broke the local install on Test-PC (destination is always
    # under "C:\Program Files\..."). Fix: build one properly quoted command-line
    # string ourselves. Also strip any trailing backslash from quoted elements -
    # a path ending in \" is parsed by Windows as an escaped quote character, not
    # "backslash then close-quote", which silently swallows everything after it.
    $argString = ($RobocopyArgs | ForEach-Object {
        if ($_ -match '\s') { '"' + ($_ -replace '\\+$', '') + '"' } else { $_ }
    }) -join ' '
    $proc = Start-Process -FilePath 'robocopy.exe' -ArgumentList $argString -NoNewWindow -PassThru `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    while (-not $proc.HasExited) {
        Write-Host -NoNewline '.'
        Start-Sleep -Seconds 1
    }
    Write-Host ''
    Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
    return $proc.ExitCode
}

# ---------------------------------------------------------------------------
#  Copy USB-INSTALL partition  (Scripts, bat files, manual etc.)
#  Exclude: Logs, System Volume Information, .git
# ---------------------------------------------------------------------------
Write-Host "  Copying USB-INSTALL partition..." -ForegroundColor Cyan
Write-Host "    From: $UsbInstall\" -ForegroundColor Gray
Write-Host "      To: $LocalInstall\" -ForegroundColor Gray
Write-Host "  Please be patient - copying from USB can take a while." -ForegroundColor Gray
# /COPY:DATS, not /COPYALL (=/COPY:DATSOU) - the Owner and Auditing-info
# components need SeSecurityPrivilege, which a plain elevated Administrator
# account doesn't automatically hold (needs to be explicitly granted via
# security policy) - confirmed 2026-07-12: this failed with robocopy exit 16
# ("serious error... insufficient access privileges") on Test-PC because of it.
$exitCode = Invoke-RobocopyDotsOnly -RobocopyArgs @(
    "$UsbInstall\", "$LocalInstall\", '/E', '/COPY:DATS', '/DCOPY:DAT', '/NFL', '/NDL', '/NJH', '/NJS',
    '/XD', 'Logs', 'System Volume Information', '.git'
)
if ($exitCode -ge 8) {
    Write-Host "  ERROR: Copy failed (robocopy exit $exitCode)." -ForegroundColor Red
    Pause; exit 1
}

# ---------------------------------------------------------------------------
#  Copy On2it-WinFixIT partition
#  Exclude: System Volume Information
#  On reinstall, offer to skip (large files rarely change)
# ---------------------------------------------------------------------------
$copyPostInstall = $true
if (Test-Path $PostInstall) {
    Write-Host ""
    Write-Host "  On2it-WinFixIT partition already exists locally." -ForegroundColor Gray
    Write-Host "  Update it from USB? (Y/N) [N]: " -NoNewline -ForegroundColor Yellow
    $r = Read-Host
    $copyPostInstall = $r -match '^[Yy]'
}
if ($copyPostInstall) {
    Write-Host "  Copying On2it-WinFixIT partition..." -ForegroundColor Cyan
    Write-Host "    From: $UsbPostInstall\" -ForegroundColor Gray
    Write-Host "      To: $PostInstall\" -ForegroundColor Gray
    Write-Host "  Please be patient - this is often 20+ GB, so it can take some time." -ForegroundColor Gray
    $exitCode = Invoke-RobocopyDotsOnly -RobocopyArgs @(
        "$UsbPostInstall\", "$PostInstall\", '/E', '/COPY:DATS', '/DCOPY:DAT', '/NFL', '/NDL', '/NJH', '/NJS',
        '/XD', 'System Volume Information'
    )
    if ($exitCode -ge 8) {
        Write-Host "  ERROR: Copy failed (robocopy exit $exitCode)." -ForegroundColor Red
        Pause; exit 1
    }
} else {
    Write-Host "  On2it-WinFixIT update skipped." -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
#  Copy On2it Software Courses partition, if this USB has one
#  Deliberately unconditional (always re-copy, no "update?" prompt) - Brian's
#  own plan for keeping local Course Notes current: "they will already have
#  an Updated USB, created in class so all they would need to do was re-
#  install WinFixIT." Matches USB-INSTALL's own simpler always-copy pattern
#  above, not On2it-WinFixIT's skip-by-default one (Courses content is small
#  - tens of MB, not 20+ GB - so there's no real cost to just always doing it).
# ---------------------------------------------------------------------------
if ($hasCourses) {
    Write-Host "  Copying On2it Software Courses partition..." -ForegroundColor Cyan
    Write-Host "    From: $UsbCourses\" -ForegroundColor Gray
    Write-Host "      To: $CoursesLocal\" -ForegroundColor Gray
    $exitCode = Invoke-RobocopyDotsOnly -RobocopyArgs @(
        "$UsbCourses\", "$CoursesLocal\", '/E', '/COPY:DATS', '/DCOPY:DAT', '/NFL', '/NDL', '/NJH', '/NJS',
        '/XD', 'System Volume Information'
    )
    if ($exitCode -ge 8) {
        Write-Host "  ERROR: Copy failed (robocopy exit $exitCode)." -ForegroundColor Red
        Pause; exit 1
    }
}

# ---------------------------------------------------------------------------
#  Copy icon(s)
# ---------------------------------------------------------------------------
Write-Host "  Copying icon..." -ForegroundColor Cyan
if (Test-Path $IconSource) {
    Copy-Item $IconSource $IconDest -Force
} else {
    Write-Host "  WARNING: Icon not found at $IconSource — shortcut will use default icon." -ForegroundColor Yellow
}
if ($hasCourses) {
    if (Test-Path $CoursesIconSource) {
        Copy-Item $CoursesIconSource $CoursesIconDest -Force
    } else {
        Write-Host "  WARNING: Icon not found at $CoursesIconSource — Course Notes shortcut will use default icon." -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
#  Create local launcher bat
# ---------------------------------------------------------------------------
Write-Host "  Creating launcher..." -ForegroundColor Cyan
$launcher = @"
@echo off
REM RUN - WinFixIT (Local Install)
REM ================================
set "WINFIXITROOT=C:\Program Files\WinFixIT"
set "PSFILE=%WINFIXITROOT%\Local-INSTALL\Scripts\WinFixIT.ps1"

net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

where pwsh >nul 2>&1
if %errorlevel%==0 (set "PSCMD=pwsh.exe") else (set "PSCMD=powershell.exe")

mode con: cols=120 lines=58
start "WinFixIT" "%PSCMD%" -NoExit -ExecutionPolicy Bypass -File "%PSFILE%"
"@
$launcher | Set-Content -Path $LauncherPath -Encoding ASCII

# ---------------------------------------------------------------------------
#  Create Start Menu shortcut
# ---------------------------------------------------------------------------
Write-Host "  Creating Start Menu shortcut..." -ForegroundColor Cyan
$pwshCmd  = Get-Command pwsh.exe -ErrorAction SilentlyContinue
$pwsh     = 'powershell.exe'
if ($pwshCmd) { $pwsh = $pwshCmd.Source }
$psFile   = "$LocalInstall\Scripts\WinFixIT.ps1"
$psCmd    = "`$env:WINFIXITROOT='$WinFixITRoot'; & '$psFile'"

$wsh      = New-Object -ComObject WScript.Shell
$shortcut = $wsh.CreateShortcut($ShortcutPath)
$shortcut.TargetPath       = $pwsh
$shortcut.Arguments        = "-NoExit -ExecutionPolicy Bypass -Command `"$psCmd`""
$shortcut.WorkingDirectory = $WinFixITRoot
$shortcut.Description      = "On2it WinFixIT - Windows Fix and Install Tool"
if (Test-Path $IconDest) { $shortcut.IconLocation = "$IconDest,0" }
$shortcut.Save()

# Set "Run as Administrator" flag (byte 0x15, bit 0x20) in the .lnk binary
$lnkBytes = [System.IO.File]::ReadAllBytes($ShortcutPath)
$lnkBytes[0x15] = $lnkBytes[0x15] -bor 0x20
[System.IO.File]::WriteAllBytes($ShortcutPath, $lnkBytes)

# ---------------------------------------------------------------------------
#  Create local Course Notes launcher + Start Menu shortcut, if this USB has
#  Course Notes content. See header note for why this is a purpose-built
#  local launcher rather than a copy of the USB's own "OPEN - On2it Software
#  Courses.bat" - that file's drive-scanning fallback has no concept of a
#  local install, so copying it verbatim wouldn't reliably work here.
#  Mirrors the real launcher's own mechanics (conhost.exe, PS7-with-5.1-
#  fallback, Launch-Menu.ps1 -MenuRoot/-TopLevelTitle) with local paths
#  baked in instead of drive-scanning. No "Run as Administrator" flag here,
#  unlike WinFixIT's own shortcut above - Course Notes never needed
#  elevation, same reasoning as the real launcher's own header comment.
# ---------------------------------------------------------------------------
if ($hasCourses) {
    Write-Host "  Creating Course Notes launcher..." -ForegroundColor Cyan
    $coursesPsFile = "$LocalInstall\Scripts\WinFixIT\Launch-Menu.ps1"
    $coursesLauncher = @"
@echo off
REM On2it Software Courses (Local Install)
REM =======================================
set "PSFILE=$coursesPsFile"
set "MENUROOT=$CoursesLocal\On2it Software Courses"

where pwsh >nul 2>&1
if %errorlevel%==0 (set "PSCMD=pwsh.exe") else (set "PSCMD=powershell.exe")

mode con: cols=120 lines=58
start "On2it Software - Course Notes" conhost.exe "%PSCMD%" -ExecutionPolicy Bypass -File "%PSFILE%" -MenuRoot "%MENUROOT%" -TopLevelTitle "On2it Software - Course Notes"
"@
    $coursesLauncher | Set-Content -Path $CoursesLauncherPath -Encoding ASCII

    Write-Host "  Creating Course Notes Start Menu shortcut..." -ForegroundColor Cyan
    $coursesShortcut = $wsh.CreateShortcut($CoursesShortcutPath)
    $coursesShortcut.TargetPath       = $CoursesLauncherPath
    $coursesShortcut.WorkingDirectory = $WinFixITRoot
    $coursesShortcut.Description      = "On2it Software Courses - Course Notes"
    if (Test-Path $CoursesIconDest) { $coursesShortcut.IconLocation = "$CoursesIconDest,0" }
    $coursesShortcut.Save()
}

# ---------------------------------------------------------------------------
#  Done
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "  ================================================================" -ForegroundColor Cyan
Write-Host "    Installation Complete!" -ForegroundColor Green
Write-Host "  ================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  WinFixIT is now installed at:"                                    -ForegroundColor Gray
Write-Host "    $WinFixITRoot"                                                  -ForegroundColor White
Write-Host ""
Write-Host "  WinFixIT has been added to your Start Menu (All Apps)."          -ForegroundColor Gray
if ($hasCourses) {
    Write-Host "  On2it Software Courses has been added too, so Course Notes" -ForegroundColor Gray
    Write-Host "  can be opened without the USB." -ForegroundColor Gray
}
Write-Host ""
Write-Host "  To pin it to the TOP of the Start Menu:"                         -ForegroundColor Gray
Write-Host "    Start Menu → find WinFixIT → right-click → Pin to Start"       -ForegroundColor White
Write-Host "  (Microsoft's security does not permit this to be done"            -ForegroundColor DarkGray
Write-Host "   programmatically — you will need to do it yourself.)"           -ForegroundColor DarkGray
Write-Host ""
Write-Host "  To pin it to the Taskbar:"                                        -ForegroundColor Gray
Write-Host "    Start Menu → find WinFixIT → right-click → Pin to taskbar"     -ForegroundColor White
Write-Host ""
Pause
