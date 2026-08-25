<# Build-Your-USB.ps1
   ==================
       Purpose: Public build script. Downloads the large On2it-WinFixIT content,
                the WinPE boot files, and the (private, unlisted) Scripts bundle
                from Cloudflare R2, then partitions a USB drive and copies
                USB-INSTALL (bundled in this repo) + the downloaded content onto it.
                
                This is the public counterpart to the internal
                Clone-WinFixIT-USB.ps1 build script used in-house — same
                partitioning/copy logic, but pulls the large content from public
                (or unlisted) download links instead of a local company source
                drive, and does not offer the Courses partition (not distributed
                publicly).

                Source (local, this repo):
                    USB-INSTALL\                  → P1 (FAT32, 1 GB, read-only)

                Source (downloaded from Cloudflare R2):
                    On2it-WinFixIT content         → P2 (NTFS, remainder)
                    WinPE boot files               → P1 (too large for git; bootmgr,
                                                        EFI\, Boot\, sources\boot.wim)
                    Scripts bundle                 → P1\Scripts (hidden after copy)

   Designed by: Brian McGuigan
            of: On2it Software Ltd
       Code by: Claude
       Version: 6 (reworded the "found a previous download" prompt - R now
                means Re-use, D means Download again, with a leading
                "Downloading X..." header before the prompt so it's clear
                which file's being asked about; download-progress cursor
                now lands on a fresh line with
                two RELATIVE newlines instead of absolute SetCursorPosition
                arithmetic - was gluing "Download complete." straight onto
                the end of the still-visible status line with no break;
                USB disk selection now waits and asks for the right
                capacity instead of throwing if none is plugged in / big
                enough; extraction cache now keyed to the zip's own hash
                instead of just "did extraction happen before", fixing a
                stale-content bug that under-reported the USB size needed;
                dropped -NoExit on the elevated relaunch - was leaving the
                window open at a bare prompt even after "Press Enter to
                close" had been answered, same fix already confirmed for
                CREATE - WinFixIT USB.ps1; fixed a pre-existing text-
                encoding corruption throughout the file's own comments)
         Dated: 24-Aug-26
        Status: Reviewed and tested against a live R2 bucket; boot files added
                after the original version shipped without them.
#>

# ─── Self-elevate ──────────────────────────────────────────────────────────────
# Double-clicking / "Run with PowerShell" launches this without admin rights.
# Relaunch elevated (triggers a UAC prompt) and hand off to that instance.
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    try {
        # -NoExit deliberately NOT used here - Brian, 2026-08-24: confirmed the
        # same "window stays open at a bare prompt" symptom already fixed in
        # CREATE - WinFixIT USB.ps1 on 2026-08-20 ("Press enter to close, need
        # to close Window Too"). That fix was to drop -NoExit entirely, since
        # this script already has its own "Press Enter to close" pause on both
        # the success path and the catch block below - -NoExit was never
        # needed for that, and Windows PowerShell can swallow a script's own
        # `exit` under -NoExit + -File, leaving the window sitting open at an
        # interactive prompt even after the user already answered the pause.
        Start-Process powershell.exe -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
        ) -ErrorAction Stop
    } catch {
        Write-Host ""
        Write-Host "  Failed to elevate to Administrator:" -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""
        Write-Host "  This usually means UAC was cancelled, or a policy is blocking" -ForegroundColor White
        Write-Host "  elevation for this account. Log in with an administrator" -ForegroundColor White
        Write-Host "  account and try again." -ForegroundColor White
        Write-Host ""
        Write-Host "  Press Enter to close: " -NoNewline -ForegroundColor Yellow
        Read-Host
    }
    exit
}

# ─── Configuration ────────────────────────────────────────────────────────────
$PostInstallZipUrl  = 'https://pub-ef7ad4a1315f418ea10408fd91c554c7.r2.dev/On2it-WinFixIT.zip'       # public link -- OK to be listed anywhere
$ScriptsZipUrl       = 'https://pub-ef7ad4a1315f418ea10408fd91c554c7.r2.dev/USB-INSTALL-Scripts.zip' # UNLISTED link -- do not publish/index this URL
$BootZipUrl          = 'https://pub-ef7ad4a1315f418ea10408fd91c554c7.r2.dev/USB-INSTALL-Boot.zip'    # public link -- WinPE boot binaries (too large for git)

# SHA256 checksums of the zips above, verified after every download (fresh or
# cached) to catch a truncated/corrupted download before it silently breaks the build.
$PostInstallZipHash = '2E9E15D2EB9F7520B909679D1EDA2D1F149212C24C3920D32902FE1BAE9542CA'
$ScriptsZipHash      = 'A10B0E936E32389D0688D40C28720D6BAAF6CAEAB59A445576F8E7537219691E'
$BootZipHash         = '9BE793028A0061A9E3066D0F99E9D1191FDA5D3B9ADE40B4C833562A5964C045'

$ScriptRoot   = $PSScriptRoot
$SRC_INSTALL  = Join-Path $ScriptRoot 'USB-INSTALL'

$P1_SIZE_MB      = 1024   # USB-INSTALL - FAT32 - 1 GB
$P3_SIZE_MB      = 1024   # Reserved (Courses)  - NTFS - 1 GB, structure only, never populated publicly
$GPT_OVERHEAD_MB = 50     # Safety margin for GPT metadata and alignment

$SAFE_LIST = @(
    '1. Purpose of USB-INSTALL Partition.txt',
    'RUN - On2it-WinFixIT.bat',
    'RUN - Win11-DeBloater.bat',
    'WinFixIT - User Manual.pdf',
    'Logs'
)
# Note: 'Scripts' is intentionally NOT in this list — hidden on the built USB,
# same as the internal distribution build.
# ──────────────────────────────────────────────────────────────────────────────

$ErrorActionPreference = 'Stop'
# Suppresses Invoke-WebRequest's default progress bar, which mislabels large
# downloads as "Writing web request / Writing request stream" (confusing --
# reads like an upload) and slows big transfers down with per-chunk UI updates.
$ProgressPreference = 'SilentlyContinue'

# ─── Prevent the system from sleeping during the build ────────────────────────
# Confirmed 2026-07-17: Windows sleep is driven by user input idle time, NOT by
# background CPU/network/disk activity - a script like this gets zero automatic
# protection. A PC going to sleep mid-download killed a 50+ minute run (the
# network connection dropped, and Invoke-WebRequest has no timeout, so it just
# hung with an ever-growing ETA instead of erroring). Media players call this
# same Win32 API while video plays, which is why watching TV normally prevents
# sleep - but only for as long as the player keeps requesting it. This does the
# same for the whole build (download + partition + copy), released in the
# `finally` block at the very end regardless of success or failure.
# ES_DISPLAY_REQUIRED added 2026-07-18 -- ES_SYSTEM_REQUIRED alone keeps the
# SYSTEM awake but does NOT stop the DISPLAY from blanking on its own timeout
# (confirmed live during Pam's test: no failure warning shown, so the API call
# had succeeded, but the screen still went blank on an ASUS All-in-One desktop).
$ES_CONTINUOUS       = [uint32]0x80000000L   # the L forces this to parse as Int64 first --
$ES_SYSTEM_REQUIRED  = [uint32]0x00000001L   # 0x80000000 alone overflows Int32 and fails the cast
$ES_DISPLAY_REQUIRED = [uint32]0x00000002L
$sleepPreventionActive = $false
try {
    Add-Type -Name Kernel32 -Namespace Win32SleepPrevention -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern uint SetThreadExecutionState(uint esFlags);
'@ -ErrorAction Stop
    [Win32SleepPrevention.Kernel32]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED -bor $ES_DISPLAY_REQUIRED) | Out-Null
    $sleepPreventionActive = $true
} catch {
    Write-Host "  NOTE: Could not disable sleep for this build -- if the PC sleeps mid-run," -ForegroundColor Yellow
    Write-Host "  the download or copy may stall. Consider disabling sleep manually for now." -ForegroundColor Yellow
    Write-Host ""
}

# Wraps the whole build below in one try/catch so ANY failure (corrupted
# download, wrong disk picked, USB too small, aborted by user, etc.) shows a
# clean "  <message>" line instead of PowerShell's raw, technical exception
# dump ("At ... char:9", "CategoryInfo", "FullyQualifiedErrorId", the message
# printed twice) that a public, non-technical user shouldn't have to read.
# Confirmed 2026-07-17: a checksum-mismatch throw was surfacing that raw dump.
# Inner code below is intentionally NOT re-indented for this wrap -- PowerShell
# doesn't care, and re-indenting 400+ lines by hand risked introducing a typo
# for a purely cosmetic change.
try {

# ─────────────────────────────────────────────────────────────────────────────
# 1. Validate prerequisites
# ─────────────────────────────────────────────────────────────────────────────
Clear-Host
Write-Host ""
Write-Host "  ===================================================================================================" -ForegroundColor Cyan
Write-Host "                               On2it WinFixIT - Build Your Own USB" -ForegroundColor Yellow
Write-Host "  ===================================================================================================" -ForegroundColor Cyan
Write-Host ""

if ($PostInstallZipUrl -like '*REPLACE-ME*' -or $ScriptsZipUrl -like '*REPLACE-ME*') {
    throw "This script has not been configured yet. Edit Build-Your-USB.ps1 and set PostInstallZipUrl / ScriptsZipUrl to your Cloudflare R2 download links."
}
if (-not (Test-Path $SRC_INSTALL)) {
    throw "USB-INSTALL folder not found next to this script (expected: $SRC_INSTALL)."
}
function Test-DownloadHash {
    param(
        [string]$Path,
        [string]$ExpectedHash,
        [string]$Label
    )
    Write-Host "  Verifying Hash Total for $Label to ensure it was downloaded correctly..." -ForegroundColor Gray
    $actualHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($actualHash -ne $ExpectedHash) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        throw "$Label failed its integrity check (checksum mismatch) -- the download is likely corrupted or incomplete. The bad file has been deleted; just re-run this script to try again."
    }
    # Previously silent on success, so a passing check gave no visible sign
    # before the next (unrelated) file's prompt appeared - looked like the
    # run had skipped or jumped ahead. Brian, 2026-08-13.
    Write-Host "  Hash verified OK." -ForegroundColor Green
    # Returned so Expand-VerifiedArchive can tag its extraction cache with this
    # exact hash, instead of hashing the same multi-GB file a second time.
    return $actualHash
}

# Shows GB for anything gigabyte-sized, MB otherwise -- "0.0 GB" for the tiny
# Scripts bundle would look broken rather than informative.
function Format-SizeMB {
    param([double]$MB)
    if ($MB -ge 1024) { return "$([math]::Round($MB / 1024, 1)) GB" }
    else { return "$([math]::Round($MB, 0)) MB" }
}

# Runs the download in a background job so the main thread is free to print a dot
# every second -- Invoke-WebRequest itself blocks with no way to report progress
# mid-call. Every ~60s also prints MB downloaded and a rough ETA (based on the
# caller's approximate expected size), by polling the partial file's size on disk.
#
# The dots line and the status line each stay pinned to their own console row,
# redrawn in place, rather than scrolling a new pair of lines every 60s for a
# 20-30 minute download. Falls back to plain scrolling dots if cursor
# positioning isn't available (e.g. output redirected to a file/log).
function Invoke-DownloadWithDots {
    param(
        [string]$Uri,
        [string]$OutFile,
        [double]$ExpectedTotalMB = 0
    )
    $job = Start-Job -ScriptBlock {
        param($Uri, $OutFile)
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile
    } -ArgumentList $Uri, $OutFile

    $canRedraw = $false
    try {
        $null = [Console]::WindowWidth   # just probing that cursor/console control works at all
        $canRedraw = $true
    } catch { }

    $startTime      = Get-Date
    $lastStatusTime = $startTime
    $lastProgressMB = 0
    $stalledChecks  = 0
    $MAX_STALLED_CHECKS = 5   # ~5 minutes of zero progress (checked once per 60s status tick)

    while ($job.State -eq 'Running') {
        Write-Host -NoNewline '.'
        Start-Sleep -Seconds 1

        if (((Get-Date) - $lastStatusTime).TotalSeconds -ge 60) {
            $lastStatusTime = Get-Date
            $downloadedMB = if (Test-Path $OutFile) { [math]::Round((Get-Item $OutFile).Length / 1MB, 0) } else { 0 }

            # Confirmed 2026-07-17: Invoke-WebRequest has no timeout, so if the
            # connection silently dies (e.g. the PC went to sleep mid-download),
            # the job just hangs forever with nothing to notice or report it - and
            # the ETA math below actually makes the displayed time climb instead
            # of counting down, since a shrinking rate against a fixed remaining
            # size grows without bound. Bail out explicitly instead.
            if ($downloadedMB -le $lastProgressMB) {
                $stalledChecks++
                if ($stalledChecks -ge $MAX_STALLED_CHECKS) {
                    Stop-Job $job -ErrorAction SilentlyContinue
                    Remove-Job $job -Force -ErrorAction SilentlyContinue
                    Write-Host ""
                    throw "Download stalled -- no progress for $MAX_STALLED_CHECKS minutes. Check your internet connection (or that the PC didn't go to sleep) and re-run this script."
                }
            } else {
                $stalledChecks = 0
            }
            $lastProgressMB = $downloadedMB

            $elapsedMin   = ((Get-Date) - $startTime).TotalMinutes
            $rateMBmin    = if ($elapsedMin -gt 0) { $downloadedMB / $elapsedMin } else { 0 }
            # ExpectedTotalMB is a rough hand-set estimate, not the real
            # Content-Length -- if the actual file is a bit bigger, show
            # "almost done" rather than silently dropping the ETA text.
            $etaText = if ($downloadedMB -ge $ExpectedTotalMB) {
                " (almost done)"
            } elseif ($rateMBmin -gt 0) {
                " (about $([math]::Ceiling(($ExpectedTotalMB - $downloadedMB) / $rateMBmin)) min remaining)"
            } else { "" }
            $statusLine = "  {0:N0} MB downloaded so far{1}" -f $downloadedMB, $etaText

            if ($canRedraw) {
                try {
                    # Compute rows AND window width fresh, right now, relative to
                    # wherever the cursor/console actually is -- not from values
                    # stored back when the loop started. That way this self-corrects
                    # instead of drifting if the console was resized or scrolled in
                    # the meantime (confirmed 2026-07-17: a stale width captured once
                    # up front caused corruption after the window was resized while
                    # the download ran in the background).
                    $windowWidth = [Console]::WindowWidth
                    Write-Host ""
                    $statusRow = [Console]::CursorTop
                    $dotsRow   = $statusRow - 1

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

    # Land the cursor on a genuinely fresh row before returning, so whatever the
    # caller prints next (e.g. "Download complete.") doesn't land on top of the
    # leftover status/dots text instead of below it.
    if ($canRedraw) {
        # TWO plain, RELATIVE newlines - not absolute SetCursorPosition
        # arithmetic. Found for real 2026-08-24 (Brian, live test): the
        # previous "jump to $lastStatusRow + 1" approach glued the caller's
        # next line straight onto the end of the still-visible status line
        # with no break at all - the exact same one-row-short landing the
        # 2026-07-17 fix below was meant to prevent, just resurfacing a
        # different way (almost certainly SetCursorPosition behaving
        # inconsistently under some terminal hosts - see
        # project_conpty_scroll_bug). The loop always leaves the cursor on
        # the dots row (one row above the status row) when it exits, so two
        # relative newlines reliably clear both rows regardless of what the
        # terminal host's own absolute row numbering was actually doing.
        Write-Host ""
        Write-Host ""
    } else {
        # Confirmed 2026-07-17: landing here after plain-scrolling (no
        # redraw) dots needs just the one newline to reach a fresh line.
        Write-Host ""
    }

    Receive-Job $job -ErrorAction Stop | Out-Null
    Remove-Job $job -Force
}

# If a previously downloaded file exists (e.g. left over from an abandoned run),
# ask whether to reuse it or start fresh, rather than either silently trusting
# it or silently redownloading a possibly-fine multi-GB file. A completion-flag
# file (written only once Test-DownloadHash has actually confirmed the file is
# good) lets this tell the user whether the leftover file is known-good or
# might be a partial/corrupted remnant, so "if in doubt, re-download" can be
# the sensible default without being the only option.
function Confirm-ExistingDownload {
    param(
        [string]$Path,
        [string]$Label
    )
    if (-not (Test-Path $Path)) { return }

    # Path shown explicitly - Brian, 2026-08-13: "I thought I had deleted
    # them" - without the path, there's no way to know WHERE to go delete a
    # leftover file from (it's $env:SystemDrive\On2it-WinFixIT-USB-Build,
    # not Downloads or anywhere else a person might expect).
    #
    # Wording/colours/response letters reworked 2026-08-24 (Brian, live
    # test): R now means Re-use (not Re-download as before - the letters
    # were swapped, not just relabelled), D means Download again. Blank
    # Enter still falls through to the same safe default as before (get a
    # fresh copy), since "" doesn't match '^[Rr]'.
    $flagPath = "$Path.complete"
    Write-Host "  Found a previous version at:" -ForegroundColor White
    if (Test-Path $flagPath) {
        $completedAt = Get-Content -LiteralPath $flagPath -Raw -ErrorAction SilentlyContinue
        Write-Host "    $Path, dated $completedAt" -ForegroundColor White
    } else {
        Write-Host "    $Path (incomplete - may not have finished downloading)" -ForegroundColor White
    }
    Write-Host "  Would you like to Re-use it or Download again? (R/D): " -NoNewline -ForegroundColor Yellow
    $answer = Read-Host
    if ($answer -notmatch '^[Rr]') {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $flagPath -Force -ErrorAction SilentlyContinue
    }
}

function Set-DownloadCompleteFlag {
    param([string]$Path)
    Get-Date -Format 'yyyy-MM-dd HH:mm:ss' | Set-Content -LiteralPath "$Path.complete"
}

# Extracts a zip, but first checks a completion-flag file inside the destination
# folder to detect a partial extraction left over from an aborted run (window
# closed mid-extraction, PC crashed, etc.) -- Test-Path on the folder alone
# can't tell "fully extracted" apart from "half extracted", which would
# otherwise silently skip re-extracting and build a USB with incomplete
# content, no error at all. Re-extracting is cheap (unlike re-downloading), so
# this just fixes it automatically rather than asking.
#
# The flag file's content is the SOURCE ZIP's own hash, not just a timestamp -
# found for real 2026-08-24 (Brian, live test): $tempRoot deliberately persists
# across separate runs (so an interrupted download/extraction can resume), but
# that also means an EARLIER test's smaller/older zip could already sit
# extracted here with its own "done" flag already in place. A fresh, larger
# zip downloaded and hash-verified in THIS run then got silently skipped -
# "12 GB needed" was measuring that stale leftover content, not the zip that
# had actually just been verified. Tying the flag to the zip's hash means any
# change to what was actually downloaded correctly invalidates the cache.
function Expand-VerifiedArchive {
    param(
        [string]$ZipPath,
        [string]$ZipHash,
        [string]$DestPath,
        [string]$Label
    )
    $flagPath   = Join-Path $DestPath '_extraction_complete.txt'
    $cachedHash = if (Test-Path $flagPath) { (Get-Content -LiteralPath $flagPath -Raw -ErrorAction SilentlyContinue).Trim() } else { $null }

    if ((Test-Path $DestPath) -and $cachedHash -ne $ZipHash) {
        Remove-Item -LiteralPath $DestPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path $DestPath)) {
        Write-Host "  Extracting $Label..." -ForegroundColor Gray
        try {
            Expand-Archive -Path $ZipPath -DestinationPath $DestPath -Force
            Set-Content -LiteralPath $flagPath -Value $ZipHash -NoNewline
        } catch {
            if (Test-Path $DestPath) { Remove-Item $DestPath -Recurse -Force }
            throw
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. Download On2it-WinFixIT content and Scripts bundle
# ─────────────────────────────────────────────────────────────────────────────
$tempRoot       = Join-Path $env:SystemDrive 'On2it-WinFixIT-USB-Build'
$postZip        = Join-Path $tempRoot 'On2it-WinFixIT.zip'
$postExtract    = Join-Path $tempRoot 'On2it-WinFixIT'
$scriptsZip     = Join-Path $tempRoot 'USB-INSTALL-Scripts.zip'
$scriptsExtract = Join-Path $tempRoot 'Scripts'
$bootZip        = Join-Path $tempRoot 'USB-INSTALL-Boot.zip'
$bootExtract    = Join-Path $tempRoot 'Boot-Files'

New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

# Brian, 2026-08-13, after watching a real run: "I didn't appreciate it was
# downloading two [really three] separate ZIP files. We need to make that
# more obvious somehow." Without this, the run jumps straight from one
# file's completed download into a completely different file's "Found a
# previously downloaded..." prompt, with nothing signalling that's a new,
# separate item rather than a repeat of the same one.
Write-Host ""
Write-Host "  First we need to download:" -ForegroundColor White
Write-Host "     - On2it-WinFixIT.zip," -ForegroundColor White
Write-Host "     - USB-INSTALL-Scripts.zip," -ForegroundColor White
Write-Host "     - USB-INSTALL-Boot.zip." -ForegroundColor White

Write-Host ""
$postExpectedMB = 20024
Write-Host "  Downloading On2it-WinFixIT.zip ($(Format-SizeMB $postExpectedMB), this will take a while)..." -ForegroundColor Cyan
Confirm-ExistingDownload -Path $postZip -Label 'On2it-WinFixIT.zip'
if (-not (Test-Path $postZip)) {
    # Content list grows with the zip - below 12 GB it's still just ISOs + the
    # menu system, but past that point Applications/AI Tools/Documentation have
    # been added, so the short description would undersell what's actually there.
    if ($postExpectedMB -lt 12288) {
        Write-Host "  On2it-WinFixIT Partition - $(Format-SizeMB $postExpectedMB) contains:" -ForegroundColor DarkGray
        Write-Host "     TWO Windows ISOs" -ForegroundColor DarkGray
        Write-Host "     + Our LIBRARY Menu files" -ForegroundColor DarkGray
    } else {
        Write-Host "  On2it-WinFixIT Partition - $(Format-SizeMB $postExpectedMB) contains: "  -ForegroundColor DarkGray
        Write-Host "     TWO Windows ISOs, "  -ForegroundColor DarkGray
        Write-Host "     Multiple Application & Utility Apps, "  -ForegroundColor DarkGray
        Write-Host "     AI Tools, "  -ForegroundColor DarkGray
        Write-Host "     Documentation & Reference Library + "  -ForegroundColor DarkGray
        Write-Host "     + Our LIBRARY Menu files" -ForegroundColor DarkGray
    }
    Write-Host "  Feel free to leave it running in the background.  An estimated time remaining will appear shortly." -ForegroundColor DarkGray
    Invoke-DownloadWithDots -Uri $PostInstallZipUrl -OutFile $postZip -ExpectedTotalMB $postExpectedMB
    Write-Host "  Download complete." -ForegroundColor Gray
    Write-Host ""
}
$postZipHash = Test-DownloadHash -Path $postZip -ExpectedHash $PostInstallZipHash -Label 'On2it-WinFixIT.zip'
Set-DownloadCompleteFlag -Path $postZip
Expand-VerifiedArchive -ZipPath $postZip -ZipHash $postZipHash -DestPath $postExtract -Label 'On2it-WinFixIT content'

Write-Host ""
$scriptsExpectedMB = 1
Write-Host "  Downloading USB-INSTALL-Scripts.zip ($(Format-SizeMB $scriptsExpectedMB))..." -ForegroundColor Cyan
Confirm-ExistingDownload -Path $scriptsZip -Label 'USB-INSTALL-Scripts.zip'
if (-not (Test-Path $scriptsZip)) {
    Write-Host "  (This is the logic that drives the system.)" -ForegroundColor DarkGray
    Invoke-DownloadWithDots -Uri $ScriptsZipUrl -OutFile $scriptsZip -ExpectedTotalMB $scriptsExpectedMB
    Write-Host "  Download complete." -ForegroundColor Gray
    Write-Host ""
}
$scriptsZipHash = Test-DownloadHash -Path $scriptsZip -ExpectedHash $ScriptsZipHash -Label 'USB-INSTALL-Scripts.zip'
Set-DownloadCompleteFlag -Path $scriptsZip
Expand-VerifiedArchive -ZipPath $scriptsZip -ZipHash $scriptsZipHash -DestPath $scriptsExtract -Label 'files from USB-INSTALL-Scripts.zip'

Write-Host ""
$bootExpectedMB = 499
Write-Host "  Downloading USB-INSTALL-Boot.zip ($(Format-SizeMB $bootExpectedMB))..." -ForegroundColor Cyan
Confirm-ExistingDownload -Path $bootZip -Label 'USB-INSTALL-Boot.zip'
if (-not (Test-Path $bootZip)) {
    Write-Host "  (Microsoft WinPE, which enables WinFixIT to run without a full OS.)" -ForegroundColor DarkGray
    Invoke-DownloadWithDots -Uri $BootZipUrl -OutFile $bootZip -ExpectedTotalMB $bootExpectedMB
    Write-Host "  Download complete." -ForegroundColor Gray
    Write-Host ""
}
$bootZipHash = Test-DownloadHash -Path $bootZip -ExpectedHash $BootZipHash -Label 'USB-INSTALL-Boot.zip'
Set-DownloadCompleteFlag -Path $bootZip
Expand-VerifiedArchive -ZipPath $bootZip -ZipHash $bootZipHash -DestPath $bootExtract -Label 'files from USB-INSTALL-Boot.zip'

$SRC_POST = $postExtract

Write-Host ""

# ─────────────────────────────────────────────────────────────────────────────
# 3. Check downloaded content sizes, then list and select a USB disk with
#    enough capacity
# ─────────────────────────────────────────────────────────────────────────────
function Get-FolderSizeMB {
    param([string]$Path)
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    if (-not $sum) { $sum = 0 }
    return [math]::Ceiling($sum / 1MB)
}

Write-Host "  Checking downloaded content sizes..." -ForegroundColor Cyan
$srcInstallMB = (Get-FolderSizeMB $SRC_INSTALL) + (Get-FolderSizeMB $scriptsExtract) + (Get-FolderSizeMB $bootExtract)
$srcPostMB    = Get-FolderSizeMB $SRC_POST

if ($srcInstallMB -gt $P1_SIZE_MB) {
    # P1 is a fixed size regardless of which USB is chosen - a bigger USB
    # can't fix this, so it's not part of the capacity wait-loop below.
    throw "USB-INSTALL content (+ Scripts + Boot files) is $srcInstallMB MB, which no longer fits the fixed $P1_SIZE_MB MB USB-INSTALL partition. This is a build configuration problem, not something a bigger USB fixes - please contact On2it Software Support."
}

Write-Host ""

# Now that the actual downloaded content size is known, the exact USB capacity
# needed can be stated up front - Brian, 2026-08-24: "if the User had not
# plugged in a USB, it needs to ask for one of the right capacity" - rather
# than the old behaviour of throwing immediately ("No USB disks found... re-
# run") and forcing the whole script to be started over just because nothing
# was plugged in yet, or because what was plugged in was too small. This
# loops instead, telling the user exactly what to insert and re-scanning once
# they've done it - the already-downloaded/verified zips are untouched either
# way, so nothing is lost by waiting here.
$minDiskMB = $P1_SIZE_MB + $srcPostMB + $GPT_OVERHEAD_MB
$minDiskGB = [math]::Round($minDiskMB / 1024, 1)

$tgtDisk = $null
while (-not $tgtDisk) {
    $usbDisks  = @(Get-Disk | Where-Object BusType -eq 'USB')
    $bigEnough = @($usbDisks | Where-Object { ($_.Size / 1MB) -ge $minDiskMB })

    if ($bigEnough.Count -eq 0) {
        if ($usbDisks.Count -eq 0) {
            Write-Host "  No USB drive detected." -ForegroundColor Yellow
        } else {
            Write-Host "  Found $($usbDisks.Count) USB drive(s) plugged in, but none big enough:" -ForegroundColor Yellow
            $usbDisks | ForEach-Object {
                Write-Host "    Disk $($_.Number)  $($_.FriendlyName)  ($([math]::Round($_.Size/1GB,1)) GB)" -ForegroundColor Yellow
            }
        }
        Write-Host "  Please plug in a USB drive of at least $minDiskGB GB (32GB+ recommended)." -ForegroundColor White
        Write-Host "  Press Enter once it's ready: " -NoNewline -ForegroundColor Yellow
        Read-Host
        continue
    }

    if ($bigEnough.Count -eq 1) {
        $tgtDisk = $bigEnough[0]
        Write-Host "  Only one suitable USB disk found: Disk $($tgtDisk.Number)  $($tgtDisk.FriendlyName)  ($([math]::Round($tgtDisk.Size/1GB,1)) GB) - using it." -ForegroundColor White
        break
    }

    Write-Host "  Available USB disks (at least $minDiskGB GB needed):" -ForegroundColor Cyan
    $bigEnough | Select-Object `
        @{N='Drive'; E={
            $letters = Get-Partition -DiskNumber $_.Number -ErrorAction SilentlyContinue |
                Get-Volume -ErrorAction SilentlyContinue |
                Where-Object { $_.DriveLetter } |
                Select-Object -ExpandProperty DriveLetter |
                Sort-Object
            if ($letters) { ($letters | ForEach-Object { "$_`:" }) -join ', ' } else { '(none)' }
        }},
        @{N='No'; E={$_.Number}},
        @{N='Name'; E={$_.FriendlyName}},
        @{N='Size'; E={"$([math]::Round($_.Size / 1GB, 1)) GB"}} |
        Format-Table -AutoSize

    Write-Host "  Enter disk NUMBER of the target USB drive: " -NoNewline -ForegroundColor Yellow
    $enteredNum = 0
    if (-not [int]::TryParse((Read-Host), [ref]$enteredNum)) {
        Write-Host "  Not a valid disk number - try again." -ForegroundColor Red
        continue
    }
    $selected = $bigEnough | Where-Object Number -eq $enteredNum
    if (-not $selected) {
        Write-Host "  '$enteredNum' is not one of the disk numbers listed above - try again." -ForegroundColor Red
        continue
    }
    $tgtDisk = $selected
}
$tgtDiskNum = $tgtDisk.Number

# Regardless of how many USB drives are attached, if the selected drive already
# has partitions on it, show what's there as a last check before it gets
# destroyed. Gated on $tgtDisk.NumberOfPartitions (straight from Get-Disk, not a
# fragile Get-Partition|Get-Volume|Where-DriveLetter pipeline) - a real incident
# (2026-07-17) showed that pipeline can silently return nothing (no drive letter
# yet assigned, disk offline, etc.) even when the disk genuinely has data on it,
# which skipped this whole warning without a trace. NumberOfPartitions can't be
# silently swallowed the same way, so it's now what actually gates the warning;
# the file listing below is only a best-effort bonus on top of it.
if ($tgtDisk.NumberOfPartitions -gt 0) {
    Write-Host ""
    Write-Host "  Disk $tgtDiskNum already has $($tgtDisk.NumberOfPartitions) partition(s) on it." -ForegroundColor White

    $existingVolumes = Get-Partition -DiskNumber $tgtDiskNum -ErrorAction SilentlyContinue |
        Get-Volume -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveLetter }

    $allItems = @()
    foreach ($vol in $existingVolumes) {
        $allItems += Get-ChildItem -LiteralPath "$($vol.DriveLetter):\" -Force -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty Name
    }

    if ($allItems.Count -gt 0) {
        $truncated    = $allItems.Count -gt 5
        $foundContent = $allItems | Select-Object -First 5

        Write-Host "  It contains:" -ForegroundColor White
        for ($i = 0; $i -lt $foundContent.Count; $i++) {
            $isLast = $i -eq ($foundContent.Count - 1)
            $suffix = if ($isLast) { if ($truncated) { ', ...' } else { '' } } else { ',' }
            Write-Host "          $($foundContent[$i])$suffix" -ForegroundColor White
        }
    } else {
        Write-Host "  Its contents could not be previewed (no drive letter is currently assigned to check)." -ForegroundColor White
    }

    Write-Host ""
    Write-Host "  Are you sure this is the right drive? (Y/N): " -NoNewline -ForegroundColor Yellow
    $doubleCheck = Read-Host
    if ($doubleCheck -notmatch '^[Yy]') { throw "Aborted by user." }
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. Calculate partition sizes and confirm
# ─────────────────────────────────────────────────────────────────────────────
# The Reserved (Courses) partition is never populated in a public build -- Courses
# is a separate, non-public product (see project_on2it_software_courses memory) --
# so unlike the in-house Clone-WinFixIT-USB.ps1 build, this is never dynamically
# true here. Kept as a named flag (rather than just deleting the P3 code) so the
# same "give the space to P2 instead" logic below stays in one place if that ever
# changes.
$coursesHasContent = $false

$diskSizeMB   = [math]::Floor($tgtDisk.Size / 1MB)
$p3ReservedMB = if ($coursesHasContent) { $P3_SIZE_MB } else { 0 }
$P2_SIZE_MB   = $diskSizeMB - $P1_SIZE_MB - $p3ReservedMB - $GPT_OVERHEAD_MB

if ($P2_SIZE_MB -le 0) {
    throw "Disk is too small for the requested partition layout ($diskSizeMB MB available)."
}

Write-Host ""
Write-Host "  Target  : Disk $tgtDiskNum  $($tgtDisk.FriendlyName)  ($([math]::Round($tgtDisk.Size/1GB,1)) GB)" -ForegroundColor White
Write-Host "  Layout  :"
Write-Host ("    {0,-28}{1,6} MB   {2,-6}{3}" -f 'P1  USB-INSTALL', $P1_SIZE_MB, 'FAT32', '(read-only after copy)')
Write-Host ("    {0,-28}{1,6} MB   {2,-6}{3}" -f 'P2  On2it-WinFixIT', $P2_SIZE_MB, 'NTFS', '')
if ($coursesHasContent) {
    Write-Host ("    {0,-28}{1,6} MB   {2,-6}{3}" -f 'P3  Reserved', $P3_SIZE_MB, 'NTFS', '(structure only, not distributed publicly)')
}
Write-Host ""
Write-Host "  Scripts folder will be HIDDEN on this USB (same as the in-house build)." -ForegroundColor Gray
Write-Host ""

# ─────────────────────────────────────────────────────────────────────────────
# 4b. Final fit safety check
# ─────────────────────────────────────────────────────────────────────────────
# Should never actually trigger now - the USB wait-loop in step 3 already only
# offers disks big enough for $srcPostMB in the first place. Kept as a cheap
# defence-in-depth check rather than trusting that filter alone, e.g. if a
# disk reports slightly less usable space once actually partitioned than
# Get-Disk's raw .Size suggested.
if ($srcPostMB -gt $P2_SIZE_MB) {
    throw "Downloaded content does not fit on this USB after all: On2it-WinFixIT needs $srcPostMB MB, only $P2_SIZE_MB MB available. Please re-run with a larger USB (32GB+ recommended)."
}

# ANSI bold ($([char]27)[1m ... [0m) -- Write-Host has no native bold switch.
# Assumes a VT100-capable console, which Windows 10/11's default conhost and
# Windows Terminal both are; worst case on an unusual host this just shows as
# plain (non-bold) red-on-white rather than breaking anything.
Write-Host "$([char]27)[1m  WARNING: ALL DATA ON DISK $tgtDiskNum WILL BE PERMANENTLY DESTROYED.  $([char]27)[0m" -ForegroundColor Red -BackgroundColor White
Write-Host ""
Write-Host "  Type YES to continue: " -NoNewline -ForegroundColor Yellow
$confirm = Read-Host
if ($confirm -ne 'YES') { throw "Aborted by user." }

# ─────────────────────────────────────────────────────────────────────────────
# 5. Find free drive letters
# ─────────────────────────────────────────────────────────────────────────────
$numPartitions = if ($coursesHasContent) { 3 } else { 2 }
$usedLetters = (Get-PSDrive -PSProvider FileSystem).Name
$freeLetters = [char[]](90..65) |
    ForEach-Object { [string]$_ } |
    Where-Object   { $_ -notin $usedLetters } |
    Select-Object  -First $numPartitions

if ($freeLetters.Count -lt $numPartitions) { throw "Not enough free drive letters available." }

$tgtL1 = $freeLetters[0]   # P1 - USB-INSTALL
$tgtL2 = $freeLetters[1]   # P2 - On2it-WinFixIT
$tgtL3 = if ($coursesHasContent) { $freeLetters[2] } else { $null }   # P3 - Reserved (if present)

# ─────────────────────────────────────────────────────────────────────────────
# 6. Partition the target USB
# ─────────────────────────────────────────────────────────────────────────────
# Shared with the in-house Clone-WinFixIT-USB.ps1 build -- see the header comment
# in Partition-USB-Common.ps1 for how the two copies are kept in sync.
. (Join-Path $ScriptRoot 'Tools\Partition-USB-Common.ps1')

Invoke-USBPartitioning -DiskNum $tgtDiskNum -CoursesHasContent $coursesHasContent `
    -L1 $tgtL1 -L2 $tgtL2 -L3 $tgtL3 `
    -P1SizeMB $P1_SIZE_MB -P2SizeMB $P2_SIZE_MB -P3SizeMB $p3ReservedMB `
    -L2Label 'On2it-WinFixIT' -L3Label 'Reserved'

# Explains what's actually in each partition, right after the sizes are shown -
# Brian, 2026-08-16: "build anticipation of the systems capabilities" for a
# public builder who doesn't already know what WinFixIT does.
# $BulletChar built from its codepoint rather than typed as a literal character -
# keeps this file's saved encoding irrelevant to whether the bullet renders right.
$BulletChar = [char]0x2022
Write-Host ""
Write-Host "  USB-INSTALL will contain:" -ForegroundColor White
Write-Host "      WinPE boot files that enable a machine to be booted without" -ForegroundColor White
Write-Host "         an existing OS, if necessary." -ForegroundColor White
Write-Host "      Scripts that:" -ForegroundColor White
Write-Host "         $BulletChar Check Compatibility of any PC to run Windows 11," -ForegroundColor Gray
Write-Host "         $BulletChar Debloat Windows 11 of unwanted Apps and Settings, either:" -ForegroundColor Gray
Write-Host "              - Accepting our default Options, or" -ForegroundColor Gray
Write-Host "              - Allowing you to choose your own - with FULL advice" -ForegroundColor Gray
Write-Host "                on EVERY Option." -ForegroundColor Gray
Write-Host ""
Write-Host "  On2it-WinFixIT contains all the files for installing:" -ForegroundColor White
Write-Host "      Windows 11:" -ForegroundColor White
Write-Host "          $BulletChar BYPASS Install.iso - installs Windows 11, bypassing its" -ForegroundColor Gray
Write-Host "            usual insistence on TPM, Secure Boot, and a UEFI BIOS." -ForegroundColor Gray
Write-Host "          $BulletChar FULL Install.iso - installs Windows with FULL enhanced" -ForegroundColor Gray
Write-Host "            security features." -ForegroundColor Gray
Write-Host "      Applications like:" -ForegroundColor White
Write-Host "          $BulletChar Office, Project, Visio - or anything else YOU add to" -ForegroundColor Gray
Write-Host "            YOUR USB." -ForegroundColor Gray
Write-Host "      Plus an Extensible Library of:" -ForegroundColor White
Write-Host "          $BulletChar Curated off-line and on-line reference material," -ForegroundColor Gray
Write-Host "            Utilities and Software Tools." -ForegroundColor Gray
Write-Host "          $BulletChar Add your own Apps, Menu and Options, simply by adding" -ForegroundColor Gray
Write-Host "            files and folders to the USB." -ForegroundColor Gray
Write-Host ""

# ─────────────────────────────────────────────────────────────────────────────
# 7. Copy content
# ─────────────────────────────────────────────────────────────────────────────
# Shared with the in-house Clone-WinFixIT-USB.ps1 build -- see the header comment
# in Robocopy-Common.ps1 for how the two copies are kept in sync.
. (Join-Path $ScriptRoot 'Tools\Robocopy-Common.ps1')

Write-Host ""
Write-Host "  Copying USB-INSTALL..." -ForegroundColor Cyan
$exitCode = Invoke-RobocopyDotsOnly -RobocopyArgs @(
    "$SRC_INSTALL\\", "$tgtL1`:\\", '/E', '/COPY:DAT', '/DCOPY:DAT', '/NFL', '/NDL', '/NJH', '/NJS', '/R:2', '/W:5',
    '/XD', 'System Volume Information'
)
if ($exitCode -ge 8) { throw "Robocopy failed on USB-INSTALL (exit $exitCode)." }

Write-Host "  Copying WinPE boot files..." -ForegroundColor Cyan
$exitCode = Invoke-RobocopyDotsOnly -RobocopyArgs @(
    "$bootExtract\\", "$tgtL1`:\\", '/E', '/COPY:DAT', '/DCOPY:DAT', '/NFL', '/NDL', '/NJH', '/NJS', '/R:2', '/W:5',
    '/XD', 'System Volume Information'
)
if ($exitCode -ge 8) { throw "Robocopy failed on WinPE boot files (exit $exitCode)." }

Write-Host "  Copying Scripts (will be hidden)..." -ForegroundColor Cyan
$exitCode = Invoke-RobocopyDotsOnly -RobocopyArgs @(
    "$scriptsExtract\\", "$tgtL1`:\Scripts\\", '/E', '/COPY:DAT', '/DCOPY:DAT', '/NFL', '/NDL', '/NJH', '/NJS', '/R:2', '/W:5',
    '/XD', 'System Volume Information'
)
if ($exitCode -ge 8) { throw "Robocopy failed on Scripts (exit $exitCode)." }

Write-Host "  Copying On2it-WinFixIT... ($(Format-SizeMB $srcPostMB))" -ForegroundColor Cyan
$postSplit = Get-LargeFileSplit -SourceRoot $SRC_POST
$exitCode = Invoke-RobocopyLargeThenSmall -SourceRoot $SRC_POST -DestDriveLetter $tgtL2 `
    -LargeFiles $postSplit.LargeFiles -SmallMB $postSplit.SmallMB `
    -SmallPassArgs @(
        "$SRC_POST\\", "$tgtL2`:\\", '/E', '/COPY:DAT', '/DCOPY:DAT', '/NFL', '/NDL', '/NJH', '/NJS', '/R:2', '/W:5',
        '/XD', 'System Volume Information'
    )
if ($exitCode -ge 8) { throw "Robocopy failed on On2it-WinFixIT (exit $exitCode)." }

# ─────────────────────────────────────────────────────────────────────────────
# 8. Hide Scripts folder on USB-INSTALL
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  Hiding Scripts and system files on USB-INSTALL..." -ForegroundColor Cyan

Get-ChildItem -LiteralPath "$tgtL1`:\" -Force | ForEach-Object {
    if ($SAFE_LIST -notcontains $_.Name) {
        cmd /c attrib +h +s "$($_.FullName)" 2>$null
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# 9. Set USB-INSTALL partition read-only
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "  Setting USB-INSTALL partition read-only..." -ForegroundColor Cyan
$readOnlyOK = Set-PartitionReadOnlySafe -DiskNum $tgtDiskNum -DriveLetter $tgtL1
if (-not $readOnlyOK) {
    Write-Host "  WARNING: This USB's controller does not support read-only" -ForegroundColor Yellow
    Write-Host "  partitions -- USB-INSTALL was copied successfully but is NOT" -ForegroundColor Yellow
    Write-Host "  write-protected. Everything else completed normally." -ForegroundColor Yellow
}

# ─────────────────────────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  ================================================================" -ForegroundColor Green
Write-Host "    Your On2it WinFixIT USB is ready!" -ForegroundColor Green
Write-Host "  ================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Drive letters assigned:" -ForegroundColor Gray
Write-Host "    $tgtL1`:  USB-INSTALL                  (FAT32$(if ($readOnlyOK) { ', read-only' } else { ', NOT write-protected' }))" -ForegroundColor White
Write-Host "    $tgtL2`:  On2it-WinFixIT               (NTFS)" -ForegroundColor White
Write-Host ""
Write-Host "  ==================================================================" -ForegroundColor Cyan
Write-Host "    Starting WinFixIT:" -ForegroundColor White
Write-Host "  ==================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  On a PC with ANY version of Windows:" -ForegroundColor White
Write-Host "        1. Open File Explorer " -ForegroundColor Gray
Write-Host "           (press the Windows key + E, or click the folder icon on your taskbar)."  -ForegroundColor Gray
Write-Host "        2. In the left-hand panel (under 'This PC'), look for drive" -ForegroundColor Gray
Write-Host "               USB-INSTALL ($tgtL1`:) or" -ForegroundColor Gray
Write-Host "               On2it-WinFixIT ($tgtL2`:)." -ForegroundColor Gray
Write-Host "        3. Double-click either one to open it, then double-click" -ForegroundColor Gray
Write-Host "               RUN - On2it-WinFixIT.bat " -ForegroundColor Gray
Write-Host "           inside it to start." -ForegroundColor Gray
Write-Host ""
Write-Host "  On a PC with NO OS installed:" -ForegroundColor White
Write-Host "        Set your BIOS to boot from your USB and follow your nose." -ForegroundColor Gray
Write-Host "        For FULL details see the User Manual." -ForegroundColor Gray
Write-Host ""
Write-Host "  A full user manual is included in the USB-INSTALL partition as 'WinFixIT - User Manual.pdf'." -ForegroundColor Gray
Write-Host "  Hopefully you won't need it, as we've designed WinFixIT to explain itself as you go along, "  -ForegroundColor Gray
Write-Host "  but it's there if you do." -ForegroundColor Gray
Write-Host ""
Write-Host "  Press Enter to close: " -NoNewline -ForegroundColor Yellow
Read-Host
exit
} catch {
    Write-Host ""
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Press Enter to close: " -NoNewline -ForegroundColor Yellow
    Read-Host
    exit
} finally {
    if ($sleepPreventionActive) {
        [Win32SleepPrevention.Kernel32]::SetThreadExecutionState($ES_CONTINUOUS) | Out-Null
    }
}
