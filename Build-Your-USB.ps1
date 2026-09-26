<# Build-Your-USB.ps1
   ==================
       Purpose: Public build script. Downloads the large On2it-WinFixIT content,
                the WinPE boot files, and the (private, unlisted) Scripts bundle
                from Cloudflare R2, optionally builds the two Windows
                installation ISOs fresh from Microsoft's own servers (the user
                is asked - Compatibility Checker, DeBloater and the Library
                all work without them), then partitions a USB drive and
                copies USB-INSTALL (bundled in this repo) + the
                downloaded/built content onto it.

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

                Source (optional - built locally from Microsoft, or user-supplied;
                        see Tools\Build-WindowsISOs.ps1):
                    FULL Install.iso               → P2\Install\Windows (untouched
                                                        official Microsoft ISO)
                    BYPASS Install.iso             → P2\Install\Windows (same ISO,
                                                        TPM/Secure Boot/CPU check removed)
                    Neither ISO is downloaded from Cloudflare or shipped in this
                    repo — Microsoft doesn't permit redistributing Windows install
                    media, so this build gets its own copy straight from Microsoft
                    every time instead, if the user wants Windows install media at
                    all. See project_github_vs_inhouse_iso_policy memory for why
                    this differs from the in-house build.

   Designed by: Brian McGuigan
            of: On2it Software Ltd
       Code by: Claude
       Version: 8 (Windows install media is now a real up-front choice, not
                something every build does regardless - Brian, 2026-09-25:
                Compatibility Checker/DeBloater/Library all work without it,
                so users who don't want a Windows install from this USB at
                all can skip the ~4.7 GB Microsoft download entirely. If
                included, a further choice between building automatically
                (as V7 always did) or supplying your own ISOs. ISO
                Descriptions.txt is now written dynamically every run,
                accurately describing whichever path was actually taken -
                see Tools\Build-WindowsISOs.ps1 V2)
         Dated: 25-Sep-26
        Status: New ISO-build step not yet proven end-to-end on real hardware
                — see Tools\Build-WindowsISOs.ps1 Status note. Everything else
                reviewed and tested against a live R2 bucket; boot files added
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
$PostInstallZipHash = '097A67DAC3A0DBFFFB0C5201AFBE52C8B3312B5409294B42CFB4F7AAB7839325'
$ScriptsZipHash      = '6EB693B643830D8389E964A5065B75EB8E3BE8BAFCE47B1F6EA365B7D74AD7F3'
$BootZipHash         = '9BE793028A0061A9E3066D0F99E9D1191FDA5D3B9ADE40B4C833562A5964C045'

$ScriptRoot   = $PSScriptRoot
$SRC_INSTALL  = Join-Path $ScriptRoot 'USB-INSTALL'
$FidoPath     = Join-Path $ScriptRoot 'Tools\Fido.ps1'   # vendored copy — see Tools\Build-WindowsISOs.ps1

$P1_SIZE_MB      = 1024   # USB-INSTALL - FAT32 - 1 GB
$P3_SIZE_MB      = 1024   # Reserved (Courses)  - NTFS - 1 GB, structure only, never populated publicly
$GPT_OVERHEAD_MB = 50     # Safety margin for GPT metadata and alignment

$SAFE_LIST = @(
    '1. Purpose of USB-INSTALL Partition.txt',
    'RUN - On2it-WinFixIT.bat',
    'RUN - Win11-DeBloater.bat',
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
            # Same cumulative-average-since-start basis as $rateMBmin above (not
            # a jumpy last-minute-only rate) -- see project_robocopy_progress_reporting
            # memory for why that's the deliberate choice elsewhere in this codebase.
            # MB here is MiB (PowerShell's 1MB = 1,048,576) but Mbps is conventionally
            # decimal megabits/sec (matches $AssumedUploadMbps in the R2 upload
            # script, sourced from a real Speedtest result) -- hence *1MB*8/1000000
            # rather than a binary-only conversion throughout.
            $rateMbps     = $rateMBmin * 1MB * 8 / 60 / 1000000
            # ExpectedTotalMB is a rough hand-set estimate, not the real
            # Content-Length -- if the actual file is a bit bigger, show
            # "almost done" rather than silently dropping the ETA text.
            $etaText = if ($downloadedMB -ge $ExpectedTotalMB) {
                " (almost done)"
            } elseif ($rateMBmin -gt 0) {
                " (about $([math]::Ceiling(($ExpectedTotalMB - $downloadedMB) / $rateMBmin)) min remaining)"
            } else { "" }
            $rateText   = if ($rateMbps -gt 0) { " at $([math]::Round($rateMbps, 0)) Mbps" } else { "" }
            $statusLine = "  {0:N0} MB downloaded so far{1}{2}" -f $downloadedMB, $rateText, $etaText

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
# Rebuilt 24-Sep-26 without the two Windows ISOs (see
# project_github_vs_inhouse_iso_policy memory) - down from 20036 MB. A stale
# copy of both ISOs sitting in the R2 staging folder from before that
# exclusion existed meant the FIRST rebuild attempt didn't actually shrink
# (robocopy /XF hides a filename from /MIR's delete-pass too, not just its
# copy-pass) - fixed by explicitly removing them from staging, confirmed by
# the real zip dropping from 8996 to 8994 files and ~19.57 GB to ~10.6 GB.
$postExpectedMB = 1209
Write-Host "  Downloading On2it-WinFixIT.zip ($(Format-SizeMB $postExpectedMB), this will take a while)..." -ForegroundColor Cyan
Confirm-ExistingDownload -Path $postZip -Label 'On2it-WinFixIT.zip'
if (-not (Test-Path $postZip)) {
    # No longer a size-threshold branch here (was: "below 12 GB it's still
    # just ISOs + the menu system"). That stopped meaning anything 24-Sep-26,
    # once the two ISOs (~9.9 GB) came OUT of this zip entirely and get built
    # separately instead - the zip dropped under the old 12 GB threshold
    # purely from losing the ISOs, not from losing Applications/AI
    # Tools/Documentation, which are still genuinely in here (confirmed
    # against PRODUCTION's actual Install\ folder the same day). Always
    # showing the fuller description is now simply accurate.
    Write-Host "  On2it-WinFixIT Partition - $(Format-SizeMB $postExpectedMB) contains: "  -ForegroundColor DarkGray
    Write-Host "     Multiple Application & Utility Apps, "  -ForegroundColor DarkGray
    Write-Host "     AI Tools, "  -ForegroundColor DarkGray
    Write-Host "     Documentation & Reference Library + "  -ForegroundColor DarkGray
    Write-Host "     + Our LIBRARY Menu files" -ForegroundColor DarkGray
    Write-Host "  (The two Windows ISOs are built separately, straight from Microsoft — see below.)" -ForegroundColor DarkGray
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
# 2b. Windows installation media - optional, and never shipped by us either way
# ─────────────────────────────────────────────────────────────────────────────
# Compatibility Checker, DeBloater, and the Library all work with no Windows
# install media at all - DeBloater specifically only ever runs once Windows 11
# is already installed. Brian, 2026-09-25: not every user building this USB
# wants a Windows install from it at all, so this is now a real up-front
# choice rather than something every build pays the Microsoft download for
# regardless. Whichever path is taken, ISO Descriptions.txt always ends up
# accurately describing what's actually in Install\Windows - never left
# stale, never describing something that didn't happen.
. (Join-Path $ScriptRoot 'Tools\Robocopy-Common.ps1')

$isoDestFolder = Join-Path $SRC_POST 'Install\Windows'
New-Item -ItemType Directory -Path $isoDestFolder -Force | Out-Null
$isoDescPath = Join-Path $isoDestFolder 'ISO Descriptions.txt'

Write-Host "  Do you want to be able to install Windows 11 from this USB?" -ForegroundColor White
Write-Host "  (Compatibility Checker, DeBloater and the Library all work either way.)" -ForegroundColor DarkGray
Write-Host "  Include Windows install media? (Y/N): " -NoNewline -ForegroundColor Yellow
$includeWindowsInstall = (Read-Host) -match '^[Yy]'
$isoChoice = ''   # only ever set below when $includeWindowsInstall is true - initialized
                  # here so the later summary text can check it unconditionally
Write-Host ""

if (-not $includeWindowsInstall) {
    Write-Host "  Skipping Windows install media - Compatibility Checker, DeBloater, and the" -ForegroundColor Gray
    Write-Host "  Library will still all work fully. Add your own FULL Install.iso /" -ForegroundColor Gray
    Write-Host "  BYPASS Install.iso to Install\Windows later if you change your mind -" -ForegroundColor Gray
    Write-Host "  no need to rebuild the USB." -ForegroundColor Gray
    Set-Content -LiteralPath $isoDescPath -Encoding UTF8 -Value @(
        "No Windows installation media is included on this USB."
        ""
        "You chose not to include it when this USB was built. Compatibility"
        "Checker, DeBloater, and the Library all still work fully without it."
        ""
        "If you change your mind later, just add your own FULL Install.iso and"
        "BYPASS Install.iso to this folder - no need to rebuild the USB."
    )
} else {
    Write-Host "  There are two ways of doing this.  We can either:" -ForegroundColor White
    Write-Host "     - Build 'FULL Install.iso' by downloading Microsoft's latest version" -ForegroundColor Gray
    Write-Host "       of Windows 11, direct from Microsoft themselves.  " -ForegroundColor Gray
    Write-Host "       These are never downloaded from us or shipped in this repo.  Microsoft doesn't " -ForegroundColor DarkGray
    Write-Host "       allow redistributing Windows media, so your own copy is built afresh instead." -ForegroundColor DarkGray
    Write-Host "     - Use it to create a 'BYPASS Install.iso', " -ForegroundColor Gray
    Write-Host "       which bypasses Windows 11's TPM 2.0, Secure Boot, and supported-CPU checks " -ForegroundColor DarkGray
    Write-Host "       by removing sources\appraiserres.dll.  This is the same mechanism Rufus's" -ForegroundColor DarkGray
    Write-Host "       'Extended Windows 11 Installation' option uses.  RAM and storage are" -ForegroundColor DarkGray
    Write-Host "       already checked separately by WinFixIT's own Compatibility Checker." -ForegroundColor DarkGray
    Write-Host "       The Microsoft-account/internet-connection requirement during setup" -ForegroundColor DarkGray
    Write-Host "       isn't bypassed here either, as WinFixIT's DeBloater already lets you" -ForegroundColor DarkGray
    Write-Host "       disable or remove that requirement post-install." -ForegroundColor DarkGray
    Write-Host "     - and an 'ISO Descriptions.txt' file, " -ForegroundColor Gray
    Write-Host "       which will record how they were created, together with details of what was bypassed." -ForegroundColor DarkGray
    Write-Host "  These will all be created in the" -NoNewline -ForegroundColor Gray
    Write-Host " Install\Windows folder" -NoNewline -ForegroundColor White
    Write-Host " of the" -NoNewline -ForegroundColor Gray
    Write-Host " On2it-WinFixIT partition" -NoNewline -ForegroundColor White
    Write-Host " of the USB" -ForegroundColor Gray
  
    Write-Host ""
    Write-Host "  OR you can supply your own." -ForegroundColor White
    Write-Host "  You MUST use the file and folder names above or WinFixIT will not find them." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  So, what do you want to do - Download the ISOs from Microsoft, or supply your own?" -ForegroundColor White
    Write-Host "    D = Download from Microsoft (downloads ~4.7 GB)" -ForegroundColor White
    Write-Host "    S = Supply your own:" -ForegroundColor White
    Write-Host "          - FULL Install.iso," -ForegroundColor Gray
    Write-Host "          - BYPASS Install.iso," -ForegroundColor Gray
    Write-Host "          - ISO Descriptions.txt" -ForegroundColor Gray
    Write-Host "        files in" -NoNewline -ForegroundColor Gray
    Write-Host " On2it-WinFixIT\Install\Windows" -NoNewline -ForegroundColor White
    Write-Host " on the USB" -ForegroundColor Gray
    Write-Host "  Download/Supply? (D/S): " -NoNewline -ForegroundColor Yellow
    $isoChoice = Read-Host   

    if ($isoChoice -match '^[Ss]') {
        # No auto-generated ISO Descriptions.txt here -- deliberately, Brian
        # 2026-09-25: if the user builds their own ISOs their own way, only
        # THEY know how, so only they can honestly describe what was actually
        # bypassed and how. A generic auto-written file here would either be
        # wrong or meaninglessly vague for whatever they actually did.
        Write-Host "  Skipping Download - add your own FULL Install.iso," -ForegroundColor Gray
        Write-Host "  BYPASS Install.iso, and ISO Descriptions.txt to:" -ForegroundColor Gray
        Write-Host "  $isoDestFolder" -ForegroundColor Gray
    } else {
        # Neither ISO is downloaded from Cloudflare or shipped in this repo —
        # Microsoft doesn't permit redistributing Windows install media. Both
        # are built fresh here instead. See Tools\Build-WindowsISOs.ps1 for
        # the full method (including exactly what BYPASS Install.iso bypasses
        # and why) and its current test status.
        . (Join-Path $ScriptRoot 'Tools\Build-WindowsISOs.ps1')
        Write-Host "  Building Windows installation ISOs (FULL and BYPASS) from Microsoft..." -ForegroundColor White
        Write-Host "  These are never downloaded from us or shipped in this repo — Microsoft doesn't" -ForegroundColor DarkGray
        Write-Host "  allow redistributing Windows media, so your own copy is built afresh instead." -ForegroundColor DarkGray
        $isoWorkFolder = Join-Path $tempRoot 'ISO-Build'
        New-WindowsInstallIsos -DestFolder $isoDestFolder -WorkFolder $isoWorkFolder -FidoPath $FidoPath
        Write-Host ""
    }
}

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

    # Partition NAMES (volume labels), not a file listing -- Brian, 2026-09-25,
    # after the file-listing version showed obscure entries like language
    # folders (bg-bg, cs-cz...) from old Windows install media: "We SHOULD use
    # Partition Names. Most users won't know file names." A label like
    # "RECOVERY" or "On2it-WinFixIT" is something a user can actually
    # recognise as theirs (or not); an internal file/folder name usually
    # isn't. Reading FileSystemLabel via Get-Volume doesn't need a drive
    # letter to be assigned either (unlike the old approach), so this also
    # covers the 2026-07-17 gap noted above for a partition with no drive
    # letter yet -- a strict improvement, not just a wording change.
    $existingPartitions = Get-Partition -DiskNumber $tgtDiskNum -ErrorAction SilentlyContinue
    $partitionLines = @(foreach ($part in $existingPartitions) {
        $vol = $part | Get-Volume -ErrorAction SilentlyContinue
        $label = if ($vol -and $vol.FileSystemLabel) { $vol.FileSystemLabel } else { '(no name)' }
        $driveLetterText = if ($vol -and $vol.DriveLetter) { " ($($vol.DriveLetter):)" } else { '' }
        "$label$driveLetterText"
    })

    if ($partitionLines.Count -gt 0) {
        Write-Host "  Partition names on it:" -ForegroundColor White
        foreach ($line in $partitionLines) {
            Write-Host "          $line" -ForegroundColor White
        }
    } else {
        Write-Host "  Its partition names could not be previewed." -ForegroundColor White
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
Write-Host "  On2it-WinFixIT contains all the files for:" -ForegroundColor White
if ($includeWindowsInstall -and $isoChoice -notmatch '^[Ss]') {
    Write-Host "      Installing Windows 11:" -ForegroundColor White
    Write-Host "          $BulletChar BYPASS Install.iso - installs Windows 11, bypassing its" -ForegroundColor Gray
    Write-Host "            usual insistence on TPM, Secure Boot, and a UEFI BIOS." -ForegroundColor Gray
    Write-Host "          $BulletChar FULL Install.iso - installs Windows with FULL enhanced" -ForegroundColor Gray
    Write-Host "            security features." -ForegroundColor Gray
} elseif ($includeWindowsInstall) {
    Write-Host "      Installing Windows 11 - once you've added your own FULL Install.iso /" -ForegroundColor White
    Write-Host "         BYPASS Install.iso to Install\Windows (see ISO Descriptions.txt there)." -ForegroundColor Gray
} else {
    Write-Host "      No Windows install media - you chose to skip it. Add your own" -ForegroundColor White
    Write-Host "         FULL Install.iso / BYPASS Install.iso to Install\Windows any time -" -ForegroundColor Gray
    Write-Host "         no need to rebuild the USB." -ForegroundColor Gray
}
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
Write-Host "  A full user manual is included in the On2it-WinFixIT partition as 'WinFixIT - User Manual.pdf'." -ForegroundColor Gray
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
